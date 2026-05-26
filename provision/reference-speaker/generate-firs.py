#!/usr/bin/env python3
"""Generate the reference virtual-speaker FIR filters for CamillaDSP.

The model is intentionally deterministic and dependency-light: it uses a
Brown/Duda one-pole/one-zero spherical-head shadow model for +/-30 degree
speakers, a Woodworth-style interaural delay, and a shared inverse of the
phantom-center response. The compensation keeps mono/center content tonally
flat while preserving the relative near-ear/far-ear speaker cues.
"""

from __future__ import annotations

from pathlib import Path
import math

import numpy as np


SAMPLE_RATE = 48_000
FFT_LENGTH = 32_768
TAPS = 2_048
COMMON_DELAY_SAMPLES = 512
SPEED_OF_SOUND = 343.0
HEAD_RADIUS = 0.0875
SPEAKER_AZIMUTH_DEG = 30.0
REGULARIZATION = 0.05


def brown_duda_shadow(alpha: float, freqs: np.ndarray) -> np.ndarray:
    """Return the Brown/Duda spherical-head shadow transfer function."""
    beta = 2.0 * SPEED_OF_SOUND / HEAD_RADIUS
    s = 1j * 2.0 * np.pi * freqs
    response = (alpha * s + beta) / (s + beta)
    response[0] = 1.0
    return response


def write_coefficients(path: Path, coeffs: np.ndarray) -> None:
    path.write_text("".join(f"{value:.18e}\n" for value in coeffs), encoding="ascii")


def main() -> None:
    out_dir = Path(__file__).resolve().parent
    freqs = np.fft.rfftfreq(FFT_LENGTH, 1.0 / SAMPLE_RATE)

    azimuth = math.radians(SPEAKER_AZIMUTH_DEG)
    interaural_delay = (HEAD_RADIUS / SPEED_OF_SOUND) * (
        azimuth + math.sin(azimuth)
    )

    ipsi = 0.5 * brown_duda_shadow(1.5, freqs)
    contra = 0.5 * brown_duda_shadow(0.5, freqs)
    contra *= np.exp(-1j * 2.0 * np.pi * freqs * interaural_delay)

    phantom_center = ipsi + contra
    center_inverse = np.conj(phantom_center) / (
        np.abs(phantom_center) ** 2 + REGULARIZATION**2
    )
    common_delay = np.exp(
        -1j * 2.0 * np.pi * freqs * COMMON_DELAY_SAMPLES / SAMPLE_RATE
    )

    ipsi_fir = np.fft.irfft(ipsi * center_inverse * common_delay, n=FFT_LENGTH)
    contra_fir = np.fft.irfft(contra * center_inverse * common_delay, n=FFT_LENGTH)

    write_coefficients(out_dir / "speaker_30_ipsi_fir.txt", ipsi_fir[:TAPS])
    write_coefficients(out_dir / "speaker_30_contra_fir.txt", contra_fir[:TAPS])


if __name__ == "__main__":
    main()
