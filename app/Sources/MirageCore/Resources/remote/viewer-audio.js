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
const AUDIO_WORKLET_SOURCE = `
class MirageAudioProcessor extends AudioWorkletProcessor {
  constructor(options) {
    super();
    this.channels = options.processorOptions.channels;
    this.capacity = Math.ceil(sampleRate * 0.5);
    this.threshold = Math.ceil(sampleRate * 0.1);
    this.ring = new Float32Array(this.capacity * this.channels);
    this.read = 0; this.depth = 0; this.playing = false;
    this.dropped = 0; this.underruns = 0; this.ticks = 0;
    this.port.onmessage = ({data}) => {
      const frames = data.length / this.channels;
      if (this.depth + frames > this.capacity) this.dropped++;
      for (let frame = 0; frame < frames; frame++) {
        if (this.depth === this.capacity) {
          this.read = (this.read + 1) % this.capacity;
          this.depth--;
        }
        const write = (this.read + this.depth) % this.capacity;
        for (let ch = 0; ch < this.channels; ch++) this.ring[write * this.channels + ch] = data[frame * this.channels + ch];
        this.depth++;
      }
      this.port.postMessage({ack:true});
    };
  }
  process(inputs, outputs) {
    const output = outputs[0];
    for (const channel of output) channel.fill(0);
    // 生產與消費同速時，零深度會讓每次 render 都補靜音，因此先蓄水 100 ms。
    if (!this.playing && this.depth >= this.threshold) this.playing = true;
    if (this.playing) {
      const count = Math.min(output[0].length, this.depth);
      for (let frame = 0; frame < count; frame++) {
        for (let ch = 0; ch < this.channels; ch++) output[ch][frame] = this.ring[this.read * this.channels + ch];
        this.read = (this.read + 1) % this.capacity;
      }
      this.depth -= count;
      if (!this.depth) { this.playing = false; this.underruns++; }
    }
    this.ticks += output[0].length;
    if (this.ticks >= sampleRate / 20) {
      this.ticks = 0;
      this.port.postMessage({bufferMs:this.depth * 1000 / sampleRate, dropped:this.dropped, underruns:this.underruns});
    }
    return true;
  }
}
registerProcessor('mirage-audio', MirageAudioProcessor);
`;
function createAudioPlayback() {
  let context = null, node = null, format = null, enabled = false, revision = 0;
  let queue = new AudioJitterQueue(), inFlight = false, failure = null;
  let totals = {dropped:0, underruns:0}, current = {bufferMs:0, dropped:0, underruns:0};
  function retire() {
    revision++;
    totals = {dropped:totals.dropped + queue.dropped + current.dropped,
      underruns:totals.underruns + current.underruns};
    queue = new AudioJitterQueue();
    current = {bufferMs:0, dropped:0, underruns:0};
    if (node) { node.port.onmessage = null; node.disconnect(); }
    if (context) { context.onstatechange = null; context.close().catch(() => {}); }
    context = node = null; inFlight = false;
  }
  function drain() {
    // 一次只交付一批，避免主執行緒把延遲藏進無上限的 MessagePort 佇列。
    if (!node || inFlight || context.state !== 'running' || !queue.size) return;
    const samples = queue.shift();
    inFlight = true;
    node.port.postMessage(samples, [samples.buffer]);
  }
  function build() {
    retire();
    failure = null;
    const target = new AudioContext({sampleRate:format.rate, latencyHint:'interactive'});
    context = target;
    const version = revision, channels = format.channels;
    target.onstatechange = drain;
    // 頁面以單一檔案內嵌送出，沒有第二個可抓取的 worklet 路徑。
    const url = URL.createObjectURL(new Blob([AUDIO_WORKLET_SOURCE], {type:'application/javascript'}));
    target.audioWorklet.addModule(url).then(() => {
      if (version !== revision) return;
      node = new AudioWorkletNode(target, 'mirage-audio', {
        numberOfInputs:0, numberOfOutputs:1, outputChannelCount:[channels], processorOptions:{channels},
      });
      node.port.onmessage = ({data}) => {
        if (version !== revision) return;
        if (data.ack) { inFlight = false; drain(); }
        else current = {...data};
      };
      node.connect(target.destination);
      drain();
    }).catch(error => {
      if (version !== revision) return;
      retire(); failure = error;
    }).finally(() => URL.revokeObjectURL(url));
    return target.resume();
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
        const resumed = build(), version = revision;
        resumed.catch(error => { if (version === revision) failure = error; });
      }
      queue.push(Float32Array.from(item.samples, sample => sample / 32768));
      drain();
    },
    stop() { enabled = false; failure = null; retire(); },
    stats() { return {bufferMs:current.bufferMs, dropped:totals.dropped + queue.dropped + current.dropped,
      underruns:totals.underruns + current.underruns}; },
  };
}
