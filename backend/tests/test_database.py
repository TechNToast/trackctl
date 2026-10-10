"""Connection settings: local password URLs and passwordless Entra sign-in on Azure."""

from __future__ import annotations

import sqlite3
import sys
from pathlib import Path
from typing import Any

import pytest
from sqlalchemy import create_engine, event, text

sys.path.append(str(Path(__file__).resolve().parents[2]))

from backend.app import database  # noqa: E402


@pytest.fixture(autouse=True)
def clean_env(monkeypatch: pytest.MonkeyPatch) -> None:
    for name in ("DATABASE_URL", "DATABASE_AUTH", "PGHOST", "PGUSER", "PGDATABASE"):
        monkeypatch.delenv(name, raising=False)


def test_no_settings_means_stub_mode() -> None:
    assert database.database_url() is None
    assert not database.uses_entra()


def test_local_url_is_normalised_per_driver(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("DATABASE_URL", "postgresql://u:p@localhost:5432/athena?ssl=require")
    assert database.database_url("asyncpg") == (
        "postgresql+asyncpg://u:p@localhost:5432/athena?ssl=require"
    )
    assert database.database_url("psycopg2") == (
        "postgresql+psycopg2://u:p@localhost:5432/athena?sslmode=require"
    )


def test_asyncpg_url_converts_for_alembic(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("DATABASE_URL", "postgresql+asyncpg://u:p@db:5432/athena?ssl=require")
    assert database.database_url("psycopg2") == (
        "postgresql+psycopg2://u:p@db:5432/athena?sslmode=require"
    )


def test_entra_url_has_no_password(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("PGHOST", "psql-athena-dev-tnt.postgres.database.azure.com")
    monkeypatch.setenv("PGUSER", "id-athena-dev-api")
    monkeypatch.setenv("DATABASE_AUTH", "entra")
    url = database.database_url("asyncpg")
    assert url == (
        "postgresql+asyncpg://id-athena-dev-api@"
        "psql-athena-dev-tnt.postgres.database.azure.com:5432/athena?ssl=require"
    )
    assert database.uses_entra()


def test_group_names_are_url_encoded(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("PGHOST", "db")
    monkeypatch.setenv("PGUSER", "TNT Prod Operators")
    assert database.database_url("psycopg2") == (
        "postgresql+psycopg2://TNT%20Prod%20Operators@db:5432/athena?sslmode=require"
    )


def test_local_url_wins_over_entra(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("DATABASE_URL", "postgresql://u:p@localhost/athena")
    monkeypatch.setenv("DATABASE_AUTH", "entra")
    assert not database.uses_entra()


def test_each_new_connection_gets_a_fresh_token(monkeypatch: pytest.MonkeyPatch) -> None:
    tokens = iter(["token-1", "token-2"])
    monkeypatch.setattr(database, "entra_token", lambda: next(tokens))

    engine = create_engine("sqlite://")
    database.use_entra_password(engine)
    seen: list[str] = []

    @event.listens_for(engine, "do_connect")
    def _capture(dialect: Any, conn_rec: Any, cargs: Any, cparams: dict[str, Any]) -> Any:
        seen.append(cparams.pop("password"))
        return sqlite3.connect(":memory:")

    for _ in range(2):
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))
        engine.dispose()

    assert seen == ["token-1", "token-2"]
