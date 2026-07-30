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
check "default BACKUP_KEEP" test "${BACKUP_KEEP}" = "7"
check "default AIDER_CONVENTIONS" test "${AIDER_CONVENTIONS}" = "true"
check "default BACKUP_SCHEDULE" test "${BACKUP_SCHEDULE}" = "*-*-* 03:30:00"

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
    # bin/lca dispatches via a case statement: 'ask)' or 'offline|online|...)'.
    grep -qE "^[[:space:]]*[a-z|\"]*\b${sub}\b[a-z|]*\)" "${REPO}/bin/lca" || {
      printf 'system prompt advertises unknown command: lca %s\n' "${sub}" >&2
      bad=1
    }
  done < <(lca_system_prompt | sed -n 's/^  lca \([a-z]\{1,\}\).*/\1/p')
  return "${bad}"
}
check "every 'lca' command named in the system prompt exists in bin/lca" prompt_commands_all_real

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
fi

echo
if (( FAILED > 0 )); then
  echo "RESULT: ${FAILED} test(s) FAILED"
  exit 1
fi
echo "RESULT: all tests passed"
