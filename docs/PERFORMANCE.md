# Performance — making it faster, honestly

Local inference on a CPU is a reading pace, not instant. This page explains what
actually controls the speed, in the order that matters, so you can spend effort
where it pays.

**If it was fast and then suddenly was not**, read
[Why it randomly gets slow](#why-it-randomly-gets-slow-the-two-models-evict-each-other)
first — that one has a cause most people never guess, and it is not your hardware.

## First: measure, don't guess

```bash
lca speed
```

That is the whole first step. It makes two real requests — one that generates,
one that only reads — takes a minute or two, and reads the timings out of
Ollama's own counters. It tells you: how fast the model **generates**, how fast
it **reads** input, **what one code edit therefore costs**, whether you are on
the CPU or the GPU, how much the first message after an idle period costs, and
what is actually limiting you. It remembers the last run, so after any change
you can see whether it helped.

The `one code edit` line is the one to read first if you came here because
aider felt slow. Generation speed is the number everybody quotes and it is the
smaller half: aider sends about 2,800 tokens and gets about 113 back, so most
of the wait is Ollama *reading* — its system prompt, the repo map, the
conventions file, the history. None of that is your file, and all of it is
re-read on every request.

That line is a **floor**, and it is worth knowing by how much. It prices the
model request and nothing else, but a whole `lca` run also starts Python, walks
the repo to build the map, and — because auto-commit is on by default — spends
a second request writing the commit message. Three one-shot `lca --message`
edits measured end to end on a CPU-only box slower than the reference one below
(`qwen2.5-coder:7b` at ~5.3 tokens/second there, not 6.1), against a model
already resident in RAM — so treat the shape of these numbers as the lesson,
not their absolute size:

| Edit | Tokens | Wall clock |
|---|---|---|
| create a small file | 2.7k sent, 163 back | 327s |
| the same, `AIDER_NO_AUTO_COMMIT=true` | 2.7k sent, 163 back | 292s |
| add a function to it | 2.9k sent, 286 back | 408s |

So budget **more than the `one code edit` figure** for a real one-shot run.
Deliberately not a multiplier: those three runs came in at 1.5–1.8× what the
measured rates predict, but the rates themselves move with what else the
machine is doing (see below), and a ratio between two different conditions is
not a property of your box. Read the two 2.7k rows together: they sent and received the same token
counts, so the 35 seconds between them is the extra request aider makes to
write the commit message, and nothing else. That is usually
worth paying — it is the safety net that makes an unwanted edit a `git revert`
away — but it is not free, and `AIDER_NO_AUTO_COMMIT=true` turns it off.

One more reason the estimate reads low: generation slows as the context fills,
because every new token is produced against everything already in the window.
Measured in a single run on the same resident model, so no reload is hiding in
these numbers — it is the ratio between the rows that carries, not the absolute
rates, which move with whatever else the machine is doing:

| Prompt already in context | Generation |
|---|---|
| 60 tokens | 4.30 tokens/second |
| 756 tokens | 4.03 tokens/second |
| 1,596 tokens | 3.75 tokens/second |
| 2,316 tokens | **2.48 tokens/second** |

`lca speed` measures generation against a short prompt, so the rate it quotes
is the top row while a real edit writes its reply down at the bottom one.

Reading speed does *not* fall off with prompt size — but it does move a lot
with how busy the machine is, which is worth knowing before you compare two
runs. The same box, the same three prompt sizes, measured in a busy window and
an idle one:

| Prompt | Reading, box busy | Reading, box idle |
|---|---|---|
| ~600 tokens | 20.0 tokens/second | 55.9 tokens/second |
| ~2,000 tokens | 19.7 tokens/second | 48.8 tokens/second |
| ~2,300 tokens | 18.8 tokens/second | 49.4 tokens/second |

Flat across the column, roughly 2.5× apart between them. So `lca speed` run on
an idle box predicts an edit that will not be that fast once aider is actually
working, and two `lca speed` runs are only comparable if the machine was
equally quiet for both — which is what the `vs last run` line cannot know.

On a CPU-only x86_64 box with 16 GiB RAM, `qwen2.5-coder:7b` measures **6.1
tokens/second** (the measured table further down has the rest). That is the
baseline to compare against; if you are far below it, something else is wrong
and `lca speed` will usually say what.

It also reports **memory traffic** in GB/s. On CPU that is the number that
really matters: generating one token means reading the entire model out of RAM,
so speed is set by memory bandwidth, not by how many cores you have. A 7B model
at ~4 GB per pass and 23 GB/s of bandwidth *predicts* ~5.5 tokens/second, which
is within noise of the 6.1 measured — that agreement is the story. It is also
comparable across model sizes in a way that tokens/second is not.

`./check-system.sh` and `lca test` report CPU vs GPU placement too, as part of
their wider checks.

## What this hardware is actually good for — three real tasks, graded

Measured 2026-10-02 on the ESXi VM: Xeon E5-2680 v2 (AVX, no AVX2), 16 vCPUs
as 2 × 8, 62 GiB, no GPU, Ollama under `numactl --interleave=all`. Each task
went through `lca` (aider, default settings: diff edit format, auto-commits,
the conventions file) in a fresh git repo with `--message`, and was graded by
hidden unit tests the model never saw. A failed try got one retry, with the
failing test output pasted back the way a person would. Times are wall clock
for the whole `lca` run: reading, writing, aider's lint round and the commit
message. The harness is in `~/projects/lca-eval` on that VM.

| Task | 7b | **14b** | 32b |
|---|---|---|---|
| **A.** Write one function from a spec, plus its tests (`parse_duration("1h30m")`, 11 invalid forms) | ✗ after 2 tries, 61 min | **✓ 1st try, 16 min** (two runs: 978 s, 975 s) | ✓ 1st try, 35 min |
| **B.** Find and fix a planted bug in a 3-module package, tests untouched (`>` vs `>=` at a discount threshold) | ✓ 2nd try, 9 min | **✓ 1st try, 9 min** | ✓ 1st try, 20 min |
| **C.** One feature across 3 files plus its tests (sales tax: model field, billing, report line) | ✗ after 2 tries, 28 min | **✓ 1st try, 36 min** | ✓ 1st try, 63 min |

How the failures failed, because that is what you would be debugging:

- **7b, task A:** the first try never stopped writing. It read the 3.8k-token
  prompt in 2.6 minutes and then generated about 3,900 tokens, against the 600
  a correct answer takes, until aider's 600 s request timeout. aider retried,
  and the same thing happened three times. The retry wrote a stub
  (`pass`) and then tried to edit the grader's test file, which it had only
  seen named in the pasted output. Its SEARCH/REPLACE blocks did not match.
- **7b, task B:** the first try changed the rounding instead of the comparison.
  The second fixed `>` to `>=`, and also swapped integer `// 10` for float
  arithmetic, so the discount now comes back as `100.0`. The tests pass
  because `100.0 == 100`. That is an unrequested regression a review would
  have to catch.
- **7b, task C:** the code was right, but it did not update the existing report
  test it was told to update, so its own suite failed. The retry produced
  three edits in a row that aider rejected as malformed.
- **14b and 32b** each needed one internal lint round on C: the first edit used
  `tax()` in `report.py` without importing it, aider's linter caught it, and the
  same request fixed it. Neither needed a retry anywhere.

**So, on this box:**

- **Good for: well-specified, single-sitting changes with 14b.** One function
  from a precise spec, a bug a failing test points at, a change across a few
  small files. It gets them right the first time, and you wait 10–35 minutes,
  with about 4 of each 16 spent just reading aider's prompt. Hand it the task,
  do something else, and review the commit.
- **Not good for: interactive pairing.** Nothing here comes back in seconds.
  A one-line fix is 9 minutes.
- **Not good for: large files or wide changes.** Every request re-reads the
  whole chat: task C's two requests sent 10k tokens for a 17-line diff. Reading
  is ~13 tok/s, so a 30k-token context is 40 minutes before the first word.
- **32b is not better on work this size, only slower.** Same results, every
  task, at about twice the time, and its first agent step outruns the agent's
  30-minute request timeout. It may still earn its keep on harder problems than
  these. That has not been measured, so it stays on disk for
  `lca ask -m qwen2.5-coder:32b` and is not the default.
- **The 7b is not a cheaper 14b.** It failed two of three, and its failures are
  the expensive kind: an hour of runaway generation, a stub, a quiet float
  regression. Use it only where a fast wrong answer is acceptable.
- **The agent tier works, slowly.** `lca agent selftest` (one file, six links)
  passes in 24 minutes on 14b and 50 on 32b.

Three tasks and one run each (two for 14b on A) is a small sample, and every
task here was well specified. The ranking was the same on every task, though,
and the gaps are big: 0/3 vs 3/3 on first tries, and 2× in time.

## qwen3-coder-next (80B MoE, 3B active) — measured, and it replaces the 32b

qwen3-coder-next:q4_K_M (Ollama's tag; 51.7 GB on disk, 51.5 GB resident)
was measured on the same VM and harness, alone in RAM, on 2026-10-04.

**The verdict, against the rule fixed beforehand** (it replaces the 32b as
the agent model if it passes at least as many graded tasks and is faster, or
passes D): it passes A, B and C, as the 32b does, in 62 minutes against the
32b's 117, and its agent self-test takes 8–9 minutes against 50. **It is the
agent model now, and the project lead.** It fails D, like every model so far.

### Speed (alone, 16 vCPUs, nothing swapping)

| | reading | writing | resident | load (page cache cold) |
|---|---|---|---|---|
| qwen2.5-coder:14b | 13.2 tok/s | 4.4 tok/s | 12.5 GB | 20–25 s |
| qwen2.5-coder:32b | 5.6 tok/s | 2.0 tok/s | 24.6 GB | ~42 s |
| qwen3.6:35b-a3b | 40.0 tok/s | 4.3–5.5 tok/s | 22.3 GB | 31 s |
| **qwen3-coder-next** | **32.9 tok/s** | **7.4 tok/s** | 51.5 GB | ~175 s |

Writing is the fastest measured here, 3.7 times the 32b's. Ollama 0.34 runs
llama.cpp's own llama-server underneath, and these numbers are not poor, so a
separate llama.cpp build was not tried.

**Memory, and the measurement rule it forced.** It fits only alone: with it
resident, 11–12 GB are left. Its load copies 51 GB into the server's memory
while the same file fills the page cache, and that pushed about 1.2 GB of
other processes into swap at every load, at `vm.swappiness` 60 and still at
1. So every number here was taken with the model already loaded, the page
cache dropped and swap emptied, under a vmstat guard that rejects any run
with a single page swapped in or out. Two `lca speed` runs taken before that
rule (7.2–7.4 and 31.9–33.3 tok/s) agreed with the clean one, but they are
not the ones quoted.

**And a product bug it exposed.** aider sends Ollama `num_ctx = prompt × 1.25
+ 8192` with every request unless told otherwise, and each new value reloads
the model. On the 14b that was ~20 s a reload and nobody noticed; on this
model it was four reloads of ~3 minutes in one graded task, each with its
burst of swap. `lca` now pins aider's window to the one it budgets for
(run-agent.sh, `aider/extra_params`). The graded runs below are with the pin.

### The graded tasks

| Task | 14b | 32b | qwen3.6 | **qwen3-coder-next** |
|---|---|---|---|---|
| A | ✓ 1st try, 16 min | ✓ 1st try, 35 min | ✓ 2nd try, 53 min | ✓ 2nd try, 47 min |
| B | ✓ 1st try, 9 min | ✓ 1st try, 20 min | ✓ 1st try, 16 min | ✓ 1st try, **4 min** |
| C | ✓ 1st try, 36 min | ✓ 1st try, 63 min | ✓ 1st try, 23 min | ✓ 1st try, **12 min** |
| D | ✗ 59 min | ✗ 95 min | ✗ 75 min | ✗ 34 min |

On A its first answer was right except for one of its own new tests
("invalid characters" accepted); the retry wrote 9.4k tokens to fix it,
which is most of the 47 minutes: corrected, it gets verbose. On D its first
try made the drift every model makes (Jan 31, Feb 29, then Mar 29 for ever)
and a float interval crashed instead of raising ValueError; the second fixed
the drift and broke the proration and the quarterly dates.

### The agent self-test, both tool-call channels

| `lca agent selftest` | native tool calls on | native tool calls off |
|---|---|---|
| qwen3-coder-next at 32768 | **pass, 8 m 44 s** (file after 8 min) | **pass, 8 m 55 s** (file after 8 min) |

The first model here for which both channels work. The agent runs with
native calls on: same speed, and no text-format call markup that can leak
into files, which is what the 2.5 models did.

## qwen3.6:35b-a3b against the 2.5 models — measured, and the verdict

qwen3.6:35b-a3b (April 2026, mixture-of-experts: 35.5B parameters in all, about
3B active per token) was measured on the same VM and harness as the table above,
one model at a time with nothing else loaded. The vendor reports 73.4 on
SWE-bench Verified on its own scaffold; nothing here relies on that number.

**The verdict, against criteria fixed before any run:** qwen3.6 would replace
the 14b if it passed task D, passed the agent self-test, and was at least as
fast as the 14b. It passed the self-test and nothing else. It failed task D at
Q4_K_M and at q8_0, and on the aider tasks it was slower. **The 14b stays the
default.** That is a statement about these criteria on this CPU, not a general
ranking: on the agent self-test qwen3.6 was the fastest model measured here
(see below), because it is the first one whose native tool calls work.

### Speed and memory (each alone, 16 vCPUs, 16384 context)

| | reading | writing | resident (`ollama ps`) |
|---|---|---|---|
| qwen2.5-coder:14b | 13.2–13.3 tok/s | 4.3–4.5 tok/s | 12.5 GB |
| qwen2.5-coder:32b | 5.6 tok/s | 2.0 tok/s | 24.6 GB (28.9 GB as the agent model at 32768) |
| **qwen3.6:35b-a3b** (Q4_K_M) | **40.0 tok/s** | 4.3 tok/s (`lca speed`), 5.5 tok/s over a 1,058-token answer | 22.3 GB |
| qwen3.6:35b-a3b-q8_0 | — | — | 37.7 GB |

Reading follows the active parameters, so it is three times the 14b. Writing
does not: it stays at the 14b's pace. A first load took 31 s from page cache.

### Thinking: off, or nothing finishes

qwen3.6 thinks by default. With thinking on, one function plus its tests used
all 6,000 tokens of its budget thinking (21,465 characters) and never started
the answer: **20 minutes, no code**. With thinking off, the same prompt took
194 s. Off is `think:false` on `/api/chat`, and `reasoning_effort: "none"`
through Ollama's `/v1` and through litellm (aider): with it unset, a one-word
reply cost 143 tokens and 29 s; with `none`, 2 tokens and 2 s. Every graded
run below is with thinking off.

Off is not quiet, though. With thinking off, qwen3.6 reasons in the answer
itself ("Let's design… Wait, what about…"): 8.0k tokens for task A, against
about 600 for a correct answer. That is why its aider times below lose most of
what its reading speed wins.

### Tool calling: the first model here whose native calls work

Asked through `/v1/chat/completions` with tools, the way OpenHands asks,
qwen3.6 returned `finish_reason: tool_calls` with a well-formed `file_editor`
create. qwen2.5-coder never filled `tool_calls` at 3b or 7b (docs/AGENT.md).
With thinking left on, it still called the tool, after 528 tokens of
reasoning.

### The graded tasks

Same harness as above, plus a fourth task. Task D is harder on purpose. It
moves subscriptions from 30-day to calendar-month billing across three modules
(the model's fields, the schedule and the invoices), with tests. It has two
traps: a Jan 31 start must bill Feb 29 and then come back to Mar 31, and the
proration rounds half up, which Python's `round()` does not. The hidden grader
was checked both ways first: a reference solution passes all 12 of its tests,
and the untouched seed fails all 12.

| Task | 14b | 32b | qwen3.6 (Q4_K_M) | qwen3.6 q8_0 |
|---|---|---|---|---|
| A | ✓ 1st try, 16 min | ✓ 1st try, 35 min | ✓ 2nd try, 53 min | — |
| B | ✓ 1st try, 9 min | ✓ 1st try, 20 min | ✓ 1st try, 16 min | — |
| C | ✓ 1st try, 36 min | ✓ 1st try, 63 min | ✓ 1st try, 23 min | — |
| **D** | ✗ after 2 tries, 59 min | ✗ after 2 tries, 95 min | ✗ after 2 tries, 75 min | ✗ after 2 tries, 66 min |

The 14b and 32b A–C results are the earlier runs on the same day, same
harness. Two harness changes came with this round, and both are neutral. aider
now gets a 3600 s request timeout instead of litellm's 600 s, because
qwen3.6's long replies were thrown away and retried; the 2.5 runs never hit it.
And thinking models run with `reasoning_effort` none.

How D failed, which is the same story four times:

- **All four stepped from the previous billing date instead of from the
  start**, so a Jan 31 subscription bills Feb 29 and then Mar 29 for ever.
- **qwen3.6, both quantisations:** no check on `interval_months`, so an
  interval of 0 returns the same date for ever and the grader timed out. The
  first Q4 try never added the two fields at all. Neither version's tests
  touched the new fields.
- **14b:** the drift, a cancelled-on-a-billing-date invoice charged 0, and a
  float interval crashing instead of raising `ValueError`.
- **32b:** the drift, an "adjustment" for short months that steps the date
  backwards (another infinite loop), and `dateutil`, which is not in the
  standard library.

On A, qwen3.6's first try accepted an empty string. Its own tests would have
caught that, but it did not run them.

### The agent self-test

`lca agent selftest` with qwen3.6:35b-a3b-agent at 16384, native tool calling
on, `reasoning_effort` none: **passed, the file written after 10 minutes**,
10.6 min end to end, against 24 for the 14b and 50 for the 32b. It found one
bug in the self-test itself. Its tool-call probe allowed 64 tokens and did not
turn thinking off, so the model spent them thinking and returned no call: a
false FAIL. The probe now sends `reasoning_effort` none, and `agent.sh` stores
`none` in the agent's settings, where OpenHands defaults to `high`.

(Run on this VM without passwordless sudo. The self-test's own `sudo docker`
calls went through a stand-in that runs `docker` only, which this account may
do as a docker-group member, and refuses everything else. The agent's settings
were switched for the run through the app's API and restored afterwards.)

### Two models resident: the 14b for chat, the 32b for the agent

Project mode's `answerer` and a pinned `AGENT_MODEL` both want two models
loaded at once. With `AGENT_MODEL=qwen2.5-coder:32b` and `sudo lca apply`,
the server runs with `OLLAMA_MAX_LOADED_MODELS=2` (read back from its
environment), and both stay resident: qwen2.5-coder:32b-agent at 32768 is
28.9 GB and the 14b at 16384 is 12.5 GB, **41.8 GB used of 64.4, 22.6 GB
still available**, during a live project run. `ollama_two_models_fit` gives
the second slot on this box (63 − 9.4 − 20.2 = 33.4 GB of weights headroom,
against the 16 it requires).

### What project mode costs on the 32b

Every step is a fresh conversation, and every fresh conversation starts by
reading the agent's own prompt, about 16k tokens. Ollama's prompt cache did
not carry it from one conversation to the next. At 5.6 tok/s that first turn
took **50–51 minutes, every step**, and after it the turns were 1–5 minutes
each. Planning a 3-step toy took 75–80 minutes; each of its steps took about
an hour end to end. Reading speed decides this far more than writing does:
the same first turn would be about 18 minutes on the 14b, and about 7 on
qwen3.6 at 40 tok/s.

## The one change that matters most: a GPU

Nothing else is close. A model that fits entirely in VRAM runs roughly an order
of magnitude faster than the same model on CPU — the difference between reading
pace and a response that feels immediate.

| Situation | What to expect |
|---|---|
| CPU only (a DigitalOcean Basic droplet) | a few tokens/second; usable, deliberate |
| GPU, model fits in VRAM (`100% GPU`) | tens of tokens/second |
| GPU, model too big (`38%/62% CPU/GPU`) | barely better than CPU — the CPU part dominates |

Your CPU differs from the box the 6.1 tokens/second above was measured on, so
treat it as a rough baseline: measuring much *less* than that usually means
something else is wrong — swap, a too-large model, or a busy machine.

That last row is the trap. A partially-offloaded model is **not** "most of the
speed". If you have a GPU, prefer a model that fits its VRAM completely:

| VRAM | Fits comfortably at q4 |
|---|---|
| 8 GB | 7–8B |
| 12 GB | 13–14B |
| 24 GB (e.g. RTX 3090) | 14B easily; 32B is tight but usually fits |

You do **not** need a GPU for this stack to work — it is designed around CPU
inference and auto-tune picks a model your RAM can actually run. A GPU is a
comfort upgrade, not a requirement.

## If you are on CPU

In descending order of impact:

**1. Use a smaller model.** This is the biggest CPU-side lever by far. Speed
scales roughly with parameter count, because generating a token means reading
the whole model out of RAM. Measured on the same CPU-only x86_64 box:

| Model | Measured |
|---|---|
| `qwen2.5-coder:3b` | **12.3 tokens/second** |
| `qwen2.5-coder:7b` | **6.1 tokens/second** |

Almost exactly 2× for 2.3× the parameters — so a 3B model is roughly 4–5× faster
than a 14B one. For short edits and questions the smaller model is often good
enough, and it still answers as *your* assistant: `qwen2.5-coder:3b` follows the
system prompt correctly, answering "how do I take a backup?" with `lca backup`.

Try both before committing to one — no config change, no re-pull:

```bash
lca speed -m qwen2.5-coder:3b
lca speed -m qwen2.5-coder:7b
lca ask -m qwen2.5-coder:3b "explain this error: ..."
```

```bash
lca model --list-recommended           # what fits this machine
lca model qwen2.5-coder:3b              # pin a smaller one
```

**2. Keep the context small.** Every token in the prompt is work. `run-agent.sh`
already sizes aider's repo map to your window, but you control the rest:

- In aider, `/clear` drops old history, and `/drop` removes files you are done
  with. A long session gets slower as history grows.
- Add specific files rather than whole directories.
- `OLLAMA_CONTEXT_LENGTH` in `.env` caps the window. Bigger is not better on CPU:
  it costs memory and time whether or not you use it.

**3. Keep the model warm.** The first request after idle pays the load time
(seconds to a minute). `OLLAMA_KEEP_ALIVE` (default `30m`) controls how long it
stays resident. Raise it if you work in bursts and have RAM to spare; lower it
if the box is doing other things.

**4. More cores help, more RAM does not.** Ollama uses every core automatically —
nothing to configure. Extra RAM beyond what the model needs does not make
inference faster; it only lets auto-tune choose a *bigger* (slower) model on the
next boot. If you resized for RAM and it got slower, that is why.

## Why it randomly gets slow: the two models evict each other

This is the one people experience as *"it was fine, then it randomly got
slow"*, and it is not the hardware.

With `ENABLE_AGENT=true` this stack runs **two** models, not one:

| | model | window | used by |
|---|---|---|---|
| 1 | `MODEL_NAME` | `OLLAMA_CONTEXT_LENGTH` (4096 on the 3b rung) | the chat app, aider |
| 2 | `<model>-agent` | `AGENT_MODEL_CONTEXT` (16384) | the agent tier |

They are separate models to Ollama, with separate KV caches. **RAM is not the
problem** — `OLLAMA_MAX_LOADED_MODELS=1` means only one is ever resident, so the
peak is the larger of the two rather than their sum (2.7 GB on the 3b rung, not
4.9 GB). The ladder below was derived for one model and one model is still what
is loaded at any instant.

**Eviction is the problem.** Every switch between surfaces unloads one model and
loads the other, and the prompt's prefix cache goes with it. Measured on this
project's own agent prompt:

| | first call, cold | later call, warm |
|---|---|---|
| the agent's prompt (18,353 when this was measured; 13,796 since the skills cut) | **543 s** | **3.6 s** |

So **one chat message in the middle of an agent session** makes that session's
next step pay the cold price again — a step that took four seconds now takes
nine minutes, for no visible reason.

What to do about it:

- **Use them in blocks**, not alternating. Finish with the chat, then work with
  the agent.
- **Or make them one model.** Ollama decides "is this the same model?" by
  weights *and* window. When `OLLAMA_CONTEXT_LENGTH` equals
  `AGENT_MODEL_CONTEXT` (the ≥24 GiB rungs: both 16384), `<model>` and
  `<model>-agent` share one runner, and nothing is evicted at all. Measured on
  the 64 GB ESXi VM with 14b, a ~5.9k-token agent prompt, then a chat message,
  then the agent prompt again:

  | | agent prompt, warm | chat message | agent prompt, after the chat |
  |---|---|---|---|
  | both at 16384 | 1.8 s | 1.5 s, no load | **1.9 s** |
  | agent at 32768 | 1.8 s | 3.7 s + 21.6 s load | **515.5 s + 26.9 s load** |

  The agent's real prompt is 13.2k tokens, so on that box one chat message costs
  the next agent step about 22 minutes once the two windows differ. Raising
  only the agent's window is therefore not free even where RAM is plentiful:
  see "Does a bigger agent window pay?" below.
- **`OLLAMA_KEEP_ALIVE` does not help here.** It controls the idle timer, and
  this eviction is the other model *arriving*, not the timer expiring.
- If you only ever use one surface, nothing above applies to you.

## What will not help

- **Quantization fiddling.** Ollama's default tags are already q4-ish, which is
  the sensible speed/quality point. Chasing q2 saves little and costs noticeably
  in output quality — on a small local model you cannot spare it.
- **Running two models at once.** `OLLAMA_MAX_LOADED_MODELS=1` is set on purpose;
  a second resident model competes for the same RAM and cores. The one
  exception is computed: an agent pinned to its own model (`AGENT_MODEL`) on a
  box with RAM for both gets two slots (`ollama_two_models_fit`).
- **`OLLAMA_KEEP_ALIVE=-1`, as a fix for the section above.** It is not one, and
  it is worth being exact about why: keep-alive decides what happens when
  *nothing is asking*. Eviction happens when the *other model arrives*. Pinning
  one model does not stop the other one loading — it only changes which of them
  is holding RAM when the switch comes. `lca tune` sets keep-alive from this
  box's RAM and which tiers are on (`-1` with the agent on, so the agent's own
  gaps stop costing a full prompt re-read), and says the same thing out loud
  when it does.

  With `ENABLE_AGENT=true` the stack itself makes a second model, and what that
  costs is its own section:
  [Why it randomly gets slow](#why-it-randomly-gets-slow-the-two-models-evict-each-other).
- **Swap.** If a model does not fit in RAM it will "work" via swap at
  unusable speed. `check-system.sh` warns about the RAM headroom instead —
  believe it, and take a smaller model.

## Measuring, not guessing

```bash
lca speed                  # the answer, with a verdict
lca speed --tokens 200     # longer sample, steadier number
ollama ps                  # raw PROCESSOR column, if you want to see it yourself
```

### `ollama ps` can say "GPU" on a machine that has none

On a CPU-only box, Ollama 0.32.5 will happily print a `PROCESSOR` column like
`13%/87% CPU/GPU`. Seen on a host with no `/dev/dri`, no display device and no
`nvidia-smi`, generating at the CPU speed the measured table above gives for
that model — nowhere near the tens of tokens/second a card produces. The
percentages are Ollama's own accounting for memory it manages; they are not
evidence of a card.

`lca check` and `lca speed` therefore classify placement against the hardware
and not against that string. On a machine with no usable NVIDIA GPU they say so
plainly and skip the VRAM advice, which would otherwise be a recommendation to
size a model against a device that is not there. If you see the raw split in
`ollama ps` on a droplet, that is the explanation.

Run `lca speed` before and after a change. It prints the delta against your
last run, and ignores swings under 10% because back-to-back runs on the same
machine vary by a few percent anyway. A change you cannot measure is not an
improvement.

Two caveats worth knowing, and they pull in opposite directions.

Measure a **warm** model. The first request after an idle period pays the load
cost (20 seconds is normal on a droplet, and it is reported separately), and its
prompt-reading rate is dominated by warm-up — around 10× slower than the real
figure. `lca speed` loads the model first for exactly this reason.

Measure reading with a prompt Ollama has **not seen before**, and a big one.
Ollama caches the KV prefix of a prompt it has already processed, so re-sending
the same text measures the cache rather than the machine. Measured here, the
same 2,050-token prompt twice in a row:

```
{"prompt_eval_count":2050, "seconds":104, "read_tps":19}
{"prompt_eval_count":2050, "seconds":0,   "read_tps":6899}
```

`lca speed` used to read with a fixed 43-token benchmark string and reported
160–213 tokens/second on a machine that reads at 20 — too small to out-weigh
per-request overhead, and identical every run so the prefix came straight from
cache. It now sends a fresh, larger prompt with a nonce at the **front** (a
nonce at the end leaves everything before it cacheable, which is most of it).
If you ever hand-roll this measurement with `curl`, do the same, or you will
measure a cache and conclude your box is ten times faster than it is.

---

## Does a 7b fit? Measured, and the answer has two halves

The ladder puts anything under 9 GiB on `qwen2.5-coder:3b`. That is a RAM rule,
and RAM turns out not to be the binding constraint. Both models were measured
here rather than reasoned about.

**Resident cost**, from Ollama's own accounting (`ollama ps`), one model at a
time, each loaded at the context named:

| Context | `3b` | `7b` |
|---|---|---|
| 2048 | 2.1 GB | 4.9 GB |
| 4096 | 2.2 GB | **5.1 GB** |
| 8192 | 2.4 GB | 5.5 GB |
| 16384 | 2.7 GB | 5.9 GB |
| 32768 | 3.4 GB | — |

5.1 GB is about 4.8 GiB. On a 7.8 GiB box that leaves roughly 3 GiB for the OS
and the chat app, so **a 7b fits at 4096 and even at 8192**. "It does not fit"
would be the wrong reason to keep the ladder where it is.

**Speed is the real constraint.** Same box, same prompt, one coding task:

| | prompt eval | generation |
|---|---|---|
| `3b` @ 4096 | 53.7 tok/s | 10.41 tok/s |
| `7b` @ 4096 | 24.4 tok/s | 5.44 tok/s |

The 7b is **1.9× slower to think and 2.2× slower to read**, for a model that
this project's other measurement shows is *not* better at the thing that was
blocking the agent tier (see docs/AGENT.md — the 7b fails the tool-call channel
exactly as the 3b does).

### The measurements above are from a faster machine than the target — and one of the two conversion factors does not travel

These numbers were taken on a 4-vCPU / 16 GB box, not on the 7.8 GiB droplet the
ladder is written for, so the throughput figures do **not** transfer directly.
The memory figures do — weights plus KV cache do not care about the CPU.

One configuration was run on both machines: `3b` at `num_ctx=32768` with a
~16k-token prompt.

| `3b` @ 32768, ~16k prompt | prompt eval | generation |
|---|---|---|
| this box | 28.07 tok/s | 4.07 tok/s |
| the droplet | 8.99 tok/s | 0.59 tok/s |
| ratio | **3.1×** | **6.9×** |

**Read that table as belonging to that configuration, not to those machines.**
The heading matters, and it was learned by getting it wrong: this section used
to hand the 6.9× figure out as a general "writing" conversion, and `docs/AGENT.md`
used it to project an agent task on the droplet at 35–60 minutes. Measured on
that droplet, the task takes **12 minutes**.

Here is the same machine, twice:

| the droplet, `3b` | prompt eval | generation |
|---|---|---|
| @ 32768, ~16k-token prompt | 8.99 tok/s | **0.59 tok/s** |
| @ 16384, a small prompt | 19.6 tok/s | **8.5 tok/s** |

Fourteen times the generation rate, on one box, from nothing but the
configuration. Generation on CPU slows down with the number of tokens already in
the window, and a 32768 allocation on a 7.8 GiB machine is near its limit
besides. Prompt evaluation moved by a factor of two over the same change, which
is why the 3.1× reading ratio has held up in every later measurement while the
6.9× one has not.

**The rule this leaves:** reading converts roughly across machines; generation
does not convert across *configurations*, and any projection that crosses one
should be treated as a guess until a `lca agent selftest` or `lca speed` on the
actual box replaces it.

**The ladder stands, and the argument for it is now narrower.** Under 9 GiB
stays on the 3b, but not because the droplet generates at 0.59 tok/s — at the
window this stack actually uses it generates at 8.5. What is left is memory: the
7b needs 5.1 GB at 4096 and 5.9 GB at 16384, and the agent tier's window is
16384, which on a 7.8 GiB box leaves under 2 GiB for everything else. Nobody has
run `lca agent selftest` with a 7b on that hardware. Anyone who wants the ladder
changed should do exactly that and bring the number — which is now a
twenty-minute experiment rather than an argument.

## Does a bigger agent window pay? Measured on 64 GB: not by default

With 62 GiB, RAM no longer limits the agent's window, so 32768 was tried
against the default 16384 for `qwen2.5-coder:14b-agent` on the ESXi VM:

| | 16384 | 32768 |
|---|---|---|
| reading, 600-token probe | 13.3 tok/s | 13.4 tok/s |
| reading, ~5.9k-token prompt | 515 s | 513 s |
| resident size (`ollama ps`) | 12 GB | 15 GB |
| `lca agent selftest` | 24 min | 23 min |
| a chat message in the middle of an agent session | nothing: shared runner, cache kept | **reload + full re-read of the agent prompt (~22 min at 13.2k tokens)** |

The window itself costs nothing per token: attention work grows with the
tokens actually in it, not with the allocation. What 32768 changes is that the
agent's model no longer matches the chat model, so Ollama runs them as two
models and evicts one for the other (see
[the eviction section](#why-it-randomly-gets-slow-the-two-models-evict-each-other)).

So 16384 stays. What 32768 would buy is room: the agent's own prompt is about
13.2k tokens, so at 16384 a run has roughly 3k tokens for its whole
conversation, which is a few tool calls and their output. The self-test fits.
A long multi-file task may not, and it will say so: the agent warns at
`AGENT_CONTEXT_WARN_PERCENT`. If you hit that, raise `AGENT_MODEL_CONTEXT` to
32768 in `.env` and run `sudo lca agent setup`, and keep the agent and chat
in separate blocks of time.

## The CPU decides the rung too, and NUMA decides writing speed

Auto-tune picks a rung by RAM, then steps down while this CPU would take more
than 300 s to read one aider edit's prompt (`cap_for_cpu` in `scripts/tune.sh`).
Reading is compute-bound and fits one constant per machine: tokens/second ≈
cores × K ÷ billions of parameters, with K ≈ 12 on the AVX-only Xeon
E5-2680 v2 and 36 assumed with AVX2. On the ESXi VM it predicted 13.7 / 27.4
tok/s for 14b / 7b at 16 cores against 13.2 / 27.0 measured. `lca tune
--dry-run` prints the estimate, and `LCA_CPU_CORES=8 LCA_CPU_AVX2=false lca
tune --dry-run` answers "what would a smaller VM get?" (here: 7b, because 14b
would read at ~7 tok/s).

Writing is memory-bound, and on a machine with more than one NUMA node it
depends on *where* the weights sit. Ollama copies the weights into its own
memory, and the kernel puts those pages wherever there is room. On the ESXi VM
(2 sockets × 8 vCPUs) that left the 32b's weights mostly on one node, and
writing was **1.0 tok/s at 8, 12 and 16 threads alike**: memory-bound, not
compute-bound. Under `numactl --interleave=all` it was 2.0, and 14b stayed at
4.3. The managed systemd drop-in now starts Ollama that way whenever there are
two or more nodes and `numactl` is installed. Check with `lscpu | grep NUMA`.
