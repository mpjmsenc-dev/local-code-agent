#!/usr/bin/env bash
# scripts/agent-setup.sh — get the agent tier from "off" to "took a task",
# in one command, fixing what it can and naming what it cannot.
#
# WHY THIS EXISTS. Submitting the first task to a fresh agent tier took an hour
# of diagnosis on a real machine. Six things were wrong, in a chain, and every
# one of them was silent:
#
#   1. ENABLE_AGENT was false, so the selftest failed on a tier that was off
#   2. tune said "Already tuned. Nothing to do." and never built the derived
#      model — it only builds one when the tier is ON, and it was not
#   3. the relay was not installed
#   4. the relay was installed and ENABLE_OLLAMA_RELAY was still false
#   5. the agent's settings held the BASE model, not the -agent one
#   6. the port was not reachable from the phone
#
# None of them is hard. What made it an hour is that each one hid the next: you
# fix one, the next failure looks identical, and nothing in any message names
# the thing that is actually wrong. Six correct fixes, discoverable only by
# reading source.
#
# So this walks the same chain in dependency order and either fixes each link
# or stops on it with the one command that fixes it. It is idempotent: run it
# on a healthy machine and it changes nothing and says so.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_env

usage() {
  cat <<EOF
Usage: lca agent setup [--dry-run]

Brings the agent tier up from wherever it is, in dependency order, and reports
what it changed. Safe to re-run: on a healthy machine it changes nothing.

  --dry-run   say what it would change, change nothing

What it will not do for you, and why: pulling a multi-gigabyte model, and
applying the inbound guard (which needs root). Both are named with the exact
command when they are what is missing.

The chain, and what each link failing looks like: docs/AGENT.md
EOF
}

DRY_RUN=false
CHANGED=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) ARG="$1"; usage >&2; die "Unknown option: ${ARG}" ;;
  esac
done

# fixed MESSAGE — record and announce a change this made.
fixed() {
  CHANGED+=("$1")
  ok "Fixed: $1"
}

# would MESSAGE — the same thing under --dry-run.
would() {
  CHANGED+=("$1")
  info "Would fix: $1"
}

# blocked REMEDY — stop here, because the next link cannot be tested until this
# one is right. Names the command rather than the concept.
blocked() {
  echo
  err "Stopped at this step: $1"
  info "Nothing after it can be checked until that is done. Re-run 'lca agent setup' afterwards and it will carry on from here."
  exit 1
}

# --- 1. the tier is switched on ---------------------------------------------
# First because everything else is conditional on it, including the derived
# model: refresh_agent_model_after_tune returns immediately when the tier is
# off, which is exactly how a machine ends up "already tuned" with no model.
step "1/7  The tier is switched on"
if [[ "${ENABLE_AGENT}" == "true" ]]; then
  ok "ENABLE_AGENT is already true."
else
  if [[ "${DRY_RUN}" == "true" ]]; then
    would "ENABLE_AGENT=true in .env"
  else
    write_env_or_die ENABLE_AGENT true
    ENABLE_AGENT=true
    fixed "ENABLE_AGENT=true in .env"
    info "You are running 'lca agent setup', which is the consent this asks for. It costs about 7 GB of images on first start, and the tier can run anything on this machine — docs/AGENT.md says what that means."
  fi
fi

# --- 2. docker ---------------------------------------------------------------
step "2/7  Docker"
require_cmd docker
# docker_daemon_reachable, not a bare 'as_root docker info': as_root die()s when
# it cannot escalate, and a probe that kills the script is not a probe. The
# suite has a gate for exactly this shape and it caught this line.
if docker_daemon_reachable; then
  ok "The docker daemon is answering."
else
  blocked "the docker daemon is not answering — $(docker_start_hint)"
fi

# --- 3. the base model -------------------------------------------------------
# Not pulled here on purpose: it is gigabytes over somebody's connection, and a
# setup command that silently starts a long download is the opposite of what
# this file is for.
step "3/7  The base model"
if ! wait_for_ollama 3; then
  blocked "Ollama is not answering at $(ollama_url) — start it: $(ollama_restart_hint)"
fi
if model_present "${MODEL_NAME}"; then
  ok "${MODEL_NAME} is present."
else
  blocked "the model ${MODEL_NAME} is not on this machine. $(pull_advice "${MODEL_NAME}")   (or let the ladder choose it for you: sudo lca tune)"
fi

# --- 4. the derived model ----------------------------------------------------
# The one the agent actually runs, at its own context window. This is stop 2
# from the list above, and the reason it is silent: tune builds it only when the
# tier is on, so a machine tuned while ENABLE_AGENT was false is "already tuned"
# for ever and has no agent model at all.
step "4/7  The agent's own model"
DERIVED="$(agent_model_name "${MODEL_NAME}")"
WANT_CTX="$(agent_model_context)"
if drift="$(agent_model_drift 2>/dev/null)"; then
  if [[ "${DRY_RUN}" == "true" ]]; then
    would "build ${DERIVED} at ${WANT_CTX} tokens (${drift})"
  else
    info "Building ${DERIVED} at ${WANT_CTX} tokens (${drift}). It is a manifest over weights you already have, so this is quick."
    built="$(ensure_agent_model "${MODEL_NAME}")" && rc=0 || rc=$?
    case "${rc}" in
      0) fixed "built ${built} at ${WANT_CTX} tokens" ;;
      2) warn "${DERIVED} was created but Ollama did not load it at ${WANT_CTX} tokens, so the agent would silently run at the server default. Check it: lca check" ;;
      *) blocked "could not build ${DERIVED} — try it by hand: sudo lca tune" ;;
    esac
  fi
else
  ok "${DERIVED} exists and loads at ${WANT_CTX} tokens."
fi

# --- 5. the relay ------------------------------------------------------------
# Two separate stops that look the same: the units not installed, and the units
# installed with the setting still false. Both end as "the model was never
# contacted", with no error, because the container cannot reach Ollama at all.
step "5/7  The relay to Ollama"
if [[ "${ENABLE_OLLAMA_RELAY}" != "true" ]]; then
  if [[ "${DRY_RUN}" == "true" ]]; then
    would "ENABLE_OLLAMA_RELAY=true in .env"
  else
    write_env_or_die ENABLE_OLLAMA_RELAY true
    ENABLE_OLLAMA_RELAY=true
    fixed "ENABLE_OLLAMA_RELAY=true in .env"
  fi
fi
if ollama_relay_healthy; then
  ok "The relay answers at $(ollama_relay_address)."
elif [[ "${DRY_RUN}" == "true" ]]; then
  would "install and start the relay units"
else
  info "Installing the relay units..."
  if as_root "${SCRIPT_DIR}/ollama-relay.sh" install >/dev/null 2>&1 && ollama_relay_healthy; then
    fixed "installed the relay and confirmed it answers at $(ollama_relay_address)"
  else
    blocked "the relay is not answering — install it and read what it says: sudo ${SCRIPT_DIR}/ollama-relay.sh install"
  fi
fi

# --- 6. the container --------------------------------------------------------
# Started through agent.sh rather than reimplemented here: the publications, the
# sandbox port variables and the settings seeding are one decision each and
# there must be exactly one copy of them.
step "6/7  The agent container"
if agent_container_running; then
  ok "${AGENT_CONTAINER} is running."
  if [[ "${#CHANGED[@]}" -gt 0 && "${DRY_RUN}" != "true" ]]; then
    info "Restarting it so it picks up what changed above..."
    "${REPO_ROOT}/agent.sh" restart >/dev/null 2>&1 \
      || blocked "could not restart the agent — run it and read the output: lca agent restart"
    fixed "restarted the agent so the new settings took"
  fi
elif [[ "${DRY_RUN}" == "true" ]]; then
  would "start the agent container"
else
  info "Starting it. The first run downloads several GB of images."
  "${REPO_ROOT}/agent.sh" start || blocked "the agent did not start — read its own output: lca agent logs"
  fixed "started the agent"
fi

# --- 7. what it will actually answer on --------------------------------------
# The last stop, and the one no check on this machine could see until now: the
# port was never published on the Tailscale address, so the URL in the docs
# refused from the phone while everything here looked healthy.
step "7/7  Reachable where the docs say it is"
if [[ "${DRY_RUN}" == "true" ]]; then
  info "Skipped under --dry-run: nothing was started, so there is nothing to reach."
else
  TSIP="$(tailscale_ip4 || true)"
  if [[ -z "${TSIP}" ]]; then
    warn "No Tailscale address on this machine, so the agent is reachable from here only. For phone access: sudo ${SCRIPT_DIR}/install_tailscale.sh"
  elif ! have ss; then
    info "ss is not installed, so what is listening could not be read."
  else
    GAPS="$(tailscale_promise_gaps "${TSIP}" "$(host_listeners || true)" || true)"
    if [[ -z "${GAPS}" ]]; then
      ok "Answering on ${TSIP}, which is the address the docs send you to."
    else
      warn "Not listening on ${TSIP} yet: ${GAPS//$'\n'/, }. If Tailscale came up after the container did, this is the fix: lca agent restart"
    fi
  fi
  # The dump is the argument, not something the function fetches: it reads the
  # ruleset once and check-system.sh feeds it the same way. Called bare, it dies
  # on an unbound $1 under set -u — which ShellCheck flagged as a style nit and
  # was in fact the bug.
  GUARD_DUMP="$(as_root nft list table inet lca_inbound 2>/dev/null || true)"
  GUARD_MISSING="$(inbound_guard_uncovered "${GUARD_DUMP}" || true)"
  if [[ -n "${GUARD_MISSING}" ]]; then
    warn "The inbound guard does not cover ${GUARD_MISSING//$'\n'/, } — those ports are open to anything that can reach this machine. Fix it: sudo lca apply"
  else
    ok "The inbound guard covers every port this machine offers."
  fi
fi

# --- what happened -----------------------------------------------------------
echo
if [[ "${#CHANGED[@]}" -eq 0 ]]; then
  ok "Nothing needed changing — the agent tier was already set up."
else
  step "Changed ${#CHANGED[@]} thing(s)"
  for c in "${CHANGED[@]}"; do info "· ${c}"; done
fi
if [[ "${DRY_RUN}" == "true" ]]; then
  info "--dry-run: nothing above was actually changed."
fi
if [[ "${DRY_RUN}" != "true" ]] && agent_container_running; then
  info "Open it: $("${REPO_ROOT}/agent.sh" url 2>/dev/null || printf 'lca agent url')"
  info "Prove the whole chain end to end, with timings: lca agent selftest"
fi
