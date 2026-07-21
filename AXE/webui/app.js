// Arranque temporal (Fase 2): pide el hardware al motor por el puente y lo pinta.
// El router + vistas llegan en Fase 4/7.
(async function () {
  const el = document.getElementById('app');
  try {
    const hw = await window.AXE.call('hw.get', {});
    el.textContent = 'CPU: ' + hw.CpuName + '  ·  RAM: ' + hw.RamGB + ' GB  ·  ' + hw.Edition;
  } catch (e) {
    el.textContent = 'Puente error: ' + e.message;
  }
})();
