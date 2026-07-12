# AXE v6 "Elite" — Design Spec

- **Date:** 2026-07-12
- **Status:** Approved (direction + F0/debloat decisions)
- **Goal:** Make AXE the best-in-class gaming optimizer — better than WinUtil *in its niche* — and production-grade for mass distribution.

## Strategic framing

WinUtil (Chris Titus, signed EV, MIT) wins on **breadth**: 300+ app installer, full Windows Update control, aggressive debloat, MicroWin ISO builder. Cloning all of it inside a single `.ps1` produces a *worse WinUtil*.

AXE wins on **depth in gaming**: honest FPS labeling, per-tweak snapshot revert (restores prior state, not factory), hardware-aware gating, per-game power-plan profiles, and 100% offline single-file trust.

**Decision:** absorb only the WinUtil capabilities that *add to gaming*, keep AXE's unique advantages, and harden to production grade. **Explicitly skip MicroWin/ISO** (huge, high-risk, adds zero FPS).

## Approved decisions

1. **Architecture:** modular source → single-file build. Develop in `/src/*.ps1` (< 500 lines each); `build.ps1` concatenates in prefix order to `dist/AXE.ps1`. Mirrors how WinUtil compiles. The `.bat` launcher is unchanged (points at the built file).
2. **Order:** **Phase 0 (modular refactor + build pipeline) first**, then features. No feature work until the foundation exists and is test-gated.
3. **Debloat aggressiveness:** **safe + reversible only.** UWP (reinstallable from Store) + reversible registry toggles (Widgets, Copilot, Edge background/prelaunch). **No** Edge/OneDrive/Store removal (breaks WebView2/apps, hard to revert).
4. **Trust model:** stay **100% offline** (no remote script fetch). This is a deliberate advantage over WinUtil, which runs remote code each launch.

## Non-goals (out of scope)

- MicroWin / custom ISO creation.
- 300-app catalog (curate ~25-30 gaming apps instead).
- Killing Windows Update entirely (deferral only, for security honesty).
- Process-priority manipulation of game exe (anticheat risk).

---

## Phase 0 — Modular source + build pipeline (THIS spec's implementation target)

Everything else (F1-F3) is roadmapped below but planned/implemented in later specs.

### Module map

Current `AXE.ps1` (~2400 lines, region-organized) splits into ordered modules. **Concatenation order == current top-to-bottom order**, so the built file is byte-behaviorally equivalent. This is the safety invariant.

| File | Content (current regions) |
|---|---|
| `src/00-header.ps1` | `#Requires`, `param()`, banner/comment header |
| `src/05-core.ps1` | paths/store vars (R1), logging `Write-AXELog`+sink (R2), HW detect `Get-AXEHardware`/`Get-AXEHwCache` |
| `src/10-reg-helpers.ps1` | registry + snapshot (R3): `Get-RV/Set-RD/Set-RS/Del-RV`, svc helpers, `Push-RegBackup/Push-SvcBackup`, `Test-SnapEligible`, `Commit/Restore/Remove-TweakState`, state persistence |
| `src/15-startup.ps1` | startup backup/restore (R4): `Read-StartupBackup`, `Get-Autoruns`, `Disable-Autorun`, `Restore-Autorun`, `Repair-StartupBackup` |
| `src/20-tweaks.ps1` | `Add-Tweak` + the 73-tweak catalog + `Get-BlockReason`/gating |
| `src/22-catalogs.ps1` | debloat list + `Get-DebloatInstalled`, DNS profiles |
| `src/25-assistant.ps1` | assistant (R8): `Get-AXEState`, `Report-Cats`, `Get-AXERecommendations`, `Invoke-AXEAssistant` |
| `src/28-revert-export.ps1` | master-revert tail (R9), export/import (R10) |
| `src/30-profiles.ps1` | game profiles (R10b): data layer + power-plan + `Tick-GameProfiles` |
| `src/45-cli.ps1` | CLI dispatch (R11, ~L874-1019): `-SelfTest` (S1-S12b), `-List`, `-Export`, `-Import` + HW sync-load |
| `src/50-xaml.ps1` | GUI shell (R12, ~L1020-1476): STA guard, P/Invoke DPI, XAML string + styles/brushes, `XamlReader.Load`, named refs, DWM chrome |
| `src/52-gui-build.ps1` | GUI builders (~L1477-1639): UI helpers (12.6), catalog->categorias/iconos (12.7), tarjeta de tweak (12.8), vistas de tweaks (12.9), `Start-AXEJob` (12.9b) |
| `src/55-gui-actions.ps1` | Action views (~L1640-1841): `Build-ActionView` (LIMPIEZA/DEBLOAT/DNS/STARTUP/PERFILES/ASISTENTE) |
| `src/57-gui-handlers.ps1` | GUI wiring (~L1842-2177): nav (12.11), refresh (12.12), HW async (12.12b), buscador (12.13), botones principales Apply/Master/Preset/Read, `Test-RecentRestorePoint`, punto de restauracion, init (12.15) |
| `src/60-gui-selftest.ps1` | GUI regression harness (~L2178-2340): `AXE_GUITEST`/`AXE_GUISHOW` |
| `src/99-main.ps1` | `Add_Closed` cleanup + `$win.ShowDialog()` (~L2341-end) |

**Ordering constraint:** `45-cli.ps1` must precede `50-xaml.ps1` because `-SelfTest`/`-List`/`-Export`/`-Import` each `exit` before GUI construction — exactly as today. All non-GUI helpers/catalog must precede `45-cli`. The map preserves this.

Each file kept < 500 lines. **Audited against real line ranges (2026-07-12, file = 2347 lines):** the 73-tweak catalog + gating (`20-tweaks.ps1`, L307-624) is ~317 lines — **under the limit, no split needed** (the earlier split-risk note was wrong). The real risk was the GUI logic (originally one ~700-line `55-gui-logic`), now **split into `52-gui-build` / `55-gui-actions` / `57-gui-handlers`** (~162 / ~201 / ~336 lines). `50-xaml` at ~456 lines is the tightest; its 366-line XAML here-string is atomic and cannot be split further, so future GUI-shell growth spills into a new `51-styles.ps1`.

### `build.ps1`

Responsibilities:
1. Enumerate `src/*.ps1` sorted by filename (prefix ordering).
2. Concatenate into `dist/AXE.ps1` with a generated header comment (`# BUILT from /src - do not edit directly`, version, UTC timestamp) and per-module separators.
3. **Test gate (build fails on any failure):**
   - `pwsh -NoProfile -File dist/AXE.ps1 -SelfTest` -> assert exit 0, parse "Fallos : 0".
   - `powershell.exe -NoProfile -STA` with `AXE_GUITEST=1` -> assert exit 0, "RESULTADO: LAYOUT OK".
4. Optional `-Sign <certThumbprint>` -> `Set-AuthenticodeSignature` on `dist/AXE.ps1` (skipped if no cert; documented).
5. Emit a build summary (line count per module, total, test results).

`build.ps1` itself gets a smoke check runnable in CI later.

### Migration procedure (behavior-preserving)

1. Snapshot current `AXE.ps1` line ranges per region (map to modules).
2. Create `src/` files by **moving** contiguous blocks verbatim - no logic edits.
3. Run `build.ps1`; diff `dist/AXE.ps1` against original `AXE.ps1` - the only differences allowed are the injected build header + module separators (comments). Verify via a normalized diff (strip comment-only/whitespace lines).
4. Both test tiers must stay green (85 checks / LAYOUT OK).
5. Repoint `.bat` to `dist/AXE.ps1`; keep root `AXE.ps1` as a thin deprecation shim OR replace with built output (decide in plan).

### Testing strategy

- The existing `-SelfTest` (S1-S12b, 85 checks) and GUI harness are the regression oracle. Phase 0 adds **no new behavior**, so both must pass unchanged.
- Add one build-level test: `build.ps1` dry-run asserting the module set is complete (no orphan functions, no missing module).

---

## Roadmap (later specs, each test-gated)

### F1 - Gaming app installer (`src/32-apps.ps1`, `INSTALAR` tab)
- winget-native (present on Win11; choco optional fallback later). Offline-safe: only runs on user click.
- Curated catalog ~25-30: Steam, Epic, GOG Galaxy, EA app, Battle.net, Ubisoft Connect, Discord, MSI Afterburner, RTSS, HWiNFO, CapFrameX, OBS, DDU, NVCleanstall, 7-Zip, Everything, Notepad++, VLC, etc. Each an entry `@{Name; Id(winget); Cat}`.
- Checkbox list -> `Start-AXEJob` (async, reuses `$script:busy` mutex). `winget install --id X --silent --accept-package-agreements --accept-source-agreements`.
- Installed detection via `winget list --id`.
- Install-only v1 (no uninstall).
- Tests: catalog schema check (S13), view-wiring harness assertion.

### F2 - Aggressive-safe debloat (`src/35-debloat-plus.ps1`)
- Extend DEBLOAT with reversible-only extras: more UWP + registry toggles (Widgets, Copilot, Edge background/prelaunch, Xbox Game Bar tips). All via snapshot revert. No Edge/OneDrive/Store removal.
- Tests: each registry toggle round-trips through snapshot (reuse Restore-TweakState path).

### F3 - Windows Update control (`src/40-winupdate.ps1`, `UPDATES` tab)
- Deferral/pause (N days), disable auto-restart while in use, wide active hours, exclude drivers from WU. All reversible registry via snapshot. Never fully disables WU.
- Tests: data-layer S14 + harness assertion.

### Production hardening (cross-cutting)
- `VERSION` file + `CHANGELOG.md`; version stamped into build header + GUI banner.
- `build.ps1 -Sign` path documented.
- GitHub release flow (later): built `dist/AXE.ps1` + `AXE.bat` zipped, checksum published.

---

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| Refactor breaks behavior | Behavior-preserving move + normalized diff + both test tiers green |
| Catalog module > 500 lines | Split by category, order preserved |
| Build order regression (SelfTest runs before GUI defs) | Module map fixes CLI before GUI; verified by tests |
| winget absent (F1) | Detect `winget` presence, disable tab with hint if missing |
| Debloat breaks Windows | Scope limited to reversible/UWP; snapshot revert on all registry |

## Success criteria (Phase 0)

- `dist/AXE.ps1` built from `/src`, all modules < 500 lines.
- `-SelfTest` -> 0 fallos, exit 0. GUI harness -> LAYOUT OK, exit 0.
- Normalized diff vs current `AXE.ps1` shows only comment/separator differences.
- `.bat` launches the built file; GUI behaves identically.
