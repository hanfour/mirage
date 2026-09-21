const audioDisabled = params.get('audio') === '0';
const audioPlayback = createAudioPlayback();
let audioSocket = null, audioState = audioDisabled ? 'disabled' : 'waiting';
let audioGestureReceived = false;
let audioEnabled = true, audioDecodeErrors = 0, audioLastDecodeLog = -Infinity;
try { audioEnabled = localStorage.getItem('mirage.audioEnabled') !== '0'; } catch {}
// 由 JS 建立浮層，讓單檔頁面沿用既有的安全區域與觸控處理。
const audioToggle = document.createElement('button'), audioNotice = document.createElement('div');
audioToggle.id = 'audio-toggle'; audioToggle.type = 'button';
audioToggle.style.cssText = 'position:absolute;top:env(safe-area-inset-top,0px);right:0;border:0;background:#000b;color:#fff;width:28px;height:28px;padding:0;touch-action:none;z-index:4';
audioNotice.style.cssText = 'position:absolute;top:calc(env(safe-area-inset-top,0px) + 30px);right:0;max-width:75vw;padding:8px;background:#7f1d1d;pointer-events:none;white-space:pre-wrap;z-index:3';
audioNotice.setAttribute('role', 'status'); audioNotice.hidden = true;
document.querySelector('#viewport').append(audioToggle, audioNotice);
// 填滿寬度：Safari 頁面比 Android 畫面矮，完整顯示會留左右黑邊；這個模式改成裁掉上下。
let fillWidth = false;
try { fillWidth = localStorage.getItem('mirage.fillWidth') === '1'; } catch {}
const fillToggle = document.createElement('button');
fillToggle.id = 'fill-toggle'; fillToggle.type = 'button';
fillToggle.style.cssText = 'position:absolute;top:env(safe-area-inset-top,0px);right:30px;border:0;background:#000b;color:#fff;width:28px;height:28px;padding:0;touch-action:none;z-index:4';
document.querySelector('#viewport').append(fillToggle);
function renderFillToggle() {
  fillToggle.textContent = fillWidth ? '⇕' : '⇔';
  fillToggle.setAttribute('aria-pressed', String(fillWidth));
  fillToggle.setAttribute('aria-label', fillWidth ? '完整顯示畫面' : '填滿寬度');
}
renderFillToggle();
fillToggle.addEventListener('pointerdown', e => e.preventDefault());
fillToggle.addEventListener('click', () => {
  fillWidth = !fillWidth;
  try { localStorage.setItem('mirage.fillWidth', fillWidth ? '1' : '0'); } catch {}
  renderFillToggle();
  resizeViewport();
});
function renderAudioToggle() {
  audioToggle.hidden = audioDisabled;
  audioToggle.textContent = audioEnabled ? '🔊' : '🔇';
  audioToggle.setAttribute('aria-pressed', String(audioEnabled));
  audioToggle.setAttribute('aria-label', audioEnabled ? '靜音' : '開啟音訊');
}
function audioError(message) {
  audioNotice.textContent = message; audioNotice.hidden = false;
}
function resumeAudio() {
  if (audioDisabled || !audioEnabled) return;
  audioPlayback.resume().then(() => {
    if (audioState === 'connected') audioNotice.hidden = true;
    // 解鎖成功就不用再聽手勢了。留著的話遊戲中每次放開手指都會多跑一次 resume。
    removeAudioGestureListeners();
  }).catch(error => { audioError('音訊無法播放：' + error.message); });
}
audioToggle.addEventListener('click', () => {
  audioGestureReceived = true;
  audioEnabled = !audioEnabled;
  try { localStorage.setItem('mirage.audioEnabled', audioEnabled ? '1' : '0'); } catch {}
  renderAudioToggle();
  if (audioEnabled) resumeAudio(); else audioPlayback.stop();
});
// capture 可涵蓋會停止冒泡的導覽按鈕，且仍在使用者手勢內解鎖音訊。
function audioGesture() { audioGestureReceived = true; resumeAudio(); }
function removeAudioGestureListeners() {
  document.removeEventListener('pointerup', audioGesture, {capture:true});
  document.removeEventListener('keydown', audioGesture, {capture:true});
}
document.addEventListener('pointerup', audioGesture, {capture:true});
document.addEventListener('keydown', audioGesture, {capture:true});
renderAudioToggle();
function closeAudio() {
  if (audioSocket) {
    audioSocket.onopen = audioSocket.onclose = audioSocket.onerror = audioSocket.onmessage = null;
    audioSocket.close(); audioSocket = null;
  }
  audioPlayback.stop();
  audioState = audioDisabled ? 'disabled' : 'waiting';
}
function connectAudio() {
  if (audioDisabled) return;
  const current = generation;
  try {
    const socket = new WebSocket(base + '/ws/audio' + query);
    audioSocket = socket; socket.binaryType = 'arraybuffer';
    const valid = () => current === generation && audioSocket === socket;
    const disconnected = () => {
      if (!valid()) return;
      audioState = 'disconnected'; audioPlayback.stop();
      audioError('音訊已斷線，畫面與觸控仍可使用');
    };
    socket.onopen = () => {
      if (!valid()) return;
      audioState = 'connected'; audioNotice.hidden = true; note('audio connected');
      if (audioGestureReceived) resumeAudio();
    };
    socket.onclose = disconnected;
    socket.onerror = disconnected;
    socket.onmessage = event => {
      if (!valid() || audioState === 'disconnected') return;
      let item;
      try { item = decodeAudioMessage(event.data); }
      catch (error) {
        audioDecodeErrors++;
        const now = performance.now();
        if (now - audioLastDecodeLog >= 1000) {
          audioLastDecodeLog = now;
          note('audio decode errors=' + audioDecodeErrors + ': ' + error.message);
        }
        return;
      }
      try { audioPlayback.push(item); }
      catch (error) { audioPlayback.stop(); audioError('音訊無法播放：' + error.message); }
    };
  } catch (error) {
    audioState = 'disconnected'; audioError('音訊無法連線：' + error.message);
  }
}
// 語音辨識字幕，走 video channel 的文字訊息（與 stats 同一條）。
// 由 JS 建立浮層，理由與音訊切換鈕相同：單檔頁面沿用既有的安全區域處理。
const speechPanel = document.createElement('div');
speechPanel.style.cssText = 'position:absolute;left:50%;transform:translateX(-50%);'
  + 'bottom:calc(env(safe-area-inset-bottom,0px) + 72px);max-width:86vw;padding:10px 14px;'
  + 'background:#000b;color:#fff;font-size:17px;line-height:1.4;border-radius:10px;'
  + 'white-space:pre-wrap;pointer-events:none;z-index:3';
speechPanel.hidden = true;
document.querySelector('#viewport').append(speechPanel);
const SPEECH_VISIBLE_CHARACTERS = 80;
let speechClearTimer = null;
function renderSpeech(message) {
  // text 由 Mac 端產生，仍然驗一次型別：解析失敗的訊息不該讓浮層顯示 undefined。
  if (typeof message.text !== 'string') return;
  // 只顯示尾端：一段語音的辨識結果是累加的，長訊息會把畫面塞滿。
  speechPanel.textContent = message.text.slice(-SPEECH_VISIBLE_CHARACTERS);
  speechPanel.hidden = message.text === '';
  // 最後一則保留一段時間再消失，不要播完就立刻不見。
  clearForegroundTimeout(speechClearTimer);
  speechClearTimer = message.final
    ? setForegroundTimeout(() => { speechPanel.hidden = true; }, 8000)
    : null;
}
function audioStatsText() {
  const stats = audioPlayback.stats();
  return `audio ${audioState}: buffer=${stats.bufferMs.toFixed(1)} ms dropped=${stats.dropped} invalid=${audioDecodeErrors}`;
}
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
  // 鍵盤開著或填滿寬度時，畫面依寬度縮放：鍵盤時靠下（露出下半部），填滿寬度時置中。
  const widthHeight = width * canvas.height / canvas.width;
  const canvasHeight = keyboardOpen || fillWidth ? widthHeight : height;
  const offset = keyboardOpen ? height - canvasHeight : fillWidth ? (height - canvasHeight) / 2 : 0;
  canvas.style.setProperty('width', width + 'px');
  canvas.style.setProperty('height', canvasHeight + 'px');
  canvas.style.setProperty('transform', `translateY(${offset}px)`);
  // 回報畫面實際需要的區域。鍵盤開著時高度被擠掉，用鍵盤出現前的高度，否則每開一次鍵盤串流就重新要求一次。
  reportViewport(width, fillWidth ? widthHeight : keyboardOpen ? viewportBaseline : height);
}
// Mac 端依此決定串流解析度。只送變化；input 還沒開就先不送（onopen 會補送），
// 也不走 send()：沒連上不是丟掉使用者的輸入，不該算進 inputDrops。
let reportedViewport = '';
function reportViewport(width, height) {
  const scale = devicePixelRatio || 1;
  const key = `${Math.round(width)}x${Math.round(height)}@${scale}`;
  if (key === reportedViewport || !(width > 0 && height > 0)) return;
  if (!inputReady || input?.readyState !== WebSocket.OPEN) return;
  input.send(JSON.stringify({type:'viewport', width:Math.round(width), height:Math.round(height), scale}));
  reportedViewport = key;
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
  input.onopen = () => { if (current !== generation) return; inputReady = true; connectionHealthy(); note('input connected'); reportedViewport = ''; resizeViewport(); };
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
      connectAudio();
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
          if (message?.type === 'stats') { macStats = message; renderFrameWarning(message); renderTextWarning(message); }
          else if (message?.type === 'speech') renderSpeech(message);
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
  frameWarning.textContent = event === 'disconnected'
    ? `模擬器未連線，畫面已停止 ${Math.floor(seconds)} 秒`
    : `畫面已停止 ${Math.floor(seconds)} 秒（模擬器仍連線）`;
  frameWarning.hidden = !event || dismissedFrameEvent === event;
}
frameWarning.addEventListener('click', () => {
  dismissedFrameEvent = frameWarningEvent;
  frameWarning.hidden = true;
});
// 文字提交暫停：`onText` 是單向的，送出去沒有回程，所以手機端只能從每秒的 stats 知道
// 自己被拒絕。恢復等同承認「欄位我核對過了」，Mac 端永不重播舊稿。
const textWarning = document.querySelector('#text-warning');
const pauseReasons = {
  clipboardConflict: '剪貼簿被其他程式改動',
  staleSession: '工作階段已更換',
  readbackTimeout: '剪貼簿回讀逾時',
  paused: '已手動暫停',
  cancelled: '已取消',
  queueLimit: '待送佇列已滿',
  queueExpired: '等待過久',
};
function pauseText(reason) {
  if (typeof reason !== 'string' || !reason) return '';
  if (pauseReasons[reason]) return pauseReasons[reason];
  return reason.startsWith('transport') ? '與模擬器的連線出問題' : reason;
}
function renderTextWarning(stats) {
  const reason = pauseText(stats.textPaused);
  textWarning.textContent = reason ? `文字輸入已暫停：${reason}。點這裡核對後恢復` : '';
  textWarning.hidden = !reason;
}
textWarning.addEventListener('click', () => {
  if (send({type:'textResume'})) { textWarning.hidden = true; }
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
  const text = `${status}\n${codec}; hw=${hw}; secure=${isSecureContext}\ndecode fps=${fps.toFixed(1)} queue=${decoder?.decodeQueueSize ?? '—'} pending=${pending.size}\narrival→output p50/p95=${percentile(a,.5)}/${percentile(a,.95)} ms (n=${a.length})\n${macStatsText()}\n${audioStatsText()}\nWS RTT=${Number.isFinite(rtt)?rtt.toFixed(1):'—'} ms\ndropped: seq=${gaps} local=${localDrops}; recv=${received}\nlocal reasons=${JSON.stringify(dropReasons)}\ninput unsent=${inputDrops}\n${lastTouch}`;
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
