// Read-only lookups an executor may request while planning, before its single gated action.
// A lookup never runs on its own: only inside an accepted skill that lists it in allowed-tools,
// only when the model asks for it, at most LOOKUP_LIMIT times per accept, and each call is logged.
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const run = promisify(execFile);
export const LOOKUP_LIMIT = 3;

export const LOOKUPS = Object.freeze({
  'contacts.lookup': {
    where: 'host',
    schema: '{"name": string}',
    describe: "address-book entries for a person's name (Name <address> lines)",
  },
  'calendar.freebusy': {
    where: 'host',
    schema: '{"from": ISO datetime, "to": ISO datetime}',
    describe:
      "busy periods in the user's calendar between two times, to pick a free slot when the requested time is vague (afternoon, next week)",
  },
  'github.contributors': {
    where: 'helper',
    schema: '{"repo": "owner/name"}',
    describe:
      'contributors of a GitHub repository with the addresses they made public in commits; take the repo from a github.com URL in the context or from the sentence, never guess one',
  },
});

export const isLookup = (tool) => tool in LOOKUPS;

/// Validates a requested lookup against the skill's allowed tools and the tool's schema.
export function validateLookup(request, allowedTools) {
  const tool = request?.tool,
    args = request?.args;
  if (!isLookup(tool) || !allowedTools.includes(tool) || !args || typeof args !== 'object')
    throw Error(`Lookup not available: ${tool}`);
  if (tool === 'contacts.lookup' && !(typeof args.name === 'string' && args.name.trim()))
    throw Error('contacts.lookup needs a name');
  if (
    tool === 'calendar.freebusy' &&
    !(Number.isFinite(Date.parse(args.from)) && Number.isFinite(Date.parse(args.to)))
  )
    throw Error('calendar.freebusy needs from and to as ISO datetimes');
  if (tool === 'github.contributors' && !/^[\w.-]+\/[\w.-]+$/.test(args.repo || ''))
    throw Error('github.contributors needs owner/name');
  return { tool, args };
}

/// Runs a helper-side lookup. Host-side ones are answered by the host through /api/prepare.
export async function runLookup({ tool, args }, { runner = run } = {}) {
  if (tool === 'github.contributors') return githubContributors(args.repo, runner);
  throw Error(`Lookup ${tool} is performed by the host`);
}

async function gh(runner, path) {
  const { stdout } = await runner('gh', ['api', path, '--paginate'], { timeout: 15000, maxBuffer: 4e6 });
  return JSON.parse(stdout.trim().replace(/\]\s*\[/g, ','));
}

// Contributors via the user's own `gh` login (read-only). Addresses come only from commit metadata
// the authors chose to publish; GitHub's noreply addresses are reported as "no public email".
async function githubContributors(repo, runner) {
  let contributors, commits;
  try {
    contributors = await gh(runner, `repos/${repo}/contributors?per_page=50`);
    commits = await gh(runner, `repos/${repo}/commits?per_page=100`);
  } catch (e) {
    const detail = String(e.stderr || e.message || '')
      .split('\n')[0]
      .slice(0, 160);
    throw Error(`GitHub lookup failed for ${repo}: ${detail || 'is gh installed and logged in?'}`);
  }
  const byLogin = new Map();
  for (const c of commits || []) {
    const login = c.author?.login,
      email = c.commit?.author?.email || '',
      name = c.commit?.author?.name || '';
    const key = login || name;
    if (!key) continue;
    const entry = byLogin.get(key) || { login, names: new Set(), emails: new Set() };
    if (name) entry.names.add(name);
    if (email && !/noreply|no-reply/i.test(email)) entry.emails.add(email);
    byLogin.set(key, entry);
  }
  const lines = [];
  for (const c of contributors || []) {
    const entry = byLogin.get(c.login);
    const names = entry ? [...entry.names].join(' / ') : '';
    const emails = entry ? [...entry.emails] : [];
    lines.push(
      `${c.login}${names ? ` — ${names}` : ''} — ${emails.length ? emails.map((e) => `<${e}>`).join(', ') : 'no public email'} (${c.contributions} commits)`
    );
  }
  return lines.length ? lines.join('\n') : `No contributors found for ${repo}`;
}
