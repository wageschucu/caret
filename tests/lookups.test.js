import test from 'node:test';
import assert from 'node:assert/strict';
import { validateLookup, runLookup, LOOKUP_LIMIT } from '../src/lookups.js';

test('lookups are validated against the allow-list and their schema', () => {
  assert.throws(() => validateLookup({ tool: 'github.contributors', args: { repo: 'a/b' } }, ['mail.draft']));
  assert.throws(() =>
    validateLookup({ tool: 'github.contributors', args: { repo: 'not a repo' } }, ['github.contributors'])
  );
  assert.throws(() => validateLookup({ tool: 'contacts.lookup', args: {} }, ['contacts.lookup']));
  assert.throws(() => validateLookup({ tool: 'mail.draft', args: {} }, ['mail.draft']));
  assert.deepEqual(validateLookup({ tool: 'contacts.lookup', args: { name: 'Sam' } }, ['contacts.lookup']), {
    tool: 'contacts.lookup',
    args: { name: 'Sam' },
  });
  assert.equal(LOOKUP_LIMIT, 3);
});

test('github.contributors joins contributors with public commit emails and hides noreply ones', async () => {
  const runner = async (cmd, args) => {
    assert.equal(cmd, 'gh');
    if (args[1].includes('/contributors'))
      return {
        stdout: JSON.stringify([
          { login: 'alice', contributions: 12 },
          { login: 'bob', contributions: 3 },
        ]),
      };
    return {
      stdout: JSON.stringify([
        {
          author: { login: 'alice' },
          commit: { author: { name: 'Alice Smith', email: 'alice@example.org' } },
        },
        {
          author: { login: 'bob' },
          commit: { author: { name: 'Bob', email: '123+bob@users.noreply.github.com' } },
        },
      ]),
    };
  };
  const text = await runLookup({ tool: 'github.contributors', args: { repo: 'x/y' } }, { runner });
  assert.match(text, /^alice — Alice Smith — <alice@example.org> \(12 commits\)$/m);
  assert.match(text, /^bob — Bob — no public email \(3 commits\)$/m);
  await assert.rejects(runLookup({ tool: 'contacts.lookup', args: { name: 'x' } }, { runner }));
});
