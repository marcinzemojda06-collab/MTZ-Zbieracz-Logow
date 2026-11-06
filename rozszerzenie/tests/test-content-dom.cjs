'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {JSDOM} = require('jsdom');
const jsdomRoot = path.dirname(require.resolve('jsdom/package.json'));
const FileList = require(path.join(jsdomRoot, 'lib/generated/idl/FileList.js'));
const idl = require(path.join(jsdomRoot, 'lib/generated/idl/utils.js'));
const dir = path.resolve(__dirname, '..');
const common = fs.readFileSync(path.join(dir, 'common.js'), 'utf8');
const content = fs.readFileSync(path.join(dir, 'content.js'), 'utf8');
const token = 'a'.repeat(64);
const bytes = Buffer.alloc(22); bytes.set([0x50,0x4b,0x05,0x06]);
const response = {ok:true, filename:'MTZ-Logi-test.zip', data:bytes.toString('base64')};
const baseHTML = '<!doctype html><form><div contenteditable="true" id="prompt-textarea">Existing draft</div><input type="file" accept=".zip" hidden><button type="submit">Send</button></form>';
let checks=0;
async function fixture(options={}) {
  const dom=new JSDOM(options.html||baseHTML, {url:options.url||`https://chatgpt.com/c/test-case#view=logs&mtz-logs=${token}`,runScripts:'outside-only',pretendToBeVisual:true});
  const w=dom.window; const state={requests:0,inputEvents:0,changeEvents:0,submitEvents:0,dom};
  for(const editor of w.document.querySelectorAll('#prompt-textarea')) editor.getClientRects=()=>[{width:300,height:20}];
  w.DataTransfer=class DataTransfer {
    constructor(){const files=FileList.create(w); this.files=files; this.items={add(file){idl.implForWrapper(files).push(idl.implForWrapper(file));}};}
  };
  w.chrome={runtime:{lastError:null,sendMessage(message,callback){state.requests++; state.lastMessage=message; w.setTimeout(()=>callback(options.response||response),options.responseDelay||0);}}};
  w.document.addEventListener('input',()=>state.inputEvents++);
  w.document.addEventListener('change',()=>state.changeEvents++);
  w.document.addEventListener('submit',event=>{state.submitEvents++;event.preventDefault();});
  if(options.prepare) options.prepare(w,state);
  w.eval(common);w.eval(content);
  await new Promise(resolve=>setTimeout(resolve,80));
  return state;
}
async function test(name,action){await action();checks++;console.log('PASS '+name);}
function readFile(w,file){return new Promise((resolve,reject)=>{const reader=new w.FileReader;reader.onload=()=>resolve(Buffer.from(reader.result));reader.onerror=reject;reader.readAsArrayBuffer(file);});}
(async()=>{
  await test('valid handoff assigns exact ZIP bytes and dispatches picker events',async()=>{
    const f=await fixture();try{const w=f.dom.window;const input=w.document.querySelector('input');assert.equal(input.files.length,1);assert.equal(input.files[0].name,response.filename);assert.deepEqual(await readFile(w,input.files[0]),bytes);assert.equal(f.inputEvents,1);assert.equal(f.changeEvents,1);assert.equal(f.requests,1);}finally{f.dom.window.close();}
  });
  await test('handoff preserves draft and never submits message',async()=>{
    const f=await fixture();try{const w=f.dom.window;assert.equal(w.document.querySelector('#prompt-textarea').textContent,'Existing draft');assert.equal(f.submitEvents,0);assert.match(w.document.querySelector('[role=status]').textContent,/nie potwierdza wysłania/);}finally{f.dom.window.close();}
  });
  await test('bearer handoff fragment removed while unrelated hash is preserved',async()=>{
    const f=await fixture();try{assert.equal(f.dom.window.location.hash,'#view=logs');assert.ok(!f.dom.window.location.href.includes(token));}finally{f.dom.window.close();}
  });
  await test('normal conversation without handoff performs no local request',async()=>{
    const f=await fixture({url:'https://chatgpt.com/c/test-case'});try{assert.equal(f.requests,0);assert.equal(f.dom.window.document.querySelector('#mtz-log-handoff-panel'),null);}finally{f.dom.window.close();}
  });
  await test('foreign page never requests local data',async()=>{
    const f=await fixture({url:`https://evil.invalid/c/test-case#mtz-logs=${token}`});try{assert.equal(f.requests,0);}finally{f.dom.window.close();}
  });
  await test('invalid token performs no local request',async()=>{
    const f=await fixture({url:'https://chatgpt.com/c/test-case#mtz-logs=bad'});try{assert.equal(f.requests,0);}finally{f.dom.window.close();}
  });
  await test('existing selected files are preserved and retry is offered',async()=>{
    const f=await fixture({prepare(w){const t=new w.DataTransfer;t.items.add(new w.File(['existing'],'existing.zip',{type:'application/zip'}));w.document.querySelector('input').files=t.files;}});try{const w=f.dom.window;assert.equal(w.document.querySelector('input').files[0].name,'existing.zip');assert.equal(f.changeEvents,0);assert.match(w.document.querySelector('[role=status]').textContent,/już wybrane pliki/);assert.equal(w.document.querySelector('#mtz-log-handoff-panel button').hidden,false);}finally{f.dom.window.close();}
  });
  await test('ambiguous picker never assigns ZIP',async()=>{
    const f=await fixture({html:baseHTML.replace('</form>','<input type="file" accept=".zip"></form>')});try{for(const input of f.dom.window.document.querySelectorAll('input'))assert.equal(input.files.length,0);assert.equal(f.changeEvents,0);}finally{f.dom.window.close();}
  });
  await test('picker outside composer is not selected',async()=>{
    const f=await fixture({html:'<form><div contenteditable id="prompt-textarea">Draft</div></form><input type="file" accept=".zip">'});try{assert.equal(f.dom.window.document.querySelector('input').files.length,0);assert.equal(f.changeEvents,0);}finally{f.dom.window.close();}
  });
  await test('picker disabled by its fieldset is not used until the form is ready',async()=>{
    const f=await fixture({html:baseHTML.replace('<form>','<form><fieldset disabled>').replace('</form>','</fieldset></form>')});
    try {
      const w=f.dom.window, input=w.document.querySelector('input');
      assert.equal(input.disabled,false);
      assert.equal(input.matches(':disabled'),true);
      assert.equal(input.files.length,0);
      assert.equal(f.changeEvents,0);
      w.document.querySelector('fieldset').disabled=false;
      await new Promise(resolve=>setTimeout(resolve,280));
      assert.equal(input.files.length,1);
      assert.equal(f.changeEvents,1);
      assert.equal(f.requests,1);
    } finally {f.dom.window.close();}
  });
  await test('closing the handoff panel discards a pending response without attachment',async()=>{
    const f=await fixture({responseDelay:50,prepare(w){w.setTimeout(()=>{
      const buttons=w.document.querySelectorAll('#mtz-log-handoff-panel button');
      buttons[buttons.length-1].click();
    },15);}});
    try {
      assert.equal(f.requests,1);
      assert.equal(f.dom.window.document.querySelector('input').files.length,0);
      assert.equal(f.dom.window.document.querySelector('#mtz-log-handoff-panel'),null);
      assert.equal(f.changeEvents,0);
      assert.equal(f.submitEvents,0);
    } finally {f.dom.window.close();}
  });
  await test('changing conversation while receiving never attaches to the new composer',async()=>{
    const f=await fixture({responseDelay:50,prepare(w){w.setTimeout(()=>{
      w.history.pushState(null,'','/c/different-conversation');
    },15);}});
    try {
      assert.equal(f.requests,1);
      assert.equal(f.dom.window.document.querySelector('input').files.length,0);
      assert.equal(f.changeEvents,0);
      assert.equal(f.submitEvents,0);
      assert.match(f.dom.window.document.querySelector('[role=status]').textContent,/Rozmowa zmieniła się/);
    } finally {f.dom.window.close();}
  });
  await test('invalid local payload reports error without changing picker',async()=>{
    const f=await fixture({response:{ok:true,filename:'bundle.zip',data:Buffer.from('not zip').toString('base64')}});try{const w=f.dom.window;assert.equal(w.document.querySelector('input').files.length,0);assert.match(w.document.querySelector('[role=status]').textContent,/nie przekazał pliku ZIP/);}finally{f.dom.window.close();}
  });
  await test('local bridge refusal is visible and does not attach',async()=>{
    const f=await fixture({response:{ok:false,error:'Fixture bridge expired'}});try{const w=f.dom.window;assert.equal(w.document.querySelector('input').files.length,0);assert.match(w.document.querySelector('[role=status]').textContent,/Fixture bridge expired/);}finally{f.dom.window.close();}
  });
  await test('retry after existing file is removed uses same snapshot without refetch',async()=>{
    const f=await fixture({prepare(w){const t=new w.DataTransfer;t.items.add(new w.File(['existing'],'existing.zip'));w.document.querySelector('input').files=t.files;}});try{const w=f.dom.window;w.document.querySelector('input').files=(new w.DataTransfer).files;w.document.querySelector('#mtz-log-handoff-panel button').click();await new Promise(resolve=>setTimeout(resolve,30));assert.equal(w.document.querySelector('input').files[0].name,response.filename);assert.equal(f.requests,1);assert.equal(f.changeEvents,1);}finally{f.dom.window.close();}
  });
  console.log(`RESULT content DOM fixtures passed=${checks} failed=0`);
})().catch(error=>{console.error(error);process.exitCode=1;});
