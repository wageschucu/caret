import test from 'node:test';import assert from 'node:assert/strict';
import {streamCompletion} from '../src/providers.js';
test('streaming handles fragmented SSE and stops at punctuation, canceling reader',async()=>{
 const old=process.env.COMPLETER_MODEL;process.env.COMPLETER_MODEL='test';let canceled=false;
 try{
  const parts=['data: {"choices":[{"delta":{"content":" for your"}}]}\n\n','data: {"choices":[{"delta":{"content":" help. Extra"}}]}\n\n'];
  const fetcher=async()=>({ok:true,body:{getReader:()=>({read:async()=>({done:!parts.length,value:new TextEncoder().encode(parts.shift()||'')}),cancel:async()=>{canceled=true;}})}});
  const chunks=[];for await(const chunk of streamCompletion({buffer:'thank you'},undefined,{fetcher,budgetMs:1000}))chunks.push(chunk);
  assert.equal(chunks.at(-1).text,' for your help.');assert.equal(chunks.at(-1).phrase_boundary,true);assert.equal(canceled,true);
 }finally{if(old===undefined)delete process.env.COMPLETER_MODEL;else process.env.COMPLETER_MODEL=old;}
});
