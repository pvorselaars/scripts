'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { start, request, tempDir, makePlaces } = require('./helpers.js');
const { readBookmarks, captionFor } = require('../server.js');

test('bookmarks: titles, urls, sorted, deduplicated, folders and place: queries skipped', async () => {
  const profile = tempDir('profile-');
  makePlaces(profile, [
    ['Zeta', 'https://zeta.example/'], ['alpha', 'https://alpha.example/'], ['Alpha again', 'https://alpha.example/'],
    ['A folder', 'https://folder.example/', 2], ['Smart', 'place:sort=8&maxResults=10'], ['', 'https://untitled.example/page'],
    ['Local file', 'file:///etc/passwd'], ['JS', 'javascript:alert(1)'],
  ]);
  const s = await start({ profile });
  try {
    const r = await request(s.port, { path: '/api/bookmarks' });
    assert.deepEqual(r.json, [
      { title: 'alpha', url: 'https://alpha.example/' },
      { title: 'untitled.example', url: 'https://untitled.example/page' },
      { title: 'Zeta', url: 'https://zeta.example/' },
    ]);
  } finally { s.close(); fs.rmSync(profile, { recursive: true, force: true }); }
});

test('bookmarks: reads a copy, so the live database is never modified', async () => {
  const profile = tempDir('profile-');
  makePlaces(profile, [['One', 'https://one.example/']]);
  const file = path.join(profile, 'places.sqlite');
  const before = fs.readFileSync(file);
  try {
    assert.equal(readBookmarks(file).length, 1);
    assert.ok(before.equals(fs.readFileSync(file)));
    assert.deepEqual(fs.readdirSync(profile).sort(), ['places.sqlite']);
  } finally { fs.rmSync(profile, { recursive: true, force: true }); }
});

test('bookmarks: a missing or broken profile gives an empty list, not an error', async () => {
  assert.deepEqual(readBookmarks(null), []);
  assert.deepEqual(readBookmarks('/nonexistent/places.sqlite'), []);
  const s = await start();
  try { assert.deepEqual((await request(s.port, { path: '/api/bookmarks' })).json, []); } finally { s.close(); }
});

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
