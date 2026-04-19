import base64
import json
import unittest
from unittest import mock

import app as app_module


def encode_principal(claims, auth_typ="aad"):
    payload = {
        "auth_typ": auth_typ,
        "name_typ": "name",
        "role_typ": "roles",
        "claims": claims,
    }
    return base64.b64encode(json.dumps(payload).encode("utf-8")).decode("utf-8")


def principal_headers():
    return {
        "X-MS-CLIENT-PRINCIPAL": encode_principal(
            [
                {"typ": "name", "val": "Alice Smith"},
                {"typ": "preferred_username", "val": "alice@example.com"},
                {
                    "typ": "http://schemas.microsoft.com/identity/claims/objectidentifier",
                    "val": "00000000-0000-0000-0000-000000000000",
                },
            ]
        )
    }


def daemon_principal_headers(roles=None, appid="daemon-client-id", object_id="daemon-object-id"):
    claims = [
        {"typ": "appid", "val": appid},
        {"typ": "oid", "val": object_id},
        {"typ": "sub", "val": object_id},
    ]

    for role in roles or []:
        claims.append({"typ": "roles", "val": role})

    return {
        "X-MS-CLIENT-PRINCIPAL": encode_principal(claims),
        "X-MS-CLIENT-PRINCIPAL-NAME": "Login Events Daemon",
    }


def daemon_principal_without_matching_sub_headers(
    roles=None,
    appid="daemon-client-id",
    object_id="daemon-object-id",
    subject="different-subject",
):
    claims = [
        {"typ": "appid", "val": appid},
        {"typ": "oid", "val": object_id},
        {"typ": "sub", "val": subject},
    ]

    for role in roles or []:
        claims.append({"typ": "roles", "val": role})

    return {
        "X-MS-CLIENT-PRINCIPAL": encode_principal(claims),
        "X-MS-CLIENT-PRINCIPAL-NAME": "Login Events Daemon",
    }


class FakeDashboardService:
    def __init__(self):
        self.calls = []
        self.rows = [
            {
                "login_at": "2026-04-12 10:00:00 UTC",
                "principal_type": "user",
                "display_name": "Alice Smith",
                "email": "alice@example.com",
                "client_app_id": None,
                "aad_object_id": "00000000-0000-0000-0000-000000000000",
                "identity_provider": "aad",
            },
            {
                "login_at": "2026-04-12 10:05:00 UTC",
                "principal_type": "application",
                "display_name": "Login Events Daemon",
                "email": None,
                "client_app_id": "daemon-client-id",
                "aad_object_id": "daemon-object-id",
                "identity_provider": "aad",
            }
        ]

    def __call__(self, user, should_record_login):
        self.calls.append(
            {
                "user": user,
                "should_record_login": should_record_login,
            }
        )
        return list(self.rows)


class FakeLoginEventsService:
    def __init__(self):
        self.calls = []
        self.rows = [
            {
                "login_at": "2026-04-12 10:00:00 UTC",
                "principal_type": "user",
                "display_name": "Alice Smith",
                "email": "alice@example.com",
                "client_app_id": None,
                "aad_object_id": "00000000-0000-0000-0000-000000000000",
                "identity_provider": "aad",
            },
            {
                "login_at": "2026-04-12 10:05:00 UTC",
                "principal_type": "application",
                "display_name": "Login Events Daemon",
                "email": None,
                "client_app_id": "daemon-client-id",
                "aad_object_id": "daemon-object-id",
                "identity_provider": "aad",
            }
        ]

    def __call__(self, user):
        self.calls.append({"user": user})
        return list(self.rows)


class FakeHealthCheckService:
    def __init__(self, is_healthy=True):
        self.calls = 0
        self.is_healthy = is_healthy

    def __call__(self):
        self.calls += 1
        return self.is_healthy


class FakeCursor:
    def __init__(self, rows):
        self.rows = rows
        self.executed = []

    def execute(self, sql, *params):
        self.executed.append((sql, params))

    def fetchall(self):
        return self.rows

    def close(self):
        return None


class FakeConnection:
    def __init__(self, cursor):
        self._cursor = cursor
        self.committed = False
        self.closed = False

    def cursor(self):
        return self._cursor

    def commit(self):
        self.committed = True

    def close(self):
        self.closed = True


class FetchRecentLoginsTests(unittest.TestCase):
    def test_fetch_recent_logins_uses_newest_first_query_and_formats_utc(self):
        rows = [
            type(
                "Row",
                (),
                {
                    "aad_object_id": "oid-1",
                    "principal_type": "application",
                    "display_name": "Alice Smith",
                    "email": "alice@example.com",
                    "client_app_id": "daemon-client-id",
                    "identity_provider": "aad",
                    "login_at_utc": "2026-04-12 11:30:00 UTC",
                },
            )()
        ]
        cursor = FakeCursor(rows)
        connection = FakeConnection(cursor)

        result = app_module.fetch_recent_logins(connection)

        self.assertEqual(result[0]["login_at"], "2026-04-12 11:30:00 UTC")
        self.assertEqual(result[0]["principal_type"], "application")
        self.assertEqual(result[0]["client_app_id"], "daemon-client-id")
        executed_sql = cursor.executed[0][0]
        self.assertIn("ORDER BY login_at DESC", executed_sql)
        self.assertIn("SELECT TOP 50", executed_sql)


class LoadLoginEventsTests(unittest.TestCase):
    def test_load_login_events_records_application_accesses(self):
        rows = []
        cursor = FakeCursor(rows)
        connection = FakeConnection(cursor)
        principal = {
            "principal_type": "application",
            "aad_object_id": "daemon-object-id",
            "display_name": "Login Events Daemon",
            "email": None,
            "client_app_id": "daemon-client-id",
            "identity_provider": "aad",
        }

        with mock.patch.object(app_module, "open_sql_connection", return_value=connection):
            app_module.load_login_events(principal)

        executed_sql = "\n".join(sql for sql, _params in cursor.executed)
        self.assertIn("INSERT INTO dbo.user_logins", executed_sql)
        self.assertTrue(connection.committed)

    def test_load_login_events_does_not_record_user_api_reads(self):
        rows = []
        cursor = FakeCursor(rows)
        connection = FakeConnection(cursor)
        principal = {
            "principal_type": "user",
            "aad_object_id": "user-object-id",
            "display_name": "Alice Smith",
            "email": "alice@example.com",
            "client_app_id": None,
            "identity_provider": "aad",
        }

        with mock.patch.object(app_module, "open_sql_connection", return_value=connection):
            app_module.load_login_events(principal)

        executed_sql = "\n".join(sql for sql, _params in cursor.executed)
        self.assertNotIn("INSERT INTO dbo.user_logins", executed_sql)
        self.assertTrue(connection.committed)


class HealthCheckTests(unittest.TestCase):
    def test_check_database_health_runs_a_lightweight_query(self):
        cursor = FakeCursor([])
        connection = FakeConnection(cursor)

        with app_module.create_app({"TESTING": True}).app_context():
            with mock.patch.object(app_module, "open_sql_connection", return_value=connection):
                is_healthy = app_module.check_database_health()

        self.assertTrue(is_healthy)
        self.assertEqual(cursor.executed, [("SELECT 1", ())])
        self.assertTrue(connection.closed)

    def test_check_database_health_returns_false_when_connection_fails(self):
        with app_module.create_app({"TESTING": True}).app_context():
            with mock.patch.object(app_module, "open_sql_connection", side_effect=RuntimeError("boom")):
                is_healthy = app_module.check_database_health()

        self.assertFalse(is_healthy)


class AppRouteTests(unittest.TestCase):
    def setUp(self):
        self.dashboard_service = FakeDashboardService()
        self.login_events_service = FakeLoginEventsService()
        self.health_check_service = FakeHealthCheckService()
        self.app = app_module.create_app(
            {
                "TESTING": True,
                "SECRET_KEY": "test-secret-key",
                "TRUST_EASY_AUTH_HEADERS": True,
                "HEALTH_CHECK_SERVICE": self.health_check_service,
                "DASHBOARD_SERVICE": self.dashboard_service,
                "LOGIN_EVENTS_SERVICE": self.login_events_service,
            }
        )
        self.client = self.app.test_client()

    def test_healthz_is_anonymous(self):
        response = self.client.get("/healthz")

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.get_data(as_text=True), "ok")
        self.assertEqual(self.health_check_service.calls, 1)

    def test_healthz_returns_503_when_database_is_unavailable(self):
        self.health_check_service.is_healthy = False

        response = self.client.get("/healthz")

        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.get_data(as_text=True), "database unavailable")

    def test_dashboard_redirects_to_easy_auth_when_anonymous(self):
        response = self.client.get("/dashboard")

        self.assertEqual(response.status_code, 302)
        self.assertEqual(response.headers["Location"], "/.auth/login/aad")

    def test_dashboard_returns_json_401_when_json_is_preferred(self):
        response = self.client.get(
            "/dashboard",
            headers={"Accept": "application/json"},
        )

        self.assertEqual(response.status_code, 401)
        self.assertEqual(response.get_json()["error"], "authentication_required")

    def test_dashboard_inserts_only_once_per_browser_session(self):
        headers = principal_headers()

        first_response = self.client.get("/dashboard", headers=headers)
        second_response = self.client.get("/dashboard", headers=headers)

        self.assertEqual(first_response.status_code, 200)
        self.assertEqual(second_response.status_code, 200)
        self.assertEqual(len(self.dashboard_service.calls), 2)
        self.assertTrue(self.dashboard_service.calls[0]["should_record_login"])
        self.assertFalse(self.dashboard_service.calls[1]["should_record_login"])

    def test_dashboard_renders_current_user_summary(self):
        mock_datetime = mock.Mock()
        mock_datetime.now.return_value.strftime.return_value = "2026-04-19 09:15:00 UTC"

        with mock.patch.object(app_module, "datetime", mock_datetime):
            response = self.client.get("/dashboard", headers=principal_headers())

        page = response.get_data(as_text=True)

        self.assertEqual(response.status_code, 200)
        self.assertIn("Alice Smith", page)
        self.assertIn("alice@example.com", page)
        self.assertIn("00000000-0000-0000-0000-000000000000", page)
        self.assertIn("application", page)
        self.assertIn("daemon-client-id", page)
        self.assertIn('href="/api/logins"', page)
        self.assertIn("Page loaded at 2026-04-19 09:15:00 UTC", page)

    def test_dashboard_rejects_application_principals(self):
        response = self.client.get(
            "/dashboard",
            headers=daemon_principal_headers(roles=["read_login_events"]),
        )

        self.assertEqual(response.status_code, 403)
        self.assertEqual(response.get_data(as_text=True), "Forbidden")

    def test_api_logins_returns_json_events_for_authenticated_user(self):
        response = self.client.get("/api/logins", headers=principal_headers())

        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            response.get_json(),
            {
                "login_events": [
                    {
                        "login_at": "2026-04-12 10:00:00 UTC",
                        "principal_type": "user",
                        "display_name": "Alice Smith",
                        "email": "alice@example.com",
                        "client_app_id": None,
                        "aad_object_id": "00000000-0000-0000-0000-000000000000",
                        "identity_provider": "aad",
                    },
                    {
                        "login_at": "2026-04-12 10:05:00 UTC",
                        "principal_type": "application",
                        "display_name": "Login Events Daemon",
                        "email": None,
                        "client_app_id": "daemon-client-id",
                        "aad_object_id": "daemon-object-id",
                        "identity_provider": "aad",
                    }
                ]
            },
        )
        self.assertEqual(len(self.login_events_service.calls), 1)
        self.assertEqual(len(self.dashboard_service.calls), 0)

    def test_api_logins_returns_json_events_for_authorized_daemon(self):
        response = self.client.get(
            "/api/logins",
            headers=daemon_principal_headers(roles=["read_login_events"]),
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.get_json()["login_events"][1]["principal_type"], "application")
        self.assertEqual(response.get_json()["login_events"][1]["client_app_id"], "daemon-client-id")
        self.assertEqual(len(self.login_events_service.calls), 1)

    def test_api_logins_accepts_daemon_without_matching_sub_when_no_user_claims_exist(self):
        response = self.client.get(
            "/api/logins",
            headers=daemon_principal_without_matching_sub_headers(roles=["read_login_events"]),
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(self.login_events_service.calls[0]["user"]["principal_type"], "application")

    def test_api_logins_rejects_daemon_without_required_role(self):
        response = self.client.get(
            "/api/logins",
            headers=daemon_principal_headers(roles=["other_role"]),
        )

        self.assertEqual(response.status_code, 403)
        self.assertEqual(response.get_json()["error"], "insufficient_role")

    def test_api_logins_returns_json_401_when_anonymous(self):
        response = self.client.get("/api/logins")

        self.assertEqual(response.status_code, 401)
        self.assertEqual(response.get_json()["error"], "authentication_required")


class PrincipalParsingTests(unittest.TestCase):
    def test_parse_client_principal_uses_claim_precedence(self):
        header_value = encode_principal(
            [
                {"typ": "name", "val": "Ada Lovelace"},
                {"typ": "email", "val": "ignored@example.com"},
                {"typ": "preferred_username", "val": "ada@example.com"},
                {"typ": "oid", "val": "fallback-oid"},
            ]
        )

        principal = app_module.parse_client_principal(header_value)

        self.assertEqual(principal["display_name"], "Ada Lovelace")
        self.assertEqual(principal["email"], "ada@example.com")
        self.assertEqual(principal["aad_object_id"], "fallback-oid")
        self.assertEqual(principal["principal_type"], "user")

    def test_parse_client_principal_requires_object_id_and_display_name(self):
        header_value = encode_principal([{"typ": "preferred_username", "val": "ada@example.com"}])

        with self.assertRaises(ValueError):
            app_module.parse_client_principal(header_value)

    def test_parse_client_principal_supports_application_principals(self):
        principal = app_module.parse_client_principal(
            daemon_principal_headers(roles=["read_login_events"])["X-MS-CLIENT-PRINCIPAL"],
            {"X-MS-CLIENT-PRINCIPAL-NAME": "Login Events Daemon"},
        )

        self.assertEqual(principal["principal_type"], "application")
        self.assertEqual(principal["client_app_id"], "daemon-client-id")
        self.assertEqual(principal["aad_object_id"], "daemon-object-id")
        self.assertEqual(principal["display_name"], "Login Events Daemon")
        self.assertEqual(principal["roles"], ["read_login_events"])

    def test_parse_client_principal_treats_appid_without_user_claims_as_application(self):
        principal = app_module.parse_client_principal(
            daemon_principal_without_matching_sub_headers(roles=["read_login_events"])[
                "X-MS-CLIENT-PRINCIPAL"
            ],
            {"X-MS-CLIENT-PRINCIPAL-NAME": "Login Events Daemon"},
        )

        self.assertEqual(principal["principal_type"], "application")


if __name__ == "__main__":
    unittest.main()
