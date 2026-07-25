# Publicar AXE en winget

Subproyecto B (spec `docs/superpowers/specs/2026-07-24-axe-signing-release-design.md`).

`winget install AXE` es distribucion **nativa** de Windows: sin warning de SmartScreen en la
descarga, con actualizacion por `winget upgrade`, y sin que el usuario tenga que confiar en un
enlace pegado en un video de YouTube. Es la via mas barata de cerrar la brecha de distribucion
con hone.gg / atlaspro / deltapro, y no cuesta dinero.

## Los manifiestos NO se editan a mano

Los genera `scripts/New-AXEWingetManifest.ps1` a partir del release ya construido, y el CI los
produce en cada tag. Motivo: de los ~40 campos, tres cambian en cada version (version, URL y
**SHA256 del zip**) y uno es un hash de 64 caracteres. Un manifiesto copiado de la version
anterior pasa la revision humana sin problema y luego falla en la maquina del usuario con un
"el paquete esta corrupto" que no tiene nada que ver con lo que realmente paso.

```powershell
# tras ./scripts/New-AXERelease.ps1
./scripts/New-AXEWingetManifest.ps1 -Tag v7.0.0
# -> dist/release/winget/7.0.0/{CARTY240HZ.AXE.yaml, .installer.yaml, .locale.en-US.yaml}
```

## Procedimiento (a mano, a proposito)

El script **no** abre la PR. Un automatismo que publica solo en el repo de paquetes de
Microsoft es exactamente el tipo de cosa que no debe existir sin revision humana.

1. **Publicar el release primero.** La URL del `InstallerUrl` tiene que existir y devolver 200
   antes de abrir la PR, o la validacion de winget falla.

2. **Validar en local:**
   ```powershell
   winget validate --manifest .\dist\release\winget\7.0.0
   # instalacion real desde el manifiesto local (necesita habilitar manifiestos locales):
   winget settings --enable LocalManifestFiles
   winget install --manifest .\dist\release\winget\7.0.0
   ```
   Comprueba a mano que tras instalar: `axe -List` funciona, la GUI abre, y `axe -Update -Check`
   responde. Si `webui/` o `webview2/` no viajaron dentro del zip, la GUI abre en blanco: eso lo
   caza esta prueba, no el validador.

3. **Fork de [`microsoft/winget-pkgs`](https://github.com/microsoft/winget-pkgs)** y copiar los
   tres ficheros a:
   ```
   manifests/c/CARTY240HZ/AXE/<version>/
   ```

4. **PR.** Un commit, titulo `New version: CARTY240HZ.AXE version <version>`. Los bots validan
   el hash, el esquema y hacen una instalacion real en sandbox. Suele tardar de horas a un par
   de dias.

## Primera vez (paquete nuevo)

La primera PR crea el paquete y la revisan humanos, no solo bots. Lo que miran:

- Que el `PackageIdentifier` (`CARTY240HZ.AXE`) coincida con el publisher real del repo.
- Que la `ShortDescription` describa lo que el paquete hace de verdad. La nuestra dice tambien
  lo que **no** hace (no toca la imagen de Windows, no desactiva Defender, no instala driver de
  kernel, no promete FPS sin medirlos): es honesto y ademas evita que un revisor lo clasifique
  como uno mas de los "system optimizer" que suelen rechazar.
- Que la URL sea estable y de un release, no de una rama.

## Estado de la firma

winget **no** exige firma Authenticode para un `portable`. Pero:

- Sin firma, quien descargue el zip a mano ve el warning de SmartScreen, y `AXE -Update` se
  niega a auto-instalar (por diseno, ver `src/43-update.ps1`).
- Con firma OV (~200 $/ano) el warning desaparece por reputacion acumulada; con EV
  (~400-600 $/ano + token HSM) desaparece desde la primera descarga.

Mientras no haya certificado, la cadena de confianza que SI se ofrece es real y verificable:
`SHA256SUMS` + `sbom.json` + commits y tags firmados. Es mas de lo que da la practica totalidad
de optimizadores de GitHub, que se distribuyen como `.bat` crudo sin nada de esto.

## Checklist antes de la PR

- [ ] Release publicado y `InstallerUrl` devuelve 200
- [ ] `winget validate` sin errores
- [ ] Instalacion local real probada (`-List`, GUI, `-Update -Check`)
- [ ] El `InstallerSha256` del manifiesto coincide con el zip publicado
      (`(Get-FileHash AXE-<ver>.zip -Algorithm SHA256).Hash`)
- [ ] La version del manifiesto coincide con `VERSION`, con el tag y con lo que reporta
      `AXE -SelfTest`
