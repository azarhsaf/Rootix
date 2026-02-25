#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
PROFILE_DIR="${SCRIPT_DIR}/profiles"

# shellcheck source=lib/ui.sh
source "${LIB_DIR}/ui.sh"
# shellcheck source=lib/hsm_luna.sh
source "${LIB_DIR}/hsm_luna.sh"
# shellcheck source=lib/openssl_pkcs11.sh
source "${LIB_DIR}/openssl_pkcs11.sh"
# shellcheck source=lib/profiles.sh
source "${LIB_DIR}/profiles.sh"
# shellcheck source=lib/audit.sh
source "${LIB_DIR}/audit.sh"

DRY_RUN=0
MODE=""
RUN_DIR=""
STATE_FILE=""
ROOTCA_KEY_MODE=""
ROOTCA_KEY_MODE_ARG=""
ROOTCA_KEY_FILE=""
TMPDIR_CLEANUP=""

cleanup() {
  if [[ -n "${TMPDIR_CLEANUP}" && -d "${TMPDIR_CLEANUP}" ]]; then
    rm -rf "${TMPDIR_CLEANUP}"
  fi
}
trap cleanup EXIT

usage() {
  cat <<USAGE
Usage:
  ./offline-rootca.sh ceremony [--dry-run] [--key-mode luna|software]
  ./offline-rootca.sh ops [--dry-run] [--key-mode luna|software]
USAGE
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    die "Run as root to write under /var/offline-rootca and protect private key files."
  fi
}

parse_args() {
  [[ $# -ge 1 ]] || { usage; exit 1; }
  MODE="$1"
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run|[--dry-run]) DRY_RUN=1 ;;
      --key-mode)
        shift
        [[ $# -gt 0 ]] || die "--key-mode requires value: luna or software"
        ROOTCA_KEY_MODE_ARG="$1"
        ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
    shift
  done
  [[ "$MODE" == "ceremony" || "$MODE" == "ops" ]] || { usage; exit 1; }

  if [[ -n "$ROOTCA_KEY_MODE_ARG" ]]; then
    [[ "$ROOTCA_KEY_MODE_ARG" == "luna" || "$ROOTCA_KEY_MODE_ARG" == "software" ]] || die "Invalid --key-mode: $ROOTCA_KEY_MODE_ARG"
    ROOTCA_KEY_MODE="$ROOTCA_KEY_MODE_ARG"
    export ROOTCA_KEY_MODE
  fi
}

create_run_context() {
  local org_slug="$1"
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  RUN_DIR="/var/offline-rootca/outputs/${org_slug}/${stamp}"
  if (( DRY_RUN == 0 )); then
    mkdir -p "${RUN_DIR}"/{certs,crl,csr,configs,profiles_used,logs,reports,manifests,state,tmp}
  fi
  STATE_FILE="${RUN_DIR}/state/steps.env"
  TMPDIR_CLEANUP="${RUN_DIR}/tmp/work"
  if (( DRY_RUN == 0 )); then
    mkdir -p "$TMPDIR_CLEANUP"
  fi
  init_state_file "$STATE_FILE" "$DRY_RUN"
  init_audit "$RUN_DIR" "$DRY_RUN"
}

select_key_storage_mode() {
  if [[ -n "${ROOTCA_KEY_MODE:-}" ]]; then
    ok "Key storage mode preset via CLI: ${ROOTCA_KEY_MODE}"
    return
  fi

  section "Select Root CA Key Storage"
  local choice
  if (( UI_USE_WHIPTAIL == 1 )); then
    choice="$(menu_select "Select Root CA Key Storage" \
      "1" "Luna USB HSM (Hardware Protected Key)" \
      "2" "Software Key (Stored Locally for Testing)")"
  else
    cat <<'SELECT_EOF'
Select Root CA Key Storage:

1) Luna USB HSM (Hardware Protected Key)
2) Software Key (Stored Locally for Testing)
SELECT_EOF
    read -r -p "Enter selection: " choice
  fi

  case "$choice" in
    luna|1) ROOTCA_KEY_MODE="luna" ;;
    software|2) ROOTCA_KEY_MODE="software" ;;
    *) die "Invalid key storage selection: $choice" ;;
  esac
  export ROOTCA_KEY_MODE

  if [[ "$ROOTCA_KEY_MODE" == "software" ]]; then
    warn "WARNING: Software Key Mode is intended ONLY for testing/lab usage."
    warn "Private key will be stored locally. Do NOT use for production Root CA."
    confirm_or_exit "Continue in Software Key Mode?"
  else
    ok "Luna HSM mode selected."
  fi
}

check_write_permissions() {
  local base_dir="/var/offline-rootca"
  mkdir -p "$base_dir"
  [[ -w "$base_dir" ]] || die "No write permission for $base_dir"
  ok "Output base path writable: $base_dir"
}

check_disk_space() {
  local avail_kb
  avail_kb="$(df -Pk /var/offline-rootca | awk 'NR==2{print $4}')"
  if (( avail_kb < 1048576 )); then
    warn "Low disk space (<1GB available) on /var/offline-rootca"
  else
    ok "Disk space check passed."
  fi
}

check_entropy_advisory() {
  local entropy_file="/proc/sys/kernel/random/entropy_avail"
  if [[ -r "$entropy_file" ]]; then
    local ent
    ent="$(<"$entropy_file")"
    if (( ent < 100 )); then
      warn "Low entropy detected (${ent}). Consider waiting for more entropy before key generation."
    else
      ok "Entropy advisory: ${ent} available."
    fi
  else
    warn "Entropy advisory unavailable on this system."
  fi
}

check_datetime() {
  info "Current UTC time: $(date -u +%FT%TZ)"
  confirm_or_exit "Confirm system date/time is correct before certificate operations. Continue?"
}

check_network_advisory() {
  local nic_count
  nic_count="$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -Ev '^lo$' | wc -l || true)"
  if [[ "$nic_count" -gt 0 ]]; then
    warn "Network interfaces detected. Offline Root CA operation is recommended in air-gapped mode."
    confirm_or_exit "Continue despite active interfaces?"
  else
    ok "No non-loopback interfaces detected."
  fi
}

run_preflight() {
  section "Pre-flight checks"
  info "Checking OpenSSL availability..."
  ensure_base_dependencies
  detect_openssl_version
  check_write_permissions
  check_disk_space
  check_entropy_advisory
  check_datetime
  check_network_advisory

  if [[ "$ROOTCA_KEY_MODE" == "luna" ]]; then
    info "Running Luna-specific checks..."
    if (( DRY_RUN == 1 )); then
      if command -v lunacm >/dev/null 2>&1; then
        ok "[dry-run] lunacm detected."
      else
        warn "[dry-run] lunacm not found. Install Luna Client offline for real runs."
      fi
      warn "[dry-run] Skipping strict PKCS#11/provider and module-path enforcement."
      detect_luna_module "$DRY_RUN"
      ok "[dry-run] Luna checks completed (advisory mode)."
    else
      ensure_lunacm
      detect_pkcs11_stack
      detect_luna_module "$DRY_RUN"
      ok "Luna + PKCS#11 checks passed."
    fi
  else
    ok "Software mode selected: skipping Luna and PKCS#11 checks."
  fi
  record_step "env_validated" "true" "$STATE_FILE" "$DRY_RUN"
}

build_subject() {
  local org="$1" cn="$2" c="$3"
  printf '/C=%s/O=%s/CN=%s' "$c" "$org" "$cn"
}

step_hsm_guided_flow() {
  [[ "$ROOTCA_KEY_MODE" == "luna" ]] || return 0
  section "Luna key ceremony"

  if (( DRY_RUN == 1 )) && ! command -v lunacm >/dev/null 2>&1; then
    warn "[dry-run] lunacm is unavailable; skipping interactive Luna ceremony steps."
    record_step "hsm_guided" "skipped_dry_run_no_lunacm" "$STATE_FILE" "$DRY_RUN"
    return 0
  fi

  show_hsm_status "$DRY_RUN"
  local init_choice
  init_choice="$(choose_partition_flow)"
  if [[ "$init_choice" == "new" ]]; then
    guided_partition_initialization "$DRY_RUN"
  else
    info "Using existing Luna partition."
  fi
  local m n
  m="$(prompt_input "Enter M value for M-of-N SO scheme" "${DEFAULT_M_OF_N_M:-2}")"
  n="$(prompt_input "Enter N value for M-of-N SO scheme" "${DEFAULT_M_OF_N_N:-3}")"
  validate_positive_int "$m" "M"
  validate_positive_int "$n" "N"
  (( m <= n )) || die "M must be <= N"
  export ROOTCA_M="$m" ROOTCA_N="$n"
  guided_mon_setup "$m" "$n" "$DRY_RUN"
  record_step "hsm_guided" "true" "$STATE_FILE" "$DRY_RUN"
}

step_root_key_and_cert() {
  local org="$1" cn="$2" validity="$3" country="$4"
  local key_label="ROOTCA_${org// /_}_$(date +%Y%m%d)"
  key_label="${key_label//[^A-Za-z0-9_.-]/_}"
  export ROOTCA_KEY_LABEL="$key_label"
  local subj cert_pem cert_der
  subj="$(build_subject "$org" "$cn" "$country")"
  cert_pem="${RUN_DIR}/certs/rootca.pem"
  cert_der="${RUN_DIR}/certs/rootca.der"

  if [[ "$ROOTCA_KEY_MODE" == "luna" ]]; then
    if (( DRY_RUN == 1 )) && ! command -v lunacm >/dev/null 2>&1; then
      warn "[dry-run] lunacm unavailable; skipping HSM key creation and root certificate signing simulation."
      record_step "root_cert_created" "skipped_dry_run_no_lunacm" "$STATE_FILE" "$DRY_RUN"
      return 0
    fi

    confirm_or_exit "Create non-exportable Root keypair in HSM with label ${key_label}?"
    create_hsm_keypair "$key_label" "$DRY_RUN"
    confirm_or_exit "Generate self-signed Root CA certificate with HSM key?"
    generate_root_self_signed_luna \
      "$key_label" "$subj" "$validity" \
      "${PROFILE_DIR}/root_ca.cnf" "$cert_pem" "$cert_der" "$RUN_DIR" "$DRY_RUN"
  else
    local key_alg
    key_alg="$(menu_select "Select software key algorithm" \
      "rsa" "RSA 4096 (default)" \
      "ecdsa" "ECDSA P-384")"
    [[ "$key_alg" == "rsa" || "$key_alg" == "ecdsa" || "$key_alg" == "1" || "$key_alg" == "2" ]] || die "Invalid key algorithm selection"
    [[ "$key_alg" == "1" ]] && key_alg="rsa"
    [[ "$key_alg" == "2" ]] && key_alg="ecdsa"
    ROOTCA_KEY_FILE="${RUN_DIR}/configs/rootca.key"
    export ROOTCA_KEY_FILE

    confirm_or_exit "Generate local Root private key (${key_alg}) at ${ROOTCA_KEY_FILE}?"
    generate_local_root_key "$key_alg" "$ROOTCA_KEY_FILE" "$DRY_RUN"
    confirm_or_exit "Generate self-signed Root CA certificate using local software key?"
    generate_root_self_signed_software \
      "$ROOTCA_KEY_FILE" "$subj" "$validity" \
      "${PROFILE_DIR}/root_ca.cnf" "$cert_pem" "$cert_der" "$DRY_RUN"
  fi

  generate_cert_report "$cert_pem" "Root CA" "${RUN_DIR}/reports/root_cert_report.txt" "$DRY_RUN"
  record_step "root_cert_created" "true" "$STATE_FILE" "$DRY_RUN"
}

step_initial_crl() {
  local next_days="$1"
  local crl_pem="${RUN_DIR}/crl/rootca.crl.pem"
  local crl_der="${RUN_DIR}/crl/rootca.crl.der"
  confirm_or_exit "Generate initial Root CRL (nextUpdate ${next_days} days)?"
  if [[ "$ROOTCA_KEY_MODE" == "luna" ]]; then
    if (( DRY_RUN == 1 )) && ! command -v lunacm >/dev/null 2>&1; then
      warn "[dry-run] lunacm unavailable; skipping Luna CRL simulation."
      record_step "initial_crl_created" "skipped_dry_run_no_lunacm" "$STATE_FILE" "$DRY_RUN"
      return 0
    fi
    generate_root_crl_luna "$RUN_DIR" "$next_days" "$crl_pem" "$crl_der" "$DRY_RUN"
  else
    generate_root_crl_software "$RUN_DIR" "$next_days" "$crl_pem" "$crl_der" "$ROOTCA_KEY_FILE" "$DRY_RUN"
  fi
  generate_crl_report "$crl_pem" "${RUN_DIR}/reports/root_crl_report.txt" "$DRY_RUN"
  record_step "initial_crl_created" "true" "$STATE_FILE" "$DRY_RUN"
}

sign_issuing_csr_by_mode() {
  local csr="$1" out_pem="$2" out_der="$3" chain="$4"
  if [[ "$ROOTCA_KEY_MODE" == "luna" ]]; then
    if (( DRY_RUN == 1 )) && ! command -v lunacm >/dev/null 2>&1; then
      warn "[dry-run] lunacm unavailable; skipping Luna issuing CSR signing simulation."
      return 0
    fi
    sign_issuing_csr_luna "$csr" "$out_pem" "$out_der" "$chain" "$RUN_DIR" "$DRY_RUN"
  else
    sign_issuing_csr_software "$csr" "$out_pem" "$out_der" "$chain" "$RUN_DIR" "$ROOTCA_KEY_FILE" "$DRY_RUN"
  fi
}

step_optional_sign_subca() {
  if ! confirm_yes_no "Do you want to sign an Issuing CA CSR now?" "no"; then
    info "Skipping Issuing CA signing during ceremony."
    return
  fi
  local csr
  csr="$(prompt_input "Enter Issuing CA CSR path" "")"
  [[ -f "$csr" ]] || die "CSR file not found: $csr"
  local out_pem="${RUN_DIR}/certs/issuing_ca_cert.pem"
  local out_der="${RUN_DIR}/certs/issuing_ca_cert.der"
  local chain="${RUN_DIR}/certs/issuing_ca_chain.pem"
  sign_issuing_csr_by_mode "$csr" "$out_pem" "$out_der" "$chain"
  generate_cert_report "$out_pem" "Issuing CA" "${RUN_DIR}/reports/issuing_ca_report.txt" "$DRY_RUN"
  record_step "issuing_signed" "true" "$STATE_FILE" "$DRY_RUN"
}

ceremony_mode() {
  require_root
  banner "OFFLINE ROOT CA CEREMONY"

  local org cn validity country org_slug
  org="$(prompt_input "Organization (O)" "ExampleOrg")"
  cn="$(prompt_input "Root CA Common Name (CN)" "${org} Offline Root CA")"
  validity="$(prompt_input "Root CA validity days" "${DEFAULT_ROOT_VALIDITY_DAYS:-7300}")"
  country="$(prompt_input "Country code (C)" "${DEFAULT_COUNTRY:-US}")"
  validate_positive_int "$validity" "validity days"
  org_slug="${org// /_}"
  org_slug="${org_slug//[^A-Za-z0-9_.-]/_}"

  create_run_context "$org_slug"
  load_defaults_profile "${PROFILE_DIR}/defaults.env"
  copy_profiles_used "$PROFILE_DIR" "$RUN_DIR" "$DRY_RUN"

  select_key_storage_mode
  run_preflight
  step_hsm_guided_flow
  step_root_key_and_cert "$org" "$cn" "$validity" "$country"
  step_initial_crl "${DEFAULT_CRL_NEXT_DAYS:-30}"
  step_optional_sign_subca

  finalize_audit_bundle "$RUN_DIR" "$MODE" "$DRY_RUN"
  ok "Ceremony complete. Output directory: ${RUN_DIR}"
}

ops_prepare_context() {
  local org
  org="$(prompt_input "Organization tag for output" "ops")"
  create_run_context "${org// /_}"
  load_defaults_profile "${PROFILE_DIR}/defaults.env"
  copy_profiles_used "$PROFILE_DIR" "$RUN_DIR" "$DRY_RUN"
  select_key_storage_mode
  run_preflight
  if [[ "$ROOTCA_KEY_MODE" == "software" ]]; then
    ROOTCA_KEY_FILE="$(prompt_input "Path to existing software Root key" "/var/offline-rootca/rootca.key")"
    [[ -f "$ROOTCA_KEY_FILE" || $DRY_RUN -eq 1 ]] || die "Software Root key not found: $ROOTCA_KEY_FILE"
    export ROOTCA_KEY_FILE
  fi
}

ops_sign_subca() {
  ops_prepare_context
  local csr out_pem out_der chain
  csr="$(prompt_input "CSR path" "")"
  [[ -f "$csr" ]] || die "CSR file not found"
  out_pem="${RUN_DIR}/certs/issuing_ca_cert.pem"
  out_der="${RUN_DIR}/certs/issuing_ca_cert.der"
  chain="${RUN_DIR}/certs/issuing_ca_chain.pem"
  sign_issuing_csr_by_mode "$csr" "$out_pem" "$out_der" "$chain"
  finalize_audit_bundle "$RUN_DIR" "$MODE" "$DRY_RUN"
}

ops_generate_crl() {
  ops_prepare_context
  if [[ "$ROOTCA_KEY_MODE" == "luna" ]]; then
    generate_root_crl_luna "$RUN_DIR" "${DEFAULT_CRL_NEXT_DAYS:-30}" "${RUN_DIR}/crl/rootca.crl.pem" "${RUN_DIR}/crl/rootca.crl.der" "$DRY_RUN"
  else
    generate_root_crl_software "$RUN_DIR" "${DEFAULT_CRL_NEXT_DAYS:-30}" "${RUN_DIR}/crl/rootca.crl.pem" "${RUN_DIR}/crl/rootca.crl.der" "$ROOTCA_KEY_FILE" "$DRY_RUN"
  fi
  finalize_audit_bundle "$RUN_DIR" "$MODE" "$DRY_RUN"
}

ops_export_chain() {
  local cert root out_dir
  cert="$(prompt_input "Path to issuing cert PEM" "")"
  root="$(prompt_input "Path to root cert PEM" "")"
  [[ -f "$cert" && -f "$root" ]] || die "Missing cert file(s)."
  out_dir="$(prompt_input "Output directory for chain export" "/var/offline-rootca/exports")"
  if (( DRY_RUN == 0 )); then
    mkdir -p "$out_dir"
    cat "$cert" "$root" > "${out_dir}/ca_chain.pem"
    sha256sum "${out_dir}/ca_chain.pem" > "${out_dir}/ca_chain.pem.sha256"
  fi
  ok "Chain export completed: ${out_dir}/ca_chain.pem"
}

ops_transfer_package() {
  local source_dir out_file
  source_dir="$(prompt_input "Source output directory" "/var/offline-rootca/outputs")"
  out_file="$(prompt_input "Transfer tar.gz path" "/var/offline-rootca/transfer_package.tar.gz")"
  [[ -d "$source_dir" ]] || die "Source directory missing."
  if (( DRY_RUN == 0 )); then
    tar -C "$(dirname "$source_dir")" -czf "$out_file" "$(basename "$source_dir")"
    sha256sum "$out_file" > "${out_file}.sha256"
  fi
  ok "Created transfer package: $out_file"
}

ops_verify_package() {
  local pkg hashf
  pkg="$(prompt_input "Package tar.gz path" "")"
  hashf="$(prompt_input "Checksum file path" "${pkg}.sha256")"
  [[ -f "$pkg" && -f "$hashf" ]] || die "Missing package/checksum file."
  if (( DRY_RUN == 0 )); then
    (cd "$(dirname "$pkg")" && sha256sum -c "$hashf")
  else
    info "[dry-run] Would verify sha256 integrity for package."
  fi
}

ops_mode() {
  require_root
  banner "OFFLINE ROOT CA OPERATIONS"
  while true; do
    local choice
    choice="$(menu_select "Select operation" \
      "1" "Check environment + HSM/software status" \
      "2" "Create additional HSM user (guided)" \
      "3" "Generate new Root CRL" \
      "4" "Sign subordinate CSR (Issuing CA)" \
      "5" "Export cert chain + fingerprints" \
      "6" "Create offline transfer package" \
      "7" "Verify transfer package integrity" \
      "8" "Exit")"
    case "$choice" in
      1)
        create_run_context "ops_status"
        load_defaults_profile "${PROFILE_DIR}/defaults.env"
        select_key_storage_mode
        run_preflight
        if [[ "$ROOTCA_KEY_MODE" == "luna" ]]; then
          show_hsm_status "$DRY_RUN"
        fi
        finalize_audit_bundle "$RUN_DIR" "$MODE" "$DRY_RUN"
        ;;
      2)
        create_run_context "ops_user"
        load_defaults_profile "${PROFILE_DIR}/defaults.env"
        select_key_storage_mode
        [[ "$ROOTCA_KEY_MODE" == "luna" ]] || die "Additional HSM user option applies only in Luna mode."
        run_preflight
        guided_additional_user "$DRY_RUN"
        finalize_audit_bundle "$RUN_DIR" "$MODE" "$DRY_RUN"
        ;;
      3) ops_generate_crl ;;
      4) ops_sign_subca ;;
      5) ops_export_chain ;;
      6) ops_transfer_package ;;
      7) ops_verify_package ;;
      8) break ;;
      *) warn "Invalid selection" ;;
    esac
  done
}

main() {
  parse_args "$@"
  case "$MODE" in
    ceremony) ceremony_mode ;;
    ops) ops_mode ;;
  esac
}

main "$@"
