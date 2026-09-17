// Cliente del puente RPC. JS -> PS por postMessage; PS -> JS por __axeReply / eventos.
(function () {
  const pending = new Map();
  let seq = 1;
  const listeners = new Map(); // evt -> Set<fn>

  // El backend tiene operaciones de duracion muy distinta. Mantener un timeout unico de 15s
  // hacia que fps/benchmark fallasen en la UI aunque el motor siguiera trabajando correctamente.
  // Los limites solo controlan cuanto espera el cliente; no cambian la semantica del motor.
  const RPC_TIMEOUT_MS = Object.freeze({
    'fps.capture': 150000,
    'bench.baseline': 120000,
    'bench.after': 120000,
    'measure.score': 30000,
    'measure.timerSweep': 30000,
    'net.probe': 90000,
    'netload.probe': 90000,
    'diag.get': 30000,
    'prueba.baseline': 30000,
    'prueba.report': 30000,
    'session.start': 30000,
    'session.status': 10000,
    'session.stop': 30000,
    'tweaks.list': 45000,
    'tweaks.apply': 30000,
    'tweaks.revert': 30000,
    'tweaks.masterRevert': 120000
  });
  const DEFAULT_TIMEOUT_MS = 15000;

  window.__axeReply = function (id, json) {
    const p = pending.get(id);
    if (!p) return;
    pending.delete(id);
    let res;
    try { res = JSON.parse(json); } catch (e) { p.reject(new Error('respuesta ilegible')); return; }
    if (res.ok) p.resolve(res.data); else p.reject(new Error(res.err || 'error'));
  };

  function call(cmd, args) {
    return new Promise((resolve, reject) => {
      const id = seq++;
      pending.set(id, { resolve, reject });
      const bridge = window.chrome && window.chrome.webview;
      if (!bridge) { pending.delete(id); reject(new Error('puente no disponible (¿fuera de WebView2?)')); return; }
      // Postar el OBJETO (no un string): WebView2 lo serializa y WebMessageAsJson lo entrega como
      // objeto JSON que ConvertFrom-Json (PS) parsea a {id,cmd,args}. Un JSON.stringify aqui haria
      // que el lado PS reciba un string doble-codificado (id=0, cmd vacio).
      bridge.postMessage({ id, cmd, args: args || {} });
      const timeout = RPC_TIMEOUT_MS[cmd] || DEFAULT_TIMEOUT_MS;
      setTimeout(() => {
        if (pending.has(id)) {
          pending.delete(id);
          reject(new Error('timeout: ' + cmd));
        }
      }, timeout);
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
