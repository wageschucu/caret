import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createApp } from '../src/server.js';
test('HTTP flow protects local endpoints and binds previews to sessions', async (t) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'skillrouter-http-'));
  const server = await createApp({ dataRoot: root });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  t.after(async () => {
    await new Promise((r) => server.close(r));
    await fs.rm(root, { recursive: true, force: true });
  });
  const base = 'http://127.0.0.1:' + server.address().port;
  const boot = await (await fetch(base + '/api/bootstrap')).json();
  assert.equal(boot.skills.length, 8);
  const post = async (endpoint, body, headers = {}) => {
    const r = await fetch(base + '/api/' + endpoint, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-SkillRouter-Session': boot.token, ...headers },
      body: JSON.stringify(body),
    });
    return { status: r.status, data: await r.json() };
  };
  assert.equal((await post('route', {}, { Origin: 'https://evil.example' })).status, 403);
  assert.equal((await post('route', {}, { 'X-SkillRouter-Session': 'bad' })).status, 403);
  assert.equal((await fetch(base + '/src/server.js')).status, 404);
  const state = { buffer: 'schedule a meeting tomorrow', screen_context: false };
  const routed = await post('route', { state });
  assert.deepEqual(routed.data.shown, ['calendar-event']);
  const first = await post('prepare', { event_id: routed.data.event_id, skill: 'calendar-event' });
  assert.equal(first.data.status, 'preview');
  assert.deepEqual(first.data.missing_slots, ['title', 'start', 'end']);
  const updated = await post('prepare', {
    event_id: routed.data.event_id,
    skill: 'calendar-event',
    previous_preview: first.data.id,
    fields: { title: 'Integration test', start: '2026-10-01T10:00:00Z', end: '2026-10-01T11:00:00Z' },
  });
  assert.equal(updated.data.status, 'preview');
  assert.deepEqual(updated.data.missing_slots, []);
  await assert.rejects(fs.stat(path.join(root, 'output', 'calendar')));
  const confirmed = await post('confirm', { id: updated.data.id });
  assert.equal(confirmed.data.status, 'done');
  assert.equal((await post('confirm', { id: updated.data.id })).status, 400);
  assert.equal((await post('undo', { id: confirmed.data.undo_id })).data.status, 'undone');
  const log = (await fs.readFile(path.join(root, 'events.jsonl'), 'utf8')).trim().split('\n').map(JSON.parse);
  assert(log.some((e) => e.type === 'routing' && e.registry_hash && e.state_hash));
  assert(log.some((e) => e.type === 'execution' && e.confirmed && e.executed));
});
test('an unrecognised intent can be drafted, saved as a reviewed skill, and hot-reloaded', async (t) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'skillrouter-propose-'));
  const skillsRoot = path.join(root, 'skills');
  await fs.cp(new URL('../skills', import.meta.url).pathname, skillsRoot, { recursive: true });
  const server = await createApp({ dataRoot: root, skillsRoot });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  t.after(async () => {
    await new Promise((r) => server.close(r));
    await fs.rm(root, { recursive: true, force: true });
  });
  const base = 'http://127.0.0.1:' + server.address().port;
  const boot = await (await fetch(base + '/api/bootstrap')).json();
  const post = async (endpoint, body) => {
    const r = await fetch(base + '/api/' + endpoint, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-SkillRouter-Session': boot.token },
      body: JSON.stringify(body),
    });
    return { status: r.status, data: await r.json() };
  };
  // Demo rules abstain on this, but "ready" is only high when a demo pattern hits; feed the
  // proposal path through the router session directly instead.
  const first = await post('route', { state: { buffer: 'convert 30 dollars to euros please' } });
  assert.equal(first.data.propose, false);
  const draft = await post('propose', { event_id: first.data.event_id });
  assert.equal(draft.status, 200);
  assert.match(draft.data.markdown, /^---\nname: [a-z0-9-]+\n/);
  assert.match(draft.data.markdown, /trust: "reviewed"/);
  const saved = await post('skills', {
    markdown: draft.data.markdown.replace(/trust: "reviewed"/, 'trust: "trusted"'),
  });
  assert.equal(saved.status, 200, JSON.stringify(saved.data));
  assert.equal(saved.data.trust, 'reviewed'); // cannot self-elevate
  assert.equal((await post('skills', { markdown: draft.data.markdown })).status, 400); // duplicate
  const after = await (await fetch(base + '/api/bootstrap')).json();
  assert.equal(after.skills.length, boot.skills.length + 1);
  assert(after.skills.some((s) => s.slug === saved.data.slug));
  const history = (await fs.readFile(path.join(root, 'registry-history.jsonl'), 'utf8')).trim().split('\n');
  assert.equal(history.length, 2);
  assert.match(history[1], /"action":"add"/);
});
