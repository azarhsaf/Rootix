# Rootix – Offline Root CA (Pure Bash)

Rootix is an **offline Root CA automation tool** implemented in pure Bash for Rocky Linux 9 / RHEL 9 / Alma / CentOS-like systems.

## Supported key storage modes
At ceremony/ops runtime, the operator selects one mode:

1. **Luna USB HSM mode** (production): private Root key remains non-exportable in HSM.
2. **Software Key mode** (lab/testing): private Root key is generated locally and protected with strict file permissions.

> Software mode is for testing/lab only and should not be used for production roots.

## Scope
This tool is intentionally minimal for offline Root CA responsibilities:
- Root key ceremony
- Root self-signed certificate generation
- Root CRL generation
- Issuing CA CSR signing
- Export/integrity packaging for offline transfer

## Entrypoint
```bash
./offline-rootca.sh ceremony [--dry-run] [--key-mode luna|software]
./offline-rootca.sh ops [--dry-run] [--key-mode luna|software]
```

You can force mode non-interactively with `--key-mode` to avoid interactive selection prompts.

Argument notes:
- `ceremony`/`ops` and flags can be provided in any order.
- Copy/paste literals like `[--dry-run]` and `[--key-mode]` are accepted for convenience.

Examples:
```bash
# explicit software-mode dry-run (mode token first)
./offline-rootca.sh ceremony --dry-run --key-mode software

# explicit software-mode dry-run (options first; also supported)
./offline-rootca.sh --key-mode software --dry-run ceremony

# explicit luna-mode ops dry-run
./offline-rootca.sh ops --dry-run --key-mode luna
```

## Offline package requirements
No online repositories are used by this tool. Install dependencies from local RPM media.

### Required base packages
- bash
- openssl
- coreutils
- findutils
- iproute
- tar
- sed, awk, grep

### Optional UI package
- whiptail (or dialog)

### Luna mode additional requirements
- Luna Client (`lunacm`)
- Luna PKCS#11 library (`libCryptoki2.so`)
- OpenSSL PKCS#11 stack:
  - OpenSSL 3.x: `pkcs11-provider` / `pkcs11prov`
  - OpenSSL 1.1.1: `libp11` / `openssl-pkcs11`

Offline install example:
```bash
rpm -Uvh /mnt/offline-rpms/*.rpm
```

If required components are missing, Rootix prints clear offline remediation guidance.

## Security behavior
- Uses `set -euo pipefail`.
- PIN input is hidden (`read -s`/whiptail passwordbox) and never persisted.
- Logs are sanitized and redact sensitive tokens.
- In software mode, private key is written to:
  - `/var/offline-rootca/outputs/<ORG>/<STAMP>/configs/rootca.key`
  - permissions: `600`, owner `root:root`.

## Profiles (authoritative policy)
These templates control extensions/validity/policy behavior:
- `profiles/defaults.env`
- `profiles/root_ca.cnf`
- `profiles/issuing_ca.cnf`

## Output structure
Per run output path:
`/var/offline-rootca/outputs/<ORG>/<YYYYMMDD-HHMMSS>/`

Artifacts:
- `certs/`, `crl/`, `csr/`, `configs/`, `profiles_used/`, `logs/`, `reports/`, `manifests/`, `state/`
- `manifests/SHA256SUMS`
- `manifests/manifest.json`
- `reports/ceremony_minutes.md`
- `reports/final_summary.txt`

Minutes and summary include the selected key storage mode, including an explicit indicator when software mode was used.

## Luna command uncertainty handling
Where vendor command syntax can differ by firmware/policy, Rootix uses guided placeholder steps and asks operator confirmation after manual execution. It does not hallucinate exact Luna command details.
