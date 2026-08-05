/* Station server — zero dependencies, Node 18+.
   Serves the pages plus:
     /api/kv/:key      JSON storage (one file per key, atomic writes)
     /api/history/...  automatic version history + restore
     /api/files/...    uploads for documents and attachments
     /api/capture      one-line capture from a phone shortcut  */

const http = require("http");
const fs   = require("fs");
const path = require("path");
const crypto = require("crypto");

const PORT     = process.env.STATION_PORT || 8099;
const HOST     = process.env.STATION_HOST || "0.0.0.0";
const DATA_DIR = process.env.STATION_DATA || "/data";
const PUB_DIR  = process.env.STATION_PUBLIC || path.join(__dirname, "public");
const FILE_DIR = path.join(DATA_DIR, "files");
const HIST_DIR = path.join(DATA_DIR, "history");
const MAX_BODY = 8 * 1024 * 1024;        // JSON payload cap
const MAX_FILE = 25 * 1024 * 1024;       // upload cap
const HIST_KEEP = 40;                    // versions kept per key

[DATA_DIR, FILE_DIR, HIST_DIR].forEach(d => fs.mkdirSync(d, { recursive: true }));

/* one capture token, generated once, used by phone shortcuts */
const TOKEN_FILE = path.join(DATA_DIR, "capture-token.txt");
if (!fs.existsSync(TOKEN_FILE)) {
  fs.writeFileSync(TOKEN_FILE, crypto.randomBytes(18).toString("base64url"));
}
const CAPTURE_TOKEN = fs.readFileSync(TOKEN_FILE, "utf8").trim();

const TYPES = {
  ".html":"text/html; charset=utf-8", ".js":"text/javascript; charset=utf-8",
  ".css":"text/css; charset=utf-8",   ".json":"application/json; charset=utf-8",
  ".svg":"image/svg+xml", ".png":"image/png", ".jpg":"image/jpeg", ".jpeg":"image/jpeg",
  ".gif":"image/gif", ".webp":"image/webp", ".pdf":"application/pdf",
  ".txt":"text/plain; charset=utf-8", ".ico":"image/x-icon", ".heic":"image/heic"
};

const okKey = k => /^[A-Za-z0-9:_.-]{1,120}$/.test(k);
const keyFile = k => okKey(k) ? path.join(DATA_DIR, k.replace(/:/g, "_") + ".json") : null;
const okId  = i => /^[A-Za-z0-9_-]{1,40}$/.test(i);

function send(res, code, body, type){
  res.writeHead(code, {
    "Content-Type": type || "application/json; charset=utf-8",
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer"
  });
  res.end(body);
}

function readBody(req, cap){
  return new Promise(resolve => {
    let n = 0, over = false; const chunks = [];
    req.on("data", c => {
      if (over) return;
      n += c.length;
      if (n > cap) { over = true; chunks.length = 0; return; }
      chunks.push(c);
    });
    req.on("end",   () => resolve(over ? null : Buffer.concat(chunks)));
    req.on("error", () => resolve(null));
  });
}

function writeAtomic(file, data){
  const tmp = file + "." + crypto.randomBytes(6).toString("hex") + ".tmp";
  const fd = fs.openSync(tmp, "w");
  try { fs.writeSync(fd, data); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
  fs.renameSync(tmp, file);
}

/* ---------- version history ---------- */
function snapshot(key, file){
  if (!fs.existsSync(file)) return;
  try {
    const dir = path.join(HIST_DIR, key.replace(/:/g, "_"));
    fs.mkdirSync(dir, { recursive: true });
    fs.copyFileSync(file, path.join(dir, Date.now() + ".json"));
    const old = fs.readdirSync(dir).filter(f => f.endsWith(".json")).sort();
    while (old.length > HIST_KEEP) fs.unlinkSync(path.join(dir, old.shift()));
  } catch (e) { /* history is best effort, never block a write */ }
}

/* ---------- capture ---------- */
function capture(text, kind){
  const file = keyFile("hub:v1");
  let H = { };
  if (fs.existsSync(file)) {
    try { H = JSON.parse(fs.readFileSync(file, "utf8")).value || {}; } catch (e) {}
  }
  H.tasks = H.tasks || []; H.notes = H.notes || []; H.journal = H.journal || [];
  H.lists = (H.lists && H.lists.length) ? H.lists : ["Inbox"];
  const id = crypto.randomBytes(4).toString("hex");
  const d = new Date();
  const today = d.getFullYear()+"-"+String(d.getMonth()+1).padStart(2,"0")+"-"+String(d.getDate()).padStart(2,"0");

  if (kind === "note") {
    H.notes.push({ id, title: text.slice(0,60), body:"", tags:["captured"], pinned:false, created:today, updated:today });
  } else if (kind === "journal") {
    const e = H.journal.find(x => x.date === today);
    if (e) e.body = (e.body ? e.body + "\n\n" : "") + text;
    else H.journal.push({ id, date: today, title:"", body: text, tags:[] });
  } else {
    H.tasks.push({ id, title: text, done:false, list:H.lists[0], prio:3, due:"", notes:"", repeat:"none", created:today });
  }
  snapshot("hub:v1", file);
  writeAtomic(file, JSON.stringify({ key:"hub:v1", value:H, updated: Date.now() }));
  return { ok:true, kind: kind || "task", text };
}

function serveStatic(req, res){
  let rel = decodeURIComponent(req.url.split("?")[0]);
  if (rel === "/") rel = "/index.html";
  const file = path.join(PUB_DIR, path.normalize(rel));
  if (!file.startsWith(PUB_DIR)) return send(res, 403, "forbidden", "text/plain");
  fs.readFile(file, (err, buf) => {
    if (err) return send(res, 404, "not found", "text/plain");
    send(res, 200, buf, TYPES[path.extname(file).toLowerCase()] || "application/octet-stream");
  });
}

const server = http.createServer(async (req, res) => {
  const url = req.url.split("?")[0];
  const q = new URLSearchParams((req.url.split("?")[1] || ""));

  if (url === "/api/health")
    return send(res, 200, JSON.stringify({ ok:true, time:Date.now() }));

  if (url === "/api/token" && req.method === "GET")
    return send(res, 200, JSON.stringify({ token: CAPTURE_TOKEN }));

  /* ---- capture: for phone shortcuts ---- */
  if (url === "/api/capture") {
    const token = q.get("token") || (req.headers.authorization||"").replace(/^Bearer /,"");
    if (token !== CAPTURE_TOKEN) return send(res, 401, JSON.stringify({ error:"bad token" }));
    let text = q.get("text") || "", kind = q.get("kind") || "task";
    if (req.method === "POST") {
      const raw = await readBody(req, 64*1024);
      if (raw) {
        const s = raw.toString("utf8").trim();
        if (s.startsWith("{")) {
          try { const j = JSON.parse(s); text = j.text || text; kind = j.kind || kind; } catch (e) { text = s; }
        } else if (s) text = s;
      }
    }
    text = String(text).trim();
    if (!text) return send(res, 400, JSON.stringify({ error:"no text" }));
    try { return send(res, 200, JSON.stringify(capture(text, kind))); }
    catch (e) { return send(res, 500, JSON.stringify({ error:"capture failed" })); }
  }

  /* ---- version history ---- */
  if (url.startsWith("/api/history/")) {
    const rest = url.slice("/api/history/".length).split("/");
    const key = decodeURIComponent(rest[0]);
    if (!okKey(key)) return send(res, 400, JSON.stringify({ error:"bad key" }));
    const dir = path.join(HIST_DIR, key.replace(/:/g, "_"));
    if (rest.length === 1) {
      if (!fs.existsSync(dir)) return send(res, 200, JSON.stringify({ versions: [] }));
      const versions = fs.readdirSync(dir).filter(f => f.endsWith(".json"))
        .map(f => ({ ts: Number(f.slice(0,-5)), size: fs.statSync(path.join(dir,f)).size }))
        .sort((a,b) => b.ts - a.ts);
      return send(res, 200, JSON.stringify({ key, versions }));
    }
    const ts = rest[1].replace(/[^0-9]/g, "");
    const f = path.join(dir, ts + ".json");
    if (!ts || !fs.existsSync(f)) return send(res, 404, JSON.stringify({ error:"no such version" }));
    if (req.method === "GET") return send(res, 200, fs.readFileSync(f, "utf8"));
    if (req.method === "POST") {          // restore
      const live = keyFile(key);
      snapshot(key, live);
      writeAtomic(live, fs.readFileSync(f));
      return send(res, 200, JSON.stringify({ restored: ts }));
    }
    return send(res, 405, JSON.stringify({ error:"method not allowed" }));
  }

  /* ---- files ---- */
  if (url === "/api/files" && req.method === "GET") {
    const list = fs.readdirSync(FILE_DIR).filter(f => f.endsWith(".json"))
      .map(f => { try { return JSON.parse(fs.readFileSync(path.join(FILE_DIR,f),"utf8")); } catch(e){ return null; } })
      .filter(Boolean).sort((a,b) => b.added - a.added);
    return send(res, 200, JSON.stringify({ files: list }));
  }

  if (url === "/api/files" && req.method === "POST") {
    const buf = await readBody(req, MAX_FILE);
    if (!buf) return send(res, 413, JSON.stringify({ error:"file too large (25 MB max)" }));
    if (!buf.length) return send(res, 400, JSON.stringify({ error:"empty file" }));
    let name = "file";
    try { name = Buffer.from(req.headers["x-filename"]||"", "base64").toString("utf8") || "file"; } catch (e) {}
    name = name.replace(/[\/\\]/g, "_").slice(0, 120);
    const id = crypto.randomBytes(8).toString("hex");
    const ext = (path.extname(name) || "").toLowerCase().slice(0, 10);
    const meta = {
      id, name,
      type: req.headers["content-type"] || TYPES[ext] || "application/octet-stream",
      size: buf.length,
      added: Date.now(),
      linkKind: (req.headers["x-link-kind"] || "").slice(0,20),
      linkId:   (req.headers["x-link-id"]   || "").slice(0,60),
      label:    (() => { try { return Buffer.from(req.headers["x-label"]||"","base64").toString("utf8").slice(0,80); } catch(e){ return ""; } })(),
      tags: []
    };
    try {
      writeAtomic(path.join(FILE_DIR, id + ".bin"), buf);
      writeAtomic(path.join(FILE_DIR, id + ".json"), JSON.stringify(meta));
    } catch (e) { return send(res, 500, JSON.stringify({ error:"save failed" })); }
    return send(res, 200, JSON.stringify(meta));
  }

  if (url.startsWith("/api/files/")) {
    const id = url.slice("/api/files/".length);
    if (!okId(id)) return send(res, 400, JSON.stringify({ error:"bad id" }));
    const metaF = path.join(FILE_DIR, id + ".json");
    const binF  = path.join(FILE_DIR, id + ".bin");
    if (!fs.existsSync(metaF)) return send(res, 404, JSON.stringify({ error:"not found" }));
    const meta = JSON.parse(fs.readFileSync(metaF, "utf8"));

    if (req.method === "GET") {
      const buf = fs.readFileSync(binF);
      const dispo = q.get("dl") ? "attachment" : "inline";
      res.writeHead(200, {
        "Content-Type": meta.type,
        "Content-Length": buf.length,
        "Content-Disposition": `${dispo}; filename="${meta.name.replace(/"/g,"")}"`,
        "Cache-Control": "private, max-age=86400",
        "X-Content-Type-Options": "nosniff"
      });
      return res.end(buf);
    }
    if (req.method === "PUT") {                       // edit label / tags / link
      const raw = await readBody(req, 64*1024);
      try {
        const j = JSON.parse(raw.toString("utf8"));
        if ("label" in j) meta.label = String(j.label).slice(0,80);
        if ("tags"  in j) meta.tags  = (j.tags||[]).slice(0,12).map(t => String(t).slice(0,24));
        if ("linkKind" in j) meta.linkKind = String(j.linkKind).slice(0,20);
        if ("linkId"   in j) meta.linkId   = String(j.linkId).slice(0,60);
        writeAtomic(metaF, JSON.stringify(meta));
        return send(res, 200, JSON.stringify(meta));
      } catch (e) { return send(res, 400, JSON.stringify({ error:"bad json" })); }
    }
    if (req.method === "DELETE") {
      try { fs.unlinkSync(metaF); if (fs.existsSync(binF)) fs.unlinkSync(binF); }
      catch (e) { return send(res, 500, JSON.stringify({ error:"delete failed" })); }
      return send(res, 200, JSON.stringify({ id, deleted:true }));
    }
    return send(res, 405, JSON.stringify({ error:"method not allowed" }));
  }

  /* ---- key/value ---- */
  if (url === "/api/keys" && req.method === "GET") {
    const keys = fs.readdirSync(DATA_DIR).filter(f => f.endsWith(".json"))
      .map(f => f.slice(0,-5).replace(/_/g, ":"));
    return send(res, 200, JSON.stringify({ keys }));
  }

  if (url.startsWith("/api/kv/")) {
    const key = decodeURIComponent(url.slice("/api/kv/".length));
    const file = keyFile(key);
    if (!file) return send(res, 400, JSON.stringify({ error:"bad key" }));

    if (req.method === "GET") {
      if (!fs.existsSync(file)) return send(res, 404, JSON.stringify({ error:"not found" }));
      try { return send(res, 200, fs.readFileSync(file, "utf8")); }
      catch (e) { return send(res, 500, JSON.stringify({ error:"read failed" })); }
    }
    if (req.method === "PUT") {
      const raw = await readBody(req, MAX_BODY);
      if (raw === null) return send(res, 413, JSON.stringify({ error:"too large" }));
      let parsed;
      try { parsed = JSON.parse(raw.toString("utf8")); }
      catch (e) { return send(res, 400, JSON.stringify({ error:"bad json" })); }
      if (!("value" in parsed)) return send(res, 400, JSON.stringify({ error:"missing value" }));
      try {
        snapshot(key, file);
        writeAtomic(file, JSON.stringify({ key, value: parsed.value, updated: Date.now() }));
      } catch (e) { return send(res, 500, JSON.stringify({ error:"write failed" })); }
      return send(res, 200, JSON.stringify({ key, ok:true }));
    }
    if (req.method === "DELETE") {
      try { snapshot(key, file); if (fs.existsSync(file)) fs.unlinkSync(file); }
      catch (e) { return send(res, 500, JSON.stringify({ error:"delete failed" })); }
      return send(res, 200, JSON.stringify({ key, deleted:true }));
    }
    return send(res, 405, JSON.stringify({ error:"method not allowed" }));
  }

  if (req.method === "GET") return serveStatic(req, res);
  return send(res, 404, JSON.stringify({ error:"not found" }));
});

server.listen(PORT, HOST, () => {
  console.log(`station on ${HOST}:${PORT}`);
  console.log(`  data:  ${DATA_DIR}`);
  console.log(`  files: ${FILE_DIR}`);
});
