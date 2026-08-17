# The agent's first prompt, measured

Every number in this file was produced by an exact tokenizer, not an estimate,
on the model this project actually runs the agent tier with. It is a
measurement log: numbers are written down as they are produced, in order, so
that a lost session costs the *work* and not the *findings*.

Measured 2026-08-17 on this box (4 vCPU, Ubuntu 24.04).

## Why an exact tokenizer was available, and where

Ollama does not expose a tokenizer. Its **runner does**: Ollama loads a model by
spawning `llama-server` on an ephemeral loopback port, and that server carries
the full `llama.cpp` HTTP API — including `/tokenize`, which returns the exact
token ids for a string under *the loaded model's own* tokenizer.

    $ ollama ps
    NAME                    ID            SIZE    PROCESSOR   CONTEXT
    qwen2.5-coder:3b-agent  94c6bce4b34c  2.7 GB  100% CPU    16384

    $ curl -s 127.0.0.1:42733/props | jq '{n_ctx: .default_generation_settings.n_ctx, model: .model_path}'
    { "n_ctx": 16384, "model": ".../blobs/sha256-4a188102020e9c9530b687fd6400f775c45e90a0d7baafe65bd0a36963fbb7ba" }

The port is ephemeral: it changes on every model load, and it went from 42733
to 43423 during this very session when the model idled out and was reloaded.
Do not hardcode it, and do not grep for it by name either — the runner does not
reliably show up as `ollama` in `ss -lntp`. Ask each loopback listener whether
it answers `/props` like llama.cpp; the one that does is the runner. `n_ctx`
coming back 16384 then confirms it is the `-agent` model's own process, so its
tokenizer is the one that will count the real prompt. Free, local, exact.

## The window

| | tokens |
|---|---|
| `AGENT_MODEL_CONTEXT`, the derived model's `num_ctx` | **16,384** |

Prompt and generation share it — but not evenly, and not the way this project
assumed. See "The window is not the window" below: a prompt may have half.

## Where the prompt comes from

The agent-server records what it was given as event 0 of the conversation, on
disk inside the runtime container:

    /workspace/conversations/<id>/events/event-00000-*.json

It has three parts that reach the model: `system_prompt.text`, the `tools`
array (26 tool schemas), and `dynamic_context.text`. The task the user typed is
a separate user message.

## Component sizes (characters, exact)

| component | chars |
|---|---|
| `system_prompt.text` | 14,387 |
| `dynamic_context.text` | 22,364 |
| `tools` | 26 schemas |

`dynamic_context` is **larger than the system prompt**, which is not what
docs/AGENT.md assumed when it recorded 15,492 tokens for "system prompt plus 22
tool definitions". Inside it, `<SKILLS>` runs from line 26 to line 256 — 231 of
its 279 lines — listing OpenHands' built-in skills (`release-notes`,
`iterate`, `linear`, PR creation for GitHub / GitLab / Bitbucket / Azure
DevOps). None of them can do anything on a private, self-hosted box with no
forge credentials.

## What Ollama itself counted

Not inferred. Ollama logged it, and it logged it as a warning because it could
not fit it:

    $ journalctl -u ollama | grep 'truncating input prompt'
    Aug 17 10:25:15 ... level=WARN source=llama_server.go:314
      msg="truncating input prompt" limit=8194 prompt=18353 keep=4 new=8194

**18,353 tokens.** The conversation that produced it is
`8cb3e1ebb7764014b9aed3c9586da068`, whose first LLM call was submitted at
14:25:15 UTC — the same second — so this is the agent's *first* request:
system prompt, dynamic context, 26 tool schemas, and the selftest's task.

## The decomposition

The three text blocks reach the model verbatim, so tokenizing each one gives
its exact contribution; tools and template scaffolding are then the remainder.

| part | tokens | share |
|---|---:|---:|
| tool schemas + chat template scaffolding | **10,280** | 56.0% |
| `dynamic_context` | 4,871 | 26.5% |
| `system_prompt` | 3,037 | 16.5% |
| **the task the user actually asked for** | **165** | **0.9%** |
| **total** | **18,353** | 100% |
| the window it has to fit in | 16,384 | — |
| **over by** | **1,969** | 12.0% of the window |

Inside `dynamic_context`:

| block | tokens | share of prompt |
|---|---:|---:|
| `SKILLS` | **4,232** | **23.1%** |
| `CUSTOM_SECRETS` | 395 | 2.2% |
| `REPO_CONTEXT` | 181 | 1.0% |
| `CURRENT_DATETIME` | 46 | 0.3% |
| `HOST` | 17 | 0.1% |

Inside `system_prompt`, the largest of sixteen sections are
`SECURITY_RISK_ASSESSMENT` 363, `SECURITY` 309, `PROBLEM_SOLVING_WORKFLOW` 295,
`VERSION_CONTROL` 272, `SELF_DOCUMENTATION` 253. None is individually large;
the whole file is 3,037.

**The task is 0.9% of the prompt.** Everything else is preamble, and 56% of it
is tool JSON.

### On the tool figure

10,280 is derived by subtraction, deliberately. Reconstructing the tool JSON
directly and tokenizing it gives 8,418 compact / 9,286 spaced — neither matches,
because Ollama re-serialises tool schemas through its own Go structs before
templating them, and that transformation is not reproducible from outside. The
subtraction does not depend on knowing it: the other three blocks are verbatim,
so whatever is left is tools plus scaffolding, exactly.

## The window is not the window: Ollama gives a prompt half of it

The warning does not say `limit=16384`. It says `limit=8194`, and that number
is not derived from `max_output_tokens` (2,048 here) or from anything this
project sets. Measured directly, by asking Ollama for a context it honours and
overflowing it on purpose:

| `num_ctx` requested | `num_predict` | `limit` Ollama used |
|---:|---:|---:|
| 512 | 1 | 258 |
| 1,024 | 200 | 514 |
| 16,384 | litellm's | 8,194 |

    limit = num_ctx / 2 + 2

Independent of `num_predict` — 1 and 200 give the same rule. Ollama 0.32.5,
`llama_server.go:314`. **A prompt may occupy at most half the context window.**

So the agent tier's real prompt budget at `num_ctx=16384` is **8,194 tokens**,
not 16,384. And `keep=4` means that when the prompt overflows, Ollama keeps the
first four tokens and then the *tail*: the role, the security policy, the
filesystem rules and most of the tool definitions are the part discarded. The
model is left holding the end of the tool list and the task.

This is measurable in the agent's own bookkeeping. Accumulated `prompt_tokens`
across the conversation went 425 → 8,619, so the big call was charged
**8,194** — exactly the limit, not the 18,353 that was sent. 10,159 tokens
were dropped on the floor, silently, and nothing in OpenHands reported it.

That reframes every previous failure in this tier. The runs that wrote outside
their working directory and reported success on code they never executed were
not ignoring their instructions. **They never received them.**

## Reproducing any of this

Nothing here needs a paid tokenizer, a library, or a second model. Four steps.

**1. Find the runner and confirm it is the right model.** The port is
ephemeral; never hardcode it.

    PORT=$(ss -lntp | awk '/ollama/ && !/11434/ {split($4,a,":"); print a[2]; exit}')
    curl -s 127.0.0.1:$PORT/props | jq '.default_generation_settings.n_ctx'

**2. Count tokens exactly.**

    ntok() { curl -s 127.0.0.1:$PORT/tokenize -H 'Content-Type: application/json' \
             -d "$(jq -Rs '{content:.}')" | jq '.tokens|length'; }
    ntok < some-file.txt

**3. Get the prompt the agent was actually given.** Event 0 of the conversation,
inside the runtime container:

    C=$(docker ps --format '{{.Names}}' | grep oh-agent-server)
    docker exec "$C" sh -c 'cat /workspace/conversations/*/events/event-00000-*.json' \
      | jq -r '.system_prompt.text'    # and .dynamic_context.text, and .tools

**4. Read what Ollama made of it.** This is the number that matters, and it is
only ever in the log:

    journalctl -u ollama | grep 'truncating input prompt'

The agent's own accounting is in the same conversation's event stream —
`.value.usage_to_metrics.agent.accumulated_token_usage.prompt_tokens` on the
`ConversationStateUpdateEvent`s — and differencing consecutive ones gives the
per-call charge, which is what proves the truncation rather than merely
suggesting it.

## The cut that fits

    18,353 − 4,232 (SKILLS) = 14,121 tokens

Against the *nominal* 16,384 window that clears it with 2,263 to spare, and no
other single cut does. Against the **real** 8,194 budget it does not come
close, and it is worth being blunt about that: cutting skills is necessary and
it is not sufficient. It removes 41% of the overflow. The prompt would still be
truncated, and still be truncated from the front.

Two things fix the rest, and they are not alternatives — the first is free:

1. **Raise `AGENT_MODEL_CONTEXT` to 32768.** The budget becomes 16,386, and
   14,121 fits with room. This is the honest fix and it costs RAM: the KV cache
   doubles, which is what this box does not have (see docs/AGENT.md on the
   3.4 GB allocation that made a 32768 run generate at 0.59 tok/s).
2. **Cut the tools too.** 56% of the prompt is tool JSON, and of the 26 tools,
   14 drive a headless browser and 5 open pull requests on GitHub, GitLab,
   Bitbucket and Azure DevOps. On this box none of the 19 can do anything.

Only both together put the prompt under 8,194 on the RAM this project targets.

### What the tools are worth

Tokenized per tool on the reconstruction, so these are shares rather than
absolute counts (the reconstruction under-counts the whole by ~18%):

| group | count | share of tool JSON | ≈ of the real 10,280 |
|---|---:|---:|---:|
| `browser_*` | 14 | 35.3% | ~3,630 |
| `create_*_pr` | 5 | 15.3% | ~1,570 |
| `invoke_skill` | 1 | 1.9% | ~195 |
| **removable here** | **20** | **52.5%** | **~5,394** |

`invoke_skill` joins them once the catalogue is gone: it is the tool whose only
purpose is to invoke a skill from a list that is now empty.

So the full arithmetic, if both cuts are made:

    18,353 − 4,232 (skills) − ~5,394 (20 dead tools) ≈ 8,727

Still ~500 over 8,194, closed by dropping `CUSTOM_SECRETS` (395) and the
`BROWSER_TOOLS` (163) and `PULL_REQUESTS` (139) sections of the system prompt,
which describe tools that would no longer exist.

## A correction, and how it was caught

`scripts/lib.sh` carried this reasoning next to `AGENT_MAX_OUTPUT_TOKENS`:

> 16384 - 8190 = 8194. The client reserved half the window for output it was
> never going to produce […] 2048 is generous for one reply from a coding agent
> and buys 6,142 more tokens of instruction.

The arithmetic works and the conclusion is wrong, because `16384/2 + 2` is
*also* 8194. Two theories, one observation, and nobody had varied the input
that separates them. Varying it:

| `num_ctx` | `num_predict` | `NumCtx−NumPredict` predicts | observed |
|---:|---:|---:|---:|
| 512 | 1 | 511 | **258** |
| 1,024 | 200 | 824 | **514** |

The reservation theory is out. And the product's own data had already said so:
the run measured here carried `max_output_tokens=2048` and was still cut to
8,194, where a 2,048-token reservation would have left 14,336.

`AGENT_MAX_OUTPUT_TOKENS` buys no instruction room at all. It is still worth
setting as what it claims to be — a cap on one reply — but the 6,142 tokens it
was believed to buy were never there.

The skills being dropped are OpenHands' built-in catalogue: `release-notes`,
`iterate`, `linear`, `code-review`, `datadog`, `discord`, `deno`,
`azure-devops`, `bitbucket`, and dozens more. On a private, self-hosted box
with no forge credentials and no network egress to any of those services, not
one of them can run.

