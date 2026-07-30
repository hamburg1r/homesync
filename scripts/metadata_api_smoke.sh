#!/usr/bin/env bash
# Manual smoke for Milestone 2 metadata API (curl).
# Prerequisites:
#   1. cd backend && uv sync --extra dev
#   2. Index a folder: uv run homesync-index --root /path/to/files --label Demo
#   3. Start daemon: uv run homesync-server
# Then: ./scripts/metadata_api_smoke.sh
set -euo pipefail

BASE="${HOMESYNC_API:-http://127.0.0.1:8787}"

echo "== health =="
curl -sS "$BASE/health" | tee /dev/stderr
echo

echo "== list files =="
FILES_JSON="$(curl -sS "$BASE/v1/files")"
echo "$FILES_JSON" | tee /dev/stderr
FILE_ID="$(echo "$FILES_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["file_id"] if d else "")')"
if [[ -z "$FILE_ID" ]]; then
  echo "No files in catalog. Run homesync-index first." >&2
  exit 1
fi
echo "Using file_id=$FILE_ID"
echo

echo "== baseline delta =="
DELTA0="$(curl -sS "$BASE/v1/catalog/delta")"
echo "$DELTA0" | tee /dev/stderr
CURSOR="$(echo "$DELTA0" | python3 -c 'import json,sys; print(json.load(sys.stdin)["next_cursor"])')"
echo "cursor=$CURSOR"
echo

echo "== tag file =="
curl -sS -X PUT "$BASE/v1/files/$FILE_ID/tags" \
  -H 'Content-Type: application/json' \
  -d '{"tags":["smoke","manual"]}' | tee /dev/stderr
echo
echo

echo "== delta since cursor (should include tagged file) =="
curl -sS --get "$BASE/v1/catalog/delta" --data-urlencode "since=$CURSOR" | tee /dev/stderr
echo
echo

echo "== get file =="
curl -sS "$BASE/v1/files/$FILE_ID" | tee /dev/stderr
echo
echo

echo "== patch metadata =="
BASE_TS="$(curl -sS "$BASE/v1/files/$FILE_ID" | python3 -c 'import json,sys; print(json.load(sys.stdin)["updated_at"])')"
curl -sS -X PATCH "$BASE/v1/files/$FILE_ID" \
  -H 'Content-Type: application/json' \
  -d "{\"title\":\"smoke-renamed\",\"notes\":\"from curl\",\"base_updated_at\":\"$BASE_TS\"}" \
  | tee /dev/stderr
echo
echo

echo "== list tags =="
curl -sS "$BASE/v1/tags" | tee /dev/stderr
echo
echo "OK"
