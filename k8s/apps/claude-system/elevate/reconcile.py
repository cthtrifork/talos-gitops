#!/usr/bin/env python3
"""Turns the request files the page drops into the spool into a ServiceAccount, a RoleBinding and a short-lived token for a tier, stored
as a kubeconfig in a Secret that claude-rc mounts.

The API server decides what is allowed (RBAC, the admission policies, the TokenRequest limits) and the token expires on its own, so this
only checks that names are safe to put in a URL. It keeps no state: every pass starts from the cluster. The page reads the cluster itself
with the read-only token left in the spool, and each action is one JSON line on stdout.
"""
import json
import os
import re
import ssl
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

SPOOL = Path(os.environ.get("SPOOL", "/spool"))
SA_DIR = Path(os.environ.get("SA_DIR", "/var/run/secrets/kubernetes.io/serviceaccount"))
CLUSTER = "https://kubernetes.default.svc"
API = os.environ.get("API_SERVER", CLUSTER)
TLS = ssl.create_default_context(cafile=str(SA_DIR / "ca.crt")) if API.startswith("https") else None
SECRET = "/api/v1/namespaces/claude-system/secrets/claude-elevated-kubeconfigs"
MANAGED = {"app.kubernetes.io/managed-by": "claude-elevate"}
EXPIRES = "claude-elevate/expires-at"
TIME = "%Y-%m-%dT%H:%M:%SZ"

TIER = re.compile(r"[a-z]{1,16}")
NAMESPACE = re.compile(r"[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?")
MINUTES = re.compile(r"[1-9][0-9]{0,3}")


class ApiError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


def call(method, path, body=None, content_type="application/json"):
    """One request to the API server. The service account token rotates, so it is read every time."""
    request = urllib.request.Request(
        API + path,
        method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": "Bearer " + (SA_DIR / "token").read_text().strip(), "Content-Type": content_type},
    )
    try:
        with urllib.request.urlopen(request, context=TLS, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        try:
            message = json.loads(error.read()).get("message", "")
        except ValueError:
            message = ""
        raise ApiError(error.code, message) from None


def log(event, tier="", namespace="", detail=""):
    entry = {"ts": now().strftime(TIME), "event": event, "tier": tier, "namespace": namespace, "detail": detail}
    print(json.dumps(entry), flush=True)


def now():
    return datetime.now(timezone.utc)


def service_account_path(namespace, name):
    return f"/api/v1/namespaces/{namespace}/serviceaccounts/{name}"


def binding_path(namespace, name):
    return f"/apis/rbac.authorization.k8s.io/v1/namespaces/{namespace}/rolebindings/{name}"


def apply(path, obj):
    call("PATCH", path + "?fieldManager=claude-elevate&force=true", obj, "application/apply-patch+yaml")


def patch_secret(patch):
    call("PATCH", SECRET, patch, "application/merge-patch+json")


def delete(path):
    try:
        call("DELETE", path)
    except ApiError as error:
        if error.status != 404:  # a missing object counts as deleted
            raise


def request_token(namespace, name, seconds):
    body = {"apiVersion": "authentication.k8s.io/v1", "kind": "TokenRequest", "spec": {"expirationSeconds": seconds}}
    return call("POST", service_account_path(namespace, name) + "/token", body)["status"]["token"]


def kubeconfig(tier, namespace, token):
    name = f"{tier}-{namespace}"
    return {
        "apiVersion": "v1",
        "kind": "Config",
        "current-context": name,
        "clusters": [{"name": "cluster", "cluster": {"server": CLUSTER, "certificate-authority": str(SA_DIR / "ca.crt")}}],
        "users": [{"name": name, "user": {"token": token}}],
        "contexts": [{"name": name, "context": {"cluster": "cluster", "user": name, "namespace": namespace}}],
    }


def remove(tier, namespace):
    """Deleting the ServiceAccount invalidates its tokens at once. The kubeconfig goes first, so a failure leaves a grant that is
    still listed and gets retried."""
    name = f"claude-elevate-{tier}"
    patch_secret({"data": {f"{tier}-{namespace}.kubeconfig": None}})
    delete(service_account_path(namespace, name))
    delete(binding_path(namespace, name))


def grant(tier, namespace, minutes):
    name = f"claude-elevate-{tier}"
    expires = (now() + timedelta(minutes=minutes)).strftime(TIME)
    metadata = {"name": name, "namespace": namespace, "labels": MANAGED, "annotations": {EXPIRES: expires}}
    service_account = {"apiVersion": "v1", "kind": "ServiceAccount", "metadata": metadata}
    binding = {
        "apiVersion": "rbac.authorization.k8s.io/v1",
        "kind": "RoleBinding",
        "metadata": metadata,
        "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": f"claude-{tier}"},
        "subjects": [{"kind": "ServiceAccount", "name": name, "namespace": namespace}],
    }
    try:
        remove(tier, namespace)  # a new ServiceAccount invalidates the tokens of an earlier grant
        apply(service_account_path(namespace, name), service_account)
        apply(binding_path(namespace, name), binding)
        token = request_token(namespace, name, minutes * 60)
        patch_secret({"stringData": {f"{tier}-{namespace}.kubeconfig": json.dumps(kubeconfig(tier, namespace, token))}})
    except ApiError as error:
        try:
            remove(tier, namespace)
        except ApiError:
            pass
        return log("grant_failed", tier, namespace, str(error)[:160])
    log("granted", tier, namespace, "until " + expires)


def revoke(tier, namespace, reason):
    try:
        remove(tier, namespace)
    except ApiError:
        return log("revoke_failed", tier, namespace)
    log("revoked", tier, namespace, reason)


def overdue(expires):
    try:
        return datetime.strptime(expires, TIME).replace(tzinfo=timezone.utc) <= now()
    except (TypeError, ValueError):
        return True  # an unreadable expiry counts as overdue


def revoke_grants(reason):
    """reason "expired" revokes the overdue grants, anything else all of them."""
    for item in call("GET", "/api/v1/serviceaccounts?labelSelector=app.kubernetes.io/managed-by%3Dclaude-elevate")["items"]:
        metadata = item["metadata"]
        if reason == "expired" and not overdue(metadata.get("annotations", {}).get(EXPIRES)):
            continue
        revoke(metadata["name"].removeprefix("claude-elevate-"), metadata["namespace"], reason)


def handle(path):
    try:
        request = json.loads(path.read_text())
    except ValueError:
        request = None
    path.unlink()
    if not isinstance(request, dict):
        return log("rejected", detail="unreadable request")

    action, tier = request.get("action"), str(request.get("tier", ""))
    if action == "revokeall":
        revoke_grants("requested")
    elif action == "revoke":
        namespace = str(request.get("namespace", ""))
        if TIER.fullmatch(tier) and NAMESPACE.fullmatch(namespace):  # allowed in any namespace, so a revoke works after an opt-in is removed
            revoke(tier, namespace, "requested")
        else:
            log("rejected", detail="revoke request")
    elif action == "grant":
        minutes = str(request.get("minutes", ""))
        if not (TIER.fullmatch(tier) and MINUTES.fullmatch(minutes)):
            return log("rejected", detail="grant request: tier or minutes")
        namespaces = request.get("namespaces")
        if not isinstance(namespaces, list):
            return log("rejected", tier, detail="namespaces must be a list")
        for namespace in namespaces:
            if isinstance(namespace, str) and NAMESPACE.fullmatch(namespace):
                grant(tier, namespace, int(minutes))
            else:
                log("rejected", tier, str(namespace)[:63], "invalid namespace")
    else:
        log("rejected", detail="unknown action")


def main():
    os.umask(0o077)
    while True:
        try:
            token = request_token("claude-system", "claude-elevate-ui", 3600)  # for the page, which reads the cluster itself
            (SPOOL / ".ui-token").write_text(token)
            os.replace(SPOOL / ".ui-token", SPOOL / "ui-token")
            for path in sorted(SPOOL.glob("req-*")):  # names sort by arrival
                if time.time() - path.stat().st_mtime < 1:  # Connect writes in place: stop here so a later request never runs first
                    break
                handle(path)
            revoke_grants("expired")
        except (ApiError, OSError) as error:
            log("error", detail=str(error)[:160])
        time.sleep(3)


if __name__ == "__main__":
    main()
