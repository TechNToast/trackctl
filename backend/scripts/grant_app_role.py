"""Give the API's managed identity its database role.

Runs in the migrate job after `alembic upgrade head`, signed in as the Entra administrator
(PGUSER = the migrate identity). Safe to run on every deploy.

The API role (APP_DB_ROLE) can read and write rows. It cannot change the schema, create roles,
or see other databases.
"""

from __future__ import annotations

import os
import sys

import psycopg2
from psycopg2 import sql

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from app.database import entra_token  # noqa: E402


def grant_statements(role: str, dbname: str) -> list[sql.Composed]:
    r = sql.Identifier(role)
    return [
        sql.SQL("GRANT CONNECT ON DATABASE {} TO {}").format(sql.Identifier(dbname), r),
        sql.SQL("GRANT USAGE ON SCHEMA public TO {}").format(r),
        sql.SQL("GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO {}").format(
            r
        ),
        sql.SQL("GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO {}").format(r),
        sql.SQL(
            "ALTER DEFAULT PRIVILEGES IN SCHEMA public "
            "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO {}"
        ).format(r),
        sql.SQL(
            "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO {}"
        ).format(r),
    ]


def connect(dbname: str) -> psycopg2.extensions.connection:
    conn = psycopg2.connect(
        host=os.environ["PGHOST"],
        dbname=dbname,
        user=os.environ["PGUSER"],
        password=entra_token(),
        sslmode="require",
    )
    conn.autocommit = True
    return conn


def main() -> None:
    role = os.environ["APP_DB_ROLE"]
    dbname = os.environ.get("PGDATABASE", "athena")

    # Entra principals are created from the postgres database.
    conn = connect("postgres")
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (role,))
            if cur.fetchone() is None:
                cur.execute("SELECT * FROM pgaadauth_create_principal(%s, false, false)", (role,))
                print(f"Created database role for {role}")
    finally:
        conn.close()

    conn = connect(dbname)
    try:
        with conn.cursor() as cur:
            for statement in grant_statements(role, dbname):
                cur.execute(statement)
    finally:
        conn.close()
    print(f"Granted read/write on {dbname} to {role}")


if __name__ == "__main__":
    main()
