#!/usr/bin/env python3
"""Add CTA-861 HDR metadata to the Samsung ATNA60HU06-0 EDID.

Derived from visorcraft/razer_16_2026_linux_oled_brightness, copyright
2026 VisorCraft LLC, under the MIT License.
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

SUPPORTED_PANEL = b"ATNA60HU06-0"
DEFAULT_INPUT = Path("/sys/class/drm/card0-eDP-1/edid")
DEFAULT_OUTPUT = Path("/tmp/oled-hdr.bin")


def fail(message: str) -> None:
    raise SystemExit(f"error: {message}")


def validate_blocks(data: bytes, label: str) -> None:
    if len(data) < 128 or len(data) % 128:
        fail(f"{label} length {len(data)} is not a complete EDID")
    for index in range(0, len(data), 128):
        if sum(data[index : index + 128]) & 0xFF:
            fail(f"{label} block {index // 128} has an invalid checksum")


def luminance_code(nits: int) -> int:
    return min(255, max(0, round(32 * math.log2(nits / 50))))


def build(source: bytes) -> bytes:
    validate_blocks(source, "input")
    if SUPPORTED_PANEL not in source:
        fail("input EDID is not for Samsung ATNA60HU06-0")

    extension_count = source[126]
    expected_size = 128 * (extension_count + 1)
    if len(source) < expected_size:
        fail(
            f"input declares {extension_count} extensions but has only "
            f"{len(source)} bytes"
        )

    edid = bytearray(source[:128])
    kept_extensions = 0
    for index in range(extension_count):
        offset = 128 + index * 128
        block = source[offset : offset + 128]
        if block[0] == 0x02:
            continue
        edid.extend(block)
        kept_extensions += 1

    cta = bytearray(128)
    cta[0] = 0x02  # CTA-861 extension
    cta[1] = 0x03  # revision 3
    cta[2] = 0x0F  # data blocks occupy bytes 4 through 14
    cta[3] = 0x00  # no native detailed modes or feature flags

    # Colorimetry: BT.2020 RGB/YCC/cYCC and DCI-P3 RGB D65.
    cta[4] = (0x07 << 5) | 0x03
    cta[5] = 0x05
    cta[6] = 0xE0
    cta[7] = 0x80

    # HDR Static Metadata: SDR, traditional HDR, PQ, descriptor type 1.
    cta[8] = (0x07 << 5) | 0x06
    cta[9] = 0x06
    cta[10] = 0x07
    cta[11] = 0x01
    cta[12] = luminance_code(1100)
    cta[13] = luminance_code(500)
    cta[14] = 0x10
    cta[127] = (-sum(cta[:127])) & 0xFF

    edid[126] = kept_extensions + 1
    edid[127] = (-sum(edid[:127])) & 0xFF
    result = bytes(edid) + bytes(cta)
    validate_blocks(result, "output")
    return result


def main() -> None:
    output = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_OUTPUT
    source_path = Path(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_INPUT
    if len(sys.argv) > 3:
        fail(f"usage: {Path(sys.argv[0]).name} [OUTPUT [INPUT]]")
    if not source_path.is_file():
        fail(f"EDID source does not exist: {source_path}")

    source = source_path.read_bytes()
    result = build(source)
    output.write_bytes(result)
    print(
        f"input={len(source)} bytes output={len(result)} bytes "
        f"extensions={result[126]} peak=1107 nits average=497 nits"
    )
    print(f"wrote {output}")


if __name__ == "__main__":
    main()
