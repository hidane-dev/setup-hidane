#!/usr/bin/env bash
# Checks an install made by the action: its outputs, the hidane on PATH, and a server that answers
# GET / and a REST write and read.
#
#   EXPECTED_VERSION    the version the step should have installed
#   EXPECTED_CACHE_HIT  true or false; empty to accept either
#   VERSION, BIN, CACHE_HIT  the step's outputs
set -euo pipefail

: "${EXPECTED_VERSION:?}" "${VERSION:?}" "${BIN:?}" "${CACHE_HIT:?}"

fail() {
  echo "::error::$*"
  exit 1
}

[[ $VERSION == "$EXPECTED_VERSION" ]] || fail "the version output is $VERSION, expected $EXPECTED_VERSION"
case $CACHE_HIT in
  true | false) ;;
  *) fail "the cache-hit output is $CACHE_HIT" ;;
esac
if [[ -n ${EXPECTED_CACHE_HIT:-} && $CACHE_HIT != "$EXPECTED_CACHE_HIT" ]]; then
  fail "the cache-hit output is $CACHE_HIT, expected $EXPECTED_CACHE_HIT"
fi
[[ $("$BIN" --version) == "hidane $EXPECTED_VERSION" ]] || fail "the path output does not run hidane $EXPECTED_VERSION"
command -v hidane
hidane --version | tee version.txt
[[ $(cat version.txt) == "hidane $EXPECTED_VERSION" ]] || fail "hidane on PATH is not hidane $EXPECTED_VERSION"

hidane --host 127.0.0.1 --port 8080 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT
curl -fsS --retry 30 --retry-connrefused --retry-delay 1 http://127.0.0.1:8080/ | tee root.txt
echo
[[ $(tr -d '\r\n' < root.txt) == Ok ]] || fail "GET / did not answer Ok"
FIRESTORE_EMULATOR_HOST=127.0.0.1:8080 bash "$(dirname "$0")/write-read.sh"
curl -fsS -X POST http://127.0.0.1:8080/shutdown
wait "$pid"
trap - EXIT
echo "hidane $EXPECTED_VERSION answered on 127.0.0.1:8080 and stopped"
