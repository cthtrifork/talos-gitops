#!/bin/sh
# Creates and rotates the fileserver upload token. Runs in the CronJob (curlimages/curl: busybox plus curl), never in the
# app: the fileserver only reads the Secret. Idempotent: it rotates only when the token is missing or older than
# ROTATE_AFTER_DAYS, and otherwise just repairs a missing or edited copy.
#
# The Secret has the keys current, previous and rotated-at (RFC 3339). The same data goes to the Secret NAME in every
# namespace of NAMESPACES (the first one decides when to rotate). Values are never printed.
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

# get NS: writes the Secret to $WORK/NS.json and returns its HTTP status in $CODE
get() { CODE="$(kube -o "$WORK/$1.json" -w '%{http_code}' "$API/api/v1/namespaces/$1/secrets/$NAME")"; }

PRIMARY="${NAMESPACES%% *}"

get "$PRIMARY"
cur=""
prev=""
at=""
case "$CODE" in
200)
  cur="$(decoded "$WORK/$PRIMARY.json" current)"
  prev="$(decoded "$WORK/$PRIMARY.json" previous)"
  at="$(decoded "$WORK/$PRIMARY.json" rotated-at)"
  ;;
404) ;;
*)
  echo "get $PRIMARY/$NAME: HTTP $CODE" >&2
  exit 1
  ;;
esac

rotate=0
if [ -z "$cur" ] || [ -z "$at" ]; then
  rotate=1
else
  # busybox date reads "YYYY-MM-DD hh:mm:ss"
  then_s="$(date -u -d "$(printf '%s' "$at" | sed 's/T/ /; s/Z$//')" +%s)"
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
  rv=""
  case "$CODE" in
  200)
    if [ "$(decoded "$WORK/$ns.json" current)" = "$cur" ] && [ "$(decoded "$WORK/$ns.json" previous)" = "$prev" ] &&
      [ "$(decoded "$WORK/$ns.json" rotated-at)" = "$at" ]; then
      echo "$ns/$NAME: up to date"
      continue
    fi
    rv="$(field "$WORK/$ns.json" resourceVersion)"
    ;;
  404) ;;
  *)
    echo "get $ns/$NAME: HTTP $CODE" >&2
    exit 1
    ;;
  esac

  meta="\"name\":\"$NAME\",\"namespace\":\"$ns\",\"labels\":{\"app.kubernetes.io/managed-by\":\"fileserver-rotate\"}"
  [ -n "$rv" ] && meta="$meta,\"resourceVersion\":\"$rv\""
  data="\"current\":\"$cur\",\"rotated-at\":\"$at\""
  [ -n "$prev" ] && data="$data,\"previous\":\"$prev\""
  printf '{"apiVersion":"v1","kind":"Secret","metadata":{%s},"type":"Opaque","stringData":{%s}}' "$meta" "$data" >"$WORK/body.json"

  if [ -n "$rv" ]; then
    method=PUT
    url="$API/api/v1/namespaces/$ns/secrets/$NAME"
  else
    method=POST
    url="$API/api/v1/namespaces/$ns/secrets"
  fi
  code="$(kube -X "$method" -H 'Content-Type: application/json' --data-binary "@$WORK/body.json" -o "$WORK/out.json" -w '%{http_code}' "$url")"
  case "$code" in
  200 | 201) echo "$ns/$NAME: written ($method)" ;;
  *)
    echo "$method $ns/$NAME: HTTP $code" >&2
    exit 1
    ;;
  esac
done
