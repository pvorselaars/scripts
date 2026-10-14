// The note view: a note rendered read-only, with todos you can still tick, and what links to it.
// A small markdown subset (headings, lists, todos, quotes, code blocks, links, bold, [[wiki links]]),
// built with createElement and textContent only: note text is never parsed as HTML.
(function () {
  'use strict';

  const { renderInline, slug } = HomepageLib;
  const state = JSON.parse(document.getElementById('state').textContent);
  const $ = (id) => document.getElementById(id);
  const el = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  };

  let note = state.note;
  const knownNames = () => new Set(note.names.map((n) => n.toLowerCase()));

  // ---- markdown subset -> blocks ------------------------------------------------------------

  const TODO = /^(\s*)- \[([ xX])\] (.*?)(\r?)$/s;
  const BULLET = /^(\s*)[-*+]\s+(.*)$/;
  const NUMBERED = /^(\s*)(\d+)[.)]\s+(.*)$/;
  const HEADING = /^(#{1,6})\s+(.*)$/;
  const QUOTE = /^>\s?(.*)$/;

  function parseBlocks(content) {
    const blocks = [];
    const lines = content.split('\n');
    let paragraph = null;
    let fence = null;
    const endParagraph = () => { paragraph = null; };

    lines.forEach((raw, index) => {
      const line = raw.replace(/\r$/, '');
      if (fence) {
        if (/^```/.test(line)) { blocks.push({ type: 'code', text: fence.join('\n') }); fence = null; } else fence.push(line);
        return;
      }
      if (/^```/.test(line)) { endParagraph(); fence = []; return; }
      if (line.trim() === '') { endParagraph(); return; }

      let m;
      if ((m = HEADING.exec(line))) { endParagraph(); blocks.push({ type: 'heading', level: Math.min(m[1].length, 4), text: m[2] }); return; }
      if ((m = TODO.exec(raw))) { endParagraph(); blocks.push({ type: 'todo', line: index + 1, text: m[3], done: m[2] !== ' ', indent: Math.floor(m[1].length / 2) }); return; }
      if ((m = BULLET.exec(line))) { endParagraph(); blocks.push({ type: 'bullet', text: m[2], indent: Math.floor(m[1].length / 2) }); return; }
      if ((m = NUMBERED.exec(line))) { endParagraph(); blocks.push({ type: 'numbered', n: m[2], text: m[3], indent: Math.floor(m[1].length / 2) }); return; }
      if ((m = QUOTE.exec(line))) {
        const last = blocks[blocks.length - 1];
        if (last && last.type === 'quote' && paragraph) last.text += ` ${m[1]}`;
        else { blocks.push({ type: 'quote', text: m[1] }); paragraph = true; }
        return;
      }
      if (paragraph && blocks[blocks.length - 1].type === 'paragraph') blocks[blocks.length - 1].text += ` ${line.trim()}`;
      else { blocks.push({ type: 'paragraph', text: line.trim() }); paragraph = true; }
    });
    if (fence) blocks.push({ type: 'code', text: fence.join('\n') });
    return blocks;
  }

  // ---- todos --------------------------------------------------------------------------------

  function setStatus(message) {
    $('status').textContent = message;
    if (message) setTimeout(() => { if ($('status').textContent === message) $('status').textContent = ''; }, 5000);
  }

  async function toggle(block, checkbox, item) {
    const wanted = checkbox.checked;
    checkbox.disabled = true;
    try {
      const response = await fetch('/api/todos/toggle', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ file: note.file, line: block.line, text: block.text, done: wanted }),
      });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(data.error || `request failed (${response.status})`);
      block.done = wanted;
      item.classList.toggle('done', wanted);
    } catch (error) {
      checkbox.checked = !wanted;
      setStatus(error.message);
    } finally {
      checkbox.disabled = false;
    }
  }

  function todoItem(block, names) {
    const item = el('li', block.done ? 'done' : '');
    item.style.setProperty('--indent', String(block.indent));
    const label = el('label');
    const checkbox = el('input');
    checkbox.type = 'checkbox';
    checkbox.checked = block.done;
    checkbox.addEventListener('change', () => toggle(block, checkbox, item));
    const text = el('span', 'text');
    renderInline(document, text, block.text, names);
    label.append(checkbox, text);
    item.append(label);
    return item;
  }

  // ---- render -------------------------------------------------------------------------------

  function render() {
    const names = knownNames();
    $('note-title').textContent = note.name;
    document.title = note.name;

    const article = $('note');
    article.replaceChildren();

    if (!note.exists) {
      article.append(el('p', 'empty', `There is no note called “${note.name}” yet.`));
    } else {
      const used = new Set();
      let list = null;
      let listKind = null;
      const into = (kind) => {
        if (listKind !== kind) { list = el(kind === 'numbered' ? 'ol' : 'ul'); article.append(list); listKind = kind; }
        return list;
      };
      for (const block of parseBlocks(note.content)) {
        if (block.type !== 'todo' && block.type !== 'bullet' && block.type !== 'numbered') { list = null; listKind = null; }
        if (block.type === 'heading') {
          const h = el(`h${Math.min(block.level + 1, 5)}`);
          renderInline(document, h, block.text, names);
          let id = slug(block.text) || 'section';
          for (let n = 1; used.has(id); n += 1) id = `${slug(block.text) || 'section'}-${n}`;
          used.add(id);
          h.id = id;
          article.append(h);
        } else if (block.type === 'todo') {
          into('bullet').append(todoItem(block, names));
        } else if (block.type === 'bullet' || block.type === 'numbered') {
          const li = el('li');
          li.style.setProperty('--indent', String(block.indent));
          renderInline(document, li, block.text, names);
          into(block.type).append(li);
        } else if (block.type === 'quote') {
          const q = el('blockquote');
          renderInline(document, q, block.text, names);
          article.append(q);
        } else if (block.type === 'code') {
          const pre = el('pre');
          pre.append(el('code', '', block.text));
          article.append(pre);
        } else {
          const p = el('p');
          renderInline(document, p, block.text, names);
          article.append(p);
        }
      }
      if (article.children.length === 0) article.append(el('p', 'empty', 'This note is empty.'));
    }

    const list = $('backlink-list');
    list.replaceChildren();
    for (const back of note.backlinks) {
      const item = el('li');
      const link = el('a', 'wiki', back.name);
      link.href = HomepageLib.noteHref(back.name);
      item.append(link);
      const snippet = el('span', 'snippet');
      // show the sentence, not the markdown around it (list and todo markers, quotes, heading hashes)
      const sentence = back.snippets[0].replace(/^\s*(?:[-*+]\s+(?:\[[ xX]\]\s+)?|>\s*|#{1,6}\s+)/, '');
      renderInline(document, snippet, sentence, names);
      item.append(snippet);
      list.append(item);
    }
    $('backlinks').hidden = note.backlinks.length === 0;
  }

  async function refresh() {
    try {
      const response = await fetch(`/api/note/${encodeURIComponent(note.name)}`, { cache: 'no-store' });
      if (!response.ok) return;
      note = await response.json();
      render();
    } catch { /* server restarting */ }
  }

  document.addEventListener('visibilitychange', () => { if (!document.hidden) refresh(); });
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && !event.ctrlKey && !event.metaKey && !event.altKey) window.location.href = '/';
  });

  if (state.wallpaper) $('credit').textContent = [state.wallpaper.text, state.wallpaper.credit].filter(Boolean).join(' · ');
  render();

  // [[note#heading]] opens at the heading
  const target = decodeURIComponent((window.location.hash || '').slice(1));
  const heading = target && $(target);
  if (heading && heading.scrollIntoView) heading.scrollIntoView();
})();
