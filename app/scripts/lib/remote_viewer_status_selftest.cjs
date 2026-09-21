const {test} = require('node:test');
const assert = require('node:assert/strict');
const {harness, html} = require('./remote_viewer_harness.cjs');

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

test('nav=0 hides navigation and handle independently of stats', () => {
  for (const suffix of ['', '&stats=0']) {
    const h = harness({search: '?t=abc&nav=0' + suffix, storage:new Map([['mirage.statsCollapsed', '0']])});
    assert.equal(h.elements['#nav'].hidden, true);
    assert.equal(h.elements['#nav-handle'].hidden, true);
    assert.equal(h.root.classList.contains('no-nav'), true);
    assert.equal(h.elements.details.hidden, suffix !== '');
  }
  assert.match(html, /:root.no-nav\{--nav-height:0px\}/);
  assert.match(html, /canvas\{[^}]*height:100%/);
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

test('stats collapse both overlays, persist, and expand from the corner marker', () => {
  const storage = new Map([['mirage.statsCollapsed', '0']]), h = harness({storage});
  assert.equal(h.elements['#panel'].hidden, false);
  h.elements['#stats-toggle'].listeners.click();
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

test('storage failures default to collapsed and do not prevent toggling', () => {
  const h = harness({storageFails: true});
  assert.equal(h.elements['#panel'].hidden, true);
  h.elements['#stats-toggle'].listeners.click();
  assert.equal(h.elements['#panel'].hidden, false);
});

test('stats=0 hides even the marker, but errors remain visible in every stats mode', () => {
  for (const search of ['?t=abc', '?t=abc&stats=0']) {
    const h = harness({search, storage: new Map([['mirage.statsCollapsed', '1']])});
    assert.equal(h.elements['#panel'].hidden, true);
    assert.equal(h.elements['#stats-toggle'].hidden, search.includes('stats=0'));
    h.run('reportError("WebSocket error")');
    assert.equal(h.elements['#error'].hidden, false);
    assert.match(h.elements['#error'].textContent, /WebSocket error/);
    h.receive(1);
    h.decoders[0].configure = () => { throw Error('unsupported codec'); };
    h.run('configureDecoder()');
    assert.match(h.elements['#error'].textContent, /unsupported codec/);
    assert.equal(h.elements['#panel'].hidden, true);
  }
});

test('stats text renders Mac stages without touching video decoding or idle flush', async () => {
  const h = harness({immediateOutput: true, storage:new Map([['mirage.statsCollapsed', '0']])});
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


test('navigation hides after idle, resets on interaction and returns by tap or swipe', async () => {
  const h = harness(), nav = h.elements['#nav'], handle = h.elements['#nav-handle'];
  await h.advance(2999);
  assert.equal(nav.hidden, false);
  h.documentListeners.pointerdown();
  await h.advance(2999);
  assert.equal(nav.hidden, false);
  await h.advance(1);
  assert.equal(nav.hidden, true);
  assert.equal(handle.hidden, false);
  handle.listeners.click();
  assert.equal(nav.hidden, false);
  await h.advance(3000);
  let stopped = 0;
  const event = {clientY:800, pointerId:1, preventDefault() {}, stopPropagation() { stopped++; }};
  handle.listeners.pointerdown(event);
  handle.listeners.pointermove({...event, clientY:790});
  assert.equal(nav.hidden, false);
  for (const type of ['pointerdown', 'pointermove', 'pointerup', 'pointercancel']) nav.listeners[type](event);
  assert.equal(stopped, 6);
  assert.equal(h.run('active.size'), 0);
  const disabled = harness({search:'?nav=0'});
  disabled.elements['#nav-handle'].listeners.click();
  await disabled.advance(3000);
  assert.equal(disabled.elements['#nav'].hidden, true);
  assert.equal(disabled.elements['#nav-handle'].hidden, true);
});


test('fresh installs show only the small stats marker and link an authenticated manifest', () => {
  const h = harness();
  assert.equal(h.elements['#panel'].hidden, true);
  assert.equal(h.elements.details.hidden, true);
  assert.equal(h.elements['#stats-toggle'].textContent, 'ⓘ');
  assert.equal(h.elements['#stats-toggle'].hidden, false);
  assert.equal(h.elements['#manifest'].attributes.href, '/manifest.webmanifest?t=abc');
  const manifest = JSON.parse(require('node:fs').readFileSync(require('node:path').join(__dirname,
    '../../Sources/MirageCore/Resources/remote/manifest.webmanifest'), 'utf8'));
  assert.equal(manifest.display, 'standalone');
  assert.equal(manifest.orientation, 'portrait');
  assert.equal(manifest.name, 'Mirage');
  assert.equal(manifest.background_color, '#000000');
  assert.equal(manifest.start_url, undefined);
  assert.match(html, /viewport-fit=cover/);
  assert.match(html, /apple-mobile-web-app-capable" content="yes"/);
  assert.match(html, /apple-mobile-web-app-status-bar-style" content="black-translucent"/);
});


test('transit requires ten new frames, regardless of heartbeat count', () => {
  const h = harness();
  for (const count of [0, 4, 9, 10, 11]) {
    h.run(`macStats = {newFrames: ${count}, heartbeatFrames: 100, transitMs: 478.6}`);
    const text = h.run('macStatsText()');
    assert.ok(text.includes(count < 10 ? `transit －（樣本 ${count}）` : 'transit 478.6 ms'));
  }
  h.run('macStats = {newFrames: 10}');
  assert.ok(h.run('macStatsText()').includes('transit — ms'));
});

function health(h, emulatorConnected, secondsSinceNewFrame) {
  h.sockets[0].onmessage({data: JSON.stringify({type:'stats', emulatorConnected, secondsSinceNewFrame})});
}

test('disconnected emulator shows a dismissible warning even with stats disabled', () => {
  const h = harness({search:'?t=abc&stats=0'}), banner = h.elements['#frame-warning'];
  health(h, false, 960);
  assert.equal(banner.hidden, false);
  assert.equal(banner.textContent, '模擬器未連線，畫面已停止 960 秒');
  banner.listeners.click();
  assert.equal(banner.hidden, true);
  health(h, false, 961);
  assert.equal(banner.hidden, true); // 每秒 stats 不是新故障事件。
  health(h, true, 0);
  health(h, false, 1);
  assert.equal(banner.hidden, false);
});

test('fresh frames from a connected emulator automatically clear the warning', () => {
  const h = harness(), banner = h.elements['#frame-warning'];
  health(h, false, 16);
  assert.equal(banner.hidden, false);
  health(h, true, 0.2);
  assert.equal(banner.hidden, true);
  health(h, true, 8);
  assert.equal(banner.hidden, false);
  health(h, true, 0);
  assert.equal(banner.hidden, true);
});

test('stalled warning requires strictly more than five seconds; heartbeat does not clear it', () => {
  const h = harness(), banner = h.elements['#frame-warning'];
  for (const seconds of [0, 4.9, 5]) { health(h, true, seconds); assert.equal(banner.hidden, true); }
  health(h, true, 5.01);
  assert.equal(banner.hidden, false);
  h.receive(1); // 即使二進位心跳仍解碼，Mac 回報的幀齡仍是故障依據。
  assert.equal(banner.hidden, false);
  banner.listeners.click();
  health(h, false, 6); // 停格變成斷線是新事件。
  assert.equal(banner.hidden, false);
  health(h, true, 0);
  assert.equal(banner.hidden, true);
});

test('stalled text identifies a connected emulator and changing either event restores dismissed warnings', () => {
  const h = harness(), banner = h.elements['#frame-warning'];
  health(h, true, 8.9);
  assert.equal(banner.hidden, false);
  assert.equal(banner.textContent, '畫面已停止 8 秒（模擬器仍連線）');
  banner.listeners.click();
  health(h, true, 9);
  assert.equal(banner.hidden, true);
  health(h, false, 10);
  assert.equal(banner.hidden, false);
  assert.equal(banner.textContent, '模擬器未連線，畫面已停止 10 秒');
  banner.listeners.click();
  health(h, false, 11);
  assert.equal(banner.hidden, true);
  health(h, true, 12);
  assert.equal(banner.hidden, false);
  assert.equal(banner.textContent, '畫面已停止 12 秒（模擬器仍連線）');
});

test('expanded stats occupy at most forty percent and only the toggle intercepts input', () => {
  const h = harness(), button = h.elements['#stats-toggle'], text = h.elements['#stats-text'];
  button.listeners.click();
  assert.equal(text.hidden, false);
  assert.match(html, /#stats-text\{[^}]*max-height:40%;overflow:auto/);
  assert.match(html, /#stats-text,#stats-text \*\{pointer-events:none\}/);
  assert.match(html, /#stats-toggle\{pointer-events:auto;/);
  assert.equal(h.elements['#panel'].listeners.click, undefined);
  button.listeners.pointerdown({clientY:100, pointerId:1});
  button.listeners.pointermove({clientY:60});
  button.listeners.pointerup();
  button.listeners.click(); // 拖曳後合成 click 不得收合。
  assert.equal(text.scrollTop, 40);
  assert.equal(text.hidden, false);
  button.listeners.wheel({deltaY:20, preventDefault() {}});
  button.listeners.keydown({key:'ArrowDown', preventDefault() {}});
  assert.equal(text.scrollTop, 100);
  h.sockets[0].onopen();
  h.elements['#canvas'].listeners.pointerdown({clientX:4, clientY:0.5, pointerId:7, preventDefault() {}});
  h.run('flushTouches()');
  assert.equal(JSON.parse(h.sockets[1].sent[0]).points[0].phase, 'down');
  button.listeners.click();
  assert.equal(text.hidden, true);
});

function textState(h, textPaused) {
  h.sockets[0].onmessage({data: JSON.stringify({type: 'stats', emulatorConnected: true, secondsSinceNewFrame: 0, textPaused})});
}

test('paused text submission is visible on the phone and resumable from there', () => {
  const h = harness({search: '?t=abc&stats=0'}), banner = h.elements['#text-warning'];
  h.sockets[0].onopen();
  const input = h.sockets[1];
  assert.equal(banner.hidden, true);
  textState(h, 'clipboardConflict');
  assert.equal(banner.hidden, false);
  assert.equal(banner.textContent, '文字輸入已暫停：剪貼簿被其他程式改動。點這裡核對後恢復');
  banner.listeners.click();
  assert.deepEqual(JSON.parse(input.sent.at(-1)), {type: 'textResume'});
  assert.equal(banner.hidden, true);
  // Mac 端真的恢復之後，下一則 stats 不會再把橫幅叫回來。
  textState(h, null);
  assert.equal(banner.hidden, true);
});

test('unknown pause reasons still reach the phone instead of being swallowed', () => {
  const h = harness(), banner = h.elements['#text-warning'];
  textState(h, 'transport("disconnected")');
  assert.equal(banner.textContent, '文字輸入已暫停：與模擬器的連線出問題。點這裡核對後恢復');
  textState(h, 'somethingNobodyMappedYet');
  assert.equal(banner.textContent, '文字輸入已暫停：somethingNobodyMappedYet。點這裡核對後恢復');
  textState(h, undefined);
  assert.equal(banner.hidden, true);
});
