#!/usr/bin/env bash
set -Eeuo pipefail

readonly PROGRAM="${0##*/}"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SUPPORTED_PRODUCT="Blade 16 - RZ09-0581"
readonly SUPPORTED_PANEL="ATNA60HU06-0"
readonly BUILDER="${SCRIPT_DIR}/build-oled-hdr-edid.py"
readonly TEST_ROOT="${RAZER_OLED_TEST_ROOT:-}"
readonly FIRMWARE_PATH="/lib/firmware/edid/oled-hdr.bin"
readonly FIRMWARE="${TEST_ROOT}${FIRMWARE_PATH}"
readonly MKINITCPIO_CONFIG="${TEST_ROOT}/etc/mkinitcpio.conf"
readonly LIMINE_CONFIG="${TEST_ROOT}/etc/default/limine"
readonly STATE_ROOT="${TEST_ROOT}/var/lib/razer-oled-brightness-fix"
readonly LIMINE_UPDATE="${RAZER_OLED_LIMINE_UPDATE:-limine-update}"

ACTION="diagnose"
DRY_RUN=0
FORCE_MODEL=0
LAST_BACKUP=""
EDID_PATH=""
CONNECTOR=""

info() { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<EOF
Usage: ${PROGRAM} [diagnose|install|restore] [options]

Actions:
  diagnose                  Collect read-only OLED, EDID, and compositor data
  install                   Install the guarded EDID firmware override
  restore                   Restore the most recent pre-install backup

Options:
  --dry-run                 Print privileged changes without applying them
  --force-unsupported-model Bypass the exact DMI model guard
  -h, --help                Show this help
EOF
}

while (($#)); do
  case "$1" in
    diagnose|install|restore) ACTION="$1" ;;
    --dry-run) DRY_RUN=1 ;;
    --force-unsupported-model) FORCE_MODEL=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

print_command() {
  printf 'DRY-RUN:'
  printf ' %q' "$@"
  printf '\n'
}

run_root() {
  if ((DRY_RUN)); then
    print_command sudo "$@"
    return
  fi
  if [[ -n "$TEST_ROOT" ]] || ((EUID == 0)); then
    "$@"
  else
    have sudo || die "sudo is required"
    sudo "$@"
  fi
}

capture_root() {
  if [[ -n "$TEST_ROOT" ]] || ((EUID == 0)); then
    "$@"
  else
    have sudo || die "sudo is required"
    sudo "$@"
  fi
}

read_product() {
  if [[ -r /sys/class/dmi/id/product_name ]]; then
    tr -d '\n' </sys/class/dmi/id/product_name
  else
    printf 'unknown'
  fi
}

find_panel_edid() {
  local path parent
  shopt -s nullglob
  for path in /sys/class/drm/card*-eDP-*/edid; do
    # sysfs reports EDID file size as zero even when reads return full data.
    [[ -r "$path" ]] || continue
    if grep -aFq "$SUPPORTED_PANEL" "$path"; then
      EDID_PATH="$path"
      parent="${path%/edid}"
      CONNECTOR="${parent##*/}"
      CONNECTOR="${CONNECTOR#*-}"
      break
    fi
  done
  shopt -u nullglob
  [[ -n "$EDID_PATH" ]] || die "could not find a connected ${SUPPORTED_PANEL} EDID"
}

check_model() {
  local product
  product="$(read_product)"
  if [[ "$product" != "$SUPPORTED_PRODUCT" ]] && ((FORCE_MODEL == 0)); then
    die "unsupported product '${product}'; expected '${SUPPORTED_PRODUCT}'"
  fi
  if [[ "$product" != "$SUPPORTED_PRODUCT" ]]; then
    warn "model guard overridden for '${product}'"
  fi
}

require_install_environment() {
  local command
  for command in python3 edid-decode "$LIMINE_UPDATE"; do
    have "$command" || die "required command not found: $command"
  done
  [[ -x "$BUILDER" ]] || die "EDID builder is missing or not executable: $BUILDER"
  [[ -r "$MKINITCPIO_CONFIG" ]] || die "missing $MKINITCPIO_CONFIG"
  [[ -r "$LIMINE_CONFIG" ]] || die "missing $LIMINE_CONFIG"
  [[ -e /sys/module/drm/parameters/edid_firmware ]] ||
    die "kernel does not expose drm.edid_firmware"
}

make_backup() {
  local stamp state_file firmware_existed=0
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  LAST_BACKUP="${STATE_ROOT}/backup-${stamp}"
  state_file="$(mktemp)"

  [[ -e "$FIRMWARE" ]] && firmware_existed=1
  printf 'FIRMWARE_EXISTED=%d\n' "$firmware_existed" >"$state_file"

  info "Creating backup at ${LAST_BACKUP}"
  run_root mkdir -p "$LAST_BACKUP"
  run_root cp -a "$MKINITCPIO_CONFIG" "${LAST_BACKUP}/mkinitcpio.conf"
  run_root cp -a "$LIMINE_CONFIG" "${LAST_BACKUP}/limine"
  if ((firmware_existed)); then
    run_root cp -a "$FIRMWARE" "${LAST_BACKUP}/oled-hdr.bin"
  fi
  run_root install -m 600 "$state_file" "${LAST_BACKUP}/state"
  run_root ln -sfn "$LAST_BACKUP" "${STATE_ROOT}/latest"
  rm -f "$state_file"
}

append_initramfs_file() {
  run_root python3 - "$MKINITCPIO_CONFIG" "$FIRMWARE_PATH" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
firmware = sys.argv[2]
text = path.read_text()
if firmware in text:
    raise SystemExit(0)
pattern = re.compile(r"^FILES=\(([^)]*)\)$", re.MULTILINE)
match = pattern.search(text)
if not match:
    raise SystemExit(f"error: cannot parse FILES=() in {path}")
current = match.group(1).strip()
replacement = f"FILES=({current + ' ' if current else ''}{firmware})"
path.write_text(pattern.sub(replacement, text, count=1))
PY
}

append_limine_argument() {
  local argument="drm.edid_firmware=${CONNECTOR}:edid/oled-hdr.bin"
  run_root python3 - "$LIMINE_CONFIG" "$argument" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
argument = sys.argv[2]
text = path.read_text()
if argument in text:
    raise SystemExit(0)
pattern = re.compile(
    r'^(KERNEL_CMDLINE\[default\]\+?=")([^"]*)(")$',
    re.MULTILINE,
)
match = pattern.search(text)
if not match:
    raise SystemExit(f"error: cannot parse default kernel command line in {path}")
arguments = match.group(2).strip()
replacement = f"{match.group(1)}{arguments} {argument}{match.group(3)}"
path.write_text(pattern.sub(replacement, text, count=1))
PY
}

diagnose() {
  local product firmware_state="missing" override_state="absent"
  product="$(read_product)"
  find_panel_edid
  [[ -r "$FIRMWARE" ]] && firmware_state="present"
  if [[ -r /proc/cmdline ]] &&
    grep -Fq "drm.edid_firmware=${CONNECTOR}:edid/oled-hdr.bin" /proc/cmdline; then
    override_state="active"
  fi

  cat <<EOF
Product:       ${product}
Kernel:        $(uname -r)
Panel:         ${SUPPORTED_PANEL}
EDID path:     ${EDID_PATH}
Connector:     ${CONNECTOR}
Firmware:      ${firmware_state}
EDID override: ${override_state}
EOF

  printf '\nEDID summary:\n'
  python3 - "$EDID_PATH" <<'PY'
import pathlib
import sys

data = pathlib.Path(sys.argv[1]).read_bytes()
checksums = [
    sum(data[offset : offset + 128]) & 0xFF
    for offset in range(0, len(data), 128)
]
print(
    f"{len(data)} bytes, extensions={data[126]}, "
    f"block checksums={','.join(map(str, checksums))}"
)
PY
  edid-decode "$EDID_PATH" 2>/dev/null |
    awk '
      /Block [0-9]+, (DisplayID|CTA-861)/ ||
      /Native Maximum Luminance/ ||
      /Colorimetry Data Block/ ||
      /HDR Static Metadata Data Block/ ||
      /Desired content max luminance/
    '

  printf '\nConfiguration:\n'
  awk '/^FILES=/{print FILENAME ": " $0}' "$MKINITCPIO_CONFIG" 2>/dev/null || true
  awk '/^KERNEL_CMDLINE\[default\]/{print FILENAME ": " $0}' "$LIMINE_CONFIG" 2>/dev/null || true

  if have hyprctl && hyprctl monitors -j >/dev/null 2>&1; then
    printf '\nHyprland panel state:\n'
    python3 - "$SUPPORTED_PANEL" <<'PY'
import json
import subprocess
import sys

panel = sys.argv[1]
monitors = json.loads(subprocess.check_output(["hyprctl", "monitors", "-j"]))
for monitor in monitors:
    if panel in monitor.get("description", ""):
        fields = (
            "name",
            "currentFormat",
            "colorManagementPreset",
            "sdrBrightness",
            "sdrMinLuminance",
            "sdrMaxLuminance",
        )
        for field in fields:
            print(f"{field}: {monitor.get(field)}")
        break
PY
  fi
}

install_fix() {
  local generated decoded
  check_model
  require_install_environment
  find_panel_edid
  generated="$(mktemp --suffix=.bin)"
  decoded="$(mktemp)"
  trap 'rm -f "${generated:-}" "${decoded:-}"' EXIT

  info "Building guarded EDID override from ${EDID_PATH}"
  python3 "$BUILDER" "$generated" "$EDID_PATH"
  edid-decode "$generated" >"$decoded"
  grep -Fq "CTA-861 Extension Block" "$decoded" ||
    die "generated EDID lacks CTA-861 extension"
  grep -Fq "HDR Static Metadata Data Block" "$decoded" ||
    die "generated EDID lacks HDR metadata"
  grep -Fq "BT2020RGB" "$decoded" ||
    die "generated EDID lacks BT.2020 colorimetry"

  make_backup
  info "Installing ${FIRMWARE}"
  run_root install -D -m 644 "$generated" "$FIRMWARE"
  append_initramfs_file
  append_limine_argument
  info "Rebuilding Limine entries and initramfs images"
  run_root "$LIMINE_UPDATE"

  info "Installation complete; backup: ${LAST_BACKUP}"
  warn "Reboot is required. If the internal screen fails, remove the drm.edid_firmware argument from the Limine boot entry."
}

restore_latest() {
  local backup state firmware_existed=0
  backup="$(capture_root readlink -f "${STATE_ROOT}/latest" 2>/dev/null || true)"
  [[ -n "$backup" ]] || die "no backup found under ${STATE_ROOT}"
  state="${backup}/state"
  firmware_existed="$(
    capture_root awk -F= '
      $1 == "FIRMWARE_EXISTED" && $2 ~ /^[01]$/ { print $2; found=1 }
      END { if (!found) exit 1 }
    ' "$state"
  )" || die "backup state is missing or invalid: ${state}"

  info "Restoring ${backup}"
  run_root cp -a "${backup}/mkinitcpio.conf" "$MKINITCPIO_CONFIG"
  run_root cp -a "${backup}/limine" "$LIMINE_CONFIG"
  if [[ "$firmware_existed" == 1 ]]; then
    run_root cp -a "${backup}/oled-hdr.bin" "$FIRMWARE"
  else
    run_root rm -f "$FIRMWARE"
  fi
  info "Rebuilding Limine entries and initramfs images"
  run_root "$LIMINE_UPDATE"
  warn "Restore complete; reboot is required"
}

case "$ACTION" in
  diagnose) diagnose ;;
  install) install_fix ;;
  restore) restore_latest ;;
esac
