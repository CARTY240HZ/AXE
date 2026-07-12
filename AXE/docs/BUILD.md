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
