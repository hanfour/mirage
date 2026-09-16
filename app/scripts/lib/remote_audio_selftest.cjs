const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {harness} = require('./remote_viewer_harness.cjs');
const source = fs.readFileSync(path.join(__dirname, '../../Sources/MirageCore/Resources/remote/viewer-audio.js'), 'utf8');
const {decodeAudioMessage, AudioJitterQueue} = vm.runInNewContext(source + '\n({decodeAudioMessage, AudioJitterQueue})', {ArrayBuffer, Int16Array});
// 寫死線上位元組，避免 encoder 與 decoder 同時寫反卻互相抵銷。
const bytes = [1,2,3,4,5,6,7,8, 0x12,0x34,0x56,0x78, 0,0,0xbb,0x80, 2, 2,1,0,0x80, 0xff,0x7f,0xfe,0xff];
const decode = values => decodeAudioMessage(Uint8Array.from(values).buffer);
test('fixed wire bytes decode to the complete message without modifying input', () => {
  const buffer = Uint8Array.from(bytes).buffer, result = decodeAudioMessage(buffer);
  assert.equal(result.sentNs, 0x0102030405060708n);
  assert.equal(result.seq, 0x12345678);
  assert.equal(result.rate, 48000);
  assert.equal(result.channels, 2);
  assert.ok(result.samples instanceof Int16Array);
  assert.deepEqual([...result.samples], [258, -32768, 32767, -2]);
  result.samples[0] = 0;
  assert.deepEqual([...new Uint8Array(buffer)], bytes);
});
test('header fields use big endian with asymmetric values', () => {
  const item = decode(bytes);
  assert.equal(item.sentNs, 72623859790382856n);
  assert.equal(item.seq, 305419896);
  assert.equal(item.rate, 48000);
});
test('unaligned S16 payload uses little endian and signed values', () => {
  assert.deepEqual([...decode([...bytes.slice(0, 16), 1, 2,1, 0xfe,0xff]).samples], [0x0102, -2]);
});
test('rejects a 17-byte message and an empty payload', () => {
  assert.throws(() => decode(bytes.slice(0, 17)), /length.*17.*empty/);
  assert.throws(() => decode([]), /length/);
});
test('rejects channels zero and three', () => {
  for (const channels of [0, 3]) assert.throws(() => decode([...bytes.slice(0,16), channels, ...bytes.slice(17)]), /channels/);
});
test('rejects rates outside inclusive 8000 to 48000 bounds', () => {
  for (const rateBytes of [[0,0,0x1f,0x3f], [0,0,0xbb,0x81]]) {
    assert.throws(() => decode([...bytes.slice(0,12), ...rateBytes, ...bytes.slice(16)]), /rate/);
  }
  assert.equal(decode([...bytes.slice(0,12), 0,0,0x1f,0x40, ...bytes.slice(16)]).rate, 8000);
  assert.equal(decode(bytes).rate, 48000);
});
test('rejects partial samples and partial stereo frames', () => {
  assert.throws(() => decode(bytes.slice(0,18)), /whole channel frames/);
  assert.throws(() => decode(bytes.slice(0,19)), /whole channel frames/);
});
test('queue preserves FIFO without drops below capacity', () => {
  const queue = new AudioJitterQueue();
  for (let i = 0; i < 10; i++) queue.push(i);
  assert.equal(queue.size, 10); assert.equal(queue.dropped, 0);
  assert.deepEqual(Array.from({length:10}, () => queue.shift()), [0,1,2,3,4,5,6,7,8,9]);
  assert.equal(queue.shift(), undefined); assert.equal(queue.size, 0);
});
test('full queue drops oldest and counts each overflow', () => {
  const queue = new AudioJitterQueue(2);
  queue.push('a'); queue.push('b'); queue.push('c');
  assert.equal(queue.size, 2); assert.equal(queue.dropped, 1);
  assert.equal(queue.shift(), 'b');
  queue.push('d'); queue.push('e');
  assert.equal(queue.dropped, 2);
  assert.equal(queue.shift(), 'd'); assert.equal(queue.shift(), 'e');
});
test('audio waits for video handshake, carries token, and audio=0 disables socket', () => {
  const h = harness({audio:true, search:'?t=abc'});
  assert.equal(h.sockets.length, 1);
  h.sockets[0].onopen();
  assert.equal(h.sockets[2].url, 'ws://127.0.0.1/ws/audio?t=abc');
  assert.equal(h.sockets[2].binaryType, 'arraybuffer');
  const disabled = harness({audio:true, search:'?t=abc&audio=0'});
  disabled.sockets[0].onopen();
  assert.equal(disabled.sockets.length, 2);
});
test('audio disconnect leaves video and input alive with an independent visible notice', () => {
  const h = harness({audio:true, search:'?t=abc&stats=0', immediateOutput:true});
  h.sockets[0].onopen(); h.sockets[2].onopen();
  h.sockets[2].onclose();
  h.sockets[1].onopen(); h.receive(1);
  assert.equal(h.run('reconnecting'), false);
  assert.equal(h.run('audioState'), 'disconnected');
  assert.equal(h.run('audioNotice.hidden'), false);
  assert.equal(h.sockets[0].readyState, 1); assert.equal(h.sockets[1].readyState, 1);
});
test('invalid audio counts every packet but logs at most once per second', async () => {
  const h = harness({audio:true, search:'?t=abc'});
  h.sockets[0].onopen();
  for (let n = 0; n < 5; n++) h.run('audioSocket.onmessage({data:new ArrayBuffer(17)})');
  assert.equal(h.run('audioDecodeErrors'), 5);
  assert.equal(h.run('lines.filter(line => line.includes("audio decode errors=")).length'), 1);
  await h.advance(1000);
  h.run('audioSocket.onmessage({data:new ArrayBuffer(17)})');
  assert.equal(h.run('lines.filter(line => line.includes("audio decode errors=")).length'), 2);
});
test('mute persists without closing socket and stats expose buffer and drops', () => {
  const storage = new Map(), h = harness({audio:true, search:'?t=abc', storage});
  h.sockets[0].onopen();
  h.run('audioToggle.listeners.click()');
  assert.equal(storage.get('mirage.audioEnabled'), '0');
  assert.equal(h.sockets[2].readyState, 1);
  assert.match(h.run('audioStatsText()'), /buffer=0.0 ms dropped=0/);
  assert.equal(harness({storage}).run('audioEnabled'), false);
});
test('video reconnect closes old audio and ignores stale callbacks', async () => {
  const h = harness({audio:true, search:'?t=abc'});
  h.sockets[0].onopen();
  const old = h.sockets[2], stale = old.onclose;
  h.sockets[0].onclose();
  assert.equal(old.readyState, 3);
  await h.advance(1000);
  h.sockets[3].onopen(); h.sockets[5].onopen(); stale();
  assert.equal(h.run('audioState'), 'connected');
});
test('schedule decision pre-rolls, follows the timeline, and drops when too far ahead', () => {
  const h = harness({audio:true});
  // vm 脈絡的物件原型與這裡不同，deepEqual 會退化成嚴格比較，所以比 JSON 字串。
  const decide = (now, scheduled) => h.run(`JSON.stringify(audioScheduleDecision(${now}, ${scheduled}))`);
  // 第一批：還沒排過，從現在加蓄水時間開始。
  assert.equal(decide(10, null), '{"startAt":10.1,"reset":true,"drop":false}');
  // 正常接續：沿用上一批的結束時間，不重新蓄水。
  assert.equal(decide(10, 10.05), '{"startAt":10.05,"reset":false,"drop":false}');
  // 排程時間已經在現在之前：排在過去會立刻播完、聽起來是破音，所以重新蓄水。
  assert.equal(decide(10, 9.99), '{"startAt":10.1,"reset":true,"drop":false}');
  // 剛好等於現在不算落後，邊界往兩側各驗一次。
  assert.equal(decide(10, 10), '{"startAt":10,"reset":false,"drop":false}');
  // 領先剛好等於上限不丟，超過才丟，不讓延遲一路長上去。
  assert.equal(decide(10, 10.5), '{"startAt":10.5,"reset":false,"drop":false}');
  assert.equal(decide(10, 10.6), '{"startAt":10.6,"reset":false,"drop":true}');
});
test('speech messages render, and only the final one schedules the clear timer', () => {
  const h = harness({audio:true});
  h.sockets[0].onopen();
  // 逐字更新期間不排清除計時器，否則講到一半字幕就消失。
  h.sockets[0].onmessage({data: JSON.stringify({type:'speech', text:'今天', final:false})});
  assert.equal(h.run('speechPanel.textContent'), '今天');
  assert.equal(h.run('speechPanel.hidden'), false);
  assert.equal(h.run('speechClearTimer === null'), true);
  h.sockets[0].onmessage({data: JSON.stringify({type:'speech', text:'今天天氣很好', final:false})});
  assert.equal(h.run('speechPanel.textContent'), '今天天氣很好');
  assert.equal(h.run('speechClearTimer === null'), true);
  // 最後一則才排清除，讓字幕留一段時間而不是播完就不見。
  h.sockets[0].onmessage({data: JSON.stringify({type:'speech', text:'今天天氣很好', final:true})});
  assert.equal(h.run('speechClearTimer !== null'), true);
});
test('speech without a string text is ignored instead of showing undefined', () => {
  const h = harness({audio:true});
  h.sockets[0].onopen();
  h.sockets[0].onmessage({data: JSON.stringify({type:'speech', text:7, final:false})});
  assert.equal(h.run('speechPanel.textContent') || '', '');
  assert.equal(h.run('speechPanel.hidden'), true);
});
test('long transcripts only show the tail so they do not fill the screen', () => {
  const h = harness({audio:true});
  h.sockets[0].onopen();
  const long = '今天天氣很好'.repeat(40);   // 240 字
  h.sockets[0].onmessage({data: JSON.stringify({type:'speech', text:long, final:false})});
  const shown = h.run('speechPanel.textContent');
  assert.equal(shown.length, 80);
  assert.equal(shown, long.slice(-80));
});
