# Third-party notices

## Razer Blade 16 OLED EDID research

The EDID translation in `build-oled-hdr-edid.py` is derived from
[`visorcraft/razer_16_2026_linux_oled_brightness`](https://github.com/visorcraft/razer_16_2026_linux_oled_brightness),
copyright 2026 VisorCraft LLC and licensed under the MIT License.

That project identified that the Samsung ATNA60HU06-0 advertises its HDR and
colorimetry capabilities inside DisplayID 2.0 data. Linux DRM does not expose
those capabilities to compositors expecting a CTA-861 extension, so the
equivalent metadata must be added in CTA-861 form.

This repository retains the same panel luminance and colorimetry values while
adding hardware guards, validation, reversible installation, and Hyprland
integration.

## ICC brightness lineage

[`udifuchs/icc-brightness`](https://github.com/udifuchs/icc-brightness)
demonstrated software dimming for OLED displays through ICC video-card gamma
tables. It is not bundled here because Hyprland does not expose the colord
display integration required by that implementation.
