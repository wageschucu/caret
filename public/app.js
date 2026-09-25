const $ = (id) => document.getElementById(id),
  editor = $('editor');
let token,
  skills = [],
  chips = [],
  chosen = 0,
  ghost = '',
  eventId = null,
  revision = 0,
  boundary = 0,
  debounce,
  routeController,
  completionController,
  preview = null,
  busy = false,
  lastTyped = 0,
  composition = false,
  mode = 'demo',
  slotAnswers = {};
const label = (slug) => skills.find((s) => s.slug === slug)?.label || slug;
async function api(endpoint, body = {}, signal) {
  const r = await fetch('/api/' + endpoint, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-SkillRouter-Session': token },
    body: JSON.stringify(body),
    signal,
  });
  // Planning streams progress lines (NDJSON) before its final object; other endpoints answer once.
  const text = await r.text();
  const lines = text
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  for (const line of lines) if (line.progress) notice(line.progress + '…');
  const data = lines.at(-1) || {};
  if (!r.ok || data.error) throw Error(data.error || 'Request failed');
  return data;
}
function notice(text = '') {
  $('notice').textContent = text;
}
function telemetry(action, extra = {}) {
  api('telemetry', { action, event_id: eventId, ...extra }).catch(() => {});
}
function state() {
  return {
    buffer: editor.value,
    active_app: $('active-app').value,
    window_title: 'Your space to think',
    selection: $('selection-context').value,
    focused_window: $('window-context').value,
    paused: $('paused').checked,
    deny_apps: $('deny-apps')
      .value.split(',')
      .map((s) => s.trim())
      .filter(Boolean),
    screens: [],
  };
}
function binding() {
  return $('tab-safe').checked ? 'Tab' : 'Ctrl Space';
}
function render() {
  editor.readOnly = busy || !!preview;
  $('mirror-text').textContent = editor.value;
  $('ghost').textContent = ghost;
  $('ghost').classList.toggle('dimmed', chips.length > 0);
  editor.style.height = '145px';
  editor.style.height = editor.scrollHeight + 'px';
  $('mode').textContent = busy ? 'WORKING ON IT' : chips.length ? 'AN ACTION IN REACH' : 'READY WHEN YOU ARE';
  $('accept-key').textContent = binding();
  $('chips').replaceChildren();
  chips.forEach((slug, i) => {
    const button = document.createElement('button');
    button.className = 'chip' + (i === chosen ? ' selected' : '');
    button.textContent = label(slug) + ' ↗';
    button.setAttribute('aria-pressed', String(i === chosen));
    const key = document.createElement('kbd');
    key.textContent = binding();
    button.append(key);
    button.onclick = () => {
      chosen = i;
      accept();
    };
    $('chips').append(button);
  });
}
async function requestRoute(v) {
  routeController?.abort();
  routeController = new AbortController();
  try {
    const r = await api('route', { state: state(), boundary }, routeController.signal);
    if (v !== revision || preview) return;
    chips = r.shown;
    chosen = 0;
    eventId = r.event_id;
    render();
    if (chips.length) telemetry('chip_rendered', { latency_ms: performance.now() - lastTyped });
  } catch (e) {
    if (e.name !== 'AbortError' && v === revision) {
      chips = [];
      render();
      notice(e.message);
    }
  }
}
async function input() {
  if (composition) return;
  const v = ++revision;
  lastTyped = performance.now();
  clearTimeout(debounce);
  routeController?.abort();
  completionController?.abort();
  ghost = '';
  if (!editor.value.trim()) {
    chips = [];
    eventId = null;
  }
  render();
  notice();
  if (!editor.value.trim()) {
    api('dismiss', { buffer: '', event_id: eventId }).catch(() => {});
    return;
  }
  completionController = new AbortController();
  (editor.selectionStart === editor.value.length
    ? streamGhost(v, completionController.signal)
    : Promise.resolve()
  ).catch((e) => {
    if (e.name !== 'AbortError' && v === revision) notice(e.message);
  });
  if (/[.!?;:\n]$/.test(editor.value)) {
    boundary++;
    requestRoute(v);
  } else debounce = setTimeout(() => requestRoute(v), 300);
}
async function streamGhost(v, signal) {
  const response = await fetch('/api/complete', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-SkillRouter-Session': token },
    body: JSON.stringify({ state: state() }),
    signal,
  });
  if (!response.ok) throw Error('Completer unavailable');
  const reader = response.body.getReader(),
    decoder = new TextDecoder();
  let pending = '',
    shown = false;
  while (true) {
    const chunk = await reader.read();
    if (chunk.done) break;
    pending += decoder.decode(chunk.value, { stream: true });
    let end;
    while ((end = pending.indexOf('\n')) >= 0) {
      const line = pending.slice(0, end);
      pending = pending.slice(end + 1);
      if (!line) continue;
      const result = JSON.parse(line);
      if (v !== revision || preview || editor.selectionStart !== editor.value.length) return;
      if (result.error) throw Error(result.error);
      ghost = result.text || '';
      render();
      if (ghost && !shown) {
        shown = true;
        telemetry('ghost_shown');
      }
      if (result.phrase_boundary) {
        boundary++;
        clearTimeout(debounce);
        requestRoute(v);
      }
    }
  }
}
function insertGhost(wordOnly = false) {
  if (!ghost) return;
  const text = wordOnly ? ghost.match(/^\s*\S+\s*/)?.[0] || ghost : ghost;
  editor.value += text;
  ghost = ghost.slice(text.length);
  telemetry(wordOnly ? 'ctrl_right' : 'ghost_accepted');
  input();
  editor.focus();
  editor.setSelectionRange(editor.value.length, editor.value.length);
}
async function accept() {
  if (busy || preview) return;
  if (!chips.length) {
    insertGhost();
    return;
  }
  const skill = chips[chosen];
  if (!skill || !eventId) return;
  busy = true;
  clearTimeout(debounce);
  routeController?.abort();
  completionController?.abort();
  revision++;
  ghost = '';
  render();
  try {
    await showResult(await api('prepare', { event_id: eventId, skill, accepted_buffer: editor.value }));
  } catch (e) {
    notice(e.message);
  } finally {
    busy = false;
    render();
  }
}
function element(tag, text, cls) {
  const e = document.createElement(tag);
  if (text !== undefined) e.textContent = text;
  if (cls) e.className = cls;
  return e;
}
async function showResult(r) {
  const panel = $('result');
  panel.hidden = false;
  panel.replaceChildren();
  chips = [];
  ghost = '';
  panel.append(element('h2', r.status === 'preview' ? 'A quick look before we continue.' : 'All set.'));
  if (r.demo) panel.append(element('p', 'Demo result · Limited examples, with local actions only.', 'muted'));
  if (r.status === 'preview') {
    preview = { ...r, event_id: eventId };
    panel.append(element('pre', r.preview));
    for (const call of r.calls) {
      panel.append(element('pre', call.tool + '\n' + JSON.stringify(call.args, null, 2), 'exact-action'));
    }
    for (const name of r.missing_slots) {
      const label = element('label', name);
      const field = element('input');
      field.className = 'slot-field';
      field.name = name;
      field.autocomplete = 'off';
      if (name === 'start' || name === 'end') field.placeholder = '2026-09-23T10:00:00-05:00';
      label.append(field);
      panel.append(label);
    }
    const go = element(
      'button',
      r.missing_slots.length ? 'Update preview' : r.requires_confirmation ? 'Confirm action' : 'Continue'
    );
    go.id = 'confirm-action';
    go.onclick = submitPreview;
    const cancel = element('button', 'Cancel · Esc', 'secondary');
    cancel.onclick = cancelPreview;
    panel.append(go, cancel);
    panel.querySelector('input,button')?.focus();
  } else {
    preview = null;
    panel.append(element('pre', r.result));
    if (/^https:\/\/www.google.com\/search\?q=/.test(r.result)) {
      const a = element('a', 'Open search ↗');
      a.href = r.result;
      a.target = '_blank';
      a.rel = 'noopener noreferrer';
      panel.append(a);
    }
    if (r.undo_id) {
      const undo = element('button', 'Undo', 'secondary');
      undo.onclick = async () => {
        try {
          await api('undo', { id: r.undo_id });
          panel.replaceChildren(element('h2', 'Undone.'));
        } catch (e) {
          notice(e.message);
        }
      };
      panel.append(undo);
    }
    editor.focus();
  }
  render();
}
async function submitPreview() {
  if (!preview || busy) return;
  busy = true;
  const p = preview;
  const button = $('confirm-action');
  button.disabled = true;
  try {
    if (p.missing_slots.length) {
      const fields = {
        ...slotAnswers,
        ...Object.fromEntries([...$('result').querySelectorAll('input')].map((i) => [i.name, i.value])),
      };
      slotAnswers = fields;
      if (Object.values(fields).some((x) => !x.trim())) throw Error('Fill in each missing detail.');
      await showResult(
        await api('prepare', {
          event_id: p.event_id,
          skill: p.skill,
          fields,
          accepted_buffer: editor.value,
          previous_preview: p.id,
        })
      );
    } else await showResult(await api('confirm', { id: p.id }));
  } catch (e) {
    notice(e.message);
  } finally {
    busy = false;
    if (button.isConnected) button.disabled = false;
    render();
  }
}
async function cancelPreview() {
  if (busy) return;
  const p = preview;
  preview = null;
  slotAnswers = {};
  if (p) await api('cancel', { id: p.id }).catch(() => {});
  $('result').hidden = true;
  editor.focus();
  render();
}
editor.addEventListener('input', () => input());
editor.addEventListener('compositionstart', () => {
  composition = true;
  clearTimeout(debounce);
  completionController?.abort();
  routeController?.abort();
  revision++;
  ghost = '';
  chips = [];
  render();
});
editor.addEventListener('compositionend', () => {
  composition = false;
  input();
});
editor.addEventListener('click', () => {
  if (editor.selectionStart !== editor.value.length) {
    ghost = '';
    render();
  }
});
document.addEventListener('keydown', (e) => {
  if ($('library').open || e.isComposing) return;
  if (e.key === 'Escape') {
    if (preview) {
      e.preventDefault();
      cancelPreview();
      return;
    }
    if (document.activeElement === editor) {
      e.preventDefault();
      revision++;
      clearTimeout(debounce);
      routeController?.abort();
      completionController?.abort();
      api('dismiss', { buffer: editor.value, event_id: eventId }).catch(() => {});
      chips = [];
      ghost = '';
      render();
    }
    return;
  }
  if (preview) {
    if (
      (e.key === 'Enter' && $('result').contains(document.activeElement)) ||
      (e.key === 'Tab' && !e.shiftKey && !preview.missing_slots.length)
    ) {
      e.preventDefault();
      submitPreview();
    }
    return;
  }
  if (document.activeElement !== editor) return;
  const acceptKey = $('tab-safe').checked ? e.key === 'Tab' && !e.shiftKey : e.code === 'Space' && e.ctrlKey;
  if (acceptKey && (chips.length || ghost)) {
    e.preventDefault();
    accept();
  } else if (e.key === 'ArrowRight' && (e.ctrlKey || e.altKey) && ghost) {
    e.preventDefault();
    insertGhost(true);
  } else if (['ArrowUp', 'ArrowDown'].includes(e.key) && chips.length) {
    e.preventDefault();
    chosen = (chosen + (e.key === 'ArrowDown' ? 1 : -1) + chips.length) % chips.length;
    render();
    telemetry('cycle');
  }
});
for (const b of document.querySelectorAll('[data-example]'))
  b.onclick = async () => {
    if (busy) return;
    await cancelPreview();
    editor.value = b.dataset.example;
    editor.focus();
    input();
  };
$('context-toggle').onclick = () => {
  $('context-panel').hidden = !$('context-panel').hidden;
};
for (const el of $('context-panel').querySelectorAll('input,textarea'))
  el.addEventListener('change', () => {
    cancelPreview();
    input();
  });
$('library-button').onclick = () => $('library').showModal();
$('close-library').onclick = () => $('library').close();
try {
  const boot = await (await fetch('/api/bootstrap')).json();
  token = boot.token;
  skills = boot.skills;
  mode = boot.mode;
  $('connection').textContent = mode === 'demo' ? '● Local demo' : '● Jev connected';
  notice(
    mode === 'demo'
      ? 'Demo mode · Set model credentials in .env for live routing and generation.'
      : boot.executor === 'demo'
        ? 'Jev routing is live; executor is in demo mode.'
        : ''
  );
  if (boot.problems?.length) notice('Skipped invalid skills: ' + boot.problems.join(' · '));
  for (const skill of skills) {
    const card = element('article', undefined, 'skill-card');
    card.append(
      element('h3', skill.label),
      element('p', skill.description),
      element(
        'small',
        skill.side_effect_class === 'preview-only'
          ? 'Returns a result'
          : skill.side_effect_class === 'reversible'
            ? 'Can be undone'
            : 'Preview & confirm'
      )
    );
    $('skill-list').append(card);
  }
  render();
} catch (e) {
  notice('Could not connect to the local helper: ' + e.message);
}
