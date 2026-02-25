#!/usr/bin/env bash
set -euo pipefail

LUNACM_BIN="${LUNACM_BIN:-$(command -v lunacm || true)}"
LUNA_PKCS11_MODULE=""

ensure_lunacm() {
  [[ -n "$LUNACM_BIN" ]] || die "lunacm not found. Install Luna Client offline before proceeding."
}

detect_luna_module() {
  local candidates=(
    "/usr/safenet/lunaclient/lib/libCryptoki2.so"
    "/usr/safenet/lunaclient/lib/libCryptoki2_64.so"
    "/usr/lib64/libCryptoki2.so"
  )
  local c
  for c in "${candidates[@]}"; do
    if [[ -f "$c" ]]; then
      LUNA_PKCS11_MODULE="$c"
      export LUNA_PKCS11_MODULE
      info "Detected Luna PKCS#11 module: ${LUNA_PKCS11_MODULE}"
      return
    fi
  done
  LUNA_PKCS11_MODULE="$(prompt_input "Enter full path to Luna PKCS#11 module (libCryptoki2.so)" "")"
  [[ -f "$LUNA_PKCS11_MODULE" ]] || die "Invalid PKCS#11 module path: $LUNA_PKCS11_MODULE"
  export LUNA_PKCS11_MODULE
}

lunacm_capture() {
  local cmd="$1"
  "$LUNACM_BIN" <<LUNA_EOF
${cmd}
exit
LUNA_EOF
}

show_hsm_status() {
  local dry_run="$1"
  ensure_lunacm
  if (( dry_run == 1 )); then
    info "[dry-run] Would run lunacm status commands."
    return
  fi
  local out
  out="$(lunacm_capture "hsm show")"
  printf '%s\n' "$out" | sed -E 's/(Password|PIN|challenge|secret).*/[REDACTED]/Ig'
  out="$(lunacm_capture "slot list")"
  printf '%s\n' "$out" | sed -E 's/(Password|PIN|challenge|secret).*/[REDACTED]/Ig'
}

choose_partition_flow() {
  local choice
  choice="$(menu_select "Partition flow" \
      "new" "A) New partition initialization flow (guided)" \
      "existing" "B) Use existing partition")"
  printf '%s' "$choice"
}

guided_partition_initialization() {
  local dry_run="$1"
  banner "Guided Luna Partition Initialization"
  cat <<'GUIDE'
The exact luna commands differ across firmware/policies.
Run each command manually in a separate terminal and return to confirm.
Suggested sequence (placeholder):
  1) lunacm> hsm login
  2) lunacm> partition create -label <LABEL> -serial <HSM_SERIAL>
  3) lunacm> partition assignpolicy ...
  4) lunacm> slot list
GUIDE
  confirm_or_exit "Have you completed partition initialization and verified slot visibility?"
  if (( dry_run == 0 )); then
    show_hsm_status 0
  fi
}

guided_mon_setup() {
  local m="$1" n="$2" dry_run="$3"
  banner "M-of-N setup guidance"
  cat <<GUIDE
Requested M-of-N: M=${m}, N=${n}
For SO (Security Officer) setup and split knowledge ceremony:
  - Use lunacm role/user commands per your Luna firmware guide.
  - Ensure SO credential workflow reflects M-of-N policy.
  - Record operator and witness identities in ceremony minutes.
Generic placeholder sequence:
  1) lunacm> role init -role SO ...
  2) lunacm> role configure -mon M=${m} -non N=${n} ...
  3) lunacm> role init -role CO ...   # "blue user"
  4) lunacm> slot list
GUIDE
  confirm_or_exit "Did you complete SO/CO role setup and verify access?"
  if (( dry_run == 0 )); then
    show_hsm_status 0
  fi
}

guided_additional_user() {
  local dry_run="$1"
  banner "Add additional HSM user (guided)"
  cat <<'GUIDE'
Run vendor-approved lunacm commands manually. Example placeholder:
  1) lunacm> slot login -c CO
  2) lunacm> role create -name <NEW_USER> -type CO
  3) lunacm> role list
Do NOT enter credentials into this script.
GUIDE
  confirm_or_exit "Have you executed user creation commands and verified with role list?"
  if (( dry_run == 0 )); then
    show_hsm_status 0
  fi
}

create_hsm_keypair() {
  local label="$1" dry_run="$2"
  ensure_lunacm
  local token_label
  token_label="$(prompt_input "Enter target token/partition label" "")"
  local co_pin
  co_pin="$(prompt_secret "Enter CO PIN for key generation (input hidden; not stored)")"
  info "Using CO PIN: $(redact "$co_pin")"
  unset co_pin

  if (( dry_run == 1 )); then
    info "[dry-run] Would create non-exportable keypair label=${label} on token=${token_label}."
    return
  fi

  local cmd
  cmd="slot login -label ${token_label} -password <REDACTED>; partition contents"
  warn "Vendor command syntax may vary. Use lunacm manual keypair command if required."
  info "Expected post-condition: private key object with label ${label} exists and is non-exportable."
  confirm_or_exit "Have you executed the Luna keypair generation command manually and verified the key label exists?"
}
