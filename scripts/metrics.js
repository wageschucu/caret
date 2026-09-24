import fs from 'node:fs/promises';
const file = process.argv[2] || '.skillrouter/events.jsonl';
const rows = (await fs.readFile(file, 'utf8')).trim().split('\n').filter(Boolean).map(JSON.parse);
const count = (action) => rows.filter((r) => r.action === action).length;
const routes = rows.filter((r) => r.type === 'routing'),
  execution = rows.filter((r) => r.type === 'execution');
const latencies = rows
  .filter((r) => r.action === 'chip_rendered' && Number.isFinite(r.latency_ms))
  .map((r) => r.latency_ms)
  .sort((a, b) => a - b);
const percentile = (p) =>
  latencies.length ? latencies[Math.min(latencies.length - 1, Math.floor((latencies.length - 1) * p))] : null;
const perSkill = {};
for (const r of routes)
  for (const [i, slug] of r.shown_slugs.entries()) {
    perSkill[slug] ??= { shown_top: 0, shown_second: 0, accepted: 0, dismissed: 0, executed: 0, undone: 0 };
    perSkill[slug][i === 0 ? 'shown_top' : 'shown_second']++;
  }
for (const r of rows) {
  if (r.type === 'interaction' && r.action === 'tab' && perSkill[r.skill]) perSkill[r.skill].accepted++;
  if (r.type === 'interaction' && r.action === 'esc') {
    const route = routes.find((x) => x.id === r.routing_event_id);
    for (const slug of route?.shown_slugs || []) if (perSkill[slug]) perSkill[slug].dismissed++;
  }
  if (r.type === 'execution' && perSkill[r.skill]) {
    if (r.undone) perSkill[r.skill].undone++;
    else if (r.executed) perSkill[r.skill].executed++;
  }
}
console.log(
  JSON.stringify(
    {
      ghost_shown: count('ghost_shown'),
      ghost_accepted: count('ghost_accepted') + count('ctrl_right'),
      ghost_acceptance_rate: count('ghost_shown')
        ? (count('ghost_accepted') + count('ctrl_right')) / count('ghost_shown')
        : null,
      routing_events: routes.length,
      chip_events: routes.filter((r) => r.shown_slugs.length).length,
      keystroke_to_chip_p50_ms: percentile(0.5),
      keystroke_to_chip_p95_ms: percentile(0.95),
      preview_events: execution.filter((e) => e.previewed && !e.executed).length,
      confirmed_executions: execution.filter((e) => e.confirmed && e.executed && !e.undone).length,
      per_skill: perSkill,
      note: 'Counts are local observations; labeled replay is required for routing accuracy and wrong-action rates.',
    },
    null,
    2
  )
);
