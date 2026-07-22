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
Show-AXEWebHost
exit 0
