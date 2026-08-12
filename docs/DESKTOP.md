# A desktop client — design, and a recommendation

**Status: design only. Nothing here is built.** This is the honest evaluation
that was asked for, including the parts where the answer is "that does not
work the way it sounds like it does".

The ask, in the owner's words:

> download the app on my Mac and Windows, with the wireguard in it, tailscale or
> whatever it needs... like download the app on my laptop and it's gonna start
> building but in my laptop, booting dockers or creating in my computer
> directly. Like have the options of doing that through the app.

The droplet is HQ. And this is meant to be *part of the project*, not a side
utility.

## The recommendation, up front

**Ship shape A with bundled networking now; design the wire protocol so shape C
is a second backend later, not a fork.** And split the switch the ask describes
into the two switches it actually is.

That recommendation comes with an admission that matters: **A on its own does
not deliver local execution, which is the part actually asked for.** It delivers
the packaging and the sign-in experience completely, and none of the "building
on my laptop". It is the right first version because it is the half that is
cheap, safe and finishable — not because it is the whole answer.

Read on for why C rather than B, why the switch is two switches, and where the
security promise stops travelling.

## The three shapes, judged

| | A — thin client | B — full local stack | C — hybrid |
|---|---|---|---|
| What runs on the laptop | a window | Docker, agent, **and a model** | Docker and agent |
| Where inference happens | droplet | laptop | droplet |
| Edits local files | **no** | yes | yes |
| Models to maintain | 1 | 2 | 1 |
| Needs a capable laptop | no | yes | no |
| Security guarantees travel | n/a — nothing local | **no** | **no** |
| New failure modes | few | many | many |

**A** works today in a browser. An app adds packaging and bundled networking and
nothing else. It is honest about being a viewer.

**B** is a genuine port, and the porting is not the app — it is everything under
it. No systemd, no nftables, no apt. Every guarantee this project makes about
the machine is enforced by those three, and none of them exist on macOS or
Windows. It also means a second model on a second piece of hardware, which is a
second set of performance numbers to measure and defend.

**C** looked like the clever middle — local files, remote inference, one model,
no GPU needed on the laptop. It mostly is. But one measurement kills the neatest
part of its story, and it should be said plainly:

> **For an Apple Silicon Mac, the droplet is the slowest machine in the
> picture.** This project's own numbers: the droplet generates at 8.5 tok/s on a
> 3b, reading at 19.6. An M-series Mac with unified memory runs a *7b* several
> times faster than that, because it has a GPU and the droplet has four CPU
> cores. "Inference from the droplet" is a downgrade on the exact machine the
> owner is asking about.

So C's real argument is not speed. It is **one model to maintain, one place
where the model lives, and a laptop that needs no GPU** — which is the right
trade for a Windows laptop with integrated graphics and the wrong one for a
Mac. That asymmetry is why the design below makes inference a *capability
question* answered per machine, rather than a property of the shape.

## The switch is two switches

The ask describes one switch: run this task here, or on the server. Building it
as one switch is the mistake this section exists to prevent, because two
independent things are being chosen:

1. **Where the files are.** The workspace the agent edits — your laptop's
   checkout, or the droplet's.
2. **Where inference runs.** Which Ollama answers — the laptop's or the
   droplet's.

They are genuinely independent. Local files with remote inference is shape C.
Local files with local inference is shape B. Remote files with remote inference
is what exists today. (Remote files with local inference is the one combination
nobody wants, and the UI should not offer it.)

Collapsing them into one control means a Mac owner who wants local files is
forced onto the droplet's slower inference, or a Windows owner who wants local
files is forced to host a model their machine cannot run. **Two controls, with
sensible defaults**:

- *Workspace*: wherever you started the task. Explicit, never guessed.
- *Inference*: the fastest one available. The app can measure this once, on
  first run, with the same generation probe `lca speed` already uses, and say
  what it chose and why.

This is the answer to "does it deliver the runtime switch or only approximate
it": **it delivers it, and it delivers a better one than the ask described** —
but only in shape C, which is not the first version.

## Bundled networking: what it actually takes

The requirement is right and it is the strongest part of the whole idea. Asking
someone to install Tailscale, find an IP and type a URL is the current
experience, and it is bad.

**Do not ship the Tailscale GUI client.** Two reasons: on Windows a normal
Tailscale install needs the WinTun driver and administrator rights, and on macOS
the App Store build cannot be redistributed inside another app.

**Use `tsnet` instead.** It is Tailscale's embeddable library: a **userspace**
WireGuard implementation that joins a tailnet from inside your process. No
system service, no TUN device, no admin rights, no separate install. The app
gets its own identity on the tailnet and dials the droplet directly.

- **Licensing**: `tailscale.com/tsnet` is BSD-3-Clause. Embedding it in a
  distributed application is permitted. (Tailscale's *hosted coordination
  service* is a separate commercial matter — free tier limits apply per tailnet,
  and a personal tailnet is well inside them.)
- **Auth flow**: the app opens a browser once for Tailscale's device
  authorization, receives a key, and stores it in the OS keychain (Keychain on
  macOS, DPAPI/Credential Manager on Windows). **Never ship an auth key in the
  installer** — a key in a binary is a key on every machine that downloads it.
- **What the user sees**: download, open, *"Sign in with Tailscale"*, approve in
  the browser, done. No IP, no URL, no second install. That is the whole setup,
  which is exactly what was asked for.

**The alternative if `tsnet` proves unworkable**: detect an existing Tailscale
install and use it, degrading to "install Tailscale first" with a link. That is
today's experience with better wording — acceptable as a fallback, not as a
plan.

## How the laptop authenticates to the droplet

Being on the tailnet is **not** authentication. It is a network path. Anything
on the tailnet — another laptop, a phone, a machine someone else added — can
reach the droplet's ports today, and the agent's port is the one that can run
commands.

So the design needs a second layer, and it should be boring:

- **A token per client**, generated on the droplet (`lca client add <name>`),
  stored in the laptop's keychain, sent on every request. Revocable
  individually, so a lost laptop is one command.
- **Tailscale ACLs** as the coarse layer: restrict the agent's port to tagged
  devices rather than the whole tailnet. This is configuration on the tailnet,
  not code, and the doc should tell people to do it.
- **Tailscale identity as the audit trail**: the droplet can see which tailnet
  node made a request. Log it. "Which of my machines started this run" is a
  question that will be asked.

What stops an untrusted machine on the tailnet from using the droplet is
therefore: it has no token, the ACL does not include it, and both facts are
visible. Today the answer is *nothing stops it*, which is fine for a
single-person tailnet and should not be shipped as a product assumption.

## Where the security promise stops

This is the part that must not be papered over.

This project's guarantees are enforced by three Linux mechanisms:

| guarantee | enforced by | travels to macOS/Windows? |
|---|---|---|
| nothing inbound except loopback and the tailnet | **nftables** inbound guard | **no** |
| the machine can be cut off the internet entirely | **nftables** kill switch (`lca offline`) | **no** |
| services survive reboot, restart on failure | **systemd** | **no** |
| the agent's blast radius is one disposable VM | the VM being disposable | **no** |

The first two have rough equivalents — `pf` on macOS, Windows Filtering
Platform — but they are different tools with different failure modes, and
writing "the guard is on" in a UI that is backed by a reimplementation nobody
has tested is worse than not claiming it.

**The honest position: on a desktop client, "private by default" means the
network path is private (WireGuard, end to end, no port forwarding). It does not
mean the laptop is hardened. It cannot, and the app should say so in those
words rather than showing a green shield.**

And the fourth row is the one that deserves the most thought. On the droplet,
the agent has the Docker socket and can run anything — and that is acceptable
because the droplet is a disposable box that costs a few dollars and holds
nothing else. **The same agent, with the same socket, on the machine that holds
your photos, your SSH keys and your browser sessions, is a materially different
proposition.** Shape B and shape C both put it there. If local execution ships,
it needs at minimum:

- an explicit, per-machine opt-in, separate from installing the app
- a workspace directory chosen by the user, mounted alone, not the home folder
- the same limits the droplet already enforces (`lca agent watch`: step ceiling,
  wall clock, stuck detector), running on the laptop from day one

## The workspace, and the switch's edge cases

The ask names the switch as the feature, so its edge cases are the design.

**Shared or separate?** Separate, with git as the bridge. A synced folder
(Syncthing, iCloud, a network mount) between two machines that both run agents
writing files is a conflict generator, and the failure mode is a half-applied
edit that neither machine can explain. Git is what this workspace is already
full of.

**What happens when both run?** Two agents, two branches, one repository. That
is a merge, and it is a merge the user is already equipped to do. The app should
make it visible — *"the droplet is also working in this repo"* — and nothing
more clever than that.

**A task started locally and continued remotely.** Here is the honest answer,
and it is a limitation rather than a feature:

> **You cannot move a running conversation between machines.** The agent's state
> lives in the sandbox container's filesystem and process table, plus
> `~/.openhands` on the machine that started it. There is no export, and
> building one means reimplementing upstream's conversation format and keeping
> up with it.

What *is* achievable, and should be what the UI offers:

- **Push, then start fresh.** Commit and push from the laptop, start a new
  conversation on the droplet pointed at the same branch, with the previous
  task's description carried over as context. The agent re-reads the code — it
  does not resume a train of thought, it picks up a repository.
- **Say so.** The switch should be labelled *"continue this work on the droplet"*
  and should tell the user it starts a new run against the pushed branch, rather
  than implying a seamless handoff it cannot perform.

Anything that claims a live handoff is claiming something upstream does not
support.

## Packaging and update path

| | macOS | Windows |
|---|---|---|
| shell | Tauri (Rust, ~10 MB) or Electron (~120 MB) | same |
| signing | Apple Developer ID, **notarization on every build** ($99/yr) | Authenticode certificate ($200-400/yr, EV for instant SmartScreen trust) |
| install | `.dmg` or `.pkg` | `.msi` or `.exe` (NSIS/WiX) |
| update | Sparkle, or Tauri's updater | Squirrel, or Tauri's updater |
| one-time work | signing identity, notarization in CI, updater keys | certificate purchase and validation (can take weeks for EV), updater endpoint |
| ongoing | notarization on every release; OS majors break things yearly | certificate renewal; SmartScreen reputation resets on cert change |

**Tauri over Electron** if this is built: the app is a window onto a web UI plus
a networking layer, which is precisely Tauri's case, and 10 MB versus 120 MB
matters for something people download once and update often.

The ongoing burden is the number to take seriously. It is not the code — it is
that **every release now needs two signed, notarized artifacts**, and two more
operating systems can break the product without anyone touching the repository.
For a project maintained by one person, that is the real cost.

## What this does to the project's identity

Today the promise is precise: *one Ubuntu VM you fully control, private by
default, with every guarantee enforced on that machine.* Its README, its
security model and its testing all rest on that.

A desktop client changes the promise to *a private system you reach from your
own devices, with the guarantees enforced on the server.* That is still a good
promise and it is not the same one. If this ships:

- **README** needs the one-VM claim rewritten. The security section must state
  where the guard ends — at the droplet — and that the client is a network path,
  not a hardened machine.
- **PHONE.md** stops being the only remote-access story and becomes one of
  three (phone browser, desktop app, SSH).
- **A new promise has to be stated and kept**: what the app sends, where the
  token lives, what the droplet logs. A client that talks to your server is a
  thing users are right to ask about.
- **CI** grows two platforms it cannot fully test. This repository's whole
  method is real installs on real machines; a Mac runner and a Windows runner
  that only build-and-sign are a weaker gate than anything here today, and that
  weakness should be admitted in the docs rather than hidden behind a green
  badge.

If those changes are not wanted, that is a sufficient reason not to build it —
and a legitimate one.

## Effort, honestly

Estimates assume one experienced developer, and *include* the parts that are not
code — certificates, notarization, and the first three times each of them fails.

| | initial | ongoing |
|---|---|---|
| **A** — thin client, `tsnet`, signing, updater, token auth | **4-6 weeks** | ~2-3 days per quarter, plus one bad week per OS major |
| **C** — A, plus local Docker, local agent lifecycle, workspace and switch UI | **+6-10 weeks** | roughly double: two execution paths, two bug surfaces |
| **B** — C, plus a local model, hardware variance, a second performance story | **+4-6 weeks** | highest; every model question now has two answers |

The uncomfortable ratio: **shape A is about a third of the total effort and
delivers none of the local execution.** Most of that third is packaging and
signing, which shape C would have to pay anyway.

## What I would cut for a first useful version

1. **A signed, auto-updating window onto the droplet's agent, with `tsnet`
   bundled and a per-client token.** Download, sign in, work. No URL, no IP, no
   second install.
2. **The switch present but honest**: *Workspace: droplet* / *this machine
   (coming)*, with the local option visible and disabled, explaining what it
   will do. Users should be able to see where the project is going; they should
   not be able to click something that half-works.
3. **A git-aware "continue on the droplet" action**, which pushes the branch and
   starts a fresh run — labelled as what it is.

Cut from v1: local Docker, local model, workspace sync beyond git, anything
claiming a security guarantee on the client.

## If the conclusion were "do not build this"

It is worth stating the case, because it is not weak.

The value the owner actually described is *"I want to work on my laptop's files
with my own agent, and I do not want to fiddle with networking."* There is a
version of that which needs no desktop app at all:

- **Bundled networking is the real win**, and most of it is achievable today by
  writing down the three steps properly. Much of the current pain is that
  `<tailscale-ip>` appears in the docs and nothing tells you what yours is.
- **Local file editing already exists**: this project's own `lca` runs aider in
  whatever directory you are standing in. On a laptop with a checkout and an
  SSH tunnel to the droplet's Ollama, that is local execution with remote
  inference — shape C — with **no new codebase at all**, and it is perhaps two
  days of scripting plus a page of documentation.

**That is the recommendation I would push hardest**: before committing 4-6 weeks
to packaging, spend two days on `lca` running against a remote Ollama over
Tailscale from a laptop, and find out whether the desktop app was mostly about
the fiddling. If it was, the app becomes a nicety rather than the plan. If the
owner tries it and still wants the window and the switch, then the four to six
weeks are being spent on something already known to be wanted.

---

Nothing in this document has been built, and no estimate in it has been tested
against a real attempt. It is a design and a recommendation, which is what was
asked for.
