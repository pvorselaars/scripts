#!/usr/bin/env node
// Start page for the browser: clock, search, todos from the notes in ~/Notes, a wallpaper.
// No dependencies. Listens on 127.0.0.1 only. See README.md.
'use strict';

const http = require('node:http');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');

const MAX_BODY = 10_000;
const MAX_TODO_LENGTH = 500;
// the s flag: . would otherwise stop at U+2028 / U+2029 and hide such a todo
const TODO_LINE = /^(\s*)- \[([ xX])\] (.*?)(\r?)$/s;
const IMAGE = /\.(jpe?g|png|webp|avif)$/i;
const MIME = {
  '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png', '.webp': 'image/webp', '.avif': 'image/avif',
};
const STATIC_FILES = new Set(['style.css', 'app.js', 'note.js', 'lib.js']);

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
    wallpaper: env.HOMEPAGE_WALLPAPER ?? '',
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

// The notes: .md files that are real files directly inside the notes folder. A symlink that points
// outside the folder is not a note (it must not be readable through the page either).
async function noteFiles(cfg) {
  let root;
  let entries;
  try { root = await fsp.realpath(cfg.notesDir); entries = await fsp.readdir(cfg.notesDir); } catch { return []; }
  const out = [];
  for (const file of entries) {
    if (!file.endsWith('.md') || file.startsWith('.')) continue;
    let real;
    try { real = await fsp.realpath(path.join(cfg.notesDir, file)); } catch { continue; }
    if (path.dirname(real) !== root) continue;
    const stat = await fsp.stat(real);
    if (stat.isFile()) out.push({ file, name: file.slice(0, -3), full: real, mtime: stat.mtimeMs });
  }
  return out;
}

const noteRank = (name, today) => (name === today ? 0 : /^\d{4}-\d{2}-\d{2}$/.test(name) ? 1 : 2);

async function listTodos(cfg) {
  const today = localDate();
  const files = await noteFiles(cfg);
  const notes = [];
  for (const { file, name, full, mtime } of files) {
    const todos = parseTodos(await fsp.readFile(full, 'utf8'));
    if (todos.length === 0) continue;
    const kind = ['today', 'daily', 'note'][noteRank(name, today)];
    notes.push({ file, title: name, kind, mtime, todos });
  }
  const rank = { today: 0, daily: 1, note: 2 };
  notes.sort((a, b) => rank[a.kind] - rank[b.kind] || (a.kind === 'note' ? b.mtime - a.mtime : b.title.localeCompare(a.title)));
  // names: every note, so [[links]] to notes that do not exist yet can be shown differently
  return { today, notes: notes.map(({ mtime, ...n }) => n), names: files.map((f) => f.name).sort() };
}

// ---- one note, and what links to it ------------------------------------------------------------

const WIKI_LINK = /\[\[([^\]\n|#]+?)(?:#[^\]\n|]+)?(?:\|[^\]\n]+)?\]\]/g;
const MAX_NOTE_BYTES = 1_000_000;

async function noteInfo(cfg, requested) {
  if (typeof requested !== 'string' || !/^[^/\\\0]{1,200}$/.test(requested) || requested.startsWith('.')) throw new HttpError(400, 'invalid note name');
  const today = localDate();
  const files = await noteFiles(cfg);
  // [[Selios]] finds selios.md; an exact match wins over a case-insensitive one
  const hit = files.find((f) => f.name === requested) ?? files.find((f) => f.name.toLowerCase() === requested.toLowerCase());
  const target = (hit?.name ?? requested).toLowerCase();

  const backlinks = [];
  for (const f of files) {
    if (hit && f.name === hit.name) continue;
    const snippets = [];
    for (const line of (await fsp.readFile(f.full, 'utf8')).split('\n')) {
      WIKI_LINK.lastIndex = 0;
      for (let m = WIKI_LINK.exec(line); m; m = WIKI_LINK.exec(line)) {
        if (m[1].trim().toLowerCase() === target) { snippets.push(line.trim().slice(0, 160)); break; }
      }
    }
    if (snippets.length) backlinks.push({ name: f.name, snippets: snippets.slice(0, 3) });
  }
  backlinks.sort((a, b) => noteRank(a.name, today) - noteRank(b.name, today) || (noteRank(a.name, today) === 1 ? b.name.localeCompare(a.name) : a.name.localeCompare(b.name)));

  let content = null;
  if (hit) content = (await fsp.readFile(hit.full, 'utf8')).slice(0, MAX_NOTE_BYTES);
  return { exists: Boolean(hit), name: hit?.name ?? requested, file: hit?.file ?? null, content, backlinks, names: files.map((f) => f.name).sort() };
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

function fnv1a(text) {
  let hash = 0x811c9dc5;
  for (const byte of Buffer.from(text)) hash = Math.imul(hash ^ byte, 0x01000193) >>> 0;
  return hash;
}

// One background for the whole day, the same on every page, tab and reload (and across a restart).
// Each image gets a score from "date:filename" and the lowest wins, so adding wallpapers during
// the day almost never changes the pick (a new file wins 1 time in n). HOMEPAGE_WALLPAPER pins one file.
function pickWallpaper(cfg) {
  const all = listWallpapers(cfg).sort();
  if (all.length === 0) return null;
  let name = cfg.wallpaper && all.includes(cfg.wallpaper) ? cfg.wallpaper : null;
  if (!name) {
    const day = localDate(cfg.now ? cfg.now() : new Date());
    name = all.reduce((best, n) => (fnv1a(`${day}:${n}`) < fnv1a(`${day}:${best}`) ? n : best));
  }
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
  const log = cfg.log ?? ((message) => console.log(message)); // every write to a note is logged (journalctl --user -u homepage)
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

      const page = async (file, extra) => {
        const html = await fsp.readFile(path.join(cfg.publicDir, file), 'utf8');
        const state = { name: cfg.name, wallpaper: pickWallpaper(cfg), ...extra };
        const picture = state.wallpaper ? `<img id="bg" alt="" src="${escapeAttr(state.wallpaper.url)}">` : '';
        return send(res, 200, html.replace('<!--WALLPAPER-->', () => picture).replace('__STATE__', () => embed(state)),
          { 'Content-Type': MIME['.html'], 'Cache-Control': 'no-store', 'Content-Security-Policy': CSP });
      };
      const noteName = (prefix) => {
        try { return decodeURIComponent(url.pathname.slice(prefix.length)); } catch { throw new HttpError(400, 'invalid note name'); }
      };

      if (route === 'GET /') return await page('index.html', { todos: await listTodos(cfg) });
      if (req.method === 'GET' && url.pathname.startsWith('/note/')) return await page('note.html', { note: await noteInfo(cfg, noteName('/note/')) });
      if (req.method === 'GET' && url.pathname.startsWith('/api/note/')) return sendJson(res, 200, await noteInfo(cfg, noteName('/api/note/')));
      if (req.method === 'GET' && STATIC_FILES.has(url.pathname.slice(1))) {
        const file = path.join(cfg.publicDir, url.pathname.slice(1));
        return send(res, 200, await fsp.readFile(file), { 'Content-Type': MIME[path.extname(file)], 'Cache-Control': 'no-cache' });
      }
      if (route === 'GET /api/todos') return sendJson(res, 200, await listTodos(cfg));
      if (route === 'GET /api/wallpaper') return sendJson(res, 200, pickWallpaper(cfg));
      if (route === 'POST /api/todos/toggle') {
        const body = await readJson(req);
        const result = await toggleTodo(cfg, body);
        if (result.changed) log(`toggle ${body.file}:${result.line} -> ${body.done ? 'done' : 'open'}: ${body.text.slice(0, 80)}`);
        return sendJson(res, 200, result);
      }
      if (route === 'POST /api/todos/add') {
        const result = await addTodo(cfg, await readJson(req));
        log(`add ${result.file}:${result.todo.line}: ${result.todo.text.slice(0, 80)}`);
        return sendJson(res, 200, result);
      }

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

module.exports = { createServer, loadConfig, parseTodos, captionFor, localDate };
