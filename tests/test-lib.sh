#!/usr/bin/env bash
# tests/test-lib.sh — automated unit tests for scripts/lib.sh and the tune
# ladder. Pure-logic tests only: no root, no network, no services touched,
# so they run anywhere (CI, the build VM, a droplet).
#
# Usage: tests/test-lib.sh   (exit 0 = all passed, 1 = something failed)
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${TESTS_DIR}/.." && pwd)"

# Everything bin/lca dispatches to, i.e. every script that runs in the USER's
# directory and speaks to them directly. Several gates below share it, so it
# lives here rather than in whichever section happened to need it first.
# run-agent.sh is absent on purpose: it forwards to aider.
LCA_TARGETS=( check-system.sh backup.sh restore.sh update.sh update-model.sh
              webui.sh netmode.sh scripts/tune.sh scripts/apply.sh
              scripts/ask.sh scripts/logs.sh scripts/speed.sh
              scripts/selftest.sh )

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
check "default BACKUP_KEEP" test "${BACKUP_KEEP}" = "7"
check "default AIDER_CONVENTIONS" test "${AIDER_CONVENTIONS}" = "true"
check "default BACKUP_SCHEDULE" test "${BACKUP_SCHEDULE}" = "*-*-* 03:30:00"
check "default SKIP_TAILSCALE" test "${SKIP_TAILSCALE}" = "false"

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

echo "# has_nvidia_gpu() runs cleanly and returns a boolean (no crash on CPU-only)"
gpu_ok() { has_nvidia_gpu; rc=$?; [[ "${rc}" -eq 0 || "${rc}" -eq 1 ]]; }
check "has_nvidia_gpu exits 0 or 1" gpu_ok

echo "# venv path helpers build paths inside the repo"
check "venv_dir under REPO_ROOT" test "$(venv_dir)" = "${SANDBOX}/${VENV_NAME}"
check "aider_bin under venv" test "$(aider_bin)" = "${SANDBOX}/${VENV_NAME}/bin/aider"

echo "# aider_token_budget() splits the Ollama window (prompt + reply), reply>=1024"
# Matches each tune-ladder context: reply is a quarter (min 1024), prompt the rest.
check "4096  -> 3072 1024"   test "$(aider_token_budget 4096)"  = "3072 1024"
check "8192  -> 6144 2048"   test "$(aider_token_budget 8192)"  = "6144 2048"
check "16384 -> 12288 4096"  test "$(aider_token_budget 16384)" = "12288 4096"
# input + output must always sum back to the window (no tokens lost/created).
budget_sums_to() { local in out; read -r in out < <(aider_token_budget "$1"); [[ $((in+out)) -eq "$1" ]]; }
check "budget sums to 4096"  budget_sums_to 4096
check "budget sums to 8192"  budget_sums_to 8192
check "budget sums to 16384" budget_sums_to 16384
# Corrupt/empty ctx must fall back to the 8192 default — never a zero budget.
check "empty ctx -> 8192 default"     test "$(aider_token_budget '')"    = "6144 2048"
check "non-numeric ctx -> 8192"       test "$(aider_token_budget abc)"   = "6144 2048"
check "absurdly small ctx -> 8192"    test "$(aider_token_budget 16)"    = "6144 2048"

echo "# load_env's \${VAR:-default} fallbacks apply when .env omits the keys"
# The checks above read a .env copied from .env.example, so they only prove the
# EXAMPLE's literals. These prove the fallbacks in lib.sh itself — load-bearing
# under 'set -u' when a user hand-trims .env (a supported degraded case).
TRIMMED="${SANDBOX}/trimmed"
mkdir -p "${TRIMMED}/scripts"
cp "${REPO}/scripts/lib.sh" "${TRIMMED}/scripts/"
# A .env with none of the newer keys, as an older/hand-edited install would have.
printf 'MODEL_NAME=qwen2.5-coder:7b\n' > "${TRIMMED}/.env"
# This MUST run in a separate bash process, with the keys cleared from the
# environment. lib.sh guards against double-sourcing (LCA_LIB_LOADED), so
# re-sourcing it in a subshell is a no-op and would keep THIS script's load_env
# (bound to a .env that does define the keys) — the assertion would then pass no
# matter what the fallbacks say. load_env also exports .env values (set -a), so
# they must be stripped with 'env -u' or the child would inherit them.
fallbacks_apply() {
  # SC2016 is intentional here: the ${...} must be expanded by the CHILD bash
  # (after it sources lib.sh), not by this script — hence the single quotes.
  # shellcheck disable=SC2016
  env -u BACKUP_KEEP -u BACKUP_SCHEDULE -u AIDER_CONVENTIONS bash -c '
    set -euo pipefail
    source "$1/scripts/lib.sh"
    load_env
    [[ "${BACKUP_KEEP}"      == "7" ]]              || { echo "BACKUP_KEEP=${BACKUP_KEEP}" >&2; exit 1; }
    [[ "${BACKUP_SCHEDULE}"  == "*-*-* 03:30:00" ]] || { echo "BACKUP_SCHEDULE=${BACKUP_SCHEDULE}" >&2; exit 1; }
    [[ "${AIDER_CONVENTIONS}" == "true" ]]          || { echo "AIDER_CONVENTIONS=${AIDER_CONVENTIONS}" >&2; exit 1; }
  ' _ "${TRIMMED}"
}
check "load_env fallbacks apply when .env omits the keys" fallbacks_apply

echo "# ollama_bind_is_public(): a bare ':PORT' binds ALL interfaces, not loopback"
bind_public()  { OLLAMA_HOST="$1" ollama_bind_is_public; }
bind_private() { ! OLLAMA_HOST="$1" ollama_bind_is_public; }
check "bare ':11434' is PUBLIC (all interfaces)" bind_public ":11434"
check "'0.0.0.0:11434' is public"                bind_public "0.0.0.0:11434"
check "'::' is public"                           bind_public "::"
check "'127.0.0.1:11434' stays private"          bind_private "127.0.0.1:11434"
check "'localhost:11434' stays private"          bind_private "localhost:11434"
check "'[::1]:11434' stays private"              bind_private "[::1]:11434"

echo "# verify_backup() rejects corrupt/incomplete archives (a bad backup must never be trusted)"
# backup.sh only runs main() when executed, so sourcing it here just defines
# its functions. Guards the "disk filled up mid-tar" case: the archive must read
# back AND contain every staged file, or retention would delete good backups on
# the strength of a broken one and restore.sh would later pick it (newest wins).
# shellcheck source=../backup.sh
source "${REPO}/backup.sh"
VB_STAGE="${SANDBOX}/vbstage"
mkdir -p "${VB_STAGE}"
printf 'env-contents\n'    > "${VB_STAGE}/env"
printf 'model-list\n'      > "${VB_STAGE}/models.txt"
VB_GOOD="${SANDBOX}/good.tar.gz"
tar czf "${VB_GOOD}" -C "${VB_STAGE}" .
# '!' is a shell keyword, so it cannot be passed through check's "$@" — negate
# inside a real function instead.
vb_rejects() { ! verify_backup "$1" "$2" 2>/dev/null; }
check "intact archive verifies"            verify_backup "${VB_GOOD}" "${VB_STAGE}"
VB_TRUNC="${SANDBOX}/truncated.tar.gz"
head -c 40 "${VB_GOOD}" > "${VB_TRUNC}"
check "truncated archive is rejected"      vb_rejects "${VB_TRUNC}" "${VB_STAGE}"
VB_PARTIAL="${SANDBOX}/partial.tar.gz"
tar czf "${VB_PARTIAL}" -C "${VB_STAGE}" ./env          # models.txt missing
check "archive missing a staged file is rejected" vb_rejects "${VB_PARTIAL}" "${VB_STAGE}"
: > "${SANDBOX}/empty.tar.gz"
check "empty file is rejected"             vb_rejects "${SANDBOX}/empty.tar.gz" "${VB_STAGE}"

echo "# backups_to_prune() keeps the newest KEEP; prints the older ones to delete"
# Timestamped names sort chronologically; the helper sorts internally, so the
# order they are fed in must not matter.
B1="backups/local-code-agent-backup-20250101-000000.tar.gz"
B2="backups/local-code-agent-backup-20250102-000000.tar.gz"
B3="backups/local-code-agent-backup-20250103-000000.tar.gz"
B4="backups/local-code-agent-backup-20250104-000000.tar.gz"
B5="backups/local-code-agent-backup-20250105-000000.tar.gz"
prune_sel() { local k="$1"; shift; printf '%s\n' "$@" | backups_to_prune "${k}"; }
check "keep 2 of 5 -> delete the oldest 3 (feed order irrelevant)" \
  test "$(prune_sel 2 "${B3}" "${B1}" "${B5}" "${B2}" "${B4}")" = "$(printf '%s\n%s\n%s' "${B1}" "${B2}" "${B3}")"
check "keep 1 of 3 -> delete the oldest 2" \
  test "$(prune_sel 1 "${B2}" "${B3}" "${B1}")" = "$(printf '%s\n%s' "${B1}" "${B2}")"
check "keep == count -> delete none" test -z "$(prune_sel 3 "${B1}" "${B2}" "${B3}")"
check "keep > count -> delete none"  test -z "$(prune_sel 7 "${B1}" "${B2}" "${B3}")"
check "keep 0 -> retention off, delete none" test -z "$(prune_sel 0 "${B1}" "${B2}")"
check "non-numeric keep -> delete none"      test -z "$(prune_sel abc "${B1}" "${B2}")"

echo "# .env keys must not collide with aider's own env vars (load_env exports them)"
# load_env sources .env under 'set -a', so every key becomes an environment
# variable. A key named AIDER_* can therefore be consumed by aider itself: our
# sentinel LCA_EDIT_FORMAT=auto, if named AIDER_EDIT_FORMAT, made even
# 'aider --version' fail because "auto" is not a valid aider edit format.
no_aider_collision() {
  local aider_bin_path key
  aider_bin_path="$(aider_bin)"
  [[ -x "${aider_bin_path}" ]] || return 0   # aider not installed here: skip
  local envs; envs="$("${aider_bin_path}" --help 2>/dev/null | grep -oE 'env var: [A-Z_]+' | sed 's/env var: //' | sort -u)"
  [[ -n "${envs}" ]] || return 0
  while read -r key; do
    [[ -n "${key}" ]] || continue
    # AIDER_VERSION is ours and predates this rule; it is not an aider env var.
    if grep -qx "${key}" <<<"${envs}"; then
      echo "collides with aider: ${key}" >&2
      return 1
    fi
  done < <(grep -oE '^[A-Z_]+' "${REPO}/.env.example" | sort -u)
  return 0
}
check "no .env key collides with an aider env var" no_aider_collision

echo "# processor_from_ps(): is the GPU actually being used? (parsed by pattern, not column)"
PS_GPU="NAME                ID              SIZE      PROCESSOR    CONTEXT    UNTIL
qwen2.5-coder:7b    dae161e27b0e    5.5 GB    100% GPU     4096       4 minutes from now"
PS_CPU="NAME                ID              SIZE      PROCESSOR    CONTEXT    UNTIL
qwen2.5-coder:7b    dae161e27b0e    5.5 GB    100% CPU     4096       4 minutes from now"
PS_SPLIT="NAME                 ID              SIZE     PROCESSOR          CONTEXT   UNTIL
qwen2.5-coder:14b    9ec8897f747e    10 GB    38%/62% CPU/GPU    8192      5 minutes from now"
PS_EMPTY="NAME    ID    SIZE    PROCESSOR    CONTEXT    UNTIL"
pfp() { printf '%s\n' "$1" | processor_from_ps "$2"; }
check "100% GPU parsed"  test "$(pfp "${PS_GPU}" qwen2.5-coder:7b)"    = "100% GPU"
check "100% CPU parsed"  test "$(pfp "${PS_CPU}" qwen2.5-coder:7b)"    = "100% CPU"
# The PROCESSOR field contains a space, so a column-index parser would return
# just "38%/62%" here — this pins the pattern-based behaviour.
check "CPU/GPU split parsed" test "$(pfp "${PS_SPLIT}" qwen2.5-coder:14b)" = "38%/62% CPU/GPU"
not_loaded() { ! printf '%s\n' "${PS_EMPTY}" | processor_from_ps qwen2.5-coder:7b 2>/dev/null; }
check "unloaded model reports nothing" not_loaded
wrong_model() { ! printf '%s\n' "${PS_GPU}" | processor_from_ps some-other-model 2>/dev/null; }
check "a different model is not matched" wrong_model

echo "# aider output quality: edit format per model size, repo map scaled to the window"
ef() { aider_edit_format "$1"; }
check "0.5b -> whole (tiny models cannot do diffs)" test "$(ef qwen2.5-coder:0.5b)" = "whole"
check "3b   -> whole"                               test "$(ef qwen2.5-coder:3b)"   = "whole"
check "4b   -> whole (boundary)"                    test "$(ef qwen3:4b)"           = "whole"
check "7b   -> diff (boundary+1)"                   test "$(ef qwen2.5-coder:7b)"   = "diff"
check "14b  -> diff"                                test "$(ef qwen2.5-coder:14b)"  = "diff"
check "unparseable tag falls back to diff"          test "$(ef weird-model)"        = "diff"
# The repo map must never crowd out the code being edited.
check "ctx 4096  -> 384 map tokens"  test "$(aider_map_tokens 4096)"  = "384"
check "ctx 8192  -> 768 map tokens"  test "$(aider_map_tokens 8192)"  = "768"
check "ctx 16384 -> 1536 map tokens" test "$(aider_map_tokens 16384)" = "1536"
map_under_prompt() { local in out; read -r in out < <(aider_token_budget "$1"); [[ "$(aider_map_tokens "$1")" -lt $(( in / 2 )) ]]; }
check "map stays well under the prompt budget (4096)"  map_under_prompt 4096
check "map stays well under the prompt budget (16384)" map_under_prompt 16384

echo "# MODEL_FAMILY: the ladder follows the configured family, with a safe fallback"
# shellcheck source=../scripts/tune.sh
source "${REPO}/scripts/tune.sh"
fam_pick() { MODEL_FAMILY="$1" choose_for_ram "$2"; printf '%s' "${TUNE_MODEL}"; }
check "default family, 16 GiB -> qwen2.5-coder:14b" test "$(fam_pick qwen2.5-coder 16)" = "qwen2.5-coder:14b"
check "qwen3 family, 12 GiB -> qwen3:8b"            test "$(fam_pick qwen3 12)"         = "qwen3:8b"
check "qwen3 family, 4 GiB -> qwen3:4b"             test "$(fam_pick qwen3 4)"          = "qwen3:4b"
check "codellama family, 24 GiB -> codellama:13b"   test "$(fam_pick codellama 24)"     = "codellama:13b"
# deepseek-coder-v2 ships only 16b, which cannot load on 8 GiB — the ladder
# must fall back rather than pull ~10 GB and then OOM on first use.
check "deepseek-coder-v2 on 8 GiB falls back" test "$(fam_pick deepseek-coder-v2 8 2>/dev/null)" = "qwen2.5-coder:3b"
check "deepseek-coder-v2 on 16 GiB is used"   test "$(fam_pick deepseek-coder-v2 16)" = "deepseek-coder-v2:16b"
# An unknown family must NOT be used verbatim — that would make tune.sh try to
# pull a tag that does not exist and fail every boot.
check "unknown family falls back to the default"    test "$(fam_pick not-a-real-model 16)" = "qwen2.5-coder:14b"
# A model auto-tune picks MUST fit the rung that picked it. At ~0.6 GB per
# billion params (q4) plus context, the 16-23 GiB rung tops out around 20B —
# so a 34b/70b/405b tag here would mean pulling tens of GB and then OOMing.
fits_rung() {
  local ram="$1" fam="$2" tag params
  tag="$(fam_pick "${fam}" "${ram}")"; tag="${tag##*:}"
  params="${tag%[bB]}"
  awk -v p="${params}" -v r="${ram}" 'BEGIN{ exit !(p * 0.6 + 1 <= r) }'
}
for f in qwen2.5-coder qwen3 deepseek-coder-v2 llama3.1 codellama; do
  check "auto-tune pick fits 8 GiB  (${f})"  fits_rung 8  "${f}"
  check "auto-tune pick fits 16 GiB (${f})"  fits_rung 16 "${f}"
done

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

echo "# run_reader() — probe once, then run; never retry a follow under sudo"
reader_ran() { test "$(run_reader true -- printf ran)" = "ran"; }
check "probe succeeds -> the real command runs" reader_ran
# The bug this replaced: 'run it, and on failure retry under sudo' restarts a
# 'logs -f' as root the moment the user presses Ctrl-C, because quitting a
# follow exits non-zero. Probing separately is what makes that impossible.
reader_skips() {
  local out
  out="$(run_reader false -- printf SHOULD-NOT-RUN 2>/dev/null || true)"
  [[ "${out}" != *SHOULD-NOT-RUN* ]]
}
check "probe fails -> the real command never runs" reader_skips
reader_status() { run_reader false -- true; }
not_ok() { ! "$@" >/dev/null 2>&1; }
check "probe fails -> nonzero exit" not_ok reader_status
# A malformed call must be loud, not silently run the wrong half.
check "no '--' separator -> usage error (2)" not_ok run_reader true echo hi
check "nothing after '--' -> usage error (2)" not_ok run_reader true --
# Arguments containing spaces must survive the split intact.
reader_keeps_spaces() { test "$(run_reader true -- printf '%s' 'two words')" = "two words"; }
check "arguments with spaces survive the split" reader_keeps_spaces

echo "# classify_gpu() — every GPU situation, testable on a machine with no GPU"
gpu_is() { test "$(classify_gpu "$2" "$3" "$4")" = "$1"; }
check "no card, no driver -> none"        gpu_is none      false false ""
# The silent case: the card is there, everything works, and it is 10x slower
# with no explanation offered anywhere.
check "card but no driver -> no-driver"   gpu_is no-driver true  false ""
check "driver but model on CPU -> idle"   gpu_is idle      true  true  "100% CPU"
check "partial offload -> split"          gpu_is split     true  true  "38%/62% CPU/GPU"
check "fully offloaded -> active"         gpu_is active    true  true  "100% GPU"
check "model not resident -> unknown"     gpu_is unknown   true  true  ""
# A driver can be present in a VM whose card is passed through and therefore
# invisible to lspci; trusting lspci alone would report 'none' with the GPU
# plainly working.
check "driver works though lspci sees nothing -> classified by placement" \
  gpu_is active false true "100% GPU"

echo "# vram_mib_from_smi() — picks the LARGEST card, not the first"
smi_gives() { test "$(printf '%s\n' "$2" | vram_mib_from_smi)" = "$1"; }
check "single 3090 -> 24576" smi_gives 24576 "24576"
# A small display adapter listed first would otherwise set every recommendation.
check "display adapter first, compute card second -> the big one" \
  smi_gives 24576 "2048
24576"
check "strips units if present" smi_gives 24576 "24576 MiB"
no_vram() { ! printf '%s\n' "$1" | vram_mib_from_smi >/dev/null 2>&1; }
check "no output (no driver) -> nonzero exit" no_vram ""
check "non-numeric output -> nonzero exit" no_vram "N/A"

echo "# largest_model_for_vram() — must fit COMPLETELY, spilling is the trap"
check "24 GB (RTX 3090) -> 37B" test "$(largest_model_for_vram 24576)" = "37"
check "12 GB -> 17B"            test "$(largest_model_for_vram 12288)" = "17"
check "8 GB -> 10B"             test "$(largest_model_for_vram 8192)" = "10"
no_fit() { ! largest_model_for_vram "$1" >/dev/null 2>&1; }
check "a 1 GB adapter fits nothing -> nonzero exit" no_fit 1024
check "non-numeric -> nonzero exit" no_fit abc

echo "# model_params_b() — parameter count read off the Ollama tag"
check "qwen2.5-coder:7b -> 7"   test "$(model_params_b qwen2.5-coder:7b)" = "7"
check "qwen2.5-coder:14b -> 14" test "$(model_params_b qwen2.5-coder:14b)" = "14"
check "deepseek-coder-v2:16b -> 16" test "$(model_params_b deepseek-coder-v2:16b)" = "16"
check "a fractional 1.5b rounds to a usable 2" test "$(model_params_b qwen2.5:1.5b)" = "2"
# A tag with no size must FAIL rather than return a wrong number: speed.sh
# multiplies this by 0.6 GB to report memory bandwidth, so a silent 0 or 1
# would print a confidently wrong figure.
# Negative cases go through a local helper, never 'bash -c': a child shell has
# not sourced lib.sh, so the function would be "command not found" (exit 127)
# and '!' would turn that into a pass — a test that cannot fail.
no_params_b() { ! model_params_b "$1" >/dev/null 2>&1; }
check "':latest' has no size -> nonzero exit" no_params_b qwen2.5-coder:latest
check "a bare name has no size -> nonzero exit" no_params_b mistral
check "'7b' inside the name is not a size tag" no_params_b llama3.1-7bfoo:latest

echo "# tokens_per_second() — rate from Ollama's own nanosecond counters"
check "19 tokens in 3.4987s -> 5.4/s" test "$(tokens_per_second 19 3498679000)" = "5.4"
check "100 tokens in exactly 1s -> 100.0/s" test "$(tokens_per_second 100 1000000000)" = "100.0"
# A zero duration would divide by zero; a divide-by-zero in awk prints 'inf'
# and the verdict would then read "inf tokens/second — working as intended".
no_tps() { ! tokens_per_second "$1" "$2" >/dev/null 2>&1; }
check "zero duration -> nonzero exit" no_tps 10 0
check "non-numeric duration -> nonzero exit" no_tps 10 abc

echo "# the shared system prompt (phone chat + 'lca ask' must agree)"
check "system prompt is non-empty" test -n "$(lca_system_prompt)"
# Run greps through a helper: 'bash -c' would start a child shell that has
# never sourced lib.sh, so lca_system_prompt would be missing there.
prompt_says() { lca_system_prompt | grep -qi -- "$1"; }
check "system prompt tells the model it is private" prompt_says "leaves that machine"
check "system prompt forbids inventing flags" prompt_says "never invent"

# The prompt advertises 'lca' subcommands to the model. If one of them is
# renamed in bin/lca and not here, the assistant confidently teaches a command
# that does not exist — the exact failure the prompt itself warns against.
# Extract every "  lca <word>" line and require bin/lca to actually dispatch it.
prompt_commands_all_real() {
  local sub bad=0
  while read -r sub; do
    [[ -n "${sub}" ]] || continue
    # bin/lca dispatches via a case statement: 'ask)', 'offline|online|...)' or
    # 'help|-h|--help)'. The character class must allow '-' and '"', or a
    # command sharing a branch with a dashed alias reads as missing and this
    # test fails for a command that is perfectly real.
    grep -qE "^[[:space:]]*[a-z|\"-]*\b${sub}\b[a-z|\"-]*\)" "${REPO}/bin/lca" || {
      printf 'system prompt advertises unknown command: lca %s\n' "${sub}" >&2
      bad=1
    }
  done < <(lca_system_prompt | sed -n 's/^  lca \([a-z]\{1,\}\).*/\1/p')
  return "${bad}"
}
check "every 'lca' command named in the system prompt exists in bin/lca" prompt_commands_all_real
# A real deployment asked the phone chat to "build the whole functioning
# project". The 3b model emitted a fabricated tool call —
# {"name": "build_expense_tracker", "arguments": {...}} — then refused with
# "I'm limited ... due to the constraints of my design and training", then
# drifted into NLP complexity and WCAG for what was a local expense tracker.
# Nothing in the prompt had told it what it is, so it invented tools it does
# not have and gave a vague excuse instead of the true, actionable answer.
prompt_forbids_tool_calls() {
  local p; p="$(lca_system_prompt)"
  grep -qi 'no tools' <<<"${p}" && grep -qi 'never emit a function' <<<"${p}"
}
check "system prompt tells the model it has no tools" prompt_forbids_tool_calls
# The prompt is not free. It is re-read on EVERY message, out of the 4096-token
# window the 3b rung runs with, so each paragraph is rent charged per turn for
# the life of the install — and it is the one cost that never shows up in a
# test, a log or a benchmark.
#
# It doubled once already, 328 -> 656 tokens, before anyone noticed: 16% of
# that window handed to instructions on every single turn. The fix then was to
# cut what measurement showed did not work, which is only possible if someone
# is watching the number. Nobody was.
#
# ~4 characters per token is rough but stable for English prose, and the point
# is a ceiling, not an estimate. 15% of 4096 leaves real headroom while making
# a doubling impossible to land quietly.
#
# The heuristic has since been checked against the real tokenizer rather than
# left as an assertion: the shipped prompt is 2,255 characters, this estimates
# 563 tokens, and ollama reports prompt_eval_count=559 for it on the 3b model.
# Within one percent, in the safe direction.
prompt_fits_its_budget() {
  local chars tokens cap
  chars="$(lca_system_prompt | wc -c)"
  tokens=$(( chars / 4 ))
  cap=$(( 4096 * 15 / 100 ))
  (( tokens <= cap )) || {
    printf 'the system prompt is ~%s tokens (%s chars) — over the %s-token budget, which is 15%%%% of the 4096 context the 3b rung runs with\n' \
      "${tokens}" "${chars}" "${cap}" >&2
    return 1
  }
}
check "the system prompt stays inside its share of a 4096-token context" \
  prompt_fits_its_budget
# ...and sends project work to the ONE command that can write files. The first
# version of this fix said only "the terminal agent", and the model duly
# suggested 'lca ask' — which is also text-only. Caught by running it.
# Asserted on meaning, not on a phrase. The first version keyed off the
# literal "NOT " that happened to be in draft one, and went red the moment the
# wording was strengthened — a test that guards a sentence rather than a
# contract. What must remain true: the prompt names bare 'lca' as the thing
# that writes files, and explicitly rules 'lca ask' out for that job.
# The shape of the copy-pasteable handover line, defined ONCE because both
# gates below match on it. Written out twice they promptly drifted together in
# the wrong direction: both anchored the line on STARTING with 'cd', and both
# went red the moment the recipe grew a 'mkdir -p' in front of it. That prefix
# was not cosmetic — a user whose first message is "build me an app" has no
# ~/my-project, so the command the chat now gives them every time died on
# "cd: No such file or directory" before aider ever ran.
#
# So the contract is not the first word. It is: ONE copy-pasteable line that
# enters a project directory and ends in the BARE word 'lca'. Anything may
# precede the cd; nothing may follow the lca.
HANDOVER_LINE='^[[:space:]]*(.*&&[[:space:]]*)?cd [^&]*&&[[:space:]]*lca[[:space:]]*$'
prompt_names_the_file_writing_command() {
  local p mentions negated
  p="$(lca_system_prompt)"
  grep -qE "${HANDOVER_LINE}" <<<"${p}" || return 1
  # And 'lca ask' may never appear un-negated. The model reads every line; one
  # neutral mention next to a file-writing request is all it took last time.
  mentions="$(grep -c 'lca ask' <<<"${p}")"
  (( mentions > 0 )) || return 1
  negated="$(grep 'lca ask' <<<"${p}" \
    | grep -ciE "never|nothing|not |no file|text only|touches no")"
  [[ "${mentions}" == "${negated}" ]]
}
check "system prompt distinguishes 'lca' from 'lca ask' for file work" \
  prompt_names_the_file_writing_command
# That pattern IS the gate now, and loosening it to admit a new recipe shape is
# precisely how a gate quietly stops gating. So assert what it accepts and what
# it refuses, against the forms this has actually taken and gone wrong as.
handover_pattern_discriminates() {
  local s
  # Named 'accepts'/'rejects', not 'good'/'bad': other functions in this file
  # use a scalar 'bad' as an error flag, and ShellCheck tracks a name's type
  # across the whole file — an array called 'bad' here turns those into
  # SC2178/SC2128 warnings pages away.
  local -a accepts=(
    "  cd ~/my-project && lca"
    "  mkdir -p ~/my-project && cd ~/my-project && lca"
  )
  local -a rejects=(
    "  cd ~/my-project && lca ask"      # the bug this gate was born for
    "  mkdir -p ~/my-project && lca"    # never entered the project directory
    "  cd ~/my-project"                 # never reached aider
    "  lca"                             # no directory at all
  )
  for s in "${accepts[@]}"; do
    grep -qE "${HANDOVER_LINE}" <<<"${s}" || {
      printf 'the handover pattern rejects a valid recipe: %s\n' "${s}" >&2
      return 1
    }
  done
  for s in "${rejects[@]}"; do
    if grep -qE "${HANDOVER_LINE}" <<<"${s}"; then
      printf 'the handover pattern accepts a broken recipe: %s\n' "${s}" >&2
      return 1
    fi
  done
}
check "the handover pattern accepts the real recipe and refuses the broken ones" \
  handover_pattern_discriminates
# And the recipe must work for someone who does not have the directory yet —
# which is most of the people who trigger it, since the trigger is "build me
# something". Run the line the prompt actually gives, in a throwaway HOME.
handover_recipe_actually_runs() {
  local line home rc
  line="$(lca_system_prompt | grep -E "${HANDOVER_LINE}" | head -1)"
  [[ -n "${line}" ]] || return 1
  home="${SANDBOX}/fakehome"
  rm -rf "${home}"; mkdir -p "${home}"
  # 'lca' itself needs Ollama and aider, so stub it: what is under test is
  # everything BEFORE it — the part that used to die on "cd: No such file or
  # directory" before aider was ever reached.
  HOME="${home}" bash -c "lca() { :; }; ${line}" >/dev/null 2>&1
  rc=$?
  (( rc == 0 )) || {
    printf 'the recipe the chat hands out fails in a fresh HOME (exit %s): %s\n' \
      "${rc}" "${line}" >&2
    return 1
  }
}
check "the handover recipe runs in a home that has no project directory yet" \
  handover_recipe_actually_runs
# The reader is on a PHONE, inside a chat app with no terminal in it, so a bash
# block is only actionable once they know where it goes. Measured on 3b: only
# 1 answer in 6 mentioned a terminal, SSH or the server at all.
#
# Telling the model to SAY so barely helped — 0/6 to 1/6. Putting the same
# words INSIDE the block it copies took it to 5/6, at no cost to how faithfully
# the command itself came through. That is the rule this asserts: for a small
# model, the payload travels in what it copies, not in an instruction about
# what to narrate.
#
# A '#' line, so it stays paste-safe: it is a valid shell comment.
handover_block_says_where_it_runs() {
  lca_system_prompt | awk -v pat="${HANDOVER_LINE}" '
    { hist[NR] = tolower($0) }
    $0 ~ pat {
      # The line immediately above must be a comment naming where it runs.
      if (hist[NR-1] ~ /^[[:space:]]*#/ &&
          (hist[NR-1] ~ /terminal|ssh|server|shell/)) found = 1
    }
    END { exit !found }'
}
check "the handover block says where to run it, inside the block" \
  handover_block_says_where_it_runs

echo "# a flag a script accepts but 'lca' never mentions is a hidden feature"
# update-model.sh takes --list-recommended, which answers "what model fits this
# machine's RAM?" — the question auto-tune exists for. It appeared in its own
# usage text and in docs/PERFORMANCE.md, and nowhere a user of 'lca' would look:
# 'lca model' mentioned only --list. Same shape as 'lca harden', which was
# dispatched and undocumented; the front door has to name what the tools behind
# it can do, or it is not a front door.
model_flags_are_discoverable() {
  local flag helptext
  helptext="$("${REPO}/bin/lca" help 2>/dev/null)"
  while read -r flag; do
    [[ -n "${flag}" ]] || continue
    grep -qF -- "${flag}" <<<"${helptext}" || {
      printf "update-model.sh accepts %s but 'lca help' never mentions it\\n" "${flag}" >&2
      return 1
    }
  done < <(grep -oE '^\s+--[a-z-]+\)' "${REPO}/update-model.sh" | tr -d ' )' | sort -u)
}
check "'lca help' names every flag update-model.sh accepts" \
  model_flags_are_discoverable

echo "# every example in 'lca help' must actually work"
# The help has advertised "lca --no-auto-commits (arguments for aider)" since
# it was written, and it did not work: a leading dash matched no branch in the
# dispatcher and fell through to "Unknown command". Nobody noticed because the
# gate that keeps help honest checks the COMMANDS in the list, and this lives
# in the examples underneath it.
#
# Asserted on the dispatcher, not by running aider: starting it needs a model.
help_examples_are_dispatched() {
  local src="${REPO}/bin/lca"
  # A dashed argument must route somewhere real...
  grep -qE '^\s*-\*\)\s*exec .*run-agent\.sh' "${src}" || {
    echo "bin/lca has no branch for a leading-dash argument, but 'lca help' shows one" >&2
    return 1
  }
  # ...after the help branch, or -h and --help would start aider instead.
  awk '/help\|-h\|--help\)/ { helpline = NR }
       /^  -\*\)/           { dashline = NR }
       END { exit !(helpline && dashline && helpline < dashline) }' "${src}" || {
    echo "the dash branch precedes the help branch — 'lca --help' would start aider" >&2
    return 1
  }
  # And an unknown NON-dashed command must still be refused.
  grep -qE 'Unknown command' "${src}" || {
    echo "bin/lca no longer refuses unknown commands" >&2
    return 1
  }
}
check "'lca <aider-flag>' reaches aider, as 'lca help' promises" \
  help_examples_are_dispatched

echo "# every systemd unit this project installs must also be uninstalled"
# Four units are installed today — tune, netmode, backup service and timer —
# and uninstall.sh removes all four. Nothing holds that together. A fifth unit
# added to an installer and forgotten here would survive 'uninstall.sh',
# keep running at every boot, and reference a directory the user believes they
# deleted. Units are the worst thing to leak because they are the one artefact
# that outlives the reboot.
#
# Same shape as the gate for settings baked into the WebUI container: derive
# the list from what the installers actually create, rather than maintaining a
# second copy of it here.
every_installed_unit_is_removed() {
  local unit leaked=0
  while read -r unit; do
    [[ -n "${unit}" ]] || continue
    grep -qF "${unit}" "${REPO}/uninstall.sh" || {
      printf 'something installs %s but uninstall.sh never removes it\n' "${unit}" >&2
      leaked=1
    }
  done < <(grep -rhoE 'local-code-agent[a-z-]*\.(service|timer)' \
             "${REPO}/setup.sh" "${REPO}"/scripts/*.sh "${REPO}/netmode.sh" \
             "${REPO}/backup.sh" 2>/dev/null | sort -u)
  return "${leaked}"
}
check "uninstall.sh removes every systemd unit the installers create" \
  every_installed_unit_is_removed

echo "# install.sh is piped into bash — a partial download must do nothing"
# It is advertised as 'curl -fsSL ... | bash', which streams the file and runs
# each statement as it arrives. A connection dropping part-way would otherwise
# execute a PARTIAL installer: far enough to install git and create the target
# directory, not far enough to clone or hand over to setup.sh, and it would
# leave that half-state behind without an error. Wrapped in main() called on
# the last line, a truncated download never reaches the call.
install_is_truncation_safe() {
  local src="${REPO}/install.sh"
  grep -qE '^main\(\) \{' "${src}" || {
    echo "install.sh has no main() wrapper — a truncated curl|bash would run a partial installer" >&2
    return 1
  }
  # The call must be the LAST statement, or the wrapper buys nothing. The
  # trailing 'exit $?' is part of it — see the self-rewrite gate below — and it
  # costs this one nothing: a truncation landing inside those last few bytes
  # means everything before the call did arrive, so calling main is right.
  [[ "$(grep -vE '^\s*(#|$)' "${src}" | tail -1)" == 'main "$@"; exit $?' ]] || {
    echo "install.sh does not end with main \"\$@\"; exit \$? — the wrapper is not the last thing that runs" >&2
    return 1
  }
  # And nothing may execute at top level between the wrapper and the call.
  awk '/^main\(\) \{/ { seen = 1 }
       seen && /^\}/   { closed = 1; next }
       closed && !/^[[:space:]]*(#|$)/ && !/^main "\$@"; exit \$\?$/ { bad = 1 }
       END { exit bad }' "${src}" || {
    echo "install.sh runs something at top level after main() — a partial download could reach it" >&2
    return 1
  }
}
check "install.sh runs nothing if the curl|bash download is truncated" \
  install_is_truncation_safe
# A clone can exit 0 and still not be this project — wrong fork in
# LCA_REPO_URL, or an LCA_BRANCH predating the code. Observed by accident here
# against a stale local 'main' holding only a README: git succeeded, the
# installer said "Clone complete", and there was no setup.sh to run.
install_verifies_the_clone() {
  # The EXISTENCE TEST, not any mention of setup.sh. The first version grepped
  # for the path and passed with the guard replaced by 'true', because the same
  # path appears in the failure message and in the closing "run it yourself"
  # hint. A grep that matches the thing you are describing rather than the
  # thing you are testing is the recurring way a gate here stops gating.
  grep -qE '\[\[ -f "\$\{INSTALL_DIR\}/setup\.sh" \]\]' "${REPO}/install.sh" || {
    echo "install.sh trusts git's exit status instead of checking it got the project" >&2
    return 1
  }
}
check "install.sh checks the clone actually contains the project" \
  install_verifies_the_clone

echo "# 'lca ask' must bound its TOTAL context, not just each piece of it"
# Every context source in ask.sh is capped, each with a comment saying it is so
# that one source "cannot blow the whole context window". Nothing capped the
# sum, and the caps add up to ~54,000 characters — roughly 13,500 tokens —
# against the 4,096-token window the 3b rung runs with on a base droplet.
# Piped input alone (12,000 chars) already exceeded the usable budget there.
#
# Ollama truncates an over-long prompt from the FRONT, which is where the
# system prompt sits. So the failure mode is the assistant quietly losing its
# own instructions and answering like a stock model — on
# 'lca logs | lca ask "why did this fail?"', which README.md and
# TROUBLESHOOTING.md both recommend as the way to diagnose a broken box.
ask_bounds_the_whole_context() {
  local src="${REPO}/scripts/ask.sh"
  # The budget must derive from the model's window and account for the system
  # prompt, not be a constant someone guessed.
  grep -q 'budget_chars=' "${src}" || {
    echo "ask.sh computes no total context budget" >&2; return 1
  }
  grep -qE 'budget_chars=.*ctx_tokens' "${src}" || {
    echo "ask.sh's context budget ignores the model's context length" >&2; return 1
  }
  grep -qE 'budget_chars=.*\$\{#system\}' "${src}" || {
    echo "ask.sh's context budget ignores the size of the system prompt" >&2; return 1
  }
  # It must actually trim...
  grep -qE 'context="\$\{context: -budget_chars\}"' "${src}" || {
    echo "ask.sh never trims the context to its budget" >&2; return 1
  }
  # ...and never silently: losing context changes the answer.
  awk '/if \(\( \$\{#context\} > budget_chars \)\); then/ { inb = 1 }
       inb && /warn / { found = 1 }
       inb && /^  fi$/ { exit }
       END { exit !found }' "${src}" || {
    echo "ask.sh trims the context without telling anyone" >&2; return 1
  }
}
check "'lca ask' bounds its total context and says when it trims" \
  ask_bounds_the_whole_context

echo "# the venv interpreter's path must come from venv_python(), not be re-typed"
# venv_python() existed, was called by nothing, and two files built the same
# string by hand instead — install_python.sh deciding whether to reuse a venv,
# and check-system.sh deciding whether one exists. Harmless today and exactly
# the shape that has bitten this repo repeatedly: the helper is the single
# source of truth right up until the moment it is not, and then it is updated
# while the hand-rolled copies quietly keep the old layout.
venv_python_is_the_only_source() {
  local hits
  # The needle is written '/bin/pyth[o]n' so this line does not match itself.
  # A whole-file scan for a literal always finds the scanner — the same trap
  # that made the ci.yml gate flag its own explanatory comment, and that
  # tests/long-wait.awk hit before either. Excluding this file wholesale would
  # work and would also blind the check to the rest of it.
  hits="$(grep -rn '/bin/pyth[o]n' --include='*.sh' --include='lca' \
            "${REPO}" 2>/dev/null \
            | grep -v '/\.venv/' \
            | grep -v 'venv_python()' \
            | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
  [[ -z "${hits}" ]] || {
    printf 'these build the venv interpreter path by hand instead of calling venv_python():\n%s\n' \
      "${hits}" >&2
    return 1
  }
}
check "nothing re-types the venv interpreter path" venv_python_is_the_only_source

echo "# the README's privacy claim about the inbound guard must stay true"
# README's "How your services are kept private" states the guard is re-applied
# "whenever WebUI is (re)created". That is a security claim, and it rests on a
# single line in install_webui.sh. It matters more now than when it was
# written: 'lca apply' re-creates the container on every settings change, so
# this is the path that keeps ports 3000 and 11434 off the public internet
# after routine use, not just at install time.
#
# Delete that line and nothing fails, nothing logs, and the only symptom is an
# exposed port on someone's droplet.
webui_installer_applies_the_guard() {
  grep -qE 'netmode\.sh" harden' "${REPO}/scripts/install_webui.sh" || {
    echo "install_webui.sh no longer applies the inbound guard — README claims it does" >&2
    return 1
  }
  # And the README must still be making the claim this guards; if the sentence
  # goes, the test should be re-examined rather than silently protecting a
  # promise nobody makes any more.
  grep -qi 'whenever WebUI is' "${REPO}/README.md" || {
    echo "README no longer claims the guard is re-applied when WebUI is re-created" >&2
    return 1
  }
}
check "install_webui.sh re-applies the inbound guard, as the README promises" \
  webui_installer_applies_the_guard

echo "# 'lca update' must re-run setup even when the checkout is already current"
# The delivery chain for any assistant fix is: update -> setup.sh ->
# install_webui.sh rebuilds the container -> selftest checks the live prompt.
# Re-running setup is unconditional, and that is load-bearing rather than
# wasteful: the documented recovery for a stale chat is 'git pull' followed by
# apply/update, so by the time update runs, 'behind' is already 0. Skipping
# setup in that case would read as an obvious optimisation and would silently
# break the exact path the docs send people down.
update_reruns_setup_unconditionally() {
  # Two spaces of indent: at the top level of main(), not nested inside the
  # 'behind != 0' branch (which would put it at four).
  grep -qE '^  step "Re-running setup"' "${REPO}/update.sh" || {
    echo "update.sh only re-runs setup conditionally — a hand-pulled fix would not be applied" >&2
    return 1
  }
  # ...and the verification after it must be the self-test, which since today
  # is what notices a stale assistant prompt.
  awk '/step "Re-running setup"/ { seen = 1 }
       seen && /selftest\.sh/ { found = 1 }
       END { exit !found }' "${REPO}/update.sh" || {
    echo "update.sh does not verify with selftest.sh after re-running setup" >&2
    return 1
  }
}
check "'lca update' re-runs setup unconditionally, then self-tests" \
  update_reruns_setup_unconditionally

echo "# CI's e2e must compare the WHOLE prompt, not a substring of it"
# The only end-to-end proof that the assistant's instructions reach a real
# container is a step in ci.yml. It asserted `.system | test("local-code-agent")`
# — satisfied by every version of the prompt that has ever existed, including
# the one that made a real user's chat invent a tool call. It proved the
# container had A prompt, never that it had THIS one, which is the only failure
# that has actually occurred here.
ci_compares_the_whole_prompt() {
  local ci="${REPO}/.github/workflows/ci.yml"
  grep -q 'want_prompt=' "${ci}" || {
    echo "ci.yml no longer builds the expected prompt to compare against" >&2
    return 1
  }
  grep -qF 'lca_system_prompt' "${ci}" || {
    echo "ci.yml does not derive the expectation from lca_system_prompt" >&2
    return 1
  }
  # Comment lines stripped first. The comment ABOVE the fixed assertion quotes
  # the broken one to explain why it was replaced, and a whole-file grep read
  # that as the bug still being present — tests/long-wait.awk had to learn the
  # same lesson about reading its own explanation as evidence.
  if grep -vE '^[[:space:]]*#' "${ci}" | grep -qF 'test("local-code-agent")'; then
    echo "ci.yml is back to asserting the prompt by substring — any stale prompt passes that" >&2
    return 1
  fi
}
check "CI compares the container's prompt with this repo's, byte for byte" \
  ci_compares_the_whole_prompt

echo "# 'lca test' must not call a stale assistant 'works end-to-end'"
# The self-test's 4th check was "does the HTTP port answer". The only real bug
# report ever filed against this project was a box where Ollama, the model,
# aider, Tailscale and the WebUI were all fine and the ASSISTANT was wrong —
# so this test would have printed "SELF-TEST PASSED — your stack works
# end-to-end" to the person filing it. That is the worst thing a test can do:
# vouch for the exact thing that is broken.
selftest_checks_the_live_prompt() {
  awk '/step "4\/4 Open WebUI"/ { seen = 1 }
       seen && /DEFAULT_MODEL_PARAMS|webui_drift/ { found = 1 }
       END { exit !found }' "${REPO}/scripts/selftest.sh" || {
    echo "selftest.sh never checks which assistant prompt the chat app is running" >&2
    return 1
  }
  # ...and an unreadable value must not be reported as a pass. "Cannot look"
  # and "fine" are different answers, and this file already learned that the
  # hard way for docker probes.
  grep -q 'skipped, not passed' "${REPO}/scripts/selftest.sh" || {
    echo "selftest.sh does not distinguish 'could not check' from 'passed'" >&2
    return 1
  }
}
check "'lca test' checks the chat app's assistant prompt is current" \
  selftest_checks_the_live_prompt

echo "# a restore replaces .env wholesale — the system must be reconciled with it"
# Every other member of the applied-settings class was found by someone editing
# one key. Restore changes ALL of them at once, and nothing in it re-rendered
# the Ollama drop-in; the chat app container was rebuilt only when the backup
# happened to contain its volume. So a recovery could complete, report success,
# and leave the box running settings the user had just replaced — during the
# one operation whose entire purpose is "put it back how it was".
restore_reconciles_with_apply() {
  # Scoped to after the .env restore, so this cannot be satisfied by an
  # unrelated mention of apply somewhere earlier in the file.
  awk '/^  # 1\. \.env/ { seen = 1 }
       seen && /scripts\/apply\.sh/ { found = 1 }
       END { exit !found }' "${REPO}/restore.sh" || {
    echo "restore.sh never reconciles the running system with the .env it restored" >&2
    return 1
  }
}
check "restore.sh applies the .env it just restored" restore_reconciles_with_apply
# ...and says the restored model came from the BACKUP's machine. The commonest
# reason to restore is moving to different hardware — docs/MIGRATE.md is about
# exactly that — so the restored MODEL_NAME and context are the old VM's, and
# auto-tune does not re-pick until the next boot. Nothing said so, which left a
# documented migration running the droplet's small model on a big new box for
# no reason anyone could see.
# The three behavioural tests below drive machine_advice() directly, which is
# stronger than any grep — but they would all still pass if main() stopped
# calling it. So this asserts the call, and nothing about the wording.
#
# It replaces a version that searched for the literal 'lca tune' after the .env
# section, which broke the moment that message moved into a function defined
# further up. It was guarding a position, not a behaviour.
restore_asks_for_the_advice() {
  # Bounded at main's closing brace, and blind to comments. The first version
  # set 'inmain' and never cleared it, so the comment BELOW main explaining
  # why the file is sourceable — which names the function — satisfied it. The
  # call could be deleted outright and the gate stayed green.
  awk '/^main\(\) \{/       { inmain = 1; next }
       inmain && /^\}/      { inmain = 0 }
       inmain && /^[[:space:]]*#/ { next }
       inmain && /machine_advice/ { found = 1 }
       END { exit !found }' "${REPO}/restore.sh" || {
    echo "restore.sh no longer asks whether the restored .env suits this machine" >&2
    return 1
  }
}
check "restore.sh checks the restored .env against this machine" \
  restore_asks_for_the_advice
# ...and the advice must be RIGHT, not merely present. backup.sh now records
# the source machine, so restore can compare instead of guessing — the earlier
# version told everyone to re-tune, including people restoring onto the same
# box, which is the kind of advice people learn to skip.
#
# Driven directly: a real restore overwrites .env and the WebUI volume, so the
# comparison lives in its own function and restore.sh is sourceable.
advice_for() {  # META_CONTENT_OR_EMPTY — the message restore would print
  local meta="${SANDBOX}/meta-fixture"
  if [[ -n "$1" ]]; then printf '%s\n' "$1" > "${meta}"; else rm -f "${meta}"; fi
  bash -c '
    source "$1" >/dev/null 2>&1
    detect_ram_gib() { echo 16; }          # this machine, for the comparison
    MODEL_NAME=qwen2.5-coder:7b
    OLLAMA_CONTEXT_LENGTH=8192
    machine_advice "$2" 2>&1
  ' _ "${REPO}/restore.sh" "${meta}"
}
same_machine_is_quiet() {
  local out; out="$(advice_for 'ram_gib=16
model=qwen2.5-coder:7b')"
  grep -q 'agree on RAM' <<<"${out}" || { printf 'got: %s\n' "${out}" >&2; return 1; }
  # Must NOT nag someone who restored onto the same hardware.
  if grep -q 'lca tune' <<<"${out}"; then
    printf 'told an unchanged machine to re-tune: %s\n' "${out}" >&2; return 1
  fi
}
different_machine_is_told() {
  local out; out="$(advice_for 'ram_gib=8
model=qwen2.5-coder:3b')"
  grep -q 'lca tune' <<<"${out}" || { printf 'got: %s\n' "${out}" >&2; return 1; }
  # And the message must carry BOTH sizes, or it cannot be acted on.
  grep -q '8 GiB' <<<"${out}" && grep -q '16 GiB' <<<"${out}"
}
old_backup_gets_conditional_advice() {
  # No meta at all: a backup taken before this existed. "Cannot tell" is not
  # "they match" — the same distinction the docker probes had to learn.
  local out; out="$(advice_for '')"
  grep -q 'lca tune' <<<"${out}" || { printf 'got: %s\n' "${out}" >&2; return 1; }
  grep -qi 'predates' <<<"${out}"
}
check "restoring onto the same machine does not nag about tuning" \
  same_machine_is_quiet
check "restoring onto different RAM names both sizes and says to re-tune" \
  different_machine_is_told
check "a backup with no machine details gets conditional advice, not silence" \
  old_backup_gets_conditional_advice
# backup.sh must actually record what restore.sh reads, or the comparison above
# silently degrades to the "old backup" branch for every new backup.
backup_records_the_machine() {
  local key
  for key in ram_gib model context; do
    grep -qE "printf '${key}=" "${REPO}/backup.sh" || {
      printf 'backup.sh does not record %s, which restore.sh reads\n' "${key}" >&2
      return 1
    }
  done
}
check "backup.sh records the machine details restore.sh compares" \
  backup_records_the_machine
# A command printed in a doc is a command being shipped. The first version of
# the "read the metadata" snippet in docs/BACKUPS.md globbed the backups
# directory — which works with exactly one backup and silently prints nothing
# with two, because tar takes the second archive as a member name to extract
# from the first. BACKUP_KEEP defaults to 7, so the broken case is the normal
# one; it only looked right because this box had a single backup at the time.
docs_read_backups_safely() {
  local hit
  while IFS= read -r hit; do
    [[ -n "${hit}" ]] || continue
    printf 'a doc globs multiple backup archives into one tar invocation:\n  %s\n' \
      "${hit}" >&2
    return 1
  done < <(grep -rn 'tar .*backup-\*\.tar\.gz' "${REPO}/docs" "${REPO}/README.md" \
             2>/dev/null | grep -v 'ls -t' || true)
}
check "no doc feeds a multi-archive glob to tar" docs_read_backups_safely
# Same glob, different command, milder consequence — and worth stopping anyway.
# 'scp remote:.../backup-*.tar.gz .' works, in the sense that it copies every
# retained archive. With BACKUP_KEEP=7 and the WebUI volume inside each one,
# that is potentially gigabytes crossing the wire on a migration where the user
# asked for the single backup they had just taken. Deliberate is fine; by
# accident is not.
docs_copy_one_backup_not_all() {
  local hit
  while IFS= read -r hit; do
    [[ -n "${hit}" ]] || continue
    printf 'a doc scp-s a backup glob, which copies every retained archive:\n  %s\n' \
      "${hit}" >&2
    return 1
  # Only a glob on the REMOTE side of the colon, which the remote shell expands
  # against a backups/ directory holding up to BACKUP_KEEP archives. A glob on
  # the local side is a different thing: it runs on the user's own machine,
  # where the migration flow has put exactly the one file they downloaded, and
  # flagging it would be a false positive on correct instructions.
  done < <(grep -rnE 'scp [^ ]*:[^ ]*backup-\*\.tar\.gz' \
             "${REPO}/docs" "${REPO}/README.md" 2>/dev/null || true)
}
check "no doc copies every backup when it means the newest" \
  docs_copy_one_backup_not_all

echo "# the one mechanism that delivers a new prompt to an existing install"
# Everything about improving the assistant is worthless if an improvement
# cannot reach a droplet that is already running. Exactly one thing carries it:
# install_webui.sh REMOVES the existing container and rebuilds it, so a repo
# update followed by 'lca update' (setup.sh -> install_webui.sh) re-bakes the
# current prompt in. 'lca apply' does the same on demand.
#
# An "optimisation" that skipped the rebuild when the container already exists
# would look entirely reasonable, pass every other test, and silently stop
# every future prompt and setting change from reaching anyone who had already
# installed. That is this repo's signature failure, on its most important path.
installer_recreates_rather_than_skipping() {
  local blk
  blk="$(awk '/if as_root docker container inspect/ { inb = 1 }
              inb { print }
              inb && /^  fi$/ { exit }' "${REPO}/scripts/install_webui.sh")"
  [[ -n "${blk}" ]] || {
    echo "install_webui.sh no longer has an existing-container branch" >&2
    return 1
  }
  grep -q 'docker rm -f' <<<"${blk}" || {
    echo "install_webui.sh does not remove the existing container — a new prompt would never reach an existing install" >&2
    return 1
  }
  # ...and it must not bail out early instead of rebuilding.
  if grep -qE '(return|exit) 0' <<<"${blk}"; then
    echo "install_webui.sh returns early when the container exists — updates would not be delivered" >&2
    return 1
  fi
}
check "install_webui.sh rebuilds an existing container instead of skipping it" \
  installer_recreates_rather_than_skipping
# ...and setup.sh must actually call it, since 'lca update' delivers changes
# only by way of setup.sh.
setup_calls_the_webui_installer() {
  grep -qE '\$\{SCRIPT_DIR\}/scripts/install_webui\.sh' "${REPO}/setup.sh"
}
check "setup.sh runs install_webui.sh, so 'lca update' carries prompt changes" \
  setup_calls_the_webui_installer

echo "# 'make lint' claims to be the same invocation as CI — check that"
# The Makefile's whole promise is "run this before pushing and your change
# matches CI". That rests on two hand-maintained glob lists, in two files, and
# nothing compared them. Add a directory of scripts to one and the local gate
# and the remote gate quietly stop covering the same files — with the local one
# passing, which is the direction that hurts.
make_lint_matches_ci() {
  local mk ci
  # Trimmed with parameter expansion, not sed. A literal '$(' inside single
  # quotes reads to ShellCheck as an expansion someone forgot to double-quote
  # (SC2016) — the same trap as a matched pair of backticks, already recorded
  # in CONTRIBUTING.md. Expansion has no such problem.
  mk="$(grep -oE '^SCRIPTS := .*' "${REPO}/Makefile" | head -1)"
  mk="${mk#*wildcard }"
  mk="${mk%)}"
  ci="$(grep -oE 'shellcheck -x -P SCRIPTDIR .*$' "${REPO}/.github/workflows/ci.yml" \
          | head -1 | sed 's/^shellcheck -x -P SCRIPTDIR //')"
  [[ -n "${mk}" ]] || { echo "cannot find SCRIPTS in the Makefile" >&2; return 1; }
  [[ -n "${ci}" ]] || { echo "cannot find the shellcheck step in ci.yml" >&2; return 1; }
  [[ "${mk}" == "${ci}" ]] || {
    printf 'make lint covers:  %s\nCI lints:          %s\n' "${mk}" "${ci}" >&2
    return 1
  }
}
check "'make lint' lints exactly the files CI lints" make_lint_matches_ci

echo "# the Makefile's header comment and its real targets must agree"
# The header lists targets by hand; 'make help' derives them from the '##'
# comments. Two sources for one fact, and adding 'bench' meant editing both —
# the kind of pair that silently diverges and leaves the header describing a
# target that no longer exists, or hiding one that does.
makefile_header_matches_targets() {
  local real listed stray
  # Real targets: anything with a '## ' help string, which is what make help shows.
  real="$(grep -oE '^[a-z-]+:.*## ' "${REPO}/Makefile" | cut -d: -f1 | sort -u)"
  # Listed: the 'make <target>' lines in the header comment block.
  listed="$(grep -oE '^#   make [a-z-]+' "${REPO}/Makefile" \
              | awk '{print $3}' | sort -u)"
  [[ -n "${real}" && -n "${listed}" ]] || {
    echo "could not read targets out of the Makefile" >&2; return 1
  }
  stray="$(comm -3 <(printf '%s\n' "${real}") <(printf '%s\n' "${listed}"))"
  [[ -z "${stray}" ]] || {
    printf 'the Makefile header and its real targets disagree:\n%s\n' "${stray}" >&2
    return 1
  }
}
check "the Makefile documents exactly the targets it has" \
  makefile_header_matches_targets

echo "# the README's file tree must list every script that exists"
# It had drifted by five: apply.sh, ask.sh, logs.sh, speed.sh and motd.sh were
# all shipped, all user-facing, and none of them appeared in the tree a reader
# uses to find out what this repo contains. A listing that is quietly a subset
# is worse than none — it reads as complete.
readme_tree_lists_every_script() {
  local f base undocumented=0
  for f in "${REPO}"/scripts/*.sh; do
    base="$(basename "${f}")"
    grep -qF "${base}" "${REPO}/README.md" || {
      printf 'scripts/%s exists but the README never mentions it\n' "${base}" >&2
      undocumented=1
    }
  done
  return "${undocumented}"
}
check "the README mentions every script in scripts/" readme_tree_lists_every_script

echo "# scripts/prompt-bench.sh — its classifiers decide every future verdict"
# The bench needs a running model, so CI cannot run it end to end. But its
# matchers are what turn a generation into a number, and a wrong matcher makes
# every future prompt measurement wrong in a way nobody would notice — this
# already happened twice by hand: a success pattern that missed "run lca in
# your project directory", and a tutorial detector that counted our own
# recipe's 'mkdir' as evidence of a doomed walkthrough.
#
# The script is sourceable precisely so these can be exercised without a model.
# Run in a child bash so its argument parsing never sees this file's "$@".
bench_matcher() {
  local fn="$1" want="$2" text="$3" got
  got="$(bash -c '
    source "$1" >/dev/null 2>&1
    if "$2" "$3"; then echo yes; else echo no; fi
  ' _ "${REPO}/scripts/prompt-bench.sh" "${fn}" "${text}" 2>/dev/null || echo error)"
  [[ "${got}" == "${want}" ]] || {
    printf '%s("%s") = %s, wanted %s\n' "${fn}" "${text:0:48}" "${got}" "${want}" >&2
    return 1
  }
}
if have jq && have curl; then
  check "bench: bare 'lca' counts as handing over" \
    bench_matcher hands_over yes 'run: mkdir -p ~/x && cd ~/x && lca'
  # The distinction the whole prompt fix rests on: 'lca ask' writes no files,
  # so an answer offering it has NOT handed the job over.
  check "bench: 'lca ask' does not count as handing over" \
    bench_matcher hands_over no 'use lca ask to query the model'
  check "bench: a terminal/SSH mention counts as saying where" \
    bench_matcher says_where yes 'run it in a terminal on the server'
  check "bench: ordinary prose does not count as saying where" \
    bench_matcher says_where no 'here is some python code'
  check "bench: the recipe counts as the handover firing" \
    bench_matcher hijacked yes 'mkdir -p ~/my-project && cd ~/x && lca'
  # 'lca backup' is the RIGHT answer to a backup question, not a hijack.
  check "bench: 'lca backup' is not the handover firing" \
    bench_matcher hijacked no 'you can use lca backup for that'
  check "bench: numbered setup steps are a tutorial" \
    bench_matcher is_tutorial yes '1. run npm init
2. then pip install flask'
  # ...and a handover written AS numbered steps is not, though it contains
  # 'mkdir'. This is the case that matters and the one that actually happened:
  # a 7b answer laid the recipe out as steps, the detector saw numbering plus
  # 'mkdir', and scored the fix as the very failure it had removed.
  #
  # The first version of this test used the bare recipe with no numbering. It
  # passed with the strip deleted — the numbered-steps half already returned
  # false, so the strip was never reached and the test could not fail.
  check "bench: a handover written as numbered steps is not a tutorial" \
    bench_matcher is_tutorial no '1. Open a terminal on the server
2. Run: mkdir -p ~/my-project && cd ~/my-project && lca'
else
  echo "skip - curl/jq missing, cannot source prompt-bench.sh"
fi
# The recipe now exists in three places: the prompt, docs/PHONE.md and
# docs/TROUBLESHOOTING.md. Three copies of a command line is how a doc comes to
# teach something that no longer works — and this exact line already shipped
# broken once. Any doc line SHAPED like the recipe is claiming to be it, so it
# must be byte-identical to what the prompt actually emits. A doc that does not
# mention it at all is free to stay silent.
docs_show_the_prompt_recipe() {
  local want line recipe_mismatch=0
  want="$(lca_system_prompt | grep -E "${HANDOVER_LINE}" | head -1 \
            | sed 's/^[[:space:]]*//')"
  [[ -n "${want}" ]] || { echo "the prompt emits no recipe at all" >&2; return 1; }
  while IFS= read -r line; do
    if [[ -n "${line}" && "${line}" != "${want}" ]]; then
      printf 'a doc teaches a recipe the prompt does not emit:\n  doc:    %s\n  prompt: %s\n' \
        "${line}" "${want}" >&2
      recipe_mismatch=1
    fi
  done < <(grep -rhE "${HANDOVER_LINE}" "${REPO}/README.md" "${REPO}"/docs/*.md 2>/dev/null \
             | sed 's/^[[:space:]]*//' || true)
  return "${recipe_mismatch}"
}
check "every doc that shows the handover recipe shows the real one" \
  docs_show_the_prompt_recipe
# The same rule for the recipe PRINTED by a script. 'lca chat' now tells the
# reader how to reach a terminal and what to type once they get there, and a
# .sh file is invisible to the doc gate above — so that copy could drift back
# to the form that fails while every other check stayed green.
#
# Scoped to output (info/ok/warn/echo/printf), because run-agent.sh's header
# comment documents its own long-path invocation, which is a different command
# and not a stale copy of this one.
printed_recipe_matches_the_prompt() {
  local want hit recipe_drift=0
  want="$(lca_system_prompt | grep -E "${HANDOVER_LINE}" | head -1 \
            | sed 's/^[[:space:]]*//')"
  [[ -n "${want}" ]] || return 1
  while IFS= read -r hit; do
    [[ -n "${hit}" ]] || continue
    grep -qF -- "${want}" <<<"${hit}" || {
      printf 'a script prints a recipe the prompt does not emit:\n  %s\n  prompt: %s\n' \
        "${hit}" "${want}" >&2
      recipe_drift=1
    }
  done < <(grep -rn 'my-project && ' "${REPO}"/*.sh "${REPO}"/scripts/*.sh 2>/dev/null \
             | grep -E '(info|ok|warn|echo|printf) ' || true)
  return "${recipe_drift}"
}
check "every recipe a script prints matches the prompt's" \
  printed_recipe_matches_the_prompt
# Naming the command is not the same as getting it said, and the gap between
# those two was measured rather than guessed. Against the real 3b model — the
# rung a base 8 GB droplet runs — on the user's own request ("build me a whole
# functioning income and expense tracker app"):
#
#   abstract phrasing, "when a request needs files created or edited"
#     handover 1/4   led with it 0/4   generic multi-file tutorial 3/4
#   the user's own verbs + "Open with exactly:"
#     handover 4/4   led with it 4/4   generic multi-file tutorial 0/4
#
# Same information, same length, opposite outcome. The tutorial is the failure
# the user actually reported: a 3b model confidently starts a React/Express
# project it has no way to finish, and truncates mid-file.
#
# So both halves are load-bearing and both are asserted, scoped to the lines
# immediately around the recipe — the file says "Lead with the answer" further
# up for an unrelated reason, and a whole-file grep would pass on that and
# guard nothing.
prompt_leads_with_the_handover() {
  lca_system_prompt | awk -v pat="${HANDOVER_LINE}" '
    { hist[NR] = tolower($0) }
    $0 ~ pat {
      for (i = NR - 6; i < NR; i++) {
        if (hist[i] ~ /build|create|make/)                 verb = 1
        if (hist[i] ~ /open with|start with|begin with|first line/) pos = 1
      }
    }
    END { exit !(verb && pos) }'
}
check "the prompt names the trigger in the user's verbs, and says to lead with it" \
  prompt_leads_with_the_handover
# A trigger strong enough to beat a 3b model's tutorial reflex overshoots. On
# the real model, "how do I take a backup right now?" was answered by LEADING
# with the aider recipe 1 time in 3 — which also contradicted the claim in
# docs/PERFORMANCE.md that 3b answers that question with 'lca backup'.
#
# The cure was the same trick as the disease: a concrete counter-example, not
# an abstract qualifier. Naming the operational questions explicitly took the
# hijack to 0/4 while build-app stayed at 4/4 and 'lca backup' came back 5/5
# with no tar lecture. Identical on 7b (4/5 handover, 0/5 tutorial, unchanged
# from the unguarded prompt), so the exception is asserted, not the sentence.
# Asserted per PARAGRAPH, not per line. The first version required the
# examples and the exclusion on one line, and the prompt wraps — so it failed
# on text that says exactly the right thing. What must hold is that wherever
# the examples are named, they are named AS an exception; the line breaks are
# the author's business.
prompt_excludes_server_questions() {
  lca_system_prompt | awk 'BEGIN { RS = "" }
    { p = tolower($0) }
    p ~ /backup/ && (p ~ /speed/ || p ~ /logs/) &&
    (p ~ /are not/ || p ~ /never send/ || p ~ /not that/) { found = 1 }
    END { exit !found }'
}
check "the prompt excludes server questions from the handover" \
  prompt_excludes_server_questions
# 'lca apply' is the remedy for the entire applied-settings class — a setting
# edited but not in effect — and the chat is exactly where someone asks "I
# changed .env and nothing happened". It could not name it: the command was
# absent from the prompt's own list. Added and measured: 4/4 on that question,
# where it was 0/4 before because the model had never been told it exists.
prompt_names_the_apply_command() {
  lca_system_prompt | grep -qE "^[[:space:]]*lca apply[[:space:]]"
}
check "the prompt names 'lca apply', the fix for every applied setting" \
  prompt_names_the_apply_command

echo "# set_env_var survives a value with spaces (BACKUP_SCHEDULE is one)"
# Written unquoted, "*-*-* 05:00:00" makes .env unsourceable and the variable
# reads back EMPTY. tune.sh writes .env on every boot, so this must be safe.
set_env_var BACKUP_SCHEDULE "*-*-* 05:00:00"
# Re-source the file in a subshell and echo one value back. Stronger than
# reading the current globals: it proves the FILE is still sourceable, which is
# exactly what an unquoted spaced value destroys.
# Sourced inside a child bash rather than in this shell: with -x, ShellCheck
# tries to FOLLOW a literal 'source'/'.' and errors when the target does not
# exist at lint time (SC1091). ".env" happens to exist in a developer's
# checkout but never in CI, so the inline form lints clean locally and fails
# there — the worst kind of difference. A quoted 'bash -c' is opaque to that
# analysis, and running in a real child process is a stricter check anyway.
env_value() {
  bash -c 'set -a; . "$1" >/dev/null 2>&1; set +a; printf "%s" "${!2-}"' _ "${SANDBOX}/.env" "$1"
}
check "a spaced value round-trips intact" \
  test "$(env_value BACKUP_SCHEDULE)" = "*-*-* 05:00:00"
check "and .env is still sourceable afterwards" test -n "$(env_value MODEL_NAME)"
# Every write made by today's callers must stay byte-identical — quoting only
# kicks in for whitespace, so the boot path's output cannot change.
set_env_var MODEL_NAME "qwen2.5-coder:7b"
check "an unspaced value is still written bare" \
  grep -qx 'MODEL_NAME=qwen2.5-coder:7b' "${SANDBOX}/.env"
# A value that could not survive the round-trip is refused, not mangled.
# The '$' is built from a variable so the literal does not sit inside single
# quotes, which reads to ShellCheck as an expansion someone forgot (SC2016).
refuses() { ! set_env_var TEST_KEY "$1" >/dev/null 2>&1; }
DOLLAR='$'
check "a value containing a quote is refused" refuses 'has"quote'
check "a value containing a dollar sign is refused" refuses "has${DOLLAR}dollar"
set_env_var BACKUP_SCHEDULE "*-*-* 03:30:00"

echo "# sync_env_keys() backfills settings an old install predates"
# .env is created from .env.example once and never updated, so an install made
# before a setting existed cannot see it. Simulate that by deleting keys.
cp "${SANDBOX}/.env" "${SANDBOX}/.env.before"
grep -vE '^(BACKUP_SCHEDULE|MODEL_FAMILY|LCA_ASK_TOKENS)=' "${SANDBOX}/.env.before" > "${SANDBOX}/.env"
sync_env_keys >/dev/null 2>&1
check "a missing key is added" grep -qE '^MODEL_FAMILY=' "${SANDBOX}/.env"
# BACKUP_SCHEDULE contains spaces, so this only works because set_env_var
# quotes such values — the bug fixed one commit earlier was not latent at all
# once anything appended that key.
check "a spaced key is added intact" \
  test "$(env_value BACKUP_SCHEDULE)" = "*-*-* 03:30:00"
check "and .env is still sourceable" test -n "$(env_value MODEL_NAME)"
# The user's own choices must survive untouched.
set_env_var MODEL_NAME "qwen2.5-coder:14b"
sync_env_keys >/dev/null 2>&1
check "an existing value is never overwritten" \
  test "$(env_value MODEL_NAME)" = "qwen2.5-coder:14b"
# Running setup twice must not keep appending.
sync_env_before="$(md5sum < "${SANDBOX}/.env")"
sync_env_keys >/dev/null 2>&1
check "re-running changes nothing (idempotent)" \
  test "$(md5sum < "${SANDBOX}/.env")" = "${sync_env_before}"
set_env_var MODEL_NAME "qwen2.5-coder:7b"

echo "# every setting must exist in BOTH lib.sh's defaults and .env.example"
# A key defaulted in lib.sh but absent from .env.example is a real setting no
# user can discover. A key in .env.example with no lib.sh default means
# deleting that line silently changes behaviour, with no fallback behind it.
lib_default_keys() {
  sed -n '/^load_env()/,/^}/p' "${REPO}/scripts/lib.sh" \
    | sed -nE 's/^[[:space:]]*([A-Z_]+)="\$\{[A-Z_]+:-.*/\1/p' | sort -u
}
example_keys() { grep -oE '^[A-Z_]+=' "${REPO}/.env.example" | tr -d '=' | sort -u; }
undocumented_settings() { [[ -z "$(comm -23 <(lib_default_keys) <(example_keys))" ]]; }
unbacked_settings() { [[ -z "$(comm -13 <(lib_default_keys) <(example_keys))" ]]; }
check "every lib.sh default is documented in .env.example" undocumented_settings
check "every .env.example key has a lib.sh default" unbacked_settings
# ...and the two must agree on the VALUE, not merely on the key. Both lists
# currently match, but nothing held them together, and a divergence is exactly
# the kind that never reproduces: the box behaves one way with a .env present
# and another without one, or an install predating a key behaves differently
# from a fresh one. The comment above says a missing fallback "silently changes
# behaviour" — a fallback that disagrees with the documented default is the
# same failure with an extra step.
example_value() {  # KEY — the value .env.example ships, unquoted, comment-free
  grep -oE "^$1=.*" "${REPO}/.env.example" | head -1 \
    | sed -E "s/^$1=//; s/[[:space:]]+#.*\$//; s/^\"//; s/\"\$//"
}
defaults_agree_on_values() {
  local key libval exval mismatch=0
  while IFS='=' read -r key libval; do
    [[ -n "${key}" ]] || continue
    # Key-only parity is the two checks above; here, only shared keys matter.
    grep -qE "^${key}=" "${REPO}/.env.example" || continue
    exval="$(example_value "${key}")"
    if [[ "${libval}" != "${exval}" ]]; then
      printf 'default disagrees for %s: lib.sh falls back to %q, .env.example ships %q\n' \
        "${key}" "${libval}" "${exval}" >&2
      mismatch=1
    fi
  done < <(sed -n '/^load_env()/,/^}/p' "${REPO}/scripts/lib.sh" \
             | sed -nE 's/^[[:space:]]*([A-Z_]+)="\$\{[A-Z_]+:-(.*)\}"$/\1=\2/p')
  return "${mismatch}"
}
check "lib.sh's fallback and .env.example agree on every value" \
  defaults_agree_on_values

echo "# warm_model() is best-effort and must never fail or block its caller"
# It runs at the end of the boot oneshot. If it can fail, a warm-up that could
# not reach Ollama turns into a failed boot unit; if it can block, the unit
# sits for minutes (a bounded 300s wait was measured timing out with the model
# still unloaded, which is why this is detached rather than merely patient).
warm_is_best_effort() {
  ( OLLAMA_HOST="127.0.0.1:59999"; MODEL_NAME="not-a-real-model:1b"
    warm_model >/dev/null 2>&1 )
}
check "warm_model succeeds when Ollama is unreachable" warm_is_best_effort
warm_returns_promptly() {
  local t0="${SECONDS}"
  ( OLLAMA_HOST="127.0.0.1:59999"; warm_model >/dev/null 2>&1 )
  (( SECONDS - t0 < 5 ))
}
check "warm_model returns promptly" warm_returns_promptly
# Structural: the request must stay backgrounded. Losing the '&' is the one
# edit that would silently reintroduce a multi-minute stall at boot, and no
# behavioural test catches it without a host that accepts and never answers.
# '[[:space:]]' not '\s' — awk has no \s, and the first version of this check
# silently failed against correct code. Caught by mutation-testing it.
warm_is_detached() {
  awk '/^warm_model\(\)/ {f=1}
       f && /curl .*api\/generate/ {c=1}
       f && c && /&[[:space:]]*\)/ {ok=1}
       f && /^}/ {exit !ok}' "${REPO}/scripts/lib.sh"
}
check "warm_model backgrounds the request" warm_is_detached

echo "# a deliberately skipped component must not be reported as a problem"
# Adding a skip flag without teaching the health check about it produces an
# unfixable warning on a healthy box — the exact trap the auto-tune ladder had,
# where 'lca check' told MODEL_FAMILY users to run a script that was already
# right. Every SKIP_* must have a branch in check-system.sh that says "skipped"
# rather than "missing".
# -F with the needle built in a variable: the literal text is
#   "${SKIP_X}" == "true"
# and getting the quoting wrong here produces a check that fails against
# correct code, which is how the first version of this went.
skip_is_understood() {
  local needle="\"\${$1}\" == \"true\""
  grep -qF "${needle}" "${REPO}/check-system.sh"
}
check "check-system.sh understands SKIP_TAILSCALE" skip_is_understood SKIP_TAILSCALE
check "check-system.sh understands SKIP_DOCKER" skip_is_understood SKIP_DOCKER
# And the installer itself must honour it, or setup would install it anyway.
honours_skip() {
  local needle="\"\${SKIP_TAILSCALE}\" == \"true\""
  grep -qF "${needle}" "${REPO}/scripts/install_tailscale.sh"
}
check "install_tailscale.sh honours SKIP_TAILSCALE" honours_skip

echo "# the README's headline model list must match what the ladder can select"
# It claimed "3b/7b/14b/32b, auto-selected". 32b is not reachable at ANY RAM
# tier — the ladder tops out at 14b by design, with larger sizes left as a
# manual 'lca model' choice. A promise in the first table someone reads is the
# worst place for that to be wrong.
readme_sizes_match_ladder() {
  local claimed actual
  claimed="$(grep -oE 'The model family \([^)]*\)' "${REPO}/README.md" \
    | grep -oE '[0-9]+(\.[0-9]+)?b' | sort -u | tr '\n' ' ')"
  actual="$(family_sizes qwen2.5-coder | tr ' ' '\n' | sort -u | tr '\n' ' ')"
  [[ -n "${claimed}" && "${claimed}" == "${actual}" ]]
}
check "README's model sizes match family_sizes" readme_sizes_match_ladder

echo "# the RAM ladder must live in exactly one place"
# check-system.sh used to keep its own copy, hardcoded to qwen2.5-coder. It
# drifted the moment MODEL_FAMILY existed: a qwen3 user was told forever that
# their model differed from a qwen2.5-coder "recommendation", and to run the
# script that had just chosen it. Any second copy will rot the same way.
# Matched without a literal '${...}' in the pattern: that reads to ShellCheck
# as a variable someone forgot to expand (SC2016), and it is also less brittle
# about how the path to tune.sh happens to be written.
sources_the_real_ladder() { grep -qE '^[[:space:]]*source .*scripts/tune\.sh' "${REPO}/check-system.sh"; }
no_hardcoded_ladder() { ! grep -qE 'TUNE_MODEL="[a-z0-9.]+-?[a-z]*:' "${REPO}/check-system.sh"; }
check "check-system.sh sources tune.sh's ladder" sources_the_real_ladder
check "check-system.sh hardcodes no model in its ladder" no_hardcoded_ladder

# Sourcing tune.sh recomputes SCRIPT_DIR from tune.sh's own location, silently
# repointing the caller's at scripts/. Both callers restore it; if that restore
# is ever dropped, the next line added below the source resolves against the
# wrong directory and fails in a way that looks nothing like its cause.
restores_script_dir() {
  awk '/source .*scripts\/tune\.sh/ {seen=1; next} seen && /SCRIPT_DIR=/ {ok=1} END {exit !ok}' "$1"
}
check "check-system.sh restores SCRIPT_DIR after sourcing tune.sh" \
  restores_script_dir "${REPO}/check-system.sh"
check "update-model.sh restores SCRIPT_DIR after sourcing tune.sh" \
  restores_script_dir "${REPO}/update-model.sh"

echo "# 'lca help' must not advertise a command bin/lca cannot run"
# The same class of bug as the system-prompt check above, one layer out: help
# text drifts when a command is renamed, and a user following it gets "Unknown
# command". Aliases dispatched but deliberately left out of help (selftest,
# agent, code) are fine — this only checks help -> dispatch, not the reverse.
help_commands_all_real() {
  local sub bad=0
  while read -r sub; do
    [[ -n "${sub}" ]] || continue
    grep -qE "^[[:space:]]*[a-z|\"-]*\b${sub}\b[a-z|\"-]*\)" "${REPO}/bin/lca" || {
      printf 'lca help advertises a command bin/lca does not dispatch: %s\n' "${sub}" >&2
      bad=1
    }
  done < <("${REPO}/bin/lca" help 2>/dev/null | sed -n 's/^  lca \([a-z]\{1,\}\).*/\1/p' | sort -u)
  return "${bad}"
}
check "every command in 'lca help' is dispatched by bin/lca" help_commands_all_real
# ...and the other direction, which was never checked. A command you can run
# but cannot find is a feature nobody uses: 'lca harden' — re-apply the inbound
# guard that keeps ports 3000 and 11434 off the public internet — was
# dispatched and completely absent from the help, so the only way to learn it
# existed was to read bin/lca.
#
# Aliases and internal spellings are excluded by name, not by pattern, so
# adding one is a deliberate act rather than something a loose regex forgives.
dispatched_commands_are_all_documented() {
  local sub undocumented=0 helptext
  helptext="$("${REPO}/bin/lca" help 2>/dev/null)"
  while read -r sub; do
    [[ -n "${sub}" ]] || continue
    case "${sub}" in
      # 'selftest' is an alias for 'test'; 'online' is documented on the
      # 'lca offline|online' line, which the extractor below cannot see.
      selftest|online) continue ;;
    esac
    grep -qE "^  lca ${sub}\b" <<<"${helptext}" || {
      printf "bin/lca dispatches '%s' but 'lca help' never mentions it\\n" "${sub}" >&2
      undocumented=1
    }
  done < <(grep -oE '^  [a-z|]+\)' "${REPO}/bin/lca" | tr -d ' )' | tr '|' '\n' | sort -u)
  return "${undocumented}"
}
check "every command bin/lca dispatches appears in 'lca help'" \
  dispatched_commands_are_all_documented

echo "# the README's command table must not omit a command 'lca help' offers"
# The table is what someone scans to learn the tool, and it had drifted: five
# commands were missing, including 'lca backup' and 'lca restore' — the entire
# safety net was invisible to anyone reading the README. Same class as the
# 'lca help' -> dispatch check above, one layer further out.
# 'help' is excluded: a help command that documents itself in the table it
# prints is noise, not a contract.
readme_documents_every_command() {
  local sub bad=0 documented
  documented="$(sed -n '/^| Command | Does |/,/^$/p' "${REPO}/README.md" \
                 | grep -oE '`lca [a-z]+' | sed 's/^`lca //' | sort -u)"
  while read -r sub; do
    [[ -n "${sub}" && "${sub}" != "help" ]] || continue
    grep -qx -- "${sub}" <<<"${documented}" || {
      printf "'lca %s' is in 'lca help' but missing from the README table\\n" "${sub}" >&2
      bad=1
    }
  done < <("${REPO}/bin/lca" help 2>/dev/null | sed -n 's/^  lca \([a-z]\{1,\}\).*/\1/p' | sort -u)
  # A table that matched nothing would "pass" without checking anything.
  [[ -n "${documented}" ]] || { echo "no command table found in README.md" >&2; return 1; }
  return "${bad}"
}
check "the README table documents every 'lca help' command" \
  readme_documents_every_command

echo "# every setting in .env.example must be documented in the README"
# Same class as the command table above. This one caught its own author:
# SKIP_TAILSCALE was added to .env.example and lib.sh in an earlier change
# tonight and never reached the README's settings table, so the only way to
# discover it was to read .env.example — which is precisely what the table
# exists to save people from.
readme_documents_every_setting() {
  local key bad=0 documented
  # The backtick is built rather than written literally: a matched PAIR inside
  # single quotes reads to ShellCheck as a command substitution (SC2016).
  local bt; bt="$(printf '\140')"
  documented="$(grep -oE "^\| ${bt}[A-Z_]+${bt}" "${REPO}/README.md" | tr -d "|${bt} " | sort -u)"
  [[ -n "${documented}" ]] || { echo "no settings table found in README.md" >&2; return 1; }
  while read -r key; do
    [[ -n "${key}" ]] || continue
    grep -qx -- "${key}" <<<"${documented}" || {
      printf '%s is in .env.example but missing from the README settings table\n' "${key}" >&2
      bad=1
    }
  done < <(grep -oE '^[A-Z_]+=' "${REPO}/.env.example" | tr -d '=' | sort -u)
  return "${bad}"
}
check "the README documents every .env.example setting" \
  readme_documents_every_setting

echo "# starter questions for the phone chat match Open WebUI's expected shape"
SUGGESTIONS="${REPO}/config/prompt-suggestions.json"
check "prompt-suggestions.json exists" test -r "${SUGGESTIONS}"
# Wrapper so jq's own stdout is discarded without redirecting check()'s "ok"
# line into /dev/null along with it.
json_ok() { jq -e "$1" "$2" >/dev/null 2>&1; }
not_stock() { ! grep -qi "roman empire\|kids' art" "${SUGGESTIONS}"; }
if have jq; then
  check "prompt-suggestions.json is valid JSON" json_ok . "${SUGGESTIONS}"
  # Open WebUI reads a list of {title: [line1, line2], content: str}. A wrong
  # shape still parses as JSON and then renders as an empty start screen, so
  # validating the shape is the only thing that actually catches it.
  check "every suggestion has a 2-line title and content" json_ok \
    'type == "array" and length > 0 and all(
       (.title | type == "array" and length == 2 and all(type == "string"))
       and (.content | type == "string" and length > 0))' "${SUGGESTIONS}"
  check "suggestions are not Open WebUI's stock ones" not_stock
  # PHONE.md tells the reader how many starter questions they will see. It said
  # "four" for as long as there were five, because nothing tied the sentence to
  # the file — and that page is the one a phone user actually reads.
  #
  # Matched on the NUMBER before the phrase, not on the sentence around it, so
  # rewording the paragraph is free and changing the count is not.
  doc_count_matches_suggestions() {
    local n claimed
    local words=(zero one two three four five six seven eight nine ten)
    n="$(jq 'length' "${SUGGESTIONS}")"
    claimed="$(grep -oiE '(one|two|three|four|five|six|seven|eight|nine|ten|[0-9]+) starter question' \
                 "${REPO}/docs/PHONE.md" | head -1 | awk '{print tolower($1)}')"
    [[ -n "${claimed}" ]] || {
      echo "PHONE.md never says how many starter questions there are" >&2; return 1
    }
    # Written as a full if, not '(( ... )) && want=...'. Measured afterwards,
    # because the first version of this comment described the mechanism wrongly:
    # a false left side does NOT abort under 'set -e' — bash exempts every
    # command in an && list except the last. What it does is make the LIST
    # return 1, which matters only when the list is a function's final
    # statement, where it silently becomes the function's exit status. Here it
    # is not final, so the 'if' is defensive rather than required — but a later
    # edit that moves it to the end would turn a passing check into a failing
    # one with nothing to see.
    local want="${n}"
    if (( n <= 10 )); then want="${words[n]}"; fi
    [[ "${claimed}" == "${want}" || "${claimed}" == "${n}" ]] || {
      printf 'PHONE.md claims %s starter questions; the file has %s\n' \
        "${claimed}" "${n}" >&2
      return 1
    }
  }
  check "PHONE.md's starter-question count matches the file" \
    doc_count_matches_suggestions
fi

echo "# starting Ollama must not look like a hung terminal"
# 'lca speed' with Ollama down printed nothing at all for up to 60 seconds:
# ensure_ollama_up was called with every word suppressed. That is the least
# helpful possible response from the command people run when the box already
# feels slow, and 'lca ask' — the most-used command — did the same.
announces_slow_start() {
  local out
  out="$(bash -c '
    set -uo pipefail
    source "$1"
    wait_for_ollama()   { return 1; }   # never comes up
    ensure_ollama_up()  { return 1; }
    ensure_ollama_up_announced 7 2>&1 >/dev/null
  ' _ "${REPO}/scripts/lib.sh")"
  grep -q 'starting it' <<<"${out}" || {
    printf 'no notice while starting Ollama: %s\n' "${out}" >&2; return 1
  }
}
check "a slow Ollama start is announced" announces_slow_start
# ...on stderr, because in 'lca ask' stdout is the model's answer and a
# progress line must not end up inside a piped or redirected one.
announcement_avoids_stdout() {
  local on_stdout
  on_stdout="$(bash -c '
    set -uo pipefail
    source "$1"
    wait_for_ollama()  { return 1; }
    ensure_ollama_up() { return 1; }
    ensure_ollama_up_announced 7 2>/dev/null
  ' _ "${REPO}/scripts/lib.sh")"
  [[ -z "${on_stdout}" ]] || {
    printf 'progress notice leaked onto stdout: %s\n' "${on_stdout}" >&2; return 1
  }
}
check "the notice goes to stderr, keeping stdout clean" announcement_avoids_stdout
# Nothing at all when Ollama is already up — the normal case must stay silent.
silent_when_already_up() {
  local out
  out="$(bash -c '
    set -uo pipefail
    source "$1"
    wait_for_ollama() { return 0; }
    ensure_ollama_up_announced 7 2>&1
  ' _ "${REPO}/scripts/lib.sh")"
  [[ -z "${out}" ]] || {
    printf 'a healthy Ollama produced noise: %s\n' "${out}" >&2; return 1
  }
}
check "a healthy Ollama produces no notice" silent_when_already_up
# And the two commands that had the bug must use the announced form.
uses_announced_start() { grep -qF 'ensure_ollama_up_announced' "${REPO}/$1"; }
check "ask.sh announces a slow Ollama start"   uses_announced_start scripts/ask.sh
check "speed.sh announces a slow Ollama start" uses_announced_start scripts/speed.sh
# restore.sh waited 30 silent seconds at the very end of a recovery, and
# 'lca model --list' let ollama's own client error through — which says to run
# "ollama serve", the wrong instruction on a systemd box where the server is a
# managed service.
check "restore.sh announces a slow Ollama start"      uses_announced_start restore.sh
check "update-model.sh announces a slow Ollama start" uses_announced_start update-model.sh
# Nothing may go back to the silent form: that spelling is the bug.
no_silent_ollama_start() {
  local hits
  hits="$(grep -rln 'ensure_ollama_up [0-9]* >/dev/null' "${REPO}/scripts" "${REPO}" \
            --include='*.sh' 2>/dev/null || true)"
  [[ -z "${hits}" ]] || {
    printf 'these still start Ollama with all output suppressed:\n%s\n' "${hits}" >&2; return 1
  }
}
check "nothing starts Ollama with its output suppressed" no_silent_ollama_start
check "run-agent.sh announces a slow Ollama start" uses_announced_start run-agent.sh
# The suppressed-output spelling was only half of it. A long bare
# 'wait_for_ollama N' is the other half, and worse: it POLLS without starting
# anything. On a host with no systemd (or no sudo), 'lca' — the headline
# command — sat silent for 60 seconds waiting for a server nothing was
# starting, then advised 'systemctl restart' on a box that has no systemd.
#
# The rule is not "never wait". install_ollama.sh, restart_ollama and
# start_ollama_bg all wait a long time and are right to: each has just started
# the thing it waits for, and said so. So a long wait is allowed when the few
# lines above it either START the server or SAY something. Encoding that rather
# than a blanket ban is what stops this being suppressed the first time it is
# inconvenient.
no_unannounced_long_wait() {
  local hits
  hits="$(awk -f "${TESTS_DIR}/long-wait.awk" "$@")"
  [[ -z "${hits}" ]] || {
    printf 'these wait a long time for an Ollama nobody started, in silence:\n%s\n' "${hits}" >&2
    return 1
  }
}
check "no long wait for an Ollama nobody started or announced" \
  no_unannounced_long_wait "${REPO}"/*.sh "${REPO}"/scripts/*.sh

echo "# a model pull must survive a transient registry failure"
# CI hit the real thing: the registry answered 503 at 396 MB of a 397 MB
# download, and the whole pull was thrown away. On a droplet that is gigabytes
# and it aborts the first-boot install. Retrying is safe because 'ollama pull'
# resumes from the blobs already in the local store.
# Driven with a stub 'ollama' so the retry loop is exercised for real, without
# a network: sleep is stubbed too, or the test would wait 15 seconds.
pull_retries_then_succeeds() {
  local out
  out="$(bash -c '
    set -uo pipefail
    source "$1"
    ATTEMPTS=0
    ollama() { ATTEMPTS=$((ATTEMPTS+1)); [[ "${ATTEMPTS}" -ge 3 ]]; }
    sleep() { :; }
    pull_model fake-model:1b >/dev/null 2>&1
    printf "rc=%s attempts=%s\n" "$?" "${ATTEMPTS}"
  ' _ "${REPO}/scripts/lib.sh")"
  [[ "${out}" == "rc=0 attempts=3" ]] || {
    printf 'expected a successful third attempt, got: %s\n' "${out}" >&2; return 1
  }
}
check "a pull that fails twice then succeeds is a success" pull_retries_then_succeeds
pull_gives_up_after_three() {
  local out
  out="$(bash -c '
    set -uo pipefail
    source "$1"
    ATTEMPTS=0
    ollama() { ATTEMPTS=$((ATTEMPTS+1)); return 1; }
    sleep() { :; }
    pull_model fake-model:1b >/dev/null 2>&1
    printf "rc=%s attempts=%s\n" "$?" "${ATTEMPTS}"
  ' _ "${REPO}/scripts/lib.sh")"
  # Bounded: a genuinely unavailable model must still fail, and not loop.
  [[ "${out}" == "rc=1 attempts=3" ]] || {
    printf 'expected failure after exactly 3 attempts, got: %s\n' "${out}" >&2; return 1
  }
}
check "a pull that never succeeds fails after exactly 3 attempts" pull_gives_up_after_three
pull_succeeds_first_time_without_retrying() {
  local out
  out="$(bash -c '
    set -uo pipefail
    source "$1"
    ATTEMPTS=0; SLEPT=0
    ollama() { ATTEMPTS=$((ATTEMPTS+1)); return 0; }
    # Counted, not printed: an echo here lands on stdout, and the first version
    # of this test discarded stdout — so it silently only checked the retry.
    sleep() { SLEPT=$((SLEPT+1)); }
    pull_model fake-model:1b >/dev/null 2>&1
    printf "attempts=%s slept=%s\n" "${ATTEMPTS}" "${SLEPT}"
  ' _ "${REPO}/scripts/lib.sh")"
  # The happy path must not sleep or re-pull — it runs on every setup.
  [[ "${out}" == "attempts=1 slept=0" ]] || {
    printf 'a first-time success did extra work: %s\n' "${out}" >&2; return 1
  }
}
check "a pull that works first time does not retry or sleep" \
  pull_succeeds_first_time_without_retrying

echo "# OnCalendar comparison must survive systemd's shorthands"
# The backup timer keeps the schedule it was installed with, so BACKUP_SCHEDULE
# edited in .env and never applied leaves backups on the old cadence. Detecting
# that by comparing raw strings would report drift on a healthy box the moment
# someone wrote "daily" instead of "*-*-* 00:00:00" — an unfixable warning,
# which is worse than no warning.
if have systemd-analyze; then
  same_schedule() {
    local a b
    a="$(normalized_calendar "$1")" || return 1
    b="$(normalized_calendar "$2")" || return 1
    [[ "${a}" == "${b}" ]]
  }
  differing_schedule() { ! same_schedule "$1" "$2"; }
  check "'daily' equals '*-*-* 00:00:00' (no false drift)" \
    same_schedule daily '*-*-* 00:00:00'
  check "'weekly' differs from 'daily' (real drift is seen)" \
    differing_schedule weekly daily
  check "the .env default normalises to itself" \
    same_schedule '*-*-* 03:30:00' '*-*-* 03:30:00'
  # An unparseable spec must yield nothing, so the caller stays silent rather
  # than reporting drift between a real schedule and a parse failure.
  rejects_nonsense() { ! normalized_calendar 'not-a-schedule' >/dev/null 2>&1; }
  check "an invalid OnCalendar spec is refused, not guessed" rejects_nonsense
  # check-system.sh must actually use it.
  check_compares_schedule() { grep -qF 'normalized_calendar' "${REPO}/check-system.sh"; }
  check "check-system.sh compares the timer's schedule with .env" check_compares_schedule
fi

echo "# a manual pin must still apply .env to the running service"
# AUTO_TUNE=false means "do not re-pick the model from RAM". It used to mean
# "ignore .env entirely": tune.sh returned before its drift check, so editing
# OLLAMA_KEEP_ALIVE or OLLAMA_CONTEXT_LENGTH did nothing, on every boot, with
# nothing said. 'lca model' sets AUTO_TUNE=false for you, so that was the state
# of anyone who had pinned a model — and .env.example openly invites editing
# OLLAMA_KEEP_ALIVE ("set this to -1 to keep the model resident").
# Reproduced with real files before it was fixed: .env said -1, the drop-in
# said 30m, and tune.sh printed "Nothing to do".
# Anchored on the block that ends in "keeping your manual pin", because
# tune.sh's --dry-run section tests AUTO_TUNE the same way earlier in the file
# and the first version of this matched that one instead — failing against
# correct code. The window resets at each occurrence so only the real branch
# can satisfy it. No literal '${...}' in the pattern: ShellCheck reads that
# inside single quotes as an unexpanded variable (SC2016).
autotune_false_still_converges() {
  awk '/AUTO_TUNE/ && /!= "true"/ {inblk=1; sawresync=0; next}
       inblk && /resync_dropin_if_drifted/ {sawresync=1}
       inblk && /keeping your manual pin/ {if (sawresync) ok=1; inblk=0}
       END {exit !ok}' "${REPO}/scripts/tune.sh"
}
check "tune.sh converges the drop-in even when AUTO_TUNE=false" \
  autotune_false_still_converges
# One convergence RULE shared by both paths. (Not "one call to
# render_ollama_dropin" — the ordinary re-tune path renders too, and asserting
# that was the second way this test failed against correct code.)
resync_rule_is_shared() {
  local defs calls
  defs="$(grep -rc '^resync_dropin_if_drifted() {' "${REPO}/scripts/lib.sh" || true)"
  calls="$(grep -c 'resync_dropin_if_drifted' "${REPO}/scripts/tune.sh" || true)"
  [[ "${defs}" == "1" ]] || { printf 'convergence rule defined %s times in lib.sh\n' "${defs}" >&2; return 1; }
  (( calls >= 2 )) || { printf 'convergence rule called from only %s place(s)\n' "${calls}" >&2; return 1; }
  # Nowhere may re-implement it: a second copy is how the pinned path was
  # forgotten, and how 'lca apply' would drift from what tune.sh does on boot.
  ! grep -q 'render_ollama_dropin' "${REPO}/scripts/apply.sh" && return 1
  grep -q 'resync_dropin_if_drifted\|render_ollama_dropin' "${REPO}/scripts/apply.sh"
}
check "the drift rule is defined once and used by both paths" resync_rule_is_shared

echo "# 'lca apply' — one command for every setting that needs applying"
# Three separate silent failures came from .env settings that are baked into
# something long-lived. 'lca check' names a different fix command for each;
# this is the one command that does whatever is needed. It must be honest
# about a component that is absent (not "already matches"), and a dry run must
# change nothing — verified against real files, not just asserted here.
APPLY="${REPO}/scripts/apply.sh"
check "apply.sh is executable" test -x "${APPLY}"
apply_covers() { grep -qF "$1" "${APPLY}"; }
check "apply covers the Ollama drop-in"  apply_covers 'apply_ollama'
check "apply covers the chat app"        apply_covers 'apply_webui'
check "apply covers the backup timer"    apply_covers 'apply_backup_timer'
# The dry run must be incapable of changing anything: every mutating call has
# to sit behind the 'would' guard that returns early.
dry_run_guards_every_change() {
  local fn bad=0
  for fn in apply_ollama apply_webui apply_backup_timer; do
    awk -v f="${fn}" '$0 ~ "^"f"\\(\\) \\{" {inf=1}
         inf && /would /        {guarded=1}
         inf && /render_ollama_dropin|install_webui\.sh|--install-timer/ \
             && !/^[[:space:]]*(info|warn|ok|die|#)/ {if (!guarded) bad=1}
         inf && /^}/            {inf=0}
         END {exit bad}' "${APPLY}" || {
      printf '%s can change something before its dry-run guard\n' "${fn}" >&2; bad=1
    }
  done
  return "${bad}"
}
check "every change in apply.sh sits behind the dry-run guard" dry_run_guards_every_change
# A dry run's plan is the entire answer, so it must survive a redirect. The
# first version printed it through warn() — i.e. to stderr — so
# 'lca apply --dry-run > plan.txt' produced a file with a summary count and no
# plan. Invisible in a terminal, where both streams land together; CI caught it
# only because it captured stdout.
dry_run_plan_is_on_stdout() {
  local out
  out="$(cd "${SANDBOX}" && DRY_RUN=true CHANGED=0 bash -c '
    source "$1"; C_YELLOW=""; C_RESET=""
    source /dev/stdin <<EOF
$(sed -n "/^would()/,/^}/p" "$2")
EOF
    would "do the thing" 2>/dev/null' _ "${REPO}/scripts/lib.sh" "${APPLY}")"
  grep -q 'do the thing' <<<"${out}" || {
    echo "the dry-run plan does not reach stdout" >&2; return 1
  }
}
check "the dry-run plan reaches stdout, not stderr" dry_run_plan_is_on_stdout
# "Cannot ask" is not "nothing to do". Every docker probe collapses "no
# container" and "daemon is down" into the same non-zero exit, and the first
# version reported a down daemon as "not created yet — create it with
# install_webui.sh": untrue, and a command that could not have worked either,
# while a perfectly good container sat there with drifted settings.
apply_distinguishes_daemon_down() {
  local out
  out="$(bash -c '
    set -uo pipefail
    source "$1"                # lib.sh
    source "$2"                # apply.sh (its guard stops main from running)
    docker_daemon_reachable() { return 1; }
    webui_container_exists()  { return 0; }   # a container DOES exist
    have() { return 0; }
    ENABLE_WEBUI=true; SKIP_DOCKER=false; DRY_RUN=false
    CHANGED=0; BLOCKED=0; UNCHECKED=0
    apply_webui 2>&1
    printf "UNCHECKED=%s CHANGED=%s\n" "${UNCHECKED}" "${CHANGED}"
  ' _ "${REPO}/scripts/lib.sh" "${APPLY}" 2>&1)"
  grep -qi 'cannot reach the Docker daemon' <<<"${out}" || {
    printf 'a down daemon was not reported as such: %s\n' "${out}" >&2; return 1
  }
  grep -q 'UNCHECKED=1' <<<"${out}" || {
    printf 'a down daemon was not counted as unchecked: %s\n' "${out}" >&2; return 1
  }
  # And it must not have claimed the container is missing.
  if grep -qi 'not created yet' <<<"${out}"; then
    echo "a down daemon was reported as a missing container" >&2; return 1
  fi
}
check "apply reports an unreachable Docker daemon, not a missing container" \
  apply_distinguishes_daemon_down
# ...and the summary must never say "everything matches" about something it
# could not look at.
apply_summary_admits_unchecked() {
  awk '/CHANGED == 0/ {inf=1}
       inf && /UNCHECKED > 0/ {guarded=1}
       inf && /already matches .env/ {if (!guarded) bad=1; inf=0}
       END {exit bad}' "${APPLY}"
}
check "apply never claims a clean bill for an unchecked component" \
  apply_summary_admits_unchecked

echo "# 'lca apply' must move Ollama before rebuilding the chat app"
# The container bakes in OLLAMA_BASE_URL at creation. docs/TROUBLESHOOTING.md
# now tells people to fix a moved OLLAMA_HOST with 'lca apply', so Ollama must
# be listening on the new port before the container is rebuilt to point at it.
# Reversed, the chat app spends the gap talking to a port nothing answers on —
# the exact failure this command was written to end. Silent if broken: the end
# state is still correct, only the window between is wrong.
apply_moves_ollama_first() {
  awk '/^main\(\) \{/ {inmain=1}
       inmain && /^  apply_ollama$/ {o=NR}
       inmain && /^  apply_webui$/  {w=NR}
       END {exit !(o > 0 && w > 0 && o < w)}' "${APPLY}"
}
check "apply re-points Ollama before it rebuilds the chat app" \
  apply_moves_ollama_first
# A missing component is not a matching one.
distinguishes_absent_from_matching() {
  grep -qF 'webui_container_exists' "${APPLY}"
}
check "apply says 'not created yet' rather than 'already matches'" \
  distinguishes_absent_from_matching
# Scheduled backups are opt-in; applying .env must not create a timer nobody
# asked for.
never_creates_a_timer() {
  awk '/^apply_backup_timer\(\) \{/ {inf=1}
       inf && /is-enabled/ {guarded=1}
       inf && /--install-timer/ && !/^[[:space:]]*(info|warn|ok|die|#)/ {if (!guarded) bad=1}
       inf && /^}/ {inf=0}
       END {exit bad}' "${APPLY}"
}
check "apply never installs a backup timer that was not there" never_creates_a_timer
check "'lca apply' is dispatched by bin/lca" grep -q 'apply)' "${REPO}/bin/lca"
# check-system.sh must report the drift, for the user who has not rebooted yet.
check_reports_dropin_drift() {
  grep -qF 'ollama_dropin_matches' "${REPO}/check-system.sh"
}
check "check-system.sh reports ollama config drift" check_reports_dropin_drift
# ...and the OTHER half of the same class. Ollama's drop-in drift was reported
# here from the start; the chat app's was reported only by './webui.sh status',
# which is not the command the README, the docs or the login banner point
# anyone at. So the half containing the assistant's own system prompt could
# drift with 'lca check' saying nothing — the exact silence this class of test
# exists to break.
check_reports_webui_drift() {
  grep -qF 'webui_drift' "${REPO}/check-system.sh" || {
    echo "'lca check' never asks whether the chat app matches .env" >&2
    return 1
  }
  # And it must not claim a match for a container that is not there: with no
  # container every comparison reads "cannot tell", and "matches .env" about a
  # thing that does not exist is worse than saying nothing.
  awk '/webui_drifted="\$\(webui_drift/ { found=1 }
       found && /p_pass "chat app matches/ { ok=guarded }
       /if \[\[ -n "\$\{webui_status\}" \]\]/ { guarded=1 }
       END { exit !ok }' "${REPO}/check-system.sh" || {
    echo "the chat-app drift check is not scoped to an existing container" >&2
    return 1
  }
}
check "check-system.sh reports chat app config drift too" check_reports_webui_drift

echo "# every setting baked into the WebUI container must be drift-checked"
# Editing .env does not change a running container, so each of these can be
# changed in .env and silently not take effect. Port and model drift were
# already reported; signup drift was not — and that is the one where the
# silence means "you think signups are locked and they are open".
drift_checked() {
  local var="$1"
  # Read out of the container in exactly ONE place (lib.sh's webui_container_env
  # / webui_drift). It used to be written out per key inline in webui.sh, and
  # the third key — signups — was simply never added, which is the whole reason
  # the comparison now lives in one function.
  grep -qF "webui_container_env ${var}" "${REPO}/scripts/lib.sh" || {
    printf 'lib.sh never reads %s out of the running container\n' "${var}" >&2; return 1
  }
  # ...while the message stays specific per key: "PORT differs" and "anyone can
  # still register an account" are not the same news.
  grep -qiE "warn \"${2} drift" "${REPO}/webui.sh" || {
    printf 'nothing warns specifically about %s (%s) drift\n' "${var}" "${2}" >&2; return 1
  }
}
check "webui.sh reports PORT drift"          drift_checked PORT Port
check "webui.sh reports DEFAULT_MODELS drift" drift_checked DEFAULT_MODELS Model
check "webui.sh reports ENABLE_SIGNUP drift"  drift_checked ENABLE_SIGNUP Signup
check "webui.sh reports OLLAMA_BASE_URL drift" drift_checked OLLAMA_BASE_URL "Ollama address"
check "webui.sh reports WEBUI_NAME drift"      drift_checked WEBUI_NAME Name
check "webui.sh reports system prompt drift" \
  drift_checked DEFAULT_MODEL_PARAMS "System prompt"
check "webui.sh reports starter question drift" \
  drift_checked DEFAULT_PROMPT_SUGGESTIONS "Starter question"
# Every setting the installer bakes in from .env must be compared. The three
# telemetry flags are constants, so they cannot drift; everything else can, and
# "the ones we happened to think of" is how OLLAMA_BASE_URL — the address the
# phone uses to reach the model at all — went unchecked.
#
# ONE definition, used by both tests below. Written out twice, the reach test
# guarded its own copy: reverting the loop's pattern to the blind one left
# every test green. Two copies drifting apart is the bug this whole gate
# exists to catch, so it must not be how the gate is built.
baked_keys() {
  grep -oE '\-e "?[A-Z_]+=' "${REPO}/scripts/install_webui.sh" \
    | grep -oE '[A-Z_]+' | sort -u
}
every_baked_setting_is_compared() {
  local key bad=0
  while read -r key; do
    [[ -n "${key}" ]] || continue
    case "${key}" in
      DO_NOT_TRACK|SCARF_NO_ANALYTICS|ANONYMIZED_TELEMETRY) continue ;;
    esac
    grep -qF "webui_container_env ${key}" "${REPO}/scripts/lib.sh" || {
      printf 'install_webui.sh bakes in %s but nothing ever compares it\n' "${key}" >&2
      bad=1
    }
  done < <(baked_keys)
  return "${bad}"
}
check "every setting baked into the container is drift-checked" \
  every_baked_setting_is_compared
# The gate above is only as good as what it can see, and for two settings it
# saw nothing. It anchored on '^<spaces>-e KEY=', which matches the plain
# 'docker run' flags but NOT the two baked in from inside an array literal as
# '-e "KEY=$(...)"' — the system prompt and the starter questions. So the pair
# that decides what the assistant will and will not do were precisely the two
# nothing compared, and 'lca apply' answered "already matches .env" after a
# repo update that changed the prompt. Assert the scanner's reach directly:
# a gate whose blind spot is invisible is worse than no gate.
baked_scanner_sees_array_form() {
  local found
  found="$(baked_keys)"
  grep -qx 'DEFAULT_MODEL_PARAMS' <<<"${found}" || {
    echo "the baked-settings scanner cannot see DEFAULT_MODEL_PARAMS" >&2; return 1
  }
  grep -qx 'DEFAULT_PROMPT_SUGGESTIONS' <<<"${found}" || {
    echo "the baked-settings scanner cannot see DEFAULT_PROMPT_SUGGESTIONS" >&2; return 1
  }
  # ...and it must not invent keys either: everything it yields has to be a
  # real '-e' flag in the installer.
  local key
  while read -r key; do
    [[ -n "${key}" ]] || continue
    grep -qE "\\-e \"?${key}=" "${REPO}/scripts/install_webui.sh" || {
      printf 'the scanner produced %s, which install_webui.sh never bakes in\n' "${key}" >&2
      return 1
    }
  done <<<"${found}"
}
check "the baked-settings scanner sees the array-literal '-e \"KEY=\"' form" \
  baked_scanner_sees_array_form
# ...and the comparison itself must work, not merely exist. The tests above
# are source greps; this one drives webui_drift() for real, with the container
# read stubbed so it runs anywhere (CI has no docker daemon). The bug being
# guarded is behavioural: 'lca apply' reported "already matches .env" to
# someone who had just pulled a repo whose system prompt was different.
#
# Each case runs in a subshell so the stub cannot leak into later tests.
if have jq; then
  # drift_says PATTERN LIVE_VALUE — is PATTERN among the drifted keys when the
  # container was created with LIVE_VALUE as its system prompt?
  # The stub's variable is NOT called 'live'. webui_drift() declares its own
  # 'local live', and bash's dynamic scoping means the stub — called from
  # inside it — would read webui_drift's empty one instead of ours. The test
  # then passed the "no drift" cases and failed the one that mattered, for a
  # reason that had nothing to do with the code under test.
  drift_says() {
    local want="$1" stub_live="$2" out
    out="$(
      webui_container_env() {
        [[ "$1" == "DEFAULT_MODEL_PARAMS" ]] || return 1
        [[ -n "${stub_live}" ]] || return 1
        printf '%s' "${stub_live}"
      }
      webui_drift || true
    )"
    # Spelled out rather than '! grep -q ...': a bare negation as a function's
    # last statement is SC2251 (it skips errexit), and the repo lints clean.
    if [[ "${want}" == "none" ]]; then
      if grep -q SYSTEM_PROMPT <<<"${out}"; then
        printf 'drift was claimed when it should not have been: %s\n' "${out}" >&2
        return 1
      fi
      return 0
    fi
    grep -q SYSTEM_PROMPT <<<"${out}"
  }
  check "a container holding today's prompt is not called drifted" \
    drift_says none "$(lca_system_prompt | jq -Rsc '{system: .}')"
  check "a container holding a different prompt IS reported as drift" \
    drift_says SYSTEM_PROMPT "$(printf 'you are a helpful assistant' | jq -Rsc '{system: .}')"
  # An install predating the setting, or one made without jq, baked in no such
  # value at all. "Cannot tell" is not "differs" — claiming drift there would
  # send every one of those users to re-create a container for no reason.
  check "a container created without the setting is not called drifted" \
    drift_says none ""
else
  echo "skip - jq not installed, cannot exercise the system prompt comparison"
fi
# And check-system.sh must say something about open signups, since that is
# where a user looks when asking "is this box safe?".
signup_reported_by_check() {
  grep -qF 'WEBUI_ENABLE_SIGNUP' "${REPO}/check-system.sh"
}
check "check-system.sh reports the signup setting" signup_reported_by_check

echo "# every drift message must name the one command that fixes drift"
# 'lca apply' exists precisely so nobody has to remember which script applies
# which setting. It was added, documented in TROUBLESHOOTING.md — and then the
# place users actually MEET drift, the output of 'lca check' and
# 'webui.sh status', went on naming individual scripts. Seven messages, seven
# different things to remember, for a problem that now has one answer.
drift_messages_name_apply() {
  local bad=0 line
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    grep -qF 'lca apply' <<<"${line}" || {
      printf 'a drift message does not point at "lca apply":\n  %s\n' "${line:0:120}" >&2
      bad=1
    }
  done < <(grep -hE '(warn|p_warn) ".*[Dd]rift' "${REPO}/check-system.sh" "${REPO}/webui.sh")
  return "${bad}"
}
check "every drift message points at 'lca apply'" drift_messages_name_apply

echo "# no document may tell you to re-run an installer to apply a .env change"
# 'lca apply' replaced a lookup table of "which script applies which setting",
# but seven instructions across README.md, YOUR-TURN.md, PHONE.md and
# TROUBLESHOOTING.md still named the individual installers. One of them was
# outright incomplete: "change OLLAMA_HOST to another port and re-run
# scripts/install_ollama.sh" renders the drop-in and never touches the chat
# app container, which is exactly how the phone came to be pointed at a port
# nothing listens on. 'lca apply' does both, so the advice is now correct as
# well as shorter.
# Naming an installer for what it IS (docs/INSTALL.md) is fine; this only
# forbids naming it as the way to APPLY an edit.
no_installer_as_apply_instruction() {
  local hits
  # printf for the backtick: a matched PAIR inside single quotes reads to
  # ShellCheck as a command substitution (SC2016). Predicted this in the last
  # commit and then wrote it literally anyway — hence the note here.
  local bt; bt="$(printf '\140')"
  hits="$(grep -rn "re-run ${bt}scripts/install_\|re-running ${bt}scripts/install_" \
            "${REPO}"/README.md "${REPO}"/docs/*.md 2>/dev/null || true)"
  [[ -z "${hits}" ]] || {
    printf 'these tell the reader to re-run an installer instead of lca apply:\n%s\n' "${hits}" >&2
    return 1
  }
}
check "no doc names an installer as the way to apply a .env edit" \
  no_installer_as_apply_instruction
# The same rule for the messages a user reads at the terminal, which is where
# it was actually still being broken: 'lca check' warned that signups were open
# and told you to re-run scripts/install_webui.sh, while PHONE.md — fixed in
# the same change that added 'lca apply' — told you 'sudo lca apply'. Two
# half-remembered ways to do one thing is precisely what that command exists
# to end, and the docs gate could not see a string inside a .sh file.
#
# Scoped to the surfaces that REPORT state. An installer telling you to re-run
# an installer is correct advice — install_webui.sh's port clash happens after
# it has already removed the old container, so 'lca apply' would have nothing
# to re-create and the installer really is the next step.
no_status_command_sends_you_to_an_installer() {
  local s hits
  # Two upgrades, both from finding this rule broken again in a place the old
  # check could not see.
  #
  # Path-agnostic, because these messages name absolute paths now and a pattern
  # tied to the old relative spelling would match nothing ever again — a gate
  # that cannot fail, guarding a rule that still matters.
  #
  # And a sliding two-line window, because 'lca speed' broke it across two
  # info() calls: "...set OLLAMA_KEEP_ALIVE=-1 in .env and re-run" on one line,
  # the installer path on the next. Each line alone was innocent. Every script
  # lca dispatches to is scanned now, not just the two that report state —
  # speed.sh is a report too, and it was not on the list.
  for s in "${LCA_TARGETS[@]}"; do
    hits="$(grep -E '\b(warn|info|die|err|ok|p_pass|p_warn|p_fail)[[:space:]]+"' "${REPO}/${s}" \
              | awk '{ prev = cur; cur = $0; print prev " " cur }' \
              | grep -E 'in \.env and re-run.*install_' || true)"
    [[ -z "${hits}" ]] || {
      printf '%s names an installer instead of lca apply:\n%s\n' "${s}" "${hits}" >&2
      return 1
    }
  done
}
check "no status command names an installer to apply a .env edit" \
  no_status_command_sends_you_to_an_installer

echo "# the login banner's install-state machine"
# The banner is the first thing anyone sees on this box, so being confidently
# wrong there is worse than saying nothing. Every state is exercised against a
# real log file, because the states differ only by content and mtime.
MOTD="${REPO}/scripts/motd.sh"
LOGDIR="${SANDBOX}/logs"
mkdir -p "${LOGDIR}"
# motd_state NAME AGE_SECONDS — write a log (from stdin), age it, classify it.
motd_state() {
  local f="${LOGDIR}/$1" age="$2"
  cat > "${f}"
  touch -d "@$(( $(date +%s) - age ))" "${f}"
  LCA_LOG="${f}" bash -c 'source "$1"; load_env_readonly; install_state' _ "${MOTD}" 2>/dev/null
}
state_is() {
  local want="$1" got="$2"
  [[ "${got}" == "${want}" ]] || { printf 'expected state %s, got %s\n' "${want}" "${got}" >&2; return 1; }
}

check "a fresh log with no verdict is 'running'" state_is running "$(motd_state running 5 <<'EOF'
=== local-code-agent first-boot install started: today ===
==> Downloading the model
EOF
)"
# The one that matters: this repository's own build VM had an interrupted
# install from 19 hours earlier, and "no verdict yet" would have told a user
# with a perfectly working stack that nothing works.
check "an old log with no verdict is 'stalled', not 'running'" state_is stalled "$(motd_state stalled 4000 <<'EOF'
=== local-code-agent first-boot install started: yesterday ===
==> Installing Docker
EOF
)"
# The log file is named 'complete', not 'done': an unquoted 'done' as an
# argument reads to ShellCheck as the loop keyword (SC1010).
check "SETUP COMPLETE is 'done'" state_is "done" "$(motd_state complete 30 <<'EOF'
=== local-code-agent first-boot install started: today ===
SETUP COMPLETE — local-code-agent is ready.
EOF
)"
check "SETUP FINISHED WITH ERRORS is 'failed'" state_is failed "$(motd_state failed 30 <<'EOF'
=== local-code-agent first-boot install started: today ===
SETUP FINISHED WITH ERRORS — 2 step(s) failed.
EOF
)"
check "FIRST-BOOT INSTALL FAILED is 'failed'" state_is failed "$(motd_state bootfail 30 <<'EOF'
=== local-code-agent first-boot install started: today ===
FIRST-BOOT INSTALL FAILED — the droplet is NOT ready.
EOF
)"
# A re-run appends to the same log. Reading the whole file would find the
# PREVIOUS run's "COMPLETE" and report a finished install while one is midway.
check "a re-run ignores the previous run's verdict" state_is running "$(motd_state rerun 5 <<'EOF'
=== local-code-agent first-boot install started: yesterday ===
SETUP COMPLETE — local-code-agent is ready.
=== local-code-agent first-boot install finished: yesterday ===
=== local-code-agent first-boot install started: today ===
==> Installing Ollama
EOF
)"
missing_log_is_none() {
  [[ "$(LCA_LOG="${SANDBOX}/no-such-log" bash -c \
    'source "$1"; load_env_readonly; install_state' _ "${MOTD}" 2>/dev/null)" == "none" ]]
}
check "no log at all is 'none'" missing_log_is_none

echo "# the login banner must never write anything"
# It runs as ROOT on every SSH login. load_env creates .env from .env.example
# when missing, so the plain loader would leave a root-owned .env behind merely
# because someone logged in — and the next non-root setup.sh could not write it.
motd_creates_nothing() {
  local dir="${SANDBOX}/noenv"
  rm -rf "${dir}"; mkdir -p "${dir}/scripts"
  cp "${REPO}/scripts/lib.sh" "${REPO}/scripts/motd.sh" "${dir}/scripts/"
  cp "${REPO}/.env.example" "${dir}/"
  LCA_LOG="${SANDBOX}/no-such-log" "${dir}/scripts/motd.sh" >/dev/null 2>&1 || true
  [[ ! -e "${dir}/.env" ]]
}
check "motd.sh does not create .env" motd_creates_nothing
# ...while the ordinary loader must still do exactly what it always did.
load_env_still_creates() {
  local dir="${SANDBOX}/withenv"
  rm -rf "${dir}"; mkdir -p "${dir}/scripts"
  cp "${REPO}/scripts/lib.sh" "${dir}/scripts/"
  cp "${REPO}/.env.example" "${dir}/"
  bash -c 'source "$1/scripts/lib.sh"; load_env' _ "${dir}" >/dev/null 2>&1 || true
  [[ -e "${dir}/.env" ]]
}
check "load_env still creates .env (the read-only mode is opt-in)" load_env_still_creates

echo "# the banner's verdict markers must match the lines actually printed"
# motd.sh classifies on prefixes of setup.sh's and do-user-data.sh's verdict
# lines. Reword either end and the banner silently reports 'running' forever.
motd_markers_are_real() {
  local marker bad=0
  for marker in "SETUP COMPLETE" "SETUP FINISHED WITH ERRORS" "FIRST-BOOT INSTALL FAILED"; do
    grep -qF "${marker}" "${REPO}/scripts/motd.sh" || {
      printf 'motd.sh no longer looks for: %s\n' "${marker}" >&2; bad=1; continue
    }
    grep -qF "${marker}" "${REPO}/setup.sh" || grep -qF "${marker}" "${REPO}/deploy/do-user-data.sh" || {
      printf 'nothing ever prints the marker motd.sh classifies on: %s\n' "${marker}" >&2; bad=1
    }
  done
  return "${bad}"
}
check "every marker motd.sh matches on is really printed" motd_markers_are_real

# do-user-data.sh runs before the clone exists, so it cannot source lib.sh and
# keeps its own copy of the log path. If the two drift, the banner watches a
# file the installer never writes and reports 'none' during every install.
log_path_agrees() {
  local from_lib from_userdata
  # Matched without a literal '${...}' in the pattern: ShellCheck reads that
  # inside single quotes as a variable someone forgot to expand (SC2016).
  from_lib="$(sed -n 's|^SETUP_LOG=.*:-\(/[^}]*\)}"$|\1|p' "${REPO}/scripts/lib.sh")"
  from_userdata="$(sed -n 's|^LOG_FILE=.*:-\(/[^}]*\)}"$|\1|p' "${REPO}/deploy/do-user-data.sh")"
  [[ -n "${from_lib}" && -n "${from_userdata}" ]] || {
    echo "could not read the log path out of one of the two files" >&2; return 1
  }
  [[ "${from_lib}" == "${from_userdata}" ]] || {
    printf 'log path drift: lib.sh=%s do-user-data.sh=%s\n' "${from_lib}" "${from_userdata}" >&2; return 1
  }
}
check "lib.sh and do-user-data.sh agree on the install log path" log_path_agrees

# run-parts --lsbsysinit (how pam_motd invokes it) skips any filename with a
# dot in it, so installing this as '99-local-code-agent.sh' would silently
# never run.
motd_filename_is_runnable() {
  local path base
  path="$(sed -n 's|^MOTD_FILE="\(.*\)"$|\1|p' "${REPO}/scripts/lib.sh")"
  [[ -n "${path}" ]] || { echo "could not read MOTD_FILE from lib.sh" >&2; return 1; }
  base="${path##*/}"
  [[ -n "${base}" && "${base}" != *.* ]]
}
check "the installed banner filename has no dot (run-parts would skip it)" \
  motd_filename_is_runnable

echo "# setup.sh must actually run every installer that exists"
# An installer that nothing calls is worse than a missing one: it looks like
# coverage, passes ShellCheck, and is only discovered when a user asks why the
# thing it installs is not there. Adding scripts/install_foo.sh and forgetting
# the line in setup.sh is a one-keystroke mistake with no other symptom.
setup_runs_every_installer() {
  local f name bad=0 found=0
  for f in "${REPO}"/scripts/install_*.sh; do
    [[ -e "${f}" ]] || continue
    found=1
    name="$(basename "${f}")"
    grep -qF "scripts/${name}" "${REPO}/setup.sh" || {
      printf 'setup.sh never invokes scripts/%s\n' "${name}" >&2
      bad=1
    }
  done
  # No installers found would otherwise "pass" without checking anything.
  (( found == 1 )) || { echo "no scripts/install_*.sh found at all" >&2; return 1; }
  return "${bad}"
}
check "setup.sh invokes every scripts/install_*.sh" setup_runs_every_installer

echo "# the install's final verdict line must read the same everywhere"
# docs/YOUR-TURN.md and docs/DO.md tell the user to watch the log for exactly
# this line, and deploy/do-user-data.sh documents it as one of its three
# outcomes. Reword it in setup.sh alone and the instruction becomes "wait for a
# line that never comes" — a failure mode that looks like a hung install.
# setup.sh is the single source; the others must quote it verbatim.
verdict_line_is_consistent() {
  local line f bad=0
  line="$(sed -n 's/^SETUP_DONE_LINE="\(.*\)"$/\1/p' "${REPO}/scripts/lib.sh")"
  # Without this guard an empty extraction makes every 'grep -qF ""' below
  # match, and the test passes while checking nothing.
  [[ -n "${line}" ]] || { echo "could not read SETUP_DONE_LINE from lib.sh" >&2; return 1; }
  for f in docs/YOUR-TURN.md docs/DO.md deploy/do-user-data.sh; do
    grep -qF -- "${line}" "${REPO}/${f}" || {
      printf '%s does not contain the verdict line from setup.sh: %s\n' "${f}" "${line}" >&2
      bad=1
    }
  done
  return "${bad}"
}
check "the SETUP COMPLETE line matches across lib.sh and the docs" \
  verdict_line_is_consistent

echo "# the install's verdict must carry an exit status, not just a line"
# setup.sh printed "SETUP FINISHED WITH ERRORS" and then exited 0. That made
# deploy/do-user-data.sh's failure branch — and its comment claiming setup
# "exits non-zero on a partial failure" — dead code: a droplet whose model
# never downloaded reported a successful first-boot install, and any
# automation branching on the exit code was misled. A verdict nobody can act
# on programmatically is not a verdict.
verdict_ok_exits_zero()  { setup_verdict true  >/dev/null 2>&1; }
verdict_bad_exits_one()  { ! setup_verdict false >/dev/null 2>&1; }
check "setup_verdict true exits 0"  verdict_ok_exits_zero
check "setup_verdict false exits non-zero" verdict_bad_exits_one
# ...and each must print the line the docs and the login banner look for.
verdict_prints() {
  local want="$1" flag="$2" out
  out="$(setup_verdict "${flag}" 2>&1 || true)"
  grep -qF -- "${want}" <<<"${out}" || {
    printf 'setup_verdict %s printed: %s\n' "${flag}" "${out}" >&2; return 1
  }
}
check "the success verdict prints SETUP COMPLETE" \
  verdict_prints "SETUP COMPLETE — local-code-agent is ready." true
check "the failure verdict prints SETUP FINISHED WITH ERRORS" \
  verdict_prints "SETUP FINISHED WITH ERRORS" false
# setup.sh must actually USE it — printing the line by hand again would
# reintroduce exactly the bug above while leaving these tests green.
setup_uses_verdict() {
  grep -qE '^[[:space:]]*setup_verdict "\$\{setup_ok\}"' "${REPO}/setup.sh" || {
    echo "setup.sh no longer ends on setup_verdict" >&2; return 1
  }
  # And nothing may re-hardcode a verdict line outside lib.sh.
  ! grep -qF 'SETUP FINISHED WITH ERRORS' "${REPO}/setup.sh"
}
check "setup.sh reports through setup_verdict" setup_uses_verdict
# update.sh takes a backup specifically so it can be restored when the update
# goes wrong. Dying bare under 'set -e' would never mention it.
# Scoped to the "Re-running setup" section and stopped at the next step: the
# first version of this searched the whole rest of the file, found the
# unrelated restore.sh mention in the self-test branch below, and passed
# happily with the guard deleted.
update_mentions_restore_on_failure() {
  awk '/step "Re-running setup"/ {seen=1; next}
       seen && /step "/ {exit}
       seen && /if ! .*setup\.sh/ {guarded=1}
       seen && /restore\.sh/ {ok=1}
       END {exit !(ok && guarded)}' "${REPO}/update.sh"
}
check "update.sh points at the backup when setup fails" \
  update_mentions_restore_on_failure

echo "# 'lca check --quick' skips the one probe that costs real time"
# Measured on this box: a full 'lca check' took 242 seconds, of which all but
# about 3 were one probe — asking the model to generate. setup.sh runs exactly
# that probe a few steps earlier and dies if it fails, so the final check was
# paying for it twice on every install and every E2E run in CI.
quick_flag_documented_in_usage() {
  local out
  out="$(bash "${REPO}/check-system.sh" --help 2>&1)" || return 1
  # A DESCRIBED flag, not merely the token. The first version searched for
  # '--quick' anywhere in the output and could not fail: the usage line
  # "Usage: lca check [--quick]" contains it, so deleting the explanation
  # entirely left the test green. What must stay true is that someone reading
  # --help learns what the flag does.
  grep -qE '^[[:space:]]*--quick[[:space:]]+[a-z]' <<<"${out}"
}
check "check-system.sh --help explains what --quick does, and exits 0" \
  quick_flag_documented_in_usage
# An unknown flag must be refused rather than silently ignored: a typo'd
# '--quik' that runs the slow path anyway is the failure this whole flag is
# meant to remove.
rejects_unknown_flag() {
  bash "${REPO}/check-system.sh" --definitely-not-a-flag >/dev/null 2>&1
  (( $? == 2 ))
}
check "check-system.sh rejects an unknown flag with exit 2" rejects_unknown_flag
# The generation probe must sit UNDER the guard, not merely somewhere in the
# same file. Asserted on the block so that moving the probe out from under the
# branch fails here even though both strings still appear.
quick_guards_the_generation_probe() {
  awk '/\{QUICK\}" == "true" \]\]; then/ { inblock=1; next }
       inblock && /^# --- / { exit }
       inblock && /model_responds/ { found=1 }
       END { exit !found }' "${REPO}/check-system.sh"
}
check "the slow generation probe sits under the --quick guard" \
  quick_guards_the_generation_probe
# setup.sh must use it — but conditionally. An unconditional --quick would be
# worse than the duplication it removes: when Ollama is unreachable the smoke
# test never runs, and this check is then the only thing that would prove
# inference works at all. So --quick may only ever be reached through the
# variable that a successful generation sets.
setup_skips_only_what_it_already_proved() {
  # The flag is never passed as a literal on the invocation line...
  ! grep -qE 'check-system\.sh".*--quick' "${REPO}/setup.sh" || return 1
  # ...it is gated on a variable, which only a real generation sets true...
  grep -qE '^[[:space:]]*smoke_tested=true$' "${REPO}/setup.sh" || return 1
  awk '/if model_responds /   { inblock=1; next }
       inblock && /^[[:space:]]*else/  { exit }
       inblock && /smoke_tested=true/  { found=1 }
       END { exit !found }' "${REPO}/setup.sh" || return 1
  # ...and that variable is what decides the argument.
  awk '/smoke_tested\}" == "true" \]\]; then/ { inblock=1; next }
       inblock && /^[[:space:]]*fi$/ { exit }
       inblock && /--quick/ { found=1 }
       END { exit !found }' "${REPO}/setup.sh"
}
check "setup.sh skips the re-test only when it already proved inference" \
  setup_skips_only_what_it_already_proved

echo "# the inbound guard bakes its ports in, so .env can drift away from it"
# Change a port in .env and the guard goes on dropping the old one while the
# service listens on the new one — unauthenticated, on every interface. 'lca
# check' reports it and 'lca apply' fixes it, from one copy of the rule.
GUARD_DUMP='table inet lca_inbound {
  chain inbound {
    type filter hook input priority -10; policy accept;
    iifname "lo" accept
    iifname "tailscale0" accept
    tcp dport { 3000, 11434 } ct state new counter packets 0 bytes 0 drop
  }
}'
ports_for() {  # ENABLE_WEBUI WEBUI_PORT OLLAMA_HOST
  local ENABLE_WEBUI="$1" WEBUI_PORT="$2" OLLAMA_HOST="$3"
  guarded_ports | paste -sd'|' -
}
uncovered_for() {  # DUMP ENABLE_WEBUI WEBUI_PORT OLLAMA_HOST
  local dump="$1" ENABLE_WEBUI="$2" WEBUI_PORT="$3" OLLAMA_HOST="$4"
  inbound_guard_uncovered "${dump}" | paste -sd'|' -
}
check "both service ports are guarded by default" \
  test "$(ports_for true 3000 127.0.0.1:11434)" = "WebUI 3000|Ollama 11434"
check "with the chat app off, only Ollama's port is" \
  test "$(ports_for false 3000 127.0.0.1:11434)" = "Ollama 11434"
# netmode.sh refuses to put SSH in the drop set so the guard can never lock
# anyone out — so a service parked on 22 is not a gap either. Reporting one
# would be a failure nobody could ever clear.
check "a chat app on port 22 is not called a gap" \
  test "$(ports_for true 22 127.0.0.1:11434)" = "Ollama 11434"
check "an Ollama on port 22 is not called a gap" \
  test "$(ports_for true 3000 127.0.0.1:22)" = "WebUI 3000"
nothing_to_guard() {
  local ENABLE_WEBUI=false OLLAMA_HOST=127.0.0.1:22
  ! guarded_ports
}
check "and with neither, there is nothing to guard" nothing_to_guard

covers_everything() {
  local ENABLE_WEBUI=true WEBUI_PORT=3000 OLLAMA_HOST=127.0.0.1:11434
  ! inbound_guard_uncovered "${GUARD_DUMP}"
}
check "a guard covering both ports reports no gap" covers_everything
check "a port moved in .env is reported as uncovered" \
  test "$(uncovered_for "${GUARD_DUMP}" true 8080 127.0.0.1:11434)" = "WebUI 8080"
check "both are reported when no guard is loaded at all" \
  test "$(uncovered_for "" true 3000 127.0.0.1:11434)" = "WebUI 3000|Ollama 11434"
# A guard covering 11434 must not be read as covering 1143.
check "a port that is a prefix of a guarded one is still uncovered" \
  test "$(uncovered_for "${GUARD_DUMP}" false 3000 127.0.0.1:1143)" = "Ollama 1143"

# ...and neither reporter nor fixer may keep its own copy of the rule.
one_copy_of_the_coverage_rule() {
  local hits
  hits="$(grep -n 'dport \\{' "${REPO}/check-system.sh" "${REPO}/scripts/apply.sh" 2>/dev/null || true)"
  [[ -z "${hits}" ]] || {
    printf 'a second copy of the guard-coverage rule:\n%s\n' "${hits}" >&2
    return 1
  }
}
guard_is_reported_and_applied() {
  grep -q 'inbound_guard_uncovered' "${REPO}/check-system.sh" || return 1
  grep -q 'inbound_guard_uncovered' "${REPO}/scripts/apply.sh"  || return 1
  # and 'lca apply' must actually run the fix, not just describe it
  grep -q 'netmode.sh" harden' "${REPO}/scripts/apply.sh" || return 1
  # ...and main() must reach it, or every test below drives dead code.
  awk '/^main\(\) \{/     { inb=1; next }
       inb && /^\}/       { exit }
       inb && /apply_guard/ { found=1 }
       END { exit !found }' "${REPO}/scripts/apply.sh"
}
check "the guard-coverage rule exists in exactly one place" \
  one_copy_of_the_coverage_rule
check "'lca check' reports guard drift and 'lca apply' fixes it" \
  guard_is_reported_and_applied

# ...and the applier itself is driven for real, because what it decides is
# whether a firewall gets loaded. apply.sh guards its own main() behind a
# BASH_SOURCE test precisely so this is possible.
cp "${REPO}/scripts/apply.sh" "${SANDBOX}/scripts/apply.sh"
printf '#!/usr/bin/env bash\necho "HARDEN-CALLED"\n' > "${SANDBOX}/netmode.sh"
chmod +x "${SANDBOX}/netmode.sh"
cat > "${SANDBOX}/apply-probe.sh" <<'PROBE'
#!/usr/bin/env bash
# $1 apply.sh  $2 have-nft  $3 can-root  $4 nft dump  $5 dry-run  $6 WEBUI_PORT
set -euo pipefail
source "$1"
# After the source, never before: apply.sh calls load_env, which re-exports
# every key in .env over whatever the caller had set.
HAVE_NFT="$2"; CAN_ROOT="$3"; NFT_DUMP="$4"; DRY_RUN="$5"
ENABLE_WEBUI=true; WEBUI_PORT="${6:-3000}"; OLLAMA_HOST=127.0.0.1:11434
have()     { case "$1" in nft) return "${HAVE_NFT}" ;; *) return 0 ;; esac; }
can_root() { return "${CAN_ROOT}"; }
as_root()  { printf '%s' "${NFT_DUMP}"; }
apply_guard
echo "CHANGED=${CHANGED} UNCHECKED=${UNCHECKED} BLOCKED=${BLOCKED}"
PROBE
chmod +x "${SANDBOX}/apply-probe.sh"
apply_probe() {
  bash "${SANDBOX}/apply-probe.sh" "${SANDBOX}/scripts/apply.sh" "$@" 2>&1
}
guard_noop_when_covered() {
  local out; out="$(apply_probe 0 0 "${GUARD_DUMP}" false)"
  grep -q 'CHANGED=0 UNCHECKED=0' <<<"${out}" || { echo "${out}" >&2; return 1; }
  ! grep -q 'HARDEN-CALLED' <<<"${out}"
}
# Both ways in: a guard that is loaded but has fallen behind .env, and no
# guard at all. They are separate branches, so a dry run has to be proved on
# each — testing only one leaves the other free to load a firewall during a
# run whose entire promise is that it changes nothing.
guard_hardens_on_a_drifted_port() {
  local out; out="$(apply_probe 0 0 "${GUARD_DUMP}" false 8080)"
  grep -q 'HARDEN-CALLED'   <<<"${out}" || { echo "${out}" >&2; return 1; }
  grep -q 'CHANGED=1'       <<<"${out}" || { echo "${out}" >&2; return 1; }
}
guard_hardens_when_not_loaded() {
  local out; out="$(apply_probe 0 0 "" false)"
  grep -q 'HARDEN-CALLED'   <<<"${out}" || { echo "${out}" >&2; return 1; }
  grep -q 'CHANGED=1'       <<<"${out}" || { echo "${out}" >&2; return 1; }
}
guard_dry_run_on_a_drifted_port() {
  local out; out="$(apply_probe 0 0 "${GUARD_DUMP}" true 8080)"
  grep -q 'would'           <<<"${out}" || { echo "${out}" >&2; return 1; }
  ! grep -q 'HARDEN-CALLED' <<<"${out}"
}
guard_dry_run_when_not_loaded() {
  local out; out="$(apply_probe 0 0 "" true)"
  grep -q 'would'           <<<"${out}" || { echo "${out}" >&2; return 1; }
  ! grep -q 'HARDEN-CALLED' <<<"${out}"
}
# "Could not look" must never be counted as "matches" — that is the exact
# failure this command exists to end, one level up.
guard_without_nft_is_unchecked() {
  local out; out="$(apply_probe 1 0 "" false)"
  grep -q 'CHANGED=0 UNCHECKED=1' <<<"${out}" || { echo "${out}" >&2; return 1; }
  ! grep -q 'HARDEN-CALLED' <<<"${out}"
}
guard_without_root_is_unchecked() {
  local out; out="$(apply_probe 0 1 "" false)"
  grep -q 'CHANGED=0 UNCHECKED=1' <<<"${out}" || { echo "${out}" >&2; return 1; }
  ! grep -q 'HARDEN-CALLED' <<<"${out}"
}
# The summary is a claim too. Three of its four branches already refused to
# say "everything matches" when something could not be looked at; the dry-run
# branch printed the count alone, so a reader whose docker daemon was down got
# "1 change(s) would be applied" as if that were the whole plan. Found by
# running 'lca apply --dry-run' on a box with no docker, which is exactly the
# combination — a change found elsewhere, a component unreadable.
cat > "${SANDBOX}/apply-summary-probe.sh" <<'PROBE'
#!/usr/bin/env bash
set -euo pipefail
source "$1"
apply_ollama()       { :; }
apply_webui()        { UNCHECKED=$((UNCHECKED+1)); }
apply_backup_timer() { :; }
apply_guard()        { CHANGED=$((CHANGED+1)); }
main "${@:2}"
PROBE
chmod +x "${SANDBOX}/apply-summary-probe.sh"
summary_probe() { bash "${SANDBOX}/apply-summary-probe.sh" "${SANDBOX}/scripts/apply.sh" "$@" 2>&1; }
dry_run_owns_up_to_what_it_could_not_read() {
  local out; out="$(summary_probe --dry-run)"
  grep -q 'could not be checked' <<<"${out}" || { echo "${out}" >&2; return 1; }
}
real_run_owns_up_too() {
  local out; out="$(summary_probe)"
  grep -q 'could not be checked' <<<"${out}" || { echo "${out}" >&2; return 1; }
}
check "a dry-run plan says when it could not read something" \
  dry_run_owns_up_to_what_it_could_not_read
check "and so does the real run"  real_run_owns_up_too

check "apply leaves a guard that already covers .env alone" guard_noop_when_covered
check "apply re-hardens when a port drifted"                guard_hardens_on_a_drifted_port
check "apply hardens when no guard is loaded"               guard_hardens_when_not_loaded
check "--dry-run only talks about a drifted port"           guard_dry_run_on_a_drifted_port
check "--dry-run only talks about a missing guard"          guard_dry_run_when_not_loaded
check "no nftables is 'not checked', never 'matches'"        guard_without_nft_is_unchecked
check "no root is 'not checked', never 'matches'"            guard_without_root_is_unchecked

echo "# what a boot unit will really run ('enabled' is a claim about a symlink)"
# All three of our units bake the installing checkout's absolute path into
# ExecStart. 'systemctl is-enabled' keeps answering "enabled" after that path
# is moved, renamed or deleted, so 'lca check' printed a green "inbound guard
# will be re-applied on boot" for a unit that could not start — and the ports
# it guards would be public from the next reboot on. Same shape for the backup
# timer, where the symptom is backups that silently never ran.
UNITS="${SANDBOX}/units"
mkdir -p "${UNITS}"

# systemd renders ExecStart as a brace-delimited record; the path must be read
# out of it without swallowing the argv[] tail that follows.
check "systemd's ExecStart record yields just the path" \
  test "$(show_execstart_program <<'EOF'
{ path=/opt/local-code-agent/netmode.sh ; argv[]=/opt/local-code-agent/netmode.sh apply-saved ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }
EOF
)" = "/opt/local-code-agent/netmode.sh"
# ...and a path containing a space still comes back whole, which is why the
# capture ends at the ' ; ' instead of at the first blank.
check "a path with a space survives the ExecStart record" \
  test "$(show_execstart_program <<'EOF'
{ path=/opt/my apps/lca/netmode.sh ; argv[]=/opt/my apps/lca/netmode.sh apply-saved ; ignore_errors=no }
EOF
)" = "/opt/my apps/lca/netmode.sh"

# The unit file is the fallback, and the only source when systemd is installed
# but not running. We write the quoted form; the bare form is what an older
# version of this repo left behind.
printf '[Service]\nType=oneshot\nExecStart="/opt/lca/netmode.sh" apply-saved\n' \
  > "${UNITS}/quoted.service"
printf '[Service]\nExecStart=/opt/lca/tune.sh\n' > "${UNITS}/bare.service"
printf '[Unit]\nDescription=no exec here\n'      > "${UNITS}/empty.service"
check "a quoted ExecStart parses (args dropped)" \
  test "$(execstart_program "${UNITS}/quoted.service")" = "/opt/lca/netmode.sh"
check "an unquoted ExecStart parses" \
  test "$(execstart_program "${UNITS}/bare.service")" = "/opt/lca/tune.sh"
no_execstart_is_silent()   { ! execstart_program "${UNITS}/empty.service"; }
no_unit_file_is_silent()   { ! execstart_program "${UNITS}/absent.service"; }
check "a unit with no ExecStart reports nothing"   no_execstart_is_silent
check "a unit file that is not there reports nothing" no_unit_file_is_silent

# stale_boot_program is the check-system predicate: it speaks up ONLY when it
# knows the program is gone. 'local' on the seam keeps it dynamically scoped to
# the call, so the surrounding tests are unaffected.
printf '[Service]\nExecStart="%s/scripts/lib.sh"\n' "${REPO}" > "${UNITS}/live.service"
printf '[Service]\nExecStart="%s/moved-away/netmode.sh"\n' "${REPO}" > "${UNITS}/moved.service"
moved_program_is_named() {
  local SYSTEMD_UNIT_DIR="${UNITS}"
  test "$(stale_boot_program moved.service)" = "${REPO}/moved-away/netmode.sh"
}
present_program_is_silent() {
  local SYSTEMD_UNIT_DIR="${UNITS}"
  ! stale_boot_program live.service
}
# An unknown is not a fault: with no unit file and no answer from systemd there
# is nothing to report, and a check that cries wolf about its own blind spot is
# worse than one that stays quiet.
unknown_unit_is_not_called_broken() {
  local SYSTEMD_UNIT_DIR="${UNITS}"
  ! stale_boot_program absent.service
}
check "a unit whose program moved is reported, with the missing path" \
  moved_program_is_named
check "a unit whose program is there says nothing"  present_program_is_silent
check "a unit we cannot read at all is not called broken" \
  unknown_unit_is_not_called_broken

# A unit that is merely disabled and one whose file was never written need
# different fixes, and 'lca check' offered the light one unconditionally:
# 'systemctl enable' cannot enable a file that is not there, which is the most
# likely reason it is not enabled.
enable_hint_when_the_file_is_there() {
  local SYSTEMD_UNIT_DIR="${UNITS}"
  test "$(reenable_hint live.service './setup.sh')" = "sudo systemctl enable live.service"
}
installer_hint_when_the_file_is_gone() {
  local SYSTEMD_UNIT_DIR="${UNITS}"
  test "$(reenable_hint absent.service './setup.sh')" = "./setup.sh"
}
# '--now' would also RUN the unit, which for auto-tune can mean an unasked-for
# model download; the question was about the next boot.
enable_hint_does_not_run_the_unit() {
  local SYSTEMD_UNIT_DIR="${UNITS}"
  ! grep -q -- '--now' <<<"$(reenable_hint live.service './setup.sh')"
}
check "an existing unit file is re-enabled, not re-installed" \
  enable_hint_when_the_file_is_there
check "a missing unit file sends you to the installer that writes it" \
  installer_hint_when_the_file_is_gone
check "the enable hint does not start the unit as a side effect" \
  enable_hint_does_not_run_the_unit

# ...and check-system.sh must actually consult it, for all three units, rather
# than trusting is-enabled the way it did before.
every_boot_unit_is_verified() {
  local unit
  for unit in local-code-agent-netmode.service local-code-agent-tune.service \
              local-code-agent-backup.service; do
    grep -q "stale_boot_program ${unit}" "${REPO}/check-system.sh" \
      || { printf 'check-system.sh never checks what %s really runs\n' "${unit}" >&2
           return 1; }
  done
}
check "check-system.sh verifies the program behind every boot unit" \
  every_boot_unit_is_verified

echo "# the documented way to put the inbound guard back must actually stick"
# 'netmode.sh harden' is the ONE command this repo names when the guard is
# missing — netmode status, 'lca check' twice, both installers and two docs all
# point at it — and netmode.sh's usage promises the guard survives reboots.
# For a long time it did not: harden loaded the ruleset for the current boot,
# while offline/online (which nobody is told to run to fix a missing guard)
# were the only subcommands that installed the unit re-applying it at boot.
# Following the documented recovery from "your ports are public" therefore
# made them public again at the next reboot.
harden_installs_the_boot_service() {
  grep -qE '^[[:space:]]*harden\)[[:space:]]+do_harden[[:space:]]*;;' "${REPO}/netmode.sh" \
    || { echo "netmode.sh: 'harden)' no longer dispatches to do_harden" >&2; return 1; }
  # awk's exit still runs END, so a body that ends before the match fails.
  awk '/^do_harden\(\) \{/     { inb=1; next }
       inb && /^\}/            { exit }
       inb && /install_service/ { found=1 }
       END { exit !found }' "${REPO}/netmode.sh" \
    || { echo "netmode.sh: do_harden does not install the boot service" >&2; return 1; }
  # ...and it still applies the guard now, which is the point of the command.
  awk '/^do_harden\(\) \{/         { inb=1; next }
       inb && /^\}/                { exit }
       inb && /apply_inbound_guard/ { found=1 }
       END { exit !found }' "${REPO}/netmode.sh" \
    || { echo "netmode.sh: do_harden no longer applies the guard" >&2; return 1; }
}
check "'netmode.sh harden' also installs the boot service" \
  harden_installs_the_boot_service

# ...and it must not report a systemd problem as a firewall problem. Both
# installers call 'netmode.sh harden' and turn ANY non-zero exit into "Could
# not apply the inbound guard — the port may be publicly reachable". Once the
# guard is up, exiting non-zero because the boot unit could not be written
# would send the reader chasing a firewall that is fine.
#
# Run for real rather than grepped: netmode.sh minus its 'main "$@"' line is
# just function definitions, and SCRIPT_DIR then resolves to the sandbox,
# which already holds a copy of lib.sh.
grep -v '^main "\$@"$' "${REPO}/netmode.sh" > "${SANDBOX}/netmode-funcs.sh"
cat > "${SANDBOX}/harden-probe.sh" <<'PROBE'
#!/usr/bin/env bash
# $1 = the function definitions, $2 = the exit status install_service should
# fake. Captured up front: inside the stub, $2 would be the stub's own arg.
set -euo pipefail
RC="$2"
source "$1"
apply_inbound_guard() { echo "GUARD-APPLIED"; }
install_service()     { return "${RC}"; }
do_harden
echo "HARDEN-RETURNED-0"
PROBE
cat > "${SANDBOX}/require-probe.sh" <<'PROBE'
#!/usr/bin/env bash
set -euo pipefail
RC="$2"
source "$1"
install_service() { return "${RC}"; }
require_service
echo "REQUIRE-RETURNED-0"
PROBE
chmod +x "${SANDBOX}/harden-probe.sh" "${SANDBOX}/require-probe.sh"
harden_probe()  { bash "${SANDBOX}/harden-probe.sh"  "${SANDBOX}/netmode-funcs.sh" "$1" 2>&1; }

# 'netmode.sh status' is what the README and TROUBLESHOOTING tell you to run to
# find out whether the guard is up. It said 'inbound_loaded; inbound_rc=$?' —
# leaving inbound_loaded an UNTESTED command, so under errexit a non-zero
# return killed the script right there, before the case that reports it and
# before the live probe. inbound_loaded returns 1 for "not loaded" and 2 for
# "cannot tell without root", so status printed three lines and stopped, exit
# 1, no explanation, in exactly the two situations it exists for. Observed on a
# box with no guard: the "NOT loaded" warning never appeared.
cat > "${SANDBOX}/status-probe.sh" <<'PROBE'
#!/usr/bin/env bash
# $1 = function definitions, $2 = what inbound_loaded should return.
set -euo pipefail
RC="$2"
source "$1"
have()           { [[ "$1" == nft ]]; }
table_loaded()   { return 1; }
netmode_state()  { printf 'online'; }
inbound_loaded() { return "${RC}"; }
curl()           { return 0; }
show_status
echo "STATUS-REACHED-THE-END"
PROBE
status_probe() { bash "${SANDBOX}/status-probe.sh" "${SANDBOX}/netmode-funcs.sh" "$1" 2>&1; }
status_survives() {  # $1 = inbound_loaded's return, $2 = text it must report
  local out rc=0
  out="$(status_probe "$1")" || rc=$?
  (( rc == 0 )) || {
    printf 'status exited %s when inbound_loaded returned %s:\n%s\n' "${rc}" "$1" "${out}" >&2
    return 1
  }
  grep -q "$2" <<<"${out}" || {
    printf 'status did not report "%s":\n%s\n' "$2" "${out}" >&2; return 1; }
  grep -q 'STATUS-REACHED-THE-END' <<<"${out}" || {
    printf 'status stopped before the live probe:\n%s\n' "${out}" >&2; return 1; }
}
status_reports_a_missing_guard() { status_survives 1 'inbound guard NOT loaded'; }
status_reports_an_unknown_guard() { status_survives 2 'UNKNOWN'; }
check "'netmode status' reports a MISSING guard instead of dying" \
  status_reports_a_missing_guard
check "'netmode status' reports an UNKNOWN guard instead of dying" \
  status_reports_an_unknown_guard
require_probe() { bash "${SANDBOX}/require-probe.sh" "${SANDBOX}/netmode-funcs.sh" "$1" 2>&1; }

harden_reports_a_failed_service_as_a_warning() {
  local out
  out="$(harden_probe 1)" || {
    printf 'harden exited non-zero because the boot service failed:\n%s\n' "${out}" >&2
    return 1
  }
  grep -q 'GUARD-APPLIED'      <<<"${out}" || return 1
  grep -q 'HARDEN-RETURNED-0'  <<<"${out}" || return 1
  # and it has to actually say so, or the reboot exposure is silent
  grep -qi 'reboot'            <<<"${out}" || {
    printf 'harden swallowed the boot-service failure without a word:\n%s\n' "${out}" >&2
    return 1
  }
}
harden_is_quiet_when_the_service_installs() {
  local out
  out="$(harden_probe 0)" || return 1
  ! grep -qi 'reboot' <<<"${out}"
}
# The same failure IS fatal where installing the unit is the whole job:
# setup.sh, offline and online all go through require_service.
require_service_still_dies() {
  local out
  out="$(require_probe 1)" && {
    printf 'require_service returned 0 on a failed install:\n%s\n' "${out}" >&2
    return 1
  }
  grep -q 'systemctl status local-code-agent-netmode' <<<"${out}"
}
fatal_callers_use_require_service() {
  local hits
  # go_offline, go_online and the --install-service dispatch, and nothing else.
  # Comments and the definition itself are stripped so only calls are counted.
  hits="$(grep -v '^[[:space:]]*#' "${REPO}/netmode.sh" \
            | grep -v 'require_service() {' \
            | grep -c 'require_service')"
  (( hits == 3 )) || { printf 'expected 3 require_service callers, found %s\n' "${hits}" >&2
                       return 1; }
}
check "harden warns (not fails) when only the boot service breaks" \
  harden_reports_a_failed_service_as_a_warning
check "harden says nothing about reboots when the service installs" \
  harden_is_quiet_when_the_service_installs
check "installing the unit is still fatal where that IS the job" \
  require_service_still_dies
check "offline, online and --install-service all go through require_service" \
  fatal_callers_use_require_service

# install_service checks every privileged step itself instead of leaning on
# errexit, because errexit is suppressed for any command whose status is
# tested — which is exactly how do_harden calls it. Without the explicit
# checks, a tee that never wrote the unit file would be followed by a
# successful enable and reported as a healthy install.
cat > "${SANDBOX}/service-probe.sh" <<'PROBE'
#!/usr/bin/env bash
# $1 = function definitions, $2 = the one privileged step to fail.
set -euo pipefail
BREAK="$2"
source "$1"
systemd_available() { return 0; }
as_root() {
  case " $* " in *" ${BREAK} "*) return 1 ;; esac
  # The real 'as_root tee' reads the unit text from a pipe. A stub that
  # returns without consuming it leaves the writer to take EPIPE, which
  # pipefail then reports as a failed install — at random, depending on who
  # wins the race. Drain it.
  case "$1" in tee) cat >/dev/null ;; esac
  return 0
}
install_service && echo "INSTALL-SAID-OK" || echo "INSTALL-SAID-FAILED"
PROBE
service_probe() {
  bash "${SANDBOX}/service-probe.sh" "${SANDBOX}/netmode-funcs.sh" "$1" 2>&1
}
step_failure_is_reported() {
  local out
  out="$(service_probe "$1")"
  grep -q 'INSTALL-SAID-FAILED' <<<"${out}" || {
    printf 'a failing "%s" was reported as a healthy install:\n%s\n' "$1" "${out}" >&2
    return 1
  }
}
tee_failure_is_reported()     { step_failure_is_reported tee; }
reload_failure_is_reported()  { step_failure_is_reported daemon-reload; }
enable_failure_is_reported()  { step_failure_is_reported enable; }
healthy_install_says_ok()     { grep -q 'INSTALL-SAID-OK' <<<"$(service_probe nothing-fails)"; }
check "a unit file that could not be written is a failed install" \
  tee_failure_is_reported
check "a daemon-reload that failed is a failed install" \
  reload_failure_is_reported
check "an enable that failed is a failed install" \
  enable_failure_is_reported
check "and an install where everything worked reports success" \
  healthy_install_says_ok

# --install-service is internal: setup.sh and CI call it, and netmode.sh's own
# usage does not list it. 'lca check' used to print it as the Fix: for a
# missing boot service, sending someone to a flag they cannot look up. Advice a
# human reads has to name a command that command's --help documents. Scoped to
# the surfaces that give advice — tune.sh documents its own flag, legitimately,
# and setup.sh/CI invoke both programmatically.
advice_names_only_documented_commands() {
  local hits
  hits="$(grep -n -- '--install-service' \
            "${REPO}/check-system.sh" "${REPO}/bin/lca" "${REPO}/README.md" \
            "${REPO}"/scripts/install_*.sh "${REPO}"/docs/*.md 2>/dev/null || true)"
  [[ -z "${hits}" ]] || {
    printf 'these send a user to the internal --install-service flag:\n%s\n' "${hits}" >&2
    return 1
  }
}
check "no user-facing message recommends the internal --install-service flag" \
  advice_names_only_documented_commands

# The general form of that rule, because finding these one at a time is how
# the last one survived: every 'some-script.sh --flag' this project puts in
# front of a human must be a flag that script actually documents. A doc that
# names a flag the script rejects is worse than no doc — the reader follows
# it, gets "Unknown option", and has no way to tell whether the feature or
# the sentence is the broken one.
#
# Scoped to the surfaces that only ever give advice. setup.sh and CI *invoke*
# these scripts, and an invocation is not a recommendation.
script_help_text() {  # header comment block + usage() body + any quoted line
  awk 'BEGIN { inhdr = 1 }
       NR == 1          { next }
       inhdr && /^#/    { print; next }
       inhdr            { inhdr = 0 }
       /^usage\(\) *\{/ { inu = 1; next }
       inu && /^\}/     { inu = 0; next }
       inu || /"/       { print }' "$1"
}
every_advised_flag_is_real() {
  local surfaces=( "${REPO}/README.md" "${REPO}"/docs/*.md "${REPO}/check-system.sh"
                   "${REPO}/bin/lca" "${REPO}/webui.sh" "${REPO}"/scripts/install_*.sh )
  local script flag path cand text unlisted=()
  while read -r script flag; do
    [[ -n "${script}" ]] || continue
    path=""
    for cand in "${REPO}/${script}" "${REPO}/scripts/${script}"; do
      if [[ -f "${cand}" ]]; then path="${cand}"; fi
    done
    if [[ -z "${path}" ]]; then
      unlisted+=("${script} ${flag} — no such script")
      continue
    fi
    text="$(script_help_text "${path}")"
    # if/fi, not '&& continue': a failing && list is only survivable because
    # check() tests this function's status and errexit is suppressed for it.
    # Written this way it does not depend on who calls it.
    if grep -qF -- "${flag}" <<<"${text}"; then
      continue
    fi
    # A script whose usage advertises '[... args...]' forwards what it does
    # not recognise (run-agent.sh hands everything to aider), so the flag
    # namespace is not its own to document.
    if grep -qE 'args\.\.\.\]' <<<"${text}"; then
      continue
    fi
    unlisted+=("${script} ${flag}")
  done < <(grep -rhoE '[a-z][a-z_-]*\.sh"? --[a-z-]+' "${surfaces[@]}" | tr -d '"' | sort -u)
  (( ${#unlisted[@]} == 0 )) || {
    printf 'advised flags that the script does not document:\n' >&2
    printf '  %s\n' "${unlisted[@]}" >&2
    return 1
  }
}
check "every flag we tell a human to run is one that script documents" \
  every_advised_flag_is_real

echo "# every 'lca' subcommand must answer --help, and only answer it"
# 'lca test --help' ran the whole acceptance suite: minutes of real generation,
# because selftest.sh never looked at "$@". 'lca restore --help' answered
# "Backup file not found: --help" — true, useless, and from a command that
# wipes a docker volume when it does work. 'lca webui --help' needed a running
# Docker daemon to print a page of text, on the machine where the daemon being
# down is what sent you looking for help in the first place.
#
# Run for real, not grepped: the claim is about what happens, and each of those
# three had a --help-shaped hole that reading the source did not make obvious.
# run-agent.sh is out — it forwards to aider, whose --help is aider's to print.
help_is_answered_not_performed() {
  local s out rc broken=()
  for s in "${LCA_TARGETS[@]}"; do
    # A timeout is part of the assertion: a script that ignores --help and does
    # its job is exactly the failure this catches, and some jobs take minutes.
    out="$(timeout 20 "${REPO}/${s}" --help 2>&1)"; rc=$?
    if (( rc != 0 )); then
      broken+=("${s}: --help exited ${rc}")
    elif ! grep -qi 'usage' <<<"${out}"; then
      # Not decoration: printing usage is how we tell "explained itself" from
      # "went and did the thing, successfully, and said so".
      broken+=("${s}: --help exited 0 but printed no usage")
    fi
  done
  (( ${#broken[@]} == 0 )) || {
    printf 'these do not answer --help:\n' >&2
    printf '  %s\n' "${broken[@]}" >&2
    return 1
  }
}
check "every script 'lca' dispatches to explains itself on --help" \
  help_is_answered_not_performed
# ...and the list above has to stay the list. bin/lca gaining a subcommand
# whose script is never asked is how the next selftest.sh happens.
every_dispatch_target_is_checked() {
  local target missing=()
  while read -r target; do
    [[ -n "${target}" ]] || continue
    [[ "${target}" == "run-agent.sh" ]] && continue
    printf '%s\n' "${LCA_TARGETS[@]}" | grep -qx "${target}" || missing+=("${target}")
  done < <(grep -oE '\$\{REPO\}/[a-z/-]+\.sh' "${REPO}/bin/lca" \
             | sed 's|[$]{REPO}/||' | sort -u)
  (( ${#missing[@]} == 0 )) || {
    printf 'bin/lca dispatches to these, and no --help test covers them:\n' >&2
    printf '  %s\n' "${missing[@]}" >&2
    return 1
  }
}
check "the --help list covers everything bin/lca dispatches to" \
  every_dispatch_target_is_checked

# The two that are NOT dispatched, and are the worst of the lot: './install.sh
# --help' installed packages and cloned into ${LCA_DIR}, and './setup.sh
# --help' began installing the whole stack as root. Both were found by running
# them — each had to be killed by a timeout, and the first left a checkout on
# disk.
#
# Structural, not behavioural. Everywhere else the --help check runs the
# script, because the claim is about what happens; here a failing check would
# install packages as root on whoever ran the suite, which is worse than the
# bug it guards. So it asserts the shape that produces the behaviour — the
# --help branch must be the FIRST thing main() does, above every side effect —
# and the behaviour itself was verified by hand once the shape was in place.
installers_answer_help_before_acting() {
  local f
  for f in install.sh setup.sh; do
    awk '/^main\(\) \{/            { inm = 1; next }
         inm && /^[[:space:]]*#/   { next }
         inm && /^[[:space:]]*$/   { next }
         inm                       { first = $0; exit }
         END { exit !(first ~ /case "\$\{1:-\}" in/) }' "${REPO}/${f}" || {
      printf '%s: main() does something before it checks for --help\n' "${f}" >&2
      return 1
    }
  done
}
check "install.sh and setup.sh explain themselves before they install anything" \
  installers_answer_help_before_acting

# The scripts answering --help only helps if the flag reaches them. 'chat' was
# 'exec webui.sh url' with no "$@", so 'lca chat --help' printed the chat
# address — one line after 'lca help' promises every command explains itself.
every_dispatch_forwards_its_arguments() {
  local hits
  hits="$(grep -nE '^[[:space:]]*[^#]*exec "\$\{REPO\}/[a-z/-]+\.sh"' "${REPO}/bin/lca" \
            | grep -v '"\$@"' || true)"
  [[ -z "${hits}" ]] || {
    printf 'these swallow the arguments, so --help never reaches the script:\n%s\n' "${hits}" >&2
    return 1
  }
}
check "every 'lca' branch passes its arguments through" \
  every_dispatch_forwards_its_arguments

# netmode.sh takes its subcommand as $1 and used to ignore everything after
# it, while bin/lca forwards trailing arguments verbatim. So 'lca harden
# --help' arrived as 'netmode.sh harden --help' and APPLIED THE FIREWALL —
# the same bug as selftest.sh, on the one command where doing the thing
# instead of describing it changes the machine's network.
#
# Exercised through 'status', which only reads. That is deliberate: if this
# check ever fails it must fail harmlessly, and a test that proves 'harden
# --help' is safe by running 'harden' would be its own worst outcome. The
# guard is one branch, so status proves it for all four.
netmode_help_is_not_an_action() {
  local out rc
  out="$(timeout 20 "${REPO}/netmode.sh" status --help 2>&1)"; rc=$?
  (( rc == 0 )) || {
    printf 'netmode.sh status --help exited %s:\n%s\n' "${rc}" "${out}" >&2
    return 1
  }
  grep -q 'Kill-switch ON' <<<"${out}" || {
    printf 'netmode.sh status --help did not print usage:\n%s\n' "${out}" >&2
    return 1
  }
  # 'netmode:' is what show_status prints; usage never does. Its presence means
  # the flag was ignored and the subcommand ran.
  ! grep -q 'netmode:' <<<"${out}"
}
# ...and the check has to sit ABOVE the dispatch, or it guards nothing.
netmode_checks_args_before_acting() {
  awk '/^main\(\) \{/                 { inm = 1 }
       inm && /case "\$\{2:-\}" in/   { second = NR }
       inm && /case "\$\{1:-\}" in/   { first = NR; exit }
       END { exit !(second && first && second < first) }' "${REPO}/netmode.sh"
}
check "'lca harden --help' explains the firewall instead of applying it" \
  netmode_help_is_not_an_action
check "netmode validates its extra argument before it dispatches" \
  netmode_checks_args_before_acting

echo "# advice has to work from where the reader is standing"
# bin/lca never cd's — that is the whole point, aider must see YOUR project —
# so 'lca check' from ~/my-project ran a health check that answered
# "(./webui.sh start)" and "run scripts/tune.sh". Neither resolves there. The
# reader types it, gets "No such file or directory", and now has two problems.
# Every path a message names must be absolute.
advice_paths_are_absolute() {
  local hits
  # Message helpers only: an 'echo' inside a render function is writing a file,
  # not talking to anyone. ${SCRIPT_DIR}/${REPO_ROOT} are erased first so an
  # already-absolute path cannot match, then anything relative still standing
  # is a defect.
  hits="$(grep -nE '\b(warn|info|die|err|ok|p_pass|p_warn|p_fail)[[:space:]]+"' \
            "${REPO}"/*.sh "${REPO}"/scripts/*.sh "${REPO}"/deploy/*.sh 2>/dev/null \
          | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
          | sed 's|[$]{SCRIPT_DIR}||g; s|[$]{REPO_ROOT}||g' \
          | grep -E '(\./|[[:space:]("'"'"']scripts/)[a-z_-]+\.sh' || true)"
  [[ -z "${hits}" ]] || {
    printf 'these name a path that only resolves inside the checkout:\n%s\n' "${hits}" >&2
    return 1
  }
  # A bare script name is the same defect wearing no prefix. 'lca model
  # --list-recommended' answered "Switch with:  update-model.sh <model>",
  # which matches neither './' nor 'scripts/' and so read as ordinary prose to
  # the scan above — while being a command, for a file that is not on PATH and
  # not in the reader's directory. Only imperative phrasings count: "setup.sh
  # will pull ${MODEL}" describes what happens and is not an instruction.
  hits="$(grep -nE '\b(warn|info|die|err|ok|p_pass|p_warn|p_fail)[[:space:]]+"' \
            "${REPO}"/*.sh "${REPO}"/scripts/*.sh "${REPO}"/deploy/*.sh 2>/dev/null \
          | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
          | sed 's|[$]{SCRIPT_DIR}||g; s|[$]{REPO_ROOT}||g' \
          | grep -oiE "(run|re-run|check|try|with|usage)['\":]? +[a-z][a-z_-]*\.sh" || true)"
  [[ -z "${hits}" ]] || {
    printf 'these tell the reader to run a bare script name:\n%s\n' "${hits}" >&2
    return 1
  }
  # Usage text is advice too, and it is not written with a message helper —
  # webui.sh's ended with "run: scripts/install_webui.sh" and slipped straight
  # past the scan above. Scoped to what 'lca' dispatches to, because that is
  # the rule: those run in the user's directory. scripts/prompt-bench.sh names
  # itself relatively and may, being a 'make bench' tool run from the checkout.
  # A one-line 'usage() { ...; }' closes on its own line, so the extractor has
  # to stop there. Without that branch it ran on to main()'s closing brace and
  # scanned the whole function as if it were help text — update.sh is written
  # that way, and it passed only because nothing in main() happened to match.
  local s body
  for s in "${LCA_TARGETS[@]}"; do
    body="$(awk '/^usage\(\) *\{/ { if ($0 ~ /\}[[:space:]]*$/) { print; next }
                                    inu = 1; next }
                 inu && /^\}/     { inu = 0; next }
                 inu              { print }' "${REPO}/${s}" \
              | sed 's|[$]{SCRIPT_DIR}||g; s|[$]{REPO_ROOT}||g')"
    hits="$(grep -E '(\./|[[:space:]("]scripts/)[a-z_-]+\.sh' <<<"${body}" || true)"
    [[ -z "${hits}" ]] || {
      printf '%s prints usage text naming a path that only resolves inside the checkout:\n%s\n' \
        "${s}" "${hits}" >&2
      return 1
    }
    # Bare names too. 'lca model' opened with "Usage: update-model.sh <model>",
    # six times over, for a file that is not on PATH — and neither the path
    # rule (no './' or 'scripts/' to match) nor the message-helper rule (usage
    # is a heredoc, not a warn) could see it. Imperative phrasings only, so
    # "(or webui.sh directly)" stays legal: that tells you what the script is
    # called, it does not ask you to type it.
    hits="$(grep -iE "(run|re-run|check|try|with|usage)['\":]? +[a-z][a-z_-]*\.sh" <<<"${body}" || true)"
    [[ -z "${hits}" ]] || {
      printf '%s prints usage text telling the reader to run a bare script name:\n%s\n' \
        "${s}" "${hits}" >&2
      return 1
    }
  done
}
check "every path a message names resolves from any directory" \
  advice_paths_are_absolute

# The same rule for the docs, where it takes a different shape: a fenced block
# may say './setup.sh' — there is no 'lca' equivalent and there cannot be one
# before the install — but then the block has to put the reader in the right
# directory first. Everything with an 'lca' subcommand uses that instead, which
# needs no cd at all.
doc_blocks_establish_their_directory() {
  local hits
  hits="$(awk '
    FNR == 1 { inb = 0; usesrel = 0; hascd = 0 }
    /^```/ {
      if (inb) {
        if (usesrel && !hascd)
          printf "%s:%d: this block runs ./script.sh without a cd\n", FILENAME, start
        inb = 0; usesrel = 0; hascd = 0
      } else { inb = 1; start = FNR }
      next
    }
    inb && /(^|[[:space:]])\.\/[a-z_-]+\.sh/ { usesrel = 1 }
    inb && /^[[:space:]]*cd /                { hascd = 1 }
  ' "${REPO}/README.md" "${REPO}"/docs/*.md)"
  [[ -z "${hits}" ]] || {
    printf 'a reader following these would be in the wrong directory:\n%s\n' "${hits}" >&2
    return 1
  }
  # And in prose, where a block's cd cannot help: INSTALL.md taught "Daily
  # usage: `run-agent.sh` in any project directory", which is the right idea
  # attached to a name that is not on PATH — 'lca' is the command that exists
  # for exactly that. Imperative phrasings only, so that describing a file
  # ("`scripts/install_webui.sh` now refuses to start on a taken port") stays
  # legal; it is a statement about the code, not an instruction.
  hits="$(grep -rniE "(run|re-run|check|try|with|usage)['\":\` ]+ ?[a-z][a-z_-]*\.sh" \
            "${REPO}/README.md" "${REPO}"/docs/*.md 2>/dev/null || true)"
  [[ -z "${hits}" ]] || {
    printf 'these docs tell the reader to run a name that is not on PATH:\n%s\n' "${hits}" >&2
    return 1
  }
}
check "every doc block that runs a script says where to stand" \
  doc_blocks_establish_their_directory

echo "# the 'lca' command is a symlink, and a moved checkout leaves it dangling"
# Every doc and message here says "type lca". Move the checkout and the symlink
# dangles — including 'lca check', which is exactly what someone reaches for
# when the stack seems broken. Real symlinks, because the whole question is
# what readlink and -x do with them.
LINKS="${SANDBOX}/links"
mkdir -p "${LINKS}/real/bin" "${LINKS}/other/bin"
printf '#!/usr/bin/env bash\n' > "${LINKS}/real/bin/lca"
printf '#!/usr/bin/env bash\n' > "${LINKS}/other/bin/lca"
chmod +x "${LINKS}/real/bin/lca" "${LINKS}/other/bin/lca"
ln -s "${LINKS}/real/bin/lca"  "${LINKS}/ok"
ln -s "${LINKS}/other/bin/lca" "${LINKS}/foreign"
ln -s "${LINKS}/gone/bin/lca"  "${LINKS}/moved"     # whole checkout renamed
ln -s "${LINKS}/real/bin/nope" "${LINKS}/deleted"   # just the file removed
printf 'not a link\n' > "${LINKS}/plain"
state_of() { lca_link_state "${LINKS}/$1" "${LINKS}/real/bin/lca"; }
check "a link into this checkout is ok"          test "$(state_of ok)"      = ok
check "a renamed checkout reads as broken"       test "$(state_of moved)"   = broken
check "a deleted target reads as broken too"     test "$(state_of deleted)" = broken
check "a link into another checkout is foreign"  test "$(state_of foreign)" = foreign
check "a real file at that path is not ours"     test "$(state_of plain)"   = other
check "nothing there at all is absent"           test "$(state_of nowhere)" = absent
# The comparison has to survive the two sides being spelled differently.
# check-system.sh builds its side with 'cd && pwd', which keeps a symlinked
# path, while readlink -f hands back the physical one — so an install reached
# through a symlinked parent would read as 'foreign' and shout about a healthy
# machine.
ln -s "${LINKS}/real" "${LINKS}/real-alias"
check "a checkout reached through a symlinked parent is still ok" \
  test "$(lca_link_state "${LINKS}/ok" "${LINKS}/real-alias/bin/lca")" = ok
lca_link_is_reported() { grep -q 'lca_link_state' "${REPO}/check-system.sh"; }
check "check-system.sh reports on the lca command" lca_link_is_reported

echo "# the guard renderer and the guard reader, run against each other"
# inbound_guard_uncovered is the rule behind two user-facing claims — 'lca
# check' printing "does NOT cover", and 'lca apply' deciding whether to reload
# the firewall — and until now the only input it was ever given was a
# hand-written fixture. Nothing checked it against what netmode.sh actually
# emits. A renderer that changed its port-set syntax would make the reader
# report every port uncovered: 'lca check' failing on a healthy machine and
# 'lca apply' re-hardening on every run, with the unit tests still green
# because they were reading a copy.
#
# Renders for real, in a throwaway checkout, and asserts the reader agrees.
guard_round_trip() {  # $1 = .env content, $2 = label
  # Not 'gaps': inbound_guard_uncovered declares a local array by that name and
  # ShellCheck -x follows the source, so a string here reads as SC2178.
  local sandbox dump uncovered_out rc=0
  sandbox="$(mktemp -d)"
  ( cd "${REPO}" && tar -c --exclude=.venv --exclude=.git --exclude=backups . ) \
    | tar -x -C "${sandbox}"
  printf '%s\n' "$1" > "${sandbox}/.env"
  dump="$("${sandbox}/netmode.sh" render-inbound 2>/dev/null || true)"
  rm -rf "${sandbox}"
  [[ -n "${dump}" ]] || {
    printf '%s: render-inbound produced nothing\n' "$2" >&2; return 1; }
  # The reader is driven with the SAME .env the renderer just used.
  # A separate process, not a subshell: sourcing lib.sh inline makes ShellCheck
  # link this to unrelated subshell assignments elsewhere in the suite (SC2030),
  # and a child is a cleaner boundary anyway — the reader sees exactly this
  # .env and nothing the suite happens to have set.
  uncovered_out="$(bash -c '
      set -uo pipefail
      source "$1" >/dev/null 2>&1
      source <(printf "%s\n" "$2") >/dev/null 2>&1
      ENABLE_WEBUI="${ENABLE_WEBUI:-true}"
      inbound_guard_uncovered "$3" || true
    ' _ "${REPO}/scripts/lib.sh" "$1" "${dump}")" || rc=$?
  (( rc == 0 )) || { printf '%s: reader errored\n' "$2" >&2; return 1; }
  [[ -z "${uncovered_out}" ]] || {
    printf '%s: the reader says these are uncovered in a guard the renderer just wrote for them:\n%s\n' \
      "$2" "${uncovered_out}" >&2
    return 1
  }
}
default_ports_round_trip() {
  guard_round_trip 'WEBUI_PORT=3000
OLLAMA_HOST="127.0.0.1:11434"' 'default ports'
}
custom_ports_round_trip() {
  guard_round_trip 'WEBUI_PORT="8080" # moved
OLLAMA_HOST="0.0.0.0:11500"' 'custom ports'
}
webui_off_round_trip() {
  guard_round_trip 'ENABLE_WEBUI=false
WEBUI_PORT=3000
OLLAMA_HOST="0.0.0.0:11434"' 'chat app disabled'
}
ssh_port_round_trip() {
  # WEBUI_PORT=22 is refused by the renderer and excluded by the reader; they
  # have to agree about that too, or 'lca check' fails forever on a box nobody
  # can fix.
  guard_round_trip 'WEBUI_PORT=22
OLLAMA_HOST="127.0.0.1:11434"' 'WebUI on the SSH port'
}
check "the reader agrees with a freshly rendered guard (default ports)" \
  default_ports_round_trip
check "...with custom ports"            custom_ports_round_trip
check "...with the chat app disabled"   webui_off_round_trip
check "...with WEBUI_PORT=22 refused"   ssh_port_round_trip

echo "# one ladder, not a shared table and a copied staircase"
# check-system.sh sources tune.sh so the two cannot disagree — and then
# re-implemented the rung selection inline, dropping choose_for_ram's fallback
# for a family whose smallest size will not fit the machine. Measured with
# MODEL_FAMILY=deepseek-coder-v2 (16b only) at 8 GiB: tune.sh chooses
# qwen2.5-coder:3b, the inline copy demanded deepseek-coder-v2:16b, and the
# health check told the reader to run the script that had just chosen right.
ladder_agrees_with_tune() {
  local fam ram real
  # Drive the real chooser exactly as check-system now does.
  for fam in qwen2.5-coder deepseek-coder-v2 qwen3; do
    for ram in 4 8 12 16 24 64; do
      real="$(MODEL_FAMILY="${fam}" bash -c '
                set -uo pipefail
                source "$1" >/dev/null 2>&1
                source "$2" >/dev/null 2>&1
                TUNE_MODEL=""; choose_for_ram "$3" 2>/dev/null
                printf "%s" "${TUNE_MODEL}"' _ \
                "${REPO}/scripts/lib.sh" "${REPO}/scripts/tune.sh" "${ram}")"
      [[ -n "${real}" ]] || {
        printf 'choose_for_ram returned nothing for %s at %s GiB\n' "${fam}" "${ram}" >&2
        return 1
      }
    done
  done
  # ...and check-system must call it rather than keep its own staircase.
  grep -q 'choose_for_ram "[$]{RAM_GIB}"' "${REPO}/check-system.sh" || {
    echo 'check-system.sh does not use choose_for_ram' >&2; return 1; }
  awk '/^[[:space:]]*#/ { next }
       /RAM_GIB < 9/ || /RAM_GIB <= 15/ { found = 1 }
       END { exit found }' "${REPO}/check-system.sh" || {
    echo 'check-system.sh still has its own copy of the RAM ladder' >&2; return 1; }
}
check "check-system uses tune.sh's chooser instead of a copy of the ladder" \
  ladder_agrees_with_tune

echo "# backups hold the session-signing key, so they cannot be world-readable"
# Every archive contains the Open WebUI database — account password hashes and
# the JWT signing key, which mints valid sessions for any account — plus a copy
# of .env. On this box they were found as -rw-r--r-- inside a drwxr-xr-x
# backups/, so any other login could read all of it. The directory permission
# is what actually gates access; the umask is defence in depth on the file.
umask_really_gives_owner_only() {
  local f="${SANDBOX}/umask.probe" mode
  ( umask 077; : > "${f}" )
  mode="$(stat -c '%a' "${f}")"; rm -f "${f}"
  [[ "${mode}" == 600 ]]
}
check "umask 077 produces a 600 file" umask_really_gives_owner_only
backup_is_not_world_readable() {
  local body
  # Scoped to do_backup, not a whole-file grep. install_timer also chmods the
  # directory, and the first version of this check was satisfied by that one
  # alone — deleting the chmod from do_backup, which is the one that runs on
  # every single backup, passed a full green suite. Proved by mutation, which
  # is the only reason it was noticed.
  awk '/^do_backup\(\) \{/            { inb = 1; next }
       inb && /^\}/                   { exit }
       inb && /^[[:space:]]*#/        { next }
       inb && /chmod 700 "\$\{BACKUP_DIR\}"/ { found = 1 }
       END { exit !found }' "${REPO}/backup.sh" || {
    echo 'do_backup does not restrict backups/ to its owner' >&2; return 1; }
  body="$(grep -v '^[[:space:]]*#' "${REPO}/backup.sh")"
  (( $(grep -c 'chmod 700 "[$]{BACKUP_DIR}"' <<<"${body}") >= 2 )) || {
    echo 'the timer install no longer restricts backups/ either' >&2; return 1; }
  # umask BEFORE the tar, not a chmod after it: tar creates the file the moment
  # it starts, so a later chmod only closes it once the secrets are on disk.
  awk '/^[[:space:]]*#/ { next }
       /umask 077/       { if (!tarred) umasked = NR }
       /tar czf .*tarball/ { tarred = NR }
       END { exit !(umasked && tarred && umasked < tarred) }' "${REPO}/backup.sh" || {
    echo 'backup.sh writes the tarball before narrowing the umask' >&2; return 1; }
}
check "backup.sh keeps backups/ and new archives owner-only" \
  backup_is_not_world_readable

echo "# a backup must not leave the chat app frozen for the next one to inherit"
# backup.sh pauses the WebUI container so the SQLite snapshot is consistent,
# with an EXIT trap to guarantee the unpause. A signal the trap cannot catch
# leaves it paused — and a paused container still reports State.Running=true,
# while 'docker pause' fails on it. The old order asked Running first, so that
# failure took the "could not pause" branch: no trap, 'paused' left false, no
# unpause at the end. Every later backup then archived happily and left the
# chat app frozen and unreachable, with the warning saying it was "archiving
# live" — the opposite of what was happening.
#
# Structural, because the behaviour needs a docker daemon and a container that
# has been killed mid-pause. The shape is what produces it: Paused has to be
# asked before Running, or the already-paused case cannot be seen at all.
backup_checks_paused_before_running() {
  # Comments stripped first. The comment above this very check explains the bug
  # by naming State.Running, and the first version of this scanner counted that
  # sentence as the code — failing on the fixed file. Same trap as every other
  # whole-file grep in this suite: the explanation matches the pattern.
  awk '/^[[:space:]]*#/ { next }
       /State.Paused/   { if (!paused)  paused  = NR }
       /State.Running/  { if (!running) running = NR }
       END { exit !(paused && running && paused < running) }' "${REPO}/backup.sh" || {
    printf 'backup.sh asks State.Running before State.Paused, so a container left paused reads as running\n' >&2
    return 1
  }
  # ...and finding it paused must take responsibility for resuming it.
  awk '/State.Paused/ { inb = 1 }
       inb && /paused=true/ { found = 1 }
       inb && /elif/ { exit }
       END { exit !found }' "${REPO}/backup.sh" || {
    printf 'backup.sh sees an already-paused container but does not adopt the unpause\n' >&2
    return 1
  }
}
check "backup.sh notices a container left paused by an earlier run" \
  backup_checks_paused_before_running

echo "# the volume restore must know whether it already emptied the volume"
# restore.sh replaces the WebUI volume by clearing it and unpacking over it.
# It used to be one '&&' chain, so a failure anywhere landed in a single branch
# that said "Your existing WebUI data was NOT wiped (the archive is validated
# before the volume is replaced)". True if the archive would not read. False —
# on the one path where the reader most needs the truth — if the unpack died
# after 'rm -rf' had run, which is what a disk filling mid-restore does.
#
# The SHIPPED script is extracted from restore.sh and run against fixtures, so
# this tests the string that actually reaches the container, not a copy of it.
VOL="${SANDBOX}/vol"; mkdir -p "${VOL}/from" "${VOL}/to" "${VOL}/bin"
vol_payload() {
  local p
  p="$(awk "/-c 'tar tzf/,/exit 5'/" "${REPO}/restore.sh" | sed 's/^[[:space:]]*//')"
  p="${p#-c \'}"
  p="${p%\' \\}"
  p="${p//\/from/${VOL}\/from}"
  p="${p//\/to/${VOL}\/to}"
  printf '%s' "${p}"
}
# If restore.sh is rewritten so this stops matching, say THAT rather than
# letting three behaviour tests fail for a reason none of them is about.
payload_was_extracted() {
  local p; p="$(vol_payload)"
  [[ "${p}" == *'tar tzf'* && "${p}" == *'exit 5'* ]] || {
    printf 'could not extract the container script from restore.sh; got:\n%s\n' "${p}" >&2
    return 1
  }
}
check "the container script can still be read out of restore.sh" payload_was_extracted
vol_run() {  # $1 = a directory to put first on PATH, or empty; echoes the status
  local rc=0 prefix=""
  # The PATH change goes INSIDE the sh -c string, where it is the inner
  # shell's business. Written out here — as a 'PATH=... env' prefix or by
  # reading "${PATH}" — ShellCheck calls it SC2031, because this suite does
  # modify PATH in a subshell elsewhere and cannot know the read is safe.
  if [[ -n "$1" ]]; then
    prefix="PATH=\"$1:\$PATH\"; export PATH; "
  fi
  sh -c "${prefix}$(vol_payload)" >/dev/null 2>&1 || rc=$?
  printf '%s' "${rc}"
}
vol_reset() {
  rm -rf "${VOL}/to"; mkdir -p "${VOL}/to"; printf 'live-accounts-and-chats\n' > "${VOL}/to/keep.txt"
}
# 1. An unreadable archive must stop BEFORE anything is cleared.
vol_reset; printf 'not a gzip archive' > "${VOL}/from/open-webui-volume.tar.gz"
corrupt_stops_before_clearing() {
  [[ "$(vol_run '')" == 3 ]] && [[ -f "${VOL}/to/keep.txt" ]]
}
check "an unreadable archive exits 3 and leaves the live volume alone" \
  corrupt_stops_before_clearing
# 2. A good archive replaces the contents.
vol_reset
( cd "${VOL}" && mkdir -p src && printf 'restored\n' > src/restored.txt \
  && tar czf from/open-webui-volume.tar.gz -C src . )
good_archive_restores() {
  [[ "$(vol_run '')" == 0 ]] && [[ -f "${VOL}/to/restored.txt" ]] && [[ ! -f "${VOL}/to/keep.txt" ]]
}
check "a good archive exits 0 and replaces the volume contents" good_archive_restores
# 3. The case the old message lied about: the unpack fails AFTER the clear.
#    A stub tar that lists happily and refuses to extract puts us exactly there.
cat > "${VOL}/bin/tar" <<'FAKE'
#!/bin/sh
case "$1" in
  tzf) exit 0 ;;
  xzf) exit 1 ;;
esac
exit 0
FAKE
chmod +x "${VOL}/bin/tar"
vol_reset
unpack_failure_is_distinguishable() {
  # 5, not 3: the volume IS empty now, and the message must be able to say so.
  [[ "$(vol_run "${VOL}/bin")" == 5 ]] && [[ ! -f "${VOL}/to/keep.txt" ]]
}
check "an unpack that fails after clearing exits 5, not 3" \
  unpack_failure_is_distinguishable
# ...and restore.sh must actually tell those apart rather than share a branch.
restore_distinguishes_the_stages() {
  grep -q 'existing WebUI data was NOT wiped' "${REPO}/restore.sh" || return 1
  grep -q 'FAILED PART-WAY' "${REPO}/restore.sh" || return 1
  # the "not wiped" sentence must not live in the same arm as the wiped case
  ! awk '/^ *5\)/ { inarm = 1; next }
         inarm && /^ *;;/ { inarm = 0 }
         inarm && /NOT wiped/ { found = 1 }
         END { exit !found }' "${REPO}/restore.sh"
}
check "restore.sh reports 'not wiped' and 'wiped' as different outcomes" \
  restore_distinguishes_the_stages

echo "# a big piped input must not kill the command that exists to read it"
# 'lca logs | lca ask "why did this fail?"' is the first thing
# docs/TROUBLESHOOTING.md tells you to run. It died outright — exit 141, no
# answer, no warning, no error — whenever the piped input passed the 64 KiB
# pipe buffer, which is to say whenever the log was big enough to be worth
# asking about. ask.sh sliced it with 'printf "%s" "${piped}" | head -c 12000':
# head leaves after 12000 bytes, printf still has the rest to write and takes
# SIGPIPE, pipefail returns 141, and errexit exits the script mid-assignment.
#
# Demonstrated rather than asserted, so the gate below is visibly guarding
# something real.
pipeline_slice_really_does_die() {
  local rc=0
  ( set -euo pipefail
    s="$(head -c 200000 /dev/zero | tr '\0' 'x')"
    printf '%s' "${s}" | head -c 12000 >/dev/null ) || rc=$?
  (( rc != 0 ))
}
parameter_slice_survives() {
  local s out
  s="$(head -c 200000 /dev/zero | tr '\0' 'x')"
  out="${s:0:12000}"
  (( ${#out} == 12000 ))
}
check "the old 'printf | head' form fails on a 200k input" \
  pipeline_slice_really_does_die
check "the parameter slice returns the same 12000 chars and lives" \
  parameter_slice_survives
ask_slices_without_a_pipe() {
  grep -q 'piped:0:12000' "${REPO}/scripts/ask.sh"
}
check "ask.sh slices piped input with parameter expansion" ask_slices_without_a_pipe
# ...and nowhere else may reintroduce it. A variable written into a reader that
# leaves early is the same bug wherever it appears; CONTRIBUTING lists it as
# shell trap #1 and it was in shipped code anyway.
no_variable_is_piped_into_an_early_exiting_reader() {
  local hits
  hits="$(grep -rnE '(printf|echo)[^|]*[$][{][A-Za-z_]+[^|]*[|][[:space:]]*(head|grep -q|grep -m)' \
            "${REPO}"/*.sh "${REPO}"/scripts/*.sh "${REPO}"/deploy/*.sh "${REPO}/bin/lca" \
            2>/dev/null || true)"
  [[ -z "${hits}" ]] || {
    printf 'these write a variable into a reader that exits early (SIGPIPE at >64KiB):\n%s\n' "${hits}" >&2
    return 1
  }
}
check "no script pipes a variable into a reader that exits early" \
  no_variable_is_piped_into_an_early_exiting_reader

echo "# a script that rewrites its own file must not let bash read on"
# bash reads a script incrementally from an open fd. update.sh fast-forwards
# the checkout it is running from, and install.sh hard-resets it; either can
# replace the file mid-run, and when main returns bash reads whatever now sits
# at its old byte offset. Measured with a 7961-byte stand-in: it executed a
# fragment of a comment in the replacement and exited 127 — right after the
# update had succeeded and said so. Ending the line with 'exit $?' means both
# commands come from one parse and there is no next read; a separate 'exit'
# line would be read at that same stale offset and never run.
self_rewriting_scripts_exit_explicitly() {
  local f rewriters=() last
  # deploy/ is in the search now, and so is 'pull --ff-only'. The first version
  # looked only at "${REPO}"/*.sh for 'merge --ff-only|reset --hard', and missed
  # deploy/do-user-data.sh on both counts: it lives one directory down, and it
  # updates itself with 'git pull --ff-only'. Its last line is a pipeline, which
  # makes no difference — measured: the replacement's tail runs just the same.
  for f in "${REPO}"/*.sh "${REPO}"/deploy/*.sh; do
    if grep -qE 'git .*(merge --ff-only|reset --hard|pull --ff-only)' "${f}"; then
      rewriters+=("${f}")
    fi
  done
  # Assert the search found something, so a regex that quietly stops matching
  # cannot pass as "nothing to check".
  (( ${#rewriters[@]} >= 3 )) || {
    printf 'expected install.sh, update.sh and do-user-data.sh, got %s\n' "${#rewriters[@]}" >&2
    return 1
  }
  for f in "${rewriters[@]}"; do
    last="$(tail -1 "${f}")"
    # The property is that the call and the exit come out of ONE parse, so the
    # last line must both invoke main and END with the exit. An 'exit $?' on
    # the next line satisfies "the file ends with an exit" and fixes nothing:
    # that line is read at the stale offset too, and never runs. The first
    # version of this check looked for the substring anywhere and passed on
    # exactly that; the second demanded the literal 'main "$@"; exit $?', which
    # was right until do-user-data.sh arrived invoking main through a pipeline.
    [[ "${last}" == *main* && "${last}" == *'; exit $?' ]] || {
      printf '%s can replace itself mid-run but ends with: %s\n' "${f##*/}" "${last}" >&2
      return 1
    }
  done
}
check "the self-rewriting scripts stop bash reading a file they replaced" \
  self_rewriting_scripts_exit_explicitly

echo
if (( FAILED > 0 )); then
  echo "RESULT: ${FAILED} test(s) FAILED"
  exit 1
fi
echo "RESULT: all tests passed"
