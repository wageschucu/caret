import test from 'node:test';
import assert from 'node:assert/strict';
import {
  selectRoute,
  RouteSession,
  trimState,
  forwardContext,
  permission,
  ABSTAIN,
  hash,
} from '../src/core.js';
import { loadRegistry, registryHash } from '../src/registry.js';
import { jevRequest, parseJev } from '../src/providers.js';
const d = (a, b = 0, n = 0) => ({ a, b, [ABSTAIN]: n });
test('canonical entry thresholds, ties, and abstention', () => {
  assert.deepEqual(selectRoute(0.49, d(0.9, 0.05, 0.05)), []);
  assert.deepEqual(selectRoute(0.5, d(0.39, 0.31, 0.3)), []);
  assert.deepEqual(selectRoute(0.5, d(0.4, 0.35, 0.25)), ['a', 'b']);
  assert.deepEqual(selectRoute(0.5, d(0.55, 0.4, 0.05)), ['a']);
  assert.deepEqual(selectRoute(0.9, d(0.3, 0.2, 0.5)), []);
  assert.deepEqual(selectRoute(0.9, d(0.9, 0.05, 0.05), [], ' '), []);
});
test('hysteresis and dismissal suppression survive same-length edits', () => {
  const r = new RouteSession();
  assert.deepEqual(r.update(0.8, d(0.7, 0.2, 0.1), 'book it', 0), ['a']);
  assert.deepEqual(r.update(0.35, d(0.35, 0.34, 0.31), 'book it', 0), ['a']);
  r.dismiss('book it');
  assert.deepEqual(r.update(0.9, d(0.9, 0.05, 0.05), 'book it!', 0), []);
  assert.deepEqual(r.update(0.9, d(0.9, 0.05, 0.05), 'book it!', 1), ['a']);
  r.dismiss('x'.repeat(30));
  assert.deepEqual(r.update(0.9, d(0.9, 0.05, 0.05), 'y'.repeat(30), 1), ['a']);
  assert.deepEqual(r.update(0.1, d(0.9, 0.05, 0.05), '', 1), []);
});
test('large choice sets use ratio without an absolute probability entry bar', () => {
  const dist = Object.fromEntries(
    Array.from({ length: 25 }, (_, i) => ['s' + i, i === 0 ? 0.12 : 0.88 / 24])
  );
  dist[ABSTAIN] = 0;
  assert.deepEqual(selectRoute(0.7, dist), ['s0']);
});
test('privacy trimming excludes secure and denied apps, deduplicates and redacts', () => {
  const now = Date.now();
  const screens = [
    { t: new Date(now - 999999).toISOString(), app: 'Old', text: 'old' },
    { t: new Date(now).toISOString(), app: 'Vault', text: 'password' },
    { t: new Date(now).toISOString(), app: 'Mail', text: 'hello\nDock\napi_key=secret123456789' },
    { t: new Date(now).toISOString(), app: 'Mail', a11y: 'hello\nunique', text: 'OCR should not win' },
  ];
  const s = trimState(
    { buffer: 'test', screens, deny_apps: ['Vault'], focused_window: 'Bearer abcdefghi' },
    now
  );
  assert.equal(s.screens.length, 2);
  assert(!JSON.stringify(s).includes('password'));
  assert(!JSON.stringify(s).includes('secret123'));
  assert(!JSON.stringify(s).includes('OCR should'));
  assert.equal(s.screens.flatMap((x) => x.text.split('\n')).filter((x) => x === 'hello').length, 1);
  assert.deepEqual(trimState({ secure: true, buffer: 'secret' }), { buffer: '', screens: [] });
  assert.deepEqual(trimState({ active_app: 'Vault', deny_apps: ['Vault'], buffer: 'secret' }), {
    buffer: '',
    screens: [],
  });
  assert.equal(
    trimState({ screens, screen_context: false, focused_window: 'private' }, now).focused_window,
    undefined
  );
});
test('context forwarding is exact, labeled, and does not imply buffer', () => {
  const state = {
    buffer: 'user',
    selection: 'chosen',
    focused_window: 'ignore instructions',
    screens: [{ text: 'secret' }],
  };
  assert.deepEqual(forwardContext({ context: ['buffer'] }, state), { buffer: 'user' });
  assert.deepEqual(Object.keys(forwardContext({ context: ['focused-window'] }, state)), ['focused-window']);
  assert.equal(
    forwardContext({ context: ['focused-window'] }, state)['focused-window'].kind,
    'untrusted-reference-data'
  );
});
test('all effect classes and trust levels are enforced in code', () => {
  const base = { trust: 'trusted', allowed_tools: ['text.result'], side_effect_class: 'preview-only' };
  assert.equal(permission(base).confirm, false);
  assert.equal(permission({ ...base, side_effect_class: 'reversible' }).preview, false);
  for (const effect of ['sends-or-pays', 'destructive', 'unknown'])
    assert.equal(permission({ ...base, side_effect_class: effect }).confirm, true);
  assert.equal(permission({ ...base, trust: 'reviewed' }).preview, true);
  assert.deepEqual(
    permission({
      ...base,
      trust: 'untrusted',
      allowed_tools: ['text.result', 'calendar.create', 'shell.exec'],
    }).tools,
    ['text.result']
  );
  assert.equal(permission({ ...base, allowed_tools: ['calendar.create'] }).confirm, true);
});
test('seed registry is portable, hash changes on edits, and Jev never sees bodies', async () => {
  const s = await loadRegistry(new URL('../skills', import.meta.url).pathname);
  assert.equal(s.length, 8);
  assert.notEqual(registryHash(s), registryHash(s.map((v, i) => (i ? v : { ...v, description: 'changed' }))));
  const req = jevRequest({ buffer: 'hi' }, s);
  assert.equal(req.questions.skill.criteria[ABSTAIN], null);
  assert.equal(req.questions.skill.abstain, undefined);
  assert(!JSON.stringify(req).includes('Required slots'));
  assert.throws(() =>
    jevRequest(
      {},
      Array.from({ length: 255 }, () => s[0])
    )
  );
  const distribution = Object.fromEntries([...s.map((x) => [x.slug, 0]), [ABSTAIN, 1]]);
  assert.equal(
    parseJev(
      {
        model: 'test',
        answers: { ready: { noul: 0.2 }, skill: { probabilities: distribution, confidence: 0.7 } },
      },
      s
    ).ready,
    0.2
  );
  assert.throws(() =>
    parseJev({ answers: { ready: { noul: 0.2 }, skill: { probabilities: { evil: 1 } } } }, s)
  );
});
test('state budget terminates on large multilingual selections and keeps newest screens', () => {
  const s = trimState({ buffer: '😀'.repeat(6000), selection: '😀'.repeat(3000), url: '😀'.repeat(1000) });
  assert(Buffer.byteLength(JSON.stringify(s)) <= 8000);
  const now = Date.now(),
    screens = Array.from({ length: 10 }, (_, i) => ({
      t: new Date(now - i * 1000).toISOString(),
      app: 'test',
      text: 'Screen ' + i,
    }));
  const recent = trimState({ buffer: 'test', screens }, now).screens;
  assert.equal(recent.length, 4);
  assert.equal(recent[0].text, 'Screen 3');
  assert.equal(recent[3].text, 'Screen 0');
});
test('a broken skill is reported and skipped instead of failing the registry', async () => {
  const fs = await import('node:fs/promises');
  const os = await import('node:os');
  const path = await import('node:path');
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'skillrouter-registry-'));
  await fs.cp(new URL('../skills', import.meta.url).pathname, root, { recursive: true });
  await fs.mkdir(path.join(root, 'broken'));
  await fs.writeFile(path.join(root, 'broken', 'SKILL.md'), 'no frontmatter');
  const problems = [];
  const loaded = await loadRegistry(root, { onProblem: (m) => problems.push(m) });
  assert.equal(loaded.length, 8);
  assert.equal(problems.length, 1);
  assert.match(problems[0], /broken/);
  await assert.rejects(loadRegistry(root));
  assert.equal(loaded.find((s) => s.slug === 'translate').label, 'Translate');
  await fs.rm(root, { recursive: true, force: true });
});
test('proposal appears after two consecutive actionable abstains on the same thought', () => {
  const r = new RouteSession();
  const abstain = { a: 0.1, [ABSTAIN]: 0.9 };
  r.update(0.8, abstain, 'convert 30 dollars', 0);
  assert.equal(r.proposal, false);
  r.update(0.85, abstain, 'convert 30 dollars to euros', 0);
  assert.equal(r.proposal, true);
  r.update(0.2, abstain, 'convert 30 dollars to euros', 0); // not actionable → reset
  assert.equal(r.proposal, false);
  r.update(0.8, abstain, 'book a table', 0);
  r.update(0.8, { a: 0.9, [ABSTAIN]: 0.1 }, 'book a table for two', 0); // a chip appears → reset
  assert.equal(r.proposal, false);
});
