-- Sprint 6 STRIDE remediation ("Elevation of privilege", flow 3): creates a dedicated,
-- least-privilege Postgres role for ArkCloud.API's runtime traffic, instead of the API
-- connecting as the server admin (arkcloudadmin) as it has done since Sprint 4/5.
--
-- Run once per environment/server (both Azure and AWS host their own independent Postgres
-- instance with their own copy of this schema), connected as the admin account -- it needs
-- CREATE ROLE and GRANT, which arkcloud_app itself will never have.
--
-- Usage (psql), :'app_password' is a psql variable, never hardcode the value in this file:
--   psql "host=<host> port=5432 dbname=arkcloud user=arkcloudadmin sslmode=require" \
--        -v app_password='the-real-password' \
--        -f bootstrap-arkcloud-app-role.sql

-- Idempotent: safe to re-run (e.g. against a second environment) without erroring on an
-- already-existing role.
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'arkcloud_app') THEN
        CREATE ROLE arkcloud_app WITH
            LOGIN
            NOSUPERUSER
            NOCREATEDB
            NOCREATEROLE
            NOREPLICATION
            NOBYPASSRLS
            PASSWORD :'app_password';
    ELSE
        ALTER ROLE arkcloud_app WITH PASSWORD :'app_password';
    END IF;
END
$$;

-- Explicit rather than relying on PUBLIC defaults (which vary by Postgres major version --
-- PostgreSQL 15 changed the default public-schema grants for newly created databases).
GRANT CONNECT ON DATABASE arkcloud TO arkcloud_app;
GRANT USAGE ON SCHEMA public TO arkcloud_app;

-- DML only -- no CREATE/DROP/ALTER on tables, no role management, no superuser. Schema changes
-- stay a deliberate, human-triggered `dotnet ef database update` run as arkcloudadmin, never
-- something the running API can do to its own schema.
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO arkcloud_app;

-- No serial/identity columns exist today (every Id is an app-generated uuid), so this is a
-- no-op right now -- kept for whenever a future migration introduces one, so this script
-- doesn't need revisiting at that point.
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO arkcloud_app;

-- Applies only to objects created by the role that runs THIS statement (arkcloudadmin, since
-- that's who this script connects as, and who runs every `dotnet ef database update`) -- so a
-- future migration's new table automatically grants arkcloud_app the same DML rights without
-- anyone having to remember to re-run a GRANT by hand.
ALTER DEFAULT PRIVILEGES FOR ROLE arkcloudadmin IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO arkcloud_app;
ALTER DEFAULT PRIVILEGES FOR ROLE arkcloudadmin IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO arkcloud_app;
