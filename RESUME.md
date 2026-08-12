# RESUME.md — the agent tier's first run on real hardware

Branch: `agent-live-verify`, based on `claude/local-code-agent-build-dd13qw`
(PR #28). Machine: the DigitalOcean droplet — 4 vCPU, 7.8 GiB RAM, 138 GB free,
Ubuntu 24.04.4, `qwen2.5-coder:3b`.

The job was the one open item the previous RESUME.md left: enable the tier,
run one real OpenHands task, and see whether a full agent reasoning loop
completes and whether `AGENT_STEP_PATTERN` matches the sandbox's real STEP
lines.

---

## Read this first: some of what follows is out of date

Everything under the next divider is the record of that night, unchanged and
worth keeping. But a file called RESUME.md is where somebody looks to find out
what to do next, and several of its statements have been overtaken — including
one that would tell you an unattended run is unprotected when it is not.

| What the record says | What is true now |
|---|---|
| `AGENT_MAX_ITERATIONS` is decoration; the log cannot carry steps | **The step ceiling is enforced**, from the app's event API rather than the log. It fired against real OpenHands events on the droplet: four events, a ceiling of three, run stopped. `AGENT_STEP_SOURCE=auto` uses the API and falls back to the log. |
| One decision still open: how the agent tier reaches Ollama | **Decided and shipped.** `OLLAMA_HOST` stays on loopback; a `systemd-socket-proxyd` relay carries the bridge, is covered by the inbound guard, survives reboots, and is part of setup, `lca check` and uninstall (`lca relay status\|install\|remove`). |
| Give the tier a bigger model before judging it again | **Measured instead of assumed, and the answer was no.** A 7b *fits* — 5.1 GB resident at 4096 — but it is 1.9× slower to think, 2.2× slower to generate, and it fails the tool-call channel exactly as the 3b does. What unblocked the tier was `AGENT_NATIVE_TOOL_CALLING=false`, not more parameters. |
| The app is published on two private addresses | **Three.** Loopback for you, the docker bridge for its own sandboxes, and the Tailscale address for your phone. The third was missing for the tier's whole life, so `lca agent url` printed an address nothing was ever bound to and the documented phone path had never once worked. |
| The tier completes a loop without doing the work | **Half true, and the half that matters is still open.** The selftest works: one real task, end to end on the droplet, 12 minutes, 19.6 tok/s reading and 8.5 writing, a file actually written. Two LARGER tasks then failed the same way — the agent declares completion without running its own work. This line said "It does the work" for a while; the two runs corrected it. |

`ENABLE_AGENT` still defaults to `false`, and the reason changed: not "too slow
to be useful" — that was a projection and the measurement refuted it — but ~7 GB
of images and a tier that can run anything on the machine. Opt-in for consent
and disk, not for viability. The long version is in docs/AGENT.md.

---

## First, a correction to the brief

**`ENABLE_AGENT` was not "currently false". The agent tier was not on this
machine at all**, and neither was any of the work described in the handover.
The checkout in `/opt/local-code-agent` was ~90 commits stale and sitting on
`main`, which has never contained the tier. `grep` over the working tree, over
every branch, and over all 103 blobs in the object store returned nothing for
`openhands`, `ENABLE_AGENT` or `AGENT_STEP_PATTERN`.

A `git fetch` is what found it: the tier lives on
`claude/local-code-agent-build-dd13qw`, unmerged, and `origin/main` had also
advanced by ~90 commits. I checked that branch out and worked from there. Had
I trusted the first search I would have reported "the feature does not exist",
which was wrong — worth stating because a stale clone gives a very confident
wrong answer.

`.env` was equally stale: 20 settings missing, including every `AGENT_*` one.
`sync_env_keys` (the project's own backfiller) added them.

---

## The headline

**A full agent reasoning loop completed, for the first time on this hardware —
and it completed without doing the work.** Getting there took four distinct,
reproducible bugs, all now fixed. What the loop then revealed is a fifth
problem that no fix in this repo can reach: the 3b model.

The previous session's diagnosis of why it never got this far was wrong.

It recorded that the sandbox "died first on an MCP server timeout (30s) with
the CPU busy running the model", and attributed the failure to resource
pressure. On this box the *identical* failure reproduced with **load average
0.52, 5.5 GiB RAM free and Ollama at zero requests** — the CPU was idle and the
model had never been asked for a token. It was never a resource problem, and
the extra CPU and disk this machine has were not what unblocked it.

**What it actually was:** the agent tier could not talk to itself, or to the
model, on any of three separate channels. Each failure was silent or
mis-signalled, and each hid the next one behind it.

---

## The four bugs, in the order they had to be peeled

### 1. Every sandbox callback went to Open WebUI

`agent.sh` publishes the app on `AGENT_PORT` (3001) precisely because 3000 is
`WEBUI_PORT`. But OpenHands hands its *own* address to every sandbox it starts
— the MCP server the agent lists its tools from, and the webhook it reports
events to — and it builds that address from a port it merely assumes:

```
MCP configuration: {'mcpServers': {'default':
  {'url': 'http://host.docker.internal:3000/mcp/mcp', ...}}}
```

`host.docker.internal:3000` is the docker bridge gateway on port 3000, which on
this stack is **Open WebUI**. Open WebUI accepts the TCP connection and never
speaks MCP — it does not refuse, it **hangs** — so the agent waited out its 30
second tool-listing timeout and died in `init_state` with `MCPTimeoutError`,
before the model was ever contacted.

Moving the UI port was only half the job; the callback port was never told.

**Fixed:** `-e OH_WEB_URL` (the MCP URL) and `-e OH_SANDBOX_HOST_PORT` (the
webhook URL) in `agent.sh`, both built from `AGENT_PORT`.

### 2. `OH_SANDBOX_HOST_PORT` on its own is a silent no-op

Setting it changed nothing. `sandbox` is a discriminated union, and its env
parser reads `<KEY>_KIND` **first**; with three candidate kinds and no kind
named it discards the whole nested entry and every `OH_SANDBOX_*` variable with
it. Measured inside the container:

```
OH_SANDBOX_HOST_PORT=3001 alone   -> config_from_env().sandbox.host_port == 3000
+ OH_SANDBOX_KIND=Docker...       -> host_port == 3001
```

Until this, webhooks kept posting to Open WebUI, which answers `405` — so they
failed four times per event and the app's UI stayed empty while the agent
worked.

**Fixed:** `-e OH_SANDBOX_KIND=DockerSandboxServiceInjector`. Verified: zero
webhook failures afterwards, against ten before.

### 3. Publishing on loopback only made the app unreachable to its own sandboxes

`-p 127.0.0.1:${AGENT_PORT}:3000` is good security and was breaking the tier. A
sandbox reaches this machine as the **bridge gateway**, never as the host's
loopback, so with the loopback publish alone the app it must call back into
does not exist for it. Measured from inside a live sandbox: `000` — connection
refused — for both the MCP URL and the app's root.

**Fixed:** published twice, on two private addresses — `127.0.0.1:AGENT_PORT`
for the human, and `<bridge-gateway>:AGENT_PORT` for the sandboxes. The gateway
is discovered from docker, not hardcoded to 172.17.0.1.

**What that widens, stated plainly:** any container on the default bridge can
now reach the agent's UI. It is still not on a public interface — a bridge
gateway is routable only from this host and its containers.

### 4. The project's own inbound guard was dropping the stack's own traffic

With the above fixed, the sandbox still could not reach **Ollama**. The guard:

```
tcp dport { 3000, 11434 } ct state new counter packets 626 bytes 32420 drop
```

It accepts `lo` and `tailscale0` and drops everything else — including
`docker0`. Those 626 dropped packets were the agent's sandbox trying to reach
the model. And worse: `docs/AGENT.md` tells the user to run `sudo lca apply`,
which would have added **3001** to that same set and broken the MCP callback
too.

There was a second defect in the same place. `guarded_ports` (lib.sh) asks for
`Agent 3001`, but `render_inbound_rules` (netmode.sh) only ever emitted
`WEBUI_PORT` and Ollama's port. So `lca apply` reported an uncovered port,
re-applied a ruleset that still did not cover it, and would have reported the
same gap for ever — the unfixable loop this project's own comments say it
refuses to create.

**Fixed, both together, because either alone is wrong:** the guard now accepts
the docker bridge (local traffic, for the same reason `lo` is), and
`AGENT_PORT` is rendered into the drop set when `ENABLE_AGENT=true`. Validated
with `nft --check`; see the cleanup note about what was and was not applied.

### 5. (bonus) `lca agent start` reported settings it had not written

Not a blocker, but the same class this repo keeps closing. `seed_agent_settings`
POSTed a flat legacy body. OpenHands 1.8 answers `200 {"message":"Settings
stored"}` and stores **none of it** — the endpoint declares
`additionalProperties: true` and drops what it does not recognise. After that
200, `GET /api/v1/settings` still read model `gpt-5.5` with a null base URL,
while `lca agent start` had already printed:

```
[ ok ] Agent settings seeded: openai/qwen2.5-coder:3b at http://...
```

The server names the right shape when given the wrong one:
`422 {"error":"Use *_diff nested settings payloads instead of legacy keys"}`.

**Fixed:** the seeder sends `agent_settings_diff` and **reads the value back**,
reporting success only when the model that comes back is the one asked for.
Proven against a genuinely empty settings store (`~/.openhands` moved aside).

---

## What the run actually did, once all four were fixed

The agent got further than it ever has here. In order, all observed:

| | |
|---|---|
| MCP tool listing | `Created 5 MCP tools` — previously 30 s timeout, every time |
| Tool loading | `Loaded 22 tools from spec` |
| Conversation start | `POST /api/conversations -> 201` — previously `500` |
| Webhooks | zero failures — previously 4 retries then ERROR, per event |
| Model | real `POST /v1/chat/completions` traffic at `n_ctx = 32768` |
| First prompt | **15,492 tokens** |

### The loop ran to completion. Here is the whole of it.

From the conversation's own event store, which is the authoritative record:

| Event | Time | What |
|---|---|---|
| 00000 | 06:23:41 | system prompt |
| 00001 | 06:23:41 | the user task |
| 00003 | 06:23:41 | `execution_status: running` |
| 00004 | **06:50:34** | the assistant's reply |
| 00005 | 06:50:34 | `execution_status: **finished**` |

One step, **26 minutes 48 seconds**, and Ollama's own timing for it:

```
prompt eval  1381689 ms / 12425 tokens (111.20 ms per token,  8.99 tok/s)
eval          225052 ms /   133 tokens (1692.12 ms per token, 0.59 tok/s)
[GIN] 200 | 26m48s | POST "/v1/chat/completions"
```

15,833 prompt tokens, 142 completion tokens, HTTP 200, status `finished`. The
loop worked.

### ...and this is what it produced

````
```
{
    "name": "file_editor",
    "arguments": {
        "file_text": "def fizzbuzz(n):\n\tif n % 15 == 0:\n\t\treturn 'FizzBuzz'\n...",
        "path": "/workspace/project/fizzbuzz.py"
    }
}
```
````

The FizzBuzz is **correct**. It is also **prose** — a fabricated tool call
inside a markdown fence, not a tool call. OpenHands received an assistant
message carrying no tool calls, which is how an agent says it has finished, so
it marked the conversation `finished`. Nothing executed. `/workspace/project`
still contained only `.git`.

So the run *succeeded* and produced nothing, which is worse than failing —
there is no error anywhere to find.

This is not a misconfiguration. `native_tool_calling` is `true`, and Ollama
reports `qwen2.5-coder:3b` as `tools`-capable with 16 tool references in its
template. A 3B model is simply not reliable at emitting one. **This repo had
already recorded the identical pathology in the phone chat** — "the chat
invented a tool call rather than admit it has no filesystem", the 3b model
emitting `{"name": "build_expense_tracker", ...}`. It is the same failure, now
confirmed in the agent tier.

### The speed limit, measured

At 8.99 tok/s of prompt processing, the agent's ~15k-token prompt costs a
quarter of an hour before the model writes anything, and generation ran at
**0.59 tok/s**. The LLM client's default `timeout` is 300 s, so it cancels
first and Ollama logs a `500`; raising it to 2400 s is what let the call above
finish. Retries do resume from Ollama's prompt cache rather than starting over,
so a too-short timeout inches forward rather than looping for ever — but an
agent step costing 27 minutes is not a tier anyone will use on this rung.

> **Superseded, and this is the correction that matters most in this file.**
> Every number above was measured at `num_ctx=32768`. The agent now runs on a
> derived model at **16384**, and on the *same droplet* one whole `lca agent
> selftest` task — six links, a file written — takes **12 minutes**, reading at
> 19.6 tok/s and generating at **8.5 tok/s**. Fourteen times the generation rate
> of the 0.59 above, from nothing but the configuration.
>
> The sentence "not a tier anyone will use on this rung" was wrong, and it was
> wrong in a way worth remembering: it generalised one configuration's numbers
> into a verdict about the hardware. `docs/PERFORMANCE.md` now scopes those
> ratios to the run they came from.

---

## `AGENT_STEP_PATTERN` — the answer, and it is not the hoped-for one

**The pattern does not match a single reasoning step, because the sandbox does
not log one.**

Applied to the real sandbox log with the same bash `=~` test `agent-watch.sh`
uses:

```
lines: 65   step matches: 6   failure matches: 0
     2  openhands.tools.browser_use.impl
     1  openhands.tools.terminal.terminal.tmux_pane_pool
     1  openhands.tools.terminal.impl
     1  openhands.sdk.conversation.impl.local_conversation
     1  openhands.sdk.agent.base
```

All six are **tool initialisation**, emitted once when the sandbox comes up.

The decisive measurement: across the whole 27-minute reasoning step above — a
step that ran to `finished` — the sandbox log went from **65 lines to 66**. The
one new line was this:

```
openhands/sdk/llm/utils/telemetry.py:285: UserWarning: Cost calculation failed:
This model isn't mapped yet. model=qwen2.5-coder:3b ...
```

A litellm cost warning. Not a step, and the pattern does not match it (it has
slashes, not dots — so at least there is no false positive either). A complete
agent turn contributed **zero** matchable lines. The sandbox emits nothing per
step at its default level (`ENV_LOG_LEVEL=20`).

The previous session recorded "5 step, 4 failure matches" and called the
pattern confirmed. That count was the same initialisation lines, and one
earlier figure in this session (12) was an artefact of two `docker logs -f`
followers writing to one file — worth naming so it is not trusted later.

**What this means for the limits.** `AGENT_MAX_ITERATIONS` counts these lines.
A sandbox contributes ~6 once and then nothing, so at the default of 100 the
step ceiling **can never fire**. That is precisely the "limit that cannot
trigger is worse than no limit" case `agent-watch.sh` was written to refuse —
and its own guard is what makes this visible rather than silent: `watch`
refuses to call a run clean when nothing matched.

The wall clock and the stuck detector are unaffected; both were already proven
against real log streams and neither depends on step lines.

**This is not fixable by tuning the regex.** The information is not in the log.
The step stream OpenHands does publish is its **event API / webhook** — now
working, thanks to bug 2 — and that is where a real step ceiling has to read
from. That is a design change, not a pattern change, and I have not made it:
it replaces the supervisor's input, and it is the owner's call. It is the
single most valuable follow-up here.

---

## Changed in this pass

| File | Change |
|---|---|
| `agent.sh` | `OH_WEB_URL`, `OH_SANDBOX_HOST_PORT`, `OH_SANDBOX_KIND`; second `-p` on the bridge gateway; `seed_agent_settings` sends a `*_diff` and reads it back; new `warn_if_model_unreachable` probe |
| `scripts/lib.sh` | `docker_bridge_gateway`, `docker_bridge_interface`, `agent_web_url` |
| `netmode.sh` | guard accepts the docker bridge; `AGENT_PORT` rendered into the drop set when enabled |
| `docs/AGENT.md` | the callback-port trap, the dual publish and what it widens, the guard/bridge rule, the real context and speed numbers |
| `tests/test-lib.sh` | 6 new assertions (bridge publish, the three env vars, `agent_web_url`, bridge-name safety, the `*_diff` seeder and its read-back) |

### The one thing deliberately left for the owner

Ollama binds `127.0.0.1` by default, and `.env` says why. A container's
loopback is the container, so **the agent tier cannot reach the model out of
the box** even with everything above fixed. The two honest answers are to widen
the bind (`OLLAMA_HOST=0.0.0.0:11434`, which the guard already covers, and
which is exactly the posture Open WebUI already runs in) or to relay the bridge
gateway to loopback. Both change this stack's security posture, so instead of
picking one silently, `lca agent start` now **probes it from inside the agent's
own container** — the same network position a sandbox has — and, when it
cannot reach the model, says so, says why, and names both remedies. A
container that is up, answering, and green in `lca agent status` will otherwise
run a task to nothing.

For this verification I used the relay (`socat` on the bridge gateway), which
is removed again — see cleanup.

---

## Gates

`shellcheck -x -P SCRIPTDIR *.sh scripts/*.sh deploy/*.sh tests/*.sh bin/*
.githooks/*` — **exit 0, zero findings.** `bash -n` clean on all of them.

`tests/test-netmode.sh` — **all pass**, including four new assertions.

`tests/test-lib.sh` — **2 failures, neither from this work**, and all new
assertions pass. Both were checked against a pristine clone of the branch tip
in `/tmp/pristine`:

| Test | Verdict |
|---|---|
| `the model listing asks no disk for a model already downloaded` | pre-existing — fails on the pristine clone too |
| `...and reads the running server rather than shrugging, where it can` | pre-existing **on this box** — it asserts against the REAL `.env`, and hardcodes `.env.example`'s 8192 while this machine's RAM ladder gives 4096 |

The second is worth being precise about, because I did briefly make it fail for
my own reason (`OLLAMA_CONTEXT_LENGTH=32768`). With `.env` restored it still
fails, and it would have failed before I arrived: `scripts/apply.sh` is
untouched by this work, and flipping only `.env` between 4096 and 8192 flips
the assertion, nothing else does.

A third failure — `the prompt scanner reads quoted and mid-line mentions too` —
appeared in the middle of this session on both the pristine clone and here, and
passes in the final run. It is order- or state-sensitive, unrelated to this
work, and worth a look on its own.

### One test was changed, and it was not weakened

`tests/test-netmode.sh` compared `apply_inbound_guard`'s output against a
ruleset rendered from *whatever `.env` the machine has*, while the apply itself
ran against a fixture. Those agreed only while nothing in the ruleset depended
on a setting that differed between them — and rendering `AGENT_PORT` made them
differ, so a developer with the agent enabled saw a failure while the writer
was working perfectly. It now renders the reference from the **same** `.env`
the apply is given: one configuration on both sides, so only a real difference
can show up. Mutation-checked — deleting the bridge-accept line from
`netmode.sh` makes the new gate fail, and restoring it makes it pass.

---

## Everything this run touched outside the repo

Read-only inspection:

- `systemctl is-active ollama`, `journalctl -u ollama` — service state and the model's own timings.
- `docker ps -a`, `docker images`, `docker port`, `docker inspect`, `docker network inspect bridge` — what was running, and the bridge gateway/interface.
- `docker logs <container>` — the sandbox log this whole verification is about.
- `docker exec <container> ...` — reachability probes (MCP, Ollama) and workspace listings from inside the containers.
- `find / -xdev -iname "*openhands*"` — looking for the tier before the fetch found it.
- `sudo ss -ltnp` — which process holds 3000/3001/11434.
- `sudo nft -a list table inet lca_inbound` — reading the guard; this is what found the 626 dropped packets.
- `sudo nft -c -f /tmp/inbound.nft` — **validating** the new ruleset, not applying it.
- `curl https://api.github.com`, `curl https://ghcr.io/v2/` — outbound connectivity check.
- `curl http://127.0.0.1:{3001,11434}/...` — the agent API and Ollama, on loopback.

Changed something:

- `git fetch --all --prune` — network. Found the branch the whole task depends on.
- `docker pull docker.openhands.dev/openhands/openhands:1.8` — the agent app image (~2 GB).
- `docker pull ghcr.io/openhands/agent-server:1.26.0-python` — the sandbox runtime image (~3 GB).
- `sudo fallocate -l 4G /swapfile-lca-verify` + `mkswap` + `swapon`, `sudo sysctl -w vm.swappiness=10` — the box had **zero** swap and the brief blamed resource pressure; this was insurance. It was never needed (peak use 5.3 GiB of 7.8, swap stayed at 0 B). **Removed.**
- `sudo apt-get install -y shellcheck` — the project's lint gate requires it and it was not installed. **Left installed** (a gate that cannot run is worse than no gate).
- `sudo apt-get install -y socat` — for the Ollama relay below. **Left installed**, relay removed.
- `sudo socat TCP-LISTEN:11434,bind=<bridge-gw>,fork,reuseaddr TCP:127.0.0.1:11434` — made Ollama reachable from the bridge for the duration. **Stopped.**
- `render_ollama_dropin && restart_ollama` — wrote `/etc/systemd/system/ollama.service.d/local-code-agent.conf` and restarted the service, to apply `OLLAMA_CONTEXT_LENGTH=32768`. The 4096 rung this box's RAM selects cannot hold the agent's 15,492-token prompt at all.
- `sudo nft insert rule inet lca_inbound ingress iifname "docker0" accept` — an **accept-only** rule so the sandbox could reach the model. It cannot lock anyone out (SSH is never in the drop set). **Removed.**
- `bin/lca agent start|stop|restart` → `docker run/stop/rm` of `openhands-app`.
- `docker rm -f oh-agent-server-*` — clearing sandboxes between attempts.
- `POST http://127.0.0.1:3001/api/v1/{settings,app-conversations}` — seeding settings and submitting the tasks.
- `mv ~/.openhands ~/.openhands.pre-verify.<ts>` — reset OpenHands state to prove the seeder against an empty store. The old directory is still there.
- `git clone /opt/local-code-agent /tmp/pristine` — the control for the test comparison.

---

## Cleanup: what state this machine is in

**I chose to restore a clean, off state.** `ENABLE_AGENT=false`.

The reason is not caution about the code — the code is better than it was. It
is that with the relay and the firewall rule reverted (both were mine, neither
is shipped), an enabled tier on this box **cannot reach the model**, so leaving
`ENABLE_AGENT=true` would mean `lca check` and `lca apply` reporting a live
tier that cannot work, and `guarded_ports` asking for a port the loaded guard
does not cover. It would also leave a container holding the **docker socket**
running unattended — the largest blast radius in this stack — in exchange for
nothing. Off is the honest state.

Restored, item by item:

| | State now |
|---|---|
| `ENABLE_AGENT` | `false` |
| `AUTO_TUNE` / `OLLAMA_CONTEXT_LENGTH` | `true` / `4096` — the ladder's value for this box, drop-in re-rendered and Ollama restarted, so the running server matches `.env` again |
| Inbound guard | byte-identical to how I found it (`lo`, `tailscale0`, drop `{3000, 11434}`); my `docker0` accept rule deleted by handle |
| `socat` relay | stopped |
| Swap file | `swapoff` + deleted; `vm.swappiness` back to 60 |
| Agent containers | stopped and removed; no `oh-agent-server-*` left |
| Agent images | removed (~5 GB) — the tier is off, and `lca agent start` re-pulls them |
| `~/.openhands` | removed, both the live one and the copy I set aside (test conversations only; it is **root-owned**, so it needed `sudo` — worth knowing for `uninstall.sh` and backups) |
| `shellcheck`, `socat` packages | **left installed.** ShellCheck was missing and the project's own lint gate cannot run without it |
| `/tmp` artifacts, `/tmp/pristine` clone | removed |

`sudo lca apply --dry-run` afterwards reports Ollama and the guard both
matching `.env`. The single remaining drift it names (`WEBUI_BANNERS` on the
chat app) was there in the first dry-run of this session, before I changed
anything, and is not mine.

## The commit is made. The push could not be.

Committed to the local branch `agent-live-verify`, which tracks
`origin/claude/local-code-agent-build-dd13qw` (PR #28):

```
c468421 The agent tier could not talk to itself, and blamed the CPU
```

**`git push` fails: this machine has no credentials for GitHub.** No credential
helper, nothing in `~/.git-credentials`, no `GH_TOKEN`/`GITHUB_TOKEN`, no `gh`
CLI, and no SSH private key — `~/.ssh` holds only `authorized_keys`, for
inbound access. `git fetch` works only because the repo is public and anonymous
HTTPS reads are allowed; `git push` asks for a username and there is nothing to
answer with.

Nothing is lost — the commit is complete and the tree is clean. To publish it:

```bash
cd /opt/local-code-agent
git push origin HEAD:claude/local-code-agent-build-dd13qw
```

## The next step, precisely

Both items that stood here — a bigger model, and the step ceiling off the log —
were answered, and the answer to the first was not the expected one. The table
at the top of this file says what replaced them.

What is genuinely open, in order:

1. **The agent declares completion without executing its own work.** Measured
   twice, on unrelated tasks, at the 3b rung: one produced a script that dies on
   its first executed line and reported success. Two rules now travel with every
   task this project submits, and `lca agent task` names the working directory —
   but neither has been re-measured against a real run. **That is the next
   experiment, and it needs a droplet.**
2. **Is the rung the cause?** Unproven, and the most tempting wrong conclusion
   available. A straight swap to a 7b is *not* the experiment, because the 7b
   fails the tool-call channel identically. The real one is the same two tasks
   at a larger rung with `AGENT_NATIVE_TOOL_CALLING=false` — which needs a
   bigger box than 7.8 GiB, since the agent runs at a 16384 window where a 7b
   takes 5.9 GB.
3. **The first prompt is ~15k tokens before the agent's first output token**,
   and most of that is OpenHands' own framing rather than the task. It is the
   single change that would make every step cheaper on every box. Upstream of
   this project; an issue is open about the related finding that
   `agent_settings.tools` round-trips and is then ignored.

None of them blocks anyone today. Turn the tier on with `lca agent setup`, run
`lca agent selftest`, and it reports your own box's figure in about a quarter of
an hour — then read docs/AGENT.md before trusting it with anything larger.

