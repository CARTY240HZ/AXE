# Security Policy

## Scope

This repository contains AXE, a Windows optimizer that can run with elevated privileges and can modify system configuration. Security reports are therefore treated as high priority.

The main security properties expected from AXE are:

- Updates must not replace the installed script unless the downloaded asset passes all verification checks implemented by the updater.
- The updater is restricted to the official `CARTY240HZ/AXE` repository and an allow-list of GitHub asset hosts.
- Checksums provide integrity checking; build provenance attestations provide release provenance; Authenticode, when present, provides Windows-signable publisher identity.
- High-impact operations should be reversible where technically possible, and failures should degrade safely rather than silently claiming success.
- The WebView2 bridge must expose only explicitly registered commands and must not become an arbitrary PowerShell execution surface.

## Reporting a vulnerability

Please do not open a public issue for an undisclosed security vulnerability.

Until a dedicated private security contact is configured for the project, use GitHub's private vulnerability reporting feature for this repository when available. Include enough information to reproduce the issue, the affected file/function, the impact, and any prerequisites.

Do not include passwords, private keys, certificates, tokens, or other secrets in the report.

## What to include

A useful report should contain:

1. A concise description of the security boundary that is bypassed.
2. Reproduction steps, including the AXE version/commit and Windows version where relevant.
3. Expected versus actual behavior.
4. Whether the issue requires administrator privileges, local access, network access, or control of a release asset.
5. A proposed mitigation only when you already have one; a complete patch is not required.

## Release and update trust model

AXE deliberately treats these mechanisms as different properties:

- `SHA256SUMS`: detects altered or corrupted bytes, but is not an independent publisher identity because it is distributed with the release.
- GitHub build provenance attestation: binds published bytes to the repository, commit, and workflow.
- Authenticode: allows Windows to validate a signed publisher certificate when releases are signed.

A release without a valid Authenticode signature must not be silently treated as trusted by the automatic updater.

## Supported security posture

AXE is not intended to disable Windows security controls merely to obtain benchmark numbers. Changes that weaken Defender, exploit mitigations, virtualization security, or other platform protections must remain explicitly gated and documented.
