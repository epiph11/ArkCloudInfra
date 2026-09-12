"""
RGPD automated retention purge — AWS side (Sprint 6, ADR-0012).

Decision made with the user (12/09/2026, docs/rgpd-classification-donnees.md §2/§5): a customer
becomes eligible once RETENTION_YEARS years have passed since their last order (or since account
creation, if they have none), and an eligible customer is anonymized in place — the same fields
ArkCloud.API's Customer.Anonymize() overwrites, and the exact same email format
("anonymized+{id:N}@arkcloud.invalid", i.e. the UUID without dashes, lowercase) so a customer
anonymized by this Lambda is indistinguishable from one anonymized through the on-demand RGPD
erasure path (CustomerAppService.DeleteAsync). Never a hard delete — same reasoning as the
on-demand path: an order referencing this customer may still exist and is retained under the
legal-obligation exception (RGPD art. 17(3)(b)), so the row must survive.

Why a Lambda at all, and why *this* Lambda's shape specifically: this only exists on AWS. Azure
runs the equivalent job as an in-process BackgroundService inside ArkCloud.API instead (see
CustomerRetentionPurgeHostedService in the ArkCloud repo) — an Azure Automation Runbook has no
network path to the private VNet Postgres lives in (the exact constraint ADR-0010 already
documents for a different job), so there is no Azure equivalent of "just write a Lambda that
connects directly". On AWS this constraint doesn't apply: this Lambda runs inside the same VPC as
modules/aws/secret-rotation's rotation Lambda (same subnets, same security group), which already
has a proven network path to RDS.

This is a standalone scheduled Lambda (EventBridge rule, see main.tf), not folded into
secret-rotation's Lambda: that one is invoked by Secrets Manager's four-step rotation state
machine (createSecret/setSecret/testSecret/finishSecret) — there is no secret being rotated here,
so shoehorning this into that state machine would be a worse fit than a second, purpose-built
function reusing the same networking and connection pattern.

Connects as arkcloud_app (read via ARKCLOUD_APP_SECRET_ARN) rather than the RDS master user —
arkcloud_app already has the exact SELECT/INSERT/UPDATE/DELETE grants this needs (see
modules/aws/secret-rotation/lambda/rotate.py's _set_secret_app_role), and using it here keeps
this Lambda's blast radius identical to the application's own, rather than escalating to admin
for a job that doesn't need it.
"""

import logging
import os
import re

import boto3
import psycopg2

logger = logging.getLogger()
logger.setLevel(logging.INFO)

secretsmanager = boto3.client("secretsmanager")

ARKCLOUD_APP_SECRET_ARN = os.environ["ARKCLOUD_APP_SECRET_ARN"]
DB_HOST = os.environ["DB_HOST"]
DB_PORT = os.environ["DB_PORT"]
DB_NAME = os.environ["DB_NAME"]
DB_USERNAME = os.environ["DB_USERNAME"]
RETENTION_YEARS = int(os.environ.get("RETENTION_YEARS", "3"))

# Idempotency marker — must match Customer.Anonymize()'s email domain exactly (ArkCloud repo,
# backend/ArkCloud.Domain/Entities/Customer.cs). A real customer email can never collide with it.
ANONYMIZED_EMAIL_SUFFIX = "@arkcloud.invalid"

# Single statement: a CTE for each customer's most recent order date, then an UPDATE ... FROM
# selecting exactly the eligible rows. Anonymizing directly with the cutoff as a bound parameter
# (rather than SELECTing eligible ids in Python first, then looping UPDATEs) keeps this a single
# round trip and avoids a TOCTOU window between "read eligible" and "write anonymized" — a row
# that stops being eligible between those two steps (it can't in practice, nothing un-ages a
# customer, but there is no reason to accept the race just to make the code read more like the
# ArkCloud.API/C# version).
PURGE_SQL = """
WITH last_order AS (
    SELECT "CustomerId", MAX("CreatedAt") AS last_order_at
    FROM orders
    GROUP BY "CustomerId"
),
eligible AS (
    SELECT c."Id"
    FROM customers c
    LEFT JOIN last_order lo ON lo."CustomerId" = c."Id"
    WHERE c.email NOT LIKE %(anonymized_suffix)s
      AND (
          (lo.last_order_at IS NULL AND c."CreatedAt" < %(cutoff)s)
          OR (lo.last_order_at IS NOT NULL AND lo.last_order_at < %(cutoff)s)
      )
)
UPDATE customers c
SET "FirstName" = 'Anonymized',
    "LastName"  = 'Anonymized',
    email       = 'anonymized+' || replace(c."Id"::text, '-', '') || %(anonymized_suffix)s,
    street      = 'Anonymized',
    city        = 'Anonymized',
    country     = 'Anonymized'
FROM eligible
WHERE c."Id" = eligible."Id"
RETURNING c."Id";
"""


def _password_from_connection_string(connection_string):
    """Same parsing as modules/aws/secret-rotation/lambda/rotate.py — the secret is an opaque
    .NET connection string, not structured JSON."""
    match = re.search(r"(?:^|;)\s*Password=([^;]*)", connection_string)
    if not match:
        raise ValueError("Stored secret does not look like a connection string with a Password= field")
    return match.group(1)


def lambda_handler(event, context):
    secret_value = secretsmanager.get_secret_value(SecretId=ARKCLOUD_APP_SECRET_ARN)["SecretString"]
    password = _password_from_connection_string(secret_value)

    conn = psycopg2.connect(
        host=DB_HOST,
        port=int(DB_PORT),
        dbname=DB_NAME,
        user=DB_USERNAME,
        password=password,
        sslmode="require",
        connect_timeout=15,
    )
    conn.autocommit = True
    try:
        with conn.cursor() as cur:
            # Postgres computes NOW() - INTERVAL server-side rather than passing a Python-computed
            # cutoff, so the boundary is anchored to the database's clock (already UTC, same as
            # every "CreatedAt" column) rather than the Lambda execution environment's.
            cur.execute(
                "SELECT NOW() - (%(years)s || ' years')::interval",
                {"years": RETENTION_YEARS},
            )
            cutoff = cur.fetchone()[0]

            cur.execute(
                PURGE_SQL,
                {"cutoff": cutoff, "anonymized_suffix": f"%{ANONYMIZED_EMAIL_SUFFIX}"},
            )
            purged_count = cur.rowcount

            # Deliberately not logging which customers (no id/email) — the point of this feature
            # is minimizing personal data; logging identifiers of the rows just anonymized would
            # undercut it. A count is enough for operational visibility (CloudWatch).
            logger.info(
                "RGPD retention purge: anonymized %d customer(s) inactive since before %s (retention=%dy).",
                purged_count, cutoff, RETENTION_YEARS,
            )
    finally:
        conn.close()

    return {"purged_count": purged_count}
