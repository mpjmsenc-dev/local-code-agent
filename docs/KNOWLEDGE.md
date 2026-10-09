# The house knowledge system: design

Status: design, 2026-10-07. Nothing here is built yet; it is built stage by
stage, each stage working and through `make gates-container` before the next.

## What it is for, and what "learning" means here

Every project this box builds should go better than the last. The model's
weights cannot be retrained on this CPU, so "learning" means a **curated,
measured knowledge base** delivered to the model as context: short lessons
from our own runs, patterns and pitfalls for the stacks our projects use, and
reference snippets from well-maintained open-source code. It is shared by the
project-mode planner, the coder (OpenCode or OpenHands, through the step
prompts the runner writes) and the dashboard's OpenClaw (through a read-only
tool). Everything is local and free: the agent model, a small embedding model
(`nomic-embed-text`, Apache-2.0, kept loaded beside the others), plain files,
local git.

It earns its place only by measurement. A fixed benchmark runs with and
without it (Stage 2), and if the knowledge base does not measurably improve
the results, the report says so plainly and no further features are added
on top of it.

## The pieces at a glance

```
~/house/knowledge/          local git, never pushed (pre-push hook refuses, no remotes)
  items/lesson/*.md         from our own runs (steering: needs your approval)
  items/rule/*.md           house rules (steering: needs your approval)
  items/pattern/*.md        how a stack is used well (steering: needs approval)
  items/pitfall/*.md        what goes wrong and how it shows (steering: needs approval)
  items/snippet/*.md        verbatim code from MIT/Apache-2.0/BSD sources only
  catalog/repos.md          the repositories and docs studied, and why each
  bench/                    benchmark definition and every result
  KNOWLEDGE-RULES.md        the caps, the formats, the review rules
~/house/index/knowledge.db  the search index (SQLite: items, embeddings)
~/house/study/              study plans, runs, and each run's fetched packet
~/house/training/           verified step examples for a future fine-tune
```

The knowledge repo holds only curated text: nothing fetched lands in it
unreviewed or un-cut, and nothing in it is ever executed.

Code: `scripts/knowledge.py` (Python 3 standard library only: json, sqlite3,
urllib to Ollama on loopback), `scripts/knowledge.sh` (`lca knowledge ...`),
the runner's hooks in `scripts/agent-project.sh`, the study worker's
container files under `knowledge/study/`, and the dashboard's views in the
lca OpenClaw plugin. Everything runs as the owner; no runtime part uses sudo.

## The item format

One Markdown file per item, with a front matter block the tools validate:

```
---
id: lesson-2026-10-07-prisma-sqlite-generate
kind: lesson            # lesson | rule | pattern | pitfall | snippet
title: Run prisma generate after every schema change, before the tests
topics: [prisma, sqlite, testing]
stacks: [node, prisma]
source:
  type: project-run     # project-run | study | manual
  ref: mpjm-accounting-plateform, step 3 (attempts 1-2 failed)
  url:                  # for study items: the repo or page
  commit:               # for snippets: the exact commit
license: n/a            # own text: n/a; snippets: MIT | Apache-2.0 | BSD-2-Clause | BSD-3-Clause
date: 2026-10-07
confidence: medium      # low | medium | high
status: proposed        # proposed | approved | rejected | retired
steering: true          # lessons, rules, patterns, pitfalls: true; snippets: false
evidence: [run:mpjm-accounting-plateform/step-3]
---
Body: at most 120 words, or for a snippet at most 60 lines of code and two
lines saying what it is for.
```

Every item records its source, date, license, topic tags and confidence, as
asked. Items are never deleted silently: rejection and retirement are status
changes, committed with the reason, so the history says what was tried.

**Caps** (in `KNOWLEDGE-RULES.md`, checked by `lca knowledge check` and by
`lca check`): 1,500 approved items; 4 KB per item; 6 MB of item text in all;
the study cache 2 GB; training examples 5 GB. Past 90% of a cap, a pruning
proposal goes to the review queue: the items least used in the last 60 days,
those with no measured benefit, and near-duplicates (embedding similarity
above 0.92), oldest and lowest-confidence first. Nothing is pruned without
your approval.

## Review: what waits for you

- **Steering items** (lessons, rules, patterns, pitfalls: anything that tells
  the model what to do) start as `proposed` and are used by nobody until you
  approve them, edit them, or reject them in the dashboard.
- **Reference snippets** from MIT, Apache-2.0 or BSD sources, with the repo
  URL, commit and license recorded, are added `approved` automatically and
  marked as such; you can remove any of them.
- Anything else from studies (docs, or code under other licenses) is a
  paraphrased note, never code, and is steering, so it waits for approval.

## Stage 1: the knowledge base and lessons from our own runs

**Index.** `lca knowledge index` embeds every item (`search_document:` prefix,
title + topics + body) with `nomic-embed-text` through Ollama's `/api/embed`
on loopback, and stores the vectors in SQLite. At this size (thousands of
items, 768 dimensions) an exact cosine scan in Python takes milliseconds; no
vector database is needed. Re-indexing is incremental by content hash.

**Lessons.** When a project finishes or stops, the runner (in its exit path,
after `SUMMARY.md`) runs `lca knowledge harvest --dir DIR`, which:

1. builds a deterministic **run digest** from what the runner already
   records: each step's outcome and attempt count, failing check output
   (clipped), splits and re-plans, the tests-check verdicts, review findings,
   acceptance rounds, the decisions in `DECISIONS.md`, and per-phase times;
2. sends the digest in one request to the agent model (temperature 0), which
   proposes **at most 8 lessons** in a fixed format: what happened, the
   cause, what fixed it or would have, and the topic and stack tags;
3. drops near-duplicates of existing items (cosine above 0.92), which add
   their run to the existing item's evidence instead, and writes the rest as
   `proposed`, committed to the knowledge repo, into the review queue.

**Delivery.** Planning and every step get only the most relevant approved
items within a fixed token budget:

| phase | query | budget |
|---|---|---|
| planning, milestone planning | spec summary + detected stacks | 2,000 tokens |
| a step's tests, the step, review fixes | step title + its check + plan section + stacks | 1,200 tokens |
| split and re-plan requests | the step and its failure output | 600 tokens |

Ranking: cosine similarity, boosted when an item's stacks match the
project's, weighted by confidence and by its measured benefit (Stage 2),
items already rejected or retired excluded. Items are added best first until
the budget is spent (counted as characters / 3.5, the same estimate the
runner uses elsewhere). They go into the task text under a heading that
frames them as **reference notes, not instructions: the spec, the plan and
the checks take precedence**, and each carries its id, so the run log records
which items each phase received. That log is what Stage 2 uses to attribute
results to items.

**OpenClaw** gets a read-only tool, `lca_knowledge_search`, and the
dashboard's knowledge views. Its own Skill Workshop stays off
(`skills.workshop.autonomous.mode: off`, the `skill_workshop` tool denied,
no skills at all), and `lca check` fails if that changes: OpenClaw reads the
shared knowledge base, it does not create skills or abilities for itself.

**Stage 1 is done when:** the repo, index and harvest work on the finished
projects already on this box (wcount, crm, the accounting platform), lessons
reach the review queue, approved items reach planning and step prompts within
budget, and the suite drives all of it with a stand-in model.

## Stage 2: the benchmark

A fixed set, versioned in `bench/`:

- graded tasks **A, B, C and D** (`~/lca-eval/seed` and the hidden graders in
  `~/lca-eval/grade`), each turned into a small project-mode spec, and
- **two small specs** with hidden graders: wcount (the end-to-end test of
  2026-10-06) and a small Flask/SQLite CRUD service, so a web stack is covered.

Each runs as a real project-mode project, twice per benchmark run: with the
knowledge base and without it (the same code, the knowledge delivery off).
Recorded per task and condition: hidden-grader result, steps passed first
time, attempts, splits, acceptance rounds, wall time and model time. Bench
runs use temperature 0 and a fixed seed, so a difference is the knowledge and
not the dice; production keeps the model's own settings.

**Cost, honestly.** On this CPU a small project takes one to three hours, so
one full benchmark (6 specs, 2 conditions) is roughly 12 to 30 hours of
machine time. It runs when no project is building, overnight and across
nights, resumable; a project you start always takes priority (the benchmark
yields at the next phase boundary).

**Schedule.** Weekly (a user timer, Sunday 01:00 America/Toronto), and after
a major knowledge change (25 or more items approved or retired since the last
run), only while the project queue is empty.

**Attribution.** Each run logs which items it received. An item delivered in
runs that did worse with the knowledge base than without, on three or more
tasks, is proposed for removal with that evidence; an item linked to better
results gains confidence.

**What counts as "better".** On 6 tasks at temperature 0, a real effect has
to be large to show: at least one more task passing, or 20% fewer attempts or
model time at the same pass rate, sustained over two benchmark runs. Anything
smaller is reported as "no measurable effect", which is a result, not a
failure of the report.

**Dashboard:** the trend of both conditions over time, per task, with the
items involved.

## Stage 3: the study worker

Studies public GitHub repositories and official documentation for the stacks
our projects use, and extracts patterns, conventions and pitfalls.

**Isolation.** Two containers on a Docker network created `--internal` (no
route out):

- the **worker**: read-only root filesystem, all capabilities dropped,
  `no-new-privileges`, running as an unprivileged user, no secrets or tokens
  in its environment, no host mounts except its own output folder
  (`~/house/study/runs/<run>/out`), never `~/projects`, never the knowledge
  repo, never the Docker socket;
- an **egress proxy** (a small allowlisting CONNECT proxy of our own, Python
  standard library, in its own container on the internal network and the
  default bridge) that opens connections only to these hosts on port 443:
  - `github.com`, `raw.githubusercontent.com`, `codeload.github.com`
  - `docs.python.org`, `packaging.python.org`, `pip.pypa.io`
  - `nodejs.org`, `docs.npmjs.com`, `www.typescriptlang.org`
  - `developer.mozilla.org`
  - `fastify.dev`, `expressjs.com`
  - `react.dev`, `vite.dev`, `vitest.dev`
  - `www.prisma.io`, `sqlite.org`
  - `flask.palletsprojects.com`, `docs.djangoproject.com`, `docs.pytest.org`

  Everything else is refused and logged. The list lives in the knowledge repo
  and changes only by an approved edit.

**Read-only.** The worker only issues GET requests and holds no
credentials, so it cannot write anywhere it reaches. Inside TLS the proxy
cannot see the method; enforcing it there would mean intercepting TLS, which
this design does not do. That limit is stated, not hidden.

**Untrusted data.** Everything fetched is data, never instructions. The
worker downloads a repository as a tarball at an exact commit
(`codeload.github.com/OWNER/REPO/tar.gz/COMMIT`), unpacks it inside its own
container, and **never executes, installs or builds** any of it; fetched code
never runs on the host either. It writes a **study packet**: the selected
files (README, docs, configuration, tests and representative modules, capped
in size), the LICENSE text, the URL, the commit and its date. Extraction then
happens on the host, from the packet, with no network: the agent model reads
the packet inside clearly delimited blocks, under a system prompt that says
the content is untrusted data to describe and never instructions to follow,
and answers in a fixed JSON schema. The output is validated: schema, sizes,
no URLs outside the allowlist, no instructions addressed to an agent. Text in
the packet that tries to instruct is reported, not followed.

**Licenses.** Verbatim snippets only from MIT, Apache-2.0 or BSD-licensed
sources (the license identified from the LICENSE file of that commit, not
from a guess), with the repo URL, commit and license recorded in the item.
Everything else becomes paraphrased notes, never code. Documentation is
always paraphrased.

**Choosing repositories.** `catalog/repos.md` lists, per stack, the
repositories and docs to study and why each was chosen: the official project
repository first, then widely used, actively maintained ones (activity read
from `github.com/OWNER/REPO/commits.atom`, inside the allowlist). New
candidates enter the catalog only by an approved edit, with the reason
written down.

## Stage 4: curiosity

A study planner (`lca knowledge plan-study`) picks topics from evidence:

- repeated failures: the same failing check pattern or stack in two or more
  runs;
- rescued steps: steps that only passed after a split, a re-plan or the
  last attempt's test correction;
- thin coverage: stacks our projects use with few approved items;
- benchmark weak spots: tasks that fail in both conditions.

Each topic gets a score and a reason, and each study run a budget: 60
minutes, 40 pages or files, at most 10 proposed items. Runs happen only when
no project is building and no benchmark is running, from 01:00 to 06:00
America/Toronto (a user timer that checks the project lock first and yields
to a project that starts). The plan and every run's outcome are in the
dashboard's study queue and history.

## Stage 5: training data for later

Every step that passed its checks and its review is recorded as one example
in `~/house/training/<project>/<step>.json`: the instruction (the step's task
text), the context it was given (spec summary, plan section, knowledge items
by id), the final diff (from the step's base to the accepted commit), the
checks with their passing output, and metadata (model, window, times,
attempts). Local only, never pushed, under the 5 GB cap, for a fine-tune on a
GPU some day. Nothing is fine-tuned now.

## The dashboard

Through the lca OpenClaw plugin, as a **Knowledge** tab beside Projects and
as `/knowledge` commands:

- **Review queue:** proposed items with their evidence; approve, edit (the
  text, tags, confidence) or reject with a reason.
- **Study queue and history:** what is planned and why, what each run read,
  what it proposed, what was refused at the proxy.
- **Knowledge browser:** every item with its source, license, confidence,
  status and where it was used; search; remove.
- **Benchmark trend:** both conditions over time, per task.

## Order of work, and what decides whether it continues

1. Stage 1, gates, used on the next projects.
2. Stage 2: the benchmark and its baseline (without, then with the items
   Stage 1 produced). **Report:** does the knowledge base measurably improve
   the benchmark? If not, say so, and stop adding features until it does.
3. Stages 3 and 4 only on that evidence; Stage 5 in any case (it costs
   nothing at run time and is useful whatever the benchmark says).
