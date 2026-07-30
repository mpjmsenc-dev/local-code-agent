#!/usr/bin/env bash
# tests/test-lib.sh — automated unit tests for scripts/lib.sh and the tune
# ladder. Pure-logic tests only: no root, no network, no services touched,
# so they run anywhere (CI, the build VM, a droplet).
#
# Usage: tests/test-lib.sh   (exit 0 = all passed, 1 = something failed)
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${TESTS_DIR}/.." && pwd)"

FAILED=0
t_ok()   { printf '%s\n' "ok   - $*"; }
t_fail() { printf '%s\n' "FAIL - $*"; FAILED=$((FAILED+1)); }
check() {
  local desc="$1"; shift
  if "$@"; then t_ok "${desc}"; else t_fail "${desc}"; fi
}

# Work in a throwaway copy so the real .env is never touched.
SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT
mkdir -p "${SANDBOX}/scripts"
cp "${REPO}/scripts/lib.sh" "${SANDBOX}/scripts/"
cp "${REPO}/.env.example" "${SANDBOX}/"

# shellcheck source=../scripts/lib.sh
source "${SANDBOX}/scripts/lib.sh"

echo "# load_env creates .env from .env.example and applies defaults"
load_env
check ".env auto-created" test -f "${SANDBOX}/.env"
check "default MODEL_NAME" test "${MODEL_NAME}" = "qwen2.5-coder:7b"
check "default OLLAMA_CONTEXT_LENGTH" test "${OLLAMA_CONTEXT_LENGTH}" = "8192"
check "default AUTO_TUNE" test "${AUTO_TUNE}" = "true"

echo "# set_env_var -> load_env round-trip (update + append, no duplicates)"
set_env_var MODEL_NAME "qwen2.5-coder:14b"
set_env_var OLLAMA_CONTEXT_LENGTH 16384
set_env_var BRAND_NEW_KEY hello
load_env
check "updated key read back" test "${MODEL_NAME}" = "qwen2.5-coder:14b"
check "second updated key read back" test "${OLLAMA_CONTEXT_LENGTH}" = "16384"
check "appended key read back" test "${BRAND_NEW_KEY}" = "hello"
check "no duplicate MODEL_NAME lines" \
  test "$(grep -c '^MODEL_NAME=' "${SANDBOX}/.env")" -eq 1
set_env_var MODEL_NAME "qwen2.5-coder:7b"
load_env
check "second update round-trips too" test "${MODEL_NAME}" = "qwen2.5-coder:7b"

echo "# confirm() auto-confirms when stdin is not a tty (unattended installs)"
check "confirm auto-yes on non-tty" confirm "test prompt?" </dev/null

echo "# ollama_url() rewrites listen addresses to connectable ones"
url_for() { OLLAMA_HOST="$1" ollama_url; }
check "plain host:port passes through" \
  test "$(url_for 127.0.0.1:11434)" = "http://127.0.0.1:11434"
check "0.0.0.0 rewritten to loopback" \
  test "$(url_for 0.0.0.0:11434)" = "http://127.0.0.1:11434"
check "http:// prefix stripped then re-added" \
  test "$(url_for http://127.0.0.1:11434)" = "http://127.0.0.1:11434"
check "trailing slash stripped" \
  test "$(url_for 127.0.0.1:11434/)" = "http://127.0.0.1:11434"
check "port-less 0.0.0.0 gets default 11434 (not port 80)" \
  test "$(url_for 0.0.0.0)" = "http://127.0.0.1:11434"
check "port-less host gets default 11434" \
  test "$(url_for 127.0.0.1)" = "http://127.0.0.1:11434"

echo "# ollama_bind_is_public() flags non-loopback binds"
# Subshells inherit the sourced functions, so scope OLLAMA_HOST per check.
is_public()  { ( OLLAMA_HOST="$1" ollama_bind_is_public ); }
not_public() { ! ( OLLAMA_HOST="$1" ollama_bind_is_public ); }
check "0.0.0.0:11434 bind is public"      is_public  "0.0.0.0:11434"
check "0.0.0.0 bare bind is public"       is_public  "0.0.0.0"
check "127.0.0.1:11434 is not public"     not_public "127.0.0.1:11434"
check "localhost:11434 is not public"     not_public "localhost:11434"
check "IPv6 :: wildcard is public"        is_public  "::"
check "IPv6 [::]:11434 is public"         is_public  "[::]:11434"
check "IPv6 [::1] loopback is not public" not_public "[::1]:11434"

echo "# detect_ram_gib() returns a sane positive integer"
RAM="$(detect_ram_gib)"
check "RAM is numeric and > 0" test "${RAM}" -gt 0

echo "# venv path helpers build paths inside the repo"
check "venv_dir under REPO_ROOT" test "$(venv_dir)" = "${SANDBOX}/${VENV_NAME}"
check "aider_bin under venv" test "$(aider_bin)" = "${SANDBOX}/${VENV_NAME}/bin/aider"

echo "# tune ladder boundaries (spec: 8, 9, 15, 16, 23, 24 GiB)"
# tune.sh only runs main when executed; sourcing it exposes choose_for_ram().
# shellcheck source=../scripts/tune.sh
source "${REPO}/scripts/tune.sh"
ladder_is() {
  local ram="$1" model="$2" ctx="$3"
  choose_for_ram "${ram}"
  [[ "${TUNE_MODEL}" == "${model}" && "${TUNE_CTX}" == "${ctx}" ]]
}
check " 4 GiB -> 3b/4096"   ladder_is 4  qwen2.5-coder:3b  4096
check " 8 GiB -> 3b/4096"   ladder_is 8  qwen2.5-coder:3b  4096
check " 9 GiB -> 7b/8192"   ladder_is 9  qwen2.5-coder:7b  8192
check "15 GiB -> 7b/8192"   ladder_is 15 qwen2.5-coder:7b  8192
check "16 GiB -> 14b/8192"  ladder_is 16 qwen2.5-coder:14b 8192
check "23 GiB -> 14b/8192"  ladder_is 23 qwen2.5-coder:14b 8192
check "24 GiB -> 14b/16384" ladder_is 24 qwen2.5-coder:14b 16384
check "64 GiB -> 14b/16384" ladder_is 64 qwen2.5-coder:14b 16384

echo "# largest_present_within() — offline-downgrade fallback picks the largest model <= target"
# Stub model_present against a PRESENT list so we can unit-test the selection
# without a real ollama. (This override is intentional and only affects the
# checks below, which are the last in the file.)
PRESENT=""
model_present() { case " ${PRESENT} " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
lpw() { PRESENT="$1" largest_present_within "$2"; }
check "target 14b, only 3b present -> 3b"       test "$(lpw 'qwen2.5-coder:3b' qwen2.5-coder:14b)" = "qwen2.5-coder:3b"
check "target 14b, 7b+3b present -> 7b"         test "$(lpw 'qwen2.5-coder:7b qwen2.5-coder:3b' qwen2.5-coder:14b)" = "qwen2.5-coder:7b"
check "target 14b, all present -> 14b"          test "$(lpw 'qwen2.5-coder:14b qwen2.5-coder:7b qwen2.5-coder:3b' qwen2.5-coder:14b)" = "qwen2.5-coder:14b"
check "target 7b, only 14b present -> none"     test -z "$(lpw 'qwen2.5-coder:14b' qwen2.5-coder:7b)"
check "target 7b, nothing present -> none"      test -z "$(lpw '' qwen2.5-coder:7b)"
lpw_fails() { ! ( PRESENT="$1" largest_present_within "$2" >/dev/null ); }
check "returns nonzero exit when nothing fits"  lpw_fails 'qwen2.5-coder:14b' qwen2.5-coder:7b

echo "# ollama_dropin_matches() — no false drift (else tune restarts Ollama every boot)"
# Render to a temp path (no root needed) and confirm the detector agrees the
# freshly-written drop-in matches, flags a real change, and treats a missing
# file as a mismatch.
dropin_drifted() { ! ollama_dropin_matches; }
DROP="$(mktemp)"
OLLAMA_DROPIN="${DROP}"
OLLAMA_HOST="127.0.0.1:11434"; OLLAMA_CONTEXT_LENGTH="8192"; OLLAMA_KEEP_ALIVE="30m"
render_ollama_dropin_content > "${DROP}"
check "freshly-rendered drop-in matches (no false drift)" ollama_dropin_matches
OLLAMA_CONTEXT_LENGTH="4096"   # simulate a tune decision that changed the context
check "a changed context is detected as drift" dropin_drifted
OLLAMA_CONTEXT_LENGTH="8192"
rm -f "${DROP}"
check "missing drop-in counts as a mismatch" dropin_drifted

echo "# lib.sh defines HOME when unset (cloud-init / systemd oneshots — else ollama panics)"
home_set_when_unset() {
  (
    # Clear the double-source guard so the HOME logic re-runs, and unset HOME
    # to simulate the cloud-init / root-oneshot environment.
    unset HOME LCA_LIB_LOADED
    # shellcheck disable=SC1090
    source "${REPO}/scripts/lib.sh"
    [[ -n "${HOME:-}" ]]
  )
}
check "HOME is set after sourcing lib.sh with HOME unset" home_set_when_unset

echo
if (( FAILED > 0 )); then
  echo "RESULT: ${FAILED} test(s) FAILED"
  exit 1
fi
echo "RESULT: all tests passed"
