# =====================================================
# REGION 14b - ARRANQUE DEL HOST WEB (bootstrap)
# =====================================================
# Va DESPUES de 47-webhost, 47b-websecurity y 48-webbridge para que todas las definiciones
# existan cuando arranque. Espeja el rol de 99-main.ps1 con la GUI vieja: separa el bootstrap
# de las definiciones.
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
try { [void](Restore-AXESessionDegraded) } catch {}

# WebView2 se ejecuta con una superficie de privilegios sensible. La politica de seguridad se
# inicializa SOLO aqui, dentro del camino GUI/STA, nunca durante la carga headless del motor.
try { Start-AXEWebSecurityWatcher } catch { Write-AXELog "No pude iniciar el watcher de seguridad WebView2: $($_.Exception.Message)" 'ERR' }

Show-AXEWebHost
exit 0
