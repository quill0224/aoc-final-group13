from __future__ import annotations

import argparse
import time
from pathlib import Path
from typing import Any

import pandas as pd
import torch

torch.backends.quantized.engine = "qnnpack"

from lib.models import VGG
from lib.models.qconfig import CustomQConfig
from lib.utils import load_model

from analytical_model.mapper import EyerissMapper
from analytical_model.StandardIP_mapper import StandardIPMapper
from analytical_model.TrIP_mapper import TrIPMapper

try:
    from analytical_model import AnalysisResult
except Exception:  # pragma: no cover - for projects that do not export AnalysisResult
    AnalysisResult = dict[str, Any]

from layer_info import Conv2DShapeParam, MaxPool2DShapeParam, ShapeParam
from network_parser import parse_onnx, parse_pytorch
from roofline import plot_compulsory_actual_roofline_from_df, plot_roofline_from_df


ARCH_ALIASES = {
    "eyeriss": "eyeriss",
    "standard_ip": "standard_ip",
    "standardip": "standard_ip",
    "standard-ip": "standard_ip",
    "stdip": "standard_ip",
    "trip": "trip",
    "tr_ip": "trip",
    "tr-ip": "trip",
}

DEFAULT_BATCH_SIZE = 1
DEFAULT_CHANNELS = 3
DEFAULT_INPUT_SIZE = 224


def normalize_arch(arch: str) -> str:
    key = arch.strip().lower().replace(" ", "_")
    if key not in ARCH_ALIASES:
        valid = ", ".join(sorted(ARCH_ALIASES))
        raise ValueError(f"Unknown architecture '{arch}'. Valid aliases: {valid}")
    return ARCH_ALIASES[key]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
    )
    parser.add_argument(
        "model_path",
        type=str,
        help="path to the ONNX or PyTorch model",
    )
    parser.add_argument(
        "-a",
        "--arch",
        type=str,
        default="eyeriss",
        help="hardware architecture: eyeriss, standard_ip/standardIP, or trip/TrIP",
    )
    parser.add_argument(
        "-f",
        "--format",
        type=str,
        default="torch",
        choices=["torch", "onnx"],
        help="input model format",
    )
    parser.add_argument(
        "-b",
        "--backend",
        type=str,
        default="power2",
        choices=["power2", "dyadic", "qnnpack", "none"],
        help="quantization backend; use 'none' for full precision",
    )
    parser.add_argument(
        "--input-size",
        type=int,
        default=DEFAULT_INPUT_SIZE,
        help="input image height/width used by the PyTorch parser; ImageNet-100 should use 224",
    )
    parser.add_argument(
        "--batch-size",
        type=int,
        default=DEFAULT_BATCH_SIZE,
        help="batch size used by the parser dummy input",
    )
    parser.add_argument(
        "--input-channels",
        type=int,
        default=DEFAULT_CHANNELS,
        help="input channels used by the parser dummy input",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=str,
        default=f"../log/{time.strftime('%Y%m%d-%H%M%S')}",
        help="directory to save output results",
    )
    parser.add_argument(
        "--plot",
        action="store_true",
        help="plot the roofline model and save it to output directory",
    )
    parser.add_argument(
        "--mode",
        type=str,
        choices=["dense", "mapping", "hardware", "none"],
        default="dense",
        help=(
            "analysis mode passed to mapper. 'dense' keeps the original "
            "latency-first behavior; other modes can use EDP/objective DSE."
        ),
    )
    parser.add_argument(
        "--num-solutions",
        type=int,
        default=1,
        help="number of best mapping solutions to keep per layer",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="print per-layer information",
    )
    return parser.parse_args()


def make_input_shape(
    batch_size: int = DEFAULT_BATCH_SIZE,
    input_channels: int = DEFAULT_CHANNELS,
    input_size: int = DEFAULT_INPUT_SIZE,
) -> tuple[int, int, int, int]:
    if batch_size <= 0:
        raise ValueError(f"batch_size must be positive, got {batch_size}")
    if input_channels <= 0:
        raise ValueError(f"input_channels must be positive, got {input_channels}")
    if input_size <= 0:
        raise ValueError(f"input_size must be positive, got {input_size}")
    return (batch_size, input_channels, input_size, input_size)


def load_torch_model(model_path: Path, backend: str) -> torch.nn.Module:
    """Load PyTorch VGG16 model for analytical parsing."""
    backend = backend.lower()

    if backend == "power2":
        model = VGG(arch="vgg16")
        model.eval()  # required before fuse_modules
        model = load_model(
            model,
            model_path,
            qconfig=CustomQConfig[backend.upper()].value,
            fuse_modules=True,
        )
        model.eval()
        return model

    if backend == "none":
        model = VGG(arch="vgg16")
        model.eval()
        model = load_model(
            model,
            model_path,
            fuse_modules=False,
        )
        model.eval()
        return model

    if backend in {"qnnpack", "dyadic"}:
        model = VGG(arch="vgg16")
        model.eval()
        model = load_model(
            model,
            model_path,
            qconfig=CustomQConfig[backend.upper()].value,
            fuse_modules=True,
        )
        model.eval()
        return model

    raise ValueError(f"Unsupported backend: {backend}")


def pair_conv_and_optional_pool(raw_layers: list[ShapeParam]) -> list[ShapeParam | None]:
    """Return [conv0, pool_or_none0, conv1, pool_or_none1, ...]."""
    paired_layers: list[ShapeParam | None] = []
    i = 0
    while i < len(raw_layers):
        layer = raw_layers[i]
        if isinstance(layer, Conv2DShapeParam):
            paired_layers.append(layer)
            if i + 1 < len(raw_layers) and isinstance(raw_layers[i + 1], MaxPool2DShapeParam):
                paired_layers.append(raw_layers[i + 1])
                i += 2
            else:
                paired_layers.append(None)
                i += 1
        else:
            i += 1
    return paired_layers


def parse_network(
    model_path: str | Path,
    model_format: str,
    backend: str = "power2",
    input_shape: tuple[int, int, int, int] = (DEFAULT_BATCH_SIZE, DEFAULT_CHANNELS, DEFAULT_INPUT_SIZE, DEFAULT_INPUT_SIZE),
) -> tuple[list[ShapeParam | None], torch.nn.Module | None]:
    """Return (paired layer list, loaded model).

    The returned layer list alternates Conv2DShapeParam and MaxPool2DShapeParam/None:
        [conv0, pool_or_none0, conv1, pool_or_none1, ...]
    """
    model_path = Path(model_path)
    model_format = model_format.lower()

    if model_format == "torch":
        model = load_torch_model(model_path, backend)
        raw_layers = parse_pytorch(model, input_shape=input_shape)
    elif model_format == "onnx":
        model = None
        raw_layers = parse_onnx(str(model_path))
    else:
        raise ValueError(f"Unsupported model format: {model_format}")

    return pair_conv_and_optional_pool(raw_layers), model


def _extract_weight_tensor(module: torch.nn.Module) -> torch.Tensor | None:
    if not hasattr(module, "weight"):
        return None

    weight_attr = getattr(module, "weight")
    try:
        weight = weight_attr() if callable(weight_attr) else weight_attr
    except Exception:
        return None

    if not isinstance(weight, torch.Tensor):
        return None

    return weight.detach()


def get_filter_densities(model: torch.nn.Module | None) -> list[float]:
    """Extract per-conv-layer filter density from a PyTorch model.

    Density = nonzero_count / total_count. Quantized tensors are dequantized before
    checking zeros, which avoids mistakes when zero_point is not integer 0.
    """
    if model is None:
        return []

    densities: list[float] = []
    for _, module in model.named_modules():
        weight = _extract_weight_tensor(module)
        if weight is None or weight.dim() != 4:
            continue

        if weight.is_quantized:
            weight_for_count = weight.dequantize()
        else:
            weight_for_count = weight

        density = float((weight_for_count != 0).sum().item()) / float(weight_for_count.numel())
        densities.append(density)

    return densities


def export_results(
    results: list[AnalysisResult],
    output_dir: str | Path,
    arch: str,
) -> pd.DataFrame:
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    df = pd.DataFrame(results)
    df.to_csv(output_dir / "output.csv", index=False)

    with open(output_dir / "output.md", "w", encoding="utf-8") as f:
        f.write(f"# {arch.upper()} Mapping Report\n\n")
        if len(df) == 0:
            f.write("No valid mapping result was generated.\n")
        else:
            f.write("## Results\n\n")
            f.write(df.to_markdown(index=False))

    print(f"[INFO] Report is saved to {output_dir}")
    return df


def print_arch_info(arch: str) -> None:
    if arch == "eyeriss":
        print("[ARCH] Eyeriss")
        print("  dataflow       : original Eyeriss mapper / row-stationary style")
    elif arch == "standard_ip":
        print("[ARCH] StandardIP")
        print("  PE array       : configured by StandardIPMapper")
        print("  DRAM model     : dense tiled model in StandardIPAnalyzer")
    elif arch == "trip":
        print("[ARCH] TrIP")
        print("  PE array       : 16 x 16 search space in TrIPMapper")
        print("  sparse model   : dense_macs * act_density * filter_density")
        print("  metadata       : K-dimension bitmask for ifmap and filter fibers")
        print("  DRAM loop      : activation-stationary-ish")


def print_layer_info(
    layer_name: str,
    conv_param: Conv2DShapeParam,
    maxpool_param: MaxPool2DShapeParam | None,
    arch: str,
    filter_density: float | None = None,
) -> None:
    m_gemm = conv_param.N * conv_param.E * conv_param.F
    k_gemm = conv_param.C * conv_param.R * conv_param.S
    n_gemm = conv_param.M
    print(f"[LAYER] {layer_name}")
    print(f"  GEMM           : M={m_gemm}, K={k_gemm}, N={n_gemm}")
    print(
        f"  Conv shape     : N={conv_param.N}, C={conv_param.C}, H={conv_param.H}, W={conv_param.W}, "
        f"M={conv_param.M}, R={conv_param.R}, S={conv_param.S}, E={conv_param.E}, F={conv_param.F}"
    )
    print(f"  MaxPool        : {'yes' if maxpool_param is not None else 'no'}")
    if arch == "trip" and filter_density is not None:
        print(f"  filter_density : {filter_density:.6f}")


def print_summary(df: pd.DataFrame, arch: str, output_dir: Path) -> None:
    print("[SUMMARY]")
    print(f"  arch           : {arch}")
    print(f"  layers         : {len(df)}")
    if len(df) == 0:
        print("  warning        : no valid mapping result")
        return

    for col in [
        "dense_macs",
        "effectual_macs",
        "dram_access",
        "dram_total",
        "dram_compulsory_total",
        "dram_actual_total",
        "total_cycles",
        "total_cycles_trip",
        "total_cycles_dense",
    ]:
        if col in df.columns:
            value = pd.to_numeric(df[col], errors="coerce").fillna(0).sum()
            print(f"  sum({col}) : {value:.4g}")

    for col in ["oi_compulsory", "oi_actual"]:
        if col in df.columns:
            value = pd.to_numeric(df[col], errors="coerce").dropna().mean()
            print(f"  avg({col}) : {value:.4g}")
    print(f"  output         : {output_dir / 'output.csv'}")


def main() -> None:
    args = parse_args()
    arch = normalize_arch(args.arch)
    model_path = Path(args.model_path).absolute()
    output_dir = Path(args.output).absolute()
    input_shape = make_input_shape(args.batch_size, args.input_channels, args.input_size)

    print("[INFO] Starting analytical mapping")
    print(f"  model_path     : {model_path}")
    print(f"  format         : {args.format}")
    print(f"  backend        : {args.backend}")
    print(f"  arch           : {arch}")
    print(f"  input_shape    : {input_shape}")
    print(f"  output_dir     : {output_dir}")
    print_arch_info(arch)

    if args.format == "torch" and args.input_size != 224:
        print(
            f"[WARN] input-size={args.input_size}. For ImageNet-100 VGG16, expected --input-size 224."
        )

    layers, model = parse_network(
        model_path,
        args.format,
        args.backend,
        input_shape=input_shape,
    )
    conv_count = len(layers) // 2
    print(f"[INFO] Parsed conv layers: {conv_count}")

    if args.verbose and conv_count > 0 and isinstance(layers[0], Conv2DShapeParam):
        first_conv = layers[0]
        if (first_conv.H, first_conv.W) != (args.input_size, args.input_size):
            print(
                f"[WARN] First Conv input is {first_conv.H}x{first_conv.W}, "
                f"but requested input-size is {args.input_size}. Check parser/model preprocessing."
            )

    filter_densities = get_filter_densities(model) if arch == "trip" else []
    if arch == "trip":
        print(f"[INFO] Extracted filter densities: {len(filter_densities)}")
        if len(filter_densities) != conv_count:
            print(
                "[WARN] Number of extracted filter densities does not match parsed conv layers. "
                "Missing layers will use density=1.0."
            )

    mode = args.mode.lower() if args.mode is not None else "dense"
    results: list[AnalysisResult] = []

    conv_idx = 0
    for i in range(0, len(layers), 2):
        conv_param = layers[i]
        maxpool_param = layers[i + 1] if i + 1 < len(layers) else None
        if not isinstance(conv_param, Conv2DShapeParam):
            continue

        layer_name = f"vgg16.conv{conv_idx}"
        filter_density: float | None = None

        if arch == "eyeriss":
            mapper = EyerissMapper(name=layer_name)
        elif arch == "standard_ip":
            mapper = StandardIPMapper(name=layer_name)
        elif arch == "trip":
            filter_density = filter_densities[conv_idx] if conv_idx < len(filter_densities) else 1.0
            mapper = TrIPMapper(
                name=layer_name,
                layer_idx=conv_idx,
                filter_density=filter_density,
            )
        else:  # normalize_arch should prevent this path.
            raise ValueError(f"Unknown architecture: {arch}")

        if args.verbose:
            print_layer_info(layer_name, conv_param, maxpool_param, arch, filter_density)

        layer_results = mapper.run(
            conv_param,
            maxpool_param,
            num_solutions=args.num_solutions,
            mode=mode,
        )
        if args.verbose:
            print(f"  valid mappings : {len(layer_results)}")
            if layer_results:
                best = layer_results[0]
                key = "total_cycles_trip" if arch == "trip" else "total_cycles_dense"
                if key in best:
                    print(f"  best {key}: {best[key]}")

        results.extend(layer_results)
        conv_idx += 1

    df = export_results(results, output_dir, arch)

    if args.plot and len(df) > 0:
        plot_roofline_from_df(
            df,
            output_dir / "roofline_compulsory.png",
            intensity_col="oi_compulsory",
        )
        print(f"[INFO] Compulsory roofline plot is saved to {output_dir / 'roofline_compulsory.png'}")

        plot_roofline_from_df(
            df,
            output_dir / "roofline_actual.png",
            intensity_col="oi_actual",
        )
        print(f"[INFO] Actual roofline plot is saved to {output_dir / 'roofline_actual.png'}")

        plot_compulsory_actual_roofline_from_df(
            df,
            output_dir / "roofline_combined.png",
        )
        print(f"[INFO] Combined roofline plot is saved to {output_dir / 'roofline_combined.png'}")

        plot_roofline_from_df(df, output_dir / "output.png")
        print(f"[INFO] Legacy roofline plot is saved to {output_dir / 'output.png'}")

    print_summary(df, arch, output_dir)


if __name__ == "__main__":
    main()
