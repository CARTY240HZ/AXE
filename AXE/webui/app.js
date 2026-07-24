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
    x.fillText('iniciando muestreo…', 14, h - 14);
  }
  drawRestScope();

  // ---------- feeds en vivo (Fase 5): buffers reales, sin ruido de relleno ----------
  const cpuBuf = [], ramBuf = [], scopeBuf = [];
  let scopeMax = 0, liveStarted = false, teleLoaded = false, lastMeanUs = null;
  const cpuCanvas = document.querySelector('.spark[data-c="cpu"]');
  const ramCanvas = document.querySelector('.spark[data-c="ram"]');
  const THR = 250; // umbral stutter (µs)
  function pushBuf(a, v, max) { a.push(v); while (a.length > max) a.shift(); }
  function drawSpark(c, buf) {
    const [x, w, h] = fit(c); x.clearRect(0, 0, w, h);
    if (!buf.length) return;
    const max = Math.max(12, Math.max.apply(null, buf)) * 1.15, n = buf.length;
    const X = (i) => i / Math.max(1, n - 1) * w, Y = (v) => h - (v / max) * h;
    x.beginPath(); x.moveTo(0, h); buf.forEach((v, i) => x.lineTo(X(i), Y(v))); x.lineTo(X(n - 1), h); x.closePath();
    const g = x.createLinearGradient(0, 0, 0, h); g.addColorStop(0, 'rgba(224,163,46,.16)'); g.addColorStop(1, 'rgba(224,163,46,0)');
    x.fillStyle = g; x.fill();
    x.beginPath(); buf.forEach((v, i) => i ? x.lineTo(X(i), Y(v)) : x.moveTo(X(i), Y(v))); x.strokeStyle = '#b98f34'; x.lineWidth = 1.6; x.stroke();
    x.fillStyle = '#E0A32E'; x.beginPath(); x.arc(X(n - 1), Y(buf[n - 1]), 2.6, 0, 7); x.fill();
  }
  function drawScope(c) {
    c = c || $('scope'); const [x, w, h] = fit(c); x.clearRect(0, 0, w, h);
    const top = Math.max(520, scopeMax * 1.2);
    x.strokeStyle = '#1b212a'; x.lineWidth = 1;
    for (let g = 0; g <= 5; g++) { const y = h - (g / 5) * h; x.beginPath(); x.moveTo(0, y); x.lineTo(w, y); x.stroke(); }
    const ty = h - (THR / top) * h;
    x.strokeStyle = 'rgba(217,96,90,.5)'; x.setLineDash([6, 6]); x.lineWidth = 1.2; x.beginPath(); x.moveTo(0, ty); x.lineTo(w, ty); x.stroke(); x.setLineDash([]);
    if (!scopeBuf.length) { x.fillStyle = '#565f6e'; x.font = '12px ui-monospace,monospace'; x.fillText('esperando primer muestreo…', 14, h - 14); return; }
    const n = scopeBuf.length, X = (i) => i / Math.max(1, n - 1) * w, Y = (v) => h - (Math.min(v, top) / top) * h;
    x.beginPath(); x.moveTo(0, h); scopeBuf.forEach((v, i) => x.lineTo(X(i), Y(v))); x.lineTo(X(n - 1), h); x.closePath();
    const g = x.createLinearGradient(0, 0, 0, h); g.addColorStop(0, 'rgba(224,163,46,.22)'); g.addColorStop(1, 'rgba(224,163,46,0)'); x.fillStyle = g; x.fill();
    x.beginPath(); scopeBuf.forEach((v, i) => i ? x.lineTo(X(i), Y(v)) : x.moveTo(X(i), Y(v))); x.strokeStyle = '#E0A32E'; x.lineWidth = 1.5; x.stroke();
    scopeBuf.forEach((v, i) => { if (v > THR) { x.fillStyle = 'rgba(217,96,90,.9)'; x.fillRect(X(i) - 1, Y(v), 2, h - Y(v)); } });
    const lv = scopeBuf[n - 1]; x.fillStyle = lv > THR ? '#D9605A' : '#E0A32E'; x.beginPath(); x.arc(X(n - 1), Y(lv), 3, 0, 7); x.fill();
  }
  function redrawLive() {
    if (liveStarted) { drawSpark(cpuCanvas, cpuBuf); drawSpark(ramCanvas, ramBuf); drawScope(); }
    else { document.querySelectorAll('.spark').forEach(drawRestSpark); drawRestScope(); }
  }
  addEventListener('resize', () => { redrawLive(); drawArc(lastScore || 0); if (teleLoaded) drawScope($('teleScope')); });

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

  // ---------- barras de componentes: composicion real del score ----------
  // maxes: Timer 30, Jitter 35, Cobertura 25, Idle 10 (los mismos pesos de Get-AXEScore).
  function setBar(k, val, max) {
    const row = document.querySelector('.sbar[data-k="' + k + '"]'); if (!row) return;
    const track = row.querySelector('.sbar-track'), bar = track.querySelector('i'), v = row.querySelector('.sbar-v');
    const na = (val === 'n/a' || val == null);
    track.classList.toggle('na', na); v.classList.toggle('na', na);
    if (na) { bar.style.width = '0%'; v.textContent = 'n/a'; return; }
    const n = Math.max(0, Math.min(max, Number(val)));
    bar.style.width = (n / max * 100) + '%';
    v.textContent = n + '/' + max;
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

      // barras de composicion del score (Timer 30 / Jitter 35 / Cobertura 25 / Idle 10)
      setBar('timer', s.timer, 30);
      setBar('jitter', s.jitter, 35);
      setBar('coverage', s.coverage, 25);
      setBar('idle', s.idle, 10);

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

  // ---------- router (Fase 6/7): Panel · Telemetría · Optimizar · Prueba · Seguridad · Ajustes ----------
  const viewEls = {};
  document.querySelectorAll('.view[data-view]').forEach((v) => { viewEls[v.dataset.view] = v; });
  const navItems = [...document.querySelectorAll('.nav-item[data-view]')];
  const loaded = {};
  // cada vista se inicializa una sola vez, la primera vez que se abre (init perezoso, sin pegar el arranque).
  const lazyInit = { optimizar: initOptimizar, telemetria: initTele, prueba: initPrueba, seguridad: initSeguridad, ajustes: initAjustes };
  function showView(name) {
    if (!viewEls[name]) return;
    Object.keys(viewEls).forEach((k) => { viewEls[k].hidden = (k !== name); });
    navItems.forEach((n) => n.classList.toggle('on', n.dataset.view === name));
    if (lazyInit[name] && !loaded[name]) { loaded[name] = true; lazyInit[name](); }
  }
  document.querySelectorAll('[data-view]').forEach((el) => {
    if (el.classList.contains('view')) return; // las secciones no navegan
    el.addEventListener('click', () => showView(el.dataset.view));
    el.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); showView(el.dataset.view); } });
  });

  // ---------- confirm modal (promesa) para acciones que MODIFICAN el sistema ----------
  const confirmSheet = $('confirmSheet');
  let confirmResolve = null;
  function sheetOpen() { return !!document.querySelector('.sheet.open'); }
  function confirmDialog(title, body, danger) {
    $('confirmTitle').textContent = title;
    $('confirmBody').textContent = body;
    $('confirmYes').classList.toggle('danger', !!danger);
    confirmSheet.classList.add('open'); $('confirmYes').focus();
    return new Promise((res) => { confirmResolve = res; });
  }
  function closeConfirm(v) { confirmSheet.classList.remove('open'); if (confirmResolve) { const r = confirmResolve; confirmResolve = null; r(v); } }
  $('confirmYes').addEventListener('click', () => closeConfirm(true));
  $('confirmNo').addEventListener('click', () => closeConfirm(false));
  confirmSheet.addEventListener('click', (e) => { if (e.target === confirmSheet) closeConfirm(false); });
  addEventListener('keydown', (e) => { if (e.key === 'Escape' && confirmSheet.classList.contains('open')) closeConfirm(false); });
  const keyMap = { '1': 'panel', '2': 'telemetria', '3': 'optimizar', '5': 'prueba', '6': 'seguridad', '7': 'ajustes' };
  addEventListener('keydown', (e) => {
    if (sheetOpen()) return;
    if (e.target && (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA')) return; // no robar teclas a los campos
    const v = keyMap[e.key]; if (v) showView(v);
  });

  // ---------- Optimizar: catalogo real (tweaks.list) + aplicar/revertir ----------
  const TIER_META = { 0: { label: 'Tier 0 · seguro', cls: 't0' }, 1: { label: 'Tier 1 · elite', cls: 't1' }, 2: { label: 'Tier 2 · extremo', cls: 't2' } };
  const optBar = $('optBar');
  function elt(tag, cls, text) { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }
  function setOptBar(msg, kind) { optBar.className = 'obar' + (kind ? ' ' + kind : ''); optBar.textContent = msg; }

  function initOptimizar() {
    setOptBar('cargando catálogo… (mide el estado real de cada tweak, puede tardar unos segundos)');
    AXE.call('tweaks.list', {}).then((list) => renderCatalog(Array.isArray(list) ? list : []))
      .catch((e) => setOptBar('No pude cargar el catálogo: ' + e.message, 'err'));
  }

  function renderCatalog(list) {
    const host = $('optList'); host.textContent = '';
    const appl = list.filter((t) => !t.blocked).length;
    const on = list.filter((t) => t.applied && !t.blocked).length;
    optBar.className = 'obar ok'; optBar.textContent = '';
    optBar.appendChild(document.createTextNode(list.length + ' tweaks · '));
    optBar.appendChild(elt('b', null, on + ' activos'));
    optBar.appendChild(document.createTextNode(' de ' + appl + ' aplicables en este equipo · reversibles 1-a-1'));
    [0, 1, 2].forEach((tier) => {
      const items = list.filter((t) => t.tier === tier);
      if (!items.length) return;
      const meta = TIER_META[tier] || { label: 'Tier ' + tier, cls: 't' + tier };
      const g = elt('div', 'tgroup');
      const h = elt('div', 'tgroup-h ' + meta.cls);
      h.appendChild(elt('span', 'dot'));
      h.appendChild(elt('h2', null, meta.label));
      const onN = items.filter((t) => t.applied && !t.blocked).length;
      h.appendChild(elt('span', 'count', onN + '/' + items.length + ' activos'));
      g.appendChild(h);
      const grid = elt('div', 'tgrid');
      items.forEach((t) => grid.appendChild(tweakCard(t)));
      g.appendChild(grid);
      host.appendChild(g);
    });
  }

  function tweakCard(t) {
    const meta = TIER_META[t.tier] || { cls: 't' + t.tier };
    const card = elt('div', 'tw ' + meta.cls);
    if (t.blocked) card.classList.add('blocked');
    if (t.applied && !t.blocked) card.classList.add('on');
    card.dataset.id = t.id;
    const top = elt('div', 'tw-top');
    top.appendChild(elt('div', 'tw-name', t.name));
    top.appendChild(elt('span', 'tw-state' + (t.blocked ? ' blocked' : (t.applied ? ' on' : '')), t.blocked ? 'no aplicable' : (t.applied ? 'activo' : 'inactivo')));
    card.appendChild(top);
    card.appendChild(elt('div', 'tw-desc', t.desc || ''));
    const foot = elt('div', 'tw-foot');
    const m = elt('div', 'tw-meta');
    if (t.source) { const a = elt('a', 'badge src', t.sourceType === 'official' ? 'fuente oficial' : 'fuente'); a.href = t.source; a.target = '_blank'; a.rel = 'noopener'; m.appendChild(a); }
    if (t.placebo) m.appendChild(elt('span', 'badge warn', 'placebo probable'));
    if (t.reboot) m.appendChild(elt('span', 'badge reboot', 'reinicio'));
    foot.appendChild(m);
    if (t.blocked) {
      foot.appendChild(elt('span', 'tw-blocked-why', t.blocked));
    } else {
      const act = elt('button', 'tw-act' + (t.applied ? ' revert' : ''), t.applied ? 'Revertir' : 'Aplicar');
      act.addEventListener('click', () => toggleTweak(t, card, act));
      foot.appendChild(act);
    }
    card.appendChild(foot);
    return card;
  }

  async function toggleTweak(t, card, act) {
    const wantApply = !t.applied;
    if (wantApply && t.tier === 2) {
      const ok = await confirmDialog('Tweak EXTREMO (Tier 2)', t.name + '\n\n' + (t.desc || '') + '\n\nOpt-in, de mayor riesgo. Es reversible, pero puede requerir reinicio. ¿Aplicar?', true);
      if (!ok) return;
    }
    act.disabled = true; act.textContent = wantApply ? 'aplicando…' : 'revirtiendo…';
    try {
      const r = await AXE.call(wantApply ? 'tweaks.apply' : 'tweaks.revert', { id: t.id });
      t.applied = !!r.applied;
      card.replaceWith(tweakCard(t));
      setOptBar((wantApply ? 'Aplicado' : 'Revertido') + ': ' + t.name + (r.reboot ? ' · requiere reinicio' : ''), 'ok');
    } catch (e) {
      act.disabled = false; act.textContent = wantApply ? 'Aplicar' : 'Revertir';
      setOptBar('Error en ' + t.name + ': ' + e.message, 'err');
    }
  }

  $('btnMasterRevert').addEventListener('click', async () => {
    const ok = await confirmDialog('Master revert', 'Revierte TODOS los tweaks aplicados a su estado previo real (snapshot 1-a-1 + limpieza de residuos v1). Puede tardar y conviene reiniciar al terminar. ¿Continuar?', true);
    if (!ok) return;
    const btn = $('btnMasterRevert'); btn.disabled = true;
    setOptBar('revirtiendo todo… no cierres la ventana', null);
    try {
      const r = await AXE.call('tweaks.masterRevert', {});
      setOptBar('Master revert: ' + r.reverted + ' revertidos' + (r.errors ? ' · ' + r.errors + ' con error (ver log)' : '') + ' · reinicia el PC', r.errors ? 'err' : 'ok');
      AXE.call('tweaks.list', {}).then((l) => renderCatalog(Array.isArray(l) ? l : [])).catch(() => {});
    } catch (e) {
      setOptBar('Master revert falló: ' + e.message, 'err');
    } finally { btn.disabled = false; }
  });

  // ================= Fase 7: vistas =================
  // Telemetría: barrido de timer bajo demanda (el jitter en vivo lo pinta el handler de telemetría
  // sobre #teleScope, reusando el mismo feed real; no se duplica el muestreo).
  function initTele() {
    const b = $('btnSweep');
    b.addEventListener('click', () => {
      const out = $('sweepOut');
      out.textContent = 'midiendo barrido… (~2 s · prioridad alta · no cierres la ventana)';
      b.disabled = true; b.classList.add('busy');
      AXE.call('measure.timerSweep', {}).then((r) => {
        out.textContent = (r.lines || []).join('\n');
      }).catch((e) => { out.textContent = 'No se pudo medir el barrido: ' + e.message; })
        .finally(() => { b.disabled = false; b.classList.remove('busy'); });
    });
    if (scopeBuf.length) drawScope($('teleScope'));
  }

  // Prueba y receta: A/B antes→después (baseline + report reales del motor) + FPS + diagnóstico.
  function initPrueba() {
    $('btnBaseline').addEventListener('click', () => {
      const b = $('btnBaseline'); b.disabled = true; b.classList.add('busy');
      $('pruebaBar').textContent = 'midiendo línea base… (~1 s)';
      AXE.call('prueba.baseline', {}).then((s) => {
        $('baseScore').textContent = s.total;
        $('baseTimer').textContent = (s.timerMs != null) ? (s.timerMs + ' ms') : 'n/a';
        $('baseJit').textContent = fmtMs(s.jitterP999);
        const tag = $('baseTag'); tag.textContent = 'capturado ' + (s.ts ? relTime(s.ts) : 'ahora'); tag.className = 'ab-tag ok';
        $('btnReport').disabled = false; $('btnReport').querySelector('span').textContent = 'antes → después';
        $('pruebaBar').textContent = 'línea base lista · aplica cambios en Optimizar (3), vuelve y mide el después';
      }).catch((e) => { $('pruebaBar').textContent = 'No pude medir baseline: ' + e.message; })
        .finally(() => { $('btnBaseline').disabled = false; $('btnBaseline').classList.remove('busy'); });
    });
    $('btnReport').addEventListener('click', () => {
      const b = $('btnReport'); b.disabled = true; b.classList.add('busy');
      $('reportOut').textContent = 'midiendo después + generando informe…';
      AXE.call('prueba.report', {}).then((r) => {
        $('afterScore').textContent = r.after;
        $('afterTimer').textContent = (r.afterTimerMs != null) ? (r.afterTimerMs + ' ms') : 'n/a';
        $('afterJit').textContent = fmtMs(r.afterJitterP999);
        const tag = $('afterTag'); tag.textContent = 'medido'; tag.className = 'ab-tag ok';
        $('reportOut').textContent = (r.lines || []).join('\n');
      }).catch((e) => { $('reportOut').textContent = 'No pude generar el informe: ' + e.message; })
        .finally(() => { $('btnReport').disabled = false; $('btnReport').classList.remove('busy'); });
    });
    // Benchmark con reinicio (subproyecto C). Distinto de baseline/report de arriba: aquel
    // compara dos snapshots de ESTA sesión; éste agrega N pasadas, mide el ruido y guarda el
    // «antes» en disco para que sobreviva al reinicio. El id se rellena solo tras el paso 1,
    // pero el campo es editable a propósito: tras reiniciar la ventana es nueva y el usuario
    // llega con el id apuntado (o lo saca de AXE/bench/).
    $('btnBenchBase').addEventListener('click', () => {
      const b = $('btnBenchBase'), out = $('benchOut');
      b.disabled = true; b.classList.add('busy');
      out.textContent = 'midiendo la línea base… (~10-30 s · no toques el equipo)';
      AXE.call('bench.baseline', {}).then((r) => {
        $('benchId').value = r.id || '';
        out.textContent = (r.lines || []).join('\n') +
          '\n\nLínea base guardada con id: ' + r.id +
          '\nAplica tus cambios, REINICIA el PC, vuelve aquí y pulsa «Medir después».';
      }).catch((e) => { out.textContent = 'No pude medir la línea base: ' + e.message; })
        .finally(() => { b.disabled = false; b.classList.remove('busy'); });
    });
    $('btnBenchAfter').addEventListener('click', () => {
      const id = $('benchId').value.trim(), out = $('benchOut');
      if (!id) { out.textContent = 'Escribe el id de la línea base (te lo dio el paso 1).'; $('benchId').focus(); return; }
      const b = $('btnBenchAfter'); b.disabled = true; b.classList.add('busy');
      out.textContent = 'midiendo el después y comparando contra el ruido… (~10-30 s)';
      AXE.call('bench.after', { id: id }).then((r) => {
        out.textContent = (r.lines || []).join('\n');
      }).catch((e) => { out.textContent = 'No pude comparar: ' + e.message; })
        .finally(() => { b.disabled = false; b.classList.remove('busy'); });
    });
    $('btnFps').addEventListener('click', () => {
      const proc = $('fpsProc').value.trim();
      const out = $('fpsOut'); out.hidden = false;
      if (!proc) { out.textContent = 'Escribe el nombre del proceso del juego (ej: cs2).'; $('fpsProc').focus(); return; }
      let secs = parseInt($('fpsSecs').value, 10); if (!(secs >= 3)) secs = 20;
      const b = $('btnFps'); b.disabled = true; b.classList.add('busy');
      out.textContent = 'capturando ' + secs + ' s… pon el juego en la escena a medir (la ventana puede tardar en responder)';
      AXE.call('fps.capture', { process: proc, seconds: secs }).then((r) => {
        out.textContent = (r.lines || []).join('\n');
      }).catch((e) => { out.textContent = 'No pude capturar: ' + e.message; })
        .finally(() => { b.disabled = false; b.classList.remove('busy'); });
    });
    $('btnDiag').addEventListener('click', () => {
      const b = $('btnDiag'); b.disabled = true; b.classList.add('busy');
      $('diagList').textContent = ''; $('diagOut').hidden = true;
      AXE.call('diag.get', {}).then((r) => renderDiag(r))
        .catch((e) => { const o = $('diagOut'); o.hidden = false; o.textContent = 'No pude diagnosticar: ' + e.message; })
        .finally(() => { b.disabled = false; b.classList.remove('busy'); });
    });
  }
  function renderDiag(r) {
    const host = $('diagList'); host.textContent = '';
    const finds = (r && r.findings) ? r.findings : [];
    if (!finds.length) { const o = $('diagOut'); o.hidden = false; o.textContent = (r && r.lines ? r.lines.join('\n') : 'sin hallazgos'); return; }
    finds.forEach((f) => {
      const st = String(f.status || '').toLowerCase();
      const cls = st === 'bad' ? 'bad' : (st === 'ok' ? 'ok' : 'unk');
      const card = elt('div', 'finding ' + cls);
      const top = elt('div', 'finding-top');
      top.appendChild(elt('span', 'finding-dot'));
      top.appendChild(elt('div', 'finding-title', f.title || ''));
      top.appendChild(elt('span', 'finding-badge ' + cls, st === 'bad' ? 'mal' : (st === 'ok' ? 'ok' : '?')));
      card.appendChild(top);
      if (f.detail) card.appendChild(elt('div', 'finding-detail', f.detail));
      if (st === 'bad') {
        if (f.fix) { const fx = elt('div', 'finding-fix'); fx.appendChild(elt('b', null, 'Arreglo: ')); fx.appendChild(document.createTextNode(f.fix)); card.appendChild(fx); }
        if (f.estPct) card.appendChild(elt('div', 'finding-est', 'en juego: ' + f.estPct + ' · estimación típica, no medida en esta máquina'));
      }
      host.appendChild(card);
    });
  }

  // Seguridad: punto de restauración (best-effort, honesto si el SO lo bloquea) + master revert.
  function initSeguridad() {
    $('btnRestore').addEventListener('click', () => {
      const b = $('btnRestore'); b.disabled = true; b.classList.add('busy');
      $('segRpState').textContent = 'creando…'; $('rpDot').className = 'dot';
      AXE.call('safety.restorePoint', {}).then((r) => {
        const ok = r.status === 'ok', fb = r.status === 'fallback';
        $('segRpState').textContent = ok ? 'creado' : (fb ? 'no disponible' : 'error');
        $('rpDot').className = 'dot ' + (ok ? 'ok' : (fb ? 'warn' : 'err'));
        $('segRpMsg').textContent = r.message || '—';
        const rs = $('rpState'); if (rs) { rs.textContent = ok ? 'creado' : (fb ? 'no disp.' : 'error'); rs.className = ok ? 'ok' : 'neutral'; }
        const rd = $('rpDetail'); if (rd) rd.textContent = r.message || '';
      }).catch((e) => { $('segRpState').textContent = 'error'; $('rpDot').className = 'dot err'; $('segRpMsg').textContent = e.message; })
        .finally(() => { $('btnRestore').disabled = false; $('btnRestore').classList.remove('busy'); });
    });
    $('btnSegMaster').addEventListener('click', async () => {
      const ok = await confirmDialog('Master revert', 'Revierte TODOS los tweaks aplicados a su estado previo real (snapshot 1-a-1 + limpieza de residuos). Puede tardar y conviene reiniciar al terminar. ¿Continuar?', true);
      if (!ok) return;
      const b = $('btnSegMaster'); b.disabled = true;
      const msg = $('segMasterMsg'); msg.hidden = false; msg.textContent = 'revirtiendo todo… no cierres la ventana';
      try {
        const r = await AXE.call('tweaks.masterRevert', {});
        msg.textContent = 'Master revert: ' + r.reverted + ' revertidos' + (r.errors ? ' · ' + r.errors + ' con error (ver log)' : '') + ' · reinicia el PC';
        if (loaded.optimizar) AXE.call('tweaks.list', {}).then((l) => renderCatalog(Array.isArray(l) ? l : [])).catch(() => {});
      } catch (e) { msg.textContent = 'Master revert falló: ' + e.message; }
      finally { b.disabled = false; }
    });
  }

  // Ajustes: información local + privacidad. Sin lógica de red, sin auto-update (es otro spec).
  function initAjustes() {
    AXE.call('app.info', {}).then((info) => {
      if (!info) return;
      if (info.version) $('ajVer').textContent = 'v' + info.version;
      if (info.tweaks != null) $('ajTweaks').textContent = info.tweaks + ' tweaks';
    }).catch(() => { $('ajVer').textContent = '?'; });
  }

  // ---------- telemetria PS->JS: uptime + feeds en vivo reales (Fase 5) ----------
  AXE.on('telemetry', (d) => {
    if (!d) return;
    if (d.uptimeS != null) {
      const s = d.uptimeS, h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60);
      $('uptime').textContent = 'encendido hace ' + (h > 0 ? h + ' h ' : '') + m + ' min';
    }
    const hasLive = (d.cpu != null || d.ram != null || d.jitterUs != null);
    if (hasLive && !liveStarted) {
      liveStarted = true;
      document.querySelectorAll('.vital.resting').forEach((v) => v.classList.remove('resting'));
      document.querySelectorAll('[data-vital="cpu"] .live-tag,[data-vital="ram"] .live-tag').forEach((t) => { t.textContent = 'en vivo'; });
      const ss = $('scopeState'); if (ss) ss.textContent = 'muestreo en vivo · ~1/s';
    }
    if (d.cpu != null) { pushBuf(cpuBuf, d.cpu, 60); $('cpuV').textContent = Math.round(d.cpu) + ' %'; drawSpark(cpuCanvas, cpuBuf); }
    if (d.ram != null) { pushBuf(ramBuf, d.ram, 60); $('ramV').textContent = Math.round(d.ram) + ' %'; drawSpark(ramCanvas, ramBuf); }
    if (d.jitterMeanUs != null) lastMeanUs = d.jitterMeanUs;
    if (d.jitterUs != null) {
      pushBuf(scopeBuf, d.jitterUs, 160);
      scopeMax = Math.max(scopeMax * 0.98, d.jitterUs);
      drawScope();
      const sorted = scopeBuf.slice().sort((a, b) => a - b);
      const p99 = sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * 0.99))];
      const nowEl = $('sNow'); nowEl.textContent = Math.round(d.jitterUs) + ' µs'; nowEl.style.color = d.jitterUs > THR ? '#D9605A' : '#E6EAF0';
      $('sP99').textContent = Math.round(p99) + ' µs';
      $('sMax').textContent = Math.round(scopeMax) + ' µs';
      // mismo feed alimenta el osciloscopio grande de Telemetría (sin duplicar el muestreo)
      if (teleLoaded) {
        drawScope($('teleScope'));
        const tn = $('tNow'); if (tn) { tn.textContent = Math.round(d.jitterUs) + ' µs'; tn.style.color = d.jitterUs > THR ? '#D9605A' : '#E6EAF0'; }
        if (lastMeanUs != null) { const tm = $('tMean'); if (tm) tm.textContent = Math.round(lastMeanUs) + ' µs'; }
        const tp = $('tP99'); if (tp) tp.textContent = Math.round(p99) + ' µs';
        const tmx = $('tMax'); if (tmx) tmx.textContent = Math.round(scopeMax) + ' µs';
        const tst = $('teleState'); if (tst) tst.textContent = 'muestreo en vivo · ~1/s';
      }
    }
  });
})();
