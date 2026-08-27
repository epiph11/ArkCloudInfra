"""
Custom Secrets Manager rotation Lambda — AWS counterpart to modules/azure/secret-rotation's
PowerShell runbook (Sprint 6).

Why custom rather than AWS's own SecretsManagerRDSPostgreSQLRotationSingleUser template:
AWS's Lambda requires the secret to be structured JSON ({"engine","host","username","password",
"dbname","port"}). This project's secret holds a plain .NET connection string instead, because
ArkCloud.API reads it wholesale via GetConnectionString("DefaultConnection") and the ECS task
definition maps the secret straight onto ConnectionStrings__DefaultConnection. Reformatting the
secret to AWS's shape would mean changing the application (and diverging from the Azure side,
which reads a connection string out of Key Vault the same way). So this Lambda does the same
three steps the Azure runbook does, on the same 90-day cadence.

Secrets Manager drives rotation as a four-step state machine and invokes this function once per
step. The steps must be idempotent — Secrets Manager retries on failure.

  createSecret  — generate the new password, stage it as AWSPENDING (nothing live changes yet)
  setSecret     — apply that password to the RDS instance
  testSecret    — connect with the pending credential and prove it works
  finishSecret  — promote AWSPENDING to AWSCURRENT, then force a new ECS deployment so the tasks
                  pick up the rotated value

Deliberately ordered so that nothing is promoted to AWSCURRENT until it has been proven to work
against the real database — a failed rotation leaves the old, still-valid password in place.
"""

import logging
import os
import re
import time

import boto3
import psycopg2
from psycopg2 import sql

logger = logging.getLogger()
logger.setLevel(logging.INFO)

secretsmanager = boto3.client("secretsmanager")
rds = boto3.client("rds")
ecs = boto3.client("ecs")

# TARGET_ROLE selects which of two structurally different rotation paths this Lambda instance
# runs (two separate Lambda instances exist, see modules/aws/secret-rotation's target_role
# variable and environments/dev/main.tf's aws_secret_rotation / aws_secret_rotation_app_role):
#
#   master — the original Sprint 6 behaviour, unchanged. Rotates RDS's own master user via the
#            control-plane API (rds.modify_db_instance). Can only ever target the one designated
#            master account — that's an RDS API constraint, not a choice made here (see
#            docs/infra-roadmap.md / the STRIDE elevation-of-privilege write-up for why this
#            can't be reused for a second role).
#
#   app    — Sprint 6 STRIDE elevation-of-privilege remediation. Rotates arkcloud_app, the
#            least-privilege DML-only role ArkCloud.API should connect as instead of the master
#            user. Since no management-plane API can touch an arbitrary Postgres role, this
#            path connects as the admin (read-only from ADMIN_SECRET_ARN, never modified) and
#            runs real SQL. The very first run also creates the role — this Lambda IS the
#            bootstrap, not a separate one-off script, precisely because both the bootstrap and
#            every later rotation need the same private VPC network path to reach RDS, and
#            building that path twice (once for a local script, once for this Lambda) would be
#            duplicated, throwaway work. See modules/aws/secrets' arkcloud_app secret comment
#            for how the very first version gets seeded so rotation has something to rotate from.
TARGET_ROLE = os.environ.get("TARGET_ROLE", "master")

DB_HOST = os.environ["DB_HOST"]
DB_PORT = os.environ["DB_PORT"]
DB_NAME = os.environ["DB_NAME"]
DB_USERNAME = os.environ["DB_USERNAME"]

# master-only
DB_INSTANCE_IDENTIFIER = os.environ.get("DB_INSTANCE_IDENTIFIER")
ECS_CLUSTER = os.environ.get("ECS_CLUSTER")
ECS_SERVICE = os.environ.get("ECS_SERVICE")

# app-only — credentials to connect AS, in order to manage a role that isn't the connecting user
ADMIN_SECRET_ARN = os.environ.get("ADMIN_SECRET_ARN")
ADMIN_USERNAME = os.environ.get("ADMIN_USERNAME")

# Same alphabet as the Azure runbook, for the same reason: connection strings are
# semicolon/equals-delimited, so punctuation would need escaping that differs between the
# connection string, the RDS API and psycopg2. 62^32 is far more entropy than needed here.
PASSWORD_ALPHABET_EXCLUDE = "/@\"'\\ ;="


def _connection_string(password):
    return (
        f"Host={DB_HOST};Port={DB_PORT};Database={DB_NAME};"
        f"Username={DB_USERNAME};Password={password};Ssl Mode=Require"
    )


def _password_from_connection_string(connection_string):
    """The secret is an opaque connection string, so the password has to be parsed back out of
    it to connect during testSecret. Anchored on ';' boundaries rather than a loose search so a
    'Password=' substring elsewhere can't match."""
    match = re.search(r"(?:^|;)\s*Password=([^;]*)", connection_string)
    if not match:
        raise ValueError("Stored secret does not look like a connection string with a Password= field")
    return match.group(1)


def _get_secret_value(arn, stage, token=None):
    kwargs = {"SecretId": arn, "VersionStage": stage}
    if token:
        kwargs["VersionId"] = token
    return secretsmanager.get_secret_value(**kwargs)["SecretString"]


def create_secret(arn, token):
    # Idempotency: if AWSPENDING already exists for this token (Secrets Manager retried), reuse
    # it rather than generating a second password and stranding the first one.
    try:
        _get_secret_value(arn, "AWSPENDING", token)
        logger.info("createSecret: AWSPENDING already staged for this token, nothing to do.")
        return
    except secretsmanager.exceptions.ResourceNotFoundException:
        pass

    new_password = secretsmanager.get_random_password(
        PasswordLength=32,
        ExcludeCharacters=PASSWORD_ALPHABET_EXCLUDE,
        ExcludePunctuation=True,
        RequireEachIncludedType=True,
    )["RandomPassword"]

    secretsmanager.put_secret_value(
        SecretId=arn,
        ClientRequestToken=token,
        SecretString=_connection_string(new_password),
        VersionStages=["AWSPENDING"],
    )
    logger.info("createSecret: staged a new connection string as AWSPENDING.")


def set_secret(arn, token):
    if TARGET_ROLE == "app":
        return _set_secret_app_role(arn, token)
    return _set_secret_master(arn, token)


def _set_secret_master(arn, token):
    pending = _get_secret_value(arn, "AWSPENDING", token)
    new_password = _password_from_connection_string(pending)

    rds.modify_db_instance(
        DBInstanceIdentifier=DB_INSTANCE_IDENTIFIER,
        MasterUserPassword=new_password,
        ApplyImmediately=True,
    )
    logger.info("setSecret: master password update requested on %s.", DB_INSTANCE_IDENTIFIER)

    # ModifyDBInstance is asynchronous even with ApplyImmediately — it returns as soon as the
    # request is accepted, not when the password is live. The first real run of this function
    # proved that the hard way: testSecret ran ~1s later and got "password authentication
    # failed", and only Secrets Manager's own retry (~100s later) made the rotation succeed.
    # Relying on that retry is not a design, so wait here until RDS reports the pending
    # modification has been applied. Mirrors the Azure runbook, which polls for state=Ready.
    deadline = time.time() + 300
    while True:
        instance = rds.describe_db_instances(DBInstanceIdentifier=DB_INSTANCE_IDENTIFIER)["DBInstances"][0]
        status = instance["DBInstanceStatus"]
        # A master password change surfaces here while it's still being applied; once RDS has
        # taken it, the key disappears from PendingModifiedValues.
        password_pending = "MasterUserPassword" in instance.get("PendingModifiedValues", {})

        if status == "available" and not password_pending:
            logger.info("setSecret: password applied and instance is available.")
            return

        if time.time() > deadline:
            raise RuntimeError(
                f"Password change not applied within 5 minutes "
                f"(status={status}, password_pending={password_pending}). "
                "Not promoting the pending secret - the old password is still the live one."
            )

        logger.info("setSecret: waiting (status=%s, password_pending=%s)", status, password_pending)
        time.sleep(10)


def _set_secret_app_role(arn, token):
    """Connects as the RDS master user (read-only from ADMIN_SECRET_ARN — that secret is never
    written by this code path) and either creates DB_USERNAME (arkcloud_app) if it doesn't exist
    yet, or just changes its password if it does. Same statement set as the original one-off
    scripts/sql/bootstrap-arkcloud-app-role.sql (ArkCloudInfra), so the very first invocation of
    this Lambda after `terraform apply` performs the real bootstrap — there is no separate manual
    step. The GRANT/ALTER DEFAULT PRIVILEGES statements are re-run on every rotation, not just at
    creation: they're idempotent, and re-running them is a cheap self-heal if a grant was ever
    manually revoked, rather than a real cost.
    """
    pending = _get_secret_value(arn, "AWSPENDING", token)
    new_password = _password_from_connection_string(pending)

    admin_connection_string = _get_secret_value(ADMIN_SECRET_ARN, "AWSCURRENT")
    admin_password = _password_from_connection_string(admin_connection_string)

    conn = psycopg2.connect(
        host=DB_HOST,
        port=int(DB_PORT),
        dbname=DB_NAME,
        user=ADMIN_USERNAME,
        password=admin_password,
        sslmode="require",
        connect_timeout=15,
    )
    conn.autocommit = True
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (DB_USERNAME,))
            role_exists = cur.fetchone() is not None

            if role_exists:
                cur.execute(
                    sql.SQL("ALTER ROLE {} WITH PASSWORD %s").format(sql.Identifier(DB_USERNAME)),
                    (new_password,),
                )
                logger.info("setSecret: altered password for existing role %s.", DB_USERNAME)
            else:
                cur.execute(
                    sql.SQL(
                        "CREATE ROLE {} WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE "
                        "NOREPLICATION NOBYPASSRLS PASSWORD %s"
                    ).format(sql.Identifier(DB_USERNAME)),
                    (new_password,),
                )
                logger.info("setSecret: created role %s (bootstrap, first rotation).", DB_USERNAME)

            cur.execute(
                sql.SQL("GRANT CONNECT ON DATABASE {} TO {}")
                .format(sql.Identifier(DB_NAME), sql.Identifier(DB_USERNAME))
            )
            cur.execute(
                sql.SQL("GRANT USAGE ON SCHEMA public TO {}").format(sql.Identifier(DB_USERNAME))
            )
            cur.execute(
                sql.SQL("GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO {}")
                .format(sql.Identifier(DB_USERNAME))
            )
            cur.execute(
                sql.SQL("GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO {}")
                .format(sql.Identifier(DB_USERNAME))
            )
            cur.execute(
                sql.SQL(
                    "ALTER DEFAULT PRIVILEGES FOR ROLE {} IN SCHEMA public "
                    "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO {}"
                ).format(sql.Identifier(ADMIN_USERNAME), sql.Identifier(DB_USERNAME))
            )
            cur.execute(
                sql.SQL(
                    "ALTER DEFAULT PRIVILEGES FOR ROLE {} IN SCHEMA public "
                    "GRANT USAGE, SELECT ON SEQUENCES TO {}"
                ).format(sql.Identifier(ADMIN_USERNAME), sql.Identifier(DB_USERNAME))
            )
        logger.info("setSecret: role %s ready with DML-only grants.", DB_USERNAME)
    finally:
        conn.close()


def test_secret(arn, token):
    pending = _get_secret_value(arn, "AWSPENDING", token)
    new_password = _password_from_connection_string(pending)

    # Retried rather than attempted once, as defence in depth for a liveness probe against a
    # distributed service. Secrets Manager's own state-machine retry exists as a last resort,
    # not as this function's error handling.
    #
    # Historical note, because the failure modes here were genuinely confusing: an early run
    # failed with "authentication failed" (fixed by the wait in setSecret above — the password
    # simply wasn't applied yet), and a later one with "timeout expired". The timeout was NOT a
    # transient RDS condition as first assumed: the sg-database ingress rule allowing this
    # Lambda in had gone missing from AWS, so the connection had nowhere to land. A missing
    # security group rule times out rather than being refused — worth remembering, since the
    # symptom looks like slowness and not like a permissions problem.
    attempts = 6
    delay = 10
    last_error = None

    for attempt in range(1, attempts + 1):
        try:
            conn = psycopg2.connect(
                host=DB_HOST,
                port=int(DB_PORT),
                dbname=DB_NAME,
                user=DB_USERNAME,
                password=new_password,
                sslmode="require",
                connect_timeout=15,
            )
            try:
                with conn.cursor() as cur:
                    cur.execute("SELECT 1")
                    cur.fetchone()
            finally:
                conn.close()

            logger.info("testSecret: pending credential authenticated successfully (attempt %d).", attempt)
            return

        except psycopg2.OperationalError as exc:
            last_error = exc
            # An authentication failure means the password genuinely doesn't work — retrying
            # won't change that, and failing fast leaves the old credential live (finishSecret
            # never runs), which is the safe outcome.
            if "authentication failed" in str(exc).lower():
                raise
            logger.info("testSecret: attempt %d/%d failed (%s), retrying in %ds", attempt, attempts, exc, delay)
            time.sleep(delay)

    raise RuntimeError(
        f"testSecret: could not connect after {attempts} attempts. Last error: {last_error}. "
        "Not promoting the pending secret - the old password stays live."
    )


def finish_secret(arn, token):
    metadata = secretsmanager.describe_secret(SecretId=arn)
    current_version = None
    for version, stages in metadata["VersionIdsToStages"].items():
        if "AWSCURRENT" in stages:
            if version == token:
                logger.info("finishSecret: %s is already AWSCURRENT, nothing to do.", token)
                return
            current_version = version
            break

    secretsmanager.update_secret_version_stage(
        SecretId=arn,
        VersionStage="AWSCURRENT",
        MoveToVersionId=token,
        RemoveFromVersionId=current_version,
    )
    logger.info("finishSecret: promoted %s to AWSCURRENT.", token)

    # ECS_SERVICE is only set for the master-role Lambda. The app-role Lambda (TARGET_ROLE=app)
    # rotates arkcloud_app's secret, but ArkCloud.API doesn't read that secret yet — the
    # connection string switch (roadmap step 4) hasn't happened, so there's nothing running that
    # would need to pick up a new value, and forcing a deployment would just be a no-op churn.
    if not ECS_SERVICE:
        logger.info("finishSecret: no ECS_SERVICE configured for this role, skipping redeploy.")
        return

    # ECS injects secrets at task start, so running tasks still hold the old password. Same
    # reason the Azure runbook restarts the App Service. force_new_deployment rolls tasks with
    # the service's normal deployment settings rather than killing them outright.
    ecs.update_service(
        cluster=ECS_CLUSTER,
        service=ECS_SERVICE,
        forceNewDeployment=True,
    )
    logger.info("finishSecret: forced a new deployment of %s so tasks pick up the new secret.", ECS_SERVICE)


def lambda_handler(event, context):
    arn = event["SecretId"]
    token = event["ClientRequestToken"]
    step = event["Step"]

    metadata = secretsmanager.describe_secret(SecretId=arn)
    if not metadata.get("RotationEnabled"):
        raise ValueError(f"Secret {arn} is not enabled for rotation")

    versions = metadata["VersionIdsToStages"]
    if token not in versions:
        raise ValueError(f"Secret version {token} has no stage for rotation of secret {arn}")
    if "AWSCURRENT" in versions[token]:
        logger.info("Secret version %s already AWSCURRENT for %s.", token, arn)
        return
    if "AWSPENDING" not in versions[token]:
        raise ValueError(f"Secret version {token} not set as AWSPENDING for rotation of secret {arn}")

    handlers = {
        "createSecret": create_secret,
        "setSecret": set_secret,
        "testSecret": test_secret,
        "finishSecret": finish_secret,
    }
    if step not in handlers:
        raise ValueError(f"Invalid step parameter: {step}")

    handlers[step](arn, token)
