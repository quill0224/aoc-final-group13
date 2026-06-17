"""Generate the roofline plot for the Final Project presentation.

Reads pe_sweep.csv, draws 3 rooflines (6x8 baseline, 16x16 same-bus, 16x16 + 8 B/cy v2),
and overlays the 5 conv layer OIs from the 6x8 baseline mapping.

Run:
    python3 analysis/results/baseline/_plot_roofline.py
"""

from __future__ import annotations

import csv
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np

CSV = Path(__file__).parent / "pe_sweep.csv"
OUT = Path(__file__).parent / "roofline.png"

ROOFLINES = [
    ("6x8 + 4 B/cy (baseline)",   48.0,  4.0, "#888888"),
    ("16x16 + 4 B/cy (PE only)", 256.0,  4.0, "#d62728"),
    ("16x16 + 8 B/cy (v2)",      256.0,  8.0, "#2ca02c"),
]


def load_6x8_layer_ois() -> dict[str, float]:
    with CSV.open() as f:
        rows = list(csv.DictReader(f))
    return {r["layer"]: float(r["intensity"]) for r in rows if r["hw_label"] == "6x8"}


def main() -> None:
    layer_ois = load_6x8_layer_ois()
    oi_min, oi_max = 1.0, max(layer_ois.values()) * 2.0

    x = np.logspace(np.log10(oi_min), np.log10(oi_max), 400)

    fig, ax = plt.subplots(figsize=(11, 6.5))

    roof_handles = []
    for label, peak_perf, peak_bw, color in ROOFLINES:
        y = np.minimum(peak_perf, x * peak_bw)
        h, = ax.plot(x, y, linewidth=2.4, color=color, label=label, zorder=3)
        roof_handles.append(h)
        balance = peak_perf / peak_bw
        ax.plot([balance], [peak_perf], "o", color=color, markersize=7, zorder=4)
        ax.annotate(f"  balance={balance:.0f}\n  peak={peak_perf:.0f}",
                    xy=(balance, peak_perf), xytext=(balance * 1.1, peak_perf * 1.15),
                    color=color, fontsize=9, fontweight="bold")

    layer_handles = []
    layer_colors = plt.get_cmap("tab10")
    for i, (layer, oi) in enumerate(sorted(layer_ois.items())):
        h = ax.axvline(oi, color=layer_colors(i), linestyle="--", linewidth=1.3,
                       alpha=0.9, label=f"{layer} (OI={oi:.1f})", zorder=2)
        layer_handles.append(h)
        ax.text(oi, 1.3, layer, color=layer_colors(i), fontsize=8,
                ha="center", rotation=90, fontweight="bold")

    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_xlim(oi_min, oi_max)
    ax.set_ylim(1, 800)
    ax.set_xlabel("Operational Intensity (MAC / Byte)", fontsize=11)
    ax.set_ylabel("Performance (MAC / cycle)", fontsize=11)
    ax.set_title("Roofline: VGG-8 conv layers · baseline 6x8 vs v2 PE+Bus scaling",
                 fontsize=12)
    ax.grid(which="both", linestyle="--", linewidth=0.4, alpha=0.5)

    leg1 = ax.legend(handles=roof_handles, loc="upper left",
                     bbox_to_anchor=(1.02, 1.0), fontsize=9, title="Rooflines",
                     title_fontsize=10, frameon=True)
    ax.add_artist(leg1)
    ax.legend(handles=layer_handles, loc="upper left",
              bbox_to_anchor=(1.02, 0.55), fontsize=9, title="VGG-8 conv (OI from 6x8)",
              title_fontsize=10, frameon=True)

    plt.tight_layout()
    plt.savefig(OUT, dpi=160, bbox_inches="tight")
    print(f"saved -> {OUT}")


if __name__ == "__main__":
    main()
