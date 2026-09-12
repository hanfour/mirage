const {test} = require('node:test');
const assert = require('node:assert/strict');
const {harness} = require('./remote_viewer_harness.cjs');

test('negative Safari pointer IDs are sent unchanged across all phases', async () => {
  const h = harness();
  h.sockets[0].onopen();
  const canvas = h.elements['#canvas'];
  canvas.width = canvas.height = 100;
  canvas.getBoundingClientRect = () => ({left:0, top:0, width:100, height:100});
  const fire = (type, pointerId) => canvas.listeners[type]({pointerId, clientX:50, clientY:50, preventDefault() {}});
  for (const [type, id] of [['pointerdown', -10102172], ['pointerdown', 1807384342],
    ['pointermove', -10102172], ['pointerup', -10102172], ['pointerdown', -42],
    ['pointercancel', 1807384342], ['pointerup', -42]]) { fire(type, id); await h.advance(16); }
  assert.deepEqual(h.sockets[1].sent.flatMap(s => JSON.parse(s).points.map(p => p.id)), [-10102172, 1807384342, -10102172, -10102172, -42, 1807384342, -42]);
  assert.equal(h.run('active.size'), 0);
  fire('pointermove', -10102172);
  assert.equal(h.sockets[1].sent.length, 7);
});


test('either socket reconnects the pair with the same token and a fresh decoder waiting for IDR', async () => {
  for (const closed of [0, 1]) {
    const h = harness({immediateOutput:true});
    h.sockets[0].onopen(); h.sockets[1].onopen(); h.receive(99);
    h.run('active.set(-10102172, {queue:[], ended:false})');
    const oldMessage = h.sockets[0].onmessage, oldClose = h.sockets[1].onclose;
    h.sockets[closed].onclose(); oldClose();
    assert.equal(h.run('status'), 'reconnecting (1/3)');
    assert.equal(h.run('active.size'), 0);
    assert.equal(h.decoders[0].state, 'closed');
    await h.advance(999); assert.equal(h.sockets.length, 2);
    await h.advance(1); assert.equal(h.sockets.length, 3);
    assert.equal(h.sockets[2].url, h.sockets[0].url);
    assert.equal(h.decoders[1].state, 'configured');
    h.sockets[2].onopen(); h.sockets[3].onopen();
    oldMessage({data:'{"type":"stats","newFrames":999}'});
    assert.equal(h.run('macStats'), null);
    h.receive(1, false);
    assert.equal(h.decoders[1].chunks.length, 0);
    assert.equal(h.run('status'), 'reconnecting (1/3)');
    h.receive(2);
    assert.equal(h.run('status'), 'streaming');
    assert.equal(h.run('reconnectAttempts'), 0);
    assert.equal(h.run('gaps'), 0);
    assert.equal(h.elements['#error'].hidden, true);
  }
});

test('failed retries use 1/2/4 second delays and only then show reload, including stats=0', async () => {
  const h = harness({search:'?t=abc&stats=0'});
  h.sockets[0].onclose();
  for (const [index, delay] of [1000, 2000, 4000].entries()) {
    assert.equal(h.run('status'), `reconnecting (${index + 1}/3)`);
    assert.equal(h.elements['#error'].hidden, true);
    const count = h.sockets.length;
    await h.advance(delay - 1); assert.equal(h.sockets.length, count);
    await h.advance(1); assert.equal(h.sockets.length, count + 1);
    // Even video opening does not reset the budget if input never opens.
    h.sockets.at(-1).onopen();
    h.sockets.at(-1).onclose();
  }
  assert.match(h.run('status'), /reload to reconnect/);
  assert.equal(h.elements['#error'].hidden, false);
  const count = h.sockets.length;
  await h.advance(10000); assert.equal(h.sockets.length, count);
});

test('a stalled handshake times out instead of hanging a retry forever', async () => {
  const h = harness();
  await h.advance(5000);
  assert.equal(h.run('status'), 'reconnecting (1/3)');
  await h.advance(1000);
  await h.advance(5000);
  assert.equal(h.run('status'), 'reconnecting (2/3)');
});

test('decode throws and closed-decoder error callbacks rebuild/configure and stop at three errors', () => {
  for (const callback of [false, true]) {
    const h = harness();
    h.receive(1);
    let sequence = 1;
    for (let n = 1; n <= 3; n++) {
      const old = h.decoders.at(-1);
      if (callback) { old.close(); old.callbacks.error(Error('bad bitstream')); }
      else { old.decode = () => { throw Error('decode failed'); }; h.receive(++sequence); }
      assert.equal(old.state, 'closed');
      assert.equal(h.run('pending.size'), 0);
      assert.equal(h.run('waiting'), true);
      if (n < 3) {
        assert.equal(h.decoders.at(-1).state, 'configured');
        assert.equal(h.decoders.length, n + 1);
        assert.equal(h.sockets[0].sent.length, n);
        h.receive(++sequence, false);
        assert.equal(h.decoders.at(-1).chunks.length, 0);
        old.callbacks.error(Error('stale error'));
        assert.equal(h.run('decodeErrors'), n);
      }
    }
    assert.equal(h.run('configurationFailed'), true);
    assert.match(h.elements['#error'].textContent, /3 consecutive errors/);
    h.receive(100);
    assert.equal(h.decoders.length, 3);
  }
});

test('successful output resets the consecutive decoder error count', () => {
  const h = harness({immediateOutput:true});
  h.receive(1);
  for (let n = 2; n <= 5; n++) {
    h.decoders.at(-1).callbacks.error(Error('transient'));
    assert.equal(h.run('decodeErrors'), 1);
    h.receive(n);
    assert.equal(h.run('decodeErrors'), 0);
  }
  assert.equal(h.run('configurationFailed'), false);
  assert.equal(h.draws(), 5);
});


test('old flush completion and output cannot affect a reconnected decoder', async () => {
  const h = harness();
  h.sockets[0].onopen(); h.receive(1);
  const old = h.decoders[0];
  let complete;
  old.flush = () => new Promise(resolve => { complete = resolve; });
  const flushing = h.advance(2000);
  h.sockets[0].onclose();
  await h.advance(1000);
  h.sockets[2].onopen();
  const sent = h.sockets[2].sent.length;
  old.emit(old.chunks[0]);
  complete(); await flushing;
  assert.equal(h.draws(), 0);
  assert.equal(h.sockets[2].sent.length, sent);
  assert.equal(h.run('waiting'), true);
});

test('visibilitychange and pageshow restart exhausted CLOSED sockets with a fresh budget', () => {
  for (const event of ['visibilitychange', 'pageshow']) {
    const h = harness({immediateOutput:true});
    h.sockets[0].onopen(); h.sockets[1].onopen(); h.receive(1);
    h.sockets[0].readyState = h.sockets[1].readyState = 3;
    h.run('reconnectAttempts = 3');
    h.document.visibilityState = 'visible';
    (event === 'visibilitychange' ? h.documentListeners : h.windowListeners)[event]();
    assert.equal(h.sockets.length, 3);
    assert.equal(h.run('reconnectAttempts'), 0);
    assert.equal(h.run('status'), 'reconnecting (0/3)');
    assert.equal(h.decoders[0].state, 'closed');
    assert.equal(h.decoders[1].state, 'configured');
    assert.equal(h.run('waiting'), true);
    assert.equal(h.sockets[2].url, h.sockets[0].url);
    // The second lifecycle event must not replace an in-flight foreground connection.
    h.sockets[2].readyState = 0;
    h.windowListeners.pageshow();
    assert.equal(h.sockets.length, 3);
  }
});

test('background callbacks spend no retries and stale backoff cannot run after foreground restart', async () => {
  const h = harness();
  h.sockets[0].onclose();
  const staleCallbacks = [...h.timers.values()].map(timer => timer.fn);
  await h.advance(500);
  h.document.visibilityState = 'hidden'; h.documentListeners.visibilitychange();
  for (let n = 0; n < 3; n++) {
    await h.advance(60000);
    for (const callback of staleCallbacks) await callback();
    assert.equal(h.sockets.length, 1);
    assert.equal(h.run('reconnectAttempts'), 0);
  }
  h.document.visibilityState = 'visible'; h.documentListeners.visibilitychange();
  assert.equal(h.sockets.length, 2);
  for (const callback of staleCallbacks) await callback();
  assert.equal(h.sockets.length, 2);
  h.sockets[1].onclose();
  await h.advance(999); assert.equal(h.sockets.length, 2);
  await h.advance(1); assert.equal(h.sockets.length, 3);
  assert.equal(h.run('reconnectAttempts'), 1);
});

test('connection timeout excludes frozen background time when both sockets remain open', async () => {
  const h = harness();
  h.sockets[0].onopen(); h.sockets[1].onopen();
  await h.advance(1000);
  h.document.visibilityState = 'hidden'; h.documentListeners.visibilitychange();
  await h.advance(60000);
  h.document.visibilityState = 'visible'; h.documentListeners.visibilitychange();
  await h.advance(3999);
  assert.equal(h.run('reconnecting'), false);
  await h.advance(1);
  assert.equal(h.run('status'), 'reconnecting (1/3)');
});

test('healthy foreground events keep the existing pair', () => {
  const h = harness({immediateOutput:true});
  h.sockets[0].onopen(); h.sockets[1].onopen(); h.receive(1);
  h.documentListeners.visibilitychange(); h.windowListeners.pageshow();
  assert.equal(h.sockets.length, 2);
  assert.equal(h.decoders.length, 1);
});

test('a deferred up does not alias the next finger to the old wire ID', async () => {
  const h = harness();
  h.sockets[0].onopen();
  const canvas = h.elements['#canvas'], input = h.sockets[1];
  canvas.width = canvas.height = 100;
  canvas.getBoundingClientRect = () => ({left:0, top:0, width:100, height:100});
  const fire = (type, pointerId) => canvas.listeners[type]({pointerId, clientX:50, clientY:50, preventDefault() {}});
  fire('pointerdown', -10102172);
  await h.advance(16);
  input.bufferedAmount = 65536;
  fire('pointerup', -10102172);
  await h.advance(16);
  input.bufferedAmount = 0;
  fire('pointerdown', 1807384342);
  await h.advance(16);
  assert.deepEqual(input.sent.flatMap(s => JSON.parse(s).points.map(p => p.id)), [-10102172, -10102172, 1807384342]);
  assert.equal(h.run('inputDrops'), 1);
});


test('a new foreground transition replaces a handshake left CONNECTING in the background', () => {
  const h = harness();
  h.sockets[0].readyState = 3;
  h.documentListeners.visibilitychange();
  h.sockets[1].readyState = 0;
  h.document.visibilityState = 'hidden'; h.documentListeners.visibilitychange();
  h.document.visibilityState = 'visible'; h.documentListeners.visibilitychange();
  assert.equal(h.sockets.length, 3);
  assert.equal(h.sockets[1].readyState, 3);
  assert.equal(h.run('reconnectAttempts'), 0);
});

function setup() {
  const h = harness();
  h.run('canvas.width = 8; canvas.height = 1; connectInput(generation)');
  const pointer = (phase, id, x = 0.5) => h.elements['#canvas'].listeners['pointer' + phase]({
    preventDefault() {}, pointerId:id, clientX:x * 8, clientY:0.5,
  });
  const batches = () => h.sockets.at(-1).sent.map(JSON.parse).filter(x => x.type === 'touches');
  return {h, pointer, batches};
}
test('two fingers emit once per frame, latest moves win, idle emits nothing', async () => {
  const {h, pointer, batches} = setup();
  pointer('down', -1); pointer('down', 2);
  assert.equal(batches().length, 0);
  await h.advance(16);
  assert.deepEqual(batches()[0].points.map(p => p.phase), ['down', 'down']);
  for (let i = 0; i < 20; i++) { pointer('move', -1, i / 20); pointer('move', 2, 1 - i / 20); }
  await h.advance(16);
  assert.equal(batches().length, 2);
  assert.deepEqual(batches()[1].points.map(p => p.x), [0.95, 1 - 0.95]);
  await h.advance(16);
  assert.equal(batches().length, 2);
});
test('down, move and up in one frame survive as ordered batches', async () => {
  const {h, pointer, batches} = setup();
  pointer('down', 1); pointer('move', 1, 0.7); pointer('up', 1, 0.8); pointer('move', 1, 0.9);
  for (let i = 0; i < 3; i++) await h.advance(16);
  assert.deepEqual(batches().map(b => b.points[0].phase), ['down', 'move', 'up']);
  assert.equal(h.run('active.size'), 0);
});
test('background fallback sends cancellation even when rAF stops', async () => {
  const {h, pointer, batches} = setup();
  pointer('down', 1);
  h.document.visibilityState = 'hidden'; h.documentListeners.visibilitychange();
  pointer('cancel', 1);
  await h.advance(16); await h.advance(16);
  assert.deepEqual(batches().map(b => b.points[0].phase), ['down', 'cancel']);
  assert.equal(h.run('active.size'), 0);
});
test('backpressure retains edges until send succeeds', async () => {
  const {h, pointer, batches} = setup();
  pointer('down', 1); pointer('up', 1);
  h.sockets.at(-1).bufferedAmount = 65536;
  await h.advance(16);
  assert.equal(batches().length, 0);
  h.sockets.at(-1).bufferedAmount = 0;
  await h.advance(16); await h.advance(16);
  assert.deepEqual(batches().map(b => b.points[0].phase), ['down', 'up']);
});

test('viewer displays actual RPC rate and coalesced batches', () => {
  const h = harness();
  h.sockets[0].onmessage({data:JSON.stringify({type:'stats', inputRPCsPerSecond:62.51, inputCoalesced:59})});
  assert.match(h.run('macStatsText()'), /input RPC\/s=62.5 coalesced=59/);
});
