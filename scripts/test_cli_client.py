import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest import mock


CLIENT_PATH = Path(__file__).with_name("sprucegoose-client.py")
SPEC = importlib.util.spec_from_file_location("sprucegoose_client", CLIENT_PATH)
CLIENT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CLIENT)


class ClientTest(unittest.TestCase):
    def assert_failure(self, callback, message):
        output = io.StringIO()
        with contextlib.redirect_stderr(output), self.assertRaises(SystemExit) as raised:
            callback()
        self.assertEqual(raised.exception.code, 2)
        response = json.loads(output.getvalue())
        self.assertIs(response["ok"], False)
        self.assertIn(message, response["error"])

    def reply(self, payload, status="200 OK"):
        response = f"HTTP/1.1 {status}\r\nConnection: close\r\n\r\n".encode() + payload
        connection = mock.Mock()
        connection.recv.side_effect = [response, b""]
        return connection

    def test_valid_success_and_refusal_envelopes_are_preserved(self):
        for status, body in [
            ("200 OK", {"ok": True, "version": "test"}),
            ("422 Unprocessable Entity", {"ok": False, "error": "refused"}),
        ]:
            with self.subTest(status=status):
                connection = self.reply(json.dumps(body).encode(), status)
                with mock.patch.object(CLIENT.socket, "socket", return_value=connection):
                    self.assertEqual(CLIENT.send(["version"], 1, "/unused"), body)
                connection.close.assert_called_once()

    def test_invalid_envelopes_and_encoding_fail_with_json(self):
        for payload in [b"[]", b"null", b"true", b"{}", b'{"ok":"yes"}', b"\xff", b"{"]:
            with self.subTest(payload=payload):
                connection = self.reply(payload)
                with mock.patch.object(CLIENT.socket, "socket", return_value=connection):
                    self.assert_failure(
                        lambda: CLIENT.send(["version"], 1, "/unused"),
                        "invalid service response",
                    )

    def test_http_error_cannot_claim_success(self):
        connection = self.reply(b'{"ok":true}', "503 Service Unavailable")
        with mock.patch.object(CLIENT.socket, "socket", return_value=connection):
            self.assert_failure(
                lambda: CLIENT.send(["version"], 1, "/unused"), "invalid service response"
            )

    def test_response_cap_closes_socket(self):
        connection = self.reply(b'{"ok":true}')
        with mock.patch.object(CLIENT.socket, "socket", return_value=connection):
            self.assertEqual(
                CLIENT.send(["version"], 1, "/unused", max_bytes=8),
                {"ok": False, "error": "response too large"},
            )
        connection.close.assert_called_once()

    def test_slow_response_has_a_total_round_trip_deadline(self):
        connection = mock.Mock()
        connection.recv.side_effect = [b"HTTP/1.1 200 OK\r\n\r\n", b'{"ok":true}', b""]
        with (
            mock.patch.object(CLIENT.socket, "socket", return_value=connection),
            mock.patch("time.monotonic", side_effect=[0, 0, 0.2, 0.6, 1.1, 1.2, 1.3]),
        ):
            self.assert_failure(
                lambda: CLIENT.send(["version"], 1, "/unused"), "timed out"
            )
        connection.close.assert_called_once()

    def test_invalid_timeout_configuration_fails_before_connecting(self):
        for value in ["", "bad", "0", "-1", "nan", "inf", "1e999"]:
            with self.subTest(value=value):
                environment = dict(os.environ)
                environment["SPRUCE_GOOSE_CLI_CLIENT_TIMEOUT_SECONDS"] = value
                environment["SPRUCE_GOOSE_CLI_SOCKET"] = "/nonexistent/sg-test.sock"
                result = subprocess.run(
                    [sys.executable, "-B", str(CLIENT_PATH), "version"],
                    env=environment, capture_output=True, text=True, timeout=5,
                )
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, "")
                self.assertIn("SPRUCE_GOOSE_CLI_CLIENT_TIMEOUT_SECONDS", json.loads(result.stderr)["error"])

    def test_invalid_page_configuration_fails_before_connecting(self):
        for value in ["", "bad", "0", "-1", "100001"]:
            with self.subTest(value=value):
                environment = dict(os.environ)
                environment["SPRUCE_GOOSE_CLI_PAGE_SIZE"] = value
                environment["SPRUCE_GOOSE_CLI_SOCKET"] = "/nonexistent/sg-test.sock"
                result = subprocess.run(
                    [sys.executable, "-B", str(CLIENT_PATH), "task", "list"],
                    env=environment, capture_output=True, text=True, timeout=5,
                )
                self.assertEqual(result.returncode, 2)
                self.assertIn("SPRUCE_GOOSE_CLI_PAGE_SIZE", json.loads(result.stderr)["error"])

    def test_format_parser_does_not_treat_option_values_as_options(self):
        args = ["task", "list", "--text", "--state", "--format", "table"]
        self.assertEqual(CLIENT.extract_format(args), ("table", args[:4]))
        args = ["task", "list", "--text", "--format", "--format=plain"]
        self.assertEqual(CLIENT.extract_format(args), ("plain", args[:4]))

    def test_global_actor_position_does_not_disable_pagination(self):
        for args in [
            ["--as", "codex", "task", "list"],
            ["--as=codex", "task", "list"],
            ["task", "--as", "codex", "list"],
            ["task", "list", "--as", "codex"],
            ["task", "list", "--text", "--limit"],
        ]:
            with self.subTest(args=args):
                self.assertTrue(CLIENT.wants_auto_pagination(args))
        self.assertFalse(CLIENT.wants_auto_pagination(["task", "list", "--limit", "1"]))
        self.assertFalse(CLIENT.wants_auto_pagination(["task", "list", "--offset=1"]))

    def test_global_actor_position_does_not_skip_sop_preflight(self):
        with mock.patch("builtins.open", side_effect=OSError("fixture missing")):
            self.assert_failure(
                lambda: CLIENT.sop_preflight(["--as", "codex", "task", "start", "tsk-test"]),
                "cannot verify Mama Systemwide SOP parity",
            )

    def test_pagination_preserves_order_and_retries_oversized_pages(self):
        pages = [
            {"ok": False, "error": "response too large"},
            {"ok": True, "tasks": [{"id": "first"}], "total": 2},
            {"ok": True, "tasks": [{"id": "second"}], "total": 2},
        ]
        with (
            mock.patch.dict(os.environ, {"SPRUCE_GOOSE_CLI_PAGE_SIZE": "4"}),
            mock.patch.object(CLIENT, "send", side_effect=pages) as send,
        ):
            result = CLIENT.paginated_task_list(["task", "list", "--as", "codex"], 1, "/unused")
        self.assertEqual(result["tasks"], [{"id": "first"}, {"id": "second"}])
        self.assertEqual(result["count"], 2)
        self.assertIsNone(result["limit"])
        self.assertEqual([call.args[0][-4:] for call in send.call_args_list], [
            ["--limit", "4", "--offset", "0"],
            ["--limit", "1", "--offset", "0"],
            ["--limit", "1", "--offset", "1"],
        ])

    def test_malformed_task_page_cannot_claim_success(self):
        for page in [{"ok": True}, {"ok": True, "tasks": None}, {"ok": True, "tasks": [1]}]:
            with self.subTest(page=page), mock.patch.object(CLIENT, "send", return_value=page):
                self.assertEqual(
                    CLIENT.paginated_task_list(["task", "list"], 1, "/unused"),
                    {"ok": False, "error": "invalid service response"},
                )


if __name__ == "__main__":
    unittest.main()
