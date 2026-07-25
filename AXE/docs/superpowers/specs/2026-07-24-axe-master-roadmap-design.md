# AXE — Roadmap maestro a "superior industrial élite" (A–H)

**Fecha:** 2026-07-24
**Estado:** Diseño aprobado (jefe de orquestación). Doc maestro; cada subproyecto → su plan propio.
**Rama:** axe

---

## 0. Visión y principio rector

AXE ya gana a hone.gg / pulsehardware / atlaspro / deltapro / optimizadores de GitHub en lo que
importa a un ingeniero: **honestidad anti-placebo, revert por snapshot, gating por hardware, medición
nativa, auditable**. Este roadmap cierra la brecha de **producto** (que un usuario lo instale, lo
pruebe, confíe y actualice) **sin traicionar** esa ventaja.

**Invariante en cada subproyecto:** 0 fallos SelfTest, Pester verde, honestidad textual (PlaceboLikely
/ veredicto de ruido / `null` cuando no se mide), reversibilidad, openness.

**NON-goals globales (categoría):** driver kernel / timer ring0 (mata safety+openness+confianza,
requiere cert EV + responsabilidad legal → es Atlas ISO, otra categoría), código cerrado, debloat que
baje seguridad (Defender/SmartScreen). Ser "no superior" en profundidad-kernel es **decisión**, no
derrota.

## 1. Mapa de subproyectos

| Sub | Qué cierra | Depende | Spec | Estado |
|---|---|---|---|---|
| **C** | Prueba medible (benchmark) | — | `2026-07-24-axe-benchmark-design.md` | ✅ **implementado** |
| **A** | Firma + cadena de confianza | — | `2026-07-24-axe-signing-release-design.md` | ✅ **implementado** (falta comprar el cert) |
| **B** | Release + distribución + updater | A | `2026-07-24-axe-signing-release-design.md` | ✅ **implementado** (falta abrir la PR de winget) |
| **D** | Matriz validación + profundidad test | — | §2 (inline) | ✅ spec |
| **E** | Observabilidad + auto-reparación | — | §3 (inline) | ✅ spec |
| **F** | Docs + governance | — | §4 (inline) | ✅ spec |
| **G** | UX / i18n / a11y | — | §5 (inline) | ✅ spec |
| **H** | Breadth acotado (opcional) | — | §6 (inline) | ✅ spec |

**Orden por leverage:** C → A → B → F → D → E → G → H.
**Mínimo para "superior de producto" honesto:** C + A + B + F. D–H = robustez/alcance.

---

## 2. Subproyecto D — Matriz de validación + profundidad test

**Propósito:** probar AXE ampliamente, no solo `windows-latest`. Industrial = tested broadly.

**Componentes:**
- **CI matrix** (`ci.yml`): `windows-2022` + `windows-2025` × pwsh 5.1 y 7.x. arm64 = documentado como
  futuro (GitHub aún no da runner windows-arm64 gratis; self-hosted opcional).
- **Code coverage**: `cfg.CodeCoverage.Enabled` en el runner → Cobertura XML como artefacto + umbral
  que no baje del actual (gate informativo primero, bloqueante después).
- **Fuzz de parsers** (`tests/Fuzz.Tests.ps1`): entradas aleatorias/property-based a
  `ConvertFrom-AXEGpuPref`, `Read-StateBak`, `Read-AXEBenchBaseline` → **no deben lanzar**, degradan a
  `$null`/vacío.
- **Meta-test de guards**: alterar sintéticamente un `Test`/`Apply` de un tweak y confirmar que
  SelfTest (S1/S5/S24) lo caza → prueba que los guards realmente guardan.
- **Integration ampliado**: más tweaks HKCU en el round-trip `Apply → Test → Restore-TweakState`.

**Testing / Done:** CI verde en toda la matriz; coverage publicado; fuzz 0 excepciones; meta-test
demuestra que romper un tweak pone SelfTest en rojo.

---

## 3. Subproyecto E — Observabilidad + auto-reparación

**Propósito:** cuando algo falla en la máquina del usuario, diagnosticable sin adivinar.

**Componentes:**
- `-Doctor` / `-Health` (`src/44-doctor.ps1`, o dentro de `35-diag`): chequeo de entorno — pwsh
  version, runtime WebView2, PresentMon, admin, estado de los servicios que AXE toca, integridad de
  `tweak_state.json`/`profiles.json`. Imprime informe accionable + exit code (0 sano / 1 con avisos).
- **Logging estructurado**: además del log de texto por día, opción JSON-lines parseable (`AXE_LOG_JSON=1`),
  niveles coherentes. Rotación ya existe (log por fecha).
- **Captura de crash local**: `trap` global (en `49-webmain`/`45-cli`) que vuelca stack + entorno a
  `AXE/crash_<ts>.log` **sin PII**; el usuario lo adjunta a un issue.
- **Auto-reparación de estado**: extiende el patrón `tweak_state.corrupt` ya existente a
  `profiles.json` y baselines de bench; comando `-Repair` que valida y renombra corruptos.

**Testing / Done (SelfTest S31):** `-Doctor` produce informe con la forma esperada sin lanzar; el
handler de corrupción renombra a `.corrupt` y sigue; crash-capture escribe archivo. Todo headless.

---

## 4. Subproyecto F — Docs + governance

**Propósito:** señales de confianza de repositorio de producción (lo que todo proyecto serio tiene).

**Componentes:**
- `SECURITY.md` — política de reporte de vulnerabilidades, alcance (herramienta admin), contacto.
- `CONTRIBUTING.md` — cómo añadir un tweak: schema de 10 claves, `NotesEng`+`SourceType`+`PlaceboLikely`
  **obligatorios y honestos**, tests requeridos, correr SelfTest+Pester antes del PR.
- `CODE_OF_CONDUCT.md`.
- `.github/ISSUE_TEMPLATE/` (bug / tweak-proposal / hw-report) + `PULL_REQUEST_TEMPLATE.md`.
- **Threat model** (`docs/THREAT-MODEL.md`): superficie (admin, registro HKLM/HKCU, puente WebView,
  updater) + mitigaciones (whitelist RPC, snapshot revert, firma+checksum, `Deny` cross-origin, CSP).
- **Docs de catálogo autogenerados** (`scripts/Build-AXEDocs.ps1`): vuelca `$script:CAT` (Desc /
  NotesEng / Source / Tier / Requires) a Markdown/HTML — rationale por tweak, **una sola fuente**
  (el catálogo), imposible que la doc mienta respecto al código.
- README badges: CI, version, license, signed.

**Testing / Done:** todos los governance files presentes; `Build-AXEDocs.ps1` genera doc por tweak
desde el catálogo vivo (test: la doc lista los N tweaks reales); threat model cubre las 4 superficies.

---

## 5. Subproyecto G — UX / i18n / a11y

**Propósito:** ampliar alcance más allá del español + accesibilidad.

**Componentes:**
- **i18n webui**: extraer strings a `webui/i18n/{es,en}.json` + `data-i18n` en el markup; selector de
  idioma; `es` default. Honesto: el CLI tiene mucho texto español embebido → fase 1 = webui EN
  completo; CLI i18n = trabajo mayor, fase posterior con tabla de mensajes.
- **a11y**: nav por teclado completo, roles/labels ARIA, focus management, contraste AA (verificar el
  tema oscuro), **respeta `prefers-reduced-motion`** (gotcha conocido 2026-07-17).
- **Tema**: ya oscuro; añadir light + `prefers-color-scheme` / toggle.

**Testing / Done:** EN completo en webui, keyboard-nav operable, contraste AA, reduce-motion honrado.
La CSP ya añadida (`connect-src 'none'`) garantiza que i18n no cargue nada externo.

---

## 6. Subproyecto H — Breadth acotado (opcional, riesgo de categoría)

**Propósito:** más cobertura **sin erosionar seguridad**.

**Componentes (todos con el schema honesto del catálogo: reversible, Source, PlaceboLikely):**
- **Debloat ACOTADO**: solo apps/telemetría reversibles. **NUNCA** Defender/SmartScreen/seguridad
  (anti-value explícito). Cada entrada gated y reversible como cualquier tweak.
- **Startup manager**: ya existe backup/restore de autoruns; exponer gestor (listar/deshabilitar con
  backup) en CLI+webui.
- **Driver hints**: **DETECTAR** drivers viejos y avisar (estilo `-Diag`). **NO** descargar ni
  instalar (misma política que PresentMon/updater).

**Done:** debloat reversible que no toca seguridad; startup manager con backup; aviso de driver-age
sin instalar nada. **NON-goal reforzado:** cero bajada de seguridad, cero instalación de binarios.

---

## 7. Criterio maestro de "industrial élite"

- **C + A + B + F** entregados → superioridad de **producto** honesta y demostrable (se prueba, se
  instala firmado, se confía). Es el mínimo para el claim sin mentir.
- **D + E** → robustez y observabilidad de nivel industrial.
- **G** → alcance (EN + a11y).
- **H** → breadth sin comprometer la ventaja.
- Todo conserva los invariantes del §0. Nada cruza los NON-goals de categoría.
- **Prueba de fuego:** un tercero técnico audita el repo y NO encuentra una sola cifra inventada, un
  solo revert que adivine, ni una sola descarga de binario sin verificar. Eso es lo que hone/atlas/
  delta no pueden decir de los suyos.

## 8. Secuencia de ejecución (una sesión por subproyecto)

`C` (arma) → `A` (firma) → `B` (release+updater) → `F` (confianza) → `D` (validación) →
`E` (observabilidad) → `G` (alcance) → `H` (breadth). Cada uno: writing-plans sobre su spec → TDD →
rebuild → SelfTest 0 fallos + Pester verde → commit.
