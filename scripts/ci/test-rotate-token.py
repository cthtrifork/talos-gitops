#!/usr/bin/env python3
"""Runs rotate-token.sh against a fake Secrets API that only allows GET and a merge PATCH (the job's RBAC).

Run from the repository root: python3 scripts/ci/test-rotate-token.py
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
NAMESPACES = ["fileserver-system", "arc-runners-system"]
NAME = "fileserver-upload-token"
FLUX = {"kustomize.toolkit.fluxcd.io/ssa": "IfNotPresent", "kustomize.toolkit.fluxcd.io/prune": "disabled"}


class FakeKube(http.server.BaseHTTPRequestHandler):
    secrets = {}  # (namespace, name) -> {"data": {k: b64}, "annotations": {...}, "labels": {...}, "rv": int}
    writes = []   # namespaces patched, in order
    methods = []  # every request method seen

    def log_message(self, *a):
        pass

    def _send(self, code, obj=None):
        body = json.dumps(obj if obj is not None else {}, indent=2).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _find(self):
        m = re.match(r"/api/v1/namespaces/([^/]+)/secrets/([^/]+)$", self.path)
        return (m.group(1), m.group(2)) if m else None

    def _auth(self):
        self.methods.append(self.command)
        if self.headers.get("Authorization") != "Bearer sa-token":
            self._send(401)
            return False
        return True

    def do_GET(self):
        if not self._auth():
            return
        key = self._find()
        s = self.secrets.get(key) if key else None
        if not s:
            return self._send(404, {"kind": "Status", "code": 404})
        self._send(200, {"metadata": {"name": key[1], "namespace": key[0], "resourceVersion": str(s["rv"]),
                                      "annotations": s["annotations"], "labels": s["labels"]}, "data": s["data"]})

    def do_PATCH(self):
        if not self._auth():
            return
        key = self._find()
        s = self.secrets.get(key) if key else None
        if not s:
            return self._send(404)
        if self.headers.get("Content-Type") != "application/merge-patch+json":
            return self._send(415)
        patch = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if set(patch) != {"stringData"}:
            return self._send(422, {"message": "the job may only patch stringData"})
        for k, v in patch["stringData"].items():
            s["data"][k] = base64.b64encode(v.encode()).decode()
        s["rv"] += 1
        self.writes.append(key[0])
        self._send(200)

    def _refuse(self):
        self._auth()
        self._send(405, {"message": "the job has no permission to create or replace Secrets"})

    do_POST = do_PUT = do_DELETE = _refuse


def git_creates_the_secrets():
    FakeKube.secrets.clear()
    for ns in NAMESPACES:
        FakeKube.secrets[(ns, NAME)] = {"data": {}, "annotations": dict(FLUX), "labels": {"app.kubernetes.io/part-of": "fileserver"}, "rv": 1}


class RotateTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeKube)
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()
        cls.tmp = tempfile.mkdtemp()
        cls.token_file = os.path.join(cls.tmp, "token")
        with open(cls.token_file, "w") as f:
            f.write("sa-token\n")

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()
        cls.srv.server_close()

    def setUp(self):
        git_creates_the_secrets()
        FakeKube.writes.clear()
        FakeKube.methods.clear()

    def run_script(self, namespaces=NAMESPACES, days="30", expect_ok=True):
        env = {
            "PATH": os.environ["PATH"], "TMPDIR": self.tmp,
            "KUBE_API": "http://127.0.0.1:%d" % self.srv.server_address[1],
            "KUBE_TOKEN_FILE": self.token_file, "KUBE_CA_FILE": self.token_file,
            "NAMESPACES": " ".join(namespaces), "ROTATE_AFTER_DAYS": days,
        }
        p = subprocess.run(["sh", SCRIPT], env=env, capture_output=True, text=True, timeout=60)
        if expect_ok:
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        return p

    def value(self, ns, key):
        d = FakeKube.secrets[(ns, NAME)]["data"]
        return base64.b64decode(d[key]).decode() if key in d else None

    def old_enough(self, ns):
        FakeKube.secrets[(ns, NAME)]["data"]["rotated-at"] = base64.b64encode(b"2020-01-01T00:00:00Z").decode()

    def test_rotation_lifecycle(self):
        p = self.run_script()
        out = p.stdout + p.stderr
        cur = self.value("fileserver-system", "current")
        self.assertRegex(cur, r"^fs_[0-9a-f]{64}$")
        for ns in NAMESPACES:
            self.assertEqual(self.value(ns, "current"), cur, "same token in every namespace")
            self.assertRegex(self.value(ns, "rotated-at"), r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
            self.assertEqual(self.value(ns, "previous"), "", "no previous token yet")
        self.assertNotIn(cur, out, "the token must never be printed")

        # a second run inside the period writes nothing
        FakeKube.writes.clear()
        self.run_script()
        self.assertEqual(FakeKube.writes, [])

        # an edited copy is put back without rotating
        FakeKube.secrets[("arc-runners-system", NAME)]["data"]["current"] = base64.b64encode(b"tampered").decode()
        self.run_script()
        self.assertEqual(self.value("arc-runners-system", "current"), cur)
        self.assertEqual(self.value("fileserver-system", "current"), cur)

        # when the token is old it rotates and keeps the old one as previous, in both namespaces
        for ns in NAMESPACES:
            self.old_enough(ns)
        p = self.run_script()
        new = self.value("fileserver-system", "current")
        self.assertNotEqual(new, cur)
        for ns in NAMESPACES:
            self.assertEqual(self.value(ns, "current"), new)
            self.assertEqual(self.value(ns, "previous"), cur)
        self.assertNotIn(new, p.stdout + p.stderr)
        self.assertNotIn(cur, p.stdout + p.stderr)

        # the job only ever read and patched; Flux's metadata is untouched
        self.assertLessEqual(set(FakeKube.methods), {"GET", "PATCH"})
        for ns in NAMESPACES:
            s = FakeKube.secrets[(ns, NAME)]
            self.assertEqual(s["annotations"], FLUX)
            self.assertEqual(s["labels"], {"app.kubernetes.io/part-of": "fileserver"})

    def test_missing_secret_is_an_error_and_nothing_is_created(self):
        FakeKube.secrets.clear()
        p = self.run_script(expect_ok=False)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("Flux creates it", p.stderr)
        self.assertEqual(FakeKube.secrets, {}, "the job must not create a Secret")
        self.assertLessEqual(set(FakeKube.methods), {"GET"})

    def test_a_missing_second_copy_heals_after_flux_creates_it(self):
        del FakeKube.secrets[("arc-runners-system", NAME)]
        p = self.run_script(expect_ok=False)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("arc-runners-system/" + NAME + " does not exist", p.stderr)
        first = self.value("fileserver-system", "current")
        self.assertRegex(first, r"^fs_[0-9a-f]{64}$", "the first copy was filled before the failure")
        # Flux creates the missing Secret empty; the next run completes it with the same token and does not rotate again
        FakeKube.secrets[("arc-runners-system", NAME)] = {"data": {}, "annotations": dict(FLUX), "labels": {}, "rv": 1}
        self.run_script()
        self.assertEqual(self.value("arc-runners-system", "current"), first)
        self.assertEqual(self.value("fileserver-system", "current"), first)

    def test_wrong_service_account_token_fails(self):
        with open(self.token_file, "w") as f:
            f.write("wrong\n")
        try:
            p = self.run_script(namespaces=["fileserver-system"], expect_ok=False)
            self.assertNotEqual(p.returncode, 0)
            self.assertEqual(self.value("fileserver-system", "current"), None)
        finally:
            with open(self.token_file, "w") as f:
                f.write("sa-token\n")


if __name__ == "__main__":
    sys.exit(unittest.main())
