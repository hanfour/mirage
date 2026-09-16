function decodeAudioMessage(arrayBuffer) {
  if (!(arrayBuffer instanceof ArrayBuffer)) throw Error('audio message must be an ArrayBuffer');
  if (arrayBuffer.byteLength <= 17) throw Error('audio length must exceed 17 bytes; payload must not be empty');
  const header = new DataView(arrayBuffer), channels = header.getUint8(16);
  if (channels !== 1 && channels !== 2) throw Error('audio channels must be 1 or 2');
  const rate = header.getUint32(12, false);
  if (rate < 8000 || rate > 48000) throw Error('audio rate must be between 8000 and 48000');
  if ((arrayBuffer.byteLength - 17) % (2 * channels)) throw Error('audio payload must contain whole channel frames');
  // 標頭長度不是二的倍數，另外配置也避免依賴主機的位元組順序。
  const samples = new Int16Array((arrayBuffer.byteLength - 17) / 2);
  for (let i = 0; i < samples.length; i++) samples[i] = header.getInt16(17 + i * 2, true);
  return {sentNs:header.getBigUint64(0, false), seq:header.getUint32(8, false), rate, channels, samples};
}
class AudioJitterQueue {
  constructor(capacity = 10) {
    if (!Number.isInteger(capacity) || capacity < 1) throw Error('audio queue capacity must be a positive integer');
    this.capacity = capacity;
    this.items = [];
    this.dropCount = 0;
  }
  push(item) {
    // 音訊落後比丟一小段更難聽，而且沒有等待下一個 keyframe 的恢復點。
    if (this.size === this.capacity) { this.items.shift(); this.dropCount++; }
    this.items.push(item);
  }
  shift() { return this.items.shift(); }
  get size() { return this.items.length; }
  get dropped() { return this.dropCount; }
}
// 排程決策抽成純函式：這是整條播放路徑唯一會算錯的地方，也是 node 裡唯一測得到的部分。
// preRoll 與 Mac 端 AudioRingBuffer 的蓄水門檻同為 100 ms，理由也相同：生產與消費
// 速率相等時，不先積一點水就會每次都補靜音。
const AUDIO_PRE_ROLL_SECONDS = 0.1, AUDIO_MAX_LEAD_SECONDS = 0.5;
function audioScheduleDecision(now, scheduled, preRoll = AUDIO_PRE_ROLL_SECONDS, maxLead = AUDIO_MAX_LEAD_SECONDS) {
  // 還沒開始、或已經落後到排程時間在現在之前：重新蓄水，不要把一批排在過去
  //（排在過去的 AudioBufferSourceNode 會立刻播完，聽起來是破音而不是延遲）。
  if (scheduled === null || scheduled < now) return {startAt:now + preRoll, reset:true, drop:false};
  // 領先太多表示手機吃不下，丟這一批而不是讓延遲一路長上去。
  if (scheduled - now > maxLead) return {startAt:scheduled, reset:false, drop:true};
  return {startAt:scheduled, reset:false, drop:false};
}
function createAudioPlayback() {
  // 不用 AudioWorklet：它只在安全脈絡下存在，而手機是走 http 的區域網路位址連進來的，
  // 那裡 AudioContext.audioWorklet 是 undefined。改成把每一批排進時間軸，
  // 兩種脈絡下走同一條路徑，不用判斷 isSecureContext。
  let context = null, format = null, enabled = false, scheduled = null;
  let dropped = 0, underruns = 0, failure = null;
  function retire() {
    if (context) { context.close().catch(() => {}); }
    context = null; scheduled = null;
  }
  function build() {
    retire();
    failure = null;
    context = new AudioContext({sampleRate:format.rate, latencyHint:'interactive'});
    return context.resume();
  }
  function play(item) {
    const frames = item.samples.length / item.channels;
    const buffer = context.createBuffer(item.channels, frames, item.rate);
    for (let ch = 0; ch < item.channels; ch++) {
      const channel = buffer.getChannelData(ch);
      for (let frame = 0; frame < frames; frame++) channel[frame] = item.samples[frame * item.channels + ch] / 32768;
    }
    const decision = audioScheduleDecision(context.currentTime, scheduled);
    if (decision.reset && scheduled !== null) underruns++;
    if (decision.drop) { dropped++; return; }
    const source = context.createBufferSource();
    source.buffer = buffer;
    source.connect(context.destination);
    source.start(decision.startAt);
    scheduled = decision.startAt + frames / item.rate;
  }
  return {
    resume() {
      enabled = true;
      // 手勢發生時可能還沒收到格式，先用預設格式解鎖；收到不同格式再重建。
      if (!format) format = {rate:48000, channels:2};
      try { return context ? context.resume() : build(); }
      catch (error) { retire(); return Promise.reject(error); }
    },
    push(arrayBuffer) {
      const item = arrayBuffer instanceof ArrayBuffer ? decodeAudioMessage(arrayBuffer) : arrayBuffer;
      const changed = !format || format.rate !== item.rate || format.channels !== item.channels;
      format = {rate:item.rate, channels:item.channels};
      if (!enabled) return;
      if (failure) throw failure;
      if (changed || !context) {
        const resumed = build();
        resumed.catch(error => { failure = error; });
      }
      if (context.state === 'running') play(item);
    },
    stop() { enabled = false; failure = null; retire(); },
    stats() {
      const lead = context && scheduled !== null ? Math.max(0, scheduled - context.currentTime) : 0;
      return {bufferMs:lead * 1000, dropped, underruns};
    },
  };
}
