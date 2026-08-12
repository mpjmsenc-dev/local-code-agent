# AGENT.md — the autonomous tier

`lca` runs aider: it edits files in the directory you are standing in, one
request at a time, and you read the diff. This is the tier above it. You give
it a task in a browser, and it plans the work and carries it out — writing
files, installing packages, running builds, starting services — inside its own
Docker sandbox, without stopping to confirm each step.

That is the point of it and it is also the whole of its risk. It is **off by
default**.

## Does it work? Yes — and there is one command that proves it here

For most of this project's history that question had no honest answer. The tier
started every time while being silently incapable of executing a single tool
call: runs finished, reported success, and left an empty workspace with no error
anywhere to find. It now completes real tasks — the first one it ever finished
wrote a correct `fizzbuzz.py` to disk, on a 3b model, on CPU, in about ten
minutes.

Rather than ask you to take that on trust for *your* box:

```bash
lca agent selftest
```

One small real task, end to end, with the wall clock and this machine's
measured reading and writing speeds at the end. It checks six links in the
order they break — relay, model, container, settings, tool-call channel, and
whether a file actually appeared — and each failure names the remedy. Every one
of those six produced the sentence "the agent does not work" at least once
while this tier was being built.

## Turning it on

```bash
# in .env
ENABLE_AGENT=true
ENABLE_OLLAMA_RELAY=true    # required: see "How the agent reaches the model"
```

```bash
lca agent setup            # do all of the below, in order, and say what changed
lca agent selftest         # proves the whole chain on this machine
lca agent url              # the address to open on your phone, over Tailscale
```

`lca agent setup` exists because the six commands it replaces have to be run in
the right order, and getting it wrong is silent every single time.

### The six stops, and why the first run took an hour

Measured on a real machine, bringing this tier up for the first time. Six things
were wrong, in a chain. None of them printed an error:

| # | what was wrong | what it looked like |
|---|---|---|
| 1 | `ENABLE_AGENT=false` | the selftest failing on a tier that is off |
| 2 | no derived model | `tune` says *"Already tuned. Nothing to do."* — it only builds the agent's model when the tier is **on**, and it was not |
| 3 | relay not installed | the model is never contacted |
| 4 | relay installed, `ENABLE_OLLAMA_RELAY` still `false` | identical to 3 |
| 5 | settings hold the **base** model, not the `-agent` one | runs, at the wrong context window |
| 6 | port not published on Tailscale | works on the server, refuses on the phone |

Each fix reveals the next failure, which looks the same as the last one. That is
what turns six small problems into an hour: no message anywhere names the thing
that is actually wrong.

So `lca agent setup` walks the same chain in dependency order, fixes what it can,
and stops on what it cannot **with the exact command that clears it**. It is
idempotent — on a healthy machine it changes nothing and says so — and
`--dry-run` reports what it would change. The order is not cosmetic and a gate
holds it: the tier switch must come before the model build, because that is stop
2 above.

The individual commands still exist and still work:

```bash
sudo lca apply             # closes its port in the inbound guard
sudo lca relay install     # the docker-bridge -> loopback forwarder
sudo lca tune              # builds the agent's own wide-context model
lca agent start            # creates and starts the container
```

### Who owns a sandbox container

The app creates one `oh-agent-server-*` container per conversation, and until
now **nothing ever removed them**. Measured on a 7.8 GiB box: three alive at
once, the oldest thirteen hours old, none of them reachable by anything.

The rule, decided and enforced:

- A sandbox belongs to a **conversation inside the app container**. The app is
  the only thing that can send it a message.
- **When the app is not running, every sandbox is an orphan** — there is no way
  left to reach it, and it goes on holding memory. `lca agent stop` now removes
  them and says how many it took. A restart is a stop, so restarting collects
  them too, which is the case that used to accumulate.
- **While the app is running, nothing is removed automatically.** Deciding that
  a particular sandbox is idle means trusting a mapping between a container name
  and a conversation's `sandbox_id`, and being wrong there kills a task somebody
  is waiting on. That case is *reported* instead — `lca agent watch` warns when
  more than one run is alive — and never acted on.

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
   **three**, and each one exists because something could not reach it:

   | address | who needs it |
   |---|---|
   | `127.0.0.1:AGENT_PORT` | you, and `lca agent status` |
   | `<docker-bridge-gateway>:AGENT_PORT` | the agent's own sandbox containers |
   | `<tailscale-ip>:AGENT_PORT` | your phone |

   Measured for the second: with the loopback publish alone, a live sandbox got
   `000` — connection refused — for both the MCP URL it must list its tools
   from and the app's own root, and the run died in init.

   The third was missing for the entire life of this tier. `lca agent url`
   printed `http://<tailscale-ip>:AGENT_PORT`, this file called it the address
   to open on your phone, and **nothing was ever published there** — so the
   documented phone path had never once worked. It was invisible from the
   server: loopback answered, the guard reported the port covered, `lca check`
   was green. The only way to see it was to be holding the phone. `lca check`
   now compares what the docs promise against what is actually listening, and
   fails when they disagree.

   **Why three specific addresses and not one `0.0.0.0`.** Two reasons, and the
   first is mechanical: you cannot add `0.0.0.0` alongside them. It already
   covers the bridge address, so docker refuses the pair with *address already
   in use*. The second is the point of this section — `0.0.0.0` would put the
   most dangerous port this project opens on every interface, including a public
   one, and then rely on the inbound guard to take it back. Naming the three
   addresses that should reach it needs no such argument.

   What the bridge publication widens, stated plainly: **any container on the
   default docker bridge can reach the agent's UI.** What none of the three do
   is put it on a public interface.

   One operational consequence, worth knowing before it surprises you: a
   container started **before** Tailscale is up has no Tailscale address to
   publish on. `lca agent start` says so at the time, and `lca check` reports it
   afterwards. The fix is `lca agent restart`.
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

---

## What one task costs, and whether this tier is honest to switch on

Measured with `lca agent selftest` — one task ("create a file with a function
that returns `ok`"), start to file-on-disk, all six links green:

| Box | Model | Task |
|---|---|---|
| 4 vCPU / 16 GB | `qwen2.5-coder:7b-agent` @ 16384 | **11 min** — reading 50.2 tok/s, writing 6.2 tok/s |
| 4 vCPU / 16 GB | `qwen2.5-coder:3b-agent` @ 16384 | ~10 min (an earlier run of the same shape) |
| **4 vCPU / 7.8 GiB** | `qwen2.5-coder:3b-agent` @ 16384 | **12 min** — reading 19.6 tok/s, writing 8.5 tok/s |

Two things in that table are worth internalising.

**Model size barely moves the number**, because an agent step is dominated by
**reading**, not writing: OpenHands' prompt is around 15,000 tokens before the
model produces its first one. A two-line function and a two-hundred-line
refactor cost nearly the same on the way in.

**Neither does halving the machine.** The 7.8 GiB droplet is the box this
project targets, and one task there costs 12 minutes against 11 on a box with
twice the RAM. It reads 2.6× slower and writes 1.4× *faster* — the second
because it is running the smaller rung. Reading is where the hardware shows.

### On the target box, measured — and the projection that was wrong

The row below used to be a projection, derived by applying `docs/PERFORMANCE.md`'s
6.9× "writing" conversion to this box's numbers. It said 35–60 minutes. It has
now been replaced by a measurement on the real hardware, and **the projection was
wrong by a factor of three**:

| | model | reading | writing | one task like the above |
|---|---|---|---|---|
| 4 vCPU / 16 GB | `7b-agent` @ 16384 | 50.2 tok/s | 6.2 tok/s | 11 min |
| **4 vCPU / 7.8 GiB droplet** | `3b-agent` @ 16384 | **19.6 tok/s** | **8.5 tok/s** | **12 min** |

Both rows are `lca agent selftest`, all six links green, exit 0, with a file
actually written. The droplet ran its own ladder rung (3b) through the relay.

Why the projection missed by so much is worth knowing, because it is the same
mistake anyone reasoning from this project's numbers can make. The 6.9× figure
came from a *32768-context run with a ~16k-token prompt*, where the droplet
generated at 0.59 tok/s. At 16384 with the selftest's much smaller prompt, the
**same droplet** generates at 8.5 tok/s — fourteen times faster. That difference
is not the machine; it is the configuration. Generation on CPU slows down with
the number of tokens already in the window, and a 3.4 GB KV allocation on a
7.8 GiB box is near its limit besides.

**Reading converts across machines; writing does not convert across
configurations.** See `docs/PERFORMANCE.md`, where the ratios are now scoped to
the run they came from.

The practical rule: the only trustworthy answer for a box is that box's own
`lca agent selftest`.

### What the 3b actually produces: two real tasks, both failed

The selftest passing is a real result and it is a narrow one — it asks for one
file containing one function, and it names the exact path to write it to. Two
larger tasks were then run on the droplet at the same rung (`3b-agent` @ 16384),
and **both failed in the same way**. This is what a user should expect here.

| | task | what it did | verdict |
|---|---|---|---|
| run 1 | create a README | `touch README.md`, then *"successfully created"* | empty file, reported as done |
| run 2 | a `wordcount.py` CLI with a stated output format, error handling, a test file, run it, show the output | one write, then 25 minutes later a message quoting the code back and *"You can now use this script"*, `execution_status: finished` | code that cannot run, in the wrong directory, none of the three requested steps done |

Run 2's code had three defects, and the first is fatal:

- **It uses `os`, `sys` and `re` with no imports at all.** Verified by executing
  it: `python wordcount.py t.txt` fails immediately with
  `NameError: name 'sys' is not defined`. **The first executed line crashes.**
- It indexes `sys.argv[1]` with no guard, so the missing-argument case the task
  explicitly asked for raises `IndexError` instead of exiting 1 with a message.
- It never ran the file, never created the test file, and never showed output —
  all three explicitly requested.

It also wrote to `/workspace/wordcount.py` while working in
`/workspace/project/TestAppOllama1Coding`, so the deliverable landed outside the
repo entirely.

**The root cause is one thing, and it is not the code quality: the agent
declares completion without executing its own work.** One execution would have
caught the `NameError` in a second. Run 1 was the same shape — `touch` plus a
success claim. Two very different tasks, one failure mode.

**So, plainly: at the 3b rung this tier writes plausible-looking code and
reports success without running it.** Treat its output as a draft that has never
been executed, because that is exactly what it is. The tier is genuinely useful
for scaffolding and for tasks you were going to review line by line anyway. It
is not useful for anything you intend to trust unread.

Two things changed because of these runs:

1. **`config/CONVENTIONS.md` now carries two rules**, and both are keyed so they
   cannot be quietly dropped: run what you built and show its real output before
   claiming a task is done, and write files into the working directory you were
   given rather than the sandbox root. That file feeds all three surfaces.
2. **Naming the absolute path works, and this project's own selftest is the
   evidence.** Its task text says *"Create a file
   `/workspace/project/lca_selftest.py`"* — and the file lands there, every run.
   The two failing runs named no path and the file went to the sandbox root.

3. **`lca agent task` exists**, because the web UI cannot be reached but this
   can. It is the answer to "could the working directory be stated at
   submission time rather than hoped for" — for tasks submitted through the
   OpenHands web UI it still cannot, since that directory is chosen in the UI
   per conversation and never passes through this project. So this project
   grew its own way in.

```bash
lca agent task --dir /workspace/project/myrepo "add a --json flag to the CLI"
lca agent task --watch --dir /workspace/project/myrepo "..."   # and supervise it
```

What it does that the web UI does not:

- **Names the working directory twice.** In the prompt text, which is
  demonstrably read, and in `system_message_suffix`, which is the documented
  home for standing instructions. And it names it as an *instruction* — *"create
  and edit files ONLY under `<dir>`… do not write to /workspace or any directory
  above"* — because both failing runs were *given* a working directory and wrote
  above it anyway. Stating it was not enough; forbidding the alternative is the
  part that was missing.
- **Carries the two rules with the task**, the same two `config/CONVENTIONS.md`
  holds, from one function so the three surfaces cannot drift apart.
- **Returns the conversation id**, found by listing conversations before and
  after and taking the difference — not by picking the newest sandbox, which is
  the guess that once attached a watcher to a stale run for an entire night. It
  records the id, and `lca agent watch` prefers it over any inference.
- **Refuses to submit into a stack that cannot run the task**: tier off,
  container down, API not answering, or settings holding the wrong model each
  stop it *before* the task is posted, with the command that fixes them. A task
  accepted by a broken stack looks fine and produces nothing for half an hour.

**Honest status of the suffix**: unverified on this build. `agent_settings.tools`
round-trips through the settings API and is then ignored — 22 tools still load —
so a field being *accepted* proves nothing about it being *used*. That is
precisely why the same rules are in the prompt text, where they are known to be
read. If the suffix works it is the better home; if it does not, nothing is lost.

### The open question, and the experiment that would answer it

None of this says a bigger model fixes the root cause. Nobody has run these two
tasks at a larger rung, so **"the 3b is too small" is a hypothesis, not a
measurement** — and it is the most tempting wrong conclusion available here.

A straight swap is *not* the experiment, because the 7b fails the tool-call
channel exactly as the 3b does — measured, through both `/api/chat` and
`/v1/chat/completions`. The real experiment is **the same two tasks at a larger
rung with the prompt-parsed channel** (`AGENT_NATIVE_TOOL_CALLING=false`), which
is what makes this tier work at all here.

That needs a bigger box than the droplet: the agent runs at a 16384 window, where
a 7b needs 5.9 GB and leaves under 2 GiB for everything else on 7.8 GiB. So it is
recorded here as the open question rather than guessed at. Anyone with the
hardware can settle it in an afternoon and bring the numbers.

### So: is `ENABLE_AGENT=true` an honest default now?

This file used to answer **no, and the reason is time** — that on the hardware
this project targets, "write me a small function" plausibly cost the better part
of an hour. That was the wrong answer, and it was wrong because it was a
projection rather than a measurement. On the real droplet the task takes **12
minutes**, which clears the 15-minute bar this section itself set.

So the time objection is answered. The default stays `false` anyway, and the
reason is now a different and more honest one: **consent and disk, not
viability.**

- It costs about **7 GB of images** on first start. A default that downloads
  that much is a default that fails on a small disk.
- It can **run anything on the machine** — installs, services, deletions —
  inside a sandbox that shares the host's docker daemon. That is the point of
  the tier and it is not something to inherit without choosing it.

Neither of those gets fixed by being faster, and neither is a reason to call the
tier unusable. It is usable on the hardware this project targets; it is opt-in
because of what it can do and what it costs to fetch, which is the same reason
`lca offline` is a command rather than a default.

What would still improve it, in order:

1. **A smaller first prompt.** ~15k tokens before the first output token is most
   of what a step costs, and most of that is OpenHands' own framing rather than
   the task. This is the one change that would make every step cheaper on every
   box.
2. **Images that are not 7 GB.**

Both are upstream of this project. Neither blocks anyone today: turn it on, run
`lca agent selftest`, and you get your own box's number in about a quarter of an
hour.

---

## The 15,000-token prompt: what it is, and what you can do about it

Every step of this tier reads about 15,000 tokens before the model writes one,
and that is most of what a task costs. This section is what recording the
agent's actual requests showed.

### It is one system message, and it is mostly the browser

The first request the sandbox sends, decomposed:

| | ~tokens | |
|---|---|---|
| whole request | 15,225 | |
| **system message** | **12,898** | **86% of it** |
| the user's task | 2,041 | |
| `tools` array | 0 | with `AGENT_NATIVE_TOOL_CALLING=false` the schemas are prose inside the system message |

And inside that system message, the biggest single block is **~5,985 tokens**
— 46% of it — documenting the **browser tool**: 46 mentions of "browser", 41 of
"tab", plus clicking, scrolling and screenshots. A coding agent on a private
CPU box never opens a browser.

### The knob for that exists, and OpenHands 1.8 ignores it

`agent_settings.tools` takes an explicit tool list, and it round-trips —
`POST` it, `GET` it back, and it is there:

```
[{"name":"TerminalTool","params":{}},{"name":"FileEditorTool","params":{}},…]
```

The sandbox then logs `Loaded 22 tools from spec` and sends a byte-identical
15,225-token prompt. Measured before and after: **0 tokens saved, 57 browser
mentions either way.** `filter_tools_regex` and `include_default_tools` exist on
the `Agent` schema and are not on the settings diff at all — posting
`filter_tools_regex` stores `null`.

Nothing this project can do closes that; it is upstream. It is written down here
so nobody spends another evening discovering the setting works and does nothing.

### What DOES help, and it is large

The 15,000 tokens are paid **once per conversation, not once per step.** That
system message is identical every time, and Ollama caches the prefix. One
conversation, two consecutive calls:

```
first call    13,430 tokens of prompt eval   543 s
next call        171 tokens of prompt eval     3.6 s
```

The cache lives with the **loaded model**. Same prompt twice with it resident:
**50.2 s, then 0.1 s.** So when `OLLAMA_KEEP_ALIVE` expires while you are
thinking, the next step pays all 15,000 again *and* a model load.

Two things follow, and both are yours to choose:

- **Stay in one conversation.** A new conversation re-pays the whole prompt. The
  second question you ask in a thread is dramatically cheaper than the first.
- **Set `OLLAMA_KEEP_ALIVE=-1` while you use this tier**, if you can spare the
  RAM — it keeps the model, and its cache, resident. `lca check` warns when the
  agent is on and this is finite, with the numbers above.

---

## Is the supervisor real? Yes, and here is exactly how far that goes

`lca agent watch` is what stops a run while you sleep. `tests/test-agent-watch.sh`
drives the real script against real containers, over a real `docker logs -f`
stream, and asserts on what it *did* — not on what it would have decided:

| limit | provoked by | result |
|---|---|---|
| wall clock | a container that says **nothing** | fires at 60s, container really stopped |
| stuck detector | one failure repeated with a new id each round | fires in 3s, signature collapsed to `ERROR build failed in /tmp/N after N retries` |
| step ceiling | an event endpoint whose count rises | fires at 3, and says it counted *events*, not log lines |
| `--dry-run` | the same world | reaches a verdict, stops nothing, says so |

It found a bug doing it: the watcher backgrounds `docker logs -f` followers, and
they outlived it holding its stdout open — so `lca agent watch | tee run.log`
never returned on a run that had already reached its verdict. Measured before
the fix: indefinite. After: 60s.

**One thing that harness does not prove**, and it is now closed. Its event
endpoint is a fixture, so the watcher's discovery, polling, verdict and stop are
real code on a real socket, but the counts are not OpenHands'. Run on the
droplet against a real agent:

```
==> Supervising the agent
[info] Step ceiling: 3   wall clock: 180 min   stuck after: 3 identical failures
[info] Steps come from the agent's event API (conversation f786c0e9...; 5 event(s)
       already recorded, and the ceiling counts what happens from here).
[warn] Stopping the agent: the step ceiling (AGENT_MAX_ITERATIONS) was reached
[info] Steps seen: 4 (events on the agent API) · failures seen: 0 · run time: 2 min
[ ok ] Agent stopped. Its workspace is intact in ~/.openhands
EXIT: 1
```

Four real OpenHands events in two minutes, ceiling of three, stopped. Every
limit in this tier has now fired against the thing it is meant to stop.

To repeat it on your own box:

```bash
sed -i 's/^AGENT_MAX_ITERATIONS=.*/AGENT_MAX_ITERATIONS=3/' .env \
  && lca agent start \
  && (lca agent selftest --keep >/tmp/lca-task.log 2>&1 &) \
  && sleep 90 && lca agent watch
```

Put `AGENT_MAX_ITERATIONS` back afterwards.

### If it sits at a number that never moves, this is why

The first attempt at that run did not fire, and the reason is worth knowing
because nothing announced it. An earlier `selftest --keep` had left a **second
sandbox alive**. The watcher attached to the *stale* conversation while the new
task stepped on a different one, so the count sat at 5 for as long as it was
left running — no error, no warning, just a number that never moved.

Two things changed because of that run:

- **The conversation is now chosen deterministically**, by the **newest running
  sandbox** rather than by whatever the listing happened to return first.
  `docker ps` orders by creation time and each conversation carries its
  `sandbox_id`, so the watcher attaches to the run you just started.
- **`watch` says when there was a choice to get wrong**, up front:

  ```
  [warn] More than one run is alive here — this machine has 2 running sandbox(es)
         and 2 conversation(s). This is watching the one belonging to the NEWEST
         sandbox (f786c0e9...). If that is not the run you meant, stop the others
         first: lca agent stop, then remove any leftover oh-agent-server-*
         containers.
  ```

It reports rather than resolves: two sandboxes may both be legitimate, and a
supervisor is not the thing that should decide which of your runs to kill.

### The follower that kept getting away

When the container outlived the watcher, exactly one `docker logs -f` was left
behind after every run. It no longer held the pipe open — that part was fixed
earlier — but a supervisor that leaks a process per run is still a supervisor
you have to clean up after.

Killing them one pid at a time could not close it, and the reason is a race that
sweep cannot win: killing a follower's parent first **reparents its child to
init**, so the survivor disappears from every pid the watcher recorded. What
does close it is that a reparented process **keeps its process group**. Measured,
outside docker, before any of this was relied on:

| | follower loop | its subshells | `docker logs -f` | the watcher |
|---|---|---|---|---|
| plain `&` | pgid 21127 | 21127 | 21127 | **21127** |
| under `set -m` | pgid 21929 | 21929 | 21929 | 21922 |

So the followers now run in a group of their own — `set -m`, a FIFO instead of
`< <(...)`, and one `kill -- -PGID` on the way out. The first row is why that
needed proving rather than assuming: without `set -m` the group kill would have
taken the watcher down with the followers, mid-report.

Measured in the same harness, on the run where the container is still up when
the watcher returns: **before, 1 survivor (reparented to init); after, 0**.
`tests/test-agent-watch.sh` counts them and fails if one comes back — and also
fails if the count is clean for the *wrong* reason, because the watcher says out
loud when it has fallen back to the old pid-by-pid sweep.
