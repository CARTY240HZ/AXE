# =====================================================
# REGION 14b - ARRANQUE DEL HOST WEB (bootstrap)
# =====================================================
# Va DESPUES de 47-webhost (Show-AXEWebHost) y 48-webbridge (Register-AXEBridge) para que ambos
# esten definidos cuando arranque. Espeja el rol de 99-main.ps1 con la GUI vieja: separa el
# bootstrap de las definiciones.
#
# Solo en modo GUI (sin args CLI, que ya hicieron 'exit' en 45-cli) y con el flag AXE_WEBUI=1.
# El 'exit 0' impide que sigan cargando/ejecutandose la GUI WPF vieja (50-60) y 99-main.
# En el cutover (Fase 8) el flag desaparece y esto pasa a ser el arranque unico e incondicional.
if($env:AXE_WEBUI -eq '1' -and $env:AXE_GUITEST -ne '1' -and $env:AXE_GUISHOW -ne '1'){
    Show-AXEWebHost
    exit 0
}
