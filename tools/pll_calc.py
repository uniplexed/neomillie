# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""Fractional PLL settings for pll_pocket (74.25 MHz reference -> MiSTer Neo Geo clock tree).

The VCO runs at 8 x CLK_96M (773.37 MHz AES, 768.000 MHz MVS). With 74.25 MHz as the
reference both modes share the integer part M = 10, which is what lets the MVS switch
rewrite only the fractional register (K, reconfig register 7). A 10 x CLK_96M VCO would
give M = 13 (AES) vs 12 (MVS) and need a second register write. The Cyclone V PLL
generator also rejects a VCO below 600 MHz, so a /2 tap is not an option.
Counters: C0 /8 (CLK_96M), C1 /16 (CLK_48M), C2 and C3 /128 (CLK_PIX, C3 is +90 degrees
= 32 VCO cycles in both modes).
"""
import sys

REF_HZ = 74_250_000
CLK96_HZ = {"aes": 96_671_316, "mvs": 96_000_000}
C0, C1, C_PIX = 8, 16, 128


def settings(mode):
    m_frac = CLK96_HZ[mode] * C0 / REF_HZ
    m = int(m_frac)
    k = round((m_frac - m) * 2**32)
    return m, k


def clk96_hz(m, k):
    return REF_HZ * (m + k / 2**32) / C0


def main():
    ms = set()
    for mode in ("aes", "mvs"):
        m, k = settings(mode)
        ms.add(m)
        f = clk96_hz(m, k)
        print(f"{mode}: M={m} K={k} CLK_96M={f:.3f} Hz CLK_48M={f / 2:.3f} Hz "
              f"CLK_PIX={f / 16:.3f} Hz")
        assert abs(f - CLK96_HZ[mode]) <= 1.0, f"{mode}: {f} Hz out of tolerance"
    assert len(ms) == 1, "integer M must match in both modes (K-only reconfiguration)"
    print("OK")


if __name__ == "__main__":
    sys.exit(main())
