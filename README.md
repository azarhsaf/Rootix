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
./offline-rootca.sh ceremony [--dry-run]
./offline-rootca.sh ops [--dry-run]
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

If provider/engine is absent, script exits with explicit offline remediation instructions.

## Security behaviors
- No secret persistence: all PINs entered with hidden prompt (`read -s`/password dialog).
- Script only logs sanitized operations.
- Designed for air-gapped operation.
- Root private key remains on Luna HSM (operator performs/validates vendor-specific steps where syntax differs).

## Profiles
Edit these files (version-controlled templates) rather than changing script logic:
- `profiles/defaults.env`
- `profiles/root_ca.cnf`
- `profiles/issuing_ca.cnf`

## Output layout
Per run:
`/var/offline-rootca/outputs/<ORG>/<YYYYMMDD-HHMMSS>/`

Includes:
- `certs/`, `crl/`, `csr/`, `configs/`, `profiles_used/`, `logs/`, `reports/`, `manifests/`, `state/`
- `SHA256SUMS`
- `manifest.json`
- `ceremony_minutes.md`
- `final_summary.txt`

## Notes on Luna commands and M-of-N
Luna firmware/policies vary. Where exact commands are uncertain, script provides guided placeholders and asks operator confirmation after manual execution. Post-conditions are verified via status/listing checks and expected key/cert outputs.
