#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

mkdir -p \
  "${test_root}/etc/default" \
  "${test_root}/var/lib" \
  "${test_root}/bin"

printf '%s\n' \
  '# previous docs mention /lib/firmware/edid/oled-hdr.bin' \
  'FILES=()' \
  'HOOKS=(base systemd autodetect kms filesystems)' \
  >"${test_root}/etc/mkinitcpio.conf"
printf '%s\n' \
  '# old note: drm.edid_firmware=eDP-1:edid/oled-hdr.bin' \
  'KERNEL_CMDLINE[default]+="quiet"' \
  >"${test_root}/etc/default/limine"
cp "${test_root}/etc/mkinitcpio.conf" "${test_root}/mkinitcpio.original"
cp "${test_root}/etc/default/limine" "${test_root}/limine.original"

cat >"${test_root}/bin/limine-update" <<EOF
#!/bin/sh
printf 'called\n' >>"${test_root}/limine-update.calls"
EOF
chmod 0755 "${test_root}/bin/limine-update"

export RAZER_OLED_TEST_ROOT="$test_root"
export RAZER_OLED_LIMINE_UPDATE="${test_root}/bin/limine-update"

"${REPO_ROOT}/razer-oled-brightness-fix.sh" install >/dev/null

test -s "${test_root}/lib/firmware/edid/oled-hdr.bin"
grep -Fq \
  'FILES=(/lib/firmware/edid/oled-hdr.bin)' \
  "${test_root}/etc/mkinitcpio.conf"
grep -Fq \
  'drm.edid_firmware=eDP-1:edid/oled-hdr.bin' \
  "${test_root}/etc/default/limine"
test -L "${test_root}/var/lib/razer-oled-brightness-fix/latest"
test -L "${test_root}/var/lib/razer-oled-brightness-fix/baseline"
baseline="$(
  readlink -f "${test_root}/var/lib/razer-oled-brightness-fix/baseline"
)"

exec 9>"${test_root}/var/lib/razer-oled-brightness-fix/operation.lock"
flock 9
if "${REPO_ROOT}/razer-oled-brightness-fix.sh" install >/dev/null 2>&1; then
  echo "concurrent install unexpectedly succeeded" >&2
  exit 1
fi
flock -u 9

"${REPO_ROOT}/razer-oled-brightness-fix.sh" install >/dev/null
latest="$(
  readlink -f "${test_root}/var/lib/razer-oled-brightness-fix/latest"
)"
test "$baseline" != "$latest"

"${REPO_ROOT}/razer-oled-brightness-fix.sh" restore >/dev/null

cmp -s \
  "${test_root}/mkinitcpio.original" \
  "${test_root}/etc/mkinitcpio.conf"
cmp -s \
  "${test_root}/limine.original" \
  "${test_root}/etc/default/limine"
test ! -e "${test_root}/lib/firmware/edid/oled-hdr.bin"
test "$(wc -l <"${test_root}/limine-update.calls")" -eq 3

echo "integration: repeat install, locking, and baseline restore passed"
