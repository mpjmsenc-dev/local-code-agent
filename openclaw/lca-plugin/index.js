// local-code-agent's own OpenClaw plugin: project mode and this server, from
// the dashboard. It is the ONLY source of agent tools in the gateway this repo
// sets up (openclaw/setup.sh): no shell, no files, no browser, no web.
//
// Everything it does is a fixed command with checked arguments, run with
// execFile (never a shell), or a file it reads or writes itself:
//
//   /project new NAME  + the spec   save ~/specs/NAME.md, start ~/projects/NAME
//   /project save NAME + the spec   save it only (to check what arrived)
//   /project list | status | stop | resume | summary | decisions | review |
//            plan | acceptance | log  NAME
//   /server status | health | models | restart agent | restart chat
//
// The commands run without the model (a before_dispatch hook sees the raw
// message, so a 40,000-character spec is taken as pasted, with no 4,096 cap
// and no rewriting), and the same operations are tools for the model, so a
// question in plain words works too. The "Projects" tab and the upload page
// are served on the gateway's port: the page needs no secret to load, and
// every request for data or action carries the dashboard password, checked
// by the gateway itself (auth: "gateway").

import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const HOME = os.homedir();
const NAME_RE = /^[a-z0-9][a-z0-9-]{0,63}$/;
const CONTAINER_RE = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/;
const MAX_SPEC = 2_000_000;
// The states a project may be deleted in: it has ended. The runner checks the
// same list (project_deletable_status in lib.sh); this copy only decides which
// projects the page offers a Delete button for.
const DELETABLE = new Set(["done", "stopped", "failed", "waiting", "stalled", "limit", "incomplete"]);
const FILES = {
  summary: ".lca-project/SUMMARY.md",
  decisions: "DECISIONS.md",
  review: "REVIEW.md",
  plan: "PLAN.md",
  acceptance: "ACCEPTANCE.md",
  log: ".lca-project/run.log",
  spec: ".lca-project/spec.md",
};

function settings(api) {
  const c = api.pluginConfig ?? {};
  return {
    lcaDir: c.lcaDir || "/opt/local-code-agent",
    projectsDir: c.projectsDir || path.join(HOME, "projects"),
    specsDir: c.specsDir || path.join(HOME, "specs"),
    openclawBin: c.openclawBin || "/opt/openclaw/app/bin/openclaw",
    dashboardUrl: c.dashboardUrl || "",
  };
}

// --- running fixed commands --------------------------------------------------
function run(file, args, { timeoutMs = 120_000, env = {} } = {}) {
  return new Promise((resolve) => {
    execFile(
      file,
      args,
      { timeout: timeoutMs, maxBuffer: 16 * 1024 * 1024, env: { ...process.env, LCA_NONINTERACTIVE: "1", ...env } },
      (err, stdout, stderr) => {
        const code = err ? (typeof err.code === "number" ? err.code : 1) : 0;
        resolve({ code, stdout: String(stdout ?? ""), stderr: String(stderr ?? ""), timedOut: Boolean(err?.killed) });
      },
    );
  });
}
const plain = (s) => String(s ?? "").replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "").replace(/\r/g, "");
const clip = (s, n = 6000) => (s.length > n ? `${s.slice(0, n)}\n[... ${s.length - n} more characters]` : s);
const tail = (s, n = 6000) => (s.length > n ? `[... ${s.length - n} earlier characters]\n${s.slice(-n)}` : s);
const sha = (s) => createHash("sha256").update(s, "utf8").digest("hex");

function duration(sec) {
  sec = Math.max(0, Math.floor(sec || 0));
  const d = Math.floor(sec / 86400), h = Math.floor((sec % 86400) / 3600), m = Math.floor((sec % 3600) / 60);
  return d ? `${d}d ${h}h ${m}m` : h ? `${h}h ${String(m).padStart(2, "0")}m` : `${m}m`;
}

// --- names ---------------------------------------------------------------------
// A name becomes a directory and a file name and nothing else: lower case,
// letters, digits and dashes, starting with a letter or digit (so it never
// reads as an option). What a person types is folded into that, and refused
// when nothing is left.
export function sanitizeName(raw) {
  const n = String(raw ?? "")
    .toLowerCase()
    .replace(/[^a-z0-9-]+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 64)
    .replace(/-+$/g, "");
  if (!NAME_RE.test(n)) throw new Error(`"${String(raw ?? "").slice(0, 80)}" is not a usable project name: use letters, digits and dashes.`);
  return n;
}

// --- projects ------------------------------------------------------------------
function makeProjects(api) {
  const S = settings(api);
  const script = path.join(S.lcaDir, "scripts", "agent-project.sh");
  let cache = { at: 0, list: null };
  let chain = Promise.resolve();
  const serial = (fn) => (chain = chain.then(fn, fn));

  async function projectJson(dir) {
    const r = await run(script, ["--dir", dir, "--json"], { timeoutMs: 60_000 });
    if (r.code !== 0) return null;
    try { return JSON.parse(r.stdout); } catch { return null; }
  }

  async function list(fresh = false) {
    if (!fresh && cache.list && Date.now() - cache.at < 3000) return cache.list;
    let names = [];
    try { names = await fs.readdir(S.projectsDir); } catch { names = []; }
    const out = [];
    for (const n of names.sort()) {
      const dir = path.join(S.projectsDir, n);
      try { await fs.access(path.join(dir, ".lca-project", "state")); } catch { continue; }
      const j = await projectJson(dir);
      if (j) out.push(j);
    }
    cache = { at: Date.now(), list: out };
    return out;
  }

  function dirOf(name) {
    return path.join(S.projectsDir, sanitizeName(name));
  }

  async function exists(name) {
    try { await fs.access(path.join(dirOf(name), ".lca-project", "state")); return true; } catch { return false; }
  }

  async function saveSpec(name, spec) {
    name = sanitizeName(name);
    if (typeof spec !== "string" || !spec.trim()) throw new Error("The spec is empty: paste it after the command, on the next line.");
    if (spec.length > MAX_SPEC) throw new Error(`The spec is ${spec.length} characters; the limit is ${MAX_SPEC}.`);
    await fs.mkdir(S.specsDir, { recursive: true, mode: 0o700 });
    const file = path.join(S.specsDir, `${name}.md`);
    const tmp = `${file}.tmp-${process.pid}-${Date.now()}`;
    await fs.writeFile(tmp, spec, { encoding: "utf8", mode: 0o600 });
    await fs.rename(tmp, file);
    const back = await fs.readFile(file, "utf8");
    if (back !== spec) throw new Error(`The spec saved to ${file} does not read back the same; nothing was started.`);
    return { name, file, chars: spec.length, lines: spec.split("\n").length, sha256: sha(spec) };
  }

  async function start(name, spec) {
    return serial(async () => {
      name = sanitizeName(name);
      if (await exists(name)) {
        throw new Error(`A project called ${name} already exists (${dirOf(name)}). Use another name, or: /project resume ${name}`);
      }
      const saved = await saveSpec(name, spec);
      const r = await run(script, [saved.file, "--dir", dirOf(name), "--autonomy", "answerer"], { timeoutMs: 600_000 });
      cache.at = 0;
      const msg = plain(`${r.stdout}\n${r.stderr}`).trim();
      if (r.code !== 0) throw new Error(`The spec is saved (${saved.file}, ${saved.chars} characters), but the project did not start:\n${tail(msg, 2000)}`);
      return { ...saved, dir: dirOf(name), output: tail(msg, 2000) };
    });
  }

  async function action(name, verb) {
    name = sanitizeName(name);
    if (!(await exists(name))) throw new Error(`There is no project called ${name}.`);
    const r = await run(script, ["--dir", dirOf(name), `--${verb}`], { timeoutMs: 300_000 });
    cache.at = 0;
    const msg = plain(`${r.stdout}\n${r.stderr}`).trim();
    if (r.code !== 0) throw new Error(tail(msg, 2000) || `${verb} failed`);
    return tail(msg, 2000);
  }

  // remove NAME CONFIRM — delete a stopped or finished project: the runner
  // removes its directory, unit and leftover sandboxes (and refuses anything
  // still running); then the spec the dashboard saved for it goes. CONFIRM
  // must be the name, typed again.
  async function remove(name, confirm) {
    return serial(async () => {
      name = sanitizeName(name);
      if (String(confirm ?? "").trim() !== name) throw new Error(`Nothing was deleted. To delete ${name}, type its name exactly: ${name}`);
      if (!(await exists(name))) throw new Error(`There is no project called ${name}.`);
      const r = await run(script, ["--dir", dirOf(name), "--delete", "--confirm", name], { timeoutMs: 300_000 });
      cache.at = 0;
      const msg = plain(`${r.stdout}\n${r.stderr}`).trim();
      if (r.code !== 0) throw new Error(tail(msg, 2000) || "the delete failed");
      const spec = path.join(S.specsDir, `${name}.md`);
      let specGone = false;
      try { await fs.rm(spec); specGone = true; } catch { specGone = false; }
      return `Deleted ${name}: ${dirOf(name)}${specGone ? ` and ${spec}` : ""}, its runner unit and any leftover sandbox.`;
    });
  }

  async function file(name, which) {
    name = sanitizeName(name);
    const rel = FILES[which];
    if (!rel) throw new Error(`Unknown file "${which}": one of ${Object.keys(FILES).join(", ")}.`);
    let text;
    try { text = await fs.readFile(path.join(dirOf(name), rel), "utf8"); } catch { throw new Error(`${name} has no ${rel} yet.`); }
    return which === "log" ? tail(text, 8000) : clip(text, 20000);
  }

  return { list, start, saveSpec, action, remove, file, exists, S };
}

function projectLine(p) {
  const bits = [`**${p.name}** — ${p.status}`];
  bits.push(`${p.done}/${p.total} steps`);
  if (["running", "planning", "accepting"].includes(p.status) && p.title) {
    bits.push(`now: ${p.step && p.step !== "0" ? `step ${p.step}: ` : ""}${p.title}${p.attempt ? ` (${p.attempt})` : ""}`);
  }
  if (p.queue_position) bits.push(`queued #${p.queue_position}`);
  bits.push(`elapsed ${duration(p.elapsed_seconds)}`);
  if (p.reason && !["running", "planning", "accepting", "queued"].includes(p.status)) bits.push(`why: ${p.reason}`);
  return `- ${bits.join(" · ")}`;
}

function projectDetail(p) {
  const lines = [projectLine(p), ""];
  for (const s of p.steps ?? []) lines.push(`  [${s.done ? "x" : " "}] ${s.n}. ${s.title}`);
  if (p.checks_on?.length) lines.push("", `Project checks on: ${p.checks_on.join(", ")}`);
  if (p.acceptance_round) lines.push(`Acceptance round: ${p.acceptance_round}`);
  if (p.last_log) lines.push("", `Last: ${p.last_log}`);
  if (p.files?.length) lines.push(`Files: ${p.files.join(", ")} (/project <file> ${p.name})`);
  return lines.join("\n");
}

// --- the server ------------------------------------------------------------------
function makeServer(api) {
  const S = settings(api);
  async function envValue(key, fallback) {
    try {
      const env = await fs.readFile(path.join(S.lcaDir, ".env"), "utf8");
      let v = fallback;
      for (const line of env.split("\n")) {
        const m = /^\s*([A-Z0-9_]+)=(.*)$/.exec(line);
        if (m && m[1] === key) v = m[2].trim().replace(/^["']|["']$/g, "");
      }
      return v;
    } catch { return fallback; }
  }
  async function ollama(pathname) {
    try {
      const r = await fetch(`http://127.0.0.1:11434${pathname}`, { signal: AbortSignal.timeout(10_000) });
      return r.ok ? await r.json() : null;
    } catch { return null; }
  }
  async function meminfo() {
    try {
      const t = await fs.readFile("/proc/meminfo", "utf8");
      const g = (k) => Number((new RegExp(`^${k}:\\s+(\\d+)`, "m").exec(t) ?? [])[1] ?? 0) * 1024;
      return { total: g("MemTotal"), available: g("MemAvailable"), swapTotal: g("SwapTotal"), swapFree: g("SwapFree") };
    } catch { return null; }
  }
  const gb = (b) => `${(b / 1024 ** 3).toFixed(1)} GB`;

  async function status(projects) {
    const [mem, ps, df, docker, list] = await Promise.all([
      meminfo(), ollama("/api/ps"), run("df", ["-h", "--output=size,used,avail,pcent", "/"], { timeoutMs: 10_000 }),
      run("docker", ["ps", "--format", "{{.Names}}\t{{.Status}}"], { timeoutMs: 20_000 }), projects.list(),
    ]);
    const load = os.loadavg().map((x) => x.toFixed(2)).join(" ");
    const running = list.filter((p) => ["running", "planning", "accepting"].includes(p.status) && p.runner === "active");
    const queued = list.filter((p) => p.status === "queued");
    const out = [
      `CPU: ${os.cpus().length} vCPUs, load ${load}`,
      mem ? `RAM: ${gb(mem.total - mem.available)} used of ${gb(mem.total)} (${gb(mem.available)} available); swap ${gb(mem.swapTotal - mem.swapFree)} used` : "RAM: unknown",
      `Disk /: ${plain(df.stdout).trim().split("\n").slice(-1)[0]?.trim().replace(/\s+/g, " ") ?? "unknown"} (size used avail use%)`,
      `Models loaded: ${ps?.models?.length ? ps.models.map((m) => `${m.name} (${gb(m.size)}, context ${m.context_length ?? "?"})`).join(", ") : "none"}`,
      `Containers: ${plain(docker.stdout).trim().split("\n").filter(Boolean).map((l) => l.replace("\t", " — ")).join("; ") || "none"}`,
      `Project running: ${running.length ? running.map((p) => `${p.name} (${p.done}/${p.total}, ${p.title || p.status})`).join(", ") : "none"}`,
      `Queued: ${queued.length ? queued.map((p) => p.name).join(", ") : "none"}`,
    ];
    return { text: out.join("\n"), mem, load: os.loadavg(), cpus: os.cpus().length, models: ps?.models ?? [], running: running.map((p) => p.name) };
  }

  async function health() {
    // --quick: no real-generation probe, which would load the chat model and
    // evict the model a running project is using.
    const r = await run(path.join(S.lcaDir, "bin", "lca"), ["check", "--quick"], { timeoutMs: 600_000 });
    return tail(plain(`${r.stdout}\n${r.stderr}`).trim(), 9000) + (r.timedOut ? "\n(lca check was stopped after 10 minutes)" : "");
  }

  async function models() {
    const [ps, tags] = await Promise.all([ollama("/api/ps"), ollama("/api/tags")]);
    if (!tags) return "Ollama is not answering on 127.0.0.1:11434.";
    const loaded = new Set((ps?.models ?? []).map((m) => m.name));
    return (tags.models ?? []).map((m) => `- ${m.name} — ${gb(m.size)}${loaded.has(m.name) ? " — LOADED" : ""}`).join("\n");
  }

  async function restart(target) {
    const key = target === "agent" ? ["AGENT_CONTAINER", "openhands-app"] : target === "chat" ? ["WEBUI_CONTAINER", "open-webui"] : null;
    if (!key) throw new Error('Only two things can be restarted from here: "agent" (the agent app) or "chat" (the chat app).');
    const name = await envValue(key[0], key[1]);
    if (!CONTAINER_RE.test(name)) throw new Error(`The container name in .env is not usable: ${name}`);
    const r = await run("docker", ["restart", name], { timeoutMs: 180_000 });
    if (r.code !== 0) throw new Error(`docker restart ${name} failed: ${plain(r.stderr).trim()}`);
    return `Restarted ${name}.`;
  }
  return { status, health, models, restart };
}

// --- the commands ------------------------------------------------------------------
const HELP = `**Projects** (one runs at a time; the others queue)
- \`/project new NAME\` and, on the next lines, the whole spec: saves it as ~/specs/NAME.md and builds it in ~/projects/NAME, unattended
- \`/project save NAME\` + spec: save only, do not start; \`/project start NAME\` starts a saved one
- \`/project list\` · \`/project status NAME\` · \`/project stop NAME\` · \`/project resume NAME\`
- \`/project delete NAME\`: a stopped or finished project, its folder, its spec and any leftover sandbox (it asks you to type the name)
- \`/project summary|decisions|review|plan|acceptance|log NAME\`
- Upload a spec file, and watch every project live: the **Projects** tab (or /lca/panel)

**Server**
- \`/server status\` (CPU, RAM, disk, models, what is running) · \`/server health\` (lca check) · \`/server models\`
- \`/server restart agent\` · \`/server restart chat\``;

export function parseCommand(text) {
  const m = /^\s*\/(project|server|lca)\b[ \t]*([^\n]*)(?:\n([\s\S]*))?$/i.exec(String(text ?? ""));
  if (!m) return null;
  const head = m[2].trim().split(/\s+/).filter(Boolean);
  return { group: m[1].toLowerCase(), verb: (head[0] ?? "").toLowerCase(), args: head.slice(1), firstLine: m[2], rest: m[3] ?? "" };
}

async function runCommand(cmd, projects, server) {
  if (cmd.group === "lca" || !cmd.verb || cmd.verb === "help") return HELP;
  if (cmd.group === "server") {
    if (cmd.verb === "status") return (await server.status(projects)).text;
    if (cmd.verb === "health") return `\`\`\`\n${await server.health()}\n\`\`\``;
    if (cmd.verb === "models") return await server.models();
    if (cmd.verb === "restart") return await server.restart((cmd.args[0] ?? "").toLowerCase());
    return HELP;
  }
  const name = cmd.args[0];
  switch (cmd.verb) {
    case "list": {
      const l = await projects.list(true);
      return l.length ? l.map(projectLine).join("\n") : "No projects yet. Start one: /project new NAME, then paste the spec on the next lines.";
    }
    case "new":
    case "save": {
      if (!name) throw new Error(`Usage: /project ${cmd.verb} NAME, then the spec on the next lines.`);
      // The spec: everything after the name, the rest of the first line and
      // every line below it, exactly as it came.
      const afterName = cmd.firstLine.replace(/^\s*\S+\s+\S+[ \t]?/, "");
      const spec = afterName.trim() ? `${afterName}${cmd.rest ? `\n${cmd.rest}` : ""}` : cmd.rest;
      if (cmd.verb === "save") {
        const s = await projects.saveSpec(name, spec);
        return `Saved ${s.file}: ${s.chars} characters, ${s.lines} lines, sha256 ${s.sha256}. Not started; start it with /project start ${s.name}`;
      }
      const s = await projects.start(name, spec);
      return `Spec saved: ${s.file} (${s.chars} characters, ${s.lines} lines, sha256 ${s.sha256.slice(0, 16)}…)\nProject: ${s.dir}\n${s.output}\n\nFollow it in the Projects tab, or /project status ${s.name}`;
    }
    case "start": {
      if (!name) throw new Error("Usage: /project start NAME (the spec saved earlier with /project save NAME)");
      let spec;
      try { spec = await fs.readFile(path.join(projects.S.specsDir, `${sanitizeName(name)}.md`), "utf8"); }
      catch { throw new Error(`There is no saved spec ~/specs/${sanitizeName(name)}.md: use /project new ${name} with the spec instead.`); }
      const s = await projects.start(name, spec);
      return `Started ${s.name} from ${s.file} (${s.chars} characters).\n${s.output}`;
    }
    case "status": {
      if (!name) throw new Error("Usage: /project status NAME");
      const l = await projects.list(true);
      const p = l.find((x) => x.name === sanitizeName(name));
      if (!p) throw new Error(`There is no project called ${name}.`);
      return projectDetail(p);
    }
    case "delete": {
      if (!name) throw new Error("Usage: /project delete NAME");
      const n = sanitizeName(name);
      if (cmd.args[1] === undefined) {
        const p = (await projects.list(true)).find((x) => x.name === n);
        if (!p) throw new Error(`There is no project called ${n}.`);
        if (!DELETABLE.has(p.status)) return `${n} is ${p.status}: only a stopped or finished project can be deleted. Stop it first: /project stop ${n}`;
        return `This permanently deletes ${n}: ~/projects/${n}, ~/specs/${n}.md, its runner unit and any leftover sandbox. There is no undo.\nTo confirm, type its name once more:\n/project delete ${n} ${n}`;
      }
      return await projects.remove(n, cmd.args[1]);
    }
    case "stop":
    case "resume":
      if (!name) throw new Error(`Usage: /project ${cmd.verb} NAME`);
      return await projects.action(name, cmd.verb);
    default:
      if (FILES[cmd.verb]) {
        if (!name) throw new Error(`Usage: /project ${cmd.verb} NAME`);
        return `\`\`\`\n${await projects.file(name, cmd.verb)}\n\`\`\``;
      }
      return HELP;
  }
}

// --- the page: the Projects tab, the upload form, browser approval --------------------
async function readBody(req, limit) {
  const chunks = [];
  let size = 0;
  for await (const c of req) {
    size += c.length;
    if (size > limit) throw new Error("too large");
    chunks.push(c);
  }
  return Buffer.concat(chunks).toString("utf8");
}
function send(res, code, body, type = "application/json; charset=utf-8") {
  res.statusCode = code;
  res.setHeader("Content-Type", type);
  res.setHeader("Cache-Control", "no-store");
  res.setHeader("X-Content-Type-Options", "nosniff");
  res.end(typeof body === "string" ? body : JSON.stringify(body));
  return true;
}

async function approveBrowsers(S) {
  const env = { OPENCLAW_NO_AUTO_UPDATE: "1", DO_NOT_TRACK: "1" };
  const l = await run(S.openclawBin, ["devices", "list", "--json"], { timeoutMs: 60_000, env });
  if (l.code !== 0) throw new Error(`openclaw devices list failed: ${plain(l.stderr).trim().slice(0, 300)}`);
  let data;
  try { data = JSON.parse(l.stdout); } catch { throw new Error("openclaw devices list did not answer in JSON"); }
  const pending = data.pending ?? data.pendingRequests ?? data.requests ?? [];
  const now = Date.now();
  const approved = [];
  for (const r of pending) {
    const id = r.requestId ?? r.id;
    const at = Number(r.createdAtMs ?? r.ts ?? Date.parse(r.createdAt ?? "")) || now;
    const role = r.role ?? (r.roles ?? [])[0];
    const browser = /control|webchat|browser|ui/i.test(`${r.clientId ?? ""} ${r.clientMode ?? ""} ${r.platform ?? ""} ${r.client?.id ?? ""} ${r.client?.mode ?? ""}`);
    if (!id || now - at > 15 * 60_000 || (role && role !== "operator") || !browser) continue;
    const a = await run(S.openclawBin, ["devices", "approve", String(id), "--json"], { timeoutMs: 60_000, env });
    if (a.code === 0) approved.push(id);
  }
  return { approved, pending: pending.length };
}

function registerPage(api, projects, server) {
  const S = settings(api);
  api.registerHttpRoute({
    path: "/lca/panel",
    auth: "plugin",
    match: "exact",
    handler: async (req, res) => {
      if (req.method !== "GET" && req.method !== "HEAD") return send(res, 405, { error: "GET only" });
      const html = await fs.readFile(path.join(HERE, "panel.html"), "utf8");
      res.setHeader("Content-Security-Policy", "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'self'; base-uri 'none'; form-action 'none'");
      return send(res, 200, html, "text/html; charset=utf-8");
    },
  });
  api.registerHttpRoute({
    path: "/lca/api",
    auth: "gateway",
    match: "prefix",
    handler: async (req, res) => {
      const url = new URL(req.url ?? "/", "http://local");
      const route = url.pathname.replace(/^\/lca\/api\/?/, "");
      try {
        if (req.method === "GET" && route === "projects") return send(res, 200, { projects: await projects.list() });
        if (req.method === "GET" && route === "server") {
          const s = await server.status(projects);
          return send(res, 200, { text: s.text, load: s.load, cpus: s.cpus, mem: s.mem, models: s.models });
        }
        if (req.method === "GET" && route === "file") {
          return send(res, 200, { text: await projects.file(url.searchParams.get("name"), url.searchParams.get("which")) });
        }
        if (req.method === "POST") {
          const body = JSON.parse((await readBody(req, MAX_SPEC * 4 + 4096)) || "{}");
          if (route === "projects") {
            if (body.start === false) return send(res, 200, await projects.saveSpec(body.name, body.spec));
            return send(res, 200, await projects.start(body.name, body.spec));
          }
          if (route === "stop" || route === "resume") return send(res, 200, { text: await projects.action(body.name, route) });
          if (route === "delete") return send(res, 200, { text: await projects.remove(body.name, body.confirm) });
          if (route === "approve-browser") return send(res, 200, await approveBrowsers(S));
        }
        return send(res, 404, { error: "no such route" });
      } catch (e) {
        return send(res, 400, { error: String(e?.message ?? e) });
      }
    },
  });
  api.session?.controls?.registerControlUiDescriptor?.({
    surface: "tab",
    id: "lca-projects",
    label: "Projects",
    slug: "projects",
    description: "Project mode: start from a spec, follow every project live, stop and resume.",
    icon: "folder",
    group: "control",
    path: "/lca/panel",
    order: 1,
  });
}

// --- the tools: the same operations, for the model -----------------------------------
function textResult(text, details = {}) {
  return { content: [{ type: "text", text: String(text) }], details };
}
const NAME_PARAM = { type: "string", description: "The project name (letters, digits, dashes)." };

function registerTools(api, projects, server) {
  const tool = (name, label, description, properties, required, fn) =>
    api.registerTool({
      name, label, description,
      parameters: { type: "object", properties, required, additionalProperties: false },
      async execute(_id, params) { return textResult(await fn(params ?? {})); },
    });
  tool("lca_projects", "Projects", "List every project with its live progress: status, steps done of total, the step it is on, elapsed time, queue position.", {}, [],
    async () => { const l = await projects.list(true); return l.length ? l.map(projectLine).join("\n") : "No projects yet."; });
  tool("lca_project_status", "Project status", "One project in detail: every step of its plan, done or not, and its last log line.", { name: NAME_PARAM }, ["name"],
    async ({ name }) => { const p = (await projects.list(true)).find((x) => x.name === sanitizeName(name)); if (!p) throw new Error(`No project ${name}`); return projectDetail(p); });
  tool("lca_project_file", "Project file", "Read one of a project's files: summary, decisions (DECISIONS.md), review (REVIEW.md), plan, acceptance, log or spec.",
    { name: NAME_PARAM, which: { type: "string", enum: Object.keys(FILES) } }, ["name", "which"],
    async ({ name, which }) => projects.file(name, which));
  tool("lca_project_start", "Start a project", "Start a new project from a SHORT spec (under 20,000 characters). For a long spec the user pastes it with /project new NAME, or uploads it in the Projects tab; never retype a spec.",
    { name: NAME_PARAM, spec: { type: "string", maxLength: 20000 } }, ["name", "spec"],
    async ({ name, spec }) => { if (String(spec).length > 20000) throw new Error("Too long for a tool call: paste it with /project new NAME instead."); const s = await projects.start(name, spec); return `Started ${s.name}: spec ${s.file} (${s.chars} characters).\n${s.output}`; });
  tool("lca_project_stop", "Stop a project", "Stop a running or queued project (it can be resumed later).", { name: NAME_PARAM }, ["name"],
    async ({ name }) => projects.action(name, "stop"));
  tool("lca_project_resume", "Resume a project", "Resume a stopped project from where it stopped.", { name: NAME_PARAM }, ["name"],
    async ({ name }) => projects.action(name, "resume"));
  tool("lca_server_status", "Server status", "CPU, RAM, disk, the models loaded, the containers and the project running now.", {}, [],
    async () => (await server.status(projects)).text);
  tool("lca_server_health", "Server health", "Run 'lca check', the full health check of this server, and return its report.", {}, [],
    async () => server.health());
  tool("lca_server_models", "Models", "The models on this server, and which one is loaded.", {}, [],
    async () => server.models());
  tool("lca_restart", "Restart", "Restart the agent app (target agent) or the chat app (target chat). Nothing else can be restarted.",
    { target: { type: "string", enum: ["agent", "chat"] } }, ["target"],
    async ({ target }) => server.restart(target));
}

// --- the entry --------------------------------------------------------------------
export default {
  id: "lca",
  name: "local-code-agent",
  description: "Project mode and this server, from the dashboard.",
  register(api) {
    const projects = makeProjects(api);
    const server = makeServer(api);
    registerTools(api, projects, server);
    registerPage(api, projects, server);

    const handle = async (text) => {
      const cmd = parseCommand(text);
      if (!cmd) return null;
      try {
        return await runCommand(cmd, projects, server);
      } catch (e) {
        return `⚠️ ${String(e?.message ?? e)}`;
      }
    };
    // The raw message, before any command parsing: a pasted spec arrives
    // whole and as written. The model is never involved.
    api.on("before_dispatch", async (event) => {
      const text = event?.content ?? event?.body ?? "";
      if (!/^\s*\/(project|server|lca)\b/i.test(text)) return { handled: false };
      const reply = await handle(text);
      return reply === null ? { handled: false } : { handled: true, text: reply };
    });
    // The same commands as registered ones, for the command list, and in case
    // a message reaches command handling without passing the hook.
    for (const name of ["project", "server", "lca"]) {
      api.registerCommand({
        name,
        description: name === "project" ? "Projects: new, list, status, stop, resume, summary…" : name === "server" ? "Server: status, health, models, restart" : "local-code-agent help",
        acceptsArgs: true,
        handler: async (ctx) => ({ text: (await handle(ctx.commandBody ?? `/${name} ${ctx.args ?? ""}`)) ?? HELP }),
      });
    }
    api.logger?.info?.(`[lca] ready: projects in ${projects.S.projectsDir}, specs in ${projects.S.specsDir}`);
  },
};
