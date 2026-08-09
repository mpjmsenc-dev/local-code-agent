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

### 3. One instructions file, respected everywhere — NOT STARTED

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

## Next step, precisely

Priority 3: one instructions file respected everywhere. Add
`lca_user_instructions` to `scripts/lib.sh` reading `config/CONVENTIONS.md`,
have `lca_system_prompt` append it (keeping the product-authored part that
describes what the chat box *is*), and have the agent's task framing use it
too. Then document what it does and does not override.

## Standing constraints observed

- Never apply firewall rules on this machine (read-only inspection, and
  `nft --check` only). `lca apply` reconciles the guard, so it is not run here.
- Test artefacts are removed when finished with.
