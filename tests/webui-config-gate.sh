#!/usr/bin/env bash
# tests/webui-config-gate.sh — assert that Open WebUI really SERVES our starter
# questions to a signed-in user, rather than its stock ones.
#
#   tests/webui-config-gate.sh http://127.0.0.1:3000
#
# Why this shape, after getting it wrong once: the first version of this gate
# asserted that our values were written into Open WebUI's `config` table. They
# are not, and they do not need to be. Config.configure(defaults=DEFAULT_CONFIG)
# registers the env-derived values as in-memory defaults, and Config.get()
# returns the database row only IF one exists, falling back to that default
# otherwise. A fresh install has zero config rows and still serves our values,
# so the old gate was testing Open WebUI's persistence strategy instead of our
# behaviour — it failed while the feature worked perfectly.
#
# This asks the server what it would actually send to a user, which is the only
# thing that matters and is stable across how upstream chooses to store it.
set -euo pipefail

BASE="${1:-}"
[[ -n "${BASE}" ]] || { echo "usage: $0 http://127.0.0.1:PORT" >&2; exit 2; }
command -v jq >/dev/null || { echo "FAIL: jq is not installed" >&2; exit 2; }

EMAIL="ci-gate@example.invalid"
PASSWORD="ci-gate-password-not-a-secret"

# A token is needed because /api/config only includes ui.prompt_suggestions for
# an authenticated user. On a fresh install signup succeeds and the first
# account becomes admin; if the account already exists (a re-run against a
# persistent volume) sign in instead.
# '|| true' on each: under 'set -o pipefail' a connection failure makes the
# whole substitution fail, which would kill the script before it could print a
# diagnosis — leaving only curl's bare exit code as the CI output.
token="$(curl -sS --max-time 20 -X POST "${BASE}/api/v1/auths/signup" \
  -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg e "${EMAIL}" --arg p "${PASSWORD}" '{name:"CI Gate", email:$e, password:$p}')" \
  2>/dev/null | jq -r '.token // empty' 2>/dev/null || true)"

if [[ -z "${token}" ]]; then
  token="$(curl -sS --max-time 20 -X POST "${BASE}/api/v1/auths/signin" \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg e "${EMAIL}" --arg p "${PASSWORD}" '{email:$e, password:$p}')" \
    2>/dev/null | jq -r '.token // empty' 2>/dev/null || true)"
fi
[[ -n "${token}" ]] || {
  echo "FAIL: could not obtain a token (is signup enabled on this instance?)" >&2
  curl -sS --max-time 10 "${BASE}/api/config" 2>/dev/null | head -c 500 >&2 || true
  exit 1
}

config="$(curl -sS --max-time 20 -H "Authorization: Bearer ${token}" "${BASE}/api/config" || true)"
[[ -n "${config}" ]] || { echo "FAIL: /api/config returned nothing" >&2; exit 1; }

titles="$(printf '%s' "${config}" | jq -r '[(.default_prompt_suggestions // .prompt_suggestions // [])[].title[]?] | join(" ")' 2>/dev/null || true)"
if [[ -z "${titles}" ]]; then
  echo "FAIL: the served config carries no starter questions." >&2
  echo "--- keys in /api/config ---" >&2
  printf '%s' "${config}" | jq -r 'keys | join(", ")' >&2 || true
  exit 1
fi

printf '%s' "${titles}" | grep -q 'Explain this command' \
  || { echo "FAIL: our starter questions are not the ones being served: ${titles}" >&2; exit 1; }
# if/fi rather than 'grep && exit 1': under set -e the AND-list's first command
# failing is the PASSING case here, and a gate should not hinge on that.
if printf '%s' "${titles}" | grep -qi 'roman empire'; then
  echo "FAIL: Open WebUI is still serving its stock starter questions" >&2
  exit 1
fi

echo "OK: Open WebUI serves our starter questions, not the stock ones"
