// The start page. State arrives embedded in the HTML (no flash of empty content), then refreshes itself.
// Everything is built with textContent and createElement: note text is never parsed as HTML.
(function () {
  'use strict';

  const { classifyInput, splitCode, greeting, formatClock, formatDate, safeHref } = HomepageLib;
  const state = JSON.parse(document.getElementById('state').textContent);
  const $ = (id) => document.getElementById(id);
  const el = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  };

  // todos ticked on this page stay visible (struck through) until the next reload, so a mis-click can be undone
  const keptVisible = new Set();
  const key = (file, todo) => `${file}\u0000${todo.text}`;

  // ---- header, credit -------------------------------------------------------------------

  function tick() {
    const now = new Date();
    $('clock').textContent = formatClock(now);
    $('date').textContent = formatDate(now);
    $('greeting').textContent = `${greeting(now)}, ${state.name}`;
  }

  // the picture itself is an <img> rendered by the server; only the caption is set here
  function showCredit(wallpaper) {
    if (wallpaper) $('credit').textContent = [wallpaper.text, wallpaper.credit].filter(Boolean).join(' · ');
  }

  // ---- search ------------------------------------------------------------------------------

  $('search').addEventListener('submit', (event) => {
    event.preventDefault();
    const target = classifyInput($('q').value);
    if (target) window.location.href = target.url;
  });

  // ---- bookmarks ---------------------------------------------------------------------------

  function renderLinks() {
    const nav = $('links');
    nav.replaceChildren();
    for (const bookmark of state.bookmarks) {
      const href = safeHref(bookmark.url);
      if (!href) continue;
      const a = el('a', 'chip', bookmark.title);
      a.href = href;
      a.rel = 'noopener noreferrer';
      a.title = href;
      nav.append(a);
    }
    nav.hidden = nav.children.length === 0;
  }

  // typing in the search box dims the bookmarks that do not match
  $('q').addEventListener('input', () => {
    const q = $('q').value.trim().toLowerCase();
    for (const chip of $('links').children) {
      chip.classList.toggle('dim', q !== '' && !chip.textContent.toLowerCase().includes(q));
    }
  });

  // ---- todos -------------------------------------------------------------------------------

  function setStatus(message) {
    $('status').textContent = message;
    if (message) setTimeout(() => { if ($('status').textContent === message) $('status').textContent = ''; }, 5000);
  }

  function visibleTodos(note) {
    return note.todos.filter((t) => !t.done || keptVisible.has(key(note.file, t)));
  }

  function groupLabel(note) {
    if (note.kind === 'today') return 'Today';
    return note.title;
  }

  async function post(path, body) {
    const response = await fetch(path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    const data = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(data.error || `request failed (${response.status})`);
    return data;
  }

  async function toggle(note, todo, checkbox, item) {
    const wanted = checkbox.checked;
    checkbox.disabled = true;
    try {
      await post('/api/todos/toggle', { file: note.file, line: todo.line, text: todo.text, done: wanted });
      todo.done = wanted;
      keptVisible.add(key(note.file, todo));
      item.classList.toggle('done', wanted);
      updateCount();
    } catch (error) {
      checkbox.checked = !wanted;
      setStatus(error.message);
    } finally {
      checkbox.disabled = false;
    }
  }

  function renderTodo(note, todo) {
    const item = el('li', todo.done ? 'done' : '');
    item.style.setProperty('--indent', String(todo.indent));
    const label = el('label');
    const checkbox = el('input');
    checkbox.type = 'checkbox';
    checkbox.checked = todo.done;
    checkbox.addEventListener('change', () => toggle(note, todo, checkbox, item));
    const text = el('span', 'text');
    for (const part of splitCode(todo.text)) text.append(part.code ? el('code', '', part.text) : document.createTextNode(part.text));
    label.append(checkbox, text);
    item.append(label);
    return item;
  }

  function renderTodos() {
    const root = $('todo-groups');
    root.replaceChildren();
    let shown = 0;
    for (const note of state.todos.notes) {
      const todos = visibleTodos(note);
      if (todos.length === 0 && note.kind !== 'today') continue;
      const group = el('section', 'group');
      group.append(el('h3', note.kind === 'today' ? 'today' : '', groupLabel(note)));
      const list = el('ul');
      for (const todo of todos) { list.append(renderTodo(note, todo)); shown += 1; }
      group.append(list);
      root.append(group);
    }
    if (shown === 0) root.append(el('p', 'empty', 'Nothing open. Add a todo above.'));
    updateCount();
  }

  function updateCount() {
    const open = state.todos.notes.reduce((n, note) => n + note.todos.filter((t) => !t.done).length, 0);
    $('todo-count').textContent = open ? `(${open})` : '';
  }

  $('add').addEventListener('submit', async (event) => {
    event.preventDefault();
    const input = $('add-text');
    const text = input.value.trim();
    if (!text) return;
    input.disabled = true;
    try {
      const result = await post('/api/todos/add', { text });
      let today = state.todos.notes.find((n) => n.kind === 'today');
      if (!today) {
        today = { file: result.file, title: result.file.replace(/\.md$/, ''), kind: 'today', todos: [] };
        state.todos.notes.unshift(today);
      }
      today.todos.push(result.todo);
      input.value = '';
      renderTodos();
    } catch (error) {
      setStatus(error.message);
    } finally {
      input.disabled = false;
      input.focus();
    }
  });

  async function refreshTodos() {
    try {
      const response = await fetch('/api/todos', { cache: 'no-store' });
      if (!response.ok) return;
      state.todos = await response.json();
      renderTodos();
    } catch { /* server restarting: try again next time */ }
  }

  document.addEventListener('visibilitychange', () => { if (!document.hidden) refreshTodos(); });
  setInterval(() => { if (!document.hidden) refreshTodos(); }, 60_000);

  // ---- keyboard ----------------------------------------------------------------------------

  document.addEventListener('keydown', (event) => {
    const typing = /^(INPUT|TEXTAREA)$/.test(document.activeElement.tagName);
    if (event.key === 'Escape') { document.activeElement.blur(); return; }
    if (typing || event.ctrlKey || event.metaKey || event.altKey) return;
    if (event.key === '/') { event.preventDefault(); $('q').focus(); }
    if (event.key === 'n') { event.preventDefault(); $('add-text').focus(); }
  });

  // ---- start -------------------------------------------------------------------------------

  tick();
  setInterval(tick, 10_000);
  showCredit(state.wallpaper);
  renderLinks();
  renderTodos();
})();
