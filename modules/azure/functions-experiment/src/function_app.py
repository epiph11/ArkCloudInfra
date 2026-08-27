"""
TEMPORARY (Sprint 6 experiment) -- see modules/azure/functions-experiment/main.tf's header
comment for the full context: this exists to try Azure Functions once, hands-on, not as the
chosen long-term Azure fix for STRIDE flow 3.

Ports the same logic already proven working on AWS (modules/aws/secret-rotation/lambda/rotate.py,
function _set_secret_app_role): connect to Postgres as the admin account, create-or-rotate the
least-privilege arkcloud_app role (DML only -- SELECT/INSERT/UPDATE/DELETE, never DDL), test the
new password actually authenticates before publishing it anywhere.

Trigger is HTTP rather than a timer, on purpose: this is invoked manually a handful of times
during the experiment, not on the 90-day schedule the AWS Lambda and the Azure Automation
Runbook use for their own credentials. Auth level FUNCTION means a function key is required --
see the README in this same directory for how to fetch it and call this once deployed.
"""
import json
import logging
import secrets as pysecrets
import string

import azure.functions as func
import psycopg2
from azure.identity import ManagedIdentityCredential
from azure.keyvault.secrets import SecretClient
from psycopg2 import sql

app = func.FunctionApp()

# Read once per cold start, not per request -- same reasoning as the constants at the top of
# rotate.py. A missing one fails loudly (KeyError) at import time rather than mysteriously deep
# inside a request.
import os

POSTGRES_HOST = os.environ["POSTGRES_HOST"]
POSTGRES_DB = os.environ["POSTGRES_DB"]
POSTGRES_ADMIN_USERNAME = os.environ["POSTGRES_ADMIN_USERNAME"]
KEY_VAULT_URI = os.environ["KEY_VAULT_URI"]
ADMIN_SECRET_NAME = os.environ["ADMIN_SECRET_NAME"]
APP_ROLE_SECRET_NAME = os.environ["APP_ROLE_SECRET_NAME"]

APP_ROLE_USERNAME = "arkcloud_app"

# No punctuation -- same "avoid escaping headaches in a semicolon/equals-delimited connection
# string" reasoning as rotate.py and the PowerShell bootstrap script.
_ALPHABET = string.ascii_letters + string.digits


def _generate_password(length: int = 32) -> str:
    return "".join(pysecrets.choice(_ALPHABET) for _ in range(length))


def _parse_password(connection_string: str) -> str:
    for part in connection_string.split(";"):
        key, _, value = part.strip().partition("=")
        if key.strip().lower() == "password":
            return value
    raise ValueError("No Password= segment found in the admin connection string from Key Vault.")


@app.route(route="bootstrap-app-role", auth_level=func.AuthLevel.FUNCTION, methods=["POST"])
def bootstrap_app_role(req: func.HttpRequest) -> func.HttpResponse:
    logging.info("bootstrap_app_role: starting.")

    # System-assigned managed identity -- no client secret anywhere, same principle as every
    # other identity in this project (Automation Account, Lambda execution role, CI's OIDC role).
    credential = ManagedIdentityCredential()
    kv_client = SecretClient(vault_url=KEY_VAULT_URI, credential=credential)

    admin_connection_string = kv_client.get_secret(ADMIN_SECRET_NAME).value
    admin_password = _parse_password(admin_connection_string)

    new_app_password = _generate_password()

    conn = psycopg2.connect(
        host=POSTGRES_HOST,
        port=5432,
        dbname=POSTGRES_DB,
        user=POSTGRES_ADMIN_USERNAME,
        password=admin_password,
        sslmode="require",
        connect_timeout=15,
    )
    conn.autocommit = True
    role_created = False
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (APP_ROLE_USERNAME,))
            role_exists = cur.fetchone() is not None
            role_created = not role_exists

            if role_exists:
                cur.execute(
                    sql.SQL("ALTER ROLE {} WITH PASSWORD %s").format(sql.Identifier(APP_ROLE_USERNAME)),
                    (new_app_password,),
                )
                logging.info("bootstrap_app_role: altered password for existing role %s", APP_ROLE_USERNAME)
            else:
                cur.execute(
                    sql.SQL(
                        "CREATE ROLE {} WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE "
                        "NOREPLICATION NOBYPASSRLS PASSWORD %s"
                    ).format(sql.Identifier(APP_ROLE_USERNAME)),
                    (new_app_password,),
                )
                logging.info("bootstrap_app_role: created role %s (bootstrap, first run)", APP_ROLE_USERNAME)

            cur.execute(
                sql.SQL("GRANT CONNECT ON DATABASE {} TO {}").format(
                    sql.Identifier(POSTGRES_DB), sql.Identifier(APP_ROLE_USERNAME)
                )
            )
            cur.execute(
                sql.SQL("GRANT USAGE ON SCHEMA public TO {}").format(sql.Identifier(APP_ROLE_USERNAME))
            )
            cur.execute(
                sql.SQL("GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO {}").format(
                    sql.Identifier(APP_ROLE_USERNAME)
                )
            )
            cur.execute(
                sql.SQL("GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO {}").format(
                    sql.Identifier(APP_ROLE_USERNAME)
                )
            )
            # So tables/sequences created *after* this run (future EF Core migrations) are
            # covered automatically -- identical reasoning and identical statements to
            # rotate.py's _set_secret_app_role.
            cur.execute(
                sql.SQL(
                    "ALTER DEFAULT PRIVILEGES FOR ROLE {} IN SCHEMA public "
                    "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO {}"
                ).format(sql.Identifier(POSTGRES_ADMIN_USERNAME), sql.Identifier(APP_ROLE_USERNAME))
            )
            cur.execute(
                sql.SQL(
                    "ALTER DEFAULT PRIVILEGES FOR ROLE {} IN SCHEMA public "
                    "GRANT USAGE, SELECT ON SEQUENCES TO {}"
                ).format(sql.Identifier(POSTGRES_ADMIN_USERNAME), sql.Identifier(APP_ROLE_USERNAME))
            )
    finally:
        conn.close()

    # Prove the new password actually authenticates before publishing it to Key Vault -- same
    # "test before promote" discipline as testSecret in the AWS Lambda's 4-step state machine.
    # If this raises, arkcloud_app has a password Key Vault doesn't know about yet; re-running
    # this function fixes it (the ALTER ROLE branch above just sets it again).
    test_conn = psycopg2.connect(
        host=POSTGRES_HOST,
        port=5432,
        dbname=POSTGRES_DB,
        user=APP_ROLE_USERNAME,
        password=new_app_password,
        sslmode="require",
        connect_timeout=15,
    )
    test_conn.close()
    logging.info("bootstrap_app_role: new password for %s authenticated successfully.", APP_ROLE_USERNAME)

    new_connection_string = (
        f"Host={POSTGRES_HOST};Port=5432;Database={POSTGRES_DB};"
        f"Username={APP_ROLE_USERNAME};Password={new_app_password};Ssl Mode=Require"
    )
    kv_client.set_secret(APP_ROLE_SECRET_NAME, new_connection_string)
    logging.info("bootstrap_app_role: wrote connection string to Key Vault secret '%s'.", APP_ROLE_SECRET_NAME)

    return func.HttpResponse(
        json.dumps({"status": "ok", "role": APP_ROLE_USERNAME, "role_created": role_created}),
        status_code=200,
        mimetype="application/json",
    )
