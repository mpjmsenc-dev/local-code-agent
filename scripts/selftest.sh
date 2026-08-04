#!/usr/bin/env bash
# scripts/selftest.sh — end-to-end ACCEPTANCE test you run on your own box.
#
# check-system.sh answers "is everything installed and healthy?" (config,
# services, ports). This answers the harder question this project keeps
# running into: "does the stack actually WORK on THIS hardware?" — because a
# green CI run on a fat GitHub runner has repeatedly hidden bugs that only bit
# on a real VM. It does a live round-trip through every moving part:
#
#   1. Ollama API answers
#   2. the model produces a real generation (inference works, RAM fits)
#   3. aider -> litellm -> Ollama makes a real request from a scratch project
#   4. Open WebUI answers its health probe AND carries this repo's assistant
#      prompt (a stale one is why the only real bug report ever filed here
#      would have seen every other check pass)
#
# Non-mutating: it pulls nothing and edits no .env. The scratch project is
# removed on the way out, with one deliberate exception — a failed aider
# round-trip keeps its log, and prints the path, because that log is the only
# record of why it failed.
# Exit 0 only if every non-skipped check passed.
#
# Usage: lca test        (no options; takes minutes — it generates for real)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Answered BEFORE anything runs. This test does real generations and takes
# minutes, so reading '--help' as "go ahead and do it" is the one answer that
# is certainly wrong — and it was the answer, because nothing looked at "$@".
case "${1:-}" in
  -h|--help)
    sed -n '2,/^[^#]/p' "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  "") ;;
  *) die "Unknown option: ${1} — 'lca test' takes none. Try: lca test --help" ;;
esac

load_env

# Run every check even if one fails, like check-system.sh.
set +e

PASS=0
FAIL=0
SKIP=0
p_pass() { ok "$*";  PASS=$((PASS+1)); }
p_fail() { err "$*"; FAIL=$((FAIL+1)); }
# p_skip — a check that could not be MADE. Counted, because the last line of
# this script says the stack works end-to-end, and a check nobody could run is
# not evidence for that. Deliberately not p_fail: "could not look" is not
# "broken", and failing an update on it would be wrong.
#
# A component switched off in .env is not this. That is a choice with nothing
# to look at, and it stays an info() — the same line 'lca apply' draws between
# "disabled — nothing to apply" and its UNCHECKED count.
p_skip() { warn "$*"; SKIP=$((SKIP+1)); }
gpu_proc=""

step "local-code-agent self-test (live end-to-end round-trip)"
info "Target: $(uname -m) · $(detect_ram_gib) GiB RAM · model ${MODEL_NAME} · ctx ${OLLAMA_CONTEXT_LENGTH}"

# --- 1. Ollama API ----------------------------------------------------------
step "1/4 Ollama API"
if ensure_ollama_up 60; then
  p_pass "Ollama API answering at $(ollama_url)"
  ollama_reachable=true
else
  p_fail "Ollama API not reachable at $(ollama_url) — try: sudo systemctl restart ollama (see: lca check)"
  ollama_reachable=false
fi

# --- 2. Real generation -----------------------------------------------------
step "2/4 Model generation"
model_ready=false
if [[ "${ollama_reachable}" != "true" ]]; then
  p_fail "skipped generation — Ollama is not up"
elif ! model_present "${MODEL_NAME}"; then
  p_fail "model '${MODEL_NAME}' is not downloaded — pull it with: ollama pull ${MODEL_NAME} (or re-run ${REPO_ROOT}/setup.sh)"
else
  info "Asking ${MODEL_NAME} for a real generation (first load can take a minute)..."
  if model_responds "${MODEL_NAME}" 300; then
    p_pass "model '${MODEL_NAME}' generated text — inference works on this hardware"
    model_ready=true
    # The model is loaded right now, so this is the moment its CPU/GPU
    # placement is visible — the honest answer to "why is this fast/slow?".
    gpu_proc="$(ollama_processor "${MODEL_NAME}" 2>/dev/null || true)"
    if [[ -n "${gpu_proc}" ]]; then
      info "Running on: ${gpu_proc}"
    fi
  else
    p_fail "model '${MODEL_NAME}' did not respond — check RAM headroom (free -h) and: journalctl -u ollama"
  fi
fi

# --- 3. aider pipeline (the real coding path) -------------------------------
step "3/4 aider -> litellm -> Ollama"
aider="$(aider_bin)"
if [[ ! -x "${aider}" ]]; then
  p_fail "aider is not installed at ${aider} — run: ${REPO_ROOT}/scripts/install_python.sh"
elif [[ "${model_ready}" != "true" ]]; then
  p_fail "skipped aider round-trip — the model is not ready (see above)"
else
  # A throwaway git repo so aider runs exactly as it would in a real project,
  # without touching anything of yours. Cleaned up on the way out.
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' EXIT
  (
    cd "${tmp}" || exit 1
    git init -q
    git config user.email selftest@local            # repo-local only, never global
    git config user.name  "local-code-agent selftest"
  )
  info "Running aider on a scratch project (CPU inference is slow — allow a minute or two)..."
  out="${tmp}/aider-out.txt"
  # timeout guards against a wedged model; aider itself exits after --message.
  runner=(); have timeout && runner=(timeout 300)
  if ( cd "${tmp}" && "${runner[@]}" "${REPO_ROOT}/run-agent.sh" \
         --message "Reply with the single word: ready" \
         --yes-always --no-stream ) >"${out}" 2>&1 && [[ -s "${out}" ]]; then
    p_pass "aider connected through litellm and got a response from Ollama"
  else
    p_fail "aider round-trip failed — last lines below; full log: ${out}"
    tail -n 15 "${out}" 2>/dev/null | sed 's/^/    /' >&2 || true
    trap - EXIT   # keep the log for debugging when it failed
  fi
fi

# --- 4. Open WebUI ----------------------------------------------------------
step "4/4 Open WebUI"
if [[ "${ENABLE_WEBUI}" != "true" || "${SKIP_DOCKER}" == "true" ]]; then
  info "Open WebUI disabled (ENABLE_WEBUI=${ENABLE_WEBUI}, SKIP_DOCKER=${SKIP_DOCKER}) — skipping."
elif webui_responds; then
  p_pass "Open WebUI healthy at $(webui_url) (reach it privately over Tailscale)"
  # "Healthy" has meant "the HTTP port answers". The only real report ever
  # filed against this project was a stack where every infrastructural check
  # passed and the ASSISTANT was wrong — so this test would have printed
  # "works end-to-end" to the person filing the bug. The assistant's own
  # instructions are baked into the container at creation, so a repo update
  # that fixes its behaviour does not reach a running one until it is rebuilt.
  # webui_prompt_comparable, not a hand-rolled probe. This used to read the
  # live value alone, and webui_drift skips the whole prompt comparison without
  # jq — so on a box without jq the drift list could not contain SYSTEM_PROMPT,
  # the grep below found nothing, and this printed "the chat app carries this
  # repo's assistant prompt". install_webui.sh warns, on that same box, that
  # the chat was started WITHOUT our prompt. A pass for a check that could not
  # run, contradicting the installer that ran an hour earlier.
  if ! webui_prompt_comparable; then
    p_skip "could not compare the chat app's assistant prompt (needs jq and docker access here) — that check was skipped, not passed"
  elif webui_drift | grep -q SYSTEM_PROMPT; then
    p_fail "the chat app is running an OLDER assistant prompt than this repo's — the chat keeps its previous behaviour, including anything an update was meant to fix. Apply it with: sudo ${REPO_ROOT}/bin/lca apply"
  else
    p_pass "the chat app carries this repo's assistant prompt (not a stale copy)"
  fi
else
  p_fail "Open WebUI not answering at $(webui_url)/health — check: ${REPO_ROOT}/webui.sh status"
fi

# --- Summary ----------------------------------------------------------------
step "Self-test summary"
# Wording and exit status together, in lib.sh — the same arrangement as
# setup_verdict, and for the same reason: docs/YOUR-TURN.md tells the reader to
# watch for the line while 'lca update' branches on the status.
selftest_verdict "${PASS}" "${FAIL}" "${SKIP}"
exit $?
