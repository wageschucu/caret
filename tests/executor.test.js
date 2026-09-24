import test from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs/promises';import os from 'node:os';import path from 'node:path';
import {Executions,validatePlan} from '../src/executor.js';import {permission} from '../src/core.js';
const make=(effect,tool,args)=>{const skill={slug:'test',version:'1',trust:'trusted',side_effect_class:effect,allowed_tools:[tool]};return {skill,gate:permission(skill),context:{buffer:'test'},plan:{preview:'Review',missing_slots:[],calls:[{tool,args}]}};};
async function setup(t){const root=await fs.mkdtemp(path.join(os.tmpdir(),'skillrouter-'));t.after(()=>fs.rm(root,{recursive:true,force:true}));const logs=[];return {root,logs,exec:new Executions(root,async e=>logs.push(e))};}
test('send-class action cannot execute before preview and single-use confirmation',async t=>{
 const {exec,root,logs}=await setup(t),p=make('sends-or-pays','calendar.create',{title:'Review',start:'2026-10-01T10:00:00Z',end:'2026-10-01T11:00:00Z'});
 const r=await exec.accept(p,'route','session');assert.equal(r.status,'preview');await assert.rejects(fs.stat(path.join(root,'calendar')));
 await assert.rejects(exec.confirm(r.id,'other'));
 const outcomes=await Promise.allSettled([exec.confirm(r.id,'session'),exec.confirm(r.id,'session')]);assert.equal(outcomes.filter(x=>x.status==='fulfilled').length,1);
 assert.equal((await fs.readdir(path.join(root,'calendar'))).length,1);assert.equal(logs.at(-1).confirmed,true);
});
test('missing slots, cancel and expiry cannot execute',async t=>{
 const {exec}=await setup(t),p=make('destructive','text.result',{text:'done'});p.plan.missing_slots=['target'];
 const r=await exec.accept(p,'route','session');await assert.rejects(exec.confirm(r.id,'session'));exec.cancel(r.id,'session');await assert.rejects(exec.confirm(r.id,'session'));
 const r2=await exec.accept({...p,plan:{...p.plan,missing_slots:[]}},'route','session');exec.pending.get(r2.id).created=0;await assert.rejects(exec.confirm(r2.id,'session'));
});
test('file save executes once, never overwrites and undo checks unchanged content',async t=>{
 const {exec,root}=await setup(t),p=make('reversible','file.save',{filename:'notes.md',content:'hello'});
 const r=await exec.accept(p,'route','session');assert.equal(r.status,'done');await assert.rejects(exec.accept(p,'route','session'));
 await fs.writeFile(path.join(root,'files','notes.md'),'user edit');await assert.rejects(exec.undo(r.undo_id,'session'));
 await fs.writeFile(path.join(root,'files','notes.md'),'hello');await exec.undo(r.undo_id,'session');await assert.rejects(fs.stat(path.join(root,'files','notes.md')));
});
test('tool validation blocks undeclared calls, traversal and invalid calendar dates',()=>{
 const p=make('preview-only','text.result',{text:'ok'});
 assert.throws(()=>validatePlan({...p.plan,calls:[{tool:'shell.exec',args:{cmd:'anything'}}]},p.gate));
 assert.throws(()=>validatePlan({...p.plan,calls:[{tool:'file.save',args:{filename:'../escape',content:'x'}}]}, {tools:['file.save']}));
 assert.throws(()=>validatePlan({...p.plan,calls:[{tool:'calendar.create',args:{title:'x',start:'not a date',end:'tomorrow'}}]}, {tools:['calendar.create']}));
});
