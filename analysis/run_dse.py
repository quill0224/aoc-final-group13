"""End-to-end DSE: parse VGG-8 -> per-layer mapper -> CSV/MD/roofline.

Usage:
    # Parse FP32 model (no quantization wrapping)
    python -m analysis.run_dse --backend none \
        --model ./quantization/weights/best_vgg_cifar10.pth

    # Parse INT8 quantized model (correctly handles ConvReLU2d / LinearReLU)
    python -m analysis.run_dse --backend power2 \
        --model ./quantization/weights/PTQ_vgg_cifar10.pth

    # Skip plot (just CSV + MD)
    python -m analysis.run_dse --no-plot --output ./analysis/results/baseline
"""

from __future__ import annotations

import argparse
import time
from pathlib import Path

import pandas as pd

from analysis.eyeriss import (
    AnalysisResult,
    Conv2DShapeParam,
    EyerissMapper,
    MaxPool2DShapeParam,
    ShapeParam,
    parse_pytorch,
    plot_roofline_from_df,
)
from quantization.model import VGG
from quantization.quantize import CustomQConfig
from quantization.utils import load_model


def parse_network(model_path: str, backend: str = "power2") -> list[ShapeParam | None]:
    """Load a checkpoint and produce a layer list (Conv2D, MaxPool2D, or None)."""
    if backend.lower() == "power2":
        model = load_model(VGG(), model_path, qconfig=CustomQConfig.POWER2.value, fuse=True)
    elif backend.lower() == "none":
        model = load_model(VGG(), model_path)
    else:
        raise ValueError(f"Unsupported backend: {backend}")

    raw_layers = parse_pytorch(model)

    # Pair Conv2D with adjacent MaxPool (for the DSE loop). Insert None
    # between Convs that have no following pool.
    paired: list[ShapeParam | None] = []
    for i, layer in enumerate(raw_layers):
        if isinstance(layer, Conv2DShapeParam):
            paired.append(layer)
            next_layer = raw_layers[i + 1] if i + 1 < len(raw_layers) else None
            if not isinstance(next_layer, MaxPool2DShapeParam):
                paired.append(None)
        elif isinstance(layer, MaxPool2DShapeParam):
            paired.append(layer)
        # LinearShapeParam dropped: this Eyeriss model only handles Conv2D
    return paired


def export_results(results: list[AnalysisResult], output_dir: Path) -> pd.DataFrame:
    output_dir.mkdir(parents=True, exist_ok=True)
    df = pd.DataFrame(results)
    df.to_csv(output_dir / "output.csv", index=False)

    with open(output_dir / "output.md", "w") as f:
        f.write("# Eyeriss DSE Report\n\n")
        f.write(df.to_markdown(index=False))
    print(f"Report saved to {output_dir}/output.{{csv,md}}")
    return df


def main() -> None:
    parser = argparse.ArgumentParser(description="Eyeriss DSE on VGG-8")
    parser.add_argument(
        "--model", type=str,
        default="./quantization/weights/best_vgg_cifar10.pth",
        help="Path to VGG-8 checkpoint (.pth)",
    )
    parser.add_argument(
        "--backend", choices=["power2", "none"], default="power2",
        help="'power2' loads the INT8 PTQ checkpoint; 'none' loads FP32",
    )
    parser.add_argument(
        "--output", type=str,
        default=f"./analysis/results/{time.strftime('%Y%m%d-%H%M%S')}",
    )
    parser.add_argument("--no-plot", action="store_true")
    args = parser.parse_args()

    output_dir = Path(args.output).absolute()

    print(f"Parsing network from {args.model} (backend={args.backend}) ...")
    layers = parse_network(args.model, args.backend)
    n_conv = sum(1 for l in layers if isinstance(l, Conv2DShapeParam))
    print(f"Found {n_conv} Conv2D layers")

    print("Running per-layer DSE ...")
    results: list[AnalysisResult] = []
    for i in range(0, len(layers), 2):
        conv = layers[i]
        pool = layers[i + 1] if i + 1 < len(layers) else None
        mapper = EyerissMapper(name=f"vgg8.conv{i // 2}")
        results.extend(mapper.run(conv, pool, num_solutions=1))

    df = export_results(results, output_dir)
    if not args.no_plot:
        plot_roofline_from_df(df, output_dir / "roofline.png")


if __name__ == "__main__":
    main()
