#!/usr/bin/env bash
# tests/webui-config-gate.sh — assert that a copy of Open WebUI's database
# really contains OUR system prompt and OUR starter questions.
#
# Run against a webui.db copied out of the container:
#   tests/webui-config-gate.sh /tmp/webui.db
#
# Why a script and not an inline CI step: this way it is ShellCheck-covered and
# can be tested against fixture databases locally, instead of learning what it
# does one slow CI round-trip at a time.
#
# Open WebUI has used two different config layouts, and the published image does
# not always match the source on main:
#   per-key  config(key TEXT PRIMARY KEY, value JSON)   -- current
#   blob     config(id, data JSON, version, ...)        -- older, one nested doc
# Both are read here, because a gate that breaks on an unrelated upstream
# refactor is a gate that gets deleted.
set -euo pipefail

DB="${1:-}"
[[ -n "${DB}" ]] || { echo "usage: $0 /path/to/webui.db" >&2; exit 2; }
[[ -s "${DB}" ]] || { echo "FAIL: ${DB} is missing or empty — the copy out of the container did not work" >&2; exit 1; }

command -v sqlite3 >/dev/null || { echo "FAIL: sqlite3 is not installed" >&2; exit 2; }
command -v jq >/dev/null      || { echo "FAIL: jq is not installed" >&2; exit 2; }

# diagnose — everything needed to tell WHY this failed, printed once, so a red
# build explains itself instead of prompting another round-trip.
diagnose() {
  echo "--- diagnosis ---"
  echo "tables: $(sqlite3 "${DB}" "select group_concat(name) from sqlite_master where type='table'" 2>&1 | head -c 500)"
  echo "config columns: $(sqlite3 "${DB}" "select group_concat(name) from pragma_table_info('config')" 2>&1 | head -c 300)"
  echo "config rows: $(sqlite3 "${DB}" "select count(*) from config" 2>&1 | head -c 80)"
  if [[ "${LAYOUT}" == "per-key" ]]; then
    echo "config keys: $(sqlite3 "${DB}" "select group_concat(key) from config" 2>&1 | head -c 2000)"
  elif [[ "${LAYOUT}" == "blob" ]]; then
    echo "top-level keys: $(sqlite3 "${DB}" "select data from config order by id desc limit 1" 2>&1 | jq -r 'keys | join(",")' 2>&1 | head -c 500)"
  fi
}

COLUMNS="$(sqlite3 "${DB}" "select group_concat(name) from pragma_table_info('config')" 2>/dev/null || true)"
LAYOUT="unknown"
case ",${COLUMNS}," in
  *,key,*)  LAYOUT="per-key" ;;
  *,data,*) LAYOUT="blob" ;;
esac

if [[ "${LAYOUT}" == "unknown" ]]; then
  echo "FAIL: Open WebUI's config table has an unrecognised layout (columns: ${COLUMNS:-none})." >&2
  diagnose >&2
  exit 1
fi
echo "Open WebUI config layout: ${LAYOUT}"

# read_config DOTTED_KEY — the stored JSON value, whichever layout is in use.
read_config() {
  local key="$1"
  if [[ "${LAYOUT}" == "per-key" ]]; then
    sqlite3 "${DB}" "select value from config where key='${key}'" 2>/dev/null || true
  else
    # Dotted keys are a nested path in the blob layout: models.default_params
    # lives at .models.default_params.
    sqlite3 "${DB}" "select data from config order by id desc limit 1" 2>/dev/null \
      | jq -c --arg k "${key}" 'getpath($k | split(".")) // empty' 2>/dev/null || true
  fi
}

fail() { echo "FAIL: $*" >&2; diagnose >&2; exit 1; }

system="$(read_config models.default_params | jq -r '.system // empty' 2>/dev/null || true)"
[[ -n "${system}" ]] || fail "no default system prompt is stored in Open WebUI's config"
printf '%s' "${system}" | grep -q 'local-code-agent' \
  || fail "the stored system prompt is not ours: ${system:0:200}"
printf '%s' "${system}" | grep -qi 'never invent' \
  || fail "the stored system prompt lost its 'never invent flags' instruction"

titles="$(read_config ui.prompt_suggestions | jq -r '[.[].title[]?] | join(" ")' 2>/dev/null || true)"
[[ -n "${titles}" ]] || fail "no starter questions are stored in Open WebUI's config"
printf '%s' "${titles}" | grep -q 'Explain this command' \
  || fail "our starter questions are missing: ${titles}"
# if/fi rather than 'grep && exit 1': under set -e the AND-list's first command
# failing is the PASSING case here, and a gate should not hinge on that.
if printf '%s' "${titles}" | grep -qi 'roman empire'; then
  fail "Open WebUI's stock starter questions are still in place"
fi

echo "OK: the chat has our system prompt and our starter questions (${LAYOUT} layout)"
