#!/usr/bin/env bash
# Writes a document through the REST API of the emulator at $FIRESTORE_EMULATOR_HOST and reads it
# back.
set -euo pipefail

: "${FIRESTORE_EMULATOR_HOST:?FIRESTORE_EMULATOR_HOST is not set}"
url="http://$FIRESTORE_EMULATOR_HOST/v1/projects/demo-setup-hidane/databases/(default)/documents/greetings/hello"
text="written on ${RUNNER_OS:-a runner} at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

curl -fsS -X PATCH "$url" \
  -H 'Authorization: Bearer owner' \
  -H 'Content-Type: application/json' \
  --data "{\"fields\": {\"text\": {\"stringValue\": \"$text\"}}}" > /dev/null
curl -fsS "$url" -H 'Authorization: Bearer owner' | tee read.json
echo
jq -e --arg text "$text" '.fields.text.stringValue == $text' read.json > /dev/null
echo "Read back the document written through $FIRESTORE_EMULATOR_HOST"
