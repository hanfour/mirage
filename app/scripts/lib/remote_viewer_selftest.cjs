const {test} = require('node:test');
const assert = require('node:assert/strict');
require('./remote_connection_selftest.cjs');
require('./remote_viewer_status_selftest.cjs');
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


test('contain coordinates use the canvas rectangle including contain letterboxing', () => {
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

test('viewport is reported once input opens, deduplicated, and ignores the keyboard', () => {
  const listeners = {}, viewport = {height:800, width:390, offsetTop:0, offsetLeft:0,
    addEventListener(type, listener) { listeners[type] = listener; }};
  const h = harness({viewport});
  h.sockets[0].onopen();
  const input = h.sockets[1];
  const reports = () => input.sent.map(s => JSON.parse(s)).filter(m => m.type === 'viewport');
  listeners.resize();
  assert.deepEqual(reports(), [], 'input 還沒 onopen 不該送');
  assert.equal(h.run('inputDrops'), 0);
  input.onopen();
  assert.deepEqual(reports(), [{type:'viewport', width:390, height:800, scale:1}]);
  listeners.scroll();
  assert.equal(reports().length, 1, '尺寸沒變不重送');
  h.elements['#text-input'].focus();
  viewport.height = 420; listeners.resize();
  assert.equal(reports().length, 1, '鍵盤擠掉的高度不回報');
  h.elements['#text-input'].blur();
  viewport.width = 800; viewport.height = 370; listeners.resize();
  assert.deepEqual(reports().at(-1), {type:'viewport', width:800, height:370, scale:1});
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

test('keyboard crops a full-width canvas and visible touches map into its lower half', () => {
  const listeners = {}, viewport = {height:874, width:402, offsetTop:0, offsetLeft:0,
    addEventListener(type, listener) { listeners[type] = listener; }};
  const h = harness({viewport}), canvas = h.elements['#canvas'];
  h.elements['#keyboard'].listeners.click();
  viewport.height = 330; viewport.offsetTop = 20;
  listeners.resize();
  const fullHeight = 402 * 2400 / 1080;
  assert.equal(canvas.style.width, '402px');
  assert.equal(canvas.style.height, fullHeight + 'px');
  assert.equal(canvas.style.transform, `translateY(${330 - fullHeight}px)`);
  // 模擬瀏覽器回傳包含 transform 與被裁切部分的完整矩形。
  canvas.getBoundingClientRect = () => ({left:0, top:20 + 330 - fullHeight, width:402, height:fullHeight});
  const y = h.run('position({clientX:201,clientY:185}).y');
  assert.ok(Math.abs(y - (1 - 165 / fullHeight)) < 1e-9);
  assert.ok(y > 0.5);
  h.sockets[0].onopen();
  canvas.listeners.pointerdown({clientX:201, clientY:185, pointerId:1, preventDefault() {}});
  h.run('flushTouches()');
  assert.equal(JSON.parse(h.sockets[1].sent[0]).points[0].y, y);
  viewport.height = 874; viewport.offsetTop = 0; listeners.resize();
  assert.equal(canvas.style.transform, 'translateY(0px)');
  assert.equal(canvas.style.height, '874px');
});

test('fill-width mode centers a full-width canvas, maps touches, persists, and reports the width-driven size', () => {
  const listeners = {}, viewport = {height:697, width:393, offsetTop:0, offsetLeft:0,
    addEventListener(type, listener) { listeners[type] = listener; }};
  const storage = new Map();
  const h = harness({viewport, storage}), canvas = h.elements['#canvas'];
  assert.equal(canvas.style.height, '697px', '預設仍是完整顯示');
  h.run('fillToggle.listeners.click()');
  const fullHeight = 393 * 2400 / 1080;
  assert.equal(canvas.style.width, '393px');
  assert.equal(canvas.style.height, fullHeight + 'px');
  assert.equal(canvas.style.transform, `translateY(${(697 - fullHeight) / 2}px)`);
  assert.equal(storage.get('mirage.fillWidth'), '1');
  canvas.getBoundingClientRect = () => ({left:0, top:(697 - fullHeight) / 2, width:393, height:fullHeight});
  const center = h.run('position({clientX:196.5,clientY:348.5})');
  assert.ok(Math.abs(center.x - 0.5) < 1e-9 && Math.abs(center.y - 0.5) < 1e-9);
  assert.ok(h.run('position({clientX:196.5,clientY:0}).y') > 0, '可見區頂端對應到被裁掉的那一段之後');
  h.sockets[0].onopen(); h.sockets[1].onopen();
  const report = h.sockets[1].sent.map(m => JSON.parse(m)).filter(m => m.type === 'viewport').at(-1);
  assert.deepEqual(report, {type:'viewport', width:393, height:Math.round(fullHeight), scale:1});
  h.run('fillToggle.listeners.click()');
  assert.equal(canvas.style.height, '697px');
  assert.equal(canvas.style.transform, 'translateY(0px)');
  assert.equal(storage.get('mirage.fillWidth'), '0');
  const restored = harness({viewport, storage: new Map([['mirage.fillWidth', '1']])});
  assert.equal(restored.elements['#canvas'].style.height, fullHeight + 'px', '重新整理後沿用上次的選擇');
});

test('toolbar changes do not enable keyboard cropping and fallback resizes without visualViewport', () => {
  const listeners = {}, viewport = {height:874, width:402, offsetTop:0, offsetLeft:0,
    addEventListener(type, listener) { listeners[type] = listener; }};
  const h = harness({viewport});
  h.elements['#keyboard'].listeners.click();
  viewport.height = 790; listeners.resize();
  assert.equal(h.elements['#canvas'].style.transform, 'translateY(0px)');
  const fallback = harness();
  fallback.run('innerWidth = 402; innerHeight = 874');
  fallback.windowListeners.resize();
  assert.equal(fallback.elements['#canvas'].style.height, '874px');
  assert.equal(fallback.elements['#viewport'].style['--view-width'], '402px');
});
