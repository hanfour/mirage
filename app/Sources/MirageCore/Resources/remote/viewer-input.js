function send(obj) {
  if (input?.readyState === WebSocket.OPEN && input.bufferedAmount < 65536) {
    input.send(JSON.stringify(obj)); return true;
  }
  inputDrops++; return false;
}
const textInput = document.querySelector('#text-input'), keyboard = document.querySelector('#keyboard');
const viewport = document.querySelector('#viewport');
let viewportBaseline = 0, baselineWidth = 0, keyboardOpen = false;
function resizeViewport() {
  const view = typeof visualViewport !== 'undefined' && visualViewport;
  const width = view ? view.width : innerWidth, height = view ? view.height : innerHeight;
  if (width !== baselineWidth) {
    baselineWidth = width;
    viewportBaseline = Math.max(height, innerHeight);
  }
  // 120px 門檻避免 Safari 工具列伸縮被當成鍵盤；保留收鍵盤動畫中的裁切。
  if (document.activeElement !== textInput && !keyboardOpen) viewportBaseline = Math.max(viewportBaseline, height);
  keyboardOpen = (document.activeElement === textInput || keyboardOpen) && viewportBaseline - height > 120;
  for (const [name, value] of Object.entries({
    height, width, top:view ? view.offsetTop : 0, left:view ? view.offsetLeft : 0,
  })) viewport.style.setProperty('--view-' + name, value + 'px');
  const canvasHeight = keyboardOpen ? width * canvas.height / canvas.width : height;
  canvas.style.setProperty('width', width + 'px');
  canvas.style.setProperty('height', canvasHeight + 'px');
  canvas.style.setProperty('transform', `translateY(${keyboardOpen ? height - canvasHeight : 0}px)`);
}
if (typeof visualViewport !== 'undefined' && visualViewport) {
  visualViewport.addEventListener('resize', resizeViewport);
  visualViewport.addEventListener('scroll', resizeViewport);
}
window.addEventListener('resize', resizeViewport);
resizeViewport();
keyboard.addEventListener('pointerdown', e => e.preventDefault());
keyboard.addEventListener('click', () => {
  if (document.activeElement === textInput) textInput.blur();
  else textInput.focus({preventScroll:true}); // 不 await：iOS 只允許使用者手勢內叫出鍵盤。
});
textInput.addEventListener('focus', () => { keyboard.setAttribute('aria-pressed', 'true'); resizeViewport(); });
textInput.addEventListener('blur', () => keyboard.setAttribute('aria-pressed', 'false'));
function submitText() {
  const text = textInput.value;
  if (!text) return;
  if (text.length > 4096) { reportError('文字太長，請分成 4096 字元以內送出'); return; }
  if (send({type:'text', text, t:performance.now()})) textInput.value = '';
  else reportError('文字尚未送出，請確認連線後再試');
}
textInput.addEventListener('keydown', e => {
  if (e.isComposing || e.keyCode === 229) return;
  if (e.key === 'Enter') { e.preventDefault(); submitText(); }
  else if (e.key === 'Backspace' && !textInput.value) {
    e.preventDefault(); send({type:'key', key:'Backspace', t:performance.now()});
  }
});
// 部分 iOS 軟鍵盤只提供 beforeinput；keydown preventDefault 會取消對應的 beforeinput。
textInput.addEventListener('beforeinput', e => {
  if (e.isComposing) return;
  if (e.inputType === 'deleteContentBackward' && !textInput.value) {
    e.preventDefault(); send({type:'key', key:'Backspace', t:performance.now()});
  }
});
// input 必須等 video 握手完成，才屬於目前的配對。
function connectInput() {
  input = new WebSocket(base + '/ws/input' + query);
  const current = generation;
  input.onopen = () => { if (current !== generation) return; inputReady = true; connectionHealthy(); note('input connected'); };
  input.onclose = () => { if (current === generation) reconnect('input disconnected'); };
  input.onerror = () => { if (current === generation) reconnect('input WebSocket error'); };
  input.onmessage = event => {
    if (current !== generation) return;
    try {
      const obj = JSON.parse(event.data);
      if(obj.type === 'ping') rtt = performance.now() - obj.t;
    } catch(e) { note('input echo error: ' + e.message); }
  };
}
async function start() {
  note(`VideoDecoder=${typeof VideoDecoder}; secure=${isSecureContext}; UA=${navigator.userAgent}`);
  note(`screen=${screen.width}x${screen.height}; viewport=${innerWidth}x${innerHeight}; DPR=${devicePixelRatio}; codec=${codec}; hw=${hw}`);
  if (typeof VideoDecoder === 'undefined') { status = '這個瀏覽器沒有 VideoDecoder';
    reportError(status);
    return;
  }
  try {
    const current = generation;
    connectionTimer = setForegroundTimeout(() => {
      if (current === generation) reconnect('connection timed out');
    }, 5000);
    if (codec && !configurationFailed) { decoder = makeDecoder(); if (!configureDecoder()) return; }
    // codec 必須等首個 keyframe 裡的 SPS，不能預先猜測。
    video = new WebSocket(base + '/ws/video' + query); video.binaryType = 'arraybuffer';
    video.onopen = () => {
      if (current !== generation) return;
      if (!reconnecting) status = 'waiting for IDR';
      connectInput();
      if (reconnecting) requestKeyframe();
      note(status);
    };
    video.onclose = () => { if (current === generation) reconnect('video disconnected'); };
    video.onerror = () => { if (current === generation) reconnect('video WebSocket error'); };
    video.onmessage = event => {
      if (current !== generation) return;
      if (typeof event.data === 'string') {
        try {
          const message = JSON.parse(event.data);
          if (message?.type === 'stats') { macStats = message; renderFrameWarning(message); }
        } catch(e) { note('stats JSON error: ' + e.message); }
        return;
      }
      cancelIdleFlush();
      if (configurationFailed) return;
      const arrival = performance.now();
      try {
        const data = event.data, header = new DataView(data);
        if(data.byteLength <= 13) throw Error('short video message');
        const sentNs = header.getBigUint64(0, false); // Different clock domain: never subtract from performance.now().
        const seq = header.getUint32(8, false), key = header.getUint8(12) === 1;
        if(header.getUint8(12) > 1 || sentNs === 0n) throw Error('bad header');
        received++;
        if(lastSeq !== null) {
          const missing = (seq - lastSeq - 1) >>> 0;
          if(missing) { gaps += missing; reset('sequence gap: ' + missing, 'gap'); }
        }
        lastSeq = seq;
        const bytes = new Uint8Array(data, 13);
        const found = key ? codecFromAccessUnit(bytes) : null;
        if (found && (found !== codec || !decoder || decoder.state === 'closed')) {
          if (decoder && decoder.state !== 'closed') decoder.close();
          localDrops += pending.size;
          pending.clear();
          waiting = true;
          codec = found;
          decoder = makeDecoder();
          if (!configureDecoder()) return;
        }
        if (!decoder || decoder.state !== 'configured') { localDrops++; return; }
        if(decoder.decodeQueueSize > 8 || pending.size > 120) reset(`browser backlog: queue=${decoder.decodeQueueSize} pending=${pending.size}; discard through next IDR`, 'backlog');
        if (configurationFailed) return;
        if(waiting && !key) { requestKeyframe(); dropReasons.waitIDR++; localDrops++; return; }
        waiting = false;
        keyframeRequested = false;
        // Unique local timestamp identifies output; no server/browser clock synchronization assumed.
        const timestamp = received * 16667;
        pending.set(timestamp, arrival);
        const target = decoder;
        try { target.decode(new EncodedVideoChunk({type:key ? 'key' : 'delta', timestamp, data:new Uint8Array(data, 13)})); }
        catch (e) { if (decoder === target) recoverDecoder(e); return; }
        if (decoder !== target) return;
        scheduleIdleFlush();
        if (!reconnecting) status = 'streaming';
      } catch(e) { status = 'video error: ' + e.message; reset(status); reportError(status); }
    };
  } catch(e) {
    reconnect(e.message);
  }
}
// 同一故障事件只收起一次；恢復或故障種類改變時重新通知。
const frameWarning = document.querySelector('#frame-warning');
let frameWarningEvent = '', dismissedFrameEvent = '';
function renderFrameWarning(stats) {
  const seconds = Number.isFinite(stats.secondsSinceNewFrame) ? Math.max(0, stats.secondsSinceNewFrame) : 0;
  const event = stats.emulatorConnected === false ? 'disconnected' : seconds > 5 ? 'stalled' : '';
  if (event !== frameWarningEvent) dismissedFrameEvent = '';
  frameWarningEvent = event;
  frameWarning.textContent = `模擬器未連線，畫面已停止 ${Math.floor(seconds)} 秒`;
  frameWarning.hidden = !event || dismissedFrameEvent === event;
}
frameWarning.addEventListener('click', () => {
  dismissedFrameEvent = frameWarningEvent;
  frameWarning.hidden = true;
});
let macStats = null;
function macStatsText() {
  const ms = value => Number.isFinite(value) ? value.toFixed(1) : '—';
  const pair = value => `${ms(value?.p50)}/${ms(value?.p95)}`;
  const count = macStats?.newFrames;
  const transit = !Number.isFinite(count) || count < 10
    ? `－（樣本 ${count ?? '－'}）` : `${ms(macStats?.transitMs)} ms`;
  return `Mac: age ${pair(macStats?.age)} · encode ${pair(macStats?.encode)} · send ${pair(macStats?.send)} · transit ${transit}\nframes/s new=${macStats?.newFrames ?? '—'} heartbeat=${macStats?.heartbeatFrames ?? '—'}\ninput RPC/s=${macStats?.inputRPCsPerSecond?.toFixed(1) ?? '—'} coalesced=${macStats?.inputCoalesced ?? '—'}`;
}
function percentile(a, p) { return a.length ? a[Math.min(a.length-1, Math.ceil(a.length*p)-1)].toFixed(1) : '—'; }
let statsTimer = null;
function startStatsTimer() {
  if (statsTimer !== null) return;
  tick = performance.now(); lastDecoded = decoded;
  statsTimer = setInterval(updateStats, 1000);
}
function stopStatsTimer() {
  clearInterval(statsTimer);
  statsTimer = null;
}
function updateStats() {
  const now = performance.now(), fps = now > tick ? (decoded-lastDecoded)*1000/(now-tick) : 0;
  lastDecoded = decoded; tick = now;
  const a = samples.sort((x,y)=>x-y); samples = [];
  const text = `${status}\n${codec}; hw=${hw}; secure=${isSecureContext}\ndecode fps=${fps.toFixed(1)} queue=${decoder?.decodeQueueSize ?? '—'} pending=${pending.size}\narrival→output p50/p95=${percentile(a,.5)}/${percentile(a,.95)} ms (n=${a.length})\n${macStatsText()}\nWS RTT=${Number.isFinite(rtt)?rtt.toFixed(1):'—'} ms\ndropped: seq=${gaps} local=${localDrops}; recv=${received}\nlocal reasons=${JSON.stringify(dropReasons)}\ninput unsent=${inputDrops}\n${lastTouch}`;
  if (showStats && !configurationFailed) { panel.textContent = text;
    note(text);
  }
  if (Number.isFinite(rtt)) send({type:'client-stats', rtt, dropped:gaps + localDrops, decodeFps:fps});
  send({type:'ping', t:performance.now()});
}
startStatsTimer();
// iOS Safari pointerId 可為負數；原樣送出，server 接受整個 signed Int32 範圍。
const active = new Map();
let touchFrame = null, touchTimer = null;
function scheduleTouches() {
  if (![...active.values()].some(state => state.queue.length)) return;
  if (document.visibilityState !== 'visible') {
    if (touchFrame !== null) cancelAnimationFrame(touchFrame);
    touchFrame = null;
    if (touchTimer === null) touchTimer = setTimeout(flushTouches, 16);
  } else {
    if (touchTimer !== null) clearTimeout(touchTimer);
    touchTimer = null;
    if (touchFrame === null) touchFrame = requestAnimationFrame(flushTouches);
  }
}
function flushTouches() {
  touchFrame = touchTimer = null;
  const points = [...active.values()].filter(state => state.queue.length).map(state => state.queue[0]);
  if (points.length && send({type:'touches', t:performance.now(), points})) {
    for (const point of points) {
      const state = active.get(point.id);
      state.queue.shift();
      if (!state.queue.length && (point.phase === 'up' || point.phase === 'cancel')) active.delete(point.id);
    }
  }
  scheduleTouches();
}
function position(e) {
  const r = canvas.getBoundingClientRect(), scale = Math.min(r.width/canvas.width, r.height/canvas.height);
  const w = canvas.width*scale, h = canvas.height*scale;
  return {x:(e.clientX-r.left-(r.width-w)/2)/w, y:(e.clientY-r.top-(r.height-h)/2)/h};
}
for(const type of ['pointerdown','pointermove','pointerup','pointercancel']) canvas.addEventListener(type, e => {
  e.preventDefault();
  const p = position(e); // 先讀位移後的矩形，再收鍵盤，避免焦點事件改動座標。
  if (type === 'pointerdown') textInput.blur();
  if(type === 'pointerdown') {
    if(p.x<0 || p.x>1 || p.y<0 || p.y>1) return;
    if (!active.has(e.pointerId)) active.set(e.pointerId, {queue:[], ended:false});
    canvas.setPointerCapture(e.pointerId);
    requestWake();
  }
  const state = active.get(e.pointerId);
  if (!state || (state.ended && type !== 'pointerdown')) return;
  if (type === 'pointerdown') state.ended = false;
  lastTouch = `${type.slice(7)} id=${e.pointerId} x=${p.x.toFixed(3)} y=${p.y.toFixed(3)}`;
  const point = {id:e.pointerId, phase:type.slice(7), x:Math.max(0,Math.min(1,p.x)), y:Math.max(0,Math.min(1,p.y))};
  const tail = state.queue[state.queue.length - 1];
  if (point.phase === 'move' && tail?.phase === 'move') state.queue[state.queue.length - 1] = point;
  else state.queue.push(point);
  if (point.phase === 'up' || point.phase === 'cancel') state.ended = true;
  scheduleTouches();
}, {passive:false});
for(const type of ['gesturestart','gesturechange']) document.addEventListener(type, e => e.preventDefault(), {passive:false});
// iOS 18.4 前，standalone 主畫面 Web App 的 Wake Lock 有已知問題。
// https://webkit.org/blog/16574/webkit-features-in-safari-18-4/
async function requestWake() {
  if(!navigator.wakeLock || wake || document.visibilityState !== 'visible') return;
  try { wake = await navigator.wakeLock.request('screen'); wake.addEventListener('release', () => { wake = null; }); }
  catch(e) { note('wakeLock: ' + e.message); }
}
let resumedGeneration = null;
function resumeForeground() {
  scheduleTouches();
  updateForegroundClock();
  if (document.visibilityState !== 'visible') { resumedGeneration = null; return; }
  requestWake();
  // visibilitychange and pageshow can both describe the same foreground transition.
  if (resumedGeneration === generation && reconnectAttempts < 3 && connectionTimer !== null &&
      (video?.readyState === WebSocket.CONNECTING || input?.readyState === WebSocket.CONNECTING)) return;
  if (video?.readyState !== WebSocket.OPEN || input?.readyState !== WebSocket.OPEN || reconnectAttempts >= 3) {
    clearForegroundTimeout(reconnectTimer);
    reconnectTimer = null;
    reconnectAttempts = 0;
    reconnect('returned to foreground', true);
    resumedGeneration = generation;
  }
}
document.addEventListener('visibilitychange', resumeForeground);
window.addEventListener('pageshow', resumeForeground);
start();
requestWake();
