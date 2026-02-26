#!/usr/bin/env bash
set -euo pipefail

OPENSSL_BIN="${OPENSSL_BIN:-$(command -v openssl || true)}"
OPENSSL_MAJOR=""
PKCS11_MODE="" # provider|engine
PKCS11_HELPER="" # provider module or engine id

ensure_base_dependencies() {
  [[ -n "$OPENSSL_BIN" ]] || die "OpenSSL not installed. Install offline RPMs and retry."
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum missing (coreutils)."
  command -v tar >/dev/null 2>&1 || die "tar missing."
  command -v find >/dev/null 2>&1 || die "find missing (findutils)."
}

detect_openssl_version() {
  local v
  v="$($OPENSSL_BIN version | awk '{print $2}')"
  OPENSSL_MAJOR="${v%%.*}"
  ok "OpenSSL detected: $v"
}

detect_pkcs11_stack() {
  if [[ "$OPENSSL_MAJOR" == "3" ]]; then
    detect_provider_or_engine_for_ossl3
  elif [[ "$OPENSSL_MAJOR" == "1" ]]; then
    detect_engine_for_ossl11
  else
    die "Unsupported OpenSSL version: $($OPENSSL_BIN version)"
  fi
  ok "PKCS#11 integration available via ${PKCS11_MODE}."
}

detect_provider_or_engine_for_ossl3() {
  local provider_paths=(
    "/usr/lib64/ossl-modules/pkcs11.so"
    "/usr/lib64/openssl3/pkcs11.so"
    "/usr/lib64/pkcs11prov.so"
  )
  local p
  for p in "${provider_paths[@]}"; do
    if [[ -f "$p" ]]; then
      PKCS11_MODE="provider"
      PKCS11_HELPER="$p"
      return
    fi
  done

  if $OPENSSL_BIN engine -t 2>/dev/null | grep -qi pkcs11; then
    PKCS11_MODE="engine"
    PKCS11_HELPER="pkcs11"
    return
  fi

  cat <<'INSTR'
No PKCS#11 provider/engine found for OpenSSL 3.
Offline install one of:
  - pkcs11-provider / pkcs11prov RPM
  - libp11 + openssl-pkcs11 engine RPM (if provider unavailable)
From local RPM media:
  rpm -Uvh /path/to/rpms/*.rpm
Then retry.
INSTR
  exit 1
}

detect_engine_for_ossl11() {
  if $OPENSSL_BIN engine -t 2>/dev/null | grep -qi pkcs11; then
    PKCS11_MODE="engine"
    PKCS11_HELPER="pkcs11"
    return
  fi
  cat <<'INSTR'
OpenSSL 1.1.1 detected but PKCS#11 engine not available.
Offline install libp11 / openssl-pkcs11 RPMs from local media, e.g.:
  rpm -Uvh /path/to/libp11*.rpm /path/to/openssl-pkcs11*.rpm
Then retry.
INSTR
  exit 1
}

openssl_pkcs11_env() {
  local conf="$1"
  if [[ "$PKCS11_MODE" == "provider" ]]; then
    cat > "$conf" <<CFG
openssl_conf = openssl_init
[openssl_init]
providers = provider_sect
[provider_sect]
default = default_sect
pkcs11 = pkcs11_sect
[default_sect]
activate = 1
[pkcs11_sect]
module = ${PKCS11_HELPER}
pkcs11-module-path = ${LUNA_PKCS11_MODULE}
activate = 1
CFG
  else
    cat > "$conf" <<CFG
openssl_conf = openssl_init
[openssl_init]
engines = engine_section
[engine_section]
pkcs11 = pkcs11_section
[pkcs11_section]
engine_id = pkcs11
dynamic_path = /usr/lib64/engines-1.1/pkcs11.so
MODULE_PATH = ${LUNA_PKCS11_MODULE}
init = 0
CFG
  fi
}

pkcs11_key_uri() {
  local key_label="$1"
  local token_label
  token_label="$(prompt_input "Enter token/partition label for OpenSSL PKCS#11 URI" "")"
  printf 'pkcs11:token=%s;object=%s;type=private' "$token_label" "$key_label"
}

generate_local_root_key() {
  local key_type="$1" key_file="$2" dry_run="$3"
  if (( dry_run == 1 )); then
    info "[dry-run] Would generate local ${key_type} private key at ${key_file}."
    return
  fi

  mkdir -p "$(dirname "$key_file")"
  case "$key_type" in
    rsa)
      "$OPENSSL_BIN" genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "$key_file"
      ;;
    ecdsa)
      "$OPENSSL_BIN" genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -out "$key_file"
      ;;
    *) die "Unsupported local key type: $key_type" ;;
  esac
  chmod 600 "$key_file"
  chown root:root "$key_file"
  ok "Local private key generated with root-only permissions: $key_file"
}

generate_root_self_signed_luna() {
  local key_label="$1" subj="$2" validity_days="$3" profile="$4" out_pem="$5" out_der="$6" run_dir="$7" dry_run="$8"
  local pin keyuri openssl_conf
  local extfile="$profile" extsection="v3_root_ca"
  if [[ "${PROFILE_MODE:-static}" == "dynamic" ]]; then
    extfile="$(generate_dynamic_extfile "$DYNAMIC_ROOT_PROFILE_JSON" "$extsection" "$run_dir")"
    validity_days="$(dynamic_validity_days "$DYNAMIC_ROOT_PROFILE_JSON" "$validity_days")"
  fi
  pin="$(prompt_secret "Enter CO PIN for signing Root certificate (hidden)")"
  keyuri="$(pkcs11_key_uri "$key_label")"
  openssl_conf="${run_dir}/configs/openssl-pkcs11.cnf"
  if (( dry_run == 1 )); then
    info "[dry-run] Would self-sign Root cert subject=${subj}, validity=${validity_days}, key=${keyuri}."
    unset pin
    return
  fi

  openssl_pkcs11_env "$openssl_conf"
  local serial_hex
  serial_hex="$($OPENSSL_BIN rand -hex 16)"

  if [[ "$PKCS11_MODE" == "provider" ]]; then
    OPENSSL_CONF="$openssl_conf" PKCS11_PIN="$pin" \
      "$OPENSSL_BIN" req -new -x509 -sha256 -days "$validity_days" \
      -subj "$subj" -set_serial "0x${serial_hex}" \
      -extfile "$extfile" -extensions "$extsection" \
      -key "$keyuri" -out "$out_pem"
  else
    OPENSSL_CONF="$openssl_conf" PKCS11_PIN="$pin" \
      "$OPENSSL_BIN" req -new -x509 -sha256 -days "$validity_days" \
      -subj "$subj" -set_serial "0x${serial_hex}" \
      -extfile "$extfile" -extensions "$extsection" \
      -engine pkcs11 -keyform engine -key "$keyuri" -out "$out_pem"
  fi
  "$OPENSSL_BIN" x509 -in "$out_pem" -outform DER -out "$out_der"
  unset pin
}

generate_root_self_signed_software() {
  local key_file="$1" subj="$2" validity_days="$3" profile="$4" out_pem="$5" out_der="$6" dry_run="$7"
  local extfile="$profile" extsection="v3_root_ca"
  if [[ "${PROFILE_MODE:-static}" == "dynamic" ]]; then
    extfile="$(generate_dynamic_extfile "$DYNAMIC_ROOT_PROFILE_JSON" "$extsection" "$(dirname "$out_pem")/..")"
    validity_days="$(dynamic_validity_days "$DYNAMIC_ROOT_PROFILE_JSON" "$validity_days")"
  fi
  if (( dry_run == 1 )); then
    info "[dry-run] Would self-sign Root cert using local key ${key_file}."
    return
  fi

  local serial_hex
  serial_hex="$($OPENSSL_BIN rand -hex 16)"
  "$OPENSSL_BIN" req -new -x509 -sha256 -days "$validity_days" \
    -subj "$subj" -set_serial "0x${serial_hex}" \
    -extfile "$extfile" -extensions "$extsection" \
    -key "$key_file" -out "$out_pem"
  "$OPENSSL_BIN" x509 -in "$out_pem" -outform DER -out "$out_der"
}

sign_issuing_csr_luna() {
  local csr="$1" out_pem="$2" out_der="$3" chain_pem="$4" run_dir="$5" dry_run="$6"
  local root_cert root_key_label profile validity pin keyuri openssl_conf
  root_cert="$(prompt_input "Path to Root CA certificate PEM" "${ROOTCA_CERT_PATH:-${run_dir}/certs/rootca.pem}")"
  [[ -f "$root_cert" || $dry_run -eq 1 ]] || die "Root cert not found: $root_cert"
  root_key_label="$(prompt_input "Root key label in HSM" "${ROOTCA_KEY_LABEL:-}")"
  validity="$(prompt_input "Issuing CA validity days" "${DEFAULT_ISSUING_VALIDITY_DAYS:-3650}")"
  profile="${PWD}/profiles/issuing_ca.cnf"
  local extfile="$profile" extsection="v3_issuing_ca"
  if [[ "${PROFILE_MODE:-static}" == "dynamic" ]]; then
    extfile="$(generate_dynamic_extfile "$DYNAMIC_ISSUING_PROFILE_JSON" "$extsection" "$run_dir")"
    validity="$(dynamic_validity_days "$DYNAMIC_ISSUING_PROFILE_JSON" "$validity")"
  fi
  pin="$(prompt_secret "Enter CO PIN for SubCA signing (hidden)")"
  keyuri="$(pkcs11_key_uri "$root_key_label")"
  openssl_conf="${run_dir}/configs/openssl-pkcs11.cnf"

  if (( dry_run == 1 )); then
    info "[dry-run] Would sign CSR ${csr} with root key ${root_key_label}."
    unset pin
    return
  fi

  openssl_pkcs11_env "$openssl_conf"
  if [[ "$PKCS11_MODE" == "provider" ]]; then
    OPENSSL_CONF="$openssl_conf" PKCS11_PIN="$pin" \
      "$OPENSSL_BIN" x509 -req -in "$csr" -CA "$root_cert" -CAcreateserial \
      -days "$validity" -sha256 -extfile "$extfile" -extensions "$extsection" \
      -CAkey "$keyuri" -out "$out_pem"
  else
    OPENSSL_CONF="$openssl_conf" PKCS11_PIN="$pin" \
      "$OPENSSL_BIN" x509 -req -in "$csr" -CA "$root_cert" -CAcreateserial \
      -days "$validity" -sha256 -extfile "$extfile" -extensions "$extsection" \
      -engine pkcs11 -CAkeyform engine -CAkey "$keyuri" -out "$out_pem"
  fi
  "$OPENSSL_BIN" x509 -in "$out_pem" -outform DER -out "$out_der"
  cat "$out_pem" "$root_cert" > "$chain_pem"
  unset pin
}

sign_issuing_csr_software() {
  local csr="$1" out_pem="$2" out_der="$3" chain_pem="$4" run_dir="$5" root_key_file="$6" dry_run="$7"
  local root_cert validity profile
  root_cert="$(prompt_input "Path to Root CA certificate PEM" "${ROOTCA_CERT_PATH:-${run_dir}/certs/rootca.pem}")"
  [[ -f "$root_cert" || $dry_run -eq 1 ]] || die "Root cert not found: $root_cert"
  [[ -f "$root_key_file" || $dry_run -eq 1 ]] || die "Root key file not found: $root_key_file"
  validity="$(prompt_input "Issuing CA validity days" "${DEFAULT_ISSUING_VALIDITY_DAYS:-3650}")"
  profile="${PWD}/profiles/issuing_ca.cnf"
  local extfile="$profile" extsection="v3_issuing_ca"
  if [[ "${PROFILE_MODE:-static}" == "dynamic" ]]; then
    extfile="$(generate_dynamic_extfile "$DYNAMIC_ISSUING_PROFILE_JSON" "$extsection" "$run_dir")"
    validity="$(dynamic_validity_days "$DYNAMIC_ISSUING_PROFILE_JSON" "$validity")"
  fi

  if (( dry_run == 1 )); then
    info "[dry-run] Would sign CSR ${csr} with local Root key ${root_key_file}."
    return
  fi

  "$OPENSSL_BIN" x509 -req -in "$csr" -CA "$root_cert" -CAcreateserial \
    -days "$validity" -sha256 -extfile "$extfile" -extensions "$extsection" \
    -CAkey "$root_key_file" -out "$out_pem"
  "$OPENSSL_BIN" x509 -in "$out_pem" -outform DER -out "$out_der"
  cat "$out_pem" "$root_cert" > "$chain_pem"
}

generate_root_crl_luna() {
  local run_dir="$1" next_days="$2" out_pem="$3" out_der="$4" dry_run="$5"
  local root_cert root_label pin keyuri openssl_conf index serial crlnumber dbdir ca_conf
  root_cert="$(prompt_input "Path to Root certificate PEM for CRL signing" "${ROOTCA_CERT_PATH:-${run_dir}/certs/rootca.pem}")"
  root_label="$(prompt_input "Root key label for CRL signing" "${ROOTCA_KEY_LABEL:-}")"
  pin="$(prompt_secret "Enter CO PIN for CRL generation (hidden)")"
  keyuri="$(pkcs11_key_uri "$root_label")"

  if (( dry_run == 1 )); then
    info "[dry-run] Would generate CRL with nextUpdate ${next_days} days."
    unset pin
    return
  fi

  dbdir="${run_dir}/tmp/ca-db"
  mkdir -p "$dbdir"
  index="${dbdir}/index.txt"
  serial="${dbdir}/serial"
  crlnumber="${dbdir}/crlnumber"
  : > "$index"
  echo "1000" > "$serial"
  echo "1000" > "$crlnumber"
  openssl_conf="${run_dir}/configs/openssl-pkcs11.cnf"
  ca_conf="${run_dir}/configs/ca-crl.cnf"
  openssl_pkcs11_env "$openssl_conf"

  cat > "$ca_conf" <<CFG
openssl_conf = openssl_init
[openssl_init]
.include ${openssl_conf}
[ca]
default_ca = CA_default
[CA_default]
database = ${index}
serial = ${serial}
crlnumber = ${crlnumber}
default_md = sha256
default_crl_days = ${next_days}
certificate = ${root_cert}
private_key = ${keyuri}
unique_subject = no
x509_extensions = v3_root_ca
[crl_ext]
authorityKeyIdentifier = keyid:always
CFG

  if [[ "$PKCS11_MODE" == "provider" ]]; then
    OPENSSL_CONF="$ca_conf" PKCS11_PIN="$pin" "$OPENSSL_BIN" ca -gencrl -out "$out_pem" -batch
  else
    OPENSSL_CONF="$ca_conf" PKCS11_PIN="$pin" "$OPENSSL_BIN" ca -gencrl -engine pkcs11 -out "$out_pem" -batch
  fi
  "$OPENSSL_BIN" crl -in "$out_pem" -outform DER -out "$out_der"
  unset pin
}

generate_root_crl_software() {
  local run_dir="$1" next_days="$2" out_pem="$3" out_der="$4" root_key_file="$5" dry_run="$6"
  local root_cert index serial crlnumber dbdir ca_conf
  root_cert="$(prompt_input "Path to Root certificate PEM for CRL signing" "${ROOTCA_CERT_PATH:-${run_dir}/certs/rootca.pem}")"

  if (( dry_run == 1 )); then
    info "[dry-run] Would generate local-key CRL with nextUpdate ${next_days} days."
    return
  fi

  dbdir="${run_dir}/tmp/ca-db"
  mkdir -p "$dbdir"
  index="${dbdir}/index.txt"
  serial="${dbdir}/serial"
  crlnumber="${dbdir}/crlnumber"
  : > "$index"
  echo "1000" > "$serial"
  echo "1000" > "$crlnumber"
  ca_conf="${run_dir}/configs/ca-crl-software.cnf"

  cat > "$ca_conf" <<CFG
[ca]
default_ca = CA_default
[CA_default]
database = ${index}
serial = ${serial}
crlnumber = ${crlnumber}
default_md = sha256
default_crl_days = ${next_days}
certificate = ${root_cert}
private_key = ${root_key_file}
unique_subject = no
[crl_ext]
authorityKeyIdentifier = keyid:always
CFG

  "$OPENSSL_BIN" ca -gencrl -config "$ca_conf" -out "$out_pem" -batch
  "$OPENSSL_BIN" crl -in "$out_pem" -outform DER -out "$out_der"
}

generate_cert_report() {
  local cert="$1" label="$2" out="$3" dry_run="$4"
  if (( dry_run == 1 )); then
    info "[dry-run] Would generate certificate report for ${label}."
    return
  fi
  {
    echo "${label} report"
    "$OPENSSL_BIN" x509 -in "$cert" -noout -fingerprint -sha256 -serial -subject -issuer -dates
  } > "$out"
}

generate_crl_report() {
  local crl="$1" out="$2" dry_run="$3"
  if (( dry_run == 1 )); then
    info "[dry-run] Would generate CRL report."
    return
  fi
  {
    echo "Root CRL report"
    "$OPENSSL_BIN" crl -in "$crl" -noout -fingerprint -sha256 -lastupdate -nextupdate
  } > "$out"
}
