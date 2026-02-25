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

usage() {
  cat <<USAGE
Usage:
  ./offline-rootca.sh ceremony [--dry-run]
  ./offline-rootca.sh ops [--dry-run]

Modes:
  ceremony   Full Root CA ceremony wizard
  ops        Operations menu

Flags:
  --dry-run  Validate environment and print actions, but make no changes
USAGE
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    die "Run as root to write under /var/offline-rootca and access local crypto assets."
  fi
}

parse_args() {
  [[ $# -ge 1 ]] || { usage; exit 1; }
  MODE="$1"
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
    shift
  done
  [[ "$MODE" == "ceremony" || "$MODE" == "ops" ]] || { usage; exit 1; }
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
  init_state_file "${STATE_FILE}" "$DRY_RUN"
  init_audit "${RUN_DIR}" "$DRY_RUN"
}

confirm_step() {
  local msg="$1"
  confirm_or_exit "$msg"
}

step_prepare_environment() {
  local defaults_file="${PROFILE_DIR}/defaults.env"
  load_defaults_profile "$defaults_file"
  ensure_base_dependencies "$DRY_RUN"
  detect_pkcs11_stack "$DRY_RUN"
  detect_luna_module
  record_step "env_validated" "true" "$STATE_FILE" "$DRY_RUN"
}

step_hsm_guided_flow() {
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

build_subject() {
  local org="$1" cn="$2" c="$3"
  printf '/C=%s/O=%s/CN=%s' "$c" "$org" "$cn"
}

step_root_key_and_cert() {
  local org="$1" cn="$2" validity="$3" country="$4"
  local key_label="ROOTCA_${org// /_}_$(date +%Y%m%d)"
  key_label="${key_label//[^A-Za-z0-9_.-]/_}"
  export ROOTCA_KEY_LABEL="$key_label"

  confirm_step "Create non-exportable Root keypair in HSM with label ${key_label}?"
  create_hsm_keypair "$key_label" "$DRY_RUN"

  local subj
  subj="$(build_subject "$org" "$cn" "$country")"
  local cert_pem="${RUN_DIR}/certs/rootca.pem"
  local cert_der="${RUN_DIR}/certs/rootca.der"

  confirm_step "Generate self-signed Root CA certificate with HSM key?"
  generate_root_self_signed \
    "$key_label" "$subj" "$validity" \
    "${PROFILE_DIR}/root_ca.cnf" "$cert_pem" "$cert_der" "$RUN_DIR" "$DRY_RUN"

  generate_cert_report "$cert_pem" "Root CA" "${RUN_DIR}/reports/root_cert_report.txt" "$DRY_RUN"
  record_step "root_cert_created" "true" "$STATE_FILE" "$DRY_RUN"
}

step_initial_crl() {
  local next_days="$1"
  local crl_pem="${RUN_DIR}/crl/rootca.crl.pem"
  local crl_der="${RUN_DIR}/crl/rootca.crl.der"
  confirm_step "Generate initial Root CRL (nextUpdate ${next_days} days)?"
  generate_root_crl "$RUN_DIR" "$next_days" "$crl_pem" "$crl_der" "$DRY_RUN"
  generate_crl_report "$crl_pem" "${RUN_DIR}/reports/root_crl_report.txt" "$DRY_RUN"
  record_step "initial_crl_created" "true" "$STATE_FILE" "$DRY_RUN"
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
  sign_issuing_csr "$csr" "$out_pem" "$out_der" "$chain" "$RUN_DIR" "$DRY_RUN"
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
  copy_profiles_used "$PROFILE_DIR" "$RUN_DIR" "$DRY_RUN"

  step_prepare_environment
  step_hsm_guided_flow
  step_root_key_and_cert "$org" "$cn" "$validity" "$country"
  step_initial_crl "${DEFAULT_CRL_NEXT_DAYS:-30}"
  step_optional_sign_subca

  finalize_audit_bundle "$RUN_DIR" "$MODE" "$DRY_RUN"
  info "Ceremony complete. Output directory: ${RUN_DIR}"
}

ops_sign_subca() {
  local run_org run_dir csr out_pem out_der chain
  run_org="$(prompt_input "Organization tag for output" "ops")"
  create_run_context "${run_org// /_}"
  step_prepare_environment
  csr="$(prompt_input "CSR path" "")"
  [[ -f "$csr" ]] || die "CSR file not found"
  out_pem="${RUN_DIR}/certs/issuing_ca_cert.pem"
  out_der="${RUN_DIR}/certs/issuing_ca_cert.der"
  chain="${RUN_DIR}/certs/issuing_ca_chain.pem"
  sign_issuing_csr "$csr" "$out_pem" "$out_der" "$chain" "$RUN_DIR" "$DRY_RUN"
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
  info "Chain export completed: ${out_dir}/ca_chain.pem"
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
  info "Created transfer package: $out_file"
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
  step_prepare_environment
  while true; do
    local choice
    choice="$(menu_select "Select operation" \
      "1" "Check HSM connectivity" \
      "2" "Create additional HSM user (guided)" \
      "3" "Generate new Root CRL" \
      "4" "Sign subordinate CSR (Issuing CA)" \
      "5" "Export cert chain + fingerprints" \
      "6" "Create offline transfer package" \
      "7" "Verify transfer package integrity" \
      "8" "Exit")"
    case "$choice" in
      1) show_hsm_status "$DRY_RUN" ;;
      2) guided_additional_user "$DRY_RUN" ;;
      3)
        local org
        org="$(prompt_input "Organization tag for CRL run output" "ops")"
        create_run_context "${org// /_}"
        generate_root_crl "$RUN_DIR" "${DEFAULT_CRL_NEXT_DAYS:-30}" "${RUN_DIR}/crl/rootca.crl.pem" "${RUN_DIR}/crl/rootca.crl.der" "$DRY_RUN"
        finalize_audit_bundle "$RUN_DIR" "$MODE" "$DRY_RUN"
        ;;
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
