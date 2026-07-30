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
#   4. Open WebUI answers its health probe (when enabled)
#
# Non-mutating: it pulls nothing, edits no .env, and cleans up its scratch repo.
# Exit 0 only if every non-skipped check passed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_env

# Run every check even if one fails, like check-system.sh.
set +e

PASS=0
FAIL=0
p_pass() { ok "$*";  PASS=$((PASS+1)); }
p_fail() { err "$*"; FAIL=$((FAIL+1)); }

step "local-code-agent self-test (live end-to-end round-trip)"
info "Target: $(uname -m) · $(detect_ram_gib) GiB RAM · model ${MODEL_NAME} · ctx ${OLLAMA_CONTEXT_LENGTH}"

# --- 1. Ollama API ----------------------------------------------------------
step "1/4 Ollama API"
if ensure_ollama_up 60; then
  p_pass "Ollama API answering at $(ollama_url)"
  ollama_reachable=true
else
  p_fail "Ollama API not reachable at $(ollama_url) — try: sudo systemctl restart ollama (see check-system.sh)"
  ollama_reachable=false
fi

# --- 2. Real generation -----------------------------------------------------
step "2/4 Model generation"
model_ready=false
if [[ "${ollama_reachable}" != "true" ]]; then
  p_fail "skipped generation — Ollama is not up"
elif ! model_present "${MODEL_NAME}"; then
  p_fail "model '${MODEL_NAME}' is not downloaded — pull it with: ollama pull ${MODEL_NAME} (or re-run ./setup.sh)"
else
  info "Asking ${MODEL_NAME} for a real generation (first load can take a minute)..."
  if model_responds "${MODEL_NAME}" 300; then
    p_pass "model '${MODEL_NAME}' generated text — inference works on this hardware"
    model_ready=true
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
else
  p_fail "Open WebUI not answering at $(webui_url)/health — check: ${REPO_ROOT}/webui.sh status"
fi

# --- Summary ----------------------------------------------------------------
step "Self-test summary"
info "PASS=${PASS}  FAIL=${FAIL}"
if (( FAIL == 0 )); then
  printf '%b%s%b\n' "${C_GREEN}${C_BOLD}" "SELF-TEST PASSED — your local-code-agent stack works end-to-end." "${C_RESET}"
  exit 0
else
  printf '%b%s%b\n' "${C_YELLOW}${C_BOLD}" "SELF-TEST FAILED (${FAIL}) — see the failing checks above and docs/TROUBLESHOOTING.md." "${C_RESET}"
  exit 1
fi
