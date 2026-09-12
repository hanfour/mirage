const {test} = require('node:test');
const assert = require('node:assert/strict');
const {harness, html} = require('./remote_viewer_harness.cjs');

test('only a full 2 seconds without chunks flushes and requests a keyframe', async () => {
  const h = harness();
  h.receive(1);
  await h.advance(1999);
  assert.equal(h.decoders[0].flushes, 0);
  assert.deepEqual(h.sockets[0].sent, []);
  await h.advance(1);
  assert.equal(h.draws(), 1);
  assert.equal(h.decoders[0].flushes, 1);
  assert.equal(h.run('pending.size'), 0);
  assert.deepEqual(h.sockets[0].sent, ['keyframe']);
});

test('250ms P-frame heartbeats keep pending zero without flush or keyframe requests', async () => {
  const h = harness({immediateOutput: true});
  h.receive(1);
  for (let seq = 2; seq <= 17; seq++) {
    await h.advance(250);
    h.receive(seq, false);
    assert.equal(h.run('pending.size'), 0);
  }
  assert.equal(h.draws(), 17);
  assert.equal(h.decoders[0].flushes, 0);
  assert.deepEqual(h.sockets[0].sent, []);
  assert.equal(h.run('localDrops'), 0);
});

test('a new chunk postpones the 2-second idle deadline', async () => {
  const h = harness();
  h.receive(1);
  await h.advance(1500);
  h.receive(2, false);
  await h.advance(1999);
  assert.equal(h.decoders[0].flushes, 0);
  await h.advance(1);
  assert.equal(h.decoders[0].flushes, 1);
  assert.equal(h.draws(), 2);
});

test('flush rejection is diagnostic only and still requests a recovery keyframe', async () => {
  const h = harness();
  h.receive(1);
  h.decoders[0].rejectFlush = true;
  await h.advance(2000);
  assert.equal(h.run('configurationFailed'), false);
  assert.equal(h.run('status'), 'streaming');
  assert.match(h.run('lines.join(" ")'), /idle flush: flush rejected/);
  assert.deepEqual(h.sockets[0].sent, ['keyframe']);
  h.decoders[0].rejectFlush = false;
  h.receive(2);
  await h.advance(2000);
  assert.equal(h.draws(), 2);
});

test('deltas after flush do not duplicate the request; IDR resumes ordinary P-frames', async () => {
  const h = harness({immediateOutput: true});
  h.receive(1);
  await h.advance(2000);
  assert.deepEqual(h.sockets[0].sent, ['keyframe']);
  h.receive(2, false);
  h.receive(3, false);
  assert.deepEqual(h.sockets[0].sent, ['keyframe']);
  assert.equal(h.decoders[0].chunks.length, 1);
  h.receive(4);
  await h.advance(250);
  h.receive(5, false);
  assert.equal(h.draws(), 3);
  assert.equal(h.run('waiting'), false);
  assert.equal(h.decoders[0].flushes, 1);
  assert.deepEqual(h.sockets[0].sent, ['keyframe']);
});

test('request is sent after flush resolves, never before', async () => {
  const h = harness();
  h.receive(1);
  let complete;
  h.decoders[0].flush = () => new Promise(resolve => { complete = resolve; });
  const flushing = h.advance(2000);
  h.receive(2, false); // flush 尚未完成時的 delta 也不能提早送出請求。
  assert.deepEqual(h.sockets[0].sent, []);
  complete();
  await flushing;
  assert.deepEqual(h.sockets[0].sent, ['keyframe']);
});

test('a keyframe arriving during flush prevents a redundant request on completion', async () => {
  const h = harness();
  h.receive(1);
  let complete;
  h.decoders[0].flush = () => new Promise(resolve => { complete = resolve; });
  const flushing = h.advance(2000);
  h.receive(2);
  complete();
  await flushing;
  assert.deepEqual(h.sockets[0].sent, []);
  assert.equal(h.run('waiting'), false);
});

test('reset and disconnect cancel idle timers; closed decoder is never flushed', async () => {
  for (const action of ['reset("test")', 'video.onclose()', 'decoder.close()']) {
    const h = harness();
    h.receive(1);
    h.run(action);
    await h.advance(2000);
    assert.equal(h.decoders[0].flushes, 0);
    assert.deepEqual(h.sockets[0].sent, []);
  }
});


test('navigation clicks send exactly one key each and clear feedback after 180ms', async () => {
  const h = harness();
  h.sockets[0].onopen();
  assert.equal(h.elements['#nav'].hidden, false);
  assert.equal(h.buttons.length, 3);
  const input = h.sockets[1];
  for (const [index, key] of ['GoBack', 'GoHome', 'AppSwitch'].entries()) {
    const button = h.buttons[index];
    button.listeners.click();
    assert.equal(input.sent.length, index + 1);
    assert.deepEqual(JSON.parse(input.sent[index]), {type: 'key', key, t: index * 180});
    assert.equal(button.classList.contains('pressed'), true);
    await h.advance(179);
    assert.equal(button.classList.contains('pressed'), true);
    await h.advance(1);
    assert.equal(button.classList.contains('pressed'), false);
  }
  assert.equal(h.run('active.size'), 0);
});

test('nav=0 hides navigation and restores canvas space independently of stats', () => {
  for (const suffix of ['', '&stats=0']) {
    const h = harness({search: '?t=abc&nav=0' + suffix});
    assert.equal(h.elements['#nav'].hidden, true);
    assert.equal(h.root.classList.contains('no-nav'), true);
    assert.equal(h.elements.details.hidden, suffix !== '');
  }
  assert.match(html, /:root.no-nav\{--nav-height:0px\}/);
  assert.match(html, /height:calc\(100% - var\(--nav-height\)\)/);
  assert.match(html, /bottom:max\(var\(--nav-height\),env\(safe-area-inset-bottom,0px\)\)/);
});

test('navigation uses input backpressure and disconnected drop accounting', () => {
  const h = harness();
  h.buttons[0].listeners.click();
  assert.equal(h.run('inputDrops'), 1);
  h.sockets[0].onopen();
  const input = h.sockets[1];
  input.bufferedAmount = 65536;
  h.buttons[1].listeners.click();
  input.bufferedAmount = 0;
  input.readyState = 3;
  h.buttons[2].listeners.click();
  assert.equal(h.run('inputDrops'), 3);
  assert.deepEqual(input.sent, []);
});

test('rapid repeated clicks keep feedback for 180ms after the final click', async () => {
  const h = harness();
  h.sockets[0].onopen();
  const button = h.buttons[0];
  button.listeners.click();
  await h.advance(100);
  button.listeners.click();
  await h.advance(80);
  assert.equal(button.classList.contains('pressed'), true);
  await h.advance(100);
  assert.equal(button.classList.contains('pressed'), false);
  assert.equal(h.sockets[1].sent.length, 2);
});

test('contain coordinates use the canvas rectangle after reserving navigation height', () => {
  const h = harness();
  const canvas = h.elements['#canvas'];
  canvas.width = 1080; canvas.height = 2400;
  canvas.getBoundingClientRect = () => ({left: 0, top: 0, width: 390, height: 758});
  assert.equal(h.run('position({clientX:195,clientY:379}).x'), 0.5);
  assert.equal(h.run('position({clientX:195,clientY:379}).y'), 0.5);
  assert.equal(h.run('position({clientX:195,clientY:758}).y'), 1);
  assert.ok(h.run('position({clientX:195,clientY:790}).y') > 1);
  assert.ok(h.run('position({clientX:0,clientY:379}).x') < 0);
});

test('stats collapse both overlays, persist, and expand from the corner marker', () => {
  const storage = new Map(), h = harness({storage});
  assert.equal(h.elements['#panel'].hidden, false);
  h.elements['#panel'].listeners.click();
  assert.equal(h.elements['#panel'].hidden, true);
  assert.equal(h.elements.details.hidden, true);
  assert.equal(h.elements['#stats-toggle'].textContent, 'ⓘ');
  const restored = harness({storage});
  assert.equal(restored.elements['#panel'].hidden, true);
  restored.elements['#stats-toggle'].listeners.click();
  assert.equal(restored.elements['#panel'].hidden, false);
  assert.equal(restored.elements.details.hidden, false);
  assert.equal(storage.get('mirage.statsCollapsed'), '0');
});

test('storage failures default to expanded and do not prevent toggling', () => {
  const h = harness({storageFails: true});
  assert.equal(h.elements['#panel'].hidden, false);
  h.elements['#stats-toggle'].listeners.click();
  assert.equal(h.elements['#panel'].hidden, true);
});

test('stats=0 hides even the marker, but errors remain visible in every stats mode', () => {
  for (const search of ['?t=abc', '?t=abc&stats=0']) {
    const h = harness({search, storage: new Map([['mirage.statsCollapsed', '1']])});
    assert.equal(h.elements['#panel'].hidden, true);
    assert.equal(h.elements['#stats-toggle'].hidden, search.includes('stats=0'));
    h.sockets[0].onerror();
    assert.equal(h.elements['#error'].hidden, false);
    assert.match(h.elements['#error'].textContent, /WebSocket error/);
    h.receive(1);
    h.decoders[0].configure = () => { throw Error('unsupported codec'); };
    h.run('configureDecoder()');
    assert.match(h.elements['#error'].textContent, /unsupported codec/);
    assert.equal(h.elements['#panel'].hidden, true);
  }
});

test('keyboard focus is synchronous in click and toggles off without discarding draft', () => {
  const h = harness(), field = h.elements['#text-input'], keyboard = h.elements['#keyboard'];
  keyboard.listeners.click();
  assert.equal(h.document.activeElement, field);
  field.value = '草稿';
  keyboard.listeners.pointerdown({preventDefault() {}});
  keyboard.listeners.click();
  assert.equal(h.document.activeElement, null);
  assert.equal(field.value, '草稿');
  keyboard.listeners.click();
  h.elements['#canvas'].getBoundingClientRect = () => ({left:0, top:0, width:100, height:100});
  h.elements['#canvas'].width = h.elements['#canvas'].height = 100;
  h.elements['#canvas'].listeners.pointerdown({preventDefault() {}, clientX:50, clientY:50, pointerId:1});
  assert.equal(h.document.activeElement, null);
});

test('Return commits final Unicode once; composition and empty Return do not send', () => {
  const h = harness(), field = h.elements['#text-input'];
  h.sockets[0].onopen();
  const input = h.sockets[1], preventDefault = () => {};
  field.value = '中文🙂é';
  field.listeners.keydown({key:'Enter', isComposing:true, preventDefault});
  assert.deepEqual(input.sent, []);
  field.listeners.keydown({key:'Enter', keyCode:229, preventDefault});
  assert.deepEqual(input.sent, []);
  field.listeners.keydown({key:'Enter', isComposing:false, preventDefault});
  assert.deepEqual(JSON.parse(input.sent[0]), {type:'text', text:'中文🙂é', t:0});
  assert.equal(field.value, '');
  field.listeners.keydown({key:'Enter', preventDefault});
  assert.equal(input.sent.length, 1);
});

test('empty Backspace forwards a key; local draft deletion and composition stay local', () => {
  const h = harness(), field = h.elements['#text-input'], preventDefault = () => {};
  h.sockets[0].onopen();
  field.value = 'draft';
  field.listeners.keydown({key:'Backspace', preventDefault});
  field.value = '';
  field.listeners.keydown({key:'Backspace', isComposing:true, preventDefault});
  assert.deepEqual(h.sockets[1].sent, []);
  field.listeners.keydown({key:'Backspace', preventDefault});
  assert.deepEqual(JSON.parse(h.sockets[1].sent[0]), {type:'key', key:'Backspace', t:0});
  field.listeners.beforeinput({inputType:'deleteContentBackward', isComposing:true, preventDefault});
  assert.equal(h.sockets[1].sent.length, 1);
  field.listeners.beforeinput({inputType:'deleteContentBackward', preventDefault});
  assert.equal(h.sockets[1].sent.length, 2);
});

test('failed or oversized text submissions retain the local draft and show an error', () => {
  const h = harness(), field = h.elements['#text-input'];
  for (const text of ['未連線', 'a'.repeat(4097), '🙂'.repeat(2049)]) {
    field.value = text;
    field.listeners.keydown({key:'Enter', preventDefault() {}});
    assert.equal(field.value, text);
    assert.equal(h.elements['#error'].hidden, false);
  }
});

test('visual viewport resize and scroll keep the canvas above the iOS keyboard', () => {
  const listeners = {}, viewport = {height:800, width:390, offsetTop:0, offsetLeft:0,
    addEventListener(type, listener) { listeners[type] = listener; }};
  const h = harness({viewport}), style = h.elements['#viewport'].style;
  assert.equal(style['--view-height'], '800px');
  viewport.height = 420; viewport.offsetTop = 20;
  listeners.resize();
  assert.equal(style['--view-height'], '420px');
  assert.equal(style['--view-top'], '20px');
  viewport.offsetLeft = 5; listeners.scroll();
  assert.equal(style['--view-left'], '5px');
  viewport.height = 800; viewport.offsetTop = 0; listeners.resize();
  assert.equal(style['--view-height'], '800px');
});

test('stats text renders Mac stages without touching video decoding or idle flush', async () => {
  const h = harness({immediateOutput: true});
  h.receive(1);
  const stats = {type: 'stats', age: {p50: 2, p95: 9}, encode: {p50: 3, p95: 7},
    send: {p50: 0.1, p95: 0.4}, transitMs: null, newFrames: 30, heartbeatFrames: 4};
  await h.advance(1500);
  h.sockets[0].onmessage({data: JSON.stringify(stats)});
  assert.match(h.run('macStatsText()'), /Mac: age 2.0\/9.0 · encode 3.0\/7.0 · send 0.1\/0.4 · transit — ms/);
  assert.match(h.run('macStatsText()'), /frames\/s new=30 heartbeat=4/);
  assert.equal(h.run('received'), 1);
  h.run('toggleStats()');
  assert.equal(h.elements['#panel'].hidden, true);
  await h.advance(500);
  assert.equal(h.decoders[0].flushes, 1);
});

test('malformed and unknown stats text only logs, then video continues', () => {
  const h = harness({immediateOutput: true});
  h.receive(1);
  for (const data of ['{bad', 'null', '{"type":"other"}']) h.sockets[0].onmessage({data});
  assert.match(h.run('lines.join(" ")'), /stats JSON error/);
  assert.equal(h.run('macStats'), null);
  h.receive(2, false);
  assert.equal(h.draws(), 2);
  assert.equal(h.run('configurationFailed'), false);
  assert.equal(h.run('localDrops'), 0);
});
