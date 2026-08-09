# AGENT.md — the autonomous tier

`lca` runs aider: it edits files in the directory you are standing in, one
request at a time, and you read the diff. This is the tier above it. You give
it a task in a browser, and it plans the work and carries it out — writing
files, installing packages, running builds, starting services — inside its own
Docker sandbox, without stopping to confirm each step.

That is the point of it and it is also the whole of its risk. It is **off by
default**.

```bash
# in .env
ENABLE_AGENT=true
```

```bash
sudo lca apply        # closes its port in the inbound guard
lca agent start       # creates and starts the container
lca agent url         # the address to open on your phone, over Tailscale
```

`lca agent start` also writes the agent's LLM settings for you. That is not a
convenience: on a fresh container `GET /api/v1/settings` answers
`{"error":"Settings not found"}`, and the first task submitted dies inside the
app on `assert settings is not None`. Without it the stack looks perfectly
healthy — container up, UI answering, `lca agent status` green — and cannot run
a single task until somebody opens the settings screen in a desktop browser,
which is not much use from a phone.

## What it is

[OpenHands](https://docs.openhands.dev), pinned to a specific image, pointed at
the Ollama already running on this machine. No API key, no cloud, nothing
leaves the box — the same claim the rest of this project makes, for the same
reason: the model is local.

| | |
|---|---|
| Image | `AGENT_IMAGE` (`docker.openhands.dev/openhands/openhands:1.8`) |
| Sandbox image | `AGENT_RUNTIME_IMAGE`:`AGENT_RUNTIME_TAG` |
| UI port | `AGENT_PORT` (3001) |
| Model | your `MODEL_NAME`, addressed as `openai/<model>` through Ollama's OpenAI-compatible endpoint |
| Workspace and settings | `~/.openhands` on this machine |

**Why 3001 and not 3000.** OpenHands' own documentation uses 3000, and so does
this project's chat app (`WEBUI_PORT`). The chat app runs with `--network=host`,
so the two would fight over one socket. `lca agent start` refuses to start if
the two ports are equal, rather than letting docker fail obscurely.

**And why moving the port is not enough on its own.** The traffic runs both
ways. The app publishes a UI for you, but every sandbox it starts must also
call *back* into it — to list its tools over MCP, and to report its events —
and OpenHands builds that callback address from a port it merely assumes,
`http://host.docker.internal:3000`, knowing nothing about the `-p` mapping. On
this stack host port 3000 is Open WebUI, which accepts the connection and then
never speaks MCP: not a refusal, a **hang**, ending in `MCPTimeoutError` after
30 seconds, in agent init, before the model is asked for a single token.

Three environment variables are therefore set for you, and each fixes a
different half of the same mistake:

| Variable | What it corrects |
|---|---|
| `OH_WEB_URL` | the MCP URL the sandbox is given |
| `OH_SANDBOX_HOST_PORT` | the webhook URL the sandbox reports events to |
| `OH_SANDBOX_KIND` | makes the line above take effect at all |

That third one is not padding. `sandbox` is a discriminated union whose env
parser reads `OH_SANDBOX_KIND` **first**, and with three candidate kinds and no
kind named it discards every `OH_SANDBOX_*` variable with it. Measured inside
the container: with `OH_SANDBOX_HOST_PORT=3001` set on its own,
`config_from_env()` still reported `host_port 3000`, and the webhooks still
went to Open WebUI — which answers `405` rather than refusing, so they failed
four times per event and the app's UI stayed empty while the agent worked.

## Where it is weak here, honestly

**The model is smaller than this agent wants, and the window is the hard
floor.** OpenHands' own local-LLM guide asks for a context window of at least
~22k tokens and suggests `OLLAMA_CONTEXT_LENGTH=32768`. This project's RAM
ladder gives **8192** on a 16 GiB box and **4096** on an 8 GiB one, because
that is what leaves room for the model itself.

This is not a "loses the thread sooner" problem, it is a "cannot start"
problem. Measured on a real run: the agent's first request to the model was
**15,492 tokens** — its system prompt plus 22 tool definitions — before the
task text. At the 4096 rung Ollama silently truncates that, and there is no
window in which the agent can work at all. Raise `OLLAMA_CONTEXT_LENGTH` to at
least 16384, and 32768 if the RAM is there, or do not enable this tier.

**The 3b model finishes the loop without doing the work.** This is the one to
read before enabling the tier on a small droplet. Measured end to end: the
agent started, thought for 26m48s, answered — and OpenHands marked the
conversation `finished` with an empty workspace. What the model returned was:

````
```
{
    "name": "file_editor",
    "arguments": {"file_text": "def fizzbuzz(n): ...", "path": "/workspace/project/fizzbuzz.py"}
}
```
````

The code in it was **correct**. It is just prose — a fabricated tool call
inside a markdown fence, not a tool call — so nothing executed, and an
assistant message with no tool calls is how the agent says it is done. The run
therefore *succeeds* and produces nothing, which is worse than failing.

This is the same pathology this project already documented for the phone chat
("the chat invented a tool call rather than admit it has no filesystem"), and
it is not a configuration problem: `native_tool_calling` is on, and Ollama
reports this model as `tools`-capable. A 3B model is simply not reliable at
emitting one. Give the agent tier the largest model your RAM allows, and do not
judge it by a run on the small rung.

**It is slower than the client's own patience.** That 15,492-token prompt is
processed at roughly **17 tokens/second** on 4 CPU cores — about fifteen
minutes for the first call. The LLM client gives up at its `timeout` (300 s by
default) and cancels, which Ollama logs as a `500`, and the run makes no
progress. Raise the LLM timeout in the agent's settings before handing it a
task on CPU. Each retry does resume from Ollama's prompt cache rather than
starting over, so it inches forward — but it inches.

**It is slow.** Every step is a full model round trip on a CPU. `lca speed`
prices one aider edit; an agent task is many of those in a row. This is a tool
for handing something over and walking away, not for watching.

**It is a large download.** Several GB across two images, on a box whose free
disk `lca check` already watches. Check before you start it.

## The limits, and whose they are

An agent left alone overnight goes wrong in three ways, and none of them
announce themselves. All three limits are enforced by **this project**, from
outside the container:

```bash
lca agent watch              # supervise a run
lca agent watch --dry-run    # report what it would stop, stop nothing
```

| Setting | Default | What it stops |
|---|---|---|
| `AGENT_MAX_ITERATIONS` | 100 | it taking thousands of tiny steps |
| `AGENT_TIMEOUT_MINUTES` | 180 | it running for ever |
| `AGENT_STUCK_STRIKES` | 3 | it retrying one broken idea until the clock runs out |
| `AGENT_STEP_SOURCE` | `auto` | where the ceiling counts steps from — see below |

`0` means "no limit" for all three — the same convention `BACKUP_KEEP=0`
already uses in this project for "keep everything". A value that is not a
number also means no limit rather than an error: a typo in `.env` must not kill
a run that is going fine. `lca check` warns about either.

**Why they are ours and not the agent's.** OpenHands' V1 documentation
publishes no environment variable for an iteration ceiling or for confirmation
mode. This project does not ship settings that might quietly do nothing, so
these are enforced here, where they can be — and are — tested.

**What the stuck detector actually compares.** Not the raw log line: the same
failure arrives with a new timestamp, pid and temp path every round, so raw
comparison sees a novel error each time and never fires. Any word containing a
digit is collapsed first, so

```
ERROR build failed in /tmp/x7f3a9b2 after 12 retries
ERROR build failed in /tmp/c1d0e5f8 after 47 retries
```

are one signature, while `build failed` and `tests failed` stay two.

**What has been proved, and against what.** All three limits were run against
real `docker logs -f` streams, not only unit-tested: the wall clock fires at
exactly 60s on a container that logs *nothing* (silence is the shape of a hung
run, and a loop that only judges on output would never notice), the step
ceiling stops at exactly `AGENT_MAX_ITERATIONS` lines, and the stuck detector
fires on three repeats of one failure whose id and timestamp differ every
round. `--dry-run` left the container running in each case.

**Where the steps actually are.** The container you start is not the one that
does the work. It spawns a **sandbox** per conversation, named
`oh-agent-server-<random>`, and every `openhands.sdk` / `openhands.tools` line
is logged there — the app container's own log contains no step line at all. So
`watch` follows both, and rediscovers sandboxes as they appear, because one
started after the run began would otherwise never be read.

That sandbox logs **JSON**, one object per line:

```json
{"asctime": "...", "levelname": "INFO", "name": "openhands.tools.terminal.impl", "message": "..."}
```

`AGENT_STEP_PATTERN` therefore matches the logger `name`, which is the stable
part. The first version of it was written for plain text against the app
container and matched **zero** lines of a real run — which is exactly why the
next paragraph exists.

**Verified against the real log shape.** A container emitting the JSON above was
followed end to end: three step lines counted, the ceiling fired at exactly
three, and no `docker logs -f` follower was left behind afterwards. The
rediscovery was tested too — the app container emitted only non-matching lines
while a sandbox appeared **twelve seconds after** the watcher started, and its
lines are what drove the ceiling. A list of containers resolved once at launch
would have counted nothing.

**What the step ceiling cannot do, measured on real hardware.** The pattern
matches, and what it matches is not steps.

A live run was followed end to end on a machine where the agent genuinely
worked — MCP tools created, 22 tools loaded, the conversation started, real
traffic to the model. Against that sandbox's whole log:

```
lines: 65   step matches: 6   failure matches: 0
     2  openhands.tools.browser_use.impl
     1  openhands.tools.terminal.terminal.tmux_pane_pool
     1  openhands.tools.terminal.impl
     1  openhands.sdk.conversation.impl.local_conversation
     1  openhands.sdk.agent.base
```

All six are emitted **once**, while the sandbox starts its tools. The log then
stayed at exactly 65 lines while the model was called over and over: at its
default level (`ENV_LOG_LEVEL=20`) the sandbox writes **nothing per reasoning
step**.

So counting log lines gives about six per sandbox and then nothing, and a
ceiling of 100 **cannot fire**. No regex fixes this, because the information is
not in the log.

`AGENT_TIMEOUT_MINUTES` and `AGENT_STUCK_STRIKES` are unaffected — neither
depends on step lines, and both were proved against real log streams.

**So the ceiling reads from the event API instead.** The stream OpenHands does
publish, one entry per event, is the conversation's own event log, and
`AGENT_STEP_SOURCE` says which stream the ceiling counts:

| Value | Counts |
|---|---|
| `auto` (default) | the event API, falling back to the container log |
| `events` | the event API only |
| `log` | the container log only |

On `auto` the supervisor asks the app for its conversation at start and every
third tick until it gets one, then polls the event count every tick — on a
clock, not on a log line, because a step that writes nothing to the log is the
entire reason this source exists. `watch` says which arm is live in its first
line and again in every stop message, so a ceiling that is not armed is visible
in the first minute rather than in the morning.

Two things are deliberately blunt about it:

- **An event is finer-grained than a reasoning turn.** The one measured turn
  here produced five events (system prompt, task, `running`, the reply,
  `finished`). The ceiling counts events *from the moment watching starts*, so
  the prologue is not charged to the run, but `AGENT_MAX_ITERATIONS=100` is
  still a bound on events rather than on turns.
- **An unreadable answer is `unknown`, never `0`.** OpenHands publishes the
  event routes but no schema this project could pin to, so several plausible
  response envelopes are accepted and anything else yields nothing at all. A
  ceiling handed `0` every tick would never fire and would then report a clean
  run — which is exactly the failure the log arm turned out to be, and it is
  not worth reproducing in a new place.

If a run ends with **no** line having matched, `watch` says so and exits
non-zero rather than reporting a clean run — a limit that silently never fires
is worse than no limit, because it was believed. That guard is what made this
visible instead of comfortable.

## Your instructions reach it too

`config/CONVENTIONS.md` is the one file that steers all three surfaces — aider,
the chat app, and this agent. The agent gets it two ways, because only one of
them is guaranteed:

- **Mounted** at `/.openhands/lca-instructions.txt` inside the container, which
  is a plain bind mount and therefore certain.
- **Passed** as `LCA_USER_INSTRUCTIONS`, which is *not* a documented OpenHands
  variable. It costs nothing if the agent ignores it, and this project does not
  claim it works — the mount is the part that does.

`AIDER_CONVENTIONS=false` switches the file off for all three at once.

## Security

This is the most dangerous port this project opens. A browser session on it can
run commands on your machine, and the container is given the Docker socket so
it can start its own sandboxes.

Two things protect it, and both are checked:

1. **It is published on private addresses only** — never `0.0.0.0`. There are
   two of them, and the second one is not decoration: `127.0.0.1:AGENT_PORT`
   for you, and `<docker-bridge-gateway>:AGENT_PORT` for the agent's own
   sandbox containers, which reach this machine as the bridge gateway and can
   never reach its loopback. Measured: with the loopback publish alone, a live
   sandbox got `000` — connection refused — for both the MCP URL it must list
   its tools from and the app's own root, and the run died in init.

   What that widens, stated plainly: **any container on the default docker
   bridge can now reach the agent's UI.** What it does not do is put it on a
   public interface — a bridge gateway is routable only from this host and its
   containers.
2. **The inbound guard covers its port**, by exactly the rule the chat app
   taught this project: `ENABLE_AGENT` is a statement of intent, a listening
   socket is a fact. A container still running after you set `ENABLE_AGENT=false`
   is still listed and still guarded — turning a feature off in `.env` must
   never make this box more exposed.

   The guard **accepts the docker bridge**, alongside `lo` and `tailscale0`,
   and that is what makes 1 and 2 able to coexist. Traffic from this machine's
   own containers arrives on `docker0`, which is not loopback, so the guard used
   to drop it: measured, 626 packets from the agent's sandbox to Ollama were
   dropped by the guard's own counter, and the tier could not work at all. A
   bridge is local traffic for the same reason `lo` is.

`sudo lca status` shows what the guard covers. `lca check` reports the agent's
port among the rest.

`sudo lca apply` **reports** the agent rather than acting on it — that is the
one applier that does not recreate its container. The chat app is stateless
between messages; this may be halfway through a task you left running
overnight, and tearing that down because a config line changed would destroy
exactly the work the tier exists for. It names the drift and the one-line fix
(`lca agent restart`) and leaves the timing to you. It also says so, loudly, if
`ENABLE_AGENT=false` while the container is still running.

## What it does not do

It does not replace `lca`. For a change you can describe in a sentence, aider
in your project directory is faster, cheaper and easier to review — and `git
diff HEAD~1` still works exactly the same way afterwards. Reach for the agent
when the work is genuinely multi-step and you want to hand it over.

---

## How the agent reaches the model

A container's loopback is the container. Ollama is bound to `127.0.0.1` on
purpose, so the agent — which runs in its own network namespace — sees this
machine only as the docker bridge gateway, where nothing is listening. Every
task it is given then fails without producing a single token, and nothing else
in the stack looks wrong.

There were two ways out and they are not equal.

**Not chosen: `OLLAMA_HOST=0.0.0.0`.** That puts an unauthenticated model API on
every interface this box has, leaving the inbound guard as the only thing
between it and the internet. One misapplied ruleset and the model server is
public.

**Shipped: a relay.** Ollama stays exactly where it is. A socket-activated
forwarder binds the bridge gateway **alone** — an address that is not routable
from outside the machine — and forwards to loopback.

```bash
ENABLE_OLLAMA_RELAY=true        # in .env
OLLAMA_RELAY_PORT=11435
sudo lca relay install          # writes and enables the boot units
lca relay status                # is it bound, and does Ollama answer through it
```

It uses **`systemd-socket-proxyd`**, which ships inside systemd. Not socat,
which would be a new package on every install; not a proxy of our own, which
would put a new HTTP parser on the path every token travels. `FreeBind=true` on
the socket is what makes it survive a reboot on a machine where docker starts
after it — the gateway address does not exist until the bridge does.

`lca check` reports it, `guarded_ports` knows the port, `uninstall.sh` removes
both units and releases the bind.

### Why it is not also a context injector

The relay was going to be a small HTTP proxy so it could inject
`options.num_ctx` per client — giving the agent a large window without raising
`OLLAMA_CONTEXT_LENGTH` for aider and the chat app. **Measured, and it cannot
work that way.** Ollama's OpenAI-compatible endpoint — the one OpenHands speaks
— ignores it:

| Request | Loaded `context_length` |
|---|---|
| `POST /v1/chat/completions` `{"options":{"num_ctx":8192}}` | 4096 |
| `POST /v1/chat/completions` `{"num_ctx":8192}` | 4096 |
| `POST /api/chat` `{"options":{"num_ctx":8192}}` | **8192** |

(read back from `/api/ps`, server default 4096). A proxy could only have
delivered it by rewriting `/v1` requests onto `/api` — reimplementing the
translation Ollama already does, on the hot path.

**A derived model does it properly**, and `/v1` honours that:

```bash
printf 'FROM qwen2.5-coder:3b\nPARAMETER num_ctx 16384\n' > agent.Modelfile
ollama create qwen2.5-coder:3b-agent -f agent.Modelfile
```

Asked through `/v1`, that model loads at `context_length: 16384` while the
server default stays 4096 for everything else. The cost is honest and worth
knowing: it is a second entry in Ollama's loader, so if both are hot at once
the box holds two copies of the weights.

---

## The tool-call channel, and why the default is `false`

The first live run of this tier produced correct FizzBuzz and an empty
workspace. No error, anywhere. The conversation was marked `finished`, which is
what OpenHands does when the assistant replies without any tool calls.

The cause, isolated in a single request and reproduced on demand:

```
POST /v1/chat/completions  (tools: [file_editor])   ->  tool_calls: 0
content: {"name":"file_editor","arguments":{"path":"/workspace/project/fizzbuzz.py",
          "file_text":"def fizzbuzz(n):\n    if n % 15 == 0:\n ..."}}
```

The model wrote a **correct, parseable tool call into the message body**. Its
own chat template tells it not to — *"return a json object ... within
`<tool_call></tool_call>` ... Do not include any backticks"* — and it ignores
that instruction. Ollama looks for the tags, finds none, and reports zero tool
calls. The content is then thrown away by the native path.

Measured across both models and both endpoints:

| Model | Endpoint | `tool_calls` | The body it wrote |
|---|---|---|---|
| `qwen2.5-coder:3b` | `/api/chat` | 0 | valid JSON, correct, runs |
| `qwen2.5-coder:7b` | `/api/chat` | 0 | valid JSON, correct, runs |
| `qwen2.5-coder:7b` | `/v1/chat/completions` | 0 | valid JSON, correct, runs |
| `qwen2.5:3b` (instruct) | `/v1/chat/completions` | **1** | a real native call |

So this is a **channel** failure, not a capability failure, and **not a size
problem** — the 7b fails exactly as the 3b does. The plain `qwen2.5` instruct
model uses the native channel correctly and writes worse code, which is the
wrong trade.

`AGENT_NATIVE_TOOL_CALLING=false` makes OpenHands parse the tool call out of
the text the model actually writes. With it, on this stack:

```
ActionEvent  agent  {"command":"view","kind":"TaskTrackerAction"}
ActionEvent  agent  {"kind":"FinishAction","message":"The task has been completed..."}
$ cat /workspace/project/fizzbuzz.py        # 180 bytes, on disk
fizzbuzz(3,5,15,7) == ['Fizz','Buzz','FizzBuzz','7']
```

A `qwen2.5-coder:3b` on CPU, start to finished file, in about ten minutes. The
run also shows the loop correcting itself — OpenHands rejected two malformed
calls (`Missing required parameters for function 'think'`, `Parameter
'security_risk' is expected to be one of [...]`) and the model fixed both.

Set it `true` only for a model that genuinely uses the native channel.
