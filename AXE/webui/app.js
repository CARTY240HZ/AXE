// Arranque temporal (Fase 2-3): pide el hardware por el puente y escucha telemetria.
// El router + vistas llegan en Fase 4/7.
(async function () {
  const el = document.getElementById('app');
  try {
    const hw = await window.AXE.call('hw.get', {});
    el.textContent = 'CPU: ' + hw.CpuName + '  ·  RAM: ' + hw.RamGB + ' GB  ·  ' + hw.Edition;
  } catch (e) {
    el.textContent = 'Puente error: ' + e.message;
  }

  // PS -> JS telemetria (Fase 3): canal push por PostWebMessageAsJson.
  window.AXE.on('telemetry', (d) => {
    el.setAttribute('data-uptime', d.uptimeS);
    el.title = 'uptime ' + d.uptimeS + 's · ' + d.ts;
  });
})();
