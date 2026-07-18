# AXE — Code Signing (§8.3)

AXE writes to the Registry, BCD, Defender and ProcessMitigation. An **unsigned**
script trips SmartScreen and is a non-starter for any managed/enterprise deployment.
Signing is the first hard blocker between "works on my PC" and production-grade.

## What gets signed — and what NEVER does

- **Sign only `dist/AXE.ps1`** — our own build artifact.
- **NEVER sign third-party binaries** bundled or referenced (`winutil.exe`, ISLC,
  Autoruns, OpenHardwareMonitor, DnsJumper). We didn't author them; re-signing violates
  their redistribution terms and destroys their original signature. Ship them as-is.

`scripts/Sign-AXE.ps1` enforces this: it refuses any path whose leaf isn't `AXE.ps1`
and any `.exe/.dll/.sys/.msi`.

## Certificate options

| Option | Trust | Notes |
|--------|-------|-------|
| **OV code-signing cert** | SmartScreen reputation builds over time | Cheapest real option |
| **EV code-signing cert** | Immediate SmartScreen trust | HSM/token-backed, pricier |
| **Azure Trusted Signing** | Microsoft-managed, immediate trust | Subscription; cert never leaves Azure |
| Self-signed | None (dev only) | `-AllowSelfSigned`; never for release |

## Usage

```powershell
# cert from the certificate store
./AXE/scripts/Sign-AXE.ps1 -Thumbprint <THUMBPRINT>

# or a .pfx
./AXE/scripts/Sign-AXE.ps1 -PfxPath .\axe-cs.pfx -PfxPassword (Read-Host -AsSecureString)

# preview without writing
./AXE/scripts/Sign-AXE.ps1 -Thumbprint <THUMBPRINT> -WhatIf
```

The script:
1. Resolves and validates the target is `dist/AXE.ps1` (own code only).
2. Loads the cert; rejects self-signed unless `-AllowSelfSigned`; warns if it expires <30 days.
3. `Set-AuthenticodeSignature -HashAlgorithm SHA256 -TimestampServer http://timestamp.digicert.com`.
   **Timestamping is mandatory** so the signature stays valid after the cert expires.
4. Prints the signed file's **SHA256** for the release/changelog.

## Release checklist

1. `./AXE/build.ps1` (green SelfTest gate).
2. `./AXE/scripts/Sign-AXE.ps1 -Thumbprint <THUMBPRINT>`.
3. Verify: `Get-AuthenticodeSignature AXE/dist/AXE.ps1` → `Valid` + a timestamp.
4. Publish `dist/AXE.ps1` + its SHA256 + changelog.

## Status

`Sign-AXE.ps1` is ready; **it needs a real code-signing certificate** (OV/EV or Azure
Trusted Signing) that the maintainer must provide. No certificate is bundled — signing
is a maintainer/release step, not part of CI (CI would need the private key as a secret;
sign in a protected release workflow only).
