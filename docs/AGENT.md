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
sudo lca apply        # creates the container and closes its port in the guard
lca agent start
lca agent url         # the address to open on your phone, over Tailscale
```

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

## Where it is weak here, honestly

**The model is smaller than this agent wants.** OpenHands' own local-LLM guide
asks for a context window of at least ~22k tokens and suggests
`OLLAMA_CONTEXT_LENGTH=32768`. This project's RAM ladder gives **8192** on a
16 GiB box, because that is what leaves room for the model itself. The agent
will therefore lose the thread on long tasks sooner than its documentation
assumes. Nothing here hides that: if you have the RAM, raising
`OLLAMA_CONTEXT_LENGTH` is the single change that helps it most.

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

**What it cannot see.** `watch` reads the container's log and counts steps and
failures by pattern. Those patterns (`AGENT_STEP_PATTERN`, `AGENT_FAIL_PATTERN`)
are a guess about somebody else's output format, not a documented interface. If
a run ends with **no** line having matched the step pattern, `watch` says so and
exits non-zero rather than reporting a clean run — a limit that silently never
fires is worse than no limit, because it was believed.

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

1. **It is published on loopback only** — `127.0.0.1:AGENT_PORT`, never
   `0.0.0.0`. Reachable from your phone through Tailscale, not from the
   internet, even in the moments when the guard is not loaded.
2. **The inbound guard covers its port**, by exactly the rule the chat app
   taught this project: `ENABLE_AGENT` is a statement of intent, a listening
   socket is a fact. A container still running after you set `ENABLE_AGENT=false`
   is still listed and still guarded — turning a feature off in `.env` must
   never make this box more exposed.

`sudo lca status` shows what the guard covers. `lca check` reports the agent's
port among the rest.

## What it does not do

It does not replace `lca`. For a change you can describe in a sentence, aider
in your project directory is faster, cheaper and easier to review — and `git
diff HEAD~1` still works exactly the same way afterwards. Reach for the agent
when the work is genuinely multi-step and you want to hand it over.
