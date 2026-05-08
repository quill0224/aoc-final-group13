"""Byte-equal parity vs Lab 2 reference (~/aoc-workspace/projects/lab2/src/).

Runs identical (conv, hardware, mapping) inputs through BOTH the Lab 2 reference
EyerissAnalyzer and the Final_project port. Asserts every numeric field matches.

Usage:
    python tests/test_lab2_baseline.py
    python tests/test_lab2_baseline.py --lab2-src /path/to/lab2/src
    python tests/test_lab2_baseline.py --max-mappings 10  # only check first N

What it catches:
    - Any formula drift between our port and the Lab 2 reference
    - Off-by-one in num_m / num_e / num_n / num_c / num_m_inner
    - PSUM_DATA_SIZE constant change (our port vs ref)
    - Wrong reuse factor in glb_access (`glb_reuse = num_m_inner`)
    - latency formula divergence (rounding, time-unit constants)

Notes:
    Lab 2 reference has a known bug at lab2/src/analytical_model/eyeriss.py:433
    where 'dram_write' key appears twice in summary, so 'dram_read' is missing.
    We compare underlying *_per_layer dicts (which are bug-free), not summary.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT))

# ----- CONFIG -----
# Default: ../lab2/src resolved relative to Final_project. Works on both host
# (/Users/.../aoc-workspace/projects/lab2/src) and inside the AOC docker
# (/home/$USER/projects/lab2/src).
CONFIG = {
    "lab2_src": str(PROJECT_ROOT.parent / "lab2" / "src"),
    "max_mappings_per_layer": 20,
}


def compare(label: str, ours: dict, ref: dict, ignore: tuple = ()) -> tuple[int, list]:
    """Return (fail_count, list of (key, ours, ref) tuples)."""
    fails = []
    common = (set(ours) & set(ref)) - set(ignore)
    for k in sorted(common):
        if ours[k] != ref[k]:
            fails.append((k, ours[k], ref[k]))
    return len(fails), fails


def main(lab2_src: str, max_mappings: int) -> int:
    # ----- Our port -----
    from analysis.eyeriss.eyeriss import (
        EyerissAnalyzer as OurAnalyzer,
        EyerissHardwareParam as OurHW,
    )
    from analysis.eyeriss.layer_info import (
        Conv2DShapeParam as OurConv,
        MaxPool2DShapeParam as OurPool,
    )
    from analysis.sweeps._common import FixedHardwareMapper, make_hardware, vgg8_conv_layers

    # ----- Lab 2 reference -----
    lab2_path = Path(lab2_src).resolve()
    if not lab2_path.is_dir():
        print(f"FAIL  lab2_src not found: {lab2_path}")
        return 1
    sys.path.insert(0, str(lab2_path))
    try:
        from analytical_model.eyeriss import (  # type: ignore
            EyerissAnalyzer as RefAnalyzer,
            EyerissHardwareParam as RefHW,
            EyerissMappingParam as RefMP,
        )
        from layer_info import (  # type: ignore
            Conv2DShapeParam as RefConv,
            MaxPool2DShapeParam as RefPool,
        )
    except ImportError as e:
        print(f"FAIL  could not import lab2 reference: {e}")
        return 1

    # ----- Hardware (must match on both sides) -----
    HW_KWARGS = dict(
        pe_array_h=6, pe_array_w=8,
        ifmap_spad_size=12, filter_spad_size=48, psum_spad_size=16,
        glb_size=64 * 1024, bus_bw=4, noc_bw=4,
    )

    fails = 0
    layers = vgg8_conv_layers()

    for i, (our_conv, our_pool) in enumerate(layers):
        layer_name = f"conv{i + 1}{'+pool' if our_pool else ''}"

        # Build matching reference shapes
        ref_conv = RefConv(**{k: getattr(our_conv, k) for k in ["N", "H", "W", "R", "S", "E", "F", "C", "M", "U", "P"]})
        ref_pool = RefPool(N=our_pool.N, kernel_size=our_pool.kernel_size, stride=our_pool.stride) if our_pool else None

        # Enumerate valid mappings via our mapper (mapper logic is identical, so the
        # same set is valid on both sides). Cap at max_mappings.
        our_hw_obj = make_hardware(
            pe_h=HW_KWARGS["pe_array_h"], pe_w=HW_KWARGS["pe_array_w"],
            glb_kib=HW_KWARGS["glb_size"] // 1024,
            bus_bw=HW_KWARGS["bus_bw"], noc_bw=HW_KWARGS["noc_bw"],
            ifmap_spad=HW_KWARGS["ifmap_spad_size"],
            filter_spad=HW_KWARGS["filter_spad_size"],
            psum_spad=HW_KWARGS["psum_spad_size"],
        )
        mapper = FixedHardwareMapper(name=layer_name, hardware=our_hw_obj)
        mapper.hardware = our_hw_obj  # see test_lab2_invariants.py for why
        mapper.analyzer.conv_shape = our_conv
        mapper.analyzer.maxpool_shape = our_pool
        valid = mapper.generate_mappings()
        if not valid:
            print(f"\n[{layer_name}]  no valid mappings (skip)")
            continue
        sample = valid[:max_mappings]

        # Set up both analyzers
        our_an = OurAnalyzer(name=layer_name, hardware_param=OurHW(**HW_KWARGS))
        our_an.conv_shape = our_conv
        our_an.maxpool_shape = our_pool

        ref_an = RefAnalyzer(name=layer_name, hardware_param=RefHW(**HW_KWARGS))
        ref_an.conv_shape = ref_conv
        ref_an.maxpool_shape = ref_pool

        layer_fails = 0
        for mp in sample:
            our_an.mapping = mp
            ref_an.mapping = RefMP(m=mp.m, n=mp.n, e=mp.e, p=mp.p, q=mp.q, r=mp.r, t=mp.t)

            # Compare every numeric output
            for label, ours_dict, ref_dict in [
                ("glb_usage_per_pass",   our_an.glb_usage_per_pass,   ref_an.glb_usage_per_pass),
                ("dram_access_per_layer", our_an.dram_access_per_layer, ref_an.dram_access_per_layer),
                ("glb_access_per_layer", our_an.glb_access_per_layer, ref_an.glb_access_per_layer),
                ("energy_per_layer",     our_an.energy_per_layer,     ref_an.energy_per_layer),
                ("power_per_layer",      our_an.power_per_layer,      ref_an.power_per_layer),
            ]:
                fc, diffs = compare(label, ours_dict, ref_dict)
                if fc:
                    layer_fails += fc
                    for k, ov, rv in diffs[:3]:
                        print(f"  [FAIL] {label}[{k!r}]  ours={ov}  ref={rv}  ({mp})")

            # Scalars
            if our_an.macs_per_layer != ref_an.macs_per_layer:
                layer_fails += 1
                print(f"  [FAIL] macs_per_layer  ours={our_an.macs_per_layer}  ref={ref_an.macs_per_layer}  ({mp})")
            if our_an.latency_per_layer != ref_an.latency_per_layer:
                layer_fails += 1
                print(f"  [FAIL] latency_per_layer  ours={our_an.latency_per_layer}  ref={ref_an.latency_per_layer}  ({mp})")
            if our_an.glb_size_legal != ref_an.glb_size_legal:
                layer_fails += 1
                print(f"  [FAIL] glb_size_legal  ours={our_an.glb_size_legal}  ref={ref_an.glb_size_legal}  ({mp})")

        marker = "OK  " if layer_fails == 0 else "FAIL"
        print(f"  [{marker}] {layer_name}  ({len(sample)} mappings × ~70 fields = {len(sample)*70} comparisons)")
        fails += layer_fails

    print()
    print("PASS  test_lab2_baseline" if fails == 0 else f"FAIL  test_lab2_baseline ({fails} field mismatch)")
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--lab2-src", default=CONFIG["lab2_src"])
    p.add_argument("--max-mappings", type=int, default=CONFIG["max_mappings_per_layer"])
    args = p.parse_args()
    sys.exit(main(args.lab2_src, args.max_mappings))
