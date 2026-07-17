# AXE Ecosystem Gating & Product-Gap Closure — Implementation Plan

> **For agentic workers:** each phase is an independent, testable deliverable. Verification in this repo is the built-in `-SelfTest` gate (run by `build.ps1`) plus `Invoke-ScriptAnalyzer -Severity Error`; full Pester arrives in Phase 6. Steps use checkbox syntax.

**Goal:** Close the concrete deliverables from the AXE system prompt that are not yet built (§3, §4.1, §7, §8), starting with the highest-value one: extended ecosystem gating.

**Architecture:** Work WITH the mature modular build (`src/NN-*.ps1` → `dist/AXE.ps1`). Extend existing detection/gating, do not reimplement. Registry writes stay behind the `Set-RD/Set-RS/Del-RV` primitives (snapshot-revert). Catalog is the single source of truth.

**Tech Stack:** PowerShell 5.1/7.x, WMI/CIM, Defender cmdlets, GitHub Actions, Pester, PSScriptAnalyzer.

## Global Constraints (verbatim from spec)
- Admin only in `99-main.ps1`; modules carry NO `#Requires -RunAsAdministrator` (breaks dot-source build).
- `Get-AXEHardware` runs inside a fresh runspace (`57-gui-handlers.ps1:105`) — it MUST stay self-contained (CIM/`$env`/registry only, no AXE helpers).
- Every Tier 0/1 tweak needs a `Source` URL. Placebo/unverified → not Tier 1.
- Primitives only for registry (`Set-RD`/`Set-RS`/`Del-RV`/`Set-SvcStart`); never `Set-ItemProperty`.
- Catalog mass-critical guard: `$script:CAT.Count -lt 10` aborts.
- Verify before "done": ScriptAnalyzer Error-clean + `-SelfTest` 0 fallos.

---

## Phase 1 — §3.2 Extended ecosystem gating (FIRST / best option)

**Why first:** unblocks MEMORIA tweaks (currently ungated → anti-pattern #23) and fixes the `gpu_hags`/EXTREMO gaps. Pure catalog+gating, no UI, lowest risk, highest correctness payoff.

**Files:**
- Modify: `src/05-core.ps1` — extend `Get-AXEHardware` output object with env fields.
- Modify: `src/20-tweaks.ps1` — extend `Get-BlockReason`; add `Requires` to 7 tweaks.
- Modify: `src/45-cli.ps1` — add SelfTest coherence check (S11).

**New `Get-AXEHardware` fields (all self-contained):**
- `CpuArch`  = `$env:PROCESSOR_ARCHITECTURE` (AMD64/ARM64/x86)
- `CpuVendor`= `$cpu.Manufacturer` (GenuineIntel/AuthenticAMD/…)
- `HasDefender` / `IsTamperProtected` = one `Get-MpComputerStatus` in try/catch, both derived
- `IsSMode` = reg `HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy` `SkuPolicyRequired`==1, try/catch → default `$false`
- `SupportsHAGS` = heuristic: `HwSchMode` value present under `GraphicsDrivers` (OS exposes toggle only on WDDM>=2.7-capable GPUs); conservative (absent→hidden)

**New `Get-BlockReason` keys:** `MinRam`, `NotLaptop`, `WinBuild`, `CpuArch`, `CpuVendor`, `HAGS`, `TamperOff`, `Defender`, `NotSMode` — each returns a legible reason string.

**Tweak wiring:**
- `gpu_hags` → `Requires=@{HAGS=$true}`
- `mem_pagingexec` → `Requires=@{MinRam=16}`
- `mem_compression` → `Requires=@{MinRam=16}`
- `mem_ntfsmem` → `Requires=@{MinRam=12}`
- `ext_vbs`, `ext_cfg`, `ext_aslr` → `Requires=@{TamperOff=$true}`

- [ ] Extend `Get-AXEHardware` with the 6 env fields (single `Get-MpComputerStatus` call).
- [ ] Extend `Get-BlockReason` with the 9 new keys.
- [ ] Add `Requires` to the 7 tweaks above.
- [ ] Add SelfTest S11: `HAGS=$true` only on `Cat='GPU'`; `MinRam` positive int; `CpuArch`/`CpuVendor` arrays.
- [ ] `build.ps1` → expect `RESULTADO: OK (0 fallos)`.
- [ ] Commit `fix(gating): extend ecosystem Requires keys + gate memory/hags/extremo`.

## Phase 2 — §3.1/§3.3 Env banner
Add `IsSSD` (OS disk MediaType) + `Test-AXEEnvApplies($tw)` = `-not (Get-BlockReason $tw)`; consume it in a banner string (GUI header + `45-cli` `-List`) showing detected ecosystem + `N aplicables / M ocultos`.

## Phase 3 — §8.2 CI (`.github/workflows/ci.yml`)
windows-latest: ScriptAnalyzer Error gate → build → `-SelfTest` schema (Source on Tier0/1, Requires coherence) → Pester `-ExcludeTag integration` → artifact. Blocks merge on red.

## Phase 4 — §4.1 Preflight (`Assert-AXEVss`, `Get-AXETamperState`)
VSS/swprv demand-startable + start; tamper state routes Defender-registry tweaks to `*-MpPreference`.

## Phase 5 — §7 Defender module (`23-defender.ps1`)
`Add-AXEDefenderExclusion` (game `.exe` + `steamapps\common` only, `Resolve-Path` literal, modal, `Requires=@{Defender=$true}`), `Set-AXEDefenderCpuLimit`, `Set-AXEScheduledScanIdle`. Reversible via `Remove-MpPreference`.

## Phase 6 — §8.1/§8.3 Pester + signing
`AXE/tests/*.Tests.ps1` unit (Mock primitives; idempotence, snapshot-revert, schema, `Test-AXEEnvApplies` ecosystem matrices), integration dir (not CI). `docs/SIGNING.md` + `scripts/Sign-AXE.ps1` (sign `dist/AXE.ps1` only, timestamp, SHA256).

---

## Self-Review
- Spec coverage: §3.1/§3.2/§3.3 (P1-P2), §4.1 (P4), §7 (P5), §8.1/§8.2/§8.3 (P3,P6). §4.2 restore-point create+verify already partially in `New-AXERestorePoint` — audit in P4. §6 catalog already ~complete (75 tweaks).
- `SupportsHAGS` is an explicit heuristic (documented), honoring "disponibilidad REAL, no asumida por GPU" conservatively (absent→hidden, never false-positive apply).
- No placeholders: every field/key/wiring above is concrete.
