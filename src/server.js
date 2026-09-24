import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID, randomBytes } from 'node:crypto';
import { loadRegistry, registryHash } from './registry.js';
import { trimState, RouteSession, THRESHOLDS, hash, redact } from './core.js';
import { route, streamCompletion } from './providers.js';
import { prepare, Executions } from './executor.js';
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export async function createApp({
  dataRoot = path.join(ROOT, '.skillrouter'),
  skillsRoot = path.join(ROOT, 'skills'),
} = {}) {
  await fs.mkdir(dataRoot, { recursive: true, mode: 0o700 });
  const skills = await loadRegistry(skillsRoot),
    active = skills.filter((s) => s.active),
    registry_hash = registryHash(skills);
  const log = async (event) => {
    const row = { id: randomUUID(), ts: new Date().toISOString(), ...event };
    await fs.appendFile(path.join(dataRoot, 'events.jsonl'), JSON.stringify(row) + '\n', { mode: 0o600 });
    return row;
  };
  // Snapshot the exact registry once so historical routes are reconstructible after edits.
  await fs.mkdir(path.join(dataRoot, 'registries'), { recursive: true });
  await fs.writeFile(
    path.join(dataRoot, 'registries', registry_hash + '.json'),
    JSON.stringify(skills, null, 2),
    { mode: 0o600 }
  );
  const executions = new Executions(path.join(dataRoot, 'output'), log),
    sessions = new Map();
  async function screens(state) {
    if (process.env.SCREENPIPE_ENABLED !== 'true' || state.screen_context === false || state.paused)
      return state;
    const url = new URL('/search', process.env.SCREENPIPE_URL || 'http://127.0.0.1:3030');
    url.searchParams.set('content_type', 'accessibility');
    url.searchParams.set('limit', '20');
    url.searchParams.set('start_time', new Date(Date.now() - 300000).toISOString());
    url.searchParams.set('end_time', new Date().toISOString());
    url.searchParams.set('max_content_length', '2000');
    url.searchParams.set(
      'fields',
      'content.timestamp,content.app_name,content.window_name,content.text,content.is_secure'
    );
    const options = {
      signal: AbortSignal.timeout(1200),
      headers: process.env.SCREENPIPE_API_KEY
        ? { Authorization: `Bearer ${process.env.SCREENPIPE_API_KEY}` }
        : {},
    };
    let r = await fetch(url, options);
    if (!r.ok) throw Error('Screenpipe unavailable; disable screen context or start Screenpipe.');
    let data = await r.json();
    if (!data.data?.length) {
      url.searchParams.set('content_type', 'ocr');
      r = await fetch(url, { ...options, signal: AbortSignal.timeout(1200) });
      if (!r.ok) throw Error('Screenpipe OCR lookup failed');
      data = await r.json();
    }
    state.screens = (data.data || []).map((x) => ({
      t: x.content?.timestamp,
      app: x.content?.app_name,
      window_title: x.content?.window_name,
      text: x.content?.text,
      secure: !!x.content?.is_secure,
    }));
    // OCR history is never assumed to be the active window. Only a host-supplied window is forwarded.
    return state;
  }
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
        sessions.set(token, {
          router: new RouteSession(),
          events: new Map(),
          created: Date.now(),
          revision: 0,
        });
        send(200, {
          token,
          mode: process.env.TYPESAFE_API_KEY ? 'live' : 'demo',
          executor: process.env.LLM_MODEL ? 'live' : 'demo',
          screenpipe: process.env.SCREENPIPE_ENABLED === 'true',
          skills: skills.map(({ slug, description, side_effect_class, context, active }) => ({
            slug,
            description,
            side_effect_class,
            context,
            active,
          })),
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
      if (!session || Date.now() - session.created > 86400000) {
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
          state = trimState(await screens(body.state || {})),
          start = performance.now();
        const output = await route(state, active, { signal: controller.signal });
        if (revision !== session.revision || controller.signal.aborted) {
          send(409, { error: 'Superseded route' });
          return;
        }
        session.screens = state.screens;
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
          registry_hash,
          thresholds_version: THRESHOLDS.version,
          jev_model: output.model,
          ready_p: output.ready,
          choice_distribution: output.distribution,
          set_size: active.length + 1,
          choice_slugs: active.map((s) => s.slug),
          shown_slugs: shown,
          action: 'none',
          latency_ms: performance.now() - start,
          token_usage: output.usage,
        });
        session.events.set(event.id, event);
        if (session.events.size > 100) session.events.delete(session.events.keys().next().value);
        send(200, {
          event_id: event.id,
          shown,
          mode: output.model === 'demo-rules-not-jev' ? 'demo' : 'live',
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
        session.router.dismiss(String(body.buffer || ''));
        await log({ type: 'interaction', routing_event_id: body.event_id, action: 'esc' });
        send(200, { ok: true });
        return;
      }
      if (url.pathname === '/api/prepare') {
        const event = session.events.get(body.event_id);
        if (!event || !event.shown_slugs.includes(body.skill))
          throw Error('Choose a currently offered skill');
        const skill = skills.find((s) => s.slug === body.skill);
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
        const prepared = await prepare(skill, acceptedState, body.fields || {});
        send(200, await executions.accept(prepared, event.id, sessionId));
        return;
      }
      if (url.pathname === '/api/confirm') {
        send(200, await executions.confirm(body.id, sessionId));
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
  server.listen(Number(process.env.PORT) || 4317, '127.0.0.1', () =>
    console.log(`SkillRouter: http://127.0.0.1:${server.address().port}`)
  );
}
