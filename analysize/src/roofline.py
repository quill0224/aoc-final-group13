from __future__ import annotations

import argparse
import csv
from pathlib import Path

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
try:
    import pandas as pd
except ImportError:
    pd = None

from lib.utils import preprocess_filename


RooflineParam = tuple[float, float]
RooflineData = tuple[np.ndarray, np.ndarray, float, float]


__all__ = [
    "plot_roofline",
    "plot_roofline_from_df",
    "plot_roofline_from_csv",
    "plot_combined_roofline",
    "load_roofline_series_from_csv",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
    )
    parser.add_argument("--example", action="store_true", help="run the example code")
    parser.add_argument(
        "-i",
        "--input",
        type=str,
        help="path to the input CSV file",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=str,
        default=None,
        help="path to the output figure, None for the same directory of the input file",
    )
    return parser.parse_args()


def get_roofline(
    peak_performance: float, peak_bandwidth: float, max_op_intensity: float = 30
) -> RooflineData:
    intensity = np.linspace(0, max_op_intensity, 200)
    compute_roof = np.full_like(intensity, peak_performance)
    bandwidth_roof = intensity * peak_bandwidth
    roofline = np.minimum(compute_roof, bandwidth_roof)
    return intensity, roofline, peak_performance, peak_bandwidth


def plot_roofline(
    rooflines: dict[str, RooflineParam],
    workloads: dict[str, float] | None = None,
    filename: str | Path = "log/figure/roofline.png",
) -> None:
    plt.figure(figsize=(8, 6))
    xmin, xmax = np.inf, -np.inf
    ymin, ymax = np.inf, -np.inf
    oi_max = 0.0

    # Plot workload intensities
    if workloads is not None:
        colors = [plt.get_cmap("tab10")(i) for i in range(len(workloads))]
        for (k, v), color in zip(workloads.items(), colors):
            plt.axvline(x=v, color=color, linestyle="--", label=f"{k} (OI = {v:.2f})")
            oi_max = max(oi_max, v)

    # Plot rooflines
    for i, (key, (perf, band)) in enumerate(rooflines.items()):
        x, y, *_ = get_roofline(perf, band, max_op_intensity=oi_max * 1.05)
        color = "black" if i == len(rooflines) - 1 else "#aaaaaa"
        plt.plot(x, y, linewidth=2, color=color, label=key)
        xmin = min(xmin, x[0])
        xmax = max(xmax, x[-1])
        ymin = min(ymin, y[0])
        ymax = max(ymax, y[-1])

    # Plot settings
    plt.xlabel("Operational Intensity (MACs/byte)")
    plt.ylabel("Performance (MACs/cycle)")
    plt.xlim(xmin, xmax)
    plt.ylim(ymin, ymax * 1.05)
    plt.title("Roofline Model")
    plt.grid(which="both", linestyle="--", linewidth=0.5)
    plt.legend()

    # Save figure
    path = Path(preprocess_filename(filename, existed="overwrite"))
    path.parent.mkdir(parents=True, exist_ok=True)
    plt.savefig(path)
    print(f"Roofline plot saved at {path}")


def plot_combined_roofline(
    series: list[dict],
    filename: str | Path = "log/figure/combined_roofline.png",
) -> None:
    rooflines = {}
    workloads = {}
    for item in series:
        name = item["roofline_name"]
        rooflines[name] = (item["peak_performance"], item["peak_bandwidth"])
        for layer, intensity in item["workloads"].items():
            workloads[f"{layer} [{name}]"] = intensity
    plot_roofline(rooflines, workloads, filename)


def _has_column(table, column: str) -> bool:
    if hasattr(table, "columns"):
        return column in table.columns
    return bool(table) and column in table[0]


def _column(table, column: str) -> list:
    if hasattr(table, "columns"):
        return list(table[column])
    return [row[column] for row in table]


def _read_csv_rows(ifile: str | Path) -> list[dict]:
    with open(ifile, newline="") as f:
        rows = []
        for row in csv.DictReader(f):
            converted = {}
            for key, value in row.items():
                try:
                    converted[key] = float(value)
                except (TypeError, ValueError):
                    converted[key] = value
            rows.append(converted)
        return rows


def plot_roofline_from_df(df, ofile: str | Path) -> None:
    # Load the roofline and workload data
    intensity_col = "intensity" if _has_column(df, "intensity") else "dense_intensity"
    if _has_column(df, "roofline_name"):
        roofline_items = []
        seen = set()
        for name, perf, band in zip(
            _column(df, "roofline_name"),
            _column(df, "peak_performance"),
            _column(df, "peak_bandwidth"),
        ):
            key = (name, perf, band)
            if key not in seen:
                seen.add(key)
                roofline_items.append(key)
        rooflines = {str(name): (perf, band) for name, perf, band in roofline_items}
    else:
        roofline_params = frozenset(zip(_column(df, "peak_performance"), _column(df, "peak_bandwidth")))
        rooflines = {f"Roofline of Hardware {i}": v for i, v in enumerate(roofline_params)}
    workloads = {k: v for k, v in zip(_column(df, "layer"), _column(df, intensity_col))}
    print(f"{len(rooflines)} rooflines and {len(workloads)} workloads loaded.")

    # Plot the roofline model
    plot_roofline(rooflines, workloads, ofile)


def plot_roofline_from_csv(ifile: str | Path, ofile: str | Path) -> None:
    if pd is not None:
        df = pd.read_csv(ifile)
    else:
        df = _read_csv_rows(ifile)
    plot_roofline_from_df(df, ofile)


def load_roofline_series_from_csv(
    ifile: str | Path,
    roofline_name: str | None = None,
    intensity_col: str | None = None,
) -> dict:
    if pd is not None:
        df = pd.read_csv(ifile)
    else:
        df = _read_csv_rows(ifile)

    selected_intensity_col = intensity_col
    if selected_intensity_col is None:
        selected_intensity_col = "intensity" if _has_column(df, "intensity") else "dense_intensity"

    name = roofline_name
    if name is None:
        name = str(_column(df, "roofline_name")[0]) if _has_column(df, "roofline_name") else "Roofline"

    return {
        "roofline_name": name,
        "peak_performance": float(_column(df, "peak_performance")[0]),
        "peak_bandwidth": float(_column(df, "peak_bandwidth")[0]),
        "workloads": {
            layer: float(intensity)
            for layer, intensity in zip(_column(df, "layer"), _column(df, selected_intensity_col))
        },
    }


def plot_example():
    plot_roofline(
        rooflines={"Roofline": (48.0, 4.0)},
        workloads={"Machine balance point": 12.0},
        filename="../log/figure/baseline.png",
    )


def main() -> None:
    args = parse_args()

    if args.example:
        plot_example()
        return

    if args.output is None:
        args.output = args.input.replace(".csv", ".png")

    plot_roofline_from_csv(args.input, args.output)


if __name__ == "__main__":
    main()
