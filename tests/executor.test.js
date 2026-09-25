import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { Executions, validatePlan } from '../src/executor.js';
import { permission } from '../src/core.js';
const make = (effect, tool, args) => {
  const skill = {
    slug: 'test',
    version: '1',
    trust: 'trusted',
    side_effect_class: effect,
    allowed_tools: [tool],
  };
  return {
    skill,
    gate: permission(skill),
    context: { buffer: 'test' },
    plan: { preview: 'Review', missing_slots: [], calls: [{ tool, args }] },
  };
};
async function setup(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'skillrouter-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const logs = [];
  return { root, logs, exec: new Executions(root, async (e) => logs.push(e)) };
}
test('send-class action cannot execute before preview and single-use confirmation', async (t) => {
  const { exec, root, logs } = await setup(t),
    p = make('sends-or-pays', 'calendar.create', {
      title: 'Review',
      start: '2026-10-01T10:00:00Z',
      end: '2026-10-01T11:00:00Z',
    });
  const r = await exec.accept(p, 'route', 'session');
  assert.equal(r.status, 'preview');
  await assert.rejects(fs.stat(path.join(root, 'calendar')));
  await assert.rejects(exec.confirm(r.id, 'other'));
  const outcomes = await Promise.allSettled([exec.confirm(r.id, 'session'), exec.confirm(r.id, 'session')]);
  assert.equal(outcomes.filter((x) => x.status === 'fulfilled').length, 1);
  assert.equal((await fs.readdir(path.join(root, 'calendar'))).length, 1);
  assert.equal(logs.at(-1).confirmed, true);
});
test('missing slots, cancel and expiry cannot execute', async (t) => {
  const { exec } = await setup(t),
    p = make('destructive', 'text.result', { text: 'done' });
  p.plan.missing_slots = ['target'];
  const r = await exec.accept(p, 'route', 'session');
  await assert.rejects(exec.confirm(r.id, 'session'));
  exec.cancel(r.id, 'session');
  await assert.rejects(exec.confirm(r.id, 'session'));
  const r2 = await exec.accept({ ...p, plan: { ...p.plan, missing_slots: [] } }, 'route', 'session');
  exec.pending.get(r2.id).created = 0;
  await assert.rejects(exec.confirm(r2.id, 'session'));
});
test('file save executes once, never overwrites and undo checks unchanged content', async (t) => {
  const { exec, root } = await setup(t),
    p = make('reversible', 'file.save', { filename: 'notes.md', content: 'hello' });
  const r = await exec.accept(p, 'route', 'session');
  assert.equal(r.status, 'done');
  await assert.rejects(exec.accept(p, 'route', 'session'));
  await fs.writeFile(path.join(root, 'files', 'notes.md'), 'user edit');
  await assert.rejects(exec.undo(r.undo_id, 'session'));
  await fs.writeFile(path.join(root, 'files', 'notes.md'), 'hello');
  await exec.undo(r.undo_id, 'session');
  await assert.rejects(fs.stat(path.join(root, 'files', 'notes.md')));
});
test('tool validation blocks undeclared calls, traversal and invalid calendar dates', () => {
  const p = make('preview-only', 'text.result', { text: 'ok' });
  assert.throws(() =>
    validatePlan({ ...p.plan, calls: [{ tool: 'shell.exec', args: { cmd: 'anything' } }] }, p.gate)
  );
  assert.throws(() =>
    validatePlan(
      { ...p.plan, calls: [{ tool: 'file.save', args: { filename: '../escape', content: 'x' } }] },
      { tools: ['file.save'] }
    )
  );
  assert.throws(() =>
    validatePlan(
      {
        ...p.plan,
        calls: [{ tool: 'calendar.create', args: { title: 'x', start: 'not a date', end: 'tomorrow' } }],
      },
      { tools: ['calendar.create'] }
    )
  );
});
test('windows reserved device names are rejected as filenames', () => {
  const gate = permission({
    trust: 'trusted',
    side_effect_class: 'reversible',
    allowed_tools: ['file.save'],
  });
  for (const filename of ['con', 'NUL.txt', 'com1.md'])
    assert.throws(() =>
      validatePlan(
        { preview: 'x', missing_slots: [], calls: [{ tool: 'file.save', args: { filename, content: 'x' } }] },
        gate
      )
    );
  validatePlan(
    {
      preview: 'x',
      missing_slots: [],
      calls: [{ tool: 'file.save', args: { filename: 'console.md', content: 'x' } }],
    },
    gate
  );
});
test('host-executed tools are gated, consumed once, and reported back', async (t) => {
  const { exec, logs } = await setup(t);
  const prepared = make('sends-or-pays', 'calendar.create', {
    title: 'Review',
    start: '2026-10-01T10:00:00Z',
    end: '2026-10-01T11:00:00Z',
  });
  const preview = await exec.accept(prepared, 'route-1', 's1');
  assert.equal(preview.status, 'preview');
  const handoff = await exec.confirm(preview.id, 's1', ['calendar.create']);
  assert.equal(handoff.status, 'host_execute');
  assert.equal(handoff.call.tool, 'calendar.create');
  await assert.rejects(exec.confirm(preview.id, 's1', ['calendar.create']));
  await assert.rejects(exec.hostExecuted(handoff.id, 'other-session', { ok: true }));
  assert.equal((await exec.hostExecuted(handoff.id, 's1', { ok: true })).status, 'done');
  assert.equal((await exec.hostExecuted(handoff.id, 's1', { undone: true })).status, 'undone');
  assert(logs.some((e) => e.host_executed && e.executed && !e.undone));
  assert(logs.some((e) => e.host_executed && e.undone));
  // A tool the host does not claim still runs locally.
  const local = await exec.accept(
    make('sends-or-pays', 'calendar.create', prepared.plan.calls[0].args),
    'r2',
    's1'
  );
  assert.equal((await exec.confirm(local.id, 's1', [])).status, 'done');
});
test('preview-free host tools are handed off at accept; unclaimed ones run locally', async (t) => {
  const { exec, logs } = await setup(t);
  const open = make('preview-only', 'url.open', { url: 'https://www.google.com/search?q=keyboards' });
  const handoff = await exec.accept(open, 'r1', 's1', ['url.open']);
  assert.equal(handoff.status, 'host_execute');
  assert.equal(handoff.call.args.url, 'https://www.google.com/search?q=keyboards');
  assert.equal((await exec.hostExecuted(handoff.id, 's1', { ok: true })).status, 'done');
  const local = await exec.accept(make('preview-only', 'url.open', open.plan.calls[0].args), 'r2', 's1', []);
  assert.equal(local.status, 'done');
  assert.equal(local.result, 'https://www.google.com/search?q=keyboards');
  const draft = await exec.accept(
    make('reversible', 'mail.draft', { to: '', subject: 'Hi', body: 'Hello there' }),
    'r3',
    's1',
    []
  );
  assert.match(draft.result, /^To: \nSubject: Hi\n\nHello there$/);
  // A tool that needs confirmation is never handed off at accept.
  const event = make('sends-or-pays', 'calendar.create', {
    title: 'x',
    start: '2026-10-01T10:00:00Z',
    end: '2026-10-01T11:00:00Z',
  });
  assert.equal((await exec.accept(event, 'r4', 's1', ['calendar.create'])).status, 'preview');
  assert(logs.some((e) => e.host_executed && !e.confirmed && e.executed));
});
test('url.open and mail.draft arguments are validated', () => {
  const gate = permission({
    trust: 'trusted',
    side_effect_class: 'preview-only',
    allowed_tools: ['url.open', 'mail.draft'],
  });
  assert.throws(() =>
    validatePlan(
      {
        preview: 'x',
        missing_slots: [],
        calls: [{ tool: 'url.open', args: { url: 'javascript:alert(1)' } }],
      },
      gate
    )
  );
  assert.throws(() =>
    validatePlan(
      { preview: 'x', missing_slots: [], calls: [{ tool: 'mail.draft', args: { subject: 'x', body: '' } }] },
      gate
    )
  );
  validatePlan(
    {
      preview: 'x',
      missing_slots: [],
      calls: [{ tool: 'mail.draft', args: { to: 'a@b.c', subject: 'x', body: 'y' } }],
    },
    gate
  );
});
test('a mail recipient the user never stated is dropped', async () => {
  const { prepare } = await import('../src/executor.js');
  const old = process.env.LLM_MODEL;
  delete process.env.LLM_MODEL; // demo executor
  try {
    const skill = {
      slug: 'draft-email',
      trust: 'trusted',
      side_effect_class: 'reversible',
      allowed_tools: ['mail.draft'],
      context: ['buffer'],
      body: '',
      version: '1',
    };
    const { plan } = await prepare(
      skill,
      { buffer: 'draft an email thanking the team' },
      {},
      { name: 'Pat' }
    );
    assert.equal(plan.calls[0].args.to, '');
    assert.match(plan.calls[0].args.body, /Pat/);
  } finally {
    if (old !== undefined) process.env.LLM_MODEL = old;
  }
});
test('currency hints parse symbols, codes, words and home currencies', async () => {
  const { currencyHints } = await import('../src/executor.js');
  assert.deepEqual(currencyHints('250chf in euros'), { amount: '250', from: 'CHF', to: 'EUR' });
  assert.deepEqual(currencyHints('convert $40', {}, { currencies: 'CHF, USD' }), {
    amount: '40',
    from: 'USD',
    to: 'CHF',
  });
  assert.deepEqual(currencyHints('how much is 1,200 eur', {}, { currencies: 'EUR, CHF' }), {
    amount: '1200',
    from: 'EUR',
    to: 'CHF',
  });
  assert.deepEqual(currencyHints('500chf', { to: 'GBP' }), { amount: '500', from: 'CHF', to: 'GBP' });
  assert.deepEqual(currencyHints('nothing here'), {});
});
test('a fully parsed currency request never calls the model', async () => {
  const { prepare } = await import('../src/executor.js');
  const old = process.env.LLM_MODEL;
  process.env.LLM_MODEL = 'model-that-does-not-exist';
  try {
    const skill = {
      slug: 'currency-converter',
      trust: 'trusted',
      side_effect_class: 'preview-only',
      allowed_tools: ['fx.convert'],
      context: ['buffer'],
      body: '',
      version: '1',
    };
    const { plan } = await prepare(skill, { buffer: '250chf in euros' }, {}, {});
    assert.deepEqual(plan.calls[0], { tool: 'fx.convert', args: { amount: 250, from: 'CHF', to: 'EUR' } });
  } finally {
    if (old === undefined) delete process.env.LLM_MODEL;
    else process.env.LLM_MODEL = old;
  }
});
