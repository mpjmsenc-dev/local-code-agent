# Performance — making it faster, honestly

Local inference on a CPU is a reading pace, not instant. This page explains what
actually controls the speed, in the order that matters, so you can spend effort
where it pays.

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

## What will not help

- **Quantization fiddling.** Ollama's default tags are already q4-ish, which is
  the sensible speed/quality point. Chasing q2 saves little and costs noticeably
  in output quality — on a small local model you cannot spare it.
- **Running two models at once.** `OLLAMA_MAX_LOADED_MODELS=1` is set on purpose;
  a second resident model competes for the same RAM and cores.
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
`13%/87% CPU/GPU`. Measured on a host with no `/dev/dri`, no display device and
no `nvidia-smi`, at 5.3 tokens/second on 7B — exactly CPU speed. The percentages
are Ollama's own accounting for memory it manages; they are not evidence of a
card.

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
