import base64
import json
import unittest

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


class FakeDashboardService:
    def __init__(self):
        self.calls = []
        self.rows = [
            {
                "login_at": "2026-04-12 10:00:00 UTC",
                "display_name": "Alice Smith",
                "email": "alice@example.com",
                "aad_object_id": "00000000-0000-0000-0000-000000000000",
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

    def cursor(self):
        return self._cursor


class FetchRecentLoginsTests(unittest.TestCase):
    def test_fetch_recent_logins_uses_newest_first_query_and_formats_utc(self):
        rows = [
            type(
                "Row",
                (),
                {
                    "aad_object_id": "oid-1",
                    "display_name": "Alice Smith",
                    "email": "alice@example.com",
                    "identity_provider": "aad",
                    "login_at_utc": "2026-04-12 11:30:00 UTC",
                },
            )()
        ]
        cursor = FakeCursor(rows)
        connection = FakeConnection(cursor)

        result = app_module.fetch_recent_logins(connection)

        self.assertEqual(result[0]["login_at"], "2026-04-12 11:30:00 UTC")
        executed_sql = cursor.executed[0][0]
        self.assertIn("ORDER BY login_at DESC", executed_sql)
        self.assertIn("SELECT TOP 50", executed_sql)


class AppRouteTests(unittest.TestCase):
    def setUp(self):
        self.service = FakeDashboardService()
        self.app = app_module.create_app(
            {
                "TESTING": True,
                "SECRET_KEY": "test-secret-key",
                "TRUST_EASY_AUTH_HEADERS": True,
                "DASHBOARD_SERVICE": self.service,
            }
        )
        self.client = self.app.test_client()

    def test_healthz_is_anonymous(self):
        response = self.client.get("/healthz")

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.get_data(as_text=True), "ok")

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
        self.assertEqual(len(self.service.calls), 2)
        self.assertTrue(self.service.calls[0]["should_record_login"])
        self.assertFalse(self.service.calls[1]["should_record_login"])

    def test_dashboard_renders_current_user_summary(self):
        response = self.client.get("/dashboard", headers=principal_headers())
        page = response.get_data(as_text=True)

        self.assertEqual(response.status_code, 200)
        self.assertIn("Alice Smith", page)
        self.assertIn("alice@example.com", page)
        self.assertIn("00000000-0000-0000-0000-000000000000", page)


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

    def test_parse_client_principal_requires_object_id_and_display_name(self):
        header_value = encode_principal([{"typ": "preferred_username", "val": "ada@example.com"}])

        with self.assertRaises(ValueError):
            app_module.parse_client_principal(header_value)


if __name__ == "__main__":
    unittest.main()
