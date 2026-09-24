import fs from 'node:fs/promises';
import path from 'node:path';
import YAML from 'yaml';
import { hash } from './core.js';
export async function loadRegistry(root) {
  const result = [];
  for (const entry of (await fs.readdir(root, { withFileTypes: true })).sort((a, b) =>
    a.name.localeCompare(b.name)
  )) {
    if (!entry.isDirectory()) continue;
    const file = path.join(root, entry.name, 'SKILL.md');
    const raw = await fs.readFile(file, 'utf8');
    const match = raw.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n([\s\S]*)$/);
    if (!match) throw Error(`Invalid frontmatter: ${entry.name}`);
    const h = YAML.parse(match[1]),
      m = h.metadata || {};
    if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(h.name) || h.name.length > 64 || h.name !== entry.name)
      throw Error(`Invalid name: ${entry.name}`);
    if (typeof h.description !== 'string' || !h.description.trim() || h.description.length > 1024)
      throw Error(`Invalid description: ${entry.name}`);
    if (Object.values(m).some((v) => typeof v !== 'string'))
      throw Error(`Metadata must contain strings: ${entry.name}`);
    const context = (m.context || 'buffer').split(',').map((s) => s.trim());
    if (context.some((k) => !['buffer', 'selection', 'focused-window', 'recent-screens'].includes(k)))
      throw Error(`Invalid context: ${entry.name}`);
    const tools = Array.isArray(h['allowed-tools'])
      ? h['allowed-tools']
      : (h['allowed-tools'] || '').split(/\s+/).filter(Boolean);
    if (tools.some((t) => typeof t !== 'string')) throw Error('Invalid tools');
    result.push({
      slug: h.name,
      description: h.description,
      examples: m.examples || '',
      body: match[2],
      body_path: file,
      allowed_tools: tools,
      context,
      side_effect_class: m.side_effect_class || 'destructive',
      trust: ['trusted', 'reviewed'].includes(m.trust) ? m.trust : 'untrusted',
      version: m.version || '0',
      origin: m.source || 'custom',
      active: m.active !== 'false',
      digest: hash(raw),
    });
  }
  return result;
}
export const registryHash = (skills) =>
  hash(
    skills
      .filter((s) => s.active)
      .map((s) => ({ slug: s.slug, description: s.description, examples: s.examples, digest: s.digest }))
  );
