'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
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
