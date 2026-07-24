# AXE Firma + Release + Updater (subproyectos A + B)

**Fecha:** 2026-07-24
**Estado:** Diseño aprobado (jefe de orquestación). Pendiente: writing-plans → implementación.
**Rama:** axe
**Depende de:** nada de código; B (updater/release firmado) depende de A (firma+checksum).

---

## 1. Propósito

Convertir AXE de "script que corres" en **producto instalable y actualizable con cadena de confianza
verificable**: sin warning SmartScreen (con cert), integridad demostrable (checksums + SBOM +
timestamp), distribución nativa Windows (winget), y auto-update que **solo confía en assets firmados
por el propio repo**. Cierra la brecha de distribución con hone/atlas/delta sin traicionar la política
del proyecto (nada de binarios de terceros a ciegas).

## 2. No-goals (YAGNI)

- **NO** descargar/ejecutar binarios de terceros a ciegas (misma política que rechazar auto-bajar
  PresentMon). El updater solo acepta assets del repo oficial, firmados + con checksum.
- **NO** instalador pesado (MSIX / Inno / WiX). Userland PS no lo necesita: copia + shortcut + updater.
- **NO** telemetría ni "phone home" en el updater. Solo lee la GitHub Releases API pública.
- **NO** auto-update silencioso. Comprueba y avisa; reemplaza solo tras verificar firma+checksum.
- **NO** hardcodear compra de certificado en el código. El pipeline funciona firmado O sin firmar
  (degrada honesto); comprar cert es decisión de dinero del owner.

## 3. Arquitectura

### A — Firma + cadena de confianza
- `scripts/Sign-AXE.ps1` (ya existe, completar): `Set-AuthenticodeSignature` sobre `dist/AXE.ps1`
  con cert (`Cert:\CurrentUser\My\<thumb>` local, o PFX desde secret en CI) **+ servidor timestamp
  RFC3161** (`-TimestampServer`) para que la firma sobreviva a la expiración del cert.
- `.cat` catálogo firmado de los assets vendored (webview2 DLLs, `AXE.ps1`, `AXE.bat`).
- `SHA256SUMS` — generado en build/release sobre todos los assets publicables.
- `sbom.json` — CycloneDX listando componentes vendored (WebView2 SDK/runtime DLLs, PresentMon
  opcional) → supply-chain transparente.
- Commits + tags de release firmados (GPG/SSH; config del repo, no código).

### B — Release + distribución + updater
- `.github/workflows/release.yml`: trigger `push tags 'v*'` → `build.ps1` → firma (si hay secret) →
  `SHA256SUMS` + `sbom.json` → crea GitHub Release con assets (`AXE.ps1`, `AXE.bat`, `webview2.zip`,
  `SHA256SUMS`, `sbom.json`, el spec). En PR: dry-run (build+checksum+sbom sin publicar).
- `scripts/New-AXEInstaller.ps1` — instalador ligero: copia a `%LOCALAPPDATA%\AXE`, crea acceso
  directo elevado (via `AXE.bat`), registra el updater. Sin MSIX.
- `packaging/winget/` — manifest (version/installer/locale) + doc del PR a `microsoft/winget-pkgs`.
  `winget install AXE` = distribución nativa, sin warning, update por winget.
- `src/43-update.ps1` — módulo del updater (numeración libre entre 41-bench y 45-cli). Comando
  `-Update` / `-Update -Check` en `45-cli` (+ `[switch]$Update`, `[switch]$Check` en `00-header`,
  verificando colisión de nombres — lección S24).

## 4. Componentes (contratos)

- `Test-AXESignature([string]$Path) -> [bool]`
  `Get-AuthenticodeSignature` → `$true` solo si `Status -eq 'Valid'`. Base de la verificación del
  updater; usado también por el launcher para avisar si el propio AXE fue manipulado.

- `Get-AXELatestRelease() -> [pscustomobject]{ Tag; Assets; PublishedAt } | $null`
  GET a `api.github.com/repos/CARTY240HZ/AXE/releases/latest` (público, sin token). Owner/repo
  **hardcoded** (no URL arbitraria). Sin red / rate-limit → `$null` + mensaje honesto, no lanza.

- `Invoke-AXEUpdate([switch]$Check) -> [pscustomobject]{ Status; Current; Latest; Message }`
  Compara `VERSION` local vs `Tag` (SemVer). `-Check` = solo informa. Sin `-Check`: descarga asset +
  `SHA256SUMS` (+ firma) a temp → **verifica checksum Y `Test-AXESignature`** → si OK, reemplazo
  atómico (escribe temp, `Move-Item -Force`). Firma/checksum inválidos → **aborta, NO reemplaza**,
  mensaje. Nunca reemplaza desde una fuente no verificada.

- `New-AXEChecksums($dir) -> [string]$sha256sumsPath` / `New-AXESbom() -> [string]$sbomPath`
  Deterministas (para el guard anti-deriva). Corren en build/release.

## 5. Datos

- `SHA256SUMS` — `<sha256>␠␠<filename>` por asset (formato coreutils, verificable con `sha256sum -c`).
- `sbom.json` — CycloneDX 1.5, componentes con nombre/versión/hash/licencia.
- Updater: lee `VERSION` local vs `tag_name` de la API. Estado en memoria, no persiste.
- `*.pfx` / `*.snk` — **NUNCA** en repo (ya en `.gitignore`); cert en GitHub secret.

## 6. Manejo de errores

- Sin cert (local o CI) → firma se salta con `WARN`; build/release siguen y marcan el asset
  **"unsigned" honestamente** (no finge estar firmado).
- Updater firma inválida / checksum mismatch → aborta, no toca el `dist` actual, mensaje claro.
- Sin red / API rate-limit → "no pude comprobar actualizaciones", exit limpio, no rompe.
- Timestamp server caído → firma sin timestamp con `WARN` (degrada, no aborta).

## 7. Seguridad (crítico)

- Updater acepta **solo** assets del repo oficial (owner/repo hardcoded) **firmados + checksum**.
  Jamás una URL o versión pasada por el usuario. Esto es lo que impide ser el agujero supply-chain
  que se critica de otros.
- Reemplazo atómico (temp + `Move-Item`) → nunca un `dist` a medio escribir.
- Cert PFX solo en secret CI; verificación de firma usa la cadena de confianza del sistema.

## 8. Testing

- **SelfTest S30**: `Test-AXESignature` sobre fixture (o skip honesto si no hay cert en el entorno);
  `Get-AXELatestRelease` parseando un JSON fixture local (CI sin red); round-trip de checksum
  (genera → verifica). `Invoke-AXEUpdate` version-compare puro con VERSIONs sintéticas.
- **Pester** (`tests/Update.Tests.ps1`): SemVer compare (igual/menor/mayor/prerelease), verificación
  de checksum, **refuse-on-mismatch** (fixture con hash malo → aborta sin reemplazar), asset del repo
  equivocado → rechazo. Sin tag integration (headless, sin red — todo con fixtures).
- **release.yml**: dry-run en PR (build + checksum + sbom, sin publicar) para validar el pipeline.

## 9. Orden de build (para writing-plans)

1. **A**: `New-AXEChecksums` + `New-AXESbom` en build/release (gratis, primero, alimenta el guard
   anti-deriva).
2. **A**: completar `Sign-AXE.ps1` (timestamp RFC3161) + step de firma en CI (secret-gated, degrada
   sin secret).
3. **B**: `release.yml` tag-triggered → firma + checksum + sbom → GitHub Release.
4. **B**: `src/43-update.ps1` (`Test-AXESignature`, `Get-AXELatestRelease`, `Invoke-AXEUpdate`) +
   `-Update` en CLI + params en `00-header` (+ S24) + SelfTest S30 + `tests/Update.Tests.ps1`.
5. **B**: `packaging/winget/` manifest + doc del PR.
6. **B**: `New-AXEInstaller.ps1` (copia + shortcut + registra updater).

## 10. Criterio de "hecho" (elite)

- `git tag v7.x` → CI publica release **firmado** (o unsigned-honest) con `SHA256SUMS` + `sbom.json`.
- `AXE -Update` comprueba, **verifica firma + checksum**, reemplazo atómico, **rechaza cualquier
  asset manipulado** (regresión-test lo prueba).
- `winget install AXE` funciona tras el merge del PR.
- Cero descarga de terceros; solo assets del repo, firmados. 0 fallos SelfTest, Pester verde.

## 11. Nota de coste (honesta)

El único gasto real es el **certificado code-signing** (OV ~$200/año, reputación por descargas; EV
~$400-600/año + token HSM, reputación SmartScreen instantánea). **Todo lo demás es gratis** y ya te
pone por encima de la mayoría de optimizadores de GitHub, que se distribuyen como `.bat` crudo sin
firma, sin checksum, sin SBOM. Sin cert, la cadena degrada a "checksums + SBOM + commits firmados" —
sigue siendo superioridad de confianza real, solo sin quitar el warning de SmartScreen.
