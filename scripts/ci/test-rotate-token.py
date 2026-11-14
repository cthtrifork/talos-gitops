#!/usr/bin/env python3
"""Runs k8s/apps/fileserver/rotate-token.sh against a fake Kubernetes Secrets API and checks what it writes.

Needs python3, sh and curl. No cluster, no network beyond localhost. Run from the repository root:
    python3 scripts/ci/test-rotate-token.py
"""
import base64
import http.server
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import unittest

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "..", "k8s", "apps", "fileserver", "rotate-token.sh")
NAMESPACES = ["fileserver", "arc-runners-system"]


class FakeKube(http.server.BaseHTTPRequestHandler):
    secrets = {}  # (namespace, name) -> {"data": {k: b64}, "rv": int}
    writes = []

    def log_message(self, *a):
        pass

    def _send(self, code, obj=None):
        body = json.dumps(obj if obj is not None else {}, indent=2).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _auth(self):
        if self.headers.get("Authorization") != "Bearer sa-token":
            self._send(401)
            return False
        return True

    def do_GET(self):
        if not self._auth():
            return
        m = re.match(r"/api/v1/namespaces/([^/]+)/secrets/([^/]+)$", self.path)
        s = self.secrets.get((m.group(1), m.group(2))) if m else None
        if not s:
            return self._send(404, {"kind": "Status", "code": 404})
        self._send(200, {"metadata": {"name": m.group(2), "namespace": m.group(1), "resourceVersion": str(s["rv"])}, "data": s["data"]})

    def _write(self, create):
        if not self._auth():
            return
        obj = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        ns, name = obj["metadata"]["namespace"], obj["metadata"]["name"]
        existing = self.secrets.get((ns, name))
        if create and existing:
            return self._send(409)
        if not create and (not existing or obj["metadata"].get("resourceVersion") != str(existing["rv"])):
            return self._send(409)  # a PUT must carry the current resourceVersion
        data = {k: base64.b64encode(v.encode()).decode() for k, v in obj["stringData"].items()}
        self.secrets[(ns, name)] = {"data": data, "rv": (existing["rv"] + 1) if existing else 1}
        self.writes.append((self.command, ns))
        self._send(201 if create else 200)

    def do_POST(self):
        self._write(True)

    def do_PUT(self):
        self._write(False)


class RotateTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeKube)
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()
        cls.tmp = tempfile.mkdtemp()
        cls.token_file = os.path.join(cls.tmp, "token")
        open(cls.token_file, "w").write("sa-token\n")

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()

    def setUp(self):
        FakeKube.secrets.clear()
        FakeKube.writes.clear()

    def run_script(self, days="30"):
        env = {
            "PATH": os.environ["PATH"], "TMPDIR": self.tmp,
            "KUBE_API": "http://127.0.0.1:%d" % self.srv.server_address[1],
            "KUBE_TOKEN_FILE": self.token_file,
            "KUBE_CA_FILE": self.token_file,
            "NAMESPACES": " ".join(NAMESPACES),
            "ROTATE_AFTER_DAYS": days,
        }
        p = subprocess.run(["sh", SCRIPT], env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        return p.stdout + p.stderr

    def value(self, ns, key):
        d = FakeKube.secrets[(ns, "fileserver-upload-token")]["data"]
        return base64.b64decode(d[key]).decode() if key in d else None

    def test_rotation_lifecycle(self):
        out = self.run_script()
        cur = self.value("fileserver", "current")
        self.assertRegex(cur, r"^fs_[0-9a-f]{64}$")
        for ns in NAMESPACES:
            self.assertEqual(self.value(ns, "current"), cur, "same token in every namespace")
            self.assertRegex(self.value(ns, "rotated-at"), r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
            self.assertIsNone(self.value(ns, "previous"))
        self.assertNotIn(cur, out, "the token must never be printed")

        # a second run inside the period writes nothing
        FakeKube.writes.clear()
        self.run_script()
        self.assertEqual(FakeKube.writes, [])

        # a deleted copy is repaired with the same token, without rotating
        del FakeKube.secrets[("arc-runners-system", "fileserver-upload-token")]
        self.run_script()
        self.assertEqual(self.value("arc-runners-system", "current"), cur)
        self.assertEqual(self.value("fileserver", "current"), cur)

        # an edited copy is put back
        FakeKube.secrets[("arc-runners-system", "fileserver-upload-token")]["data"]["current"] = base64.b64encode(b"tampered").decode()
        self.run_script()
        self.assertEqual(self.value("arc-runners-system", "current"), cur)

        # when the token is old it rotates and keeps the old one as previous, in both namespaces
        for ns in NAMESPACES:
            FakeKube.secrets[(ns, "fileserver-upload-token")]["data"]["rotated-at"] = base64.b64encode(b"2020-01-01T00:00:00Z").decode()
        out = self.run_script()
        new = self.value("fileserver", "current")
        self.assertNotEqual(new, cur)
        for ns in NAMESPACES:
            self.assertEqual(self.value(ns, "current"), new)
            self.assertEqual(self.value(ns, "previous"), cur)
        self.assertNotIn(new, out)
        self.assertNotIn(cur, out)

    def test_wrong_service_account_token_fails(self):
        open(self.token_file, "w").write("wrong\n")
        try:
            env = {"PATH": os.environ["PATH"], "TMPDIR": self.tmp, "KUBE_API": "http://127.0.0.1:%d" % self.srv.server_address[1],
                   "KUBE_TOKEN_FILE": self.token_file, "KUBE_CA_FILE": self.token_file, "NAMESPACES": "fileserver"}
            p = subprocess.run(["sh", SCRIPT], env=env, capture_output=True, text=True, timeout=60)
            self.assertNotEqual(p.returncode, 0)
            self.assertEqual(FakeKube.secrets, {})
        finally:
            open(self.token_file, "w").write("sa-token\n")


if __name__ == "__main__":
    sys.exit(unittest.main())
