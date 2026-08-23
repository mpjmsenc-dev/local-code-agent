#!/usr/bin/env bash
# agent.sh — the autonomous agent tier (OpenHands), the step up from 'lca'.
#
# 'lca' runs aider: it edits files in the directory you are standing in, one
# request at a time, and you read the diff. This runs an agent that plans
# multi-step work and carries it out inside its own Docker sandbox — installing
# packages, running builds, starting services — without stopping to confirm
# each step. That is the point of it and it is also the whole of its risk, so
# it is off by default (ENABLE_AGENT) and it is never reachable from the public
# internet: the same inbound guard that covers the chat app covers this port,
# and it is the more important of the two to keep closed.
#
# Everything it does happens on this machine. The model is the local Ollama —
# there is no API key to leak because there is no API.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/scripts/lib.sh"
load_env

usage() {
  cat <<EOF
Usage: lca agent <command>       (or agent.sh directly)

Commands:
  setup     Bring the tier up from wherever it is: switch it on, build the
            agent's model, install the relay, start it, and say what changed.
            Start here on a machine that has never run it.
  task      Give it a task from here, with the working directory named
            explicitly — the thing two failed runs did not have
  start     Start the agent (pulls the images on first run — several GB)
  stop      Stop it (settings are kept in ~/.openhands; the agent's workspace
            is copied to ~/.openhands/workspaces/ when its sandbox is collected)
  restart   Restart it
  status    Container state + HTTP health on port ${AGENT_PORT}
  url       The address to open on your phone, over Tailscale
  logs      Follow the agent's logs (Ctrl-C to stop)
  watch     Supervise a run in progress: stop it at the step ceiling, the
            wall-clock limit, or when the same failure keeps repeating.
            'watch --live' is the read-only view instead: each turn as it
            lands — thoughts, tool calls, results, and the clock on the
            current step, which is how you tell working from stuck here
  selftest  Run one small real task end to end, assert a file appeared, and
            report the timing — the honest answer to "is this usable here?"

Limits for an unattended run live in .env:
  AGENT_MAX_ITERATIONS=${AGENT_MAX_ITERATIONS}   AGENT_TIMEOUT_MINUTES=${AGENT_TIMEOUT_MINUTES}   AGENT_STUCK_STRIKES=${AGENT_STUCK_STRIKES}

Enable it with ENABLE_AGENT=true in .env, then: sudo lca apply
Full notes, including what it costs and where it is weak: docs/AGENT.md
EOF
}

# agent_health — HTTP reachable on the port it publishes.
agent_health() {
  local port="${1:-${AGENT_PORT}}"
  curl -fsS --max-time 5 -o /dev/null "http://127.0.0.1:${port}/" 2>/dev/null
}

require_enabled() {
  [[ "${ENABLE_AGENT}" == "true" ]] || die "The agent tier is off. Set ENABLE_AGENT=true in .env, then: sudo lca apply"
}

start_agent() {
  require_enabled
  require_cmd docker curl
  docker_daemon_reachable || die "Cannot reach the Docker daemon as '$(whoami)'. $(docker_unreachable_advice)"

  if agent_container_running; then
    ok "The agent is already running: $(agent_url_line)"
    return 0
  fi

  # The port must be free before docker binds it, for the reason
  # install_webui.sh spells out at length: a squatter answering the port makes
  # a crash-looping container look healthy. Checked against the SAME port the
  # container will publish, and refused rather than worked around.
  # Captured, then matched against a here-string. 'ss | grep -q' SIGPIPEs the
  # producer and returns 141 under pipefail, which reads as "port is free"
  # exactly when it was taken — install_webui.sh carries the same two lines and
  # the same reason, and the direction of the failure is why it is worth them:
  # a missed match means docker cannot bind, the container crash-loops under
  # --restart unless-stopped, and the squatter answers the health probe.
  local listeners=""
  have ss && listeners="$(ss -ltn 2>/dev/null || true)"
  if [[ -n "${listeners}" ]] && grep -qE ":${AGENT_PORT}[[:space:]]" <<<"${listeners}"; then
    die "Port ${AGENT_PORT} is already in use, so the agent cannot bind it. See what holds it (sudo ss -tlnp | grep :${AGENT_PORT}), or set AGENT_PORT in .env to a free port and re-run: sudo lca apply"
  fi
  if [[ "${AGENT_PORT}" == "${WEBUI_PORT}" ]]; then
    die "AGENT_PORT and WEBUI_PORT are both ${AGENT_PORT}. The chat app runs with --network=host, so the two would fight for one socket. Give the agent its own port in .env."
  fi

  # Recreate rather than start a stale container: its port mapping and its
  # model settings are baked in at creation, so a container made before an
  # .env edit would keep answering with the old ones.
  if agent_container_exists; then
    info "Removing the previous agent container so this one gets the current .env settings..."
    as_root docker rm -f "${AGENT_CONTAINER}" >/dev/null 2>&1 || true
  fi

  local model base_url instructions bridge_gw
  model="$(agent_llm_model "$(agent_model_for_run)")"
  base_url="$(agent_llm_base_url)"
  bridge_gw="$(docker_bridge_gateway)"
  # The same instructions file aider reads — but read what happens to it below
  # before believing this reaches the agent. It does not: its only destination
  # is LCA_USER_INSTRUCTIONS, and nothing on the other side reads that name.
  # This line used to say the agent must not "become the one place the user's
  # preferences are ignored", and that is exactly what it is; the rules that DO
  # reach it travel in the task text (agent_task_prompt), measured
  # sha256-identical on arrival. Kept, and labelled, rather than removed.
  instructions="$(lca_user_instructions)"
  info "Starting the agent on port ${AGENT_PORT}, using ${model} at ${base_url}"
  info "First run downloads several GB of images — this takes a while."

  # --add-host is what makes host.docker.internal resolve to this machine, and
  # without it the agent cannot see Ollama at all. The docker socket is what
  # lets it start its own sandbox containers; that is also why this tier is
  # opt-in, and docs/AGENT.md says so in those words.
  #
  # Load-bearing, and it fails in the worst possible way. Without it the
  # container cannot resolve the relay, so every LLM call fails to connect —
  # and LiteLLM's num_retries=5 with long backoffs swallows that. Measured: the
  # sandbox up, the settings correct, the conversation open, and the model
  # never contacted once, with no error surfacing anywhere. Nothing tells you;
  # it just sits there. A gate holds this flag in place.
  #
  # OH_SANDBOX_HOST_PORT is the other half of publishing on a non-default port,
  # and leaving it out cost this project a whole verification run.
  #
  # The container listens on 3000 and we publish it on AGENT_PORT, because 3000
  # is WEBUI_PORT here. But the app also hands its OWN address to every sandbox
  # it starts — the MCP tool server the agent must list its tools from, and the
  # webhook it reports events to — and it builds that address from a port it
  # merely assumes: 'http://host.docker.internal:<host_port>', where host_port
  # defaults to 3000. Nothing tells it about the -p mapping.
  #
  # So the sandbox dialled host.docker.internal:3000 and reached Open WebUI,
  # which accepts the connection and then never speaks MCP. It does not refuse
  # — it hangs — so the agent waited out its 30 s tool-listing timeout and died
  # in init with MCPTimeoutError, before one token was ever asked of the model.
  # Measured here: load average 0.52 and zero Ollama requests at the moment it
  # failed, which is why "it ran out of CPU" was the wrong reading of it.
  #
  # OpenHands documents the fix on the field itself: "If running OpenHands on a
  # non-default port, set this to match." The two flags are one decision and
  # must not drift apart, so they sit together. OH_SANDBOX_HOST_PORT is what
  # the webhook callback is built from and OH_WEB_URL what the MCP URL is built
  # from — two different code paths off the same mistake, so both are set.
  #
  # OH_SANDBOX_KIND is not redundant, and leaving it out is a silent no-op.
  # 'sandbox' is a discriminated union, and its env parser reads <KEY>_KIND
  # FIRST; with three candidate kinds and no KIND set it cannot choose, so it
  # discards the whole nested entry — every OH_SANDBOX_* var with it. Measured
  # in the container: with OH_SANDBOX_HOST_PORT=3001 alone, config_from_env()
  # still reported host_port 3000 and the webhooks still went to Open WebUI,
  # which answers 405 rather than refusing. Naming the kind we are already
  # using makes the port setting take.
  #
  # And the publications are the other half again: naming the right port is no
  # use if nothing can dial it. Publishing ONLY on 127.0.0.1 puts the agent
  # behind the host's loopback, where a sandbox container — which reaches this
  # machine as the bridge gateway, never as 127.0.0.1 — cannot reach it at all.
  # Measured from inside a live sandbox: both the MCP URL and the app's root
  # answered 000, connection refused, on a container that was up and healthy.
  #
  # THREE addresses, all private, and the third one is why the phone never
  # worked. 'lca agent url' prints http://<tailscale-ip>:AGENT_PORT and
  # docs/AGENT.md calls it "the address to open on your phone" — but nothing
  # was ever published there, so the documented phone path had never once
  # worked. From this machine it was invisible: loopback answered, the guard
  # reported the port covered, every check passed.
  #
  #   127.0.0.1        you, and 'lca agent status'
  #   <bridge gateway> the agent's own sandboxes
  #   <tailscale ip>   your phone
  #
  # Three SPECIFIC addresses, deliberately, rather than one 0.0.0.0. They do
  # not collide with each other — only 0.0.0.0 collides, because it already
  # covers the others, and adding it alongside the bridge publication fails
  # with "address already in use". Publishing on 0.0.0.0 would also put the
  # most dangerous port this project opens on every interface including a
  # public one, and lean on the inbound guard to take it back; naming the three
  # addresses that should reach it needs no such argument. docs/AGENT.md
  # carries the full reasoning.
  #
  # When Tailscale is not up yet there is no address to publish on, so the
  # agent starts without it and says so — a restart picks it up. That is also
  # what 'lca check' reports, rather than leaving it to be discovered from a
  # phone that will not connect.
  local tailscale_pub=() tsip=""
  if tsip="$(tailscale_ip4)"; then
    tailscale_pub=( -p "${tsip}:${AGENT_PORT}:3000" )
  else
    warn "No Tailscale address yet, so the agent is being published on this machine only. Your phone will not reach it until Tailscale is up and you run: lca agent restart"
  fi

  local extra_env=()
  if [[ -n "${instructions}" ]]; then
    # LLM_SYSTEM_PROMPT_SUFFIX is not a documented OpenHands variable, so this
    # does not pretend it is one: the file is also mounted where the agent can
    # read it, and docs/AGENT.md says which of the two is guaranteed. An env
    # var that may do nothing is fine only when something else does the job.
    # INERT, and now known to be. 'grep -rn LCA_USER_INSTRUCTIONS /app/openhands'
    # is empty: it is a name this project invented, so nothing on the other side
    # was ever going to read it. Kept because it costs one env var and would be
    # the natural hook if OpenHands ever grows one -- but nothing may reason
    # from its presence that the instructions reach the model. They reach it
    # through agent_task_prompt, which is measured and byte-identical on
    # arrival, and through nothing else.
    extra_env+=( -e "LCA_USER_INSTRUCTIONS=${instructions}" )
  fi

  # WHICH OF THESE ACTUALLY DO ANYTHING. Audited 2026-08-22, by experiment
  # rather than by whether the API accepted them, after three settings in a row
  # turned out to be inert. The rule that came out of it:
  #
  #   OH_<FIELD> / OH_SANDBOX_<FIELD>   nested config. WORKS.
  #   bare SANDBOX_<FIELD>              read only inside `if config.sandbox is
  #                                     None`, and OH_SANDBOX_KIND makes that
  #                                     false, so it is DEAD here. This is how
  #                                     SANDBOX_STARTUP_GRACE_SECONDS fooled us;
  #                                     SANDBOX_VOLUMES sits in the same branch.
  #   a name this project invented      nothing reads it. Ever.
  #
  # Verified working: AGENT_SERVER_IMAGE_* (the sandbox runs that image),
  # OH_SANDBOX_HOST_PORT (arrives as OH_WEBHOOKS_0_BASE_URL), OH_WEB_URL
  # (arrives as OH_ALLOW_CORS_ORIGINS_0), OH_SANDBOX_STARTUP_GRACE_SECONDS
  # (setting it to 1 reproduced the 08-22 failure on demand), OH_AGENT_SERVER_ENV
  # (EXTENSIONS_REF reaches the sandbox and the catalogue is gone from the
  # prompt), LOG_ALL_EVENTS (read at app_server/utils/logger.py:62).
  #
  # INERT, and left in place deliberately -- see LCA_USER_INSTRUCTIONS above and
  # the lca-instructions mount below. docs/AGENT.md carries the whole table.
  as_root docker run -d \
    --name "${AGENT_CONTAINER}" \
    --restart unless-stopped \
    ${extra_env[@]+"${extra_env[@]}"} \
    `# INERT. Nothing reads this path: 'grep -rl lca-instructions /app/openhands'` \
    `# is empty, and none of CONVENTIONS.md's five load-bearing phrases appear` \
    `# anywhere in event 0. What OpenHands DOES read from .openhands is` \
    `# hooks.json, microagents, skills, setup.sh and pre-commit.sh. The rules` \
    `# reach the model through the TASK TEXT (agent_task_prompt) and only there.` \
    -v "${REPO_ROOT}/config/CONVENTIONS.md:/.openhands/lca-instructions.txt:ro" \
    -e AGENT_SERVER_IMAGE_REPOSITORY="${AGENT_RUNTIME_IMAGE}" \
    -e AGENT_SERVER_IMAGE_TAG="${AGENT_RUNTIME_TAG}" \
    -e OH_SANDBOX_KIND=DockerSandboxServiceInjector \
    -e OH_SANDBOX_HOST_PORT="${AGENT_PORT}" \
    -e OH_SANDBOX_STARTUP_GRACE_SECONDS="${AGENT_SANDBOX_GRACE_SECONDS}" \
    -e OH_WEB_URL="$(agent_web_url)" \
    -e OH_AGENT_SERVER_ENV="$(agent_sandbox_env)" \
    -e LLM_MODEL="${model}" \
    -e LLM_BASE_URL="${base_url}" \
    -e LLM_API_KEY=local-llm \
    -e LOG_ALL_EVENTS=true \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${HOME}/.openhands:/.openhands" \
    -p "127.0.0.1:${AGENT_PORT}:3000" \
    -p "${bridge_gw}:${AGENT_PORT}:3000" \
    ${tailscale_pub[@]+"${tailscale_pub[@]}"} \
    --add-host host.docker.internal:host-gateway \
    "${AGENT_IMAGE}" >/dev/null \
    || die "Could not start the agent container. Its own output: lca agent logs"

  ok "Agent started. ${AGENT_CONTAINER} is running."
  info "It may take a minute to answer while it unpacks. Then: $(agent_url_line)"
  seed_agent_settings
  warn_if_model_unreachable
}

# warn_if_model_unreachable — ask the agent's own container whether it can see
# Ollama, and say so plainly when it cannot.
#
# This is a probe, not a guess about the config. The app container sits on the
# same docker bridge as every sandbox and reaches this machine by the same
# route, so what it can dial is what they can dial.
#
# The failure it catches is the one that costs a whole night. OLLAMA_HOST is
# 127.0.0.1 by default — deliberately, and .env says why — but a container's
# loopback is the container, so it reaches this machine as the bridge gateway
# instead, and nothing is listening for it there. The stack still looks
# perfectly healthy: the container is up, the UI answers, 'lca agent status' is
# green, and the task simply never produces a token.
#
# Warned, not refused, and that is deliberate too: a relay or a widened bind
# are both legitimate answers, and this cannot tell that one is in place except
# by trying — which is exactly what it does.
warn_if_model_unreachable() {
  local base probe
  base="$(agent_llm_base_url)"
  # Its own curl, inside its own network namespace. '|| true' so a container
  # that is still unpacking, or an image without curl, is not turned into a
  # failure of 'start' — an unanswerable question gets no verdict.
  if ! as_root docker exec "${AGENT_CONTAINER}" \
        curl -fsS -m 8 -o /dev/null "${base}/models" >/dev/null 2>&1; then
    probe="$(as_root docker exec "${AGENT_CONTAINER}" command -v curl 2>/dev/null || true)"
    if [[ -z "${probe}" ]]; then
      info "Could not check whether the agent can reach the model (no curl in its image); if tasks never start, that is the first thing to test."
      return 0
    fi
    warn "The agent cannot reach Ollama at ${base}, so every task it is given will fail without producing a token — and nothing else here will look wrong."
    info "Why: OLLAMA_HOST is '${OLLAMA_HOST}', and a container's loopback is the container. It reaches this machine as the docker bridge gateway ($(docker_bridge_gateway)), where nothing is listening."
    info "Two ways out, and both are yours to choose: bind Ollama where the bridge can see it (OLLAMA_HOST=0.0.0.0:${OLLAMA_HOST##*:}, which the inbound guard already covers), or run a relay from the gateway to loopback. See docs/AGENT.md."
  fi
}

# agent_model_for_run lives in scripts/lib.sh, beside agent_llm_model and
# agent_model_name — the two it is always used with. It was defined here, and
# scripts/agent-task.sh sources lib.sh only, so the very first live run of
# 'lca agent task' died on "agent_model_for_run: command not found" before it
# could submit anything. See the note on the function itself.

# seed_agent_settings — write the LLM settings the agent needs before it can
# start ANY conversation.
#
# The LLM_MODEL / LLM_BASE_URL environment variables the docs give are not
# enough on their own. Measured on a freshly started container: GET
# /api/v1/settings answers {"error":"Settings not found"}, and the first task
# submitted then dies inside the app with
#
#   File ".../user/auth_user_context.py", line 50, in get_user_info
#     assert settings is not None
#
# So a stack that looks healthy — container up, UI answering, 'lca agent
# status' green — cannot run a single task until somebody opens the settings
# screen by hand. That is a phone-first product asking for a desktop browser.
#
# POSTed once at start, and best-effort: a failure here is a warning, never a
# reason to fail a container that did start. It is idempotent, so a restart
# re-asserts .env's model rather than leaving a stale one from an older run.
#
# The payload is a *_diff, and the shape is not cosmetic. The flat legacy body
# this function used to send — {llm_model, llm_base_url, ...} — is answered
# with 200 {"message":"Settings stored"} and stores NONE of it: the endpoint
# declares 'additionalProperties: true', so unknown keys are accepted and
# dropped. Measured on 1.8: after that 200, GET /api/v1/settings still read
# model 'gpt-5.5' with a null base_url, and this function had already printed
# "Agent settings seeded: openai/qwen2.5-coder:3b". A success message for
# something that did not happen, which is the exact class this repo keeps
# closing. The server names the right shape when asked for the wrong one:
# 422 {"error":"Use *_diff nested settings payloads instead of legacy keys"}.
#
# So the write is READ BACK, and only a value that actually landed is reported
# as seeded. A 200 from this endpoint is not evidence.
seed_agent_settings() {
  local url="http://127.0.0.1:${AGENT_PORT}/api/v1/settings" body waited=0
  local model base_url got got_native
  model="$(agent_llm_model "$(agent_model_for_run)")"
  base_url="$(agent_llm_base_url)"
  # Wait for the API rather than racing it: the container answers HTTP well
  # before this route exists.
  #
  # Announced, because measured this takes the full 90s when the API never
  # comes up — and a silent 90-second pause straight after "Agent started" is
  # the "is it hung?" this project keeps removing. Same reason the model load
  # says how long it may take.
  info "Waiting for the agent's API so its settings can be written (up to 90s)..."
  while (( waited < 90 )); do
    curl -fsS --max-time 3 -o /dev/null "${url}" 2>/dev/null && break
    # 404/500 still means the server is answering, which is all this needs.
    curl -sS --max-time 3 -o /dev/null "http://127.0.0.1:${AGENT_PORT}/" 2>/dev/null && break
    sleep 3; waited=$(( waited + 3 ))
  done
  # native_tool_calling is the setting that decides whether this tier does
  # anything at all, and it is sent as a real boolean rather than a string —
  # this endpoint accepts unknown keys and drops them silently, so a "false"
  # that arrives as a string is a setting that looks stored and is not.
  #
  # Why false. qwen2.5-coder never fills the API's tool_calls field: its own
  # template tells it to wrap calls in <tool_call> tags, it ignores that and
  # writes clean JSON in the message body, and Ollama — finding no tags —
  # reports zero tool calls. OpenHands reads that as "the assistant is
  # finished", so the run ends at once with an empty workspace and no error
  # anywhere. Measured on 3b and 7b, through both /api/chat and
  # /v1/chat/completions; and with this false the 3b created the file, ran it
  # and finished the task.
  # max_output_tokens is seeded as a cap on one reply, and for nothing else.
  # It was once believed to buy instruction room — "unset, the client reserved
  # half the window for output" — and it does not: measured, Ollama truncates
  # on prompt > num_ctx whatever the client asks for. See AGENT_MAX_OUTPUT_TOKENS
  # in lib.sh and docs/PROMPT-WINDOW.md. It is still sent as a number, not a
  # string: this API stores what it is given and a quoted "2048" round-trips
  # looking correct while meaning nothing.
  #
  # enable_switch_llm_tool is the ONE tool this stack can decline. It is read
  # by create_agent() and honoured, unlike the 'tools' list, which the app
  # overwrites with its own defaults on every conversation. Worth 254 tokens,
  # measured live by differencing two runs and subtracting the task-length
  # change — the tool lets the agent switch to another model on a box with one.
  # docs/PROMPT-WINDOW.md has the rest of the tool budget and why it is stuck.
  # agent:"CodeActAgent" is INERT, and kept only because it is this API's own
  # default. Measured: the string round-trips, but "CodeActAgent" exists nowhere
  # in the image except as the default of this very field -- the SDK ships
  # Agent and ACPAgent, and the conversation's base_state.json records
  # agent.kind = "Agent" whatever is posted here. Do not read its presence as
  # "this stack runs CodeActAgent"; nothing resolves the name at all.
  #
  # The llm.* fields below are the opposite and were checked the same way: all
  # five arrive in the sandbox's own base_state.json (model, base_url,
  # native_tool_calling, max_output_tokens 2048, timeout 1800).
  body="$(jq -nc --arg m "${model}" --arg u "${base_url}" \
        --argjson native "$([[ "${AGENT_NATIVE_TOOL_CALLING}" == "true" ]] && echo true || echo false)" \
        --argjson out "$(agent_max_output_tokens)" \
        --argjson tmo "$(agent_request_timeout)" \
        '{agent_settings_diff:{agent:"CodeActAgent",
                               enable_switch_llm_tool:false,
                               llm:{model:$m, base_url:$u, api_key:"local-llm",
                                    native_tool_calling:$native,
                                    max_output_tokens:$out,
                                    timeout:$tmo}}}')"
  curl -fsS --max-time 20 -X POST "${url}" -H 'Content-Type: application/json' \
       -d "${body}" >/dev/null 2>&1 || true
  # Read back, because the POST's status code proved nothing. jq's // guards a
  # null model; an unreachable API yields an empty string, which matches
  # neither and is reported as not seeded.
  got="$(curl -fsS --max-time 10 "${url}" 2>/dev/null \
         | jq -r '.agent_settings.llm.model // ""' 2>/dev/null || true)"
  # Read back separately, because this one is the difference between a tier
  # that works and one that finishes instantly with an empty workspace.
  got_native="$(agent_stored_native_tool_calling \
                "$(curl -fsS --max-time 10 "${url}" 2>/dev/null || true)")"
  if [[ "${got}" == "${model}" ]]; then
    ok "Agent settings seeded: ${model} at ${base_url} (native tool calling: ${got_native:-unset})"
    if [[ "${got_native}" != "${AGENT_NATIVE_TOOL_CALLING}" ]]; then
      warn "The agent stored native_tool_calling='${got_native:-unset}', not '${AGENT_NATIVE_TOOL_CALLING}'. With qwen2.5-coder that is the difference between a run that works and one that ends instantly with an empty workspace and no error — see docs/AGENT.md."
    fi
  else
    # Keeps the stronger check — this reports what the agent ACTUALLY holds, not
    # merely that a POST failed — and names a URL rather than a bare port:
    # "open port 3001's settings screen" reads as an instruction to open a
    # number.
    warn "The agent's LLM settings did not take — it still reports '${got:-none}', not '${model}', so its first task will fail or run against the wrong model. Open http://127.0.0.1:${AGENT_PORT} and save its settings once, or re-run: lca agent restart"
  fi
}

# The URL this prints is a promise, and 'lca check' now holds it to one: for
# the whole life of this tier it printed a Tailscale address that nothing was
# ever published on. Same helper as the publication, so the address it advertises
# and the address it binds cannot drift apart.
# remove_orphan_sandboxes — collect the sandboxes the app left behind.
#
# Says what it took and roughly what it was holding, because "removed 3
# containers" is the kind of line that is either reassuring or alarming
# depending on whether you knew they were there. Nobody knew they were there.
remove_orphan_sandboxes() {
  local orphans n name saved
  orphans="$(agent_orphan_sandboxes 2>/dev/null || true)"
  [[ -n "${orphans}" ]] || return 0
  n="$(grep -c . <<<"${orphans}")"
  step "Cleaning up sandbox containers"
  info "The app is down, so these cannot be reached by anything any more."
  while read -r name; do
    [[ -n "${name}" ]] || continue
    # Save the work BEFORE destroying the container that holds it. The sandbox
    # has no mounts, so 'docker rm -f' is the only thing standing between the
    # agent's output and oblivion, and this project used to tell people to go
    # read it afterwards. Best-effort and quiet when there is nothing to save.
    saved="$(agent_preserve_workspace "${name}" 2>/dev/null || true)"
    if as_root docker rm -f "${name}" >/dev/null 2>&1; then
      if [[ -n "${saved}" ]]; then
        ok "Removed ${name}. Its workspace was copied to ${saved} first."
      else
        ok "Removed ${name}."
      fi
    else
      warn "Could not remove ${name} — it is still running. Remove it by hand: sudo docker rm -f ${name}"
    fi
  done <<<"${orphans}"
  info "${n} sandbox container(s) collected. They do not stop on their own, and on a small box they are most of your memory."
}

agent_url_line() {
  local ip=""
  ip="$(tailscale_ip4 || true)"
  if [[ -n "${ip}" ]]; then
    printf 'http://%s:%s' "${ip}" "${AGENT_PORT}"
  else
    printf 'http://127.0.0.1:%s (no Tailscale address yet — see docs/PHONE.md)' "${AGENT_PORT}"
  fi
}

main() {
  local cmd="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "${cmd}" in
    # setup before start in the list because it is the order a new machine
    # needs them in: 'start' assumes six things are already true, and setup is
    # what makes them true and says which one was not.
    setup)   exec "${SCRIPT_DIR}/scripts/agent-setup.sh" "$@" ;;
    task)    exec "${SCRIPT_DIR}/scripts/agent-task.sh" "$@" ;;
    start)   start_agent ;;
    stop)
      require_cmd docker
      # if/else, not 'A && B || C', which is not if-then-else: C runs when A
      # succeeds and B fails, so a stop that worked could still report that
      # nothing was running.
      if as_root docker stop "${AGENT_CONTAINER}" >/dev/null 2>&1; then
        # Not "its workspace is kept in ~/.openhands" — it never was. Stopping
        # the app leaves the sandbox up, so at this moment the agent's files are
        # still inside that container; they reach ~/.openhands/workspaces only
        # when the sandbox is collected, which is what 'lca agent start' does.
        ok "Agent stopped; its settings are kept in ${HOME}/.openhands."
        if [[ -n "$(agent_live_sandboxes 2>/dev/null || true)" ]]; then
          info "Its sandbox is still running and still holds the agent's files. They are copied to ${HOME}/.openhands/workspaces when it is collected: lca agent start"
        fi
      else
        warn "The agent container was not running."
      fi
      # ...and its sandboxes, which nothing else was ever going to remove.
      #
      # With the app down every sandbox is unreachable by definition, and they
      # do not exit on their own: measured on a 7.8 GiB box, three alive at
      # once with the oldest thirteen hours old. Stopping the agent is the
      # moment they become garbage, so it is the moment to collect them.
      remove_orphan_sandboxes
      ;;
    restart) main stop || true; main start ;;
    selftest) exec "${SCRIPT_DIR}/scripts/agent-selftest.sh" "$@" ;;
    # gc — collect the sandboxes of conversations that are over, while the app
    # stays up. 'stop' has always collected them, but only by taking the whole
    # tier down with it, so on a machine that keeps the agent running they were
    # never collected at all. This is that collection, without the outage.
    #
    # It ASKS, and the confirmation is not politeness: a sandbox has no host
    # mount, so its filesystem is the only copy of whatever the agent built in
    # it. --yes is there for a script that has already decided.
    gc)
      require_cmd docker
      local reclaim="" line name why count=0 assume_yes=false answer="" saved=""
      for arg in ${@+"$@"}; do
        case "${arg}" in
          -y|--yes) assume_yes=true ;;
          -h|--help)
            printf 'Usage: lca agent gc [--yes]\n\nRemoves running sandbox containers whose conversation has finished.\nIdle conversations are left alone — they are yours to resume.\n'
            return 0 ;;
          *) die "Unknown option: ${arg}. Try: lca agent gc --help" ;;
        esac
      done
      reclaim="$(agent_reclaimable_sandboxes 2>/dev/null || true)"
      if [[ -z "${reclaim}" ]]; then
        ok "No sandboxes to collect: every running one belongs to a conversation that is still going, or the app could not be asked."
        return 0
      fi
      count="$(grep -c . <<<"${reclaim}")"
      step "Sandboxes whose conversation is over"
      while IFS=$'\t' read -r name why; do
        [[ -n "${name}" ]] || continue
        info "${name} — ${why}"
      done <<<"${reclaim}"
      info "A sandbox has no host mount, so anything the agent built lives only inside it. Whatever it wrote is copied to ${HOME}/.openhands/workspaces before the container goes."
      if [[ "${assume_yes}" != "true" ]]; then
        printf 'Remove %s sandbox container(s)? [y/N] ' "${count}"
        read -r answer || answer=""
        [[ "${answer}" =~ ^[Yy]$ ]] || { info "Nothing removed."; return 0; }
      fi
      while IFS=$'\t' read -r name why; do
        [[ -n "${name}" ]] || continue
        # Same order as remove_orphan_sandboxes, for the same reason: this is
        # the last moment the work exists. This path used to tell the user to
        # copy it out by hand and then delete it for them if they had not.
        saved="$(agent_preserve_workspace "${name}" 2>/dev/null || true)"
        if as_root docker rm -f "${name}" >/dev/null 2>&1; then
          if [[ -n "${saved}" ]]; then
            ok "Removed ${name}. Its workspace was copied to ${saved} first."
          else
            ok "Removed ${name}. It had written nothing."
          fi
        else
          warn "Could not remove ${name} — remove it by hand: sudo docker rm -f ${name}"
        fi
      done <<<"${reclaim}"
      ;;
    status)
      require_cmd docker
      if agent_container_running; then
        ok "Container '${AGENT_CONTAINER}': running"
      elif agent_container_exists; then
        warn "Container '${AGENT_CONTAINER}': exists but is not running (lca agent start)"
        return 1
      else
        warn "Container '${AGENT_CONTAINER}' does not exist (lca agent start)"
        return 1
      fi
      local live; live="$(agent_live_port 2>/dev/null || printf '%s' "${AGENT_PORT}")"
      if agent_health "${live}"; then
        ok "Agent answering on port ${live}"
      else
        warn "No answer on port ${live} yet (still unpacking? check: lca agent logs)"
        return 1
      fi
      ;;
    url)    printf '%s\n' "$(agent_url_line)" ;;
    logs)
      require_cmd docker
      as_root docker logs -f --tail 100 "${AGENT_CONTAINER}" \
        || die "Could not read the agent's logs (is it created? try: lca agent status)"
      ;;
    watch)  "${SCRIPT_DIR}/scripts/agent-watch.sh" "$@" ;;
    help|-h|--help) usage ;;
    "")     usage >&2; die "agent.sh needs a command." ;;
    *)      usage >&2; die "Unknown command: ${cmd}" ;;
  esac
}

main "$@"
