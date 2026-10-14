'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { start, request } = require('./helpers.js');
const { captionFor } = require('../server.js');

test('wallpaper: serves only listed images, with the right type', async () => {
  const s = await start({ wallpapers: { 'one.png': 'PNGDATA', 'two.jpg': 'JPGDATA', 'notes.txt': 'not an image' } });
  try {
    const pick = (await request(s.port, { path: '/api/wallpaper' })).json;
    assert.match(pick.url, /^\/wallpaper\/(one\.png|two\.jpg)$/);
    const img = await request(s.port, { path: pick.url });
    assert.equal(img.status, 200);
    assert.equal(img.headers['content-type'], pick.url.endsWith('png') ? 'image/png' : 'image/jpeg');
    assert.match(img.text, /^(PNGDATA|JPGDATA)$/);
    assert.equal((await request(s.port, { path: '/wallpaper/notes.txt' })).status, 404);
    assert.equal((await request(s.port, { path: '/wallpaper/missing.png' })).status, 404);
    for (const p of ['/wallpaper/../one.png', '/wallpaper/%2e%2e%2fone.png', '/wallpaper/sub/one.png', '/wallpaper/..%2f..%2fetc%2fpasswd']) {
      assert.equal((await request(s.port, { path: p })).status, 404, p);
    }
  } finally { s.close(); }
});

test('wallpaper: no images gives null; names turn into readable captions', async () => {
  const s = await start();
  try { assert.equal((await request(s.port, { path: '/api/wallpaper' })).json, null); } finally { s.close(); }
  assert.deepEqual(captionFor('apod-2026-october-23-andromeda-in-southern-spring.jpg'),
    { text: 'Andromeda in southern spring', credit: 'NASA APOD, 23 Oct 2026' });
  assert.deepEqual(captionFor('spacex-wallhaven-qzxrxq.jpg'), { text: 'SpaceX', credit: '' });
  assert.deepEqual(captionFor('417994.jpg'), { text: '', credit: '' });
});

// ---- one background, stable ----

const pickFrom = async (s) => (await request(s.port, { path: '/api/wallpaper' })).json.url;
const images = (n) => Object.fromEntries(Array.from({ length: n }, (_, i) => [`img${String(i).padStart(2, '0')}.jpg`, 'x']));

test('the background is one image, the same on every page, tab and reload', async () => {
  const s = await start({ wallpapers: images(8), notes: { 'x.md': 'x\n' } });
  try {
    const pick = await pickFrom(s);
    const embedded = async (p) => JSON.parse(/<script id="state" type="application\/json">([\s\S]*?)<\/script>/.exec((await request(s.port, { path: p })).text)[1]).wallpaper.url;
    for (let i = 0; i < 15; i += 1) {
      assert.equal(await pickFrom(s), pick, 'API');
      assert.equal(await embedded('/'), pick, 'home page');
      assert.equal(await embedded('/note/x'), pick, 'note view (navigating must not change the background)');
    }
    const html = (await request(s.port, { path: '/note/x' })).text;
    assert.ok(html.includes(`<img id="bg" alt="" src="${pick}">`), 'and the <img> in the page is that one');
  } finally { s.close(); }
});

test('it changes from one day to the next', async () => {
  let day = new Date(2026, 9, 1, 12);
  const s = await start({ wallpapers: images(6), now: () => day });
  try {
    const picks = new Set();
    for (let i = 0; i < 20; i += 1) { day = new Date(2026, 9, 1 + i, 12); picks.add(await pickFrom(s)); }
    assert.ok(picks.size >= 3, `20 days gave only ${picks.size} different images`);
    // and within one day, the time does not matter
    day = new Date(2026, 9, 5, 0, 1); const morning = await pickFrom(s);
    day = new Date(2026, 9, 5, 23, 59); assert.equal(await pickFrom(s), morning);
  } finally { s.close(); }
});

test('adding wallpapers during the day almost never changes the pick', async () => {
  let day = new Date(2026, 0, 1, 12);
  const s = await start({ wallpapers: images(30), now: () => day });
  try {
    const before = [];
    for (let i = 0; i < 60; i += 1) { day = new Date(2026, 0, 1 + i, 12); before.push(await pickFrom(s)); }
    fs.writeFileSync(path.join(s.cfg.wallpaperDir, 'new-arrival.jpg'), 'x');
    let changed = 0;
    for (let i = 0; i < 60; i += 1) { day = new Date(2026, 0, 1 + i, 12); if ((await pickFrom(s)) !== before[i]) changed += 1; }
    assert.ok(changed <= 6, `${changed} of 60 days changed after adding one image to 30 (expected about 2)`);
  } finally { s.close(); }
});

test('a pinned wallpaper is used every day; an unknown pin is ignored', async () => {
  let day = new Date(2026, 9, 1, 12);
  const s = await start({ wallpapers: images(6), now: () => day, wallpaper: 'img03.jpg' });
  try {
    for (let i = 0; i < 10; i += 1) { day = new Date(2026, 9, 1 + i, 12); assert.equal(await pickFrom(s), '/wallpaper/img03.jpg'); }
  } finally { s.close(); }
  const t = await start({ wallpapers: images(3), wallpaper: 'missing.jpg' });
  try { assert.match(await pickFrom(t), /^\/wallpaper\/img0[0-2]\.jpg$/); } finally { t.close(); }
});
