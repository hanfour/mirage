#!/usr/bin/env python3
"""mirage_ctl.py 的 Unix socket 傳輸與命令列自我測試，不需要 Mirage 或模擬器。"""
import json
from pathlib import Path
import socket
import contextlib
import io
import sys
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mirage_ctl  # noqa: E402


class FakeServer:
    def __init__(self, responses):
        self.responses = list(responses)
        self.requests = []
        self.errors = []
        self.client, self.server = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
        self.thread = threading.Thread(target=self.run, daemon=True)

    def start(self):
        self.thread.start()

    def join(self):
        self.thread.join(timeout=5)
        if self.thread.is_alive():
            raise AssertionError("假的 socket server 沒有結束")
        if self.errors:
            raise self.errors[0]

    def run(self):
        try:
            with self.server, self.server.makefile("rb") as reader:
                for response in self.responses:
                    line = reader.readline()
                    if not line:
                        raise AssertionError("用戶端在送完命令前關閉連線")
                    self.requests.append(json.loads(line.decode("utf-8")))
                    self.server.sendall((json.dumps(response, ensure_ascii=False) + "\n").encode("utf-8"))
        except BaseException as error:
            self.errors.append(error)


class FakeConnection:
    def __init__(self, connection):
        self.connection = connection

    def settimeout(self, _timeout):
        pass

    def connect(self, _path):
        pass

    def sendall(self, data):
        self.connection.sendall(data)

    def recv(self, size):
        return self.connection.recv(size)

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.connection.close()


class MirageControlClientTests(unittest.TestCase):
    def test_encodes_utf8_and_handles_multiple_replies_on_one_connection(self):
        server = FakeServer([{"ok": True, "name": "鏡像"}, {"ok": True, "windowNumber": 12}])
        server.start()
        client = mirage_ctl.MirageControlClient(server.client)
        first = client.request({"cmd": "state"})
        second = client.request({"cmd": "mouse", "action": "click", "x": 0.5, "y": 0.6,
                                 "unit": "norm", "label": "鏡像"})
        server.client.close()
        server.join()
        self.assertEqual(first, {"ok": True, "name": "鏡像"})
        self.assertEqual(second, {"ok": True, "windowNumber": 12})
        self.assertEqual(server.requests, [
            {"cmd": "state"},
            {"cmd": "mouse", "action": "click", "x": 0.5, "y": 0.6,
             "unit": "norm", "label": "鏡像"},
        ])

    def test_scroll_cli_sends_expected_fields_and_prints_json_reply(self):
        server = FakeServer([{"ok": True, "queued": True}])
        server.start()
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(mirage_ctl.socket, "socket", return_value=FakeConnection(server.client)), \
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = mirage_ctl.main(["/fake/control.sock", "scroll", "--x", "0.5", "--y", "0.6",
                                      "--dy", "-10", "--steps", "25", "--unit", "norm",
                                      "--interval-ms", "12", "--momentum", "3"])
        server.join()
        self.assertEqual(result, 0, stderr.getvalue())
        self.assertEqual(json.loads(stdout.getvalue()), {"ok": True, "queued": True})
        self.assertEqual(server.requests, [{
            "cmd": "scroll", "x": 0.5, "y": 0.6, "dx": 0, "dy": -10.0,
            "steps": 25, "interval_ms": 12, "unit": "norm", "momentum": 3,
        }])

    def test_ok_false_exits_nonzero_and_prints_server_error(self):
        server = FakeServer([{"ok": False, "error": "未知的 cmd：bad"}])
        server.start()
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(mirage_ctl.socket, "socket", return_value=FakeConnection(server.client)), \
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = mirage_ctl.main(["/fake/control.sock", "state"])
        server.join()
        self.assertEqual(result, 1)
        self.assertIn("未知的 cmd：bad", stderr.getvalue())
        self.assertEqual(json.loads(stdout.getvalue()), {"ok": False, "error": "未知的 cmd：bad"})


if __name__ == "__main__":
    unittest.main()
