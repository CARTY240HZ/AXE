// Cliente del puente RPC. JS -> PS por postMessage; PS -> JS por __axeReply / eventos.
(function () {
  const pending = new Map();
  let seq = 1;
  const listeners = new Map();
  const ALLOWED = new Set([
    'hw.get', 'app.info', 'measure.score', 'catalog.tiers',
    'tweaks.list', 'tweaks.apply', 'tweaks.revert', 'tweaks.masterRevert',
    'measure.timerSweep', 'net.probe', 'fps.capture', 'diag.get',
    'prueba.baseline', 'prueba.report', 'bench.baseline', 'bench.after',
    'safety.restorePoint', 'session.preview', 'session.start', 'session.status',
    'session.stop', 'session.setLevel', 'advisor.get', 'session.detect'
  ]);

  window.__axeReply = function (id, json) {
    const p = pending.get(id);
    if (!p) return;
    pending.delete(id);
    let res;
    try { res = JSON.parse(json); } catch (e) { p.reject(new Error('respuesta ilegible')); return; }
    if (res.ok) p.resolve(res.data); else p.reject(new Error(res.err || 'error'));
  };

  function safeArgs(args) {
    if (args == null) return {};
    if (typeof args !== 'object' || Array.isArray(args)) throw new Error('args invalidos');
    const keys = Object.keys(args);
    if (keys.length > 32) throw new Error('demasiados parametros');
    return args;
  }

  function call(cmd, args) {
    return new Promise((resolve, reject) => {
      if (typeof cmd !== 'string' || cmd.length === 0 || cmd.length > 64 || !ALLOWED.has(cmd)) {
        reject(new Error('comando no permitido'));
        return;
      }
      let safe;
      try { safe = safeArgs(args); } catch (e) { reject(e); return; }

      const bridge = window.chrome && window.chrome.webview;
      if (!bridge) { reject(new Error('puente no disponible (¿fuera de WebView2?)')); return; }
      const id = seq++;
      pending.set(id, { resolve, reject });
      // Postar el OBJETO (no un string): WebView2 lo serializa y WebMessageAsJson lo entrega como
      // objeto JSON que ConvertFrom-Json (PS) parsea a {id,cmd,args}. Un JSON.stringify aqui haria
      // que el lado PS reciba un string doble-codificado (id=0, cmd vacio).
      bridge.postMessage({ id, cmd, args: safe });
      setTimeout(() => {
        if (pending.has(id)) {
          pending.delete(id);
          reject(new Error('timeout: ' + cmd));
        }
      }, 15000);
    });
  }

  function on(evt, fn) {
    if (typeof evt !== 'string' || evt.length === 0 || evt.length > 64 || typeof fn !== 'function') {
      throw new Error('listener invalido');
    }
    if (!listeners.has(evt)) listeners.set(evt, new Set());
    listeners.get(evt).add(fn);
    return () => listeners.get(evt)?.delete(fn);
  }

  const bridge = window.chrome && window.chrome.webview;
  if (bridge) {
    bridge.addEventListener('message', (ev) => {
      const m = ev.data;
      // Eventos solo deben entrar como objetos simples desde el canal WebView2; el CSP bloquea
      // red externa, pero no sustituye la validacion de datos que cruza el boundary nativo.
      if (!m || typeof m !== 'object' || Array.isArray(m) || typeof m.evt !== 'string' || m.evt.length > 64) return;
      if (listeners.has(m.evt)) listeners.get(m.evt).forEach((fn) => {
        try { fn(m.data); } catch (_) {}
      });
    });
  }

  window.AXE = Object.freeze({ call, on });
})();
