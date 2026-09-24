import fs from 'node:fs/promises';
import { loadRegistry, registryHash } from '../src/registry.js';
import { trimState, selectRoute, THRESHOLDS, ABSTAIN, hash } from '../src/core.js';
import { route, demoRoute } from '../src/providers.js';
const args = process.argv.slice(2),
  value = (key, fallback) => (args.includes(key) ? args[args.indexOf(key) + 1] : fallback);
const file = value('--dataset', 'eval/states.jsonl'),
  live = args.includes('--live');
if (live && !process.env.TYPESAFE_API_KEY) throw Error('--live requires TYPESAFE_API_KEY');
const rows = (await fs.readFile(file, 'utf8')).trim().split('\n').filter(Boolean).map(JSON.parse);
const skills = (await loadRegistry('skills')).filter((s) => s.active);
const confusion = {},
  languages = {},
  calibration = Array.from({ length: 10 }, (_, i) => ({
    lower: i / 10,
    upper: (i + 1) / 10,
    n: 0,
    no_route: 0,
  }));
let stale = 0,
  negatives = 0,
  positives = 0,
  falseRoutes = 0,
  missed = 0,
  wrong = 0;
const predictions = [];
for (const row of rows) {
  if (!row.label) throw Error('Every state needs a hand-checked label, including NO_ROUTE');
  const state = trimState(row.state),
    output = live
      ? await route(state, skills)
      : row.choice_distribution
        ? { ready: row.ready_p, distribution: row.choice_distribution, model: row.jev_model }
        : demoRoute(state, skills);
  if (row.registry_hash && row.registry_hash !== registryHash(skills) && !live) {
    // Recorded probabilities are only valid for the registry that produced them.
    stale++;
    continue;
  }
  const shown = selectRoute(output.ready, output.distribution, [], state.buffer),
    predicted = shown[0] || 'NO_ROUTE',
    correct = row.label === 'NO_ROUTE' ? !shown.length : shown.includes(row.label);
  confusion[row.label] ??= {};
  confusion[row.label][predicted] = (confusion[row.label][predicted] || 0) + 1;
  if (row.label === 'NO_ROUTE') {
    negatives++;
    if (shown.length) falseRoutes++;
  } else {
    positives++;
    if (!shown.includes(row.label)) missed++;
    if (shown.length && !shown.includes(row.label)) wrong++;
  }
  const lang = row.language || 'unknown';
  languages[lang] ??= { total: 0, correct: 0 };
  languages[lang].total++;
  languages[lang].correct += Number(correct);
  const p = output.distribution[ABSTAIN] || 0,
    bin = calibration[Math.min(9, Math.floor(p * 10))];
  bin.n++;
  bin.no_route += Number(row.label === 'NO_ROUTE');
  predictions.push({ id: row.id, label: row.label, shown, model: output.model });
}
const report = {
  mode: live
    ? 'live-jev'
    : rows.some((r) => r.choice_distribution)
      ? 'recorded-probability-replay'
      : 'synthetic-demo-only',
  dataset_hash: hash(rows),
  registry_hash: registryHash(skills),
  thresholds_version: THRESHOLDS.version,
  total: rows.length - stale,
  stale_skipped: stale,
  false_route_rate: negatives ? falseRoutes / negatives : 0,
  missed_route_rate: positives ? missed / positives : 0,
  wrong_route_count: wrong,
  confusion_matrix: confusion,
  per_language: languages,
  abstain_calibration: calibration.map((b) => ({
    ...b,
    observed_no_route_rate: b.n ? b.no_route / b.n : null,
  })),
  predictions,
};
const baseline = value('--baseline', null);
if (baseline) {
  const old = JSON.parse(await fs.readFile(baseline, 'utf8'));
  if (old.dataset_hash !== report.dataset_hash || old.mode !== report.mode)
    throw Error('Baseline dataset or evaluation mode does not match');
  if (
    report.false_route_rate > old.false_route_rate ||
    report.missed_route_rate > old.missed_route_rate ||
    report.wrong_route_count > old.wrong_route_count
  ) {
    process.exitCode = 1;
    report.regression = true;
  }
}
if (stale)
  console.error(
    `${stale} state(s) skipped: recorded under a different registry. Run with --live to re-evaluate them.`
  );
const out = value('--out', null);
if (out) await fs.writeFile(out, JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report, null, 2));
