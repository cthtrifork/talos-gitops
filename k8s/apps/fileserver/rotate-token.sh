#!/bin/sh
# Rotates the fileserver upload token. Runs in the CronJob (curlimages/curl: busybox plus curl), never in the app: the
# fileserver only reads the Secret. Idempotent: it rotates only when the token is missing or older than ROTATE_AFTER_DAYS,
# and otherwise just repairs an edited copy.
#
# The Secrets themselves are created by Git (token-secret.yaml, empty, with the Flux annotation IfNotPresent), so this job
# only needs get and patch on those names and cannot create anything. It writes three keys with a JSON merge patch and
# leaves the metadata alone (Flux's annotations and labels survive): current, previous (empty when there is none) and
# rotated-at (RFC 3339). The same values go to the Secret NAME in every namespace of NAMESPACES; the first one decides when
# to rotate. Values are never printed.
#
# Environment: NAMESPACES (space separated, required), SECRET_NAME, ROTATE_AFTER_DAYS (30), KUBE_API,
# KUBE_TOKEN_FILE, KUBE_CA_FILE (the last three default to the pod's ServiceAccount).
set -eu

API="${KUBE_API:-https://kubernetes.default.svc}"
SA=/var/run/secrets/kubernetes.io/serviceaccount
TOKEN_FILE="${KUBE_TOKEN_FILE:-$SA/token}"
CA_FILE="${KUBE_CA_FILE:-$SA/ca.crt}"
NAME="${SECRET_NAME:-fileserver-upload-token}"
DAYS="${ROTATE_AFTER_DAYS:-30}"
: "${NAMESPACES:?NAMESPACES is required}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

kube() { curl -sS --max-time 30 --cacert "$CA_FILE" -H "Authorization: Bearer $(cat "$TOKEN_FILE")" "$@"; }

# field FILE KEY: the value of a string field of the (pretty or compact) JSON the API returns
field() { sed -n "s/.*\"$2\": *\"\([^\"]*\)\".*/\1/p" "$1" | head -n 1; }
# decoded FILE KEY: a base64 value of .data, decoded; empty when the key is absent
decoded() {
  v="$(field "$1" "$2")"
  if [ -n "$v" ]; then printf '%s' "$v" | base64 -d; fi
}

# get NS: writes the Secret to $WORK/NS.json. It must exist: Git creates it, this job does not.
get() {
  code="$(kube -o "$WORK/$1.json" -w '%{http_code}' "$API/api/v1/namespaces/$1/secrets/$NAME")"
  case "$code" in
  200) ;;
  404)
    echo "$1/$NAME does not exist: Flux creates it from token-secret.yaml (this job cannot), retry after the next reconcile" >&2
    exit 1
    ;;
  *)
    echo "get $1/$NAME: HTTP $code" >&2
    exit 1
    ;;
  esac
}

PRIMARY="${NAMESPACES%% *}"

get "$PRIMARY"
cur="$(decoded "$WORK/$PRIMARY.json" current)"
prev="$(decoded "$WORK/$PRIMARY.json" previous)"
at="$(decoded "$WORK/$PRIMARY.json" rotated-at)"

rotate=0
if [ -z "$cur" ] || [ -z "$at" ]; then
  rotate=1
else
  # busybox date reads "YYYY-MM-DD hh:mm:ss": split the RFC 3339 value with parameter expansion
  day="${at%%T*}"
  clock="${at#*T}"
  clock="${clock%Z}"
  then_s="$(date -u -d "$day $clock" +%s)"
  now_s="$(date -u +%s)"
  [ $((now_s - then_s)) -ge $((DAYS * 86400)) ] && rotate=1
fi

if [ "$rotate" = 1 ]; then
  new="fs_$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  prev="$cur"
  cur="$new"
  at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "rotating: new token created at $at"
else
  echo "not due: token from $at is younger than $DAYS days"
fi

for ns in $NAMESPACES; do
  get "$ns"
  if [ "$(decoded "$WORK/$ns.json" current)" = "$cur" ] && [ "$(decoded "$WORK/$ns.json" previous)" = "$prev" ] &&
    [ "$(decoded "$WORK/$ns.json" rotated-at)" = "$at" ]; then
    echo "$ns/$NAME: up to date"
    continue
  fi

  printf '{"stringData":{"current":"%s","previous":"%s","rotated-at":"%s"}}' "$cur" "$prev" "$at" >"$WORK/body.json"
  code="$(kube -X PATCH -H 'Content-Type: application/merge-patch+json' --data-binary "@$WORK/body.json" -o "$WORK/out.json" -w '%{http_code}' "$API/api/v1/namespaces/$ns/secrets/$NAME")"
  case "$code" in
  200) echo "$ns/$NAME: written" ;;
  *)
    echo "patch $ns/$NAME: HTTP $code" >&2
    exit 1
    ;;
  esac
done
