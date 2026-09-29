import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID, randomBytes } from 'node:crypto';
import { loadRegistry, registryHash, parseSkill } from './registry.js';
import { trimState, RouteSession, THRESHOLDS, ABSTAIN, hash, redact } from './core.js';
import {
  route,
  streamCompletion,
  draftSkill,
  keepModelsWarm,
  applyLocalDefaults,
  detectedDefaults,
  hostedExecutorProblem,
} from './providers.js';
import { prepare, Executions } from './executor.js';
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const SESSION_TTL = 86400000;
export async function createApp({
  dataRoot = path.join(ROOT, '.skillrouter'),
  skillsRoot = path.join(ROOT, 'skills'),
} = {}) {
  await fs.mkdir(dataRoot, { recursive: true, mode: 0o700 });
  const problems = [];
  // The registry is mutable: skills can be added at runtime and are hot-reloaded.
  const registry = { skills: [], active: [], hash: '' };
  async function reloadRegistry(action = 'load', slug = null) {
    problems.length = 0;
    registry.skills = await loadRegistry(skillsRoot, { onProblem: (m) => problems.push(m) });
    registry.active = registry.skills.filter((s) => s.active);
    registry.hash = registryHash(registry.skills);
    // Snapshot the exact registry so historical routes are reconstructible after edits.
    await fs.mkdir(path.join(dataRoot, 'registries'), { recursive: true });
    await fs.writeFile(
      path.join(dataRoot, 'registries', registry.hash + '.json'),
      JSON.stringify(registry.skills, null, 2),
      { mode: 0o600 }
    );
    await fs.appendFile(
      path.join(dataRoot, 'registry-history.jsonl'),
      JSON.stringify({
        ts: new Date().toISOString(),
        action,
        slug,
        registry_hash: registry.hash,
        count: registry.active.length,
      }) + '\n',
      { mode: 0o600 }
    );
  }
  await reloadRegistry();
  const eventsFile = path.join(dataRoot, 'events.jsonl');
  const log = async (event) => {
    const row = { id: randomUUID(), ts: new Date().toISOString(), ...event };
    // Rotate once the log passes 5 MB; routing states are logged on every pause in typing.
    const size = (await fs.stat(eventsFile).catch(() => ({ size: 0 }))).size;
    if (size > 5 * 1024 * 1024)
      await fs.rename(eventsFile, eventsFile.replace(/\.jsonl$/, `.${row.ts.replace(/[:.]/g, '-')}.jsonl`));
    await fs.appendFile(eventsFile, JSON.stringify(row) + '\n', { mode: 0o600 });
    return row;
  };
  for (const p of problems) console.warn('Skill skipped: ' + p);
  const executions = new Executions(path.join(dataRoot, 'output'), log),
    sessions = new Map();
  // A trigger counts only for what is being typed now: the match must end at the caret (trailing
  // space or punctuation allowed), not somewhere earlier in the paragraph.
  const triggerAtCaret = (trigger, buffer) => {
    const tail = buffer.slice(-60),
      end = tail.replace(/[\s.,;:!?)]+$/, '').length;
    return [...tail.matchAll(new RegExp(trigger.source, 'gi'))].some((m) => m.index + m[0].length >= end);
  };
  // Tools a native host may perform itself; anything else always runs here.
  const HOST_PERFORMABLE = ['calendar.create', 'url.open', 'mail.draft'];
  const hostToolsOf = (body) =>
    Array.isArray(body.host_tools) ? body.host_tools.filter((t) => HOST_PERFORMABLE.includes(t)) : [];
  // Set when TypeSafe rejects the key: routing falls back to demo rules (always labeled as such) until restart.
  let jevAuthError = null;
  const server = http.createServer(async (req, res) => {
    const send = (status, value) => {
      res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
      res.end(JSON.stringify(value));
    };
    try {
      const host = req.headers.host,
        expected = new Set([`127.0.0.1:${server.address().port}`, `localhost:${server.address().port}`]);
      if (!expected.has(host)) {
        send(403, { error: 'Invalid host' });
        return;
      }
      if (req.headers.origin && !new Set([...expected].map((h) => 'http://' + h)).has(req.headers.origin)) {
        send(403, { error: 'Cross-origin request denied' });
        return;
      }
      res.setHeader(
        'Content-Security-Policy',
        "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
      );
      res.setHeader('X-Content-Type-Options', 'nosniff');
      const url = new URL(req.url, 'http://' + host);
      if (req.method === 'GET' && url.pathname === '/api/bootstrap') {
        const token = randomBytes(32).toString('hex');
        for (const [id, s] of sessions) if (Date.now() - s.created > SESSION_TTL) sessions.delete(id);
        sessions.set(token, {
          router: new RouteSession(),
          events: new Map(),
          created: Date.now(),
          revision: 0,
        });
        send(200, {
          token,
          mode: process.env.TYPESAFE_API_KEY && !jevAuthError ? 'live' : 'demo',
          executor: process.env.LLM_MODEL ? 'live' : 'demo',
          executor_model: process.env.LLM_MODEL || null,
          completer_model: process.env.COMPLETER_MODEL || process.env.LLM_MODEL || null,
          detected_models: detectedDefaults,
          executor_fallback: hostedExecutorProblem,
          warning: jevAuthError,
          problems,
          skills: registry.skills.map(
            ({
              slug,
              label,
              description,
              side_effect_class,
              context,
              active,
              variants,
              variant_slot,
              styles,
              style_slot,
              allowed_tools,
            }) => ({
              slug,
              label,
              description,
              side_effect_class,
              context,
              active,
              variants,
              variant_slot,
              styles,
              style_slot,
              allowed_tools,
            })
          ),
        });
        return;
      }
      if (req.method === 'GET') {
        const allowed = { '/': 'index.html', '/app.js': 'app.js', '/style.css': 'style.css' };
        const file = allowed[url.pathname];
        if (!file) {
          send(404, { error: 'Not found' });
          return;
        }
        res.writeHead(200, {
          'Content-Type': file.endsWith('.js')
            ? 'text/javascript'
            : file.endsWith('.css')
              ? 'text/css'
              : 'text/html',
          'Cache-Control': 'no-store',
        });
        res.end(await fs.readFile(path.join(ROOT, 'public', file)));
        return;
      }
      const sessionId = req.headers['x-skillrouter-session'],
        session = sessions.get(sessionId);
      if (!session || Date.now() - session.created > SESSION_TTL) {
        send(403, { error: 'Reload to start a new session' });
        return;
      }
      if (req.method !== 'POST' || !String(req.headers['content-type']).startsWith('application/json')) {
        send(415, { error: 'JSON POST required' });
        return;
      }
      let raw = '';
      for await (const chunk of req) {
        raw += chunk;
        if (raw.length > 100000) throw Error('Request too large');
      }
      const body = JSON.parse(raw || '{}');
      const controller = new AbortController();
      res.on('close', () => {
        if (!res.writableEnded) controller.abort();
      });
      if (url.pathname === '/api/route') {
        const revision = ++session.revision,
          state = trimState(body.state || {}),
          start = performance.now();
        let output;
        try {
          output = await route(state, registry.active, { signal: controller.signal, live: !jevAuthError });
        } catch (e) {
          if (e.code !== 'jev_auth') throw e;
          jevAuthError = e.message;
          console.warn(e.message + ' Routing uses demo rules until then.');
          output = await route(state, registry.active, { live: false });
        }
        if (revision !== session.revision || controller.signal.aborted) {
          send(409, { error: 'Superseded route' });
          return;
        }
        session.screens = state.screens;
        // Deterministic triggers: a skill's pattern matched, so offer it regardless of "ready".
        const triggered = registry.active
          .filter((s) => s.trigger && triggerAtCaret(s.trigger, state.buffer))
          .map((s) => s.slug);
        if (triggered.length) {
          output = {
            ...output,
            ready: Math.max(output.ready, 0.95),
            distribution: { ...output.distribution },
          };
          for (const slug of triggered)
            output.distribution[slug] = Math.max(output.distribution[slug] || 0, 0.9);
          output.distribution[ABSTAIN] = Math.min(output.distribution[ABSTAIN] || 0, 0.05);
          const total = Object.values(output.distribution).reduce((a, b) => a + b, 0);
          for (const k in output.distribution) output.distribution[k] /= total;
        }
        const shown = session.router.update(
          output.ready,
          output.distribution,
          state.buffer,
          body.boundary || 0
        );
        const event = await log({
          type: 'routing',
          state,
          state_hash: hash(state),
          state_tokens: Math.ceil(Buffer.byteLength(JSON.stringify(state)) / 3),
          state_tokens_estimated: true,
          registry_hash: registry.hash,
          thresholds_version: THRESHOLDS.version,
          jev_model: output.model,
          ready_p: output.ready,
          choice_distribution: output.distribution,
          set_size: registry.active.length + 1,
          choice_slugs: registry.active.map((s) => s.slug),
          shown_slugs: shown,
          triggered,
          action: 'none',
          latency_ms: performance.now() - start,
          token_usage: output.usage,
        });
        session.events.set(event.id, event);
        if (session.events.size > 100) session.events.delete(session.events.keys().next().value);
        send(200, {
          event_id: event.id,
          shown,
          propose: session.router.proposal,
          mode: output.model === 'demo-rules-not-jev' ? 'demo' : 'live',
          warning: jevAuthError,
        });
        return;
      }
      if (url.pathname === '/api/complete') {
        res.writeHead(200, { 'Content-Type': 'application/x-ndjson', 'Cache-Control': 'no-store' });
        try {
          for await (const chunk of streamCompletion(
            trimState({ ...body.state, screens: session.screens || [] }),
            controller.signal
          )) {
            res.write(JSON.stringify(chunk) + '\n');
          }
        } catch (e) {
          res.write(JSON.stringify({ error: redact(e.message) }) + '\n');
        }
        res.end();
        return;
      }
      if (url.pathname === '/api/dismiss') {
        ++session.revision;
        const acted = Array.isArray(body.skills)
          ? body.skills.filter((x) => typeof x === 'string').slice(0, 5)
          : [];
        session.router.dismiss(String(body.buffer || ''), acted);
        await log({
          type: 'interaction',
          routing_event_id: body.event_id,
          action: acted.length ? 'acted' : 'esc',
        });
        send(200, { ok: true });
        return;
      }
      if (url.pathname === '/api/prepare') {
        const event = session.events.get(body.event_id);
        if (!event || !event.shown_slugs.includes(body.skill))
          throw Error('Choose a currently offered skill');
        const skill = registry.skills.find((s) => s.slug === body.skill);
        if (body.previous_preview) executions.cancel(body.previous_preview, sessionId);
        if (!body.previous_preview)
          await log({ type: 'interaction', routing_event_id: event.id, skill: skill.slug, action: 'tab' });
        const acceptedState = {
          ...event.state,
          buffer: redact(body.accepted_buffer ?? event.state.buffer).slice(0, 6000),
        };
        await log({
          type: 'acceptance',
          routing_event_id: event.id,
          state: acceptedState,
          state_hash: hash(acceptedState),
        });
        // Facts the user entered about themselves; used by the executor only, never logged or routed.
        const profile = Object.fromEntries(
          Object.entries(body.profile || {})
            .filter(
              ([k, v]) =>
                ['name', 'email', 'signature', 'notes', 'currencies'].includes(k) &&
                typeof v === 'string' &&
                v.trim()
            )
            .map(([k, v]) => [k, v.slice(0, 500)])
        );
        // Lookup results the host already obtained for this accept (host-side lookups).
        const lookups = (Array.isArray(body.lookups) ? body.lookups : [])
          .filter((l) => l && typeof l.tool === 'string' && l.args && typeof l.args === 'object')
          .slice(0, 3)
          .map((l) => ({ tool: l.tool, args: l.args, result: String(l.result ?? '').slice(0, 6000) }));
        // Streamed: progress lines while planning, then exactly one final object.
        res.writeHead(200, { 'Content-Type': 'application/x-ndjson', 'Cache-Control': 'no-store' });
        const emit = (obj) => res.write(JSON.stringify(obj) + '\n');
        try {
          const prepared = await prepare(
            skill,
            acceptedState,
            body.fields || {},
            profile,
            lookups,
            (text) => emit({ progress: text }),
            { forceFinal: body.final === true, signal: controller.signal }
          );
          if (controller.signal.aborted) throw Object.assign(Error('Cancelled'), { name: 'AbortError' });
          if (prepared.needs) {
            await log({
              type: 'interaction',
              routing_event_id: event.id,
              action: 'lookup',
              lookups: prepared.needs.map((n) => n.tool),
            });
            emit({ status: 'needs', skill: skill.slug, lookups: prepared.needs, obtained: prepared.lookups });
          } else {
            emit(await executions.accept(prepared, event.id, sessionId, hostToolsOf(body)));
          }
        } catch (e) {
          if (controller.signal.aborted) {
            // The user pressed Esc while planning: nothing is executed or shown.
            await log({ type: 'interaction', routing_event_id: event.id, skill: skill.slug, action: 'cancel' });
            res.end();
            return;
          }
          emit({ error: redact(e.message) });
        }
        res.end();
        return;
        return;
      }
      if (url.pathname === '/api/debug') {
        // The one place probabilities are shown: this session's recent routing decisions.
        const recent = [...session.events.values()]
          .slice(-25)
          .reverse()
          .map((e) => ({
            ts: e.ts,
            buffer: e.state.buffer,
            app: e.state.active_app,
            ready_p: e.ready_p,
            distribution: Object.entries(e.choice_distribution)
              .sort((a, b) => b[1] - a[1])
              .slice(0, 5),
            shown: e.shown_slugs,
            latency_ms: Math.round(e.latency_ms),
            model: e.jev_model,
            registry_hash: e.registry_hash.slice(0, 8),
          }));
        const history = (
          await fs.readFile(path.join(dataRoot, 'registry-history.jsonl'), 'utf8').catch(() => '')
        )
          .trim()
          .split('\n')
          .filter(Boolean)
          .map(JSON.parse)
          .slice(-20)
          .reverse();
        send(200, { thresholds: THRESHOLDS, registry_hash: registry.hash, recent, history });
        return;
      }
      if (url.pathname === '/api/registry/rollback') {
        // Restore every skill file from a recorded snapshot. Skills added since are moved aside,
        // never deleted.
        const target = String(body.registry_hash || '');
        if (!/^[a-f0-9]{64}$/.test(target)) throw Error('Choose a registry version');
        const snapshot = JSON.parse(
          await fs.readFile(path.join(dataRoot, 'registries', target + '.json'), 'utf8')
        );
        if (!snapshot.every((s) => typeof s.raw === 'string'))
          throw Error('This snapshot predates rollback support');
        const keep = new Set(snapshot.map((s) => s.slug));
        const aside = path.join(dataRoot, 'trash', new Date().toISOString().replace(/[:.]/g, '-'));
        for (const s of registry.skills)
          if (!keep.has(s.slug)) {
            await fs.mkdir(aside, { recursive: true });
            await fs.rename(path.join(skillsRoot, s.slug), path.join(aside, s.slug));
          }
        for (const s of snapshot) {
          await fs.mkdir(path.join(skillsRoot, s.slug), { recursive: true });
          await fs.writeFile(path.join(skillsRoot, s.slug, 'SKILL.md'), s.raw);
        }
        await reloadRegistry('rollback', target.slice(0, 8));
        await log({ type: 'registry', action: 'rollback', to: target, registry_hash: registry.hash });
        send(200, { registry_hash: registry.hash, skills: registry.active.length, moved_aside: aside });
        return;
      }
      if (url.pathname === '/api/propose') {
        // Draft a new skill from an unrecognised intent. Nothing is saved until /api/skills.
        const event = session.events.get(body.event_id);
        if (!event) throw Error('Choose a current sentence');
        const draft = await draftSkill(
          event.state.buffer,
          registry.skills.map((s) => s.slug)
        );
        await log({ type: 'interaction', routing_event_id: event.id, action: 'propose' });
        send(200, draft);
        return;
      }
      if (url.pathname === '/api/skills') {
        // Save a user-authored skill. Trust is forced to "reviewed": preview and confirm until the
        // user edits the file to say otherwise. The registry reloads immediately.
        const markdown = String(body.markdown || '');
        const name = markdown.match(/^---[\s\S]*?\nname:\s*"?([a-z0-9-]+)"?/)?.[1];
        if (!name) throw Error('The skill needs a name of lowercase letters, digits and dashes');
        if (registry.skills.some((s) => s.slug === name)) throw Error(`A skill named ${name} already exists`);
        const reviewed = markdown.replace(/(\n\s*trust:\s*)"?[a-z]+"?/, '$1"reviewed"');
        const parsed = parseSkill(
          reviewed.includes('trust:')
            ? reviewed
            : reviewed.replace(/\nmetadata:\n/, '\nmetadata:\n  trust: "reviewed"\n'),
          name
        );
        const folder = path.join(skillsRoot, name);
        await fs.mkdir(folder, { recursive: true });
        const handle = await fs.open(path.join(folder, 'SKILL.md'), 'wx', 0o644);
        try {
          await handle.writeFile(
            reviewed.includes('trust:')
              ? reviewed
              : reviewed.replace(/\nmetadata:\n/, '\nmetadata:\n  trust: "reviewed"\n')
          );
        } finally {
          await handle.close();
        }
        await reloadRegistry('add', name);
        await log({ type: 'registry', action: 'add', skill: name, registry_hash: registry.hash });
        send(200, {
          slug: parsed.slug,
          label: parsed.label,
          trust: parsed.trust,
          registry_hash: registry.hash,
        });
        return;
      }
      if (url.pathname === '/api/confirm') {
        const hostTools = Array.isArray(body.host_tools)
          ? body.host_tools.filter((t) => t === 'calendar.create')
          : [];
        send(200, await executions.confirm(body.id, sessionId, hostTools));
        return;
      }
      if (url.pathname === '/api/host-executed') {
        send(200, await executions.hostExecuted(body.id, sessionId, body));
        return;
      }
      if (url.pathname === '/api/cancel') {
        executions.cancel(body.id, sessionId);
        send(200, { ok: true });
        return;
      }
      if (url.pathname === '/api/undo') {
        send(200, await executions.undo(body.id, sessionId));
        return;
      }
      if (url.pathname === '/api/telemetry') {
        if (!['ghost_shown', 'ghost_accepted', 'cycle', 'ctrl_right', 'chip_rendered'].includes(body.action))
          throw Error('Invalid telemetry action');
        await log({
          type: 'interaction',
          action: body.action,
          routing_event_id: body.event_id,
          latency_ms: Number.isFinite(body.latency_ms) ? body.latency_ms : null,
        });
        send(200, { ok: true });
        return;
      }
      send(404, { error: 'Not found' });
    } catch (e) {
      if (!res.headersSent) send(400, { error: redact(e.message) });
      else res.end();
    }
  });
  return server;
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const server = await createApp();
  // Empty model settings are filled from the models Ollama already has; nothing is downloaded.
  const local = await applyLocalDefaults();
  if (Object.keys(local.filled).length)
    console.log(
      'Using local models Ollama already has: ' +
        Object.entries(local.filled)
          .map(([k, v]) => `${k}=${v}`)
          .join(', ') +
        '. Set them in .env to choose differently.'
    );
  const roles = { COMPLETER_MODEL: 'ghost text', LLM_MODEL: 'the executor' };
  const stillDemo = local.wanted.filter((k) => !local.filled[k] && roles[k]).map((k) => roles[k]);
  if (stillDemo.length && local.reachable !== null)
    console.warn(
      (local.reachable ? 'Ollama has no chat models pulled' : 'Ollama is not running') +
        `; ${stillDemo.join(' and ')} ${stillDemo.length > 1 ? 'stay' : 'stays'} in demo mode. ` +
        'Pull a model (see README) or set the model in .env.'
    );
  keepModelsWarm();
  server.listen(Number(process.env.PORT) || 4317, '127.0.0.1', () =>
    console.log(`SkillRouter: http://127.0.0.1:${server.address().port}`)
  );
}
