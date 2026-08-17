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

Prompt and generation share it, and a prompt may use all of it — but overshoot
it by a token and Ollama does not trim, it halves. See "Overflowing the window"
below.

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

## Overflowing the window does not cost you the overflow. It costs you half.

The warning does not say `limit=16384`. It says `limit=8194`, and the tempting
reading — that a prompt may only ever have half the window — is wrong. `limit`
is not the threshold at which Ollama truncates. It is the size it truncates
*down to*.

Measured, by overflowing contexts Ollama honours and then by watching a real
prompt that sits between the two candidate thresholds:

| `num_ctx` | prompt | truncated? | cut down to |
|---:|---:|:--|---:|
| 512 | 2,319 | yes | 258 |
| 1,024 | 3,519 | yes | 514 |
| 16,384 | 18,353 | yes | 8,194 |
| 16,384 | **13,975** | **no** | — |

That last row is the one that settles it, and it is not a synthetic probe — it
is this project's own agent after the cut below. 13,975 is comfortably above
8,194 and was processed **in full**, all 13,975 tokens of it. So:

    truncation fires when   prompt > num_ctx
    and when it fires       the prompt is cut to num_ctx / 2 + 2, keep = 4

Ollama 0.32.5, `llama_server.go:314`. The budget really is the whole 16,384.
What is brutal is the penalty: exceeding it by 1,969 tokens did not cost 1,969
tokens, it cost **10,159**, because Ollama does not trim to fit — it halves.

And `keep=4` says which half. The first four tokens survive and the rest of
what is kept is the *tail*, so the role, the security policy, the filesystem
rules and most of the tool definitions are precisely the part discarded. The
model is left holding the end of the tool list and the task.

The agent's own bookkeeping shows the charge. Accumulated `prompt_tokens` went
425 → 8,619 across the conversation, so the big call was billed **8,194** —
not the 18,353 that was sent. 10,159 tokens were dropped on the floor, and
nothing in OpenHands said a word about it.

That reframes every previous failure in this tier. The runs that wrote outside
their working directory and reported success on code they never executed were
not ignoring their instructions. **They never received them.**

## Reproducing any of this

Nothing here needs a paid tokenizer, a library, or a second model. Four steps.

**1. Find the runner and confirm it is the right model.** The port is
ephemeral; never hardcode it.

    for p in $(ss -lnt | awk '$4 ~ /^127\.0\.0\.1:/ {split($4,a,":"); print a[2]}'); do
      [ "$p" = 11434 ] && continue
      curl -sf -m 2 "127.0.0.1:$p/props" -o /dev/null && PORT=$p && break
    done
    curl -s "127.0.0.1:$PORT/props" | jq '.default_generation_settings.n_ctx'

Probe for `/props` rather than grepping for the name: the runner does not
reliably appear as `ollama` in `ss -lntp`, and answering `/props` is what
actually identifies it.

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
only ever in the log. Two lines to look for, because a prompt that *fits*
produces no warning at all — which is exactly the state to confirm after a cut:

    journalctl -u ollama | grep 'truncating input prompt'   # over the window
    journalctl -u ollama -o cat | grep 'new prompt, n_ctx_slot'   # every prompt

The second prints `n_ctx_slot = 16384 … task.n_tokens = 13975` whether or not
truncation happened, so it is the one to trust. Silence from the first is the
result you want.

The agent's own accounting is in the same conversation's event stream —
`.value.usage_to_metrics.agent.accumulated_token_usage.prompt_tokens` on the
`ConversationStateUpdateEvent`s — and differencing consecutive ones gives the
per-call charge, which is what proves the truncation rather than merely
suggesting it.

## The cut that fits

    18,353 − 4,232 (SKILLS) = 14,121 tokens

Under 16,384, with 2,263 to spare — and no other single cut does it. Measured
after the fact the real figure came out slightly better still, 13,975, because
removing the catalogue also removed the tool that reads it.

This is the first configuration in this project's history where the agent's
prompt fits its window.

There is still headroom worth taking, and it is worth knowing where it is,
because the margin is 2,409 tokens and a user's `config/CONVENTIONS.md` lands
in `REPO_CONTEXT` inside it. Tool JSON is now **72.5%** of the prompt — 10,134
of 13,975, a larger share than before precisely because everything around it
got smaller — and of the 25 tools, 14 drive a headless browser and 5 open pull
requests on GitHub, GitLab, Bitbucket and Azure DevOps. On this box none of
those 19 can do anything.

### What the tools are worth

Tokenized per tool on the reconstruction, so these are shares rather than
absolute counts (the reconstruction under-counts the whole by ~18%):

| group | count | share of tool JSON | ≈ of the real 10,280 |
|---|---:|---:|---:|
| `browser_*` | 14 | 35.3% | ~3,630 |
| `create_*_pr` | 5 | 15.3% | ~1,570 |
| `invoke_skill` | 1 | 1.9% | ~195 |
| **removable here** | **20** | **52.5%** | **~5,394** |

`invoke_skill` has already gone — OpenHands dropped it by itself when the
catalogue emptied, which is where ~150 of the 4,378 actually saved came from.
The remaining 19 are still being sent.

Dropping the browser and forge tools as well would take the prompt to roughly

    13,975 − ~5,200 ≈ 8,800

which is not needed to fit the window and would be worth doing anyway: it is
the difference between an agent that reads its instructions in 11 minutes and
one that reads them in 7. `browser_tool_set` is one entry in the agent spec's
`tools` list, so the lever exists; it was left alone here because the measured
task was the skills cut and one change at a time is how this was kept honest.

## After the cut, measured the same way

`AGENT_EXTENSIONS_REF` set to a ref that does not resolve, agent restarted, the
*same* task submitted (`hello.py`, in `/workspace/project`), conversation
`0f38875470b34832ababe26ab3b95a06`.

First, that the cut reached where it had to. Inside the new sandbox:

    $ docker inspect oh-agent-server-... | grep EXTENSIONS_REF
    EXTENSIONS_REF=lca-public-skills-disabled
    $ ls /home/openhands/.openhands/cache/skills/public-skills
    (no such directory — the clone never happened)

Then the prompt itself. Event 0 fell from 65,098 bytes to 44,766.

| | before | after | Δ |
|---|---:|---:|---:|
| `system_prompt` | 3,037 | 3,037 | — |
| `dynamic_context` | 4,871 | **639** | **−4,232** |
| ⤷ `SKILLS` | 4,232 | *gone* | −4,232 |
| ⤷ `CUSTOM_SECRETS` | 395 | 395 | — |
| ⤷ `REPO_CONTEXT` | 181 | 181 | — |
| ⤷ `CURRENT_DATETIME` | 46 | 46 | — |
| ⤷ `HOST` | 17 | 17 | — |
| tool count | 26 | **25** | −1 |

Exactly the 4,232 predicted, and nothing else moved — the system prompt is
untouched to the token, which is what makes the comparison worth anything.

**One saving was not predicted.** The tool count fell to 25: OpenHands drops
`invoke_skill` on its own once the catalogue is empty, because a tool whose
only job is to invoke a skill has nothing left to invoke. That is ~156 tokens
nobody had to ask for.

### And what Ollama made of it

The measurement that decides it, in Ollama's own words:

    slot operator(): id 0 | task 4 | new prompt, n_ctx_slot = 16384,
                                     n_keep = 4, task.n_tokens = 13975

**13,975 tokens, and no truncation warning at all** — not in that run, not
anywhere in the log since. It then processed all 13,975 of them, straight
through, `progress = 0.07 … 0.51 …` at ~20 tok/s.

| | before | after |
|---|---:|---:|
| prompt Ollama was sent | 18,353 | **13,975** |
| prompt the model actually read | 8,194 | **13,975** |
| thrown away, unreported | 10,159 | **0** |

The middle row is the point. The saving on the wire is 4,378 tokens; the saving
in *instructions the model receives* is 5,781, because the tokens that were
being discarded were the ones this project had written.

For the first time in this tier's history the agent is reading its whole
prompt: its role, its security policy, its filesystem rules, the
working-directory rule that two failed droplet runs were blamed on, and all 25
tool definitions.

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

`AGENT_MAX_OUTPUT_TOKENS` buys no instruction room at all. Nothing is reserved
from the prompt for output: the threshold is `num_ctx` whatever the client
asks for, and `num_ctx/2 + 2` is where an over-long prompt lands, not where it
is allowed to start. The setting is still worth what it claims to be — a cap on
one reply — but the 6,142 tokens it was believed to buy were never there.

Two wrong readings of one warning line, in one day, an hour apart: first that
the reservation explained it, then that a prompt only ever gets half the
window. Both fitted `limit=8194` perfectly. What separated them was varying an
input rather than admiring a coincidence — `num_predict` for the first, and a
prompt that lands *between* the two candidate thresholds for the second.

The skills being dropped are OpenHands' built-in catalogue: `release-notes`,
`iterate`, `linear`, `code-review`, `datadog`, `discord`, `deno`,
`azure-devops`, `bitbucket`, and dozens more. On a private, self-hosted box
with no forge credentials and no network egress to any of those services, not
one of them can run.

