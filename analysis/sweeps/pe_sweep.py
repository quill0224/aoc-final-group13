"""PE-array sweep: response to proposal review concern #1.

Runs the analytical model on VGG-8's 5 conv layers across multiple PE-array
sizes (course baseline 6x8, proposal target 16x16, plus alternatives) and
records latency / utilization / energy / bound_by per layer.

Output: analysis/results/pe_sweep_<ts>/{output.csv, output.md, latency.png}

Usage:
    python -m analysis.sweeps.pe_sweep
    python -m analysis.sweeps.pe_sweep --glb-kib 64 --output ./analysis/results/pe_sweep
"""

from __future__ import annotations

import argparse
import time
from pathlib import Path

import matplotlib.pyplot as plt
import pandas as pd

from analysis.sweeps._common import best_for_each_layer, make_hardware


# (pe_h, pe_w) configurations to compare
DEFAULT_PE_CONFIGS = [
    (6, 8),    # course baseline
    (12, 8),   # Lab 2 stretch
    (16, 16),  # proposal target
    (8, 8),    # smaller corner
    (32, 16),  # bigger corner
]


def run_sweep(pe_configs: list[tuple[int, int]], glb_kib: int, bus_bw: int) -> pd.DataFrame:
    rows: list[dict] = []
    for pe_h, pe_w in pe_configs:
        hw = make_hardware(pe_h=pe_h, pe_w=pe_w, glb_kib=glb_kib, bus_bw=bus_bw)
        per_layer = best_for_each_layer(hw)
        for r in per_layer:
            r["pe_h"] = pe_h
            r["pe_w"] = pe_w
            r["pe_total"] = pe_h * pe_w
            r["hw_label"] = f"{pe_h}x{pe_w}"
            rows.append(r)
    return pd.DataFrame(rows)


def plot_latency_per_config(df: pd.DataFrame, ofile: Path) -> None:
    pivot = df.pivot_table(
        index="layer", columns="hw_label", values="latency", aggfunc="first"
    )
    ax = pivot.plot(kind="bar", figsize=(10, 6))
    ax.set_ylabel("Latency (cycles)")
    ax.set_yscale("log")
    ax.set_title("VGG-8 per-layer latency vs PE array size")
    ax.legend(title="PE array (h x w)")
    plt.tight_layout()
    ofile.parent.mkdir(parents=True, exist_ok=True)
    plt.savefig(ofile)
    print(f"Plot saved at {ofile}")


def main() -> None:
    parser = argparse.ArgumentParser(description="PE-array size sweep on VGG-8")
    parser.add_argument(
        "--glb-kib", type=int, default=64,
        help="GLB size to hold constant (KiB). Course baseline = 64.",
    )
    parser.add_argument("--bus-bw", type=int, default=4)
    parser.add_argument(
        "--output", type=str,
        default=f"./analysis/results/pe_sweep_{time.strftime('%Y%m%d-%H%M%S')}",
    )
    args = parser.parse_args()

    print(f"PE configs to sweep: {DEFAULT_PE_CONFIGS}")
    print(f"Hold GLB = {args.glb_kib} KiB, bus_bw = {args.bus_bw} bytes/cycle")

    df = run_sweep(DEFAULT_PE_CONFIGS, args.glb_kib, args.bus_bw)

    output_dir = Path(args.output).absolute()
    output_dir.mkdir(parents=True, exist_ok=True)
    df.to_csv(output_dir / "output.csv", index=False)
    with open(output_dir / "output.md", "w") as f:
        f.write("# PE-array Sweep Report\n\n")
        f.write(f"GLB held at {args.glb_kib} KiB; bus bandwidth {args.bus_bw} bytes/cycle.\n\n")
        f.write("## Per-layer best mapping by hardware\n\n")
        cols = ["hw_label", "pe_total", "layer", "latency", "energy_total",
                "intensity", "bound_by", "macs", "infeasible"]
        f.write(df[cols].to_markdown(index=False))

    plot_latency_per_config(df, output_dir / "latency.png")

    # Summary print
    print("\n=== Summary (lower latency = better) ===")
    summary = df.groupby("hw_label")["latency"].sum().sort_values()
    for hw, total in summary.items():
        print(f"  {hw:>8s}  total = {total:>15,d} cycles")


if __name__ == "__main__":
    main()
