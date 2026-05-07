"""Roofline plotting helpers (lifted from AOC Lab 2)."""

from __future__ import annotations

from pathlib import Path
from typing import Tuple

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

RooflineParam = Tuple[float, float]
RooflineData = Tuple[np.ndarray, np.ndarray, float, float]

__all__ = ["plot_roofline", "plot_roofline_from_df", "plot_roofline_from_csv"]


def get_roofline(
    peak_performance: float,
    peak_bandwidth: float,
    max_op_intensity: float = 30,
) -> RooflineData:
    intensity = np.linspace(0, max_op_intensity, 200)
    compute_roof = np.full_like(intensity, peak_performance)
    bandwidth_roof = intensity * peak_bandwidth
    return intensity, np.minimum(compute_roof, bandwidth_roof), peak_performance, peak_bandwidth


def plot_roofline(
    rooflines: dict[str, RooflineParam],
    workloads: dict[str, float] | None = None,
    filename: str | Path = "results/roofline.png",
) -> None:
    plt.figure(figsize=(8, 6))
    xmin, xmax = np.inf, -np.inf
    ymin, ymax = np.inf, -np.inf
    oi_max = 0.0

    if workloads is not None:
        colors = [plt.get_cmap("tab10")(i) for i in range(len(workloads))]
        for (k, v), color in zip(workloads.items(), colors):
            plt.axvline(x=v, color=color, linestyle="--", label=f"{k} (OI = {v:.2f})")
            oi_max = max(oi_max, v)

    for i, (key, (perf, band)) in enumerate(rooflines.items()):
        x, y, *_ = get_roofline(perf, band, max_op_intensity=oi_max * 1.05 if oi_max > 0 else 30)
        color = "black" if i == len(rooflines) - 1 else "#aaaaaa"
        plt.plot(x, y, linewidth=2, color=color, label=key)
        xmin = min(xmin, x[0])
        xmax = max(xmax, x[-1])
        ymin = min(ymin, y[0])
        ymax = max(ymax, y[-1])

    plt.xlabel("Operational Intensity (MACs/byte)")
    plt.ylabel("Performance (MACs/cycle)")
    plt.xlim(xmin, xmax)
    plt.ylim(ymin, ymax * 1.05)
    plt.title("Roofline Model")
    plt.grid(which="both", linestyle="--", linewidth=0.5)
    plt.legend()

    path = Path(filename)
    path.parent.mkdir(parents=True, exist_ok=True)
    plt.savefig(path)
    print(f"Roofline plot saved at {path}")


def plot_roofline_from_df(df: pd.DataFrame, ofile: str | Path) -> None:
    roofline_params = frozenset(zip(df["peak_performance"], df["peak_bandwidth"]))
    rooflines = {f"Roofline of Hardware {i}": v for i, v in enumerate(roofline_params)}
    workloads = {k: v for k, v in zip(df["layer"], df["intensity"])}
    print(f"{len(rooflines)} rooflines and {len(workloads)} workloads loaded.")
    plot_roofline(rooflines, workloads, ofile)


def plot_roofline_from_csv(ifile: str | Path, ofile: str | Path) -> None:
    plot_roofline_from_df(pd.read_csv(ifile), ofile)
