#!/usr/bin/env python3
"""Configure Azure SQL database-level Microsoft Entra access.

This helper is executed by the app-stack Terraform module through local-exec.
It intentionally manages database-level contained users only. It does not
create server-level Microsoft Entra logins or grant server roles.

Required environment variables:
  SQL_SERVER_FQDN
    Fully qualified Azure SQL server name, for example
    sql-app-dev-001.database.windows.net.

  SQL_DATABASE_ACCESS_JSON
    JSON object keyed by a stable Terraform database alias. Each value contains
    the target database name and a map of principals to create/grant:

    {
      "app": {
        "name": "db-app-dev-001",
        "principals": {
          "webapp_managed_identity": {
            "name": "app-app-dev-001",
            "object_id": "00000000-0000-0000-0000-000000000000",
            "use_object_id": true,
            "roles": ["db_datareader", "db_datawriter", "db_ddladmin"]
          }
        }
      }
    }

Optional environment variables:
  MAX_ATTEMPTS
    Number of sqlcmd attempts per database. Defaults to 12.

  RETRY_DELAY_SEC
    Delay between failed sqlcmd attempts. Defaults to 10.

Runtime requirements:
  - python3 from the standard library only.
  - sqlcmd with support for:
      --authentication-method ActiveDirectoryDefault
  - The current Azure CLI or managed identity context must be accepted by
    Azure SQL as the configured Microsoft Entra SQL admin.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import time


UNSUPPORTED_SQLCMD_AUTH_ERRORS = (
    "unknown flag: --authentication-method",
    "flag provided but not defined",
    "unknown shorthand flag",
    "unknown authentication method",
    "unsupported authentication method",
)


def fail(message):
    print(message, file=sys.stderr)
    sys.exit(1)


def require_env(name):
    value = os.environ.get(name)
    if not value:
        fail(f"Missing required environment variable: {name}")
    return value


def log(message):
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {message}", flush=True)


def sql_identifier(value):
    return f"[{value.replace(']', ']]')}]"


def sql_literal(value):
    return f"N'{value.replace(chr(39), chr(39) + chr(39))}'"


def sql_string(value):
    return f"'{value.replace(chr(39), chr(39) + chr(39))}'"


def parse_bool(value, default=True):
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    normalized = str(value).strip().lower()
    if normalized in ("1", "true", "yes", "y"):
        return True
    if normalized in ("0", "false", "no", "n"):
        return False
    fail(f"Invalid boolean value: {value}")


def load_access_config():
    payload = require_env("SQL_DATABASE_ACCESS_JSON")
    try:
        config = json.loads(payload)
    except json.JSONDecodeError as exc:
        fail(f"SQL_DATABASE_ACCESS_JSON is not valid JSON: {exc}")
    return normalize_config(config)


def normalize_config(config):
    """Validate and normalize the JSON payload from Terraform."""
    if not isinstance(config, dict):
        fail("SQL database access config must be a JSON object.")

    normalized = {}
    for database_key, database_config in config.items():
        if not isinstance(database_config, dict):
            fail(f"Database access entry {database_key!r} must be an object.")

        database_name = database_config.get("name")
        if not isinstance(database_name, str) or not database_name.strip():
            fail(f"Database access entry {database_key!r} must include a non-empty name.")

        principals = database_config.get("principals", {})
        if principals is None:
            principals = {}
        if not isinstance(principals, dict):
            fail(f"Database access entry {database_key!r} principals must be an object.")

        normalized_principals = {}
        for principal_key, principal_config in principals.items():
            if not isinstance(principal_config, dict):
                fail(f"Principal {principal_key!r} in database {database_key!r} must be an object.")

            principal_name = principal_config.get("name")
            if not isinstance(principal_name, str) or not principal_name.strip():
                fail(f"Principal {principal_key!r} in database {database_key!r} must include a non-empty name.")

            roles = principal_config.get("roles", [])
            if not isinstance(roles, list):
                fail(f"Principal {principal_key!r} in database {database_key!r} roles must be a list.")
            if any(not isinstance(role, str) or not role.strip() for role in roles):
                fail(f"Principal {principal_key!r} in database {database_key!r} has an invalid role name.")

            use_object_id = parse_bool(principal_config.get("use_object_id"), default=True)
            object_id = principal_config.get("object_id")
            if use_object_id and (not isinstance(object_id, str) or not object_id.strip()):
                fail(f"Principal {principal_key!r} in database {database_key!r} requires object_id when use_object_id is true.")

            normalized_principals[principal_key] = {
                "name": principal_name.strip(),
                "object_id": object_id.strip() if isinstance(object_id, str) else None,
                "use_object_id": use_object_id,
                "roles": [role.strip() for role in roles],
            }

        normalized[database_key] = {
            "name": database_name.strip(),
            "principals": normalized_principals,
        }

    return normalized


def build_sql(database_config):
    """Build idempotent database-scoped SQL for one database."""
    statements = ["SET NOCOUNT ON;", ""]

    for principal in database_config["principals"].values():
        principal_name = principal["name"]
        principal_identifier = sql_identifier(principal_name)
        principal_literal = sql_literal(principal_name)

        if principal["use_object_id"]:
            create_user = (
                f"CREATE USER {principal_identifier} FROM EXTERNAL PROVIDER "
                f"WITH OBJECT_ID = {sql_string(principal['object_id'])};"
            )
        else:
            create_user = f"CREATE USER {principal_identifier} FROM EXTERNAL PROVIDER;"

        statements.extend([
            f"IF DATABASE_PRINCIPAL_ID({principal_literal}) IS NULL",
            "BEGIN",
            f"  {create_user}",
            "END;",
            "",
        ])

        for role in principal["roles"]:
            role_identifier = sql_identifier(role)
            role_literal = sql_literal(role)
            error_message = sql_string(f"Database role {role} does not exist.")

            statements.extend([
                f"IF DATABASE_PRINCIPAL_ID({role_literal}) IS NULL",
                "BEGIN",
                f"  THROW 50001, {error_message}, 1;",
                "END;",
                "",
                "IF NOT EXISTS (",
                "  SELECT 1",
                "  FROM sys.database_role_members AS role_members",
                "  INNER JOIN sys.database_principals AS roles",
                "    ON roles.principal_id = role_members.role_principal_id",
                "  INNER JOIN sys.database_principals AS members",
                "    ON members.principal_id = role_members.member_principal_id",
                f"  WHERE roles.name = {role_literal}",
                f"    AND members.name = {principal_literal}",
                ")",
                "BEGIN",
                f"  ALTER ROLE {role_identifier} ADD MEMBER {principal_identifier};",
                "END;",
                "",
            ])

    return "\n".join(statements)


def run_sqlcmd(sql_server_fqdn, database_name, sql_query, max_attempts, retry_delay):
    """Run sqlcmd with retries to tolerate Azure SQL provisioning latency."""
    attempt = 1

    with tempfile.NamedTemporaryFile("w", suffix=".sql", delete=False) as sql_file:
        sql_file.write(sql_query)
        sql_file_path = sql_file.name

    try:
        while attempt <= max_attempts:
            log(f"Configuring SQL database access for {database_name} on {sql_server_fqdn} (attempt {attempt}/{max_attempts})")

            result = subprocess.run(
                [
                    "sqlcmd",
                    "-S",
                    sql_server_fqdn,
                    "-d",
                    database_name,
                    "--authentication-method",
                    "ActiveDirectoryDefault",
                    "-b",
                    "-i",
                    sql_file_path,
                ],
                check=False,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )

            if result.stdout:
                print(result.stdout, end="")

            if result.returncode == 0:
                log(f"SQL database access is configured for {database_name}.")
                return

            output_lower = result.stdout.lower()
            if any(error.lower() in output_lower for error in UNSUPPORTED_SQLCMD_AUTH_ERRORS):
                fail(
                    "The installed sqlcmd does not support --authentication-method "
                    "ActiveDirectoryDefault. Install a sqlcmd build that supports "
                    "Microsoft Entra Default authentication, or run the SQL manually."
                )

            if attempt == max_attempts:
                break

            log(f"Attempt {attempt} failed. Waiting {retry_delay}s before retrying.")
            time.sleep(retry_delay)
            attempt += 1
    finally:
        try:
            os.unlink(sql_file_path)
        except FileNotFoundError:
            pass

    fail(f"Failed to configure SQL database access for {database_name} after {max_attempts} attempts.")


def parse_args():
    parser = argparse.ArgumentParser(
        description="Configure Azure SQL contained database users and database role memberships.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=textwrap.dedent("""\
            Configuration is supplied through SQL_DATABASE_ACCESS_JSON. Terraform
            generates this payload from the app-stack sql_database_access input
            plus the default web app managed identity principal.
        """),
    )
    return parser.parse_args()


def main():
    parse_args()

    if shutil.which("sqlcmd") is None:
        fail("Required command not found: sqlcmd")

    sql_server_fqdn = require_env("SQL_SERVER_FQDN")
    max_attempts = int(os.environ.get("MAX_ATTEMPTS", "12"))
    retry_delay = int(os.environ.get("RETRY_DELAY_SEC", "10"))
    access_config = load_access_config()

    for database_config in access_config.values():
        if not database_config["principals"]:
            log(f"No SQL database access principals configured for {database_config['name']}.")
            continue
        sql_query = build_sql(database_config)
        run_sqlcmd(sql_server_fqdn, database_config["name"], sql_query, max_attempts, retry_delay)


if __name__ == "__main__":
    main()
