# Offline Root CA Automation (Pure Bash)

Production-oriented **offline Root CA** utility for Rocky Linux 9 / RHEL 9 / Alma / CentOS-like systems.

## Scope
This project automates only Root CA duties:
- Root key ceremony (HSM-backed, non-exportable key)
- Root self-signed certificate generation
- Root CRL generation
- Issuing CA CSR signing
- Minimal ops workflows and auditable output packaging

## Entrypoint
```bash
./offline-rootca.sh ceremony [--dry-run]
./offline-rootca.sh ops [--dry-run]
```

## Offline dependency installation
Do not use internet repositories. Gather RPMs on a trusted staging machine, transfer via approved media, then install locally.

### Required base tools
- bash
- openssl
- coreutils (sha256sum, stat)
- util-linux
- tar
- findutils
- sed, awk, grep
- lunacm (Luna Client)

### Optional UX
- whiptail (or dialog)

### PKCS#11 requirements
Tool auto-detects OpenSSL version and supports:

- **OpenSSL 3.x preferred:** PKCS#11 provider (e.g., `pkcs11-provider`, `pkcs11prov`)
- **OpenSSL 1.1.1:** PKCS#11 engine (`openssl-pkcs11`, `libp11`)

Offline installation example:
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
