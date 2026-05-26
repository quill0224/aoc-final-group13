from __future__ import annotations

import argparse
import csv
import math
from pathlib import Path
import time

import torch
import torch.ao.quantization as tq

if "qnnpack" in torch.backends.quantized.supported_engines:
    torch.backends.quantized.engine = "qnnpack"
elif "fbgemm" in torch.backends.quantized.supported_engines:
    torch.backends.quantized.engine = "fbgemm"

from lib.models import VGG
from lib.models.qconfig import CustomQConfig
from lib.utils import (
    is_float_model,
    load_model,
    sanitize_state_dict_for_float_model,
)

from network_parser import parse_pytorch, parse_onnx, profile_conv_weights
from layer_info import Conv2DShapeParam, MaxPool2DShapeParam

try:
    import onnx
except ImportError:
    onnx = None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
    )
    parser.add_argument(
        "model_path", type=str, help="path to the ONNX or PyTorch model"
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
        "--arch",
        type=str,
        default="vgg16",
        choices=["vgg8", "vgg16"],
        help="VGG architecture to instantiate for PyTorch parsing",
    )
    parser.add_argument(
        "--accelerator",
        type=str,
        default="sparse_dense",
        choices=["eyeriss", "sparse_dense"],
        help="analytical accelerator model to use",
    )
    parser.add_argument(
        "--input-size",
        type=int,
        default=224,
        help="input image size for PyTorch parser dummy input",
    )
    parser.add_argument(
        "--num-classes",
        type=int,
        default=100,
        help="number of classifier output classes",
    )
    parser.add_argument(
        "-b",
        "--backend",
        type=str,
        default="power2",
        choices=["power2", "dyadic", "qnnpack", "none"],
        help="quantization backend, 'none' for full-precision",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=str,
        default=f"../log/{time.strftime('%Y%m%d-%H%M%S')}",
        help="directory to save the output results",
    )
    parser.add_argument(
        "--plot",
        action="store_true",
        help="plot the roofline model and save it to the output directory",
    )
    parser.add_argument(
        "--plot-combined-roofline",
        action="store_true",
        help="plot available Standard IP, TrIP-like, and Eyeriss rooflines together",
    )
    parser.add_argument(
        "--mode",
        type=str,
        choices=["mapping", "hardware", "none", "dense"],
        default=None,
        help="run the specified mode, analytical model only, DSE for mappings, for DSE for both mappings and hardware",
    )
    parser.add_argument(
        "--analysis-mode",
        type=str,
        choices=["dense", "sparse"],
        default="dense",
        help="analysis model used for exported Conv-layer metrics",
    )
    parser.add_argument(
        "--profile-sparsity",
        action="store_true",
        help="export per-Conv weight sparsity to layer_sparsity.csv",
    )
    parser.add_argument(
        "--glb-sweep",
        action="store_true",
        help="run GLB/tile sweep for the sparse_dense accelerator",
    )
    parser.add_argument(
        "--conv-only",
        action="store_true",
        help="parse Conv layers only and ignore classifier layers",
    )
    parser.add_argument(
        "-v", "--verbose", action="store_true", help="print the results to stdout"
    )
    return parser.parse_args()


def _extract_state_dict(checkpoint):
    if isinstance(checkpoint, dict):
        for key in ("state_dict", "model_state_dict", "model"):
            if key in checkpoint and isinstance(checkpoint[key], dict):
                return checkpoint[key]
    return checkpoint


def _load_state_dict_flexible(
    model: torch.nn.Module,
    model_path,
    conv_only: bool = False,
    analytical_only: bool = False,
) -> torch.nn.Module:
    checkpoint = torch.load(model_path, map_location="cpu")
    state_dict = _extract_state_dict(checkpoint)
    if is_float_model(model):
        state_dict = sanitize_state_dict_for_float_model(state_dict)

    strict = not (conv_only or analytical_only)
    try:
        model.load_state_dict(state_dict, strict=strict)
        return model
    except RuntimeError:
        if not conv_only:
            raise

    current = model.state_dict()
    matched = {}
    for key, value in state_dict.items():
        if key not in current:
            continue
        current_value = current[key]
        if hasattr(value, "shape") and hasattr(current_value, "shape"):
            if tuple(value.shape) != tuple(current_value.shape):
                continue
        matched[key] = value
    missing, unexpected = model.load_state_dict(matched, strict=False)
    print(
        f"Loaded {len(matched)} matching tensors for Conv-only parsing "
        f"({len(missing)} missing, {len(unexpected)} unexpected)."
    )
    return model


def load_torch_model(
    model_path,
    arch: str,
    backend: str,
    input_size: int,
    num_classes: int,
    conv_only: bool = False,
    analytical_only: bool = False,
) -> torch.nn.Module:
    model = VGG(
        arch=arch,
        in_channels=3,
        in_size=input_size,
        num_classes=num_classes,
    )

    backend = backend.lower()
    if arch == "vgg8":
        if backend == "power2":
            return load_model(
                model,
                str(model_path),
                qconfig=CustomQConfig[backend.upper()].value,
                fuse_modules=True,
            )
        if backend == "none":
            return load_model(model, str(model_path))
        raise ValueError(f"Unsupported backend for vgg8: {backend}")

    if backend in ("power2", "dyadic", "qnnpack"):
        model.eval()
        if hasattr(model, "fuse_modules"):
            model.fuse_modules()
        model.qconfig = CustomQConfig[backend.upper()].value
        tq.prepare(model, inplace=True)
        tq.convert(model, inplace=True)
    elif backend != "none":
        raise ValueError(f"Unsupported backend: {backend}")

    return _load_state_dict_flexible(
        model,
        model_path,
        conv_only=conv_only,
        analytical_only=analytical_only,
    )


def parse_network(
    model_path,
    model_format: str,
    backend: str = "power2",
    arch: str = "vgg16",
    input_size: int = 224,
    num_classes: int = 100,
    conv_only: bool = False,
    analytical_only: bool = False,
) -> list:
    if model_format == "torch":
        model = load_torch_model(
            model_path,
            arch=arch,
            backend=backend,
            input_size=input_size,
            num_classes=num_classes,
            conv_only=conv_only,
            analytical_only=analytical_only,
        )
        parsed_layers = parse_pytorch(
            model,
            input_shape=(1, 3, input_size, input_size),
            conv_only=conv_only,
        )
    elif model_format == "onnx":
        if onnx is None:
            raise ImportError("onnx is not installed; use --format torch or install onnx.")
        model = onnx.load(str(model_path))
        parsed_layers = parse_onnx(model)
        if conv_only:
            parsed_layers = [
                layer for layer in parsed_layers if isinstance(layer, Conv2DShapeParam)
            ]
    else:
        raise ValueError(f"Unsupported model format: {model_format}")

    layers = []
    for i, layer in enumerate(parsed_layers):
        if isinstance(layer, Conv2DShapeParam):
            layers.append(layer)
            if i + 1 >= len(parsed_layers) or not isinstance(
                parsed_layers[i + 1], MaxPool2DShapeParam
            ):
                layers.append(None)
        elif isinstance(layer, MaxPool2DShapeParam):
            layers.append(layer)
    return layers


def _write_csv(rows: list, path: Path) -> None:
    fieldnames = list(rows[0].keys()) if rows else []
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def _to_markdown(rows: list) -> str:
    if not rows:
        return ""
    headers = list(rows[0].keys())
    lines = [
        "| " + " | ".join(headers) + " |",
        "| " + " | ".join(["---"] * len(headers)) + " |",
    ]
    for row in rows:
        lines.append("| " + " | ".join(str(row.get(key, "")) for key in headers) + " |")
    return "\n".join(lines)


def export_results(
    results: list,
    output_dir,
    csv_name: str = "output.csv",
    md_name: str = "output.md",
    title: str = "Eyeriss Mapping Report",
) -> list:
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    _write_csv(results, output_dir / csv_name)

    markdown_table = _to_markdown(results)
    with open(output_dir / md_name, "w") as f:
        f.write(f"# {title}\n\n")
        f.write("## Results\n\n")
        f.write(markdown_table)

    print(f"Report is saved to {output_dir}.")
    return results


DENSE_BEST_COLUMNS = [
    "layer",
    "glb_size",
    "tile_m",
    "tile_n",
    "tile_k",
    "dense_macs",
    "dense_ifmap_bytes",
    "dense_weight_bytes",
    "dense_psum_bytes",
    "dense_dram_bytes",
    "dense_compute_cycles",
    "dense_memory_cycles",
    "dense_total_cycles",
    "dense_glb_working_set",
    "dram_bw",
    "glb_bw",
    "pe_array_h",
    "pe_array_w",
    "peak_performance",
    "peak_bandwidth",
    "dense_intensity",
    "intensity",
    "roofline_name",
    "bound_by",
]


SPARSE_BEST_COLUMNS = [
    "layer",
    "recommended_mode",
    "glb_size",
    "tile_m",
    "tile_n",
    "tile_k",
    "density",
    "sparsity",
    "compression_ratio",
    "dense_macs",
    "effective_sparse_macs",
    "skipped_macs",
    "dense_dram_bytes",
    "sparse_dram_bytes",
    "sparse_dram_reduction_ratio",
    "dense_total_cycles",
    "sparse_total_cycles",
    "speedup_sparse_over_dense",
    "trip_utilization",
    "decode_cycles",
    "routing_cycles",
    "reduction_cycles",
    "sparse_glb_working_set",
    "sparse_glb_legal",
    "peak_performance",
    "peak_bandwidth",
    "sparse_intensity",
    "intensity",
    "roofline_name",
]


def _as_bool(value) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.lower() == "true"
    return bool(value)


def _dense_bound_by(row: dict) -> str:
    compute_cycles = float(row["dense_compute_cycles"])
    memory_cycles = float(row["dense_memory_cycles"])
    return "compute" if compute_cycles >= memory_cycles else "memory"


def _layer_sort_key(name: str) -> int:
    try:
        return int(name.rsplit("conv", 1)[-1])
    except (ValueError, IndexError):
        return 0


def _rows_from_table(table) -> list:
    if hasattr(table, "to_dict"):
        return table.to_dict("records")
    return list(table)


def export_dense_best_per_layer(results: list, output_dir) -> list:
    output_dir = Path(output_dir)
    legal_rows = [row for row in results if _as_bool(row.get("dense_glb_legal", False))]
    best_by_layer = {}

    for row in legal_rows:
        layer = row["layer"]
        current = best_by_layer.get(layer)
        if current is None or int(row["dense_total_cycles"]) < int(current["dense_total_cycles"]):
            best_by_layer[layer] = row

    best_rows = []
    for layer in sorted(best_by_layer, key=_layer_sort_key):
        row = dict(best_by_layer[layer])
        row["bound_by"] = _dense_bound_by(row)
        best_rows.append({column: row[column] for column in DENSE_BEST_COLUMNS})

    _write_csv(best_rows, output_dir / "dense_best_per_layer.csv")
    export_dense_summary(best_rows, output_dir / "dense_summary.md")
    return best_rows


def export_dense_summary(best_rows: list, path: Path) -> None:
    num_layers = len(best_rows)
    total_macs = sum(int(row["dense_macs"]) for row in best_rows)
    total_dram = sum(int(row["dense_dram_bytes"]) for row in best_rows)
    total_cycles = sum(int(row["dense_total_cycles"]) for row in best_rows)
    compute_bound = sum(1 for row in best_rows if row["bound_by"] == "compute")
    memory_bound = sum(1 for row in best_rows if row["bound_by"] == "memory")

    with open(path, "w") as f:
        f.write("# Dense Summary\n\n")
        f.write(f"- Number of Conv layers: {num_layers}\n")
        f.write(f"- Total dense_macs: {total_macs}\n")
        f.write(f"- Total dense_dram_bytes: {total_dram}\n")
        f.write(f"- Total dense_total_cycles: {total_cycles}\n")
        f.write(f"- Number of compute-bound layers: {compute_bound}\n")
        f.write(f"- Number of memory-bound layers: {memory_bound}\n\n")
        f.write("## Best Tile Per Layer\n\n")
        f.write(_to_markdown(best_rows))


def export_sparse_best_per_layer(results: list, output_dir) -> list:
    output_dir = Path(output_dir)
    legal_rows = [row for row in results if _as_bool(row.get("sparse_glb_legal", False))]
    best_by_layer = {}

    for row in legal_rows:
        layer = row["layer"]
        current = best_by_layer.get(layer)
        if current is None or int(row["sparse_total_cycles"]) < int(current["sparse_total_cycles"]):
            best_by_layer[layer] = row

    best_rows = []
    for layer in sorted(best_by_layer, key=_layer_sort_key):
        row = dict(best_by_layer[layer])
        best_rows.append({column: row[column] for column in SPARSE_BEST_COLUMNS})

    _write_csv(best_rows, output_dir / "sparse_best_per_layer.csv")
    export_sparse_summary(best_rows, output_dir / "sparse_summary.md")
    return best_rows


def _geomean(values: list) -> float:
    positive = [float(value) for value in values if float(value) > 0]
    if not positive:
        return 0.0
    return math.exp(sum(math.log(value) for value in positive) / len(positive))


def export_sparse_summary(best_rows: list, path: Path) -> None:
    num_layers = len(best_rows)
    total_dense_macs = sum(int(row["dense_macs"]) for row in best_rows)
    total_sparse_macs = sum(int(row["effective_sparse_macs"]) for row in best_rows)
    total_dense_dram = sum(int(row["dense_dram_bytes"]) for row in best_rows)
    total_sparse_dram = sum(int(row["sparse_dram_bytes"]) for row in best_rows)
    total_dense_cycles = sum(int(row["dense_total_cycles"]) for row in best_rows)
    total_sparse_cycles = sum(int(row["sparse_total_cycles"]) for row in best_rows)
    geomean_speedup = _geomean([row["speedup_sparse_over_dense"] for row in best_rows])
    standard_ip = sum(1 for row in best_rows if row["recommended_mode"] == "standard_ip")
    trip = sum(1 for row in best_rows if row["recommended_mode"] == "trip")
    too_sparse = sum(
        1
        for row in best_rows
        if row["recommended_mode"] == "too_sparse_for_trip_future_trgt_trgs"
    )

    with open(path, "w") as f:
        f.write("# Sparse Summary\n\n")
        f.write(f"- Number of Conv layers: {num_layers}\n")
        f.write(f"- Total dense MACs: {total_dense_macs}\n")
        f.write(f"- Total effective sparse MACs: {total_sparse_macs}\n")
        f.write(f"- Total dense DRAM bytes: {total_dense_dram}\n")
        f.write(f"- Total sparse DRAM bytes: {total_sparse_dram}\n")
        f.write(f"- Total dense cycles: {total_dense_cycles}\n")
        f.write(f"- Total sparse cycles: {total_sparse_cycles}\n")
        f.write(f"- Geometric mean speedup: {geomean_speedup}\n")
        f.write(f"- Layers recommended as standard_ip: {standard_ip}\n")
        f.write(f"- Layers recommended as trip: {trip}\n")
        f.write(
            "- Layers marked too_sparse_for_trip_future_trgt_trgs: "
            f"{too_sparse}\n\n"
        )
        f.write("## Best Sparse Tile Per Layer\n\n")
        f.write(_to_markdown(best_rows))


def _best_rows_by_layer_and_glb(
    rows: list,
    legal_key: str,
    cycle_key: str,
) -> list:
    best = {}
    for row in rows:
        if not _as_bool(row.get(legal_key, False)):
            continue
        key = (row["layer"], int(row["glb_size"]))
        current = best.get(key)
        if current is None or int(row[cycle_key]) < int(current[cycle_key]):
            best[key] = row
    return [
        best[key]
        for key in sorted(best, key=lambda item: (int(item[1]), _layer_sort_key(item[0])))
    ]


def export_glb_sweep_outputs(rows: list, output_dir) -> dict:
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    _write_csv(rows, output_dir / "glb_sweep_raw.csv")
    best_dense = _best_rows_by_layer_and_glb(
        rows,
        legal_key="dense_glb_legal",
        cycle_key="dense_total_cycles",
    )
    best_sparse = _best_rows_by_layer_and_glb(
        rows,
        legal_key="sparse_glb_legal",
        cycle_key="sparse_total_cycles",
    )
    _write_csv(best_dense, output_dir / "glb_sweep_best_dense.csv")
    _write_csv(best_sparse, output_dir / "glb_sweep_best_sparse.csv")

    summary_rows = build_glb_sweep_summary(rows, best_dense, best_sparse)
    _write_csv(summary_rows, output_dir / "glb_sweep_summary.csv")
    export_glb_sweep_summary_md(summary_rows, best_sparse, output_dir / "glb_sweep_summary.md")
    return {
        "raw": rows,
        "best_dense": best_dense,
        "best_sparse": best_sparse,
        "summary": summary_rows,
    }


def build_glb_sweep_summary(
    raw_rows: list,
    best_dense: list,
    best_sparse: list,
) -> list:
    glb_sizes = sorted({int(row["glb_size"]) for row in raw_rows})
    layers = sorted({row["layer"] for row in raw_rows}, key=_layer_sort_key)
    summary_rows = []

    for glb_size in glb_sizes:
        dense_rows = [row for row in best_dense if int(row["glb_size"]) == glb_size]
        sparse_rows = [row for row in best_sparse if int(row["glb_size"]) == glb_size]
        total_dense_macs = sum(int(row["dense_macs"]) for row in dense_rows)
        total_sparse_macs = sum(int(row["effective_sparse_macs"]) for row in sparse_rows)
        total_dense_dram = sum(int(row["dense_dram_bytes"]) for row in dense_rows)
        total_sparse_dram = sum(int(row["sparse_dram_bytes"]) for row in sparse_rows)
        total_dense_cycles = (
            sum(int(row["dense_total_cycles"]) for row in dense_rows)
            if dense_rows
            else math.nan
        )
        total_sparse_cycles = (
            sum(int(row["sparse_total_cycles"]) for row in sparse_rows)
            if sparse_rows
            else math.nan
        )
        avg_trip_utilization = (
            sum(float(row["trip_utilization"]) for row in sparse_rows) / len(sparse_rows)
            if sparse_rows
            else 0.0
        )
        summary_rows.append(
            {
                "glb_size": glb_size,
                "num_layers": len(layers),
                "legal_dense_layers": len(dense_rows),
                "legal_sparse_layers": len(sparse_rows),
                "total_dense_macs": total_dense_macs,
                "total_effective_sparse_macs": total_sparse_macs,
                "total_dense_dram_bytes": total_dense_dram,
                "total_sparse_dram_bytes": total_sparse_dram,
                "total_dense_cycles": total_dense_cycles,
                "total_sparse_cycles": total_sparse_cycles,
                "speedup_sparse_over_dense": (
                    total_dense_cycles / total_sparse_cycles
                    if not math.isnan(total_dense_cycles)
                    and not math.isnan(total_sparse_cycles)
                    and total_sparse_cycles
                    else 0.0
                ),
                "dense_dram_reduction_ratio": (
                    total_sparse_dram / total_dense_dram
                    if total_dense_dram
                    else 0.0
                ),
                "average_trip_utilization": avg_trip_utilization,
                "standard_ip_layer_count": sum(
                    1 for row in sparse_rows if row["recommended_mode"] == "standard_ip"
                ),
                "trip_layer_count": sum(
                    1 for row in sparse_rows if row["recommended_mode"] == "trip"
                ),
                "too_sparse_layer_count": sum(
                    1
                    for row in sparse_rows
                    if row["recommended_mode"] == "too_sparse_for_trip_future_trgt_trgs"
                ),
            }
        )
    return summary_rows


def export_glb_sweep_summary_md(summary_rows: list, best_sparse: list, path: Path) -> None:
    if not summary_rows:
        with open(path, "w") as f:
            f.write("# GLB Sweep Summary\n\nNo rows were generated.\n")
        return

    num_layers = int(summary_rows[0]["num_layers"])
    dense_complete = [
        row
        for row in summary_rows
        if int(row["legal_dense_layers"]) == num_layers
        and not math.isnan(float(row["total_dense_cycles"]))
    ]
    sparse_complete = [
        row
        for row in summary_rows
        if int(row["legal_sparse_layers"]) == num_layers
        and not math.isnan(float(row["total_sparse_cycles"]))
    ]
    best_sparse_glb = (
        min(sparse_complete, key=lambda row: float(row["total_sparse_cycles"]))
        if sparse_complete
        else None
    )
    best_dense_glb = (
        min(dense_complete, key=lambda row: float(row["total_dense_cycles"]))
        if dense_complete
        else None
    )
    smallest_dense_legal = min(dense_complete, key=lambda row: int(row["glb_size"])) if dense_complete else None
    smallest_sparse_legal = min(sparse_complete, key=lambda row: int(row["glb_size"])) if sparse_complete else None
    all_legal = [
        row
        for row in summary_rows
        if int(row["legal_dense_layers"]) == num_layers
        and int(row["legal_sparse_layers"]) == num_layers
    ]
    all_legal_text = (
        ", ".join(f"{int(row['glb_size']) // 1024}KB" for row in all_legal)
        if all_legal
        else "none"
    )
    row_16kb = next((row for row in summary_rows if int(row["glb_size"]) == 16 * 1024), None)
    if row_16kb is None:
        enough_16kb = "16KB was not part of the sweep."
    elif (
        int(row_16kb["legal_dense_layers"]) == num_layers
        and int(row_16kb["legal_sparse_layers"]) == num_layers
    ):
        enough_16kb = "Yes, 16KB GLB has legal dense and sparse tiles for all layers."
    else:
        enough_16kb = (
            "No, 16KB GLB does not make all selected dense/sparse tile choices legal "
            f"({row_16kb['legal_dense_layers']} dense, "
            f"{row_16kb['legal_sparse_layers']} sparse legal layers)."
        )

    comparable_rows = [
        row
        for row in summary_rows
        if int(row["legal_dense_layers"]) == num_layers
        and int(row["legal_sparse_layers"]) == num_layers
        and not math.isnan(float(row["total_dense_cycles"]))
        and not math.isnan(float(row["total_sparse_cycles"]))
    ]
    best_comparable = (
        min(comparable_rows, key=lambda row: float(row["total_sparse_cycles"]))
        if comparable_rows
        else None
    )
    if best_comparable is None:
        sparse_cycle_gain = (
            "No GLB size has all dense and sparse layers legal, so sparse cycle "
            "improvement is not comparable."
        )
    elif float(best_comparable["speedup_sparse_over_dense"]) > 1.0:
        sparse_cycle_gain = "Sparse mode improves total cycles."
    else:
        sparse_cycle_gain = "Sparse mode mainly reduces DRAM traffic and does not improve total cycles."
    memory_bound_layers = [
        row["layer"]
        for row in best_sparse
        if int(row["sparse_memory_cycles"]) > int(row["sparse_compute_cycles"])
    ]
    memory_bound_text = ", ".join(memory_bound_layers) if memory_bound_layers else "none"

    with open(path, "w") as f:
        f.write("# GLB Sweep Summary\n\n")
        f.write(
            "- Smallest GLB with all dense layers legal: "
            f"{int(smallest_dense_legal['glb_size']) // 1024}KB\n"
            if smallest_dense_legal is not None
            else "- Smallest GLB with all dense layers legal: none\n"
        )
        f.write(
            "- Smallest GLB with all sparse layers legal: "
            f"{int(smallest_sparse_legal['glb_size']) // 1024}KB\n"
            if smallest_sparse_legal is not None
            else "- Smallest GLB with all sparse layers legal: none\n"
        )
        f.write(
            "- Best GLB by dense_total_cycles: "
            f"{int(best_dense_glb['glb_size']) // 1024}KB "
            f"({best_dense_glb['total_dense_cycles']} cycles)\n"
            if best_dense_glb is not None
            else "- Best GLB by dense_total_cycles: none\n"
        )
        f.write(
            "- Best GLB by sparse_total_cycles: "
            f"{int(best_sparse_glb['glb_size']) // 1024}KB "
            f"({best_sparse_glb['total_sparse_cycles']} cycles)\n"
            if best_sparse_glb is not None
            else "- Best GLB by sparse_total_cycles: none\n"
        )
        f.write(f"- GLB sizes with all layers legal: {all_legal_text}\n")
        f.write(f"- Is 16KB GLB enough: {enough_16kb}\n")
        f.write(f"- Sparse mode interpretation: {sparse_cycle_gain}\n")
        f.write(f"- Memory-bound sparse layers: {memory_bound_text}\n\n")
        f.write("## Network Summary By GLB Size\n\n")
        f.write(_to_markdown(summary_rows))


def plot_glb_sweep(summary_rows: list, output_dir) -> None:
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    output_dir = Path(output_dir)
    x = [int(row["glb_size"]) // 1024 for row in summary_rows]
    total_layers = int(summary_rows[0]["num_layers"]) if summary_rows else 0
    incomplete = [
        row
        for row in summary_rows
        if int(row["legal_dense_layers"]) < total_layers
        or int(row["legal_sparse_layers"]) < total_layers
    ]
    if incomplete:
        sizes = ", ".join(f"{int(row['glb_size']) // 1024}KB" for row in incomplete)
        print(f"Warning: not all layers are legal for GLB sizes: {sizes}")

    def legal_value(row: dict, value_key: str, legal_key: str):
        if int(row[legal_key]) < total_layers:
            return math.nan
        value = float(row[value_key])
        return value

    def save_line_plot(filename: str, ylabel: str, series: list[tuple[str, list]]) -> None:
        plt.figure(figsize=(7, 5))
        for label, values in series:
            clean_x = []
            clean_values = []
            for x_value, y_value in zip(x, values):
                y_float = float(y_value)
                if math.isnan(y_float):
                    continue
                clean_x.append(x_value)
                clean_values.append(y_float)
            plt.plot(clean_x, clean_values, marker="o", label=label)
        plt.xlabel("GLB size (KB)")
        plt.ylabel(ylabel)
        plt.grid(which="both", linestyle="--", linewidth=0.5)
        plt.legend()
        plt.tight_layout()
        plt.savefig(output_dir / filename)
        plt.close()

    save_line_plot(
        "glb_speedup_vs_size.png",
        "Speedup sparse over dense",
        [
            (
                "speedup",
                [
                    float(row["speedup_sparse_over_dense"])
                    if int(row["legal_dense_layers"]) == total_layers
                    and int(row["legal_sparse_layers"]) == total_layers
                    else math.nan
                    for row in summary_rows
                ],
            )
        ],
    )
    save_line_plot(
        "glb_dram_vs_size.png",
        "DRAM bytes",
        [
            (
                "dense",
                [
                    legal_value(row, "total_dense_dram_bytes", "legal_dense_layers")
                    for row in summary_rows
                ],
            ),
            (
                "sparse",
                [
                    legal_value(row, "total_sparse_dram_bytes", "legal_sparse_layers")
                    for row in summary_rows
                ],
            ),
        ],
    )
    save_line_plot(
        "glb_cycles_vs_size.png",
        "Cycles",
        [
            (
                "dense",
                [
                    legal_value(row, "total_dense_cycles", "legal_dense_layers")
                    for row in summary_rows
                ],
            ),
            (
                "sparse",
                [
                    legal_value(row, "total_sparse_cycles", "legal_sparse_layers")
                    for row in summary_rows
                ],
            ),
        ],
    )
    save_line_plot(
        "glb_legal_layers_vs_size.png",
        "Legal layer count",
        [
            ("dense", [int(row["legal_dense_layers"]) for row in summary_rows]),
            ("sparse", [int(row["legal_sparse_layers"]) for row in summary_rows]),
        ],
    )


def run_glb_sweep(layers: list, sparsity_profiles: list, args: argparse.Namespace) -> list:
    from analytical_model import SparseDenseAcceleratorMapper

    conv_layers = _conv_layers_from_pairs(layers)
    mapper = SparseDenseAcceleratorMapper(name=args.arch)
    table = mapper.run_network(
        conv_layers,
        sparsity_profiles,
        analysis_mode=args.analysis_mode,
    )
    return _rows_from_table(table)


def _conv_layers_from_pairs(layers: list) -> list:
    return [layers[i] for i in range(0, len(layers), 2) if isinstance(layers[i], Conv2DShapeParam)]


def _build_sparsity_profiles(
    model_path: Path,
    args: argparse.Namespace,
    conv_layers: list,
) -> list:
    if args.format != "torch":
        return [None for _ in conv_layers]

    from analytical_model import LayerSparsityProfile, profile_conv_weight
    from analytical_model.sparsity_model import conv_module_types

    model = load_torch_model(
        model_path,
        arch=args.arch,
        backend=args.backend,
        input_size=args.input_size,
        num_classes=args.num_classes,
        conv_only=args.conv_only,
        analytical_only=True,
    )
    conv_modules = [
        module for module in model.modules() if isinstance(module, conv_module_types())
    ]
    profiles = []
    for idx, (module, conv) in enumerate(zip(conv_modules, conv_layers)):
        layer_name = f"{args.arch}.conv{idx}"
        profiles.append(profile_conv_weight(module, layer_name))

    for idx in range(len(profiles), len(conv_layers)):
        conv = conv_layers[idx]
        total = conv.M * conv.C * conv.R * conv.S
        bitmask = ((total + 63) // 64) * 8
        profiles.append(
            LayerSparsityProfile(
                layer_name=f"{args.arch}.conv{idx}",
                total_weights=total,
                nonzero_weights=total,
                zero_weights=0,
                density=1.0,
                sparsity=0.0,
                dense_weight_bytes=total,
                sparse_weight_value_bytes=total,
                weight_bitmask_bytes=bitmask,
                sparse_weight_total_bytes=total + bitmask,
                compression_ratio=(total + bitmask) / total if total else 0.0,
            )
        )
    return profiles


def run_sparse_dense_accelerator(
    layers: list,
    sparsity_profiles: list,
    args: argparse.Namespace,
) -> list:
    from analytical_model import SparseDenseAcceleratorMapper

    results = []
    conv_idx = 0
    for i in range(0, len(layers), 2):
        conv = layers[i]
        if not isinstance(conv, Conv2DShapeParam):
            continue
        mapper = SparseDenseAcceleratorMapper(
            name=f"{args.arch}.conv{conv_idx}",
            sparsity_profile=sparsity_profiles[conv_idx],
        )
        results.extend(
            mapper.run(
                conv,
                mode=args.analysis_mode,
                num_solutions=0,
            )
        )
        conv_idx += 1
    return results


def run_eyeriss_accelerator(layers: list, args: argparse.Namespace) -> list:
    mode = args.mode.lower() if args.mode is not None else None
    if mode is None and args.analysis_mode == "dense":
        mode = "dense"
    from analytical_model import EyerissMapper

    results: list = []
    for i in range(0, len(layers), 2):
        mapper = EyerissMapper(name=f"{args.arch}.conv{i // 2}")
        res = mapper.run(layers[i], layers[i + 1], num_solutions=1, mode=mode)
        for row in res:
            row["roofline_name"] = "Eyeriss Legacy"
        results.extend(res)
    return results


def roofline_series_from_rows(
    rows: list,
    roofline_name: str,
    intensity_key: str,
    legal_key: str,
    cycle_key: str,
) -> dict:
    best_rows = {}
    for row in rows:
        if not _as_bool(row.get(legal_key, False)):
            continue
        layer = row["layer"]
        current = best_rows.get(layer)
        if current is None or int(row[cycle_key]) < int(current[cycle_key]):
            best_rows[layer] = row
    ordered_layers = sorted(best_rows, key=_layer_sort_key)
    first = best_rows[ordered_layers[0]] if ordered_layers else {}
    return {
        "roofline_name": roofline_name,
        "peak_performance": float(first.get("peak_performance", 256)),
        "peak_bandwidth": float(first.get("peak_bandwidth", 16)),
        "workloads": {
            layer: float(best_rows[layer][intensity_key])
            for layer in ordered_layers
        },
    }


def plot_available_combined_roofline(output_dir: Path, extra_series: list | None = None) -> None:
    from roofline import load_roofline_series_from_csv, plot_combined_roofline

    series = list(extra_series or [])
    candidates = [
        (
            output_dir / "dense_best_per_layer.csv",
            "Standard IP 16x16",
            "dense_intensity",
        ),
        (
            output_dir / "sparse_best_per_layer.csv",
            "TrIP-like 16x16",
            "sparse_intensity",
        ),
        (
            output_dir / "output.csv",
            "Eyeriss Legacy",
            "intensity",
        ),
    ]
    for path, name, intensity_col in candidates:
        if any(item["roofline_name"] == name for item in series):
            continue
        if path.exists():
            series.append(
                load_roofline_series_from_csv(
                    path,
                    roofline_name=name,
                    intensity_col=intensity_col,
                )
            )
    if series:
        plot_combined_roofline(series, output_dir / "combined_roofline.png")
    else:
        print("No roofline CSVs available for combined_roofline.png.")


def main():
    args = parse_args()
    model_path = Path(args.model_path).absolute()
    output_dir = Path(args.output).absolute()

    if args.profile_sparsity:
        if args.format != "torch":
            raise ValueError("--profile-sparsity currently supports --format torch.")
        model = load_torch_model(
            model_path,
            arch=args.arch,
            backend=args.backend,
            input_size=args.input_size,
            num_classes=args.num_classes,
            conv_only=args.conv_only,
            analytical_only=True,
        )
        sparsity_rows = profile_conv_weights(model)
        output_dir.mkdir(parents=True, exist_ok=True)
        _write_csv(sparsity_rows, output_dir / "layer_sparsity.csv")
        if args.verbose:
            print(_to_markdown(sparsity_rows))
        print(f"Sparsity profile is saved to {output_dir / 'layer_sparsity.csv'}.")

    layers = parse_network(
        model_path,
        args.format,
        args.backend,
        arch=args.arch,
        input_size=args.input_size,
        num_classes=args.num_classes,
        conv_only=args.conv_only,
        analytical_only=args.accelerator == "sparse_dense" or args.analysis_mode == "dense",
    )

    if args.glb_sweep:
        if args.accelerator != "sparse_dense":
            raise ValueError("--glb-sweep is only supported for --accelerator sparse_dense.")
        conv_layers = _conv_layers_from_pairs(layers)
        sparsity_profiles = _build_sparsity_profiles(model_path, args, conv_layers)
        glb_rows = run_glb_sweep(layers, sparsity_profiles, args)
        glb_outputs = export_glb_sweep_outputs(glb_rows, output_dir)
        if args.plot:
            plot_glb_sweep(glb_outputs["summary"], output_dir)
        return

    if args.accelerator == "sparse_dense":
        conv_layers = _conv_layers_from_pairs(layers)
        sparsity_profiles = _build_sparsity_profiles(model_path, args, conv_layers)
        results = run_sparse_dense_accelerator(layers, sparsity_profiles, args)
        report_title = "Sparse/Dense Accelerator Analytical Report"
    else:
        results = run_eyeriss_accelerator(layers, args)
        report_title = "Eyeriss Mapping Report"

    if args.accelerator == "eyeriss":
        csv_name = "output.csv"
        md_name = "output.md"
    elif args.analysis_mode == "dense":
        csv_name = "dense_output.csv"
        md_name = "dense_output.md"
    elif args.accelerator == "sparse_dense":
        csv_name = "sparse_output.csv"
        md_name = "sparse_output.md"
    else:
        csv_name = "output.csv"
        md_name = "output.md"
    export_results(
        results,
        output_dir,
        csv_name=csv_name,
        md_name=md_name,
        title=report_title,
    )
    if args.accelerator == "sparse_dense" and args.analysis_mode == "dense":
        export_dense_best_per_layer(results, output_dir)
    elif args.accelerator == "sparse_dense" and args.analysis_mode == "sparse":
        export_sparse_best_per_layer(results, output_dir)

    if args.plot:
        from roofline import plot_roofline_from_csv

        if args.accelerator == "sparse_dense":
            best_name = (
                "sparse_best_per_layer.csv"
                if args.analysis_mode == "sparse"
                else "dense_best_per_layer.csv"
            )
            plot_name = (
                "trip_roofline.png"
                if args.analysis_mode == "sparse"
                else "standard_ip_roofline.png"
            )
            plot_csv = output_dir / best_name
            if not plot_csv.exists():
                plot_csv = output_dir / csv_name
            plot_roofline_from_csv(plot_csv, output_dir / plot_name)
        else:
            plot_roofline_from_csv(output_dir / csv_name, output_dir / "eyeriss_roofline.png")

    if args.plot_combined_roofline:
        extra_series = []
        if args.accelerator == "sparse_dense":
            extra_series = [
                roofline_series_from_rows(
                    results,
                    roofline_name="Standard IP 16x16",
                    intensity_key="dense_intensity",
                    legal_key="dense_glb_legal",
                    cycle_key="dense_total_cycles",
                ),
                roofline_series_from_rows(
                    results,
                    roofline_name="TrIP-like 16x16",
                    intensity_key="sparse_intensity",
                    legal_key="sparse_glb_legal",
                    cycle_key="sparse_total_cycles",
                ),
            ]
        plot_available_combined_roofline(output_dir, extra_series=extra_series)


if __name__ == "__main__":
    main()
