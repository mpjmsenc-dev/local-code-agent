# RESUME.md — where this work is, and the next step

Branch: `claude/local-code-agent-build-dd13qw` (PR #28, open, based on `main`).
Everything below is committed. `make gates` and both suites pass at every commit.

## The three named priorities

### 1. OpenHands full-autonomy agent tier — DONE

**Starting state: it did not exist.** No `openhands` reference anywhere in the
repo, no branch, no PR, no spec — checked before starting. So this is designed
here from OpenHands' official docs plus this project's own conventions, not
resumed from an earlier design.

What the official docs pin down (docs.openhands.dev, fetched, not guessed):

| Thing | Value |
|---|---|
| App image | `docker.openhands.dev/openhands/openhands:1.8` |
| Agent server image | `ghcr.io/openhands/agent-server` tag `1.26.0-python` |
| UI port (in container) | 3000 — **collides with this project's `WEBUI_PORT`** |
| Ollama wiring | `LLM_MODEL=openai/<model>`, `LLM_BASE_URL=http://host.docker.internal:11434/v1`, `LLM_API_KEY=<any>` |
| Host reachability | `--add-host host.docker.internal:host-gateway` |
| Mounts | `/var/run/docker.sock`, `~/.openhands:/.openhands` |

Two facts that shape the design and are NOT worked around silently:

- **Port 3000 is already `WEBUI_PORT`'s default here.** `AGENT_PORT` defaults
  to 3001 and collides with nothing; the collision is checked, not assumed.
- **OpenHands asks for a context window of at least ~22k tokens** and suggests
  `OLLAMA_CONTEXT_LENGTH=32768`. This project's RAM ladder gives **8192** on a
  16 GiB box. The agent will therefore be weaker here than its docs assume.
  That is documented for the user rather than hidden.

### 2. Long-run hardening (ceiling, wall clock, stuck detector) — DONE

Design decision already made and worth keeping: OpenHands' V1 docs do **not**
document env vars for `max_iterations` or confirmation mode, so this project
must not ship env vars that may do nothing — that is exactly the "reports
something that did not happen" class this repo keeps closing. The ceiling,
wall clock and stuck detector are therefore **our own supervisor**, written as
pure, unit-testable policy over a log stream, with the marker patterns
configurable and documented as needing tuning against a real run.

### 3. One instructions file, respected everywhere — DONE

Today `config/CONVENTIONS.md` is aider-only (via `--read`), and the WebUI's
system prompt is a separate hardcoded heredoc, `lca_system_prompt` in
`scripts/lib.sh`. The plan is a shared `lca_user_instructions` reader that
aider, the WebUI system prompt and the agent's task framing all consume, with
the product-authored part of the WebUI prompt kept (it describes what that
chat box *is* — no tools, no filesystem — which the user must not have to
restate).

Shipped for 1 and 2: `agent.sh` (start/stop/restart/status/url/logs/watch),
`scripts/agent-watch.sh` (the supervisor), the `lca agent` dispatch, nine
`.env` settings with defaults and `lca check` validation, `AGENT_PORT` in
`guarded_ports` on both the intent and the listening-socket arms, `docs/AGENT.md`,
and 21 assertions covering the limit policy, the stuck-detector signature and
the guard. `lca agent` took the name from an undocumented aider alias; bare
`lca` and `lca code` are unchanged.

**Not done and deliberately so: the images have never been pulled here.** This
box has ~14 GB free against a 15 GB floor `lca check` already fails, and the
two images are several GB. Every part that can be tested without them is
tested; the parts that need a running container (does OpenHands answer on
3001, do the watch patterns match its real log) are untested and marked as
such in docs/AGENT.md.

Shipped for 3: `lca_user_instructions` in `scripts/lib.sh`, read by aider
(unchanged), by `lca_system_prompt` (appended, never substituted, and last so
it is the most recent thing the model reads), and by the agent (bind-mounted,
plus a best-effort env var that docs/AGENT.md explicitly does not claim works).
`AIDER_CONVENTIONS` keeps its name and now governs all three at once.

The size cost is reported rather than spent: `lca check` measures the whole
prompt against 15% of THIS machine's `OLLAMA_CONTEXT_LENGTH` and warns when a
long instructions file eats the window. The unit gate still bounds the part
this project ships, measured with the appendix off — raising that budget to fit
a user's file would have been weakening a gate to pass.

## Verified live, not just gated

The app image turned out to be 0.35 GB compressed (~2 GB on disk), so it WAS
pulled and run here, and the design was checked against a real container:

    3000/tcp -> 127.0.0.1:3001        published on loopback only
    lca agent status -> running, answering on 3001
    guarded_ports    -> WebUI 3000 / Ollama 11434 / Agent 3001
    wall clock       -> fired at exactly 60s on a SILENT log, --dry-run left
                        the container running
    step ceiling     -> stopped at exactly 5 of 5 steps, real log stream
    stuck detector   -> fired on 3 repeats of one failure whose id and
                        timestamp differed every round

That found two bugs no unit test would have. The image has since been removed
and .env restored (ENABLE_AGENT=false, AGENT_TIMEOUT_MINUTES=180).

## The live run (done — on the sandbox box, NOT the droplet)

A real OpenHands task was submitted against the local model. It confirmed
`AGENT_STEP_PATTERN` by disproving it, and found a second blocker:

- The work happens in a **sandbox** container (`oh-agent-server-<random>`), not
  the one you start. Old pattern: **0 matches**. New pattern (matching the
  JSON logger `name`): **5 step, 4 failure matches**. `watch` now follows both
  and rediscovers sandboxes as they appear.
- The agent could not run **any** task: `GET /api/v1/settings` →
  `{"error":"Settings not found"}`, then `assert settings is not None`. The
  `LLM_*` env vars do not create that record. `lca agent start` now seeds it.

**Still not observed:** a full agent reasoning loop. The five matches are tool
initialisation; the sandbox died first on an MCP server timeout (30s) with the
CPU busy running the model. Re-check the pattern against a droplet run where
the loop completes.

## Context above the ladder — measured, not changed

| `num_ctx` | resident | gen tok/s (short prompt) |
|---|---|---|
| 4096 | 5.1 GB | — |
| 8192 | 5.5 GB | 4.82 |
| 16384 | 5.9 GB | — |
| 32768 | 6.9 GB | 3.93 |

~60 MB per 1k tokens; 32768 costs +1.4 GB over the 16384 rung and **−18%
throughput before the window is even filled**. `OLLAMA_CONTEXT_LENGTH` is
server-wide, so the agent cannot have a bigger window than aider and the chat
app without raising it for all three (a second Ollama instance would double
model residency). Per-request `num_ctx` works but OpenHands does not expose it.
The ladder is UNCHANGED — that is a default affecting every user.

## Swept after the three priorities

- `lca apply` did not know the agent existed while docs/AGENT.md said it did —
  `apply_agent` added, reporting rather than recreating (an agent may be hours
  into a task; the chat app is stateless and can be recreated, this cannot).
- `uninstall.sh` left the agent container running and still reported the stack
  removed. It holds the docker socket. Removed first now.
- `lca check` validated the agent's settings but never said whether it was
  running.

## Proposals — both since resolved by the owner

1. **Back up `~/.openhands`** — **APPROVED AND BUILT**. `BACKUP_AGENT_WORKSPACE`
   (off by default) with a `BACKUP_AGENT_MAX_MB` ceiling, one pure decision
   function, and a restore that moves a live workspace aside rather than
   overwriting it. Round-tripped on real files.
2. **Exercise the agent in CI** — **DECLINED, deliberately**. It would have
   caught nothing the live run did not.

## Next step, precisely

Nothing is mid-flight. All three named priorities are done, the ladder is
swept, and both proposals are resolved.

The one open item needs a machine this session cannot reach: confirm
`AGENT_STEP_PATTERN` against a **full agent reasoning loop**. The pattern has
been corrected against a real sandbox log (the original matched zero lines),
but the five matches observed were tool *initialisation* — the sandbox died
first on an MCP server timeout (30s) with the CPU busy running the model. Run a
task on the droplet, let the loop complete, and re-check. `watch` refuses to
call a run clean when nothing matched, so the gap is loud, not silent.

Also noted, not done: OpenHands' API accepts `system_message_suffix` per
conversation — a real documented field, unlike the `LCA_USER_INSTRUCTIONS` env
var priority 3 currently passes on spec. Worth rewiring the instructions
through it. The bind mount already works and is what docs/AGENT.md claims.

## Standing constraints observed

- Never apply firewall rules on this machine (read-only inspection, and
  `nft --check` only). `lca apply` reconciles the guard, so it is not run here.
- Test artefacts are removed when finished with.
