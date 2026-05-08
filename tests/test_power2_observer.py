"""Unit test for PowerOfTwoObserver scale snapping (Lab 1).

Usage:
    python tests/test_power2_observer.py
    python tests/test_power2_observer.py --max-shift 4

What it catches:
    - scale not snapping to nearest 2^(-c)
    - max_shift_amount clip on tiny / huge scales
    - dtype/zero_point pairing (quint8 -> zp=128, qint8 -> zp=0)
    - calculate_qparams returning non-power-of-2 scale
"""
from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

# ----- CONFIG (override via CLI) -----
CONFIG = {
    "max_shift_amount": 8,  # Lab 1 spec: keep c within byte-shift hardware range
}


def main(max_shift: int) -> int:
    import torch  # noqa: F401  (used by PowerOfTwoObserver internals)

    from quantization.quantize import PowerOfTwoObserver

    fails = 0

    # ----- 1. scale_approximate snaps to 2^(-c) -----
    obs = PowerOfTwoObserver()
    cases = [
        # (input scale, expected output, comment)
        (0.5,    2 ** -1, "exact 2^-1"),
        (0.25,   2 ** -2, "exact 2^-2"),
        (0.125,  2 ** -3, "exact 2^-3"),
        (0.4,    2 ** -1, "round(-log2(0.4))=1 -> 0.5"),
        (0.6,    2 ** -1, "round(-log2(0.6))=1 -> 0.5"),
        (0.7,    2 ** -1, "round(-log2(0.7))=1 -> 0.5"),
        (0.8,    2 ** 0,  "round(-log2(0.8))=0 -> 1.0"),
        (1e-10,  2 ** -max_shift, "tiny scale clipped to +max_shift"),
        (1e10,   2 ** max_shift,  "huge scale clipped to -max_shift"),
        (0,      1.0,     "zero short-circuits to 1.0 (avoid -inf)"),
    ]
    for s, expected, comment in cases:
        got = obs.scale_approximate(s, max_shift_amount=max_shift)
        ok = math.isclose(got, expected, rel_tol=1e-9)
        marker = "OK  " if ok else "FAIL"
        print(f"  [{marker}] scale_approximate({s}) = {got}  expect {expected}  ({comment})")
        if not ok:
            fails += 1

    # ----- 2. calculate_qparams: dtype determines zero_point + scale stays power of 2 -----
    print()
    for dtype, expected_zp in [(torch.quint8, 128), (torch.qint8, 0)]:
        obs2 = PowerOfTwoObserver(dtype=dtype, qscheme=torch.per_tensor_symmetric)
        obs2.min_val = torch.tensor(-1.0)
        obs2.max_val = torch.tensor(1.0)
        scale, zp = obs2.calculate_qparams()

        ok_zp = int(zp.item()) == expected_zp
        marker = "OK  " if ok_zp else "FAIL"
        print(f"  [{marker}] dtype={dtype} -> zero_point={int(zp.item())}  expect {expected_zp}")
        fails += 0 if ok_zp else 1

        # scale must equal 2^-c for some integer c
        s = scale.item()
        c = -math.log2(s)
        is_pow2 = math.isclose(c, round(c), abs_tol=1e-9)
        marker = "OK  " if is_pow2 else "FAIL"
        print(f"  [{marker}] dtype={dtype} -> scale={s:.6f} = 2^-{round(c)}  (power-of-2 invariant)")
        fails += 0 if is_pow2 else 1

    print()
    print(f"PASS  test_power2_observer" if fails == 0 else f"FAIL  test_power2_observer ({fails} fail)")
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--max-shift", type=int, default=CONFIG["max_shift_amount"])
    args = p.parse_args()
    sys.exit(main(args.max_shift))
