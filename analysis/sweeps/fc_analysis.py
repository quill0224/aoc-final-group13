"""FC-layer memory analysis: response to proposal review concern #2.

The Eyeriss analytical model targets Conv2D only; FC layers (a.k.a. fully-
connected / Linear) need separate accounting. This script computes:
    - per-FC weight footprint (bytes)
    - tile counts required to fit each FC into a given GLB size
    - DRAM weight-streaming cost vs accumulator-only design

VGG-8 FC layers (matches quantization.model.VGG):
    FC6 : 4096 -> 256    1,048,576 weights = 1.0 MiB INT8
    FC7 : 256  -> 128       32,768 weights = 32 KiB INT8
    FC8 : 128  -> 10         1,280 weights = 1.25 KiB INT8

Usage:
    python -m analysis.sweeps.fc_analysis
    python -m analysis.sweeps.fc_analysis --glb-list 16 64 128 256 512 1024
"""

from __future__ import annotations

import argparse
import time
from dataclasses import dataclass
from pathlib import Path

import matplotlib.pyplot as plt
import pandas as pd


@dataclass(frozen=True)
class FCLayer:
    name: str
    in_features: int
    out_features: int

    @property
    def n_weights(self) -> int:
        return self.in_features * self.out_features

    @property
    def n_bias(self) -> int:
        return self.out_features

    @property
    def weight_bytes_int8(self) -> int:
        return self.n_weights  # INT8 = 1 byte per weight

    @property
    def weight_bytes_fp32(self) -> int:
        return self.n_weights * 4

    @property
    def macs(self) -> int:
        return self.n_weights  # 1 MAC per weight per single-batch input


VGG8_FC_LAYERS = [
    FCLayer(name="FC6", in_features=4096, out_features=256),
    FCLayer(name="FC7", in_features=256,  out_features=128),
    FCLayer(name="FC8", in_features=128,  out_features=10),
]


def tiles_required(layer: FCLayer, glb_bytes: int, dtype_bytes: int = 1) -> dict:
    """Estimate weight-streaming cost for one inference of `layer`.

    Strategy: output-stationary, weight streaming.
    A tile = one chunk of weights that fits in GLB along with input + output
    activations.

    Simple model (overhead-free): if the entire weight matrix fits in GLB
    after reserving room for input + bias + output, no streaming is needed
    (1 tile). Otherwise approximate tiles = ceil(weight_bytes / glb_avail).
    """
    # Reserve space for input vector + bias + output vector (small for FC)
    activation_bytes = (layer.in_features + 2 * layer.out_features) * 4  # FP32 psum
    glb_avail = max(glb_bytes - activation_bytes, 1)  # bytes left for weights

    weight_total = layer.n_weights * dtype_bytes
    if weight_total <= glb_avail:
        n_tiles = 1
    else:
        n_tiles = -(-weight_total // glb_avail)  # ceil-div

    return {
        "weight_bytes": weight_total,
        "glb_bytes": glb_bytes,
        "glb_avail_for_weights": glb_avail,
        "n_tiles": n_tiles,
        # Each tile must read its weights from DRAM once per inference
        "dram_read_bytes": weight_total,  # weights ARE always read from DRAM regardless of tiling
        # But if tile count > 1, input must be re-read per tile
        "ifmap_re_read_bytes": (n_tiles - 1) * layer.in_features * dtype_bytes,
        "fits_in_glb": n_tiles == 1,
    }


def run(glb_list_kib: list[int]) -> pd.DataFrame:
    rows: list[dict] = []
    for glb_kib in glb_list_kib:
        for layer in VGG8_FC_LAYERS:
            r = tiles_required(layer, glb_kib * 1024)
            r["layer"] = layer.name
            r["in_features"] = layer.in_features
            r["out_features"] = layer.out_features
            r["macs"] = layer.macs
            r["glb_kib"] = glb_kib
            rows.append(r)
    return pd.DataFrame(rows)


def plot_tiles(df: pd.DataFrame, ofile: Path) -> None:
    pivot = df.pivot_table(index="glb_kib", columns="layer", values="n_tiles", aggfunc="first")
    ax = pivot.plot(kind="bar", figsize=(10, 6))
    ax.set_ylabel("Number of tiles (1 = fits in GLB)")
    ax.set_yscale("log")
    ax.set_title("FC-layer tile count vs GLB size (INT8)")
    plt.axhline(y=1, color="green", linestyle="--", alpha=0.4, label="No streaming")
    plt.tight_layout()
    ofile.parent.mkdir(parents=True, exist_ok=True)
    plt.savefig(ofile)
    print(f"Plot saved at {ofile}")


def main() -> None:
    parser = argparse.ArgumentParser(description="FC-layer memory analysis")
    parser.add_argument(
        "--glb-list", type=int, nargs="+",
        default=[16, 32, 64, 128, 256, 512, 1024],
        help="GLB sizes to evaluate (KiB)",
    )
    parser.add_argument(
        "--output", type=str,
        default=f"./analysis/results/fc_analysis_{time.strftime('%Y%m%d-%H%M%S')}",
    )
    args = parser.parse_args()

    df = run(args.glb_list)

    output_dir = Path(args.output).absolute()
    output_dir.mkdir(parents=True, exist_ok=True)
    df.to_csv(output_dir / "output.csv", index=False)
    with open(output_dir / "output.md", "w") as f:
        f.write("# FC-layer Memory Analysis\n\n")
        f.write("VGG-8 has 3 FC layers. INT8 weights = 1 byte each.\n\n")
        f.write("| Layer | in × out | Weights (bytes) |\n")
        f.write("|-------|----------|-----------------|\n")
        for layer in VGG8_FC_LAYERS:
            f.write(
                f"| {layer.name} | {layer.in_features} × {layer.out_features} "
                f"| {layer.weight_bytes_int8:,} |\n"
            )
        f.write("\n## GLB-size vs tile count\n\n")
        f.write(df[["glb_kib", "layer", "weight_bytes", "n_tiles", "fits_in_glb"]].to_markdown(index=False))

    plot_tiles(df, output_dir / "fc_tiles.png")

    # Summary
    print("\n=== FC layers — does the proposal's 16 KiB GLB fit them? ===")
    proposal_glb = 16
    for layer in VGG8_FC_LAYERS:
        r = tiles_required(layer, proposal_glb * 1024)
        verdict = "✓ fits" if r["fits_in_glb"] else f"✗ NEEDS STREAMING (n_tiles={r['n_tiles']})"
        print(f"  {layer.name:>5s}  {layer.weight_bytes_int8:>10,d} B  →  {verdict}")

    print("\n=== Course baseline 64 KiB GLB ===")
    for layer in VGG8_FC_LAYERS:
        r = tiles_required(layer, 64 * 1024)
        verdict = "✓ fits" if r["fits_in_glb"] else f"✗ NEEDS STREAMING (n_tiles={r['n_tiles']})"
        print(f"  {layer.name:>5s}  {layer.weight_bytes_int8:>10,d} B  →  {verdict}")


if __name__ == "__main__":
    main()
