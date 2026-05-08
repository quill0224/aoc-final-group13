"""Sanity invariants for Eyeriss analytical model (Lab 2 / Final_project port).

Usage:
    python tests/test_lab2_invariants.py
    python tests/test_lab2_invariants.py --pe-h 16 --pe-w 16 --glb-kib 128 --bus-bw 8

What it catches:
    - macs_per_layer formula drifts (e.g. forgets a dim) - tested across all 5 VGG-8 layers
    - Mapper returns mappings that violate GLB capacity
    - bound_by string disagrees with peak_perf / peak_bw vs OI logic
    - glb_usage_per_pass['total'] != sum of components
    - peak_performance != pe_h * pe_w
    - maxpool layer ofmap_write not shrunk by k^2 (so summary['dram_write'] not affected by pool_k)
    - summary's 'intensity' / 'peak_performance' / 'peak_bandwidth' / 'bound_by' columns
      drift from the underlying property values
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

# ----- CONFIG -----
CONFIG = {
    "pe_h": 6,
    "pe_w": 8,
    "glb_kib": 64,
    "bus_bw": 4,
    "noc_bw": 4,
    "max_mappings_to_check": 200,  # cap mapping enumeration per layer
}


def main(pe_h: int, pe_w: int, glb_kib: int, bus_bw: int, noc_bw: int, max_mappings: int) -> int:
    from analysis.eyeriss.eyeriss import EyerissAnalyzer
    from analysis.eyeriss.layer_info import Conv2DShapeParam, MaxPool2DShapeParam
    from analysis.sweeps._common import FixedHardwareMapper, make_hardware, vgg8_conv_layers

    hw = make_hardware(pe_h=pe_h, pe_w=pe_w, glb_kib=glb_kib, bus_bw=bus_bw, noc_bw=noc_bw)
    layers = vgg8_conv_layers()
    fails = 0

    # ----- 1. Static invariants on hardware -----
    expected_peak = pe_h * pe_w
    a = EyerissAnalyzer(name="static", hardware_param=hw)
    a.conv_shape, a.maxpool_shape = layers[0]
    print(f"\n[Hardware invariants]  pe={pe_h}x{pe_w}, glb={glb_kib}KiB, bus={bus_bw}B/cy")
    ok = a.peak_performance == expected_peak
    print(f"  [{'OK  ' if ok else 'FAIL'}] peak_performance == pe_h*pe_w  ({a.peak_performance} == {expected_peak})")
    fails += 0 if ok else 1

    ok = a.peak_bandwidth == bus_bw
    print(f"  [{'OK  ' if ok else 'FAIL'}] peak_bandwidth == bus_bw  ({a.peak_bandwidth} == {bus_bw})")
    fails += 0 if ok else 1

    # ----- 2. Per-layer invariants -----
    for i, (conv, pool) in enumerate(layers):
        layer_name = f"conv{i + 1}{'+pool' if pool else ''}"
        print(f"\n[{layer_name}]  shape={conv}")
        mapper = FixedHardwareMapper(name=layer_name, hardware=hw)
        mapper.hardware = hw  # generate_mappings() needs hardware set; normally done in run()
        mapper.analyzer.conv_shape = conv
        mapper.analyzer.maxpool_shape = pool
        valid = mapper.generate_mappings()
        if not valid:
            print(f"  [SKIP] no valid mappings (hardware too constrained for this layer)")
            continue

        # 2a. macs_per_layer is mapping-independent
        macs_set = set()
        for m in valid[:max_mappings]:
            mapper.analyzer.mapping = m
            macs_set.add(mapper.analyzer.macs_per_layer)
        ok = len(macs_set) == 1
        expected_macs = conv.N * conv.M * conv.E * conv.F * conv.C * conv.R * conv.S
        ok_value = ok and macs_set.pop() == expected_macs
        print(f"  [{'OK  ' if ok_value else 'FAIL'}] macs_per_layer = N*M*E*F*C*R*S = {expected_macs:,} (mapping-invariant)")
        fails += 0 if ok_value else 1

        # 2b. Every valid mapping respects GLB capacity (validate() and glb_size_legal agree)
        violations = []
        for m in valid[:max_mappings]:
            mapper.analyzer.mapping = m
            usage = mapper.analyzer.glb_usage_per_pass["total"]
            if usage > hw.glb_size:
                violations.append((m, usage))
        ok = len(violations) == 0
        print(f"  [{'OK  ' if ok else 'FAIL'}] all {min(len(valid), max_mappings)} valid mappings respect GLB <= {hw.glb_size}B")
        if not ok:
            for m, u in violations[:3]:
                print(f"      VIOLATION: {m}  usage={u}B")
            fails += 1

        # 2c. glb_usage_per_pass['total'] == sum of components
        sample = valid[0]
        mapper.analyzer.mapping = sample
        u = mapper.analyzer.glb_usage_per_pass
        component_sum = u["ifmap"] + u["filter"] + u["bias"] + u["psum"]
        ok = u["total"] == component_sum
        print(f"  [{'OK  ' if ok else 'FAIL'}] glb_usage['total'] == ifmap+filter+bias+psum  ({u['total']} == {component_sum})")
        fails += 0 if ok else 1

        # 2d. bound_by ↔ OI vs balance_point
        oi = mapper.analyzer.operational_intensity
        balance = pe_h * pe_w / bus_bw
        if oi > balance:
            expected_bound = "compute"
        elif oi < balance:
            expected_bound = "memory"
        else:
            expected_bound = "balanced"
        actual_bound = mapper.analyzer.bound_by
        ok = actual_bound == expected_bound
        print(f"  [{'OK  ' if ok else 'FAIL'}] bound_by  OI={oi:.2f} vs balance={balance:.2f}  -> {actual_bound}  (expect {expected_bound})")
        fails += 0 if ok else 1

        # 2e. summary columns agree with property values
        s = mapper.analyzer.summary
        checks = [
            ("intensity",        s["intensity"],        oi),
            ("peak_performance", s["peak_performance"], expected_peak),
            ("peak_bandwidth",   s["peak_bandwidth"],   bus_bw),
            ("bound_by",         s["bound_by"],         actual_bound),
            ("macs",             s["macs"],             expected_macs),
        ]
        for key, got, want in checks:
            ok = got == want
            print(f"  [{'OK  ' if ok else 'FAIL'}] summary[{key!r}] = {got}  expect {want}")
            fails += 0 if ok else 1

        # 2f. Maxpool layer: ofmap_write shrunk by k^2 (vs hypothetical no-pool)
        if pool is not None:
            mapper.analyzer.maxpool_shape = None
            no_pool_ofmap = mapper.analyzer.dram_access_per_layer["ofmap_write"]
            mapper.analyzer.maxpool_shape = pool
            with_pool_ofmap = mapper.analyzer.dram_access_per_layer["ofmap_write"]
            expected_ratio = pool.kernel_size ** 2
            ok = no_pool_ofmap == with_pool_ofmap * expected_ratio
            print(f"  [{'OK  ' if ok else 'FAIL'}] maxpool ofmap_write shrunk by k^2={expected_ratio} "
                  f"({no_pool_ofmap} -> {with_pool_ofmap})")
            fails += 0 if ok else 1

    print()
    print("PASS  test_lab2_invariants" if fails == 0 else f"FAIL  test_lab2_invariants ({fails} fail)")
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--pe-h",   type=int, default=CONFIG["pe_h"])
    p.add_argument("--pe-w",   type=int, default=CONFIG["pe_w"])
    p.add_argument("--glb-kib", type=int, default=CONFIG["glb_kib"])
    p.add_argument("--bus-bw", type=int, default=CONFIG["bus_bw"])
    p.add_argument("--noc-bw", type=int, default=CONFIG["noc_bw"])
    p.add_argument("--max-mappings", type=int, default=CONFIG["max_mappings_to_check"])
    args = p.parse_args()
    sys.exit(main(args.pe_h, args.pe_w, args.glb_kib, args.bus_bw, args.noc_bw, args.max_mappings))
