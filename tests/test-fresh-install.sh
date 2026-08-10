#!/usr/bin/env bash
# tests/test-fresh-install.sh — walk a CLEAN machine through setup.sh, once,
# and check the things a first-time user actually depends on.
#
# This is the repo's biggest untested claim. Every install this project has ever
# had was incremental: a box that already had Ollama, or aider, or a .env from
# last week. CI's E2E lane runs setup.sh too, but only after it has installed
# Ollama and aider itself, so it proves setup.sh is safe to RE-run, not that it
# works from nothing.
#
# Two bugs reached a real droplet through exactly that gap, and both are asserted
# below by name:
#
#   the bootstrap loop  ENABLE_AGENT=true on a fresh box left no <model>-agent,
#                       so 'lca agent selftest' failed and told the user to run
#                       'lca tune' — which did nothing, and said so.
#   the four exits      tune.sh built that model at the bottom of main(), past
#                       the four places main() can exit. On an already-tuned box
#                       — which is what a box IS one second after setup.sh —
#                       it never ran.
#
# Neither is a unit-testable shape on its own: they are what a first user meets
# in the first five minutes, in the order they meet it.
#
# WHAT THIS DOES NOT COVER, on purpose: Docker, Open WebUI and Tailscale. A
# container cannot honestly host a nested docker daemon or a VPN, so they are
# switched off rather than faked. The agent's MODEL bootstrap is covered, and
# that is the half the bugs were in — it depends on Ollama and tune.sh, not on
# the container ever starting.
#
# Usage: tests/test-fresh-install.sh [--keep]
#   --keep   leave the container behind for inspection
#
# Needs docker on the host and pulls a real model, so it is not part of the unit
# suite. It is its own CI job, and one command by hand.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${TESTS_DIR}/.." && pwd)"
CONTAINER="lca-fresh-install-test"
BASE_IMAGE="${LCA_FRESH_BASE_IMAGE:-ubuntu:24.04}"
KEEP=false
[[ "${1:-}" == "--keep" ]] && KEEP=true

FAILED=0
t_ok()   { printf 'ok   - %s\n' "$*"; }
t_fail() { printf 'FAIL - %s\n' "$*"; FAILED=$((FAILED+1)); }

command -v docker >/dev/null 2>&1 \
  || { echo "skip - docker is not installed, so a clean machine cannot be created"; exit 0; }
docker info >/dev/null 2>&1 \
  || { echo "skip - the docker daemon is not reachable, so a clean machine cannot be created"; exit 0; }

# An extra CA to trust inside the container. Not a hack for one environment: a
# corporate proxy that terminates TLS is common, and without its certificate pip
# cannot reach pypi and the run says nothing about setup.sh. Empty by default.
CA_MOUNT=()
if [[ -n "${LCA_TEST_CA_BUNDLE:-}" && -r "${LCA_TEST_CA_BUNDLE}" ]]; then
  CA_MOUNT=(-v "${LCA_TEST_CA_BUNDLE}:/extra-ca.crt:ro")
fi

# The script that runs INSIDE the clean machine. Everything it asserts is about
# state the machine is left in, so it runs after setup.sh rather than watching it.
IN_CONTAINER=$(cat <<'GUEST'
set -uo pipefail
say() { printf '\n### %s\n' "$*"; }

apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq git ca-certificates >/dev/null 2>&1
if [ -r /extra-ca.crt ]; then
  cp /extra-ca.crt /usr/local/share/ca-certificates/extra.crt
  update-ca-certificates >/dev/null 2>&1
  export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
  export REQUESTS_CA_BUNDLE="${SSL_CERT_FILE}" PIP_CERT="${SSL_CERT_FILE}"
  export CURL_CA_BUNDLE="${SSL_CERT_FILE}"
fi

# The TRACKED files as they are on disk right now — not 'git clone /src'.
#
# That was the first version and it is a trap worth naming: a clone copies HEAD,
# so a test whose entire purpose is checking a fix before it ships silently
# tested the code without the fix. It reported the bug still present, twice, and
# it was right about HEAD and useless about the tree. 'git ls-files' gives the
# same file set a clone would — no .venv, no .env, no build droppings — taken
# from the working copy.
mkdir -p /opt/local-code-agent || exit 1
git -C /src ls-files -z 2>/dev/null | tar -C /src --null -T - -cf - 2>/dev/null \
  | tar -C /opt/local-code-agent -xf - || { echo "GUEST-FATAL could not copy the checkout"; exit 1; }
cd /opt/local-code-agent || exit 1
[ -f setup.sh ] || { echo "GUEST-FATAL no setup.sh in the copy"; exit 1; }
cp .env.example .env
# The agent tier ON, because its bootstrap is what this test exists for. Docker,
# Tailscale and the chat app off: a container cannot honestly host them.
sed -i 's/^SKIP_DOCKER=.*/SKIP_DOCKER=true/;      s/^SKIP_TAILSCALE=.*/SKIP_TAILSCALE=true/;
        s/^ENABLE_WEBUI=.*/ENABLE_WEBUI=false/;   s/^AUTO_TUNE=.*/AUTO_TUNE=false/;
        s/^MODEL_NAME=.*/MODEL_NAME=qwen2.5-coder:3b/;
        s/^OLLAMA_CONTEXT_LENGTH=.*/OLLAMA_CONTEXT_LENGTH=4096/;
        s/^ENABLE_AGENT=.*/ENABLE_AGENT=true/;    s/^AGENT_MODEL_CONTEXT=.*/AGENT_MODEL_CONTEXT=8192/' .env
chmod +x ./*.sh scripts/*.sh bin/* 2>/dev/null

say "setup.sh on a machine with nothing on it"
./setup.sh </dev/null 2>&1 | tail -25
echo "SETUP-EXIT ${PIPESTATUS[0]}"

# From here on the questions are about the machine setup.sh left behind.
say "ASSERTIONS"
have_model() { ollama list 2>/dev/null | tail -n +2 | awk '{print $1}' | grep -qxF "$1"; }

echo "ASSERT lca-on-path $(command -v lca >/dev/null 2>&1 && echo yes || echo no)"
echo "ASSERT base-model $(have_model qwen2.5-coder:3b && echo yes || echo no)"
echo "ASSERT agent-model $(have_model qwen2.5-coder:3b-agent && echo yes || echo no)"
echo "ASSERT agent-window $(ollama show qwen2.5-coder:3b-agent --parameters 2>/dev/null \
        | awk '$1 == "num_ctx" { print $2; exit }')"

# The four-exits bug, from the direction a user meets it: the box is already
# tuned now, so a second tune must still leave the model in place — and must
# REBUILD it when it is missing, which is the state the loop got stuck in.
say "tune.sh on an already-tuned box"
./scripts/tune.sh 2>&1 | tail -4
echo "ASSERT agent-model-after-retune $(have_model qwen2.5-coder:3b-agent && echo yes || echo no)"

say "tune.sh must rebuild a model that was removed"
ollama rm qwen2.5-coder:3b-agent >/dev/null 2>&1
echo "ASSERT agent-model-deleted $(have_model qwen2.5-coder:3b-agent && echo yes || echo no)"
./scripts/tune.sh 2>&1 | tail -4
echo "ASSERT agent-model-rebuilt $(have_model qwen2.5-coder:3b-agent && echo yes || echo no)"

say "lca check"
./check-system.sh 2>&1 | tail -12
echo "CHECK-EXIT ${PIPESTATUS[0]}"
GUEST
)

echo "# a clean ${BASE_IMAGE}, one setup.sh, and the questions a first user asks"
echo "# (this pulls a real model; give it 15-25 minutes)"
docker rm -f "${CONTAINER}" >/dev/null 2>&1
LOG="$(mktemp)"
docker run --name "${CONTAINER}" -v "${REPO}:/src:ro" "${CA_MOUNT[@]}" \
  "${BASE_IMAGE}" bash -c "${IN_CONTAINER}" >"${LOG}" 2>&1
run_rc=$?

assert_value() { sed -n "s/^ASSERT $1 //p" "${LOG}" | head -1; }

if (( run_rc != 0 )); then
  # Not fatal by itself: setup.sh exits non-zero on a container for reasons that
  # are the container's (no systemd, so no boot services and no inbound guard).
  # The assertions below are what decide, so this is reported and passed over.
  printf 'note - the run exited %s; the assertions below are what decide\n' "${run_rc}"
fi
if ! grep -q '^SETUP-EXIT' "${LOG}"; then
  t_fail "setup.sh never finished on a clean machine — the run died before it could be asked anything"
  tail -30 "${LOG}"
  echo; echo "RESULT: fresh-install test FAILED"
  [[ "${KEEP}" == "true" ]] || docker rm -f "${CONTAINER}" >/dev/null 2>&1
  exit 1
fi

# The model is what everything else here depends on; without it the rest of the
# assertions would be vacuously false and say the wrong thing about why.
if [[ "$(assert_value base-model)" == "yes" ]]; then
  t_ok "setup.sh pulled the model on a machine that had none"
else
  t_fail "setup.sh finished without the model on disk, so nothing below can be judged"
  grep -E '^\[(err|warn)\]' "${LOG}" | tail -10
  echo; echo "RESULT: fresh-install test FAILED"
  [[ "${KEEP}" == "true" ]] || docker rm -f "${CONTAINER}" >/dev/null 2>&1
  exit 1
fi

# if/else, not 'A && B || C'. That shape is not if-then-else — C runs whenever B
# fails — and this repo has already shipped one bug from writing it.
assert_is() {   # LABEL EXPECTED OK_MESSAGE FAIL_MESSAGE
  if [[ "$(assert_value "$1")" == "$2" ]]; then t_ok "$3"; else t_fail "$4"; fi
}

assert_is lca-on-path yes \
  "the 'lca' command is on PATH afterwards" \
  "setup.sh finished and 'lca' is not on PATH — every instruction this project gives starts with it"

# THE BOOTSTRAP LOOP. With ENABLE_AGENT=true, a fresh install must leave the
# agent's derived model built. It did not, and the selftest then sent the user
# to 'lca tune', which did nothing and said so.
assert_is agent-model yes \
  "ENABLE_AGENT=true leaves the derived model built, with no second command" \
  "a fresh install with ENABLE_AGENT=true left no <model>-agent — this is the bootstrap loop: the selftest fails and sends the user to 'lca tune', which does nothing"

assert_is agent-window 8192 \
  "...and it carries the window .env asked for, not the server's" \
  "the derived model exists but declares '$(assert_value agent-window)' rather than AGENT_MODEL_CONTEXT=8192, so the agent would silently truncate"

# THE FOUR EXITS, from the user's side. One second after setup.sh the box IS an
# already-tuned box, which is the exact state where the build used to be skipped.
assert_is agent-model-after-retune yes \
  "a second 'lca tune' on the now-already-tuned box keeps it" \
  "running tune.sh again destroyed the derived model"

assert_is agent-model-deleted no \
  "...and the test really did remove it before asking" \
  "the removal step did not remove the model, so the rebuild assertion below proves nothing"

assert_is agent-model-rebuilt yes \
  "...and tune.sh REBUILDS it on an already-tuned box (the four-exits bug)" \
  "tune.sh left the machine without the derived model on an already-tuned box — 'Already tuned ... Nothing to do' and the user is stuck in the loop"

echo
if (( FAILED == 0 )); then
  echo "RESULT: a clean machine walks through setup.sh and lands somewhere usable"
else
  echo "RESULT: ${FAILED} fresh-install assertion(s) FAILED"
  echo "Full log: ${LOG}"
fi
[[ "${KEEP}" == "true" ]] || docker rm -f "${CONTAINER}" >/dev/null 2>&1
[[ "${KEEP}" == "true" ]] && echo "container kept: docker logs ${CONTAINER}"
exit $(( FAILED > 0 ? 1 : 0 ))
