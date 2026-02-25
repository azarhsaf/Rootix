#!/usr/bin/env bash
set -euo pipefail

load_defaults_profile() {
  local defaults_file="$1"
  [[ -f "$defaults_file" ]] || die "Missing defaults profile: $defaults_file"
  # shellcheck disable=SC1090
  source "$defaults_file"

  : "${DEFAULT_ROOT_VALIDITY_DAYS:?Missing DEFAULT_ROOT_VALIDITY_DAYS in defaults.env}"
  : "${DEFAULT_ISSUING_VALIDITY_DAYS:?Missing DEFAULT_ISSUING_VALIDITY_DAYS in defaults.env}"
  : "${DEFAULT_CRL_NEXT_DAYS:?Missing DEFAULT_CRL_NEXT_DAYS in defaults.env}"
  : "${DEFAULT_COUNTRY:?Missing DEFAULT_COUNTRY in defaults.env}"
}

copy_profiles_used() {
  local profile_dir="$1" run_dir="$2" dry_run="$3"
  if (( dry_run == 1 )); then
    info "[dry-run] Would copy profiles into ${run_dir}/profiles_used"
    return
  fi
  cp -a "$profile_dir"/*.cnf "$profile_dir"/*.env "${run_dir}/profiles_used/"
}
