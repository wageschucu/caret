// Interactive labeling of real routing events into the eval set.
//
//   npm run label            label live-Jev events not yet in eval/states.jsonl
//   npm run label -- --all   include demo-rule events too
//
// For each distinct sentence (the final buffer of a typing burst) the script shows what Caret
// offered and what the user did, proposes a label (the accepted skill, else the shown skill, else
// NO_ROUTE), and appends the state with its recorded probabilities so the eval can replay it offline.
import fs from 'node:fs/promises';
import readline from 'node:readline/promises';
import { stdin, stdout } from 'node:process';
import { loadRegistry, registryHash } from '../src/registry.js';

const EVENTS = '.skillrouter/events.jsonl',
  DATASET = 'eval/states.local.jsonl'; // real sentences stay out of the repository
const all = process.argv.includes('--all');
const skills = (await loadRegistry('skills')).filter((s) => s.active),
  slugs = skills.map((s) => s.slug);
const rows = (await fs.readFile(EVENTS, 'utf8')).split('\n').filter(Boolean).map(JSON.parse);
const existing = (await fs.readFile(DATASET, 'utf8').catch(() => ''))
  .split('\n')
  .filter(Boolean)
  .map(JSON.parse);
const labeled = new Set(existing.map((r) => r.state.buffer.trim()));

const routing = rows.filter((r) => r.type === 'routing' && (all || r.jev_model !== 'demo-rules-not-jev'));
const byId = new Map(routing.map((r) => [r.id, r]));
const accepted = new Map(),
  dismissed = new Set();
for (const r of rows) {
  if (r.type === 'interaction' && r.action === 'tab' && r.routing_event_id)
    accepted.set(r.routing_event_id, r.skill);
  if (r.type === 'interaction' && r.action === 'esc' && r.routing_event_id) dismissed.add(r.routing_event_id);
}
// Keep the last event of each typing burst: the next event's buffer does not extend this one.
const candidates = [];
const seen = new Set();
for (let i = 0; i < routing.length; i++) {
  const buffer = routing[i].state.buffer.trim(),
    next = routing[i + 1]?.state.buffer.trim() ?? '';
  if (!buffer || next.startsWith(buffer) || seen.has(buffer) || labeled.has(buffer)) continue;
  if (buffer.split(/\s+/).length < 2) continue; // single words carry no labelable intent
  seen.add(buffer);
  candidates.push(routing[i]);
}
if (!candidates.length) {
  console.log('Nothing new to label.');
  process.exit(0);
}
console.log(
  `${candidates.length} sentence(s) to label. Enter = accept suggestion, a skill name, "n" = NO_ROUTE, "s" = skip, "q" = quit.\n`
);
const rl = readline.createInterface({ input: stdin, output: stdout });
let added = 0;
for (const event of candidates) {
  const shown = event.shown_slugs || [],
    took = accepted.get(event.id);
  const suggestion = took || shown[0] || 'NO_ROUTE';
  console.log(`— ${event.state.active_app || 'unknown app'} · ${event.ts.slice(0, 16).replace('T', ' ')}`);
  console.log(`  "${event.state.buffer.trim().slice(0, 160)}"`);
  console.log(
    `  offered: ${shown.length ? shown.join(', ') : 'nothing'}${took ? ` · accepted: ${took}` : dismissed.has(event.id) ? ' · dismissed' : ''}`
  );
  let answer = (await rl.question(`  label [${suggestion}]: `)).trim();
  if (answer === 'q') break;
  if (answer === 's') continue;
  if (answer === '') answer = suggestion;
  if (answer === 'n') answer = 'NO_ROUTE';
  if (answer !== 'NO_ROUTE' && !slugs.includes(answer)) {
    console.log(`  unknown skill "${answer}"; skipped. Skills: ${slugs.join(', ')}`);
    continue;
  }
  const row = {
    id: `real-${event.id.slice(0, 8)}`,
    state: { buffer: event.state.buffer, active_app: event.state.active_app },
    label: answer,
    language: /[^\u0000-ɏ]/.test(event.state.buffer) ? 'other' : 'en',
    source: 'real',
    ready_p: event.ready_p,
    choice_distribution: event.choice_distribution,
    jev_model: event.jev_model,
    registry_hash: event.registry_hash,
    labeled_at: new Date().toISOString(),
  };
  await fs.appendFile(DATASET, JSON.stringify(row) + '\n');
  added++;
}
rl.close();
console.log(
  `\nAdded ${added} labeled state(s) to ${DATASET}. Registry hash now: ${registryHash(skills).slice(0, 12)}…`
);
console.log(
  'Replay offline: npm run eval    Re-evaluate against the current registry: npm run eval -- --live'
);
