# =====================================================
# REGION 14b - ARRANQUE DEL HOST WEB (bootstrap)
# =====================================================
# Va DESPUES de 47-webhost (Show-AXEWebHost) y 48-webbridge (Register-AXEBridge) para que ambos
# esten definidos cuando arranque. Espeja el rol de 99-main.ps1 con la GUI vieja: separa el
# bootstrap de las definiciones.
#
# Cutover (Fase 8): la GUI WPF vieja (50-60, 99-main) se retiro. Este es el arranque UNICO del
# frontend, incondicional. Llegar aqui = modo GUI: los modos CLI (-SelfTest/-List/-Diag/...) ya
# hicieron 'exit' en 45-cli, y las pruebas Pester cargan via _load-engine, que SALTA este modulo
# (no abre ventana). El harness del build entra con AXE_WEBUI_TEST=1: Show-AXEWebHost construye la
# carcasa, imprime 'WEBHOST OK' y vuelve sin ShowDialog bloqueante. El arranque real (sin ese flag)
# bloquea con la ventana hasta que el usuario la cierra. El 'exit 0' cierra el proceso al volver.
# Antes de abrir la ventana: si una sesion anterior no cerro limpiamente (kill, BSOD, corte de luz),
# el kernel ya descongelo lo congelado, pero las prioridades DEGRADADAS siguen bajas porque eso no es
# estado del job. El diario en disco (AXE/session_degraded.json) las devuelve, comprobando
# pid+nombre+arranque para no tocar un proceso que solo heredo el numero.
# --- BROKER (issue #5): antes que cualquier otra cosa del arranque GUI, incluido
# Restore-AXESessionDegraded. Si -Broker esta presente, este proceso ES el broker: procesa
# UNA peticion y sale, nunca llega a abrir la ventana. No puede vivir en 45-cli.ps1: ese modulo
# se concatena ANTES que 46-broker.ps1 (orden alfabetico de build.ps1), y PowerShell no permite
# llamar una funcion antes de que su sentencia 'function' se haya ejecutado en el script -- Start-
# AXEBroker (definida en 46) no existiria todavia en ese punto si el despacho viviera en 45.
# -LibOnly (worker del puente): motor ya definido, se vuelve SIN abrir ventana. 'return', no
# 'exit': es un dot-source dentro del proceso GUI y 'exit' mataria el runspace del worker.
if($LibOnly){ return }
if($Broker){
    exit (Start-AXEBroker $Broker $Token)
}

try { [void](Restore-AXESessionDegraded) } catch {}
Show-AXEWebHost
exit 0
