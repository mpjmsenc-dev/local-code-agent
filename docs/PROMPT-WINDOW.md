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

The port is ephemeral and changes on every model load — find it with
`ss -lntp | grep ollama` rather than hardcoding it. `n_ctx: 16384` confirms
this runner *is* the `-agent` model's process, so its tokenizer is the one that
will count the real prompt. It is free, it is local, and it is exact.

## The window

| | tokens |
|---|---|
| `AGENT_MODEL_CONTEXT` (scripts/lib.sh:533), the derived model's `num_ctx` | **16,384** |

This is the whole window: prompt and generation share it.

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

The skills being dropped are OpenHands' built-in catalogue: `release-notes`,
`iterate`, `linear`, `code-review`, `datadog`, `discord`, `deno`,
`azure-devops`, `bitbucket`, and dozens more. On a private, self-hosted box
with no forge credentials and no network egress to any of those services, not
one of them can run.

