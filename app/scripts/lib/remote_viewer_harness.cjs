// 真正執行 viewer.html，以假 WebCodecs 與時鐘驗證靜止／恢復；不開 App 或連網。
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const html = fs.readFileSync(path.join(__dirname, '../../Sources/MirageCore/Resources/remote/viewer.html'), 'utf8').replace('/* MIRAGE_VIEWER_INPUT */',
  () => fs.readFileSync(path.join(__dirname, '../../Sources/MirageCore/Resources/remote/viewer-input.js'), 'utf8'));
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];

function harness({immediateOutput = false, search = '?t=abc', storage = new Map(), storageFails = false, viewport = null} = {}) {
  const timers = new Map(), decoders = [], sockets = [];
  let timerID = 0, now = 0, draws = 0;
  function element() {
    const classes = new Set(), listeners = {};
    return {listeners, hidden: false, value: '', attributes: {}, properties: {},
      setAttribute(name, value) { this.attributes[name] = value; },
      style: {setProperty(name, value) { this[name] = value; }},
      focus() { document.activeElement = this; this.listeners.focus?.(); },
      blur() { if (document.activeElement === this) { document.activeElement = null; this.listeners.blur?.(); } },
      setPointerCapture() {},
      getBoundingClientRect: () => ({left:0, top:0, width:8, height:1}),
      getContext: () => ({drawImage() { draws++; }}),
      addEventListener(type, listener) { listeners[type] = listener; },
      classList: {
        add: value => classes.add(value), remove: value => classes.delete(value),
        contains: value => classes.has(value),
        toggle(value, enabled) { if (enabled) classes.add(value); else classes.delete(value); },
      },
    };
  }
  const elements = Object.fromEntries(['#canvas', '#panel', '#log', '#nav', 'details', '#stats-toggle', '#error', '#text-input', '#keyboard', '#viewport', '#nav-handle', '#manifest'].map(id => [id, element()]));
  const buttons = [...html.matchAll(/<button[^>]+data-key="([^"]+)"/g)].map(match =>
    Object.assign(element(), {dataset: {key: match[1]}}));
  elements['#nav'].querySelectorAll = () => buttons;
  elements['#canvas'].width = 1080; elements['#canvas'].height = 2400;
  elements['#error'].hidden = true;
  elements['#nav-handle'].hidden = true;
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
    static CONNECTING = 0;
    constructor(url) { this.url = url; this.readyState = 1; this.bufferedAmount = 0; this.sent = []; sockets.push(this); }
    send(text) { this.sent.push(text); }
    close() { this.readyState = 3; this.onclose?.(); }
  }
  const windowListeners = {}, documentListeners = {};
  const window = {addEventListener(type, listener) { windowListeners[type] = listener; }};
  const document = {querySelector: selector => elements[selector], documentElement: root,
    addEventListener(type, listener) { documentListeners[type] = listener; }, visibilityState: 'visible', activeElement: null};
  const context = vm.createContext({
    document, window, visualViewport: viewport,
    location: {search, protocol: 'http:', host: '127.0.0.1'},
    navigator: {userAgent: 'test'}, screen: {width: 8, height: 1},
    innerWidth: 8, innerHeight: 1, devicePixelRatio: 1, isSecureContext: true,
    localStorage: {
      getItem(key) { if (storageFails) throw Error('denied'); return storage.get(key); },
      setItem(key, value) { if (storageFails) throw Error('denied'); storage.set(key, value); },
    },
    URLSearchParams, WebSocket: Socket, VideoDecoder: Decoder,
    EncodedVideoChunk: class {constructor(options) { Object.assign(this, options); }},
    performance: {now: () => now},
    setTimeout(fn, delay) { timers.set(++timerID, {fn, at: now + delay}); return timerID; },
    requestAnimationFrame(fn) { timers.set(++timerID, {fn, at:now + 16, frame:true}); return timerID; },
    cancelAnimationFrame(id) { timers.delete(id); },
    clearTimeout(id) { timers.delete(id); },
    setInterval(fn, delay) { timers.set(++timerID, {fn, at:now + delay, interval:delay}); return timerID; },
    clearInterval(id) { timers.delete(id); },
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
      if (timer.at <= now && (!timer.frame || document.visibilityState === 'visible')) { if (timer.interval) timer.at = now + timer.interval;
        else timers.delete(id);
        const result = timer.fn();
        if (result?.then) await result; }
    }
  }
  return {receive, advance, decoders, sockets, timers, elements, buttons, root, document,
    documentListeners, windowListeners,
    run: expression => vm.runInContext(expression, context), draws: () => draws};
}

module.exports = {harness, html};
