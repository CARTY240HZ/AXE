# Carga las funciones de AXE para test unitario del puente, sin arrancar CLI/GUI/host.
# Dot-sourcea los modulos del motor + 39-webdetect + 48-webbridge, SALTANDO:
#   00 (param block / #Requires), 15/23/25 (side-effects de arranque no necesarios),
#   45 (CLI dispatch + exit), 47/49/50/52/55/57/60/99 (host + arranque + GUI, abren ventana).
# Cargar 48 solo DEFINE el mapa y las funciones; nada se ejecuta.
$env:AXE_NOSR   = '1'   # no crear puntos de restauracion reales
$env:AXE_LIBONLY = '1'
$src = Join-Path (Split-Path $PSScriptRoot -Parent) 'src'
Get-ChildItem $src -Filter '*.ps1' | Sort-Object Name | ForEach-Object {
    if($_.Name -match '^(00|15|23|25|45|47|49|50|52|55|57|60|99)'){ return }
    . $_.FullName
}
