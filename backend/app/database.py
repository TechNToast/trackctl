from __future__ import annotations

import os
from collections.abc import AsyncGenerator
from typing import Any
from urllib.parse import quote

from sqlalchemy import Engine, event
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase

# Two ways to reach Postgres:
#   DATABASE_URL        local development (postgresql://user:password@host:5432/dbname).
#   PGHOST + PGUSER     Azure (DATABASE_AUTH=entra). No password exists; each new connection signs
#                       in with the managed identity named by AZURE_CLIENT_ID.
# With neither set the app runs in stub-only mode; DB-backed endpoints are skipped.

ENTRA_SCOPE = "https://ossrdbms-aad.database.windows.net/.default"

# Entra tokens last about an hour; recycle pooled connections well before that.
POOL_RECYCLE_SECONDS = 1800


def database_url(driver: str = "asyncpg") -> str | None:
    """SQLAlchemy URL for the given driver ("asyncpg" for the app, "psycopg2" for Alembic)."""
    url = os.environ.get("DATABASE_URL")
    if url:
        for prefix in ("postgresql+asyncpg://", "postgresql+psycopg2://", "postgresql://"):
            if url.startswith(prefix):
                url = f"postgresql+{driver}://" + url[len(prefix) :]
                break
        if driver == "psycopg2":
            url = url.replace("?ssl=require", "?sslmode=require", 1)
        return url

    host = os.environ.get("PGHOST")
    user = os.environ.get("PGUSER")
    if not (host and user):
        return None
    dbname = os.environ.get("PGDATABASE", "athena")
    ssl = "ssl=require" if driver == "asyncpg" else "sslmode=require"
    return f"postgresql+{driver}://{quote(user, safe='')}@{host}:5432/{dbname}?{ssl}"


def uses_entra() -> bool:
    return not os.environ.get("DATABASE_URL") and os.environ.get("DATABASE_AUTH") == "entra"


_credential: Any = None


def entra_token() -> str:
    global _credential
    if _credential is None:
        from azure.identity import DefaultAzureCredential

        _credential = DefaultAzureCredential(
            managed_identity_client_id=os.environ.get("AZURE_CLIENT_ID")
        )
    return _credential.get_token(ENTRA_SCOPE).token


def use_entra_password(sync_engine: Engine) -> None:
    """Supply a fresh Entra token as the password whenever the pool opens a connection."""

    @event.listens_for(sync_engine, "do_connect")
    def _provide_token(dialect: Any, conn_rec: Any, cargs: Any, cparams: dict[str, Any]) -> None:
        cparams["password"] = entra_token()


_DATABASE_URL = database_url("asyncpg")

engine = (
    create_async_engine(
        _DATABASE_URL,
        echo=False,
        pool_pre_ping=True,
        pool_recycle=POOL_RECYCLE_SECONDS,
        # Reduce connection churn on Container Apps where connections are expensive.
        pool_size=5,
        max_overflow=10,
    )
    if _DATABASE_URL
    else None
)

if engine is not None and uses_entra():
    use_entra_password(engine.sync_engine)

SessionLocal: async_sessionmaker[AsyncSession] | None = (
    async_sessionmaker(engine, expire_on_commit=False) if engine else None
)

DB_AVAILABLE: bool = engine is not None


class Base(DeclarativeBase):
    pass


async def get_db() -> AsyncGenerator[AsyncSession | None, None]:
    """FastAPI dependency — yields a DB session, or None if DATABASE_URL is not configured."""
    if SessionLocal is None:
        yield None
        return
    async with SessionLocal() as session:
        yield session
