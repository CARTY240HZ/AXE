// AXE Panel (Fase 4). Cablea datos REALES del motor por el puente RPC.
// Regla de honestidad: nada de datos inventados. Lo que aun no se mide (CPU/RAM en vivo -> Fase 5,
// activos por tier -> Fase 6) se pinta en estado de reposo, nunca con ruido aleatorio de relleno.
(function () {
  'use strict';
  const $ = (id) => document.getElementById(id);
  const reduce = matchMedia('(prefers-reduced-motion:reduce)').matches;
  const dpr = Math.min(devicePixelRatio || 1, 2);
  const ease = (t) => 1 - Math.pow(1 - t, 3);
  const AXE = window.AXE;

  // ---------- reloj local (hora, no una medicion) ----------
  const clk = $('clock');
  const tick = () => { clk.textContent = new Date().toLocaleTimeString('es-ES', { hour12: false }); };
  tick(); setInterval(tick, 1000);

  // ---------- version + catalogo ----------
  AXE.call('app.info', {}).then((info) => {
    if (info && info.version) $('ver').textContent = info.version;
  }).catch(() => { $('ver').textContent = '?'; });

  // ---------- chips de hardware (hw.get) ----------
  function chip(label, value, cls) {
    const d = document.createElement('div');
    d.className = 'chip' + (cls ? ' ' + cls : '');
    // textContent para el valor (viene de CIM local, aun asi evitamos innerHTML): sin riesgo XSS.
    if (label) d.appendChild(document.createTextNode(label + ' '));
    const b = document.createElement('b'); b.textContent = value; d.appendChild(b);
    return d;
  }
  function shortCpu(name) {
    if (!name) return '—';
    return String(name).replace(/\(R\)|\(TM\)|CPU|Processor|@.*$/g, '').replace(/\s+/g, ' ').trim();
  }
  AXE.call('hw.get', {}).then((hw) => {
    const eco = $('eco'); eco.innerHTML = '';
    eco.appendChild(chip('CPU', shortCpu(hw.CpuName)));
    if (hw.Cores) eco.appendChild(chip('', hw.Cores + 'C · ' + hw.Threads + 'T'));
    eco.appendChild(chip('', (hw.RamGB != null ? hw.RamGB : '—') + ' GB'));
    if (hw.HasNvidia) eco.appendChild(chip('GPU', 'NVIDIA'));
    eco.appendChild(chip('', hw.IsSSD ? 'SSD/NVMe' : 'HDD'));
    eco.appendChild(chip('', 'Win ' + (hw.IsWin11 ? '11' : '10') + (hw.IsHome ? ' · Home' : '')));
    eco.appendChild(chip('', hw.IsWifi ? 'Wi-Fi' : 'Ethernet'));
    if (hw.HasDefender) {
      const tamper = hw.IsTamperProtected;
      eco.appendChild(chip('Defender', tamper ? 'Tamper ON' : 'Tamper OFF', tamper ? 'on' : 'off'));
    }
  }).catch((e) => {
    $('eco').innerHTML = '';
    $('eco').appendChild(chip('', 'hardware no disponible: ' + e.message));
  });

  // ---------- catalogo por tier (catalog.tiers) ----------
  AXE.call('catalog.tiers', {}).then((tiers) => {
    const arr = Array.isArray(tiers) ? tiers : (tiers ? [tiers] : []);
    const by = {}; arr.forEach((t) => { by[t.tier] = t.total; });
    if (by[0] != null) $('t0').textContent = by[0];
    if (by[1] != null) $('t1').textContent = by[1];
    if (by[2] != null) $('t2').textContent = by[2];
  }).catch(() => {});

  // ---------- score arc (canvas) ----------
  const arc = $('arc');
  const actx = arc.getContext('2d');
  const A0 = Math.PI * 0.75, A1 = Math.PI * 2.25;
  function drawArc(v) {
    const w = arc.width, h = arc.height, cx = w / 2, cy = h / 2, R = w / 2 - 28;
    actx.clearRect(0, 0, w, h);
    actx.lineCap = 'round'; actx.lineWidth = 28;
    actx.strokeStyle = '#232a33';
    actx.beginPath(); actx.arc(cx, cy, R, A0, A1); actx.stroke();
    if (v > 0) {
      const a = A0 + (A1 - A0) * (v / 100);
      const g = actx.createLinearGradient(0, 0, w, h);
      g.addColorStop(0, '#c98f24'); g.addColorStop(1, '#E0A32E');
      actx.strokeStyle = g; actx.shadowColor = 'rgba(224,163,46,.5)'; actx.shadowBlur = 28;
      actx.beginPath(); actx.arc(cx, cy, R, A0, a); actx.stroke(); actx.shadowBlur = 0;
    }
    for (let i = 0; i <= 10; i++) {
      const ta = A0 + (A1 - A0) * (i / 10), r1 = R - 48, r2 = R - 60;
      actx.strokeStyle = i <= v / 10 ? 'rgba(224,163,46,.5)' : '#2a313b'; actx.lineWidth = 4;
      actx.beginPath();
      actx.moveTo(cx + Math.cos(ta) * r1, cy + Math.sin(ta) * r1);
      actx.lineTo(cx + Math.cos(ta) * r2, cy + Math.sin(ta) * r2);
      actx.stroke();
    }
  }
  drawArc(0);
  function animateArc(target) {
    const sv = $('scoreVal');
    if (reduce) { drawArc(target); sv.textContent = target; return; }
    let t0 = null; const dur = 1100;
    (function run(ts) {
      if (!t0) t0 = ts; const p = Math.min((ts - t0) / dur, 1); const e = ease(p);
      drawArc(target * e); sv.textContent = Math.round(target * e);
      if (p < 1) requestAnimationFrame(run);
    })(performance.now());
  }

  // ---------- reposo honesto: sparkline plana (sin datos aun) ----------
  function fit(c) {
    const r = c.getBoundingClientRect();
    if (r.width) { c.width = r.width * dpr; c.height = r.height * dpr; }
    const x = c.getContext('2d'); x.setTransform(dpr, 0, 0, dpr, 0, 0);
    return [x, r.width || c.width, r.height || c.height];
  }
  function drawRestSpark(c) {
    const [x, w, h] = fit(c);
    x.clearRect(0, 0, w, h);
    x.strokeStyle = '#232a33'; x.lineWidth = 1.4; x.setLineDash([4, 5]);
    x.beginPath(); x.moveTo(0, h * 0.62); x.lineTo(w, h * 0.62); x.stroke();
    x.setLineDash([]);
  }
  document.querySelectorAll('.spark').forEach(drawRestSpark);

  // ---------- osciloscopio en reposo (rejilla + umbral, sin traza falsa) ----------
  function drawRestScope() {
    const c = $('scope'); const [x, w, h] = fit(c);
    x.clearRect(0, 0, w, h);
    const top = 520;
    x.strokeStyle = '#1b212a'; x.lineWidth = 1;
    for (let g = 0; g <= 5; g++) { const y = h - (g * 100 / top) * h; x.beginPath(); x.moveTo(0, y); x.lineTo(w, y); x.stroke(); }
    const ty = h - (250 / top) * h;
    x.strokeStyle = 'rgba(217,96,90,.45)'; x.setLineDash([6, 6]); x.lineWidth = 1.2;
    x.beginPath(); x.moveTo(0, ty); x.lineTo(w, ty); x.stroke(); x.setLineDash([]);
    x.fillStyle = '#565f6e'; x.font = '12px ui-monospace,monospace';
    x.fillText('esperando stream en vivo (Fase 5)', 14, h - 14);
  }
  drawRestScope();
  addEventListener('resize', () => { document.querySelectorAll('.spark').forEach(drawRestSpark); drawRestScope(); drawArc(lastScore || 0); });

  // ---------- verdict a partir del score real ----------
  function verdictFor(total) {
    if (total >= 85) return ['excelente', 'ok'];
    if (total >= 70) return ['latencia estable', 'ok'];
    if (total >= 50) return ['mejorable', 'na'];
    return ['conviene optimizar', 'na'];
  }
  function fmtMs(v) { return (v == null) ? 'n/a' : (Number(v).toFixed(v < 1 ? 3 : 2) + ' ms'); }
  function relTime(iso) {
    try {
      const d = new Date(iso.replace(' ', 'T') + (/[zZ]$/.test(iso) ? '' : 'Z'));
      const s = Math.max(0, (Date.now() - d.getTime()) / 1000);
      if (s < 60) return 'hace ' + Math.round(s) + ' s';
      return 'hace ' + Math.round(s / 60) + ' min';
    } catch (e) { return iso; }
  }

  // ---------- medicion real (measure.score) ----------
  let lastScore = 0;
  let prevJitter = null;
  const btn = $('btnMeasure');
  function setMeasuring(on) {
    const v = $('verdict');
    if (on) {
      v.className = 'verdict measuring'; v.textContent = '● midiendo…';
      $('scoreVal').textContent = '—';
      btn.classList.add('busy'); btn.disabled = true;
    } else {
      btn.classList.remove('busy'); btn.disabled = false;
    }
  }
  function runMeasure() {
    setMeasuring(true);
    AXE.call('measure.score', {}).then((s) => {
      lastScore = s.total;
      animateArc(s.total);
      const vd = verdictFor(s.total);
      const v = $('verdict'); v.className = 'verdict ' + (vd[1] === 'ok' ? '' : 'na'); v.textContent = '● ' + vd[0];

      // cobertura real (Tier 0·1 activos / aplicables)
      $('covVal').textContent = (s.on != null && s.app != null) ? (s.on + '/' + s.app) : 'n/a';

      // delta jitter vs. medicion previa de ESTA sesion (honesto: '—' en la primera)
      if (prevJitter != null && s.jitterP999 != null) {
        const d = s.jitterP999 - prevJitter;
        const pct = prevJitter > 0 ? Math.round((d / prevJitter) * 100) : 0;
        const el = $('deltaJit');
        el.textContent = (pct <= 0 ? '' : '+') + pct + '%';
        el.className = 'n' + (pct <= 0 ? ' up' : '');
      } else {
        $('deltaJit').textContent = '—';
        $('deltaJit').className = 'n';
      }
      prevJitter = s.jitterP999;

      $('lastMeas').textContent = s.ts ? relTime(s.ts) : 'ahora';

      // vitales reales medidos bajo demanda
      $('timerV').textContent = (s.timerMs != null) ? (s.timerMs + ' ms') : 'n/a';
      $('timerSub').textContent = (s.timer === 'n/a') ? 'no medible' : ('componente ' + s.timer + '/30');
      $('jitterV').textContent = fmtMs(s.jitterP999);
      $('jitterSub').textContent = (s.jitter === 'n/a') ? 'no medible · P99.9' : ('P99.9 · componente ' + s.jitter + '/35');

      // receta real
      $('receiptBody').textContent = s.breakdown || '(sin desglose)';
      $('receiptBtn').disabled = false;

      // pill: activas reales
      if (s.on != null) $('pillTxt').textContent = 'Reversible · ' + s.on + ' activas';

      setMeasuring(false);
    }).catch((e) => {
      const v = $('verdict'); v.className = 'verdict na'; v.textContent = '● error al medir';
      $('scoreVal').textContent = '—';
      $('receiptBody').textContent = 'Puente error: ' + e.message;
      setMeasuring(false);
    });
  }
  btn.addEventListener('click', runMeasure);
  runMeasure(); // medicion automatica al abrir

  // ---------- receta modal ----------
  const sheet = $('sheet');
  $('receiptBtn').addEventListener('click', () => { if (!$('receiptBtn').disabled) sheet.classList.add('open'); });
  $('sheetClose').addEventListener('click', () => sheet.classList.remove('open'));
  sheet.addEventListener('click', (e) => { if (e.target === sheet) sheet.classList.remove('open'); });
  addEventListener('keydown', (e) => { if (e.key === 'Escape') sheet.classList.remove('open'); });

  // ---------- telemetria PS->JS (Fase 3): prueba de liveness -> uptime honesto ----------
  AXE.on('telemetry', (d) => {
    if (d && d.uptimeS != null) {
      const s = d.uptimeS, h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60);
      $('uptime').textContent = 'encendido hace ' + (h > 0 ? h + ' h ' : '') + m + ' min';
    }
  });
})();
