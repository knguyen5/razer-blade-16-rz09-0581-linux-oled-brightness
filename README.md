# Razer Blade 16 RZ09-0581 Linux OLED brightness fix

Native-color software brightness tooling for the 2026 Razer Blade 16 model
`Blade 16 - RZ09-0581` with:

- Samsung `ATNA60HU06-0` 2560×1600 OLED panel
- Intel Panther Lake Xe integrated graphics
- NVIDIA RTX 5080 Laptop GPU
- Hyprland on Wayland

> [!WARNING]
> This repair installs a custom EDID firmware override, changes the kernel
> command line, and rebuilds initramfs images. It was developed and tested on
> **CachyOS** with Limine, `linux-cachyos-lts 6.18.42-1`,
> `linux-cachyos 7.1.8-1`, Hyprland 0.56.2, and hyprmoncfg 1.13.0.
> The installer refuses other laptop models by default and currently supports
> only mkinitcpio + Limine. Keep another bootable kernel and read the recovery
> instructions before installing.

## Symptoms

- Brightness keys and sliders update `/sys/class/backlight`, but the panel
  does not visibly dim.
- `intel_backlight` and `nvidia_0` accept values even though neither controls
  the display.
- `colormgr get-devices` returns no Hyprland display devices.
- `icc-brightness` times out while importing a profile through colord.
- Forcing generic HDR in Hyprland can produce crushed shadows, excessive
  saturation, or dull SDR colors.

## Why it happens

OLED pixels emit their own light, so this panel has no physical backlight.
The kernel backlight interfaces are inert compatibility devices. Dimming must
scale pixel luminance in the compositor.

The panel already advertises accurate primaries, PQ support, and luminance
limits in **DisplayID 2.0**:

- 500 nits full-screen luminance
- 1100 nits 10% peak luminance
- DCI-P3 / BT.2020 with SMPTE ST 2084

Linux DRM does not expose this metadata through the CTA-861 path expected by
compositors. The kernel therefore reports the connector as non-HDR-capable.
This fix preserves the original DisplayID blocks and adds an equivalent
CTA-861 extension with valid checksums.

Hyprland can then use:

- `cm = "hdredid"` for the panel's real primaries;
- 10-bit output;
- the sRGB transfer function for SDR content; and
- `sdrbrightness` for color-preserving software dimming.

## Automated system repair

Inspect the scripts before running them:

```bash
less ./razer-oled-brightness-fix.sh
less ./build-oled-hdr-edid.py
```

Collect read-only diagnostics:

```bash
./razer-oled-brightness-fix.sh diagnose |
  tee razer-oled-diagnostics.log
```

Preview privileged changes:

```bash
./razer-oled-brightness-fix.sh install --dry-run
```

Install the EDID override:

```bash
./razer-oled-brightness-fix.sh install
sudo reboot
```

The installer:

- verifies the exact DMI product and Samsung panel;
- validates every input and output EDID checksum;
- strips stale CTA extensions while preserving DisplayID data;
- generates the tested BT.2020/DCI-P3 and HDR static metadata;
- creates a timestamped backup under
  `/var/lib/razer-oled-brightness-fix`;
- installs `/lib/firmware/edid/oled-hdr.bin`;
- adds the firmware to mkinitcpio;
- adds `drm.edid_firmware=eDP-1:edid/oled-hdr.bin` to Limine; and
- rebuilds Limine entries and initramfs images.

`--force-unsupported-model` bypasses the DMI guard and is intentionally not
recommended.

## Verify after reboot

Confirm the kernel received the argument:

```bash
cat /proc/cmdline
```

The live EDID should be 512 bytes with three extension blocks:

```bash
stat -c '%s bytes' /sys/class/drm/card0-eDP-1/edid
edid-decode /sys/class/drm/card0-eDP-1/edid |
  grep -A12 'CTA-861 Extension'
```

Expected CTA data:

- `BT2020RGB`
- `HDR Static Metadata Data Block`
- content maximum near 1107 nits
- frame-average maximum near 497 nits

Check for firmware failures:

```bash
sudo journalctl -b -k --no-pager |
  grep -Ei 'edid|firmware'
```

`nvidia-modeset: Unable to read EDID for display device DP-0` can appear for
the inactive NVIDIA connector. The internal panel is Intel `eDP-1`; verify
the live EDID path above rather than treating the NVIDIA warning as failure.

## Configure Hyprland

Use this monitor configuration for the internal panel:

```lua
hl.monitor({
  output = "desc:Samsung Display Corp. ATNA60HU06-0",
  mode = "2560x1600@60.00",
  position = "0x0",
  scale = 1,
  bitdepth = 10,
  cm = "hdredid",
  sdrbrightness = 0.6,
  sdr_min_luminance = 0,
  sdr_max_luminance = 500,
  sdr_eotf = "srgb",
})
```

For hyprmoncfg, set these fields on the Samsung output in every saved profile:

```json
{
  "bitdepth": 10,
  "cm": "hdredid",
  "sdr_eotf": "srgb",
  "sdr_brightness": 0.6,
  "sdr_saturation": 1,
  "sdr_min_luminance": 0,
  "sdr_max_luminance": 500,
  "min_luminance": 0
}
```

Leave external-monitor entries unchanged. Apply the profile after editing:

```bash
hyprmoncfg apply laptop --confirm-timeout 0
```

Verify the live state:

```bash
hyprctl monitors -j |
  python3 -c 'import json,sys; m=json.load(sys.stdin)[0]; print({
      "format": m["currentFormat"],
      "color": m["colorManagementPreset"],
      "brightness": m["sdrBrightness"],
  })'
```

Expected format is `XRGB2101010` and color preset is `hdredid`.

## Install brightness controls

Install the helper:

```bash
install -Dm755 \
  hyprland/hypr-oled-brightness \
  ~/.local/bin/hypr-oled-brightness
```

Bind the laptop brightness keys in `hyprland.lua`:

```lua
hl.bind(
  "XF86MonBrightnessUp",
  hl.dsp.exec_cmd("hypr-oled-brightness up"),
  { locked = true, repeating = true, description = "Increase brightness" }
)
hl.bind(
  "XF86MonBrightnessDown",
  hl.dsp.exec_cmd("hypr-oled-brightness down"),
  { locked = true, repeating = true, description = "Decrease brightness" }
)
```

Reload Hyprland:

```bash
hyprctl reload
```

Manual controls:

```bash
hypr-oled-brightness down
hypr-oled-brightness up
hypr-oled-brightness set 40
hypr-oled-brightness max
```

The helper:

- adjusts from 5% to 100% in 5% steps;
- drops excess repeated key events instead of queueing them;
- updates every matching hyprmoncfg JSON profile;
- changes live Hyprland `sdrbrightness`; and
- mirrors the percentage to inert `intel_backlight` through logind so the
  desktop's normal brightness OSD appears.

The backlight write is only state synchronization. It does not physically
control the OLED.

## Rollback

Restore the latest pre-install system backup:

```bash
./razer-oled-brightness-fix.sh restore
sudo reboot
```

The restore action reinstates the previous mkinitcpio and Limine
configurations, restores or removes the firmware according to its original
state, and rebuilds the boot files.

Remove the user helper and restore your previous key bindings separately:

```bash
rm ~/.local/bin/hypr-oled-brightness
```

### Boot recovery

If the internal display does not light after installation:

1. highlight the normal entry in Limine;
2. edit its kernel command line;
3. remove
   `drm.edid_firmware=eDP-1:edid/oled-hdr.bin`;
4. boot once without the override; and
5. run the restore command above.

## Troubleshooting

### Colors are too saturated or shadows are crushed

Confirm all of these are present together:

```text
bitdepth = 10
cm = "hdredid"
sdr_eotf = "srgb"
sdr_min_luminance = 0
sdr_max_luminance = 500
```

Do not force generic `cm = "hdr"` for this panel. `hdredid` uses the actual
Samsung primaries supplied by the corrected EDID.

### Brightness briefly changes and resets

hyprmoncfg is reapplying a saved profile with different color settings.
Update every profile containing `samsung display corp.|atna60hu06-0`.
The supplied helper does this automatically after initial setup.

### Controls stop after holding a key

Use the current helper. Older versions derived the profile filename from
hyprmoncfg's transient `custom layout` status and queued repeated processes.
This version reads live Hyprland state and uses a nonblocking lock.

### `colormgr import-profile` times out

Hyprland does not register this display with colord. The EDID + compositor
path in this repository does not use colord or ICC profile import.

## Development checks

Run syntax, builder, and isolated install/restore checks:

```bash
bash -n razer-oled-brightness-fix.sh tests/integration.sh
sh -n hyprland/hypr-oled-brightness
python3 -m py_compile build-oled-hdr-edid.py
./tests/integration.sh
```

The integration test uses a temporary root and mock `limine-update`; it does
not modify the running system. EDID generation still requires the supported
panel to be connected.

## Credits

The EDID discovery and original CTA translation came from
[`visorcraft/razer_16_2026_linux_oled_brightness`](https://github.com/visorcraft/razer_16_2026_linux_oled_brightness).
That project targets KDE Plasma/KWin; this repository adds guarded Limine
installation, rollback, validation, and tested Hyprland/hyprmoncfg controls.

[`udifuchs/icc-brightness`](https://github.com/udifuchs/icc-brightness)
provided earlier Linux OLED software-dimming work. See
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for attribution details.

## License

MIT. See [`LICENSE`](LICENSE).
