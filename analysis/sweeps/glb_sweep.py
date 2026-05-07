"""GLB-size sweep: response to proposal review concern #2 (memory bottleneck).

Runs the analytical model on VGG-8's 5 conv layers across multiple GLB sizes,
holding PE configuration constant. Records DRAM access count per layer to
quantify how undersized GLB inflates DRAM traffic.

Output: analysis/results/glb_sweep_<ts>/{output.csv, output.md, dram.png}

Usage:
    python -m analysis.sweeps.glb_sweep
    python -m analysis.sweeps.glb_sweep --pe-h 16 --pe-w 16
"""

from __future__ import annotations

import argparse
import time
from pathlib import Path

import matplotlib.pyplot as plt
import pandas as pd

from analysis.sweeps._common import best_for_each_layer, make_hardware


# Compare proposal's 16 KiB against course baseline (64 KiB) and bigger options
DEFAULT_GLB_KIB = [16, 32, 64, 128, 256, 512]


def run_sweep(pe_h: int, pe_w: int, glb_list: list[int], bus_bw: int) -> pd.DataFrame:
    rows: list[dict] = []
    for glb_kib in glb_list:
        hw = make_hardware(pe_h=pe_h, pe_w=pe_w, glb_kib=glb_kib, bus_bw=bus_bw)
        per_layer = best_for_each_layer(hw)
        for r in per_layer:
            r["glb_kib"] = glb_kib
            rows.append(r)
    return pd.DataFrame(rows)


def plot_dram_per_glb(df: pd.DataFrame, ofile: Path) -> None:
    feasible = df[df["infeasible"] == False]
    pivot = feasible.pivot_table(
        index="glb_kib", columns="layer", values="dram_access", aggfunc="first"
    )
    ax = pivot.plot(kind="line", marker="o", figsize=(10, 6))
    ax.set_xlabel("GLB size (KiB)")
    ax.set_ylabel("DRAM accesses (bytes)")
    ax.set_xscale("log", base=2)
    ax.set_yscale("log")
    ax.set_title("VGG-8 per-layer DRAM access vs GLB size")
    plt.grid(True, which="both", linestyle="--", linewidth=0.5)
    plt.tight_layout()
    ofile.parent.mkdir(parents=True, exist_ok=True)
    plt.savefig(ofile)
    print(f"Plot saved at {ofile}")


def main() -> None:
    parser = argparse.ArgumentParser(description="GLB-size sweep on VGG-8")
    parser.add_argument("--pe-h", type=int, default=6, help="PE array height (default: course baseline)")
    parser.add_argument("--pe-w", type=int, default=8)
    parser.add_argument("--bus-bw", type=int, default=4)
    parser.add_argument(
        "--glb-list", type=int, nargs="+", default=DEFAULT_GLB_KIB,
        help="GLB sizes to test (KiB)",
    )
    parser.add_argument(
        "--output", type=str,
        default=f"./analysis/results/glb_sweep_{time.strftime('%Y%m%d-%H%M%S')}",
    )
    args = parser.parse_args()

    print(f"PE = {args.pe_h}x{args.pe_w}, bus_bw = {args.bus_bw}")
    print(f"GLB list = {args.glb_list} KiB")

    df = run_sweep(args.pe_h, args.pe_w, args.glb_list, args.bus_bw)

    output_dir = Path(args.output).absolute()
    output_dir.mkdir(parents=True, exist_ok=True)
    df.to_csv(output_dir / "output.csv", index=False)
    with open(output_dir / "output.md", "w") as f:
        f.write("# GLB-size Sweep Report\n\n")
        f.write(f"Hardware: {args.pe_h}x{args.pe_w} PE, bus bandwidth {args.bus_bw} bytes/cycle.\n\n")
        f.write("## Per-layer best mapping by GLB size\n\n")
        cols = ["glb_kib", "layer", "latency", "dram_access", "glb_access",
                "energy_total", "infeasible"]
        f.write(df[cols].to_markdown(index=False))

    plot_dram_per_glb(df, output_dir / "dram.png")

    # Summary
    print("\n=== Total DRAM access across all 5 conv layers ===")
    feasible = df[df["infeasible"] == False]
    summary = feasible.groupby("glb_kib")["dram_access"].sum().sort_index()
    for glb, total in summary.items():
        print(f"  GLB={glb:>4d} KiB  total DRAM = {total:>15,d} bytes")


if __name__ == "__main__":
    main()
