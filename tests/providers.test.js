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
