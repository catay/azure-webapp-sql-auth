import base64
import binascii
import json
import logging
import os
import struct
from contextlib import closing
from datetime import UTC, datetime
from functools import lru_cache
from time import sleep

from flask import Flask, Response, current_app, g, redirect, render_template, request, session


SQL_COPT_SS_ACCESS_TOKEN = 1256
USER_SESSION_FLAG = "login_recorded"
SQL_SCOPE = "https://database.windows.net/.default"
MAX_RECENT_LOGINS = 50
SQL_CONNECT_TIMEOUT_SECONDS = 30
SQL_CONNECT_RETRIES = 2
SQL_CONNECT_RETRY_DELAY_SECONDS = 10
SCHEMA_SQL = """
IF NOT EXISTS (
    SELECT 1
    FROM sys.tables
    WHERE name = 'user_logins'
)
BEGIN
    CREATE TABLE dbo.user_logins (
        id INT IDENTITY(1,1) PRIMARY KEY,
        aad_object_id NVARCHAR(64) NOT NULL,
        display_name NVARCHAR(256) NOT NULL,
        email NVARCHAR(256) NULL,
        identity_provider NVARCHAR(64) NOT NULL,
        login_at DATETIMEOFFSET NOT NULL
            CONSTRAINT DF_user_logins_login_at DEFAULT SYSDATETIMEOFFSET()
    );

    CREATE INDEX IX_user_logins_login_at
        ON dbo.user_logins (login_at DESC);

    CREATE INDEX IX_user_logins_aad_object_id
        ON dbo.user_logins (aad_object_id);
END
"""


def create_app(test_config=None):
    app = Flask(__name__)
    app.config.update(
        SECRET_KEY=_load_secret_key(),
        SQL_SERVER_NAME=os.environ.get("SQL_SERVER_NAME", "").strip(),
        SQL_DATABASE_NAME=os.environ.get("SQL_DATABASE_NAME", "").strip(),
        TRUST_EASY_AUTH_HEADERS=_is_running_on_app_service(),
        DASHBOARD_SERVICE=load_dashboard_data,
    )

    if test_config:
        app.config.update(test_config)

    _configure_logging(app)

    @app.before_request
    def require_authentication():
        if request.endpoint in {"healthz", "index", "static"}:
            return None

        user = get_authenticated_user()
        if user is None:
            return _unauthenticated_response()

        g.current_user = user
        return None

    @app.get("/")
    def index():
        return redirect("/dashboard")

    @app.get("/dashboard")
    def dashboard():
        user = g.current_user
        should_record_login = not session.get(USER_SESSION_FLAG, False)

        try:
            rows = current_app.config["DASHBOARD_SERVICE"](user, should_record_login)
        except Exception:
            current_app.logger.exception("Failed to load dashboard data.")
            return _server_error_response()

        if should_record_login:
            session[USER_SESSION_FLAG] = True

        return render_template(
            "dashboard.html",
            page_title="Azure SQL Login Dashboard",
            current_user=user,
            login_rows=rows,
        )

    @app.get("/healthz")
    def healthz():
        return Response("ok", mimetype="text/plain")

    return app


def _configure_logging(app):
    if not app.logger.handlers:
        logging.basicConfig(level=logging.INFO)
    app.logger.setLevel(logging.INFO)


def _load_secret_key():
    secret_key = os.environ.get("FLASK_SECRET_KEY")
    if secret_key:
        return secret_key

    if _is_running_on_app_service():
        raise RuntimeError("FLASK_SECRET_KEY must be set when running on Azure App Service.")

    return "dev-secret-key-not-for-production"


def _is_running_on_app_service():
    return any(
        os.environ.get(variable)
        for variable in ("WEBSITE_HOSTNAME", "WEBSITE_SITE_NAME", "WEBSITE_INSTANCE_ID")
    )


def get_authenticated_user():
    if not current_app.config.get("TRUST_EASY_AUTH_HEADERS", False):
        current_app.logger.warning("Easy Auth headers are not trusted outside Azure App Service.")
        return None

    principal_header = request.headers.get("X-MS-CLIENT-PRINCIPAL")
    if not principal_header:
        return None

    try:
        return parse_client_principal(principal_header, request.headers)
    except (ValueError, binascii.Error, json.JSONDecodeError, UnicodeDecodeError) as exc:
        current_app.logger.warning("Unable to parse Easy Auth principal: %s", exc)
        return None


def parse_client_principal(principal_header, headers=None):
    headers = headers or {}
    principal_bytes = base64.b64decode(_pad_base64(principal_header))
    principal = json.loads(principal_bytes.decode("utf-8"))

    claims = {}
    for claim in principal.get("claims", []):
        claim_type = claim.get("typ")
        claim_value = claim.get("val")
        if claim_type and claim_value is not None and claim_type not in claims:
            claims[claim_type] = claim_value

    object_id = _first_non_empty(
        claims.get("http://schemas.microsoft.com/identity/claims/objectidentifier"),
        claims.get("oid"),
    )
    display_name = _first_non_empty(claims.get("name"))
    email = _first_non_empty(
        claims.get("preferred_username"),
        claims.get("email"),
        claims.get("upn"),
    )
    identity_provider = _first_non_empty(
        principal.get("auth_typ"),
        headers.get("X-MS-CLIENT-PRINCIPAL-IDP"),
        "aad",
    )

    if not object_id or not display_name:
        raise ValueError("Authenticated principal is missing required claims.")

    return {
        "aad_object_id": object_id,
        "display_name": display_name,
        "email": email,
        "identity_provider": identity_provider,
    }


def _first_non_empty(*values):
    for value in values:
        if value:
            return value
    return None


def _pad_base64(value):
    padding = (-len(value)) % 4
    return value + ("=" * padding)


def load_dashboard_data(user, should_record_login):
    with closing(open_sql_connection()) as connection:
        ensure_schema(connection)

        if should_record_login:
            insert_login_event(connection, user)

        rows = fetch_recent_logins(connection)
        connection.commit()
        return rows


def ensure_schema(connection):
    try:
        with closing(connection.cursor()) as cursor:
            cursor.execute(SCHEMA_SQL)
    except Exception:
        current_app.logger.exception("Failed to create or validate schema.")
        raise


def insert_login_event(connection, user):
    try:
        with closing(connection.cursor()) as cursor:
            cursor.execute(
                """
                INSERT INTO dbo.user_logins (
                    aad_object_id,
                    display_name,
                    email,
                    identity_provider
                )
                VALUES (?, ?, ?, ?)
                """,
                user["aad_object_id"],
                user["display_name"],
                user["email"],
                user["identity_provider"],
            )
    except Exception:
        current_app.logger.exception("Failed to insert login audit row.")
        raise


def fetch_recent_logins(connection):
    try:
        with closing(connection.cursor()) as cursor:
            cursor.execute(
                f"""
                SELECT TOP {MAX_RECENT_LOGINS}
                    aad_object_id,
                    display_name,
                    email,
                    identity_provider,
                    CONVERT(
                        VARCHAR(19),
                        CAST(SWITCHOFFSET(login_at, '+00:00') AS datetime2),
                        120
                    ) + ' UTC' AS login_at_utc
                FROM dbo.user_logins
                ORDER BY login_at DESC
                """
            )

            return [
                {
                    "aad_object_id": row.aad_object_id,
                    "display_name": row.display_name,
                    "email": row.email,
                    "identity_provider": row.identity_provider,
                    "login_at": row.login_at_utc,
                }
                for row in cursor.fetchall()
            ]
    except Exception:
        current_app.logger.exception("Failed to query recent logins.")
        raise


def _format_utc_timestamp(value):
    if value is None:
        return ""

    if isinstance(value, datetime):
        timestamp = value if value.tzinfo else value.replace(tzinfo=UTC)
        return timestamp.astimezone(UTC).strftime("%Y-%m-%d %H:%M:%S UTC")

    return str(value)


def open_sql_connection():
    server_name = current_app.config["SQL_SERVER_NAME"]
    database_name = current_app.config["SQL_DATABASE_NAME"]

    if not server_name or not database_name:
        raise RuntimeError("SQL_SERVER_NAME and SQL_DATABASE_NAME must be configured.")

    access_token = _get_sql_access_token()
    token_bytes = access_token.encode("utf-16-le")
    packed_token = struct.pack(f"<I{len(token_bytes)}s", len(token_bytes), token_bytes)

    connection_string = (
        "Driver={ODBC Driver 18 for SQL Server};"
        f"Server={server_name};"
        f"Database={database_name};"
        "Encrypt=yes;"
        "TrustServerCertificate=no;"
    )

    try:
        import pyodbc
    except ImportError as exc:
        raise RuntimeError("pyodbc is required to connect to Azure SQL.") from exc

    last_error = None
    for attempt in range(1, SQL_CONNECT_RETRIES + 1):
        try:
            return pyodbc.connect(
                connection_string,
                attrs_before={SQL_COPT_SS_ACCESS_TOKEN: packed_token},
                timeout=SQL_CONNECT_TIMEOUT_SECONDS,
            )
        except pyodbc.OperationalError as exc:
            last_error = exc
            sql_state = exc.args[0] if exc.args else ""
            if sql_state == "HYT00" and attempt < SQL_CONNECT_RETRIES:
                current_app.logger.warning(
                    "Azure SQL connection attempt %s timed out; retrying in %s seconds. "
                    "Serverless databases can need extra time to resume from auto-pause.",
                    attempt,
                    SQL_CONNECT_RETRY_DELAY_SECONDS,
                )
                sleep(SQL_CONNECT_RETRY_DELAY_SECONDS)
                continue
            current_app.logger.exception("Failed to connect to Azure SQL.")
            raise
        except Exception:
            current_app.logger.exception("Failed to connect to Azure SQL.")
            raise

    if last_error is not None:
        raise last_error
    raise RuntimeError("Failed to connect to Azure SQL.")


@lru_cache(maxsize=1)
def _credential():
    try:
        from azure.identity import DefaultAzureCredential
    except ImportError as exc:
        raise RuntimeError("azure-identity is required to obtain managed identity tokens.") from exc

    return DefaultAzureCredential(exclude_interactive_browser_credential=True)


def _get_sql_access_token():
    try:
        return _credential().get_token(SQL_SCOPE).token
    except Exception:
        current_app.logger.exception("Failed to obtain managed identity token for Azure SQL.")
        raise


def _unauthenticated_response():
    if _prefers_json():
        return Response(
            json.dumps({"error": "authentication_required"}),
            mimetype="application/json",
            status=401,
        )

    return redirect("/.auth/login/aad")


def _prefers_json():
    best = request.accept_mimetypes.best_match(["application/json", "text/html"])
    if request.path.startswith("/api/"):
        return True
    return best == "application/json" and (
        request.accept_mimetypes["application/json"] >= request.accept_mimetypes["text/html"]
    )


def _server_error_response():
    return Response(
        "The application could not load the dashboard right now.",
        mimetype="text/plain",
        status=500,
    )


app = create_app()


if __name__ == "__main__":
    port = int(os.environ.get("PORT") or os.environ.get("WEBSITES_PORT") or "8000")
    app.run(host="0.0.0.0", port=port)
