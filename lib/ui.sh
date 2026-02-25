#!/usr/bin/env bash
set -euo pipefail

UI_USE_WHIPTAIL=0
if command -v whiptail >/dev/null 2>&1; then
  UI_USE_WHIPTAIL=1
fi

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

banner() {
  printf '\n==== %s ====\n' "$*"
}

prompt_input() {
  local prompt="$1" default="$2" input=""
  if (( UI_USE_WHIPTAIL == 1 )); then
    input="$(whiptail --inputbox "$prompt" 12 80 "$default" 3>&1 1>&2 2>&3)" || die "Cancelled by user"
  else
    read -r -p "${prompt} [${default}]: " input
    input="${input:-$default}"
  fi
  printf '%s' "$input"
}

prompt_secret() {
  local prompt="$1" value
  if (( UI_USE_WHIPTAIL == 1 )); then
    value="$(whiptail --passwordbox "$prompt" 10 80 3>&1 1>&2 2>&3)" || die "Cancelled by user"
  else
    read -r -s -p "${prompt}: " value
    printf '\n' >&2
  fi
  printf '%s' "$value"
}

confirm_yes_no() {
  local prompt="$1" default="${2:-no}" ans
  if (( UI_USE_WHIPTAIL == 1 )); then
    if whiptail --yesno "$prompt" 10 80; then
      return 0
    else
      return 1
    fi
  fi
  read -r -p "${prompt} [${default}]: " ans
  ans="${ans:-$default}"
  [[ "$ans" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]
}

confirm_or_exit() {
  local prompt="$1"
  confirm_yes_no "$prompt" "no" || die "Operator declined: $prompt"
}

menu_select() {
  local title="$1"; shift
  if (( UI_USE_WHIPTAIL == 1 )); then
    whiptail --title "$title" --menu "$title" 20 90 10 "$@" 3>&1 1>&2 2>&3
  else
    local items=("$@")
    local i
    printf '%s\n' "$title"
    for (( i=0; i<${#items[@]}; i+=2 )); do
      printf '  %s) %s\n' "${items[i]}" "${items[i+1]}"
    done
    read -r -p "Choose option: " REPLY
    printf '%s' "$REPLY"
  fi
}

redact() {
  local s="$1"
  if [[ ${#s} -le 4 ]]; then
    printf '****'
  else
    printf '%s****%s' "${s:0:2}" "${s: -2}"
  fi
}

validate_positive_int() {
  local v="$1" label="$2"
  [[ "$v" =~ ^[0-9]+$ ]] || die "$label must be an integer"
  (( v > 0 )) || die "$label must be > 0"
}
