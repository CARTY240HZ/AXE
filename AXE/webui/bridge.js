// Cliente del puente RPC. JS -> PS por postMessage; PS -> JS por __axeReply / eventos.
(function () {
  const pending = new Map();
  let seq = 1;
  const listeners = new Map(); // evt -> Set<fn>

  window.__axeReply = function (id, json) {
    const p = pending.get(id);
    if (!p) return;
    pending.delete(id);
    let res;
    try { res = JSON.parse(json); } catch (e) { p.reject(new Error('respuesta ilegible')); return; }
    if (res.ok) p.resolve(res.data); else p.reject(new Error(res.err || 'error'));
  };

  function call(cmd, args, timeoutMs) {
    return new Promise((resolve, reject) => {
      const id = seq++;
      pending.set(id, { resolve, reject });
      const bridge = window.chrome && window.chrome.webview;
      if (!bridge) { reject(new Error('puente no disponible (¿fuera de WebView2?)')); return; }
      bridge.postMessage({ id, cmd, args: args || {} });
      const ms = timeoutMs || 15000;
      setTimeout(() => { if (pending.has(id)) { pending.delete(id); reject(new Error('timeout: ' + cmd)); } }, ms);
    });
  }

  function on(evt, fn) {
    if (!listeners.has(evt)) listeners.set(evt, new Set());
    listeners.get(evt).add(fn);
    return () => listeners.get(evt).delete(fn);
  }

  // PS -> JS telemetria: PostWebMessageAsJson llega por este evento (Fase 3).
  const bridge = window.chrome && window.chrome.webview;
  if (bridge) {
    bridge.addEventListener('message', (ev) => {
      const m = ev.data;
      if (m && m.evt && listeners.has(m.evt)) listeners.get(m.evt).forEach((fn) => fn(m.data));
    });
  }

  window.AXE = { call, on };
})();
