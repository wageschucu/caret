import test from 'node:test';
import assert from 'node:assert/strict';
import { streamCompletion, healPrompt } from '../src/providers.js';
test('streaming handles fragmented SSE and stops at punctuation, canceling reader', async () => {
  const old = process.env.COMPLETER_MODEL,
    oldBase = process.env.LLM_BASE_URL;
  process.env.COMPLETER_MODEL = 'test';
  process.env.LLM_BASE_URL = 'http://compatible.test/v1';
  let canceled = false;
  try {
    const parts = [
      'data: {"choices":[{"delta":{"content":" for your"}}]}\n\n',
      'data: {"choices":[{"delta":{"content":" help. Extra"}}]}\n\n',
    ];
    const fetcher = async () => ({
      ok: true,
      body: {
        getReader: () => ({
          read: async () => ({ done: !parts.length, value: new TextEncoder().encode(parts.shift() || '') }),
          cancel: async () => {
            canceled = true;
          },
        }),
      },
    });
    const chunks = [];
    for await (const chunk of streamCompletion({ buffer: 'thank you' }, undefined, {
      fetcher,
      budgetMs: 1000,
    }))
      chunks.push(chunk);
    assert.equal(chunks.at(-1).text, ' for your help.');
    assert.equal(chunks.at(-1).phrase_boundary, true);
    assert.equal(canceled, true);
  } finally {
    if (old === undefined) delete process.env.COMPLETER_MODEL;
    else process.env.COMPLETER_MODEL = old;
    if (oldBase === undefined) delete process.env.LLM_BASE_URL;
    else process.env.LLM_BASE_URL = oldBase;
  }
});
// Fake Ollama: the first (non-streaming) call answers the forced-prefix step, the second streams.
function fakeOllama(tops, stream) {
  const requests = [];
  const fetcher = async (url, init) => {
    const body = JSON.parse(init.body);
    requests.push({ url, body });
    if (!body.stream)
      return { ok: true, json: async () => ({ response: tops[0]?.token || '', logprobs: [{ top_logprobs: tops }] }) };
    const parts = stream.map((t) => JSON.stringify(t) + '\n');
    return {
      ok: true,
      body: {
        getReader: () => ({
          read: async () => ({ done: !parts.length, value: new TextEncoder().encode(parts.shift() || '') }),
          cancel: async () => {},
        }),
      },
    };
  };
  return { fetcher, requests };
}
async function ghost(buffer, tops, stream) {
  const old = process.env.COMPLETER_MODEL,
    oldBase = process.env.LLM_BASE_URL;
  process.env.COMPLETER_MODEL = 'tiny';
  process.env.LLM_BASE_URL = 'http://127.0.0.1:11434/v1';
  const fake = fakeOllama(tops, stream);
  try {
    let last = null;
    for await (const chunk of streamCompletion({ buffer, screens: [{ text: 'secret' }] }, undefined, {
      fetcher: fake.fetcher,
      budgetMs: 1000,
    }))
      last = chunk;
    return { last, requests: fake.requests };
  } finally {
    if (old === undefined) delete process.env.COMPLETER_MODEL;
    else process.env.COMPLETER_MODEL = old;
    if (oldBase === undefined) delete process.env.LLM_BASE_URL;
    else process.env.LLM_BASE_URL = oldBase;
  }
}
const sure = (token) => ({ response: token, logprobs: [{ token, logprob: -0.05 }] });

test('token healing backs up over a half-typed word or a trailing space', () => {
  assert.deepEqual(healPrompt('translate into Spanis'), { prompt: 'translate into', typed: ' Spanis' });
  assert.deepEqual(healPrompt('thank you '), { prompt: 'thank you', typed: ' ' });
  assert.deepEqual(healPrompt('done.'), { prompt: 'done.', typed: '' });
  assert.deepEqual(healPrompt('Hallo zusammen,\nKönnten'), { prompt: 'Hallo zusammen,\n', typed: 'Könnten' });
});

test('ollama raw completion finishes the typed word, stops at punctuation, and never sends screens', async () => {
  const { last, requests } = await ghost(
    'translate into Spanis',
    [
      { token: ' Spanish', logprob: -0.1 },
      { token: ' French', logprob: -2 },
    ],
    [sure(':'), sure(' more')]
  );
  assert.equal(requests[0].url, 'http://127.0.0.1:11434/api/generate');
  assert.equal(requests[0].body.raw, true);
  assert.equal(requests[0].body.prompt, 'translate into');
  assert.equal(requests[1].body.prompt, 'translate into Spanish');
  assert(!JSON.stringify(requests).includes('secret'));
  assert.equal(last.text, 'h:');
  assert.equal(last.phrase_boundary, true);
});

test('ghost text stops at the first unlikely word and shows nothing when the first is unlikely', async () => {
  const shown = await ghost('thank you for', [{ token: ' for', logprob: -0.01 }], [
    sure(' the'),
    sure(' gift'),
    { response: ' yesterday', logprobs: [{ token: ' yesterday', logprob: -3 }] },
    sure('.'),
  ]);
  assert.equal(shown.last.text, ' the gift');
  const none = await ghost('thank you for', [{ token: ' for', logprob: -0.01 }], [
    { response: ' the', logprobs: [{ token: ' the', logprob: -2 }] },
    sure(' gift'),
  ]);
  assert.equal(none.last, null);
});

test('no ghost text when no likely token agrees with the typed letters', async () => {
  const { last, requests } = await ghost('see you tomorr', [{ token: ' today', logprob: -0.1 }], [sure('ow')]);
  assert.equal(last, null);
  assert.equal(requests.length, 1);
});

test('currency conversion uses the reference-rate service and labels the result', async () => {
  const { convertCurrency } = await import('../src/providers.js');
  let url;
  const fetcher = async (u) => {
    url = u;
    return {
      ok: true,
      status: 200,
      json: async () => ({ amount: 1, base: 'CHF', date: '2026-09-25', rates: { EUR: 1.0616 } }),
    };
  };
  const text = await convertCurrency({ amount: 250, from: 'CHF', to: 'EUR', style: 'verbose' }, { fetcher });
  assert.match(url, /from=CHF&to=EUR$/);
  assert.equal(text, '250.00 CHF ≈ 265.40 EUR (ECB reference rate, 2026-09-25)');
  assert.equal(await convertCurrency({ amount: 250, from: 'CHF', to: 'EUR' }, { fetcher }), '265.40 EUR');
  await assert.rejects(
    convertCurrency(
      { amount: 1, from: 'CHF', to: 'XXX' },
      { fetcher: async () => ({ ok: false, status: 404 }) }
    )
  );
});
test('anthropic executor sends system + turns through the SDK client and strips fences', async () => {
  const { chatAnthropic } = await import('../src/providers.js');
  let seen;
  const client = {
    messages: {
      create: async (params) => {
        seen = params;
        return {
          stop_reason: 'end_turn',
          model: 'claude-haiku-4-5',
          content: [
            {
              type: 'text',
              text: '```json\n{"preview":"x","missing_slots":[],"calls":[{"tool":"text.result","args_json":"{\\"text\\":\\"hi\\"}"}],"lookups":[]}\n```',
            },
          ],
          usage: { input_tokens: 10, output_tokens: 5 },
        };
      },
    },
  };
  const r = await chatAnthropic(
    [
      { role: 'system', content: 'S' },
      { role: 'user', content: 'U' },
    ],
    { model: 'claude-haiku-4-5', json: true, maxTokens: 500 },
    { client }
  );
  assert.equal(seen.model, 'claude-haiku-4-5');
  assert.match(seen.system, /^S/);
  assert.deepEqual(seen.messages, [{ role: 'user', content: 'U' }]);
  assert.equal(seen.thinking, undefined); // Haiku: no adaptive thinking
  assert.equal(seen.output_config.format.type, 'json_schema');
  assert.deepEqual(seen.output_config.format.schema.required, [
    'preview',
    'missing_slots',
    'calls',
    'lookups',
  ]);
  assert.equal(JSON.parse(r.text).preview, 'x');
  assert.deepEqual(JSON.parse(r.text).calls[0], { tool: 'text.result', args: { text: 'hi' } });
  const refusing = { messages: { create: async () => ({ stop_reason: 'refusal', content: [], usage: {} }) } };
  await assert.rejects(
    chatAnthropic([{ role: 'user', content: 'U' }], { model: 'claude-opus-5' }, { client: refusing })
  );
});
test('argument strings with raw newlines inside values are repaired', async () => {
  const { chatAnthropic } = await import('../src/providers.js');
  const client = {
    messages: {
      create: async () => ({
        stop_reason: 'end_turn',
        content: [
          {
            type: 'text',
            text: JSON.stringify({
              preview: 'p',
              missing_slots: [],
              lookups: [],
              calls: [
                {
                  tool: 'mail.draft',
                  args_json: '{"to": "", "subject": "Hi", "body": "Dear Sam,\nthanks\n\nBest,\nPaul"}',
                },
              ],
            }),
          },
        ],
        usage: {},
      }),
    },
  };
  const r = await chatAnthropic(
    [{ role: 'user', content: 'U' }],
    { model: 'claude-haiku-4-5', json: true },
    { client }
  );
  assert.equal(JSON.parse(r.text).calls[0].args.body, 'Dear Sam,\nthanks\n\nBest,\nPaul');
});

import { detectLocalModels, applyLocalDefaults, detectedDefaults } from '../src/providers.js';
const MODEL_VARS = [
  'COMPLETER_MODEL',
  'LLM_MODEL',
  'LLM_BASE_URL',
  'LLM_FALLBACK_MODEL',
  'EXECUTOR_PROVIDER',
  'OLLAMA_AUTODETECT',
];
async function withEnv(values, fn) {
  const saved = Object.fromEntries(MODEL_VARS.map((k) => [k, process.env[k]]));
  for (const k of MODEL_VARS) delete process.env[k];
  Object.assign(process.env, values);
  for (const k of Object.keys(detectedDefaults)) delete detectedDefaults[k];
  try {
    return await fn();
  } finally {
    for (const k of MODEL_VARS) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
    for (const k of Object.keys(detectedDefaults)) delete detectedDefaults[k];
  }
}
const tags = (models) => async (url) => {
  tags.url = url;
  return { ok: true, json: async () => ({ models }) };
};
test('ollama probe picks the smallest model for ghost text and the largest for planning, skipping embeddings', () =>
  withEnv({}, async () => {
    const fetcher = tags([
      { name: 'llama3.1:8b', size: 4_900_000_000 },
      { name: 'nomic-embed-text', size: 200_000_000 },
      { name: 'llama3.2:1b', size: 1_300_000_000 },
    ]);
    const found = await detectLocalModels({ fetcher });
    assert.equal(tags.url, 'http://127.0.0.1:11434/api/tags');
    assert.equal(found.completer, 'llama3.2:1b');
    assert.equal(found.executor, 'llama3.1:8b');
    assert.deepEqual(
      found.models.map((m) => m.name),
      ['llama3.2:1b', 'llama3.1:8b']
    );
  }));
test('ollama probe returns null when Ollama is down or the endpoint is not Ollama', () =>
  withEnv({}, async () => {
    assert.equal(
      await detectLocalModels({
        fetcher: async () => {
          throw Error('ECONNREFUSED');
        },
      }),
      null
    );
    process.env.LLM_BASE_URL = 'https://api.example.test/v1';
    let called = false;
    assert.equal(
      await detectLocalModels({
        fetcher: async () => {
          called = true;
        },
      }),
      null
    );
    assert.equal(called, false, 'a non-Ollama endpoint is never probed');
  }));
test('local defaults fill only empty settings and never override .env', () =>
  withEnv({ LLM_MODEL: 'my-choice:7b' }, async () => {
    const fetcher = tags([
      { name: 'big:70b', size: 40e9 },
      { name: 'small:1b', size: 1e9 },
    ]);
    const r = await applyLocalDefaults({ fetcher });
    assert.equal(process.env.LLM_MODEL, 'my-choice:7b');
    // The completer borrows LLM_MODEL when it is local, so it is not wanted here.
    assert.deepEqual(r.wanted, ['LLM_FALLBACK_MODEL']);
    assert.deepEqual(r.filled, { LLM_FALLBACK_MODEL: 'big:70b' });
    assert.deepEqual(detectedDefaults, { LLM_FALLBACK_MODEL: 'big:70b' });
  }));
test('local defaults fill everything on a machine with Ollama and no .env', () =>
  withEnv({}, async () => {
    const fetcher = tags([
      { name: 'big:70b', size: 40e9 },
      { name: 'small:1b', size: 1e9 },
    ]);
    const r = await applyLocalDefaults({ fetcher });
    assert.equal(r.reachable, true);
    assert.deepEqual(r.filled, { COMPLETER_MODEL: 'small:1b', LLM_MODEL: 'big:70b', LLM_FALLBACK_MODEL: 'big:70b' });
    assert.equal(process.env.COMPLETER_MODEL, 'small:1b');
    assert.equal(process.env.LLM_MODEL, 'big:70b');
  }));
test('a hosted executor keeps its Claude id but gets a local completer and fallback', () =>
  withEnv({ EXECUTOR_PROVIDER: 'anthropic', LLM_MODEL: 'claude-haiku-4-5-20251001' }, async () => {
    const fetcher = tags([
      { name: 'big:8b', size: 5e9 },
      { name: 'small:1b', size: 1e9 },
    ]);
    const r = await applyLocalDefaults({ fetcher });
    assert.deepEqual(r.wanted, ['COMPLETER_MODEL', 'LLM_FALLBACK_MODEL']);
    assert.equal(process.env.LLM_MODEL, 'claude-haiku-4-5-20251001');
    assert.equal(process.env.COMPLETER_MODEL, 'small:1b');
    assert.equal(process.env.LLM_FALLBACK_MODEL, 'big:8b');
  }));
test('local defaults report demo mode when Ollama is down, and stay off when disabled', () =>
  withEnv({}, async () => {
    const down = async () => {
      throw Error('ECONNREFUSED');
    };
    let r = await applyLocalDefaults({ fetcher: down });
    assert.equal(r.reachable, false);
    assert.deepEqual(r.filled, {});
    assert.equal(process.env.LLM_MODEL, undefined);
    process.env.OLLAMA_AUTODETECT = 'false';
    let probed = false;
    r = await applyLocalDefaults({
      fetcher: async () => {
        probed = true;
      },
    });
    assert.equal(probed, false);
    assert.equal(r.reachable, null);
  }));
test('ollama with only embedding models fills nothing', () =>
  withEnv({}, async () => {
    const r = await applyLocalDefaults({ fetcher: tags([{ name: 'nomic-embed-text', size: 2e8 }]) });
    assert.equal(r.reachable, true);
    assert.deepEqual(r.filled, {});
  }));

test('a cancelled hosted request never falls back to the local model', () =>
  withEnv({ EXECUTOR_PROVIDER: 'anthropic', LLM_FALLBACK_MODEL: 'llama3.1:8b' }, async () => {
    const { chat } = await import('../src/providers.js');
    const savedFetch = globalThis.fetch,
      savedKey = process.env.ANTHROPIC_API_KEY;
    const urls = [];
    globalThis.fetch = async (url, init) => {
      urls.push(String(url));
      init?.signal?.throwIfAborted();
      throw Object.assign(Error('offline'), { name: 'TypeError' });
    };
    process.env.ANTHROPIC_API_KEY = 'test-key';
    const control = new AbortController();
    control.abort();
    try {
      await assert.rejects(chat([{ role: 'user', content: 'x' }], { model: 'claude-haiku-4-5', signal: control.signal }));
      assert.ok(!urls.some((u) => u.includes('11434')), `fell back to Ollama: ${urls.join(', ')}`);
    } finally {
      globalThis.fetch = savedFetch;
      if (savedKey === undefined) delete process.env.ANTHROPIC_API_KEY;
      else process.env.ANTHROPIC_API_KEY = savedKey;
    }
  }));
