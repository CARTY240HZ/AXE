# AXE v6 Phase 0 — Modular Source + Build Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert the working 2347-line `AXE.ps1` into `/src/*.ps1` modules (< 500 lines each) built into a single `dist/AXE.ps1` by `build.ps1`, with a test gate — without changing any behavior.

**Architecture:** Incremental *carve* refactor. Copy the whole script into one monolith module, stand up the build pipeline, then move one contiguous block at a time out of the monolith into a properly-named module. After every move: rebuild, prove a normalized diff against the committed original is clean, and run both test tiers. The tests + diff are the safety oracle — this phase adds zero new behavior.

**Tech Stack:** Windows PowerShell 5.1 (GUI/WPF, `powershell.exe -STA`), PowerShell 7 (`pwsh`, headless SelfTest), Git Bash for shell steps.

## Global Constraints

- Each `src/*.ps1` module MUST be < 500 lines.
- Concatenation order = filename sort order = current top-to-bottom order. `45-cli.ps1` MUST sort before any `50+`/GUI module (CLI `-SelfTest`/`-List`/`-Export`/`-Import` each `exit` before GUI construction).
- Behavior-preserving: `dist/AXE.ps1` must differ from committed `AXE.ps1` ONLY in full-line comments / blank lines (build header + module separators). Verified by normalized diff every task.
- Regression oracle (must stay green every task): `pwsh -NoProfile -File dist/AXE.ps1 -SelfTest` → "Fallos : 0", exit 0; GUI harness (`AXE_GUITEST=1`, `powershell.exe -STA`) → "RESULTADO: LAYOUT OK", exit 0.
- No `Co-Authored-By` trailer (repo has no `attribution.commit` set).
- Repo root for git = the `AXE/` folder; paths below are relative to it. Branch: `axe`.

---

## File Structure

Created by this phase (all under `AXE/`):

- `build.ps1` — concatenator + test gate.
- `VERSION` — single line, e.g. `6.0.0-dev`.
- `src/00-header.ps1` … `src/99-main.ps1` — the modules (table below + carve tasks).
- `dist/AXE.ps1` — build output (git-tracked so users can run without building).
- `src/zz-monolith.ps1` — TEMPORARY; holds not-yet-carved tail; deleted in Task 17.

Modified:
- `AXE.bat` — repoint the two `AXE.ps1` references to `dist\AXE.ps1`.
- `AXE.ps1` (root) — removed in Task 18 once `dist/AXE.ps1` is the artifact.

Module map with audited source line ranges in the current `AXE.ps1`:

| Module | Source lines | Content |
|---|---|---|
| `src/00-header.ps1` | 1-27 | `#Requires`, `param()`, banner |
| `src/05-core.ps1` | 28-87 | R1 paths+logging, R2 hardware detect |
| `src/10-reg-helpers.ps1` | 88-216 | R3 registry/service/snapshot helpers |
| `src/15-startup.ps1` | 217-305 | R4 startup backup/restore |
| `src/20-tweaks.ps1` | 306-624 | R5 catalog (73 tweaks) + R6 gating |
| `src/22-catalogs.ps1` | 625-668 | R7 debloat list + DNS profiles |
| `src/25-assistant.ps1` | 669-734 | R8 local assistant |
| `src/28-revert-export.ps1` | 735-786 | R9 master-revert tail + R10 export/import |
| `src/30-profiles.ps1` | 787-872 | R10b game profiles |
| `src/45-cli.ps1` | 873-1019 | R11 CLI dispatch (SelfTest/List/Export/Import) |
| `src/50-xaml.ps1` | 1020-1476 | R12 shell: STA guard, P/Invoke, XAML+styles, Load, refs, DWM |
| `src/52-gui-build.ps1` | 1477-1639 | 12.6-12.9b builders + Start-AXEJob |
| `src/55-gui-actions.ps1` | 1640-1841 | 12.10 Build-ActionView (incl PERFILES) |
| `src/57-gui-handlers.ps1` | 1842-2177 | 12.11-12.15 nav/refresh/HW/search/buttons/restore-point/init |
| `src/60-gui-selftest.ps1` | 2178-2340 | GUI regression harness |
| `src/99-main.ps1` | 2341-end | Add_Closed + ShowDialog |

> Line ranges are the audit snapshot. Carving removes from the top, so a block's *content* never shifts relative to the monolith's current top — but the executor MUST Read `zz-monolith.ps1` before each carve and match on the region banner (not absolute line numbers) to find the boundary.

---

## Canonical Carve Procedure (used by Tasks 3-16)

Each carve task moves the **current top block** of `src/zz-monolith.ps1` into a new module. Steps are identical except for `<NN-name>` and the block boundary. Perform exactly:

1. **Read** `src/zz-monolith.ps1` from its top to confirm the block's start/end (match on the region banner in the boundary column).
2. **Create** `src/<NN-name>.ps1` with the exact block text (verbatim, no edits).
3. **Edit** `src/zz-monolith.ps1`: delete that same block from the top.
4. **Rebuild:** `pwsh -NoProfile -File build.ps1`
   Expected: per-module line counts then `GATE OK: SelfTest + GUI harness verdes.`
5. **Normalized diff** (behavior-preserving proof):
   ```bash
   cd "AXE"
   strip(){ grep -vE '^[[:space:]]*#' "$1" | grep -vE '^[[:space:]]*$'; }
   git show HEAD:AXE.ps1 > /tmp/axe_orig.ps1
   diff <(strip /tmp/axe_orig.ps1) <(strip dist/AXE.ps1) && echo "NORMALIZED DIFF CLEAN"
   ```
   Expected: `NORMALIZED DIFF CLEAN` (only comment/blank differences).
6. **Verify module size:** `wc -l src/<NN-name>.ps1` → must be < 500.
7. **Commit:** `git add src/<NN-name>.ps1 src/zz-monolith.ps1 dist/AXE.ps1 && git commit -m "refactor(axe): carve <NN-name> module"`

If step 4 fails (gate red) or step 5 shows a real code diff, the carve split a syntactic unit — revert the module create + monolith edit, move the boundary to a complete unit, retry.

---

## Task 1: Baseline — stand up build.ps1 + monolith, prove pipeline

**Files:**
- Create: `AXE/VERSION`
- Create: `AXE/build.ps1`
- Create: `AXE/src/zz-monolith.ps1` (verbatim copy of `AXE/AXE.ps1`)

**Interfaces:**
- Produces: `dist/AXE.ps1` build artifact; `build.ps1` with params `[-NoTest] [-Sign <thumbprint>]`.

- [ ] **Step 1: Create VERSION**

```
6.0.0-dev
```

- [ ] **Step 2: Create build.ps1**

```powershell
#Requires -Version 5.1
[CmdletBinding()]
param([switch]$NoTest,[string]$Sign)
$ErrorActionPreference='Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$src  = Join-Path $root 'src'
$dist = Join-Path $root 'dist'
if(-not(Test-Path $dist)){ New-Item -ItemType Directory -Path $dist | Out-Null }
$out  = Join-Path $dist 'AXE.ps1'
$modules = Get-ChildItem -Path $src -Filter '*.ps1' | Sort-Object Name
if($modules.Count -eq 0){ throw 'No hay modulos en /src' }
$ver = (Get-Content (Join-Path $root 'VERSION') -Raw -EA SilentlyContinue); if($ver){ $ver=$ver.Trim() } else { $ver='6.0.0-dev' }
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("# ================================================================")
[void]$sb.AppendLine("# AXE $ver - BUILT from /src by build.ps1 - DO NOT EDIT DIRECTLY")
[void]$sb.AppendLine("# Build UTC: $((Get-Date).ToUniversalTime().ToString('u'))")
[void]$sb.AppendLine("# Modules: $($modules.Name -join ', ')")
[void]$sb.AppendLine("# ================================================================")
foreach($m in $modules){
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("# >>>>> MODULE: $($m.Name) >>>>>")
    [void]$sb.Append((Get-Content $m.FullName -Raw))
    [void]$sb.AppendLine("")
}
Set-Content -Path $out -Value $sb.ToString() -Encoding UTF8
Write-Host ("BUILT: {0} ({1} lineas, {2} modulos)" -f $out,(Get-Content $out).Count,$modules.Count)
foreach($m in $modules){ Write-Host ("  {0,-28} {1,5} lineas" -f $m.Name,(Get-Content $m.FullName).Count) }
if($Sign){ Set-AuthenticodeSignature -FilePath $out -Certificate (Get-Item "Cert:\CurrentUser\My\$Sign") | Out-Null; Write-Host "Firmado ($Sign)" }
if($NoTest){ return }
Write-Host "`n=== TEST GATE ==="
$st = & pwsh -NoProfile -File $out -SelfTest 2>&1
$stExit = $LASTEXITCODE
$st | Select-String 'Catalogo|Checks|Fallos|RESULTADO' | ForEach-Object { Write-Host "  $_" }
if($stExit -ne 0 -or ($st -notmatch 'Fallos\s*:\s*0')){ throw "SelfTest FALLO (exit $stExit)" }
$env:AXE_GUITEST='1'; $env:AXE_GUITEST_PNG_DIR=$dist
$gt = & powershell.exe -NoProfile -STA -File $out 2>&1
$gtExit = $LASTEXITCODE
Remove-Item Env:\AXE_GUITEST -EA SilentlyContinue
if($gtExit -ne 0 -or ($gt -notmatch 'LAYOUT OK')){ $gt | Select-String 'FALLO|EXCEP' | ForEach-Object { Write-Host "  $_" }; throw "GUI harness FALLO (exit $gtExit)" }
Write-Host 'GATE OK: SelfTest + GUI harness verdes.'
```

- [ ] **Step 3: Copy the whole current script into the monolith module**

```bash
cd "AXE"
mkdir -p src
cp AXE.ps1 src/zz-monolith.ps1
```

- [ ] **Step 4: Build and run the gate**

Run: `pwsh -NoProfile -File build.ps1`
Expected: line-count summary then `GATE OK: SelfTest + GUI harness verdes.` (SelfTest shows `Fallos : 0`; harness shows `LAYOUT OK`).

- [ ] **Step 5: Prove normalized diff clean**

```bash
cd "AXE"
strip(){ grep -vE '^[[:space:]]*#' "$1" | grep -vE '^[[:space:]]*$'; }
git show HEAD:AXE.ps1 > /tmp/axe_orig.ps1
diff <(strip /tmp/axe_orig.ps1) <(strip dist/AXE.ps1) && echo "NORMALIZED DIFF CLEAN"
```
Expected: `NORMALIZED DIFF CLEAN`.

- [ ] **Step 6: Commit**

```bash
cd "AXE"
git add VERSION build.ps1 src/zz-monolith.ps1 dist/AXE.ps1
git commit -m "build(axe): add build.ps1 + monolith baseline (behavior-preserving)"
```

---

## Task 2: Prove the gate actually guards

**Files:** none (verification only)

- [ ] **Step 1: Inject a fault**

```bash
cd "AXE"
printf '\n throw "INTENTIONAL" \n' >> src/zz-monolith.ps1
```

- [ ] **Step 2: Build expecting failure**

Run: `pwsh -NoProfile -File build.ps1`
Expected: throws `SelfTest FALLO` (non-zero exit) — proves the gate guards.

- [ ] **Step 3: Restore and rebuild green**

```bash
cd "AXE"
git checkout -- src/zz-monolith.ps1
pwsh -NoProfile -File build.ps1
```
Expected: `GATE OK`.

- [ ] **Step 4:** No commit (tree clean after checkout).

---

## Tasks 3-16: Carve modules (apply the Canonical Carve Procedure)

Each task = one row, executed via the **Canonical Carve Procedure** above. Read the monolith top before each to confirm the boundary (banner match). Order is mandatory (top-of-file first) so filename sort keeps concatenation order identical.

| Task | Module (`src/`) | Block | Boundary (start banner → end just before) |
|---|---|---|---|
| 3  | `00-header.ps1` | header | `#Requires -Version 5.1` → `# REGION 1` banner |
| 4  | `05-core.ps1` | R1+R2 | `# REGION 1` → `# REGION 3` banner |
| 5  | `10-reg-helpers.ps1` | R3 | `# REGION 3` → `# REGION 4` banner |
| 6  | `15-startup.ps1` | R4 | `# REGION 4` → `# REGION 5` banner |
| 7  | `20-tweaks.ps1` | R5+R6 | `# REGION 5` → `# REGION 7` banner |
| 8  | `22-catalogs.ps1` | R7 | `# REGION 7` → `# REGION 8` banner |
| 9  | `25-assistant.ps1` | R8 | `# REGION 8` → `# REGION 9` banner |
| 10 | `28-revert-export.ps1` | R9+R10 | `# REGION 9` → `# REGION 10b` banner |
| 11 | `30-profiles.ps1` | R10b | `# REGION 10b` → `# REGION 11` banner |
| 12 | `45-cli.ps1` | R11 | `# REGION 11` → `# REGION 12` banner |
| 13 | `50-xaml.ps1` | R12 shell | `# REGION 12` → `# ---- 12.6 helpers UI ----` |
| 14 | `52-gui-build.ps1` | 12.6-12.9b | `# ---- 12.6 helpers UI ----` → `# ---- 12.10 vistas de accion ----` |
| 15 | `55-gui-actions.ps1` | 12.10 | `# ---- 12.10 vistas de accion ----` → `# ---- 12.11 navegacion ----` |
| 16 | `57-gui-handlers.ps1` | 12.11-12.15 | `# ---- 12.11 navegacion ----` → the GUITEST harness block (`# ---- 12.16 GUITEST ...` / the `if($env:AXE_GUITEST -eq '1'){` assertion section) |

After Task 16, `zz-monolith.ps1` holds only the GUI harness + `Add_Closed`/`ShowDialog` tail.

---

## Task 17: Final split of the tail + drop monolith

**Files:**
- Create: `src/60-gui-selftest.ps1` (harness block)
- Create: `src/99-main.ps1` (Add_Closed + ShowDialog tail)
- Delete: `src/zz-monolith.ps1`

- [ ] **Step 1:** Read `src/zz-monolith.ps1` (now small). Identify the GUITEST harness block (up to but excluding the `# H4: al cerrar...` comment / `$win.Add_Closed({` line) vs the final tail (`$win.Add_Closed({...})` through `[void]$win.ShowDialog()`).

- [ ] **Step 2:** Create `src/60-gui-selftest.ps1` with the harness block.

- [ ] **Step 3:** Create `src/99-main.ps1` with the `Add_Closed` + `ShowDialog` tail.

- [ ] **Step 4: Delete monolith**

```bash
cd "AXE"
rm src/zz-monolith.ps1
```

- [ ] **Step 5: Build + gate**

Run: `pwsh -NoProfile -File build.ps1`
Expected: `GATE OK`; no `zz-monolith` in Modules list.

- [ ] **Step 6: Normalized diff clean** (Canonical step 5 command). Expected `NORMALIZED DIFF CLEAN`.

- [ ] **Step 7: All modules < 500 lines**

```bash
cd "AXE"
for f in src/*.ps1; do echo "$(wc -l < "$f")  $f"; done | sort -rn | head -5
```
Expected: top file < 500.

- [ ] **Step 8: Commit**

```bash
cd "AXE"
git add src/60-gui-selftest.ps1 src/99-main.ps1 dist/AXE.ps1
git rm src/zz-monolith.ps1
git commit -m "refactor(axe): carve final GUI harness + main; drop monolith"
```

---

## Task 18: Repoint launcher, retire root AXE.ps1

**Files:**
- Modify: `AXE.bat`
- Delete: `AXE.ps1` (root)

- [ ] **Step 1:** Edit `AXE.bat` line 22: `'%~dp0AXE.ps1'` → `'%~dp0dist\AXE.ps1'`.
- [ ] **Step 2:** Edit `AXE.bat` lines 27 and 29: `"%~dp0AXE.ps1"` → `"%~dp0dist\AXE.ps1"` (both branches).
- [ ] **Step 3: Remove root source**

```bash
cd "AXE"
git rm AXE.ps1
```

- [ ] **Step 4: Rebuild (proves /src is self-sufficient)**

Run: `pwsh -NoProfile -File build.ps1`
Expected: `GATE OK`.

- [ ] **Step 5: Final diff vs the last revision that had the root file**

```bash
cd "AXE"
strip(){ grep -vE '^[[:space:]]*#' "$1" | grep -vE '^[[:space:]]*$'; }
git show HEAD:AXE.ps1 2>/dev/null > /tmp/axe_orig.ps1 || git show HEAD~1:AXE.ps1 > /tmp/axe_orig.ps1
diff <(strip /tmp/axe_orig.ps1) <(strip dist/AXE.ps1) && echo "NORMALIZED DIFF CLEAN"
```
Expected: `NORMALIZED DIFF CLEAN`.

- [ ] **Step 6: Commit**

```bash
cd "AXE"
git add AXE.bat dist/AXE.ps1
git rm AXE.ps1
git commit -m "build(axe): launcher -> dist/AXE.ps1; source of truth is /src"
```

---

## Task 19: Document the build

**Files:**
- Create: `AXE/docs/BUILD.md`

- [ ] **Step 1: Create `AXE/docs/BUILD.md`**

```markdown
# Building AXE

Source lives in `/src/*.ps1` (each < 500 lines). Never edit `dist/AXE.ps1` directly.

## Build
`pwsh -NoProfile -File build.ps1`

Concatenates `src/*.ps1` (filename order) into `dist/AXE.ps1`, then runs the gate:
- `-SelfTest` (85 checks, 0 fallos)
- GUI harness (`AXE_GUITEST=1`, `powershell.exe -STA`, "LAYOUT OK")

Build fails if either tier is red. `-NoTest` skips the gate. `-Sign <thumbprint>` Authenticode-signs the output.

## Run
`AXE.bat` (self-elevates, launches `dist\AXE.ps1`).
```

- [ ] **Step 2: Commit**

```bash
cd "AXE"
git add docs/BUILD.md
git commit -m "docs(axe): build instructions"
```

---

## Self-Review

- **Spec coverage:** module map (spec §Phase 0) → Tasks 3-17; `build.ps1` (+gate, +sign) → Task 1; behavior-preserving proof → normalized diff every carve; `.bat` repoint + root-file decision (replace, not shim) → Task 18; "< 500 lines" → per-carve + Task 17 step 7; testing strategy (existing tiers as oracle) → gate in build.ps1; build-level completeness check → Task 2 (gate-guards proof) + Task 17 step 7. All covered.
- **Placeholder scan:** none — `build.ps1` and `BUILD.md` shown in full; each carve names exact file + boundary markers + full command set via the Canonical Procedure.
- **Type consistency:** `build.ps1` params (`-NoTest`,`-Sign`) used consistently; module filenames match the map and the CLI-before-GUI ordering constraint; `zz-monolith.ps1` sorts last throughout and is deleted in Task 17.
- **Known deviation:** carve Tasks 3-16 reference one shared Canonical Procedure rather than repeating identical shell blocks 14×; each row still supplies its exact filename + boundary. A deliberate DRY call by the orchestration lead for a purely mechanical move — not a hidden placeholder.
