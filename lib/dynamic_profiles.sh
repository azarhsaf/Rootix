#!/usr/bin/env bash
set -euo pipefail

PROFILE_MODE="static"   # static|dynamic
DYNAMIC_ROOT_PROFILE_JSON=""
DYNAMIC_ISSUING_PROFILE_JSON=""
ROOT_DYNAMIC_VALIDITY_DAYS=""
ISSUING_DYNAMIC_VALIDITY_DAYS=""

init_profile_mode() {
  PROFILE_MODE="${PROFILE_MODE:-${DEFAULT_PROFILE_MODE:-static}}"
  PROFILE_MODE="${PROFILE_MODE,,}"
  [[ "$PROFILE_MODE" == "static" || "$PROFILE_MODE" == "dynamic" ]] || die "Invalid profile mode: $PROFILE_MODE"

  DYNAMIC_ROOT_PROFILE_JSON="${DYNAMIC_ROOT_PROFILE_JSON:-${DEFAULT_DYNAMIC_ROOT_PROFILE_JSON:-${PWD}/profiles/dynamic/root_ca.json}}"
  DYNAMIC_ISSUING_PROFILE_JSON="${DYNAMIC_ISSUING_PROFILE_JSON:-${DEFAULT_DYNAMIC_ISSUING_PROFILE_JSON:-${PWD}/profiles/dynamic/issuing_ca.json}}"

  if [[ "$PROFILE_MODE" == "dynamic" ]]; then
    command -v jq >/dev/null 2>&1 || die "Dynamic profile mode requires jq. Install jq from offline RPM media."
    [[ -f "$DYNAMIC_ROOT_PROFILE_JSON" ]] || die "Missing dynamic root profile JSON: $DYNAMIC_ROOT_PROFILE_JSON"
    [[ -f "$DYNAMIC_ISSUING_PROFILE_JSON" ]] || die "Missing dynamic issuing profile JSON: $DYNAMIC_ISSUING_PROFILE_JSON"
    ok "Dynamic profile mode enabled."
  else
    ok "Static profile mode enabled."
  fi
  export PROFILE_MODE DYNAMIC_ROOT_PROFILE_JSON DYNAMIC_ISSUING_PROFILE_JSON
}

_build_dynamic_ext_block() {
  local json="$1" section="$2"
  local bc ku eku cp aia crldp
  bc="$(jq -r '.basicConstraints // empty' "$json")"
  ku="$(jq -r '.keyUsage // empty' "$json")"
  eku="$(jq -r '.extendedKeyUsage // empty' "$json")"
  cp="$(jq -r '.certificatePolicies // empty' "$json")"
  aia="$(jq -r '.authorityInfoAccess // empty' "$json")"
  crldp="$(jq -r '.crlDistributionPoints // empty' "$json")"

  printf '[%s]\n' "$section"
  printf 'subjectKeyIdentifier = hash\n'
  [[ "$section" == "v3_root_ca" ]] && printf 'authorityKeyIdentifier = keyid:always\n' || printf 'authorityKeyIdentifier = keyid,issuer\n'
  [[ -n "$bc" ]] && printf 'basicConstraints = %s\n' "$bc"
  [[ -n "$ku" ]] && printf 'keyUsage = %s\n' "$ku"
  [[ -n "$eku" ]] && printf 'extendedKeyUsage = %s\n' "$eku"
  [[ -n "$cp" ]] && printf 'certificatePolicies = %s\n' "$cp"
  [[ -n "$aia" ]] && printf 'authorityInfoAccess = %s\n' "$aia"
  [[ -n "$crldp" ]] && printf 'crlDistributionPoints = %s\n' "$crldp"
}

generate_dynamic_extfile() {
  local json="$1" section="$2" run_dir="$3"
  local out="${run_dir}/configs/dynamic-${section}.cnf"
  _build_dynamic_ext_block "$json" "$section" > "$out"
  printf '%s' "$out"
}

dynamic_validity_days() {
  local json="$1" fallback="$2"
  local days
  days="$(jq -r '.validityDays // empty' "$json")"
  if [[ -n "$days" ]]; then
    printf '%s' "$days"
  else
    printf '%s' "$fallback"
  fi
}
