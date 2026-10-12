#!/usr/bin/env node
// Start page for the browser: clock, search, todos from the notes in ~/Notes, Firefox bookmarks,
// a wallpaper. No dependencies. Listens on 127.0.0.1 only. See README.md.
'use strict';

const http = require('node:http');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');

const MAX_BODY = 10_000;
const MAX_TODO_LENGTH = 500;
// the s flag: . would otherwise stop at U+2028 / U+2029 and hide such a todo
const TODO_LINE = /^(\s*)- \[([ xX])\] (.*?)(\r?)$/s;
const IMAGE = /\.(jpe?g|png|webp|avif)$/i;
const MIME = {
  '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png', '.webp': 'image/webp', '.avif': 'image/avif',
};
const STATIC_FILES = new Set(['style.css', 'app.js', 'lib.js']);

class HttpError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

function loadConfig(env = process.env) {
  const home = os.homedir();
  const user = os.userInfo().username;
  return {
    host: '127.0.0.1',
    port: Number(env.HOMEPAGE_PORT ?? 7878),
    notesDir: path.resolve(env.NOTES_DIR ?? path.join(home, 'Notes')),
    wallpaperDir: path.resolve(env.WALLPAPER_DIR ?? path.join(home, 'Pictures', 'Wallpapers')),
    firefoxProfile: env.FIREFOX_PROFILE ?? '',
    name: env.HOMEPAGE_NAME ?? user.charAt(0).toUpperCase() + user.slice(1),
    publicDir: path.join(__dirname, 'public'),
  };
}

// ---- notes and todos -------------------------------------------------------------------------

function localDate(date = new Date()) {
  const p = (n) => String(n).padStart(2, '0');
  return `${date.getFullYear()}-${p(date.getMonth() + 1)}-${p(date.getDate())}`;
}

// A note is a .md file directly inside the notes folder. Anything else is rejected,
// including symlinks that point out of the folder.
async function notePath(cfg, file) {
  if (typeof file !== 'string' || !/^[^/\\\0]+\.md$/.test(file) || file.startsWith('.')) throw new HttpError(400, 'invalid note name');
  const full = path.join(cfg.notesDir, file);
  let real;
  try { real = await fsp.realpath(full); } catch { throw new HttpError(404, 'note not found'); }
  const root = await fsp.realpath(cfg.notesDir);
  if (path.dirname(real) !== root) throw new HttpError(400, 'invalid note location');
  return real;
}

function parseTodos(content) {
  const todos = [];
  content.split('\n').forEach((line, index) => {
    const m = TODO_LINE.exec(line);
    if (m) todos.push({ line: index + 1, text: m[3], done: m[2] !== ' ', indent: Math.floor(m[1].length / 2) });
  });
  return todos;
}

async function listTodos(cfg) {
  const today = localDate();
  let names = [];
  try { names = (await fsp.readdir(cfg.notesDir)).filter((n) => n.endsWith('.md') && !n.startsWith('.')); } catch { /* no notes yet */ }
  const notes = [];
  for (const file of names) {
    const full = path.join(cfg.notesDir, file);
    const stat = await fsp.stat(full);
    if (!stat.isFile()) continue;
    const todos = parseTodos(await fsp.readFile(full, 'utf8'));
    if (todos.length === 0) continue;
    const title = file.replace(/\.md$/, '');
    const kind = title === today ? 'today' : /^\d{4}-\d{2}-\d{2}$/.test(title) ? 'daily' : 'note';
    notes.push({ file, title, kind, mtime: stat.mtimeMs, todos });
  }
  const rank = { today: 0, daily: 1, note: 2 };
  notes.sort((a, b) => rank[a.kind] - rank[b.kind] || (a.kind === 'note' ? b.mtime - a.mtime : b.title.localeCompare(a.title)));
  return { today, notes: notes.map(({ mtime, ...n }) => n) };
}

async function writeAtomically(file, content, mode) {
  const tmp = `${file}.tmp-${process.pid}-${Math.random().toString(36).slice(2)}`;
  try {
    await fsp.writeFile(tmp, content, { mode });
    await fsp.rename(tmp, file);
  } catch (error) {
    await fsp.rm(tmp, { force: true });
    throw error;
  }
}

async function toggleTodo(cfg, body) {
  const { file, line, text, done } = body ?? {};
  if (!Number.isInteger(line) || line < 1 || typeof text !== 'string' || typeof done !== 'boolean') throw new HttpError(400, 'file, line, text and done are required');
  const full = await notePath(cfg, file);
  const before = await fsp.stat(full);
  const lines = (await fsp.readFile(full, 'utf8')).split('\n');

  // the line number may have shifted since the page loaded: trust the text, not the position
  let index = -1;
  const here = TODO_LINE.exec(lines[line - 1] ?? '');
  if (here && here[3] === text) {
    index = line - 1;
  } else {
    const matches = lines.map((l, i) => [TODO_LINE.exec(l), i]).filter(([m]) => m && m[3] === text);
    if (matches.length !== 1) throw new HttpError(409, matches.length === 0 ? 'that todo changed or is gone: reload the page' : 'several todos have that text: reload the page');
    index = matches[0][1];
  }

  const m = TODO_LINE.exec(lines[index]);
  if ((m[2] !== ' ') === done) return { ok: true, changed: false };
  lines[index] = `${m[1]}- [${done ? 'x' : ' '}] ${m[3]}${m[4]}`;

  const after = await fsp.stat(full);
  if (after.mtimeMs !== before.mtimeMs || after.size !== before.size) throw new HttpError(409, 'the note changed while saving: reload the page');
  await writeAtomically(full, lines.join('\n'), before.mode & 0o777);
  return { ok: true, changed: true, line: index + 1 };
}

async function addTodo(cfg, body) {
  const text = String(body?.text ?? '').replace(/[\r\n]+/g, ' ').trim();
  if (!text) throw new HttpError(400, 'text is required');
  if (text.length > MAX_TODO_LENGTH) throw new HttpError(400, `text is longer than ${MAX_TODO_LENGTH} characters`);
  await fsp.mkdir(cfg.notesDir, { recursive: true });
  const file = `${localDate()}.md`;
  const full = path.join(cfg.notesDir, file);
  let existing = '';
  try { existing = await fsp.readFile(full, 'utf8'); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  // do not glue the new line onto a last line that has no trailing newline
  const prefix = existing && !existing.endsWith('\n') ? '\n' : '';
  await fsp.appendFile(full, `${prefix}- [ ] ${text}\n`);
  const lineCount = (existing + prefix).split('\n').length;
  return { ok: true, file, todo: { line: lineCount, text, done: false, indent: 0 } };
}

// ---- Firefox bookmarks -----------------------------------------------------------------------

function findPlaces(cfg) {
  if (cfg.firefoxProfile) return path.join(cfg.firefoxProfile, 'places.sqlite');
  const home = os.homedir();
  const candidates = [];
  for (const root of [path.join(home, '.config', 'mozilla', 'firefox'), path.join(home, '.mozilla', 'firefox')]) {
    let dirs = [];
    try { dirs = fs.readdirSync(root); } catch { continue; }
    for (const dir of dirs) {
      const db = path.join(root, dir, 'places.sqlite');
      if (!fs.existsSync(db)) continue;
      const wal = `${db}-wal`;
      const newest = Math.max(fs.statSync(db).mtimeMs, fs.existsSync(wal) ? fs.statSync(wal).mtimeMs : 0);
      candidates.push({ db, newest });
    }
  }
  candidates.sort((a, b) => b.newest - a.newest);
  return candidates[0]?.db ?? null;
}

function readBookmarks(placesFile) {
  if (!placesFile || !fs.existsSync(placesFile)) return [];
  // Firefox keeps the live database locked: work on a copy (with its write-ahead log)
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'homepage-'));
  try {
    for (const ext of ['', '-wal']) {
      if (fs.existsSync(placesFile + ext)) fs.copyFileSync(placesFile + ext, path.join(tmp, `places.sqlite${ext}`));
    }
    const db = new DatabaseSync(path.join(tmp, 'places.sqlite'));
    const rows = db.prepare(
      `SELECT b.title AS title, p.url AS url FROM moz_bookmarks b JOIN moz_places p ON b.fk = p.id
       WHERE b.type = 1 AND p.url NOT LIKE 'place:%' ORDER BY b.title COLLATE NOCASE`).all();
    db.close();
    const seen = new Set();
    const out = [];
    for (const { title, url } of rows) {
      if (!/^https?:\/\//i.test(url) || seen.has(url)) continue;
      seen.add(url);
      let label = title;
      if (!label) { try { label = new URL(url).hostname; } catch { label = url; } }
      out.push({ title: label, url });
    }
    // sort by the label we show (untitled bookmarks are labelled with their host), not by the raw title
    return out.sort((a, b) => a.title.localeCompare(b.title, undefined, { sensitivity: 'base' }));
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

function makeBookmarkCache(cfg, ttlMs = 60_000) {
  let value = null;
  let at = 0;
  return () => {
    if (!value || Date.now() - at > ttlMs) {
      try { value = readBookmarks(findPlaces(cfg)); } catch (error) { console.error('bookmarks:', error.message); value = value ?? []; }
      at = Date.now();
    }
    return value;
  };
}

// ---- wallpaper -------------------------------------------------------------------------------

function listWallpapers(cfg) {
  try { return fs.readdirSync(cfg.wallpaperDir).filter((n) => IMAGE.test(n)); } catch { return []; }
}

function captionFor(name) {
  const apod = /^apod-(\d{4})-([a-z]+)-(\d{1,2})-(.+)\.\w+$/i.exec(name);
  if (apod) {
    const title = apod[4].replace(/-/g, ' ');
    return { text: title.charAt(0).toUpperCase() + title.slice(1), credit: `NASA APOD, ${apod[3]} ${apod[2].charAt(0).toUpperCase()}${apod[2].slice(1, 3).toLowerCase()} ${apod[1]}` };
  }
  if (/^spacex-/i.test(name)) return { text: 'SpaceX', credit: '' };
  return { text: '', credit: '' };
}

function pickWallpaper(cfg) {
  const all = listWallpapers(cfg);
  if (all.length === 0) return null;
  const name = all[Math.floor(Math.random() * all.length)];
  return { url: `/wallpaper/${encodeURIComponent(name)}`, ...captionFor(name) };
}

// ---- http ------------------------------------------------------------------------------------

function send(res, status, body, headers = {}) {
  res.writeHead(status, { 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer', ...headers });
  res.end(body);
}

function sendJson(res, status, value) {
  send(res, status, JSON.stringify(value), { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
}

async function readJson(req) {
  if (!String(req.headers['content-type'] ?? '').toLowerCase().startsWith('application/json')) throw new HttpError(415, 'content-type must be application/json');
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_BODY) throw new HttpError(413, 'request too large');
    chunks.push(chunk);
  }
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { throw new HttpError(400, 'invalid JSON'); }
}

// JSON placed inside an HTML script block must not be able to close it
const escapeAttr = (text) => text.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const embed = (value) => JSON.stringify(value).replace(/</g, '\\u003c').replace(/\u2028/g, '\\u2028').replace(/\u2029/g, '\\u2029');

const CSP = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'self'; "
  + "base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

function createServer(cfg) {
  const bookmarks = makeBookmarkCache(cfg);
  let allowedHosts = new Set();
  let allowedOrigins = new Set();

  const server = http.createServer(async (req, res) => {
    try {
      // DNS rebinding: a hostile site that resolves to 127.0.0.1 would still send its own Host header
      if (!allowedHosts.has(req.headers.host)) throw new HttpError(403, 'forbidden host');
      const url = new URL(req.url, 'http://localhost');
      const route = `${req.method} ${url.pathname}`;

      if (req.method === 'POST') {
        // other websites cannot read or send these: no CORS headers, JSON only, same-origin only
        const origin = req.headers.origin;
        if (origin && !allowedOrigins.has(origin)) throw new HttpError(403, 'forbidden origin');
      }

      if (route === 'GET /') {
        const html = await fsp.readFile(path.join(cfg.publicDir, 'index.html'), 'utf8');
        const state = { name: cfg.name, todos: await listTodos(cfg), bookmarks: bookmarks(), wallpaper: pickWallpaper(cfg) };
        const picture = state.wallpaper ? `<img id="bg" alt="" src="${escapeAttr(state.wallpaper.url)}">` : '';
        return send(res, 200, html.replace('<!--WALLPAPER-->', () => picture).replace('__STATE__', () => embed(state)),
          { 'Content-Type': MIME['.html'], 'Cache-Control': 'no-store', 'Content-Security-Policy': CSP });
      }
      if (req.method === 'GET' && STATIC_FILES.has(url.pathname.slice(1))) {
        const file = path.join(cfg.publicDir, url.pathname.slice(1));
        return send(res, 200, await fsp.readFile(file), { 'Content-Type': MIME[path.extname(file)], 'Cache-Control': 'no-cache' });
      }
      if (route === 'GET /api/todos') return sendJson(res, 200, await listTodos(cfg));
      if (route === 'GET /api/bookmarks') return sendJson(res, 200, bookmarks());
      if (route === 'GET /api/wallpaper') return sendJson(res, 200, pickWallpaper(cfg));
      if (route === 'POST /api/todos/toggle') return sendJson(res, 200, await toggleTodo(cfg, await readJson(req)));
      if (route === 'POST /api/todos/add') return sendJson(res, 200, await addTodo(cfg, await readJson(req)));

      if (req.method === 'GET' && url.pathname.startsWith('/wallpaper/')) {
        const name = decodeURIComponent(url.pathname.slice('/wallpaper/'.length));
        if (!listWallpapers(cfg).includes(name)) throw new HttpError(404, 'not found');
        const file = path.join(cfg.wallpaperDir, name);
        const { size } = await fsp.stat(file);
        res.writeHead(200, { 'Content-Type': MIME[path.extname(name).toLowerCase()], 'Content-Length': size,
          'Cache-Control': 'max-age=3600', 'X-Content-Type-Options': 'nosniff' });
        return fs.createReadStream(file).pipe(res);
      }
      throw new HttpError(404, 'not found');
    } catch (error) {
      if (res.headersSent) return res.destroy();
      if (error instanceof HttpError) return sendJson(res, error.status, { error: error.message });
      console.error(error);
      return sendJson(res, 500, { error: 'internal error' });
    }
  });

  server.on('listening', () => {
    const { port } = server.address();
    allowedHosts = new Set([`127.0.0.1:${port}`, `localhost:${port}`]);
    allowedOrigins = new Set([`http://127.0.0.1:${port}`, `http://localhost:${port}`]);
  });
  return server;
}

if (require.main === module) {
  const cfg = loadConfig();
  const server = createServer(cfg);
  server.on('error', (error) => {
    console.error(error.code === 'EADDRINUSE' ? `port ${cfg.port} is already in use (HOMEPAGE_PORT changes it)` : error.message);
    process.exit(1);
  });
  server.listen(cfg.port, cfg.host, () => console.log(`homepage on http://${cfg.host}:${server.address().port}  notes: ${cfg.notesDir}`));
  for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close(() => process.exit(0)));
}

module.exports = { createServer, loadConfig, parseTodos, readBookmarks, captionFor, localDate };
