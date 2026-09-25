import test from 'node:test';
import assert from 'node:assert/strict';
import { streamCompletion } from '../src/providers.js';
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
test('ollama raw completion continues the buffer, stops at punctuation, and never sends screens', async () => {
  const old = process.env.COMPLETER_MODEL,
    oldBase = process.env.LLM_BASE_URL;
  process.env.COMPLETER_MODEL = 'tiny';
  process.env.LLM_BASE_URL = 'http://127.0.0.1:11434/v1';
  let request;
  try {
    const parts = ['{"response":" the"}\n{"response":" gift"}\n', '{"response":". More","done":false}\n'];
    const fetcher = async (url, init) => {
      request = { url, body: JSON.parse(init.body) };
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
    const chunks = [];
    for await (const chunk of streamCompletion(
      { buffer: 'thank you for', screens: [{ text: 'secret' }] },
      undefined,
      {
        fetcher,
        budgetMs: 1000,
      }
    ))
      chunks.push(chunk);
    assert.equal(request.url, 'http://127.0.0.1:11434/api/generate');
    assert.equal(request.body.raw, true);
    assert.equal(request.body.prompt, 'thank you for');
    assert(!JSON.stringify(request.body).includes('secret'));
    assert.equal(chunks.at(-1).text, ' the gift.');
    assert.equal(chunks.at(-1).phrase_boundary, true);
  } finally {
    if (old === undefined) delete process.env.COMPLETER_MODEL;
    else process.env.COMPLETER_MODEL = old;
    if (oldBase === undefined) delete process.env.LLM_BASE_URL;
    else process.env.LLM_BASE_URL = oldBase;
  }
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
