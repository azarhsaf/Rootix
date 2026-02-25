#!/usr/bin/env bash
set -euo pipefail

AUDIT_LOG=""

init_state_file() {
  local state_file="$1" dry_run="$2"
  if (( dry_run == 0 )); then
    mkdir -p "$(dirname "$state_file")"
    [[ -f "$state_file" ]] || printf '# step flags\n' > "$state_file"
  fi
}

record_step() {
  local key="$1" value="$2" state_file="$3" dry_run="$4"
  if (( dry_run == 1 )); then
    info "[dry-run] State update: ${key}=${value}"
    return
  fi
  if grep -q "^${key}=" "$state_file"; then
    sed -i "s/^${key}=.*/${key}=${value}/" "$state_file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$state_file"
  fi
}

init_audit() {
  local run_dir="$1" dry_run="$2"
  AUDIT_LOG="${run_dir}/logs/operations.log"
  export AUDIT_LOG
  if (( dry_run == 0 )); then
    printf 'Offline RootCA run started at %s\n' "$(date -u +%FT%TZ)" > "$AUDIT_LOG"
  fi
}

audit_cmd() {
  local cmd="$1"
  printf '%s\n' "[CMD] ${cmd//PIN=*/PIN=<REDACTED>}" >> "$AUDIT_LOG"
}

build_manifest_json() {
  local run_dir="$1"
  local manifest="${run_dir}/manifests/manifest.json"
  {
    echo '{'
    echo '  "generated_at": "'"$(date -u +%FT%TZ)"'",'
    echo '  "files": ['
    local first=1
    while IFS= read -r -d '' f; do
      local rel size sum
      rel="${f#${run_dir}/}"
      size="$(stat -c '%s' "$f")"
      sum="$(sha256sum "$f" | awk '{print $1}')"
      if (( first == 0 )); then echo '    ,'; fi
      first=0
      printf '    {"path":"%s","size":%s,"sha256":"%s"}' "$rel" "$size" "$sum"
      echo
    done < <(find "$run_dir" -type f ! -path "*/manifests/manifest.json" -print0 | sort -z)
    echo '  ]'
    echo '}'
  } > "$manifest"
}

build_sha256sums() {
  local run_dir="$1"
  (cd "$run_dir" && find certs crl csr configs profiles_used logs reports -type f 2>/dev/null | sort | xargs -r sha256sum > manifests/SHA256SUMS)
}

build_ceremony_minutes() {
  local run_dir="$1" mode="$2"
  local minutes="${run_dir}/reports/ceremony_minutes.md"
  cat > "$minutes" <<MD
# Offline Root CA Ceremony Minutes

- Date (UTC): $(date -u +%FT%TZ)
- Hostname: $(hostname)
- Mode: ${mode}
- Organization: 
- Operators: 
- Witnesses: 
- HSM Serial: 
- Slot/Partition: 
- Root key label: ${ROOTCA_KEY_LABEL:-N/A}
- M-of-N: ${ROOTCA_M:-N/A}/${ROOTCA_N:-N/A}

## Results
- Root certificate fingerprint: (see reports/root_cert_report.txt)
- Root CRL fingerprint: (see reports/root_crl_report.txt)
- Issuing CA signing details: (if performed, see reports/issuing_ca_report.txt)

## Sanitized command log excerpt

audit log: logs/operations.log

> Ensure all PINs and split secrets remain off-record.
MD
}

build_final_summary() {
  local run_dir="$1"
  local out="${run_dir}/reports/final_summary.txt"
  {
    echo "Offline Root CA run summary"
    echo "Run directory: ${run_dir}"
    echo "Generated at: $(date -u +%FT%TZ)"
    echo "Artifacts:"
    find "$run_dir" -maxdepth 2 -type f | sed "s#^${run_dir}/# - #"
  } > "$out"
}

finalize_audit_bundle() {
  local run_dir="$1" mode="$2" dry_run="$3"
  if (( dry_run == 1 )); then
    info "[dry-run] Would finalize audit bundle in ${run_dir}."
    return
  fi
  build_sha256sums "$run_dir"
  build_manifest_json "$run_dir"
  build_ceremony_minutes "$run_dir" "$mode"
  build_final_summary "$run_dir"
}
