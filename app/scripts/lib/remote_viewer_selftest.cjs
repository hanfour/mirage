// 真正執行 viewer.html，以假 WebCodecs 與時鐘驗證靜止／恢復；不開 App 或連網。
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const html = fs.readFileSync(path.join(__dirname, '../../Sources/MirageCore/Resources/remote/viewer.html'), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];

function harness({immediateOutput = false, search = '?t=abc'} = {}) {
  const timers = new Map(), decoders = [], sockets = [];
  let timerID = 0, now = 0, draws = 0;
  function element() {
    const classes = new Set(), listeners = {};
    return {listeners, hidden: false,
      getContext: () => ({drawImage() { draws++; }}),
      addEventListener(type, listener) { listeners[type] = listener; },
      classList: {
        add: value => classes.add(value), remove: value => classes.delete(value),
        contains: value => classes.has(value),
        toggle(value, enabled) { if (enabled) classes.add(value); else classes.delete(value); },
      },
    };
  }
  const elements = Object.fromEntries(['#canvas', '#panel', '#log', '#nav', 'details'].map(id => [id, element()]));
  const buttons = [...html.matchAll(/<button[^>]+data-key="([^"]+)"/g)].map(match =>
    Object.assign(element(), {dataset: {key: match[1]}}));
  elements['#nav'].querySelectorAll = () => buttons;
  const root = element();
  class Decoder {
    constructor(callbacks) {
      this.callbacks = callbacks;
      this.state = 'unconfigured';
      this.decodeQueueSize = 0;
      this.chunks = [];
      this.held = [];
      this.flushes = 0;
      this.requiresKey = true;
      decoders.push(this);
    }
    configure() { this.state = 'configured'; this.requiresKey = true; }
    decode(chunk) {
      if (this.requiresKey && chunk.type !== 'key') throw Error('key required after flush');
      this.requiresKey = false;
      this.chunks.push(chunk);
      if (immediateOutput) this.emit(chunk);
      else this.held.push(chunk);
    }
    emit(chunk) {
      this.callbacks.output({timestamp: chunk.timestamp, displayWidth: 8, displayHeight: 1, close() {}});
    }
    flush() {
      this.flushes++;
      this.requiresKey = true; // 規範在呼叫時就設旗標，不是 Promise 完成時。
      if (this.rejectFlush) return Promise.reject(Error('flush rejected'));
      for (const chunk of this.held.splice(0)) {
        this.emit(chunk);
      }
      return Promise.resolve();
    }
    reset() { this.held = []; this.state = 'unconfigured'; }
    close() { this.state = 'closed'; }
  }
  class Socket {
    static OPEN = 1;
    constructor(url) { this.url = url; this.readyState = 1; this.bufferedAmount = 0; this.sent = []; sockets.push(this); }
    send(text) { this.sent.push(text); }
  }
  const context = vm.createContext({
    document: {querySelector: selector => elements[selector], documentElement: root, addEventListener() {}, visibilityState: 'visible'},
    location: {search, protocol: 'http:', host: '127.0.0.1'},
    navigator: {userAgent: 'test'}, screen: {width: 8, height: 1},
    innerWidth: 8, innerHeight: 1, devicePixelRatio: 1, isSecureContext: true,
    URLSearchParams, WebSocket: Socket, VideoDecoder: Decoder,
    EncodedVideoChunk: class {constructor(options) { Object.assign(this, options); }},
    performance: {now: () => now},
    setTimeout(fn, delay) { timers.set(++timerID, {fn, at: now + delay}); return timerID; },
    clearTimeout(id) { timers.delete(id); }, setInterval() {},
  });
  vm.runInContext(script, context);
  function receive(sequence, key = true) {
    vm.runInContext(`{
      const bytes = new Uint8Array(21), header = new DataView(bytes.buffer);
      header.setBigUint64(0, 1n); header.setUint32(8, ${sequence}); header.setUint8(12, ${key ? 1 : 0});
      bytes.set([0, 0, 0, 1, ${key ? 0x67 : 0x41}, 0x42, 0, 0x1f], 13);
      video.onmessage({data: bytes.buffer});
    }`, context);
  }
  async function advance(ms) {
    now += ms;
    for (const [id, timer] of [...timers]) {
      if (timer.at <= now) { timers.delete(id); await timer.fn(); }
    }
  }
  return {receive, advance, decoders, sockets, timers, elements, buttons, root,
    run: expression => vm.runInContext(expression, context), draws: () => draws};
}

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
