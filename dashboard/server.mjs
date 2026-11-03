// Jarvis status dashboard: read-only health page for the Xiaomi box, built-in modules only.
// GET /            -> HTML page that polls /api/status
// GET /api/status  -> JSON snapshot (cached for CACHE_MS)
import { createServer } from "node:http";
import { readFile, readdir, readlink, statfs } from "node:fs/promises";
import { execFile } from "node:child_process";
import { networkInterfaces, hostname } from "node:os";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const PORT = Number(process.env.JARVIS_DASH_PORT ?? 8080);
const HOST = process.env.JARVIS_DASH_HOST ?? "0.0.0.0";
const CACHE_MS = 5_000;
const CMD_TIMEOUT_MS = 4_000;
const WATCHDOG_EVENTS = 15;
const SERVICES = [
  "jarvis-wifi-power",
  "jarvis-wifi-watchdog.timer",
  "wpa_supplicant@wlan0",
  "systemd-networkd",
  "ssh",
  "nftables",
  "jarvis-claude-rc",
  "avahi-daemon",
  "jarvis-dashboard",
];
// The service runs with ProtectHome, so it cannot execute claude (installed under /root);
// the version is the basename of the /usr/local/bin/claude symlink target instead.
const CLAUDE_LINK = "/usr/local/bin/claude";
const PAGE_PATH = join(dirname(fileURLToPath(import.meta.url)), "index.html");

const run = (cmd, args) =>
  new Promise((resolve) => {
    execFile(cmd, args, { timeout: CMD_TIMEOUT_MS }, (err, stdout, stderr) => {
      resolve({ ok: !err, out: String(stdout).trim(), err: err ? String(stderr || err.message).trim() : "" });
    });
  });

const readText = async (path) => {
  try {
    return (await readFile(path, "utf8")).trim();
  } catch {
    return null;
  }
};

const memInfo = async () => {
  const raw = (await readText("/proc/meminfo")) ?? "";
  const kb = (key) => Number(raw.match(new RegExp(`^${key}:\\s+(\\d+)`, "m"))?.[1] ?? 0);
  return {
    totalMiB: Math.round(kb("MemTotal") / 1024),
    availableMiB: Math.round(kb("MemAvailable") / 1024),
    swapTotalMiB: Math.round(kb("SwapTotal") / 1024),
    swapFreeMiB: Math.round(kb("SwapFree") / 1024),
  };
};

const temperaturesC = async () => {
  try {
    const zones = (await readdir("/sys/class/thermal")).filter((z) => z.startsWith("thermal_zone"));
    const readings = await Promise.all(
      zones.map(async (z) => {
        const type = await readText(`/sys/class/thermal/${z}/type`);
        const milli = Number(await readText(`/sys/class/thermal/${z}/temp`));
        return Number.isFinite(milli) ? { zone: type ?? z, c: Math.round(milli / 100) / 10 } : null;
      }),
    );
    return readings.filter(Boolean);
  } catch {
    return [];
  }
};

const diskRoot = async () => {
  try {
    const s = await statfs("/");
    const gib = (blocks) => Math.round(((blocks * s.bsize) / 1024 ** 3) * 10) / 10;
    return { totalGiB: gib(s.blocks), freeGiB: gib(s.bavail) };
  } catch (e) {
    return { error: String(e) };
  }
};

const wifi = async () => {
  const link = await run("iw", ["dev", "wlan0", "link"]);
  const pick = (re) => link.out.match(re)?.[1] ?? null;
  const ipv4 = (networkInterfaces().wlan0 ?? []).find((a) => a.family === "IPv4")?.address ?? null;
  return {
    connected: link.out.startsWith("Connected"),
    ssid: pick(/SSID: (.+)/),
    bssid: pick(/Connected to ([0-9a-f:]+)/),
    freqMHz: Number(pick(/freq: ([\d.]+)/)) || null,
    signalDbm: Number(pick(/signal: (-?\d+)/)) || null,
    txBitrate: pick(/tx bitrate: (.+)/),
    ipv4,
  };
};

const services = async () =>
  Promise.all(
    SERVICES.map(async (name) => {
      const r = await run("systemctl", ["is-active", name]);
      return { name, state: r.out || "unknown" };
    }),
  );

const watchdogEvents = async () => {
  const r = await run("journalctl", ["-b", "--no-pager", "-o", "short-iso", "-u", "jarvis-wifi-watchdog"]);
  const lines = r.out.split("\n").filter((l) => /link check failed|recovered|still down|vo hang/.test(l));
  return {
    failuresThisBoot: lines.filter((l) => l.includes("link check failed")).length,
    voHangsIgnored: lines.filter((l) => l.includes("vo hang")).length,
    recent: lines.slice(-WATCHDOG_EVENTS).map((l) => l.replace(/\s+jarvis jarvis-wifi-watchdog\[\d+\]:/, "")),
    error: r.ok ? null : r.err,
  };
};

const snapshot = async () => {
  const [uptime, loadavg, mem, temps, disk, link, svc, wd, claude] = await Promise.all([
    readText("/proc/uptime"),
    readText("/proc/loadavg"),
    memInfo(),
    temperaturesC(),
    diskRoot(),
    wifi(),
    services(),
    watchdogEvents(),
    readlink(CLAUDE_LINK).then((t) => t.split("/").pop()).catch(() => null),
  ]);
  return {
    host: hostname(),
    time: new Date().toISOString(),
    uptimeS: Math.round(Number(uptime?.split(" ")[0] ?? 0)),
    load: loadavg?.split(" ").slice(0, 3).map(Number) ?? [],
    mem,
    temps,
    disk,
    wifi: link,
    services: svc,
    watchdog: wd,
    claudeVersion: claude,
  };
};

let cache = { at: 0, data: null, pending: null };
const cachedSnapshot = async () => {
  if (cache.data && Date.now() - cache.at < CACHE_MS) return cache.data;
  cache.pending ??= snapshot().finally(() => {
    cache.pending = null;
  });
  const data = await cache.pending;
  cache = { ...cache, at: Date.now(), data };
  return data;
};

// Blocks DNS rebinding: a page on another origin that resolves its name to this box would send
// its own hostname in Host. Only this box's names and current addresses are accepted.
const allowedHosts = () => {
  const names = new Set(["localhost", "jarvis", "jarvis.local", hostname(), `${hostname()}.local`]);
  for (const addrs of Object.values(networkInterfaces())) {
    for (const a of addrs ?? []) names.add(a.family === "IPv6" ? `[${a.address}]` : a.address);
  }
  return names;
};
const hostAllowed = (hostHeader) => {
  if (!hostHeader) return false;
  const name = hostHeader.toLowerCase().replace(/:\d+$/, "");
  return allowedHosts().has(name);
};

const send = (res, status, type, body) => {
  res.writeHead(status, { "content-type": type, "cache-control": "no-store", "x-content-type-options": "nosniff" });
  res.end(body);
};

const server = createServer(async (req, res) => {
  if (req.method !== "GET") return send(res, 405, "text/plain", "method not allowed");
  if (!hostAllowed(req.headers.host)) return send(res, 421, "text/plain", "misdirected request");
  try {
    if (req.url === "/api/status") return send(res, 200, "application/json", JSON.stringify(await cachedSnapshot()));
    if (req.url === "/" || req.url === "/index.html") return send(res, 200, "text/html; charset=utf-8", await readFile(PAGE_PATH));
    return send(res, 404, "text/plain", "not found");
  } catch (e) {
    process.stderr.write(`request ${req.url} failed: ${e?.stack ?? e}\n`);
    return send(res, 500, "text/plain", "internal error");
  }
});

server.listen(PORT, HOST, () => process.stderr.write(`jarvis dashboard on http://${HOST}:${PORT}\n`));
