from __future__ import annotations

import argparse
from collections import OrderedDict
from pathlib import Path
import re

import numpy as np
import torch

import config
from dump_writer import (
    dump_sparse_bitmask_tensor,
    dump_hex_txt,
    dump_meta_txt,
    dump_numeric_txt,
    dump_quant_meta_txt,
    dump_tensor_txt,
    ensure_dir,
)
from gemm_converter import convert_layer, tensor_int_repr
from hook_extractor import extract_layer_records
from image_loader import load_image_tensor
from model_loader import load_model
from verify import verify_layer


GEMM_LAYER_TYPES = {"Conv2d", "Linear"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    parser.add_argument("--model-path", type=Path, default=config.default_model_path)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, default=config.default_output_dir)
    parser.add_argument("--target-layer", type=str, default=config.default_target_layer)
    parser.add_argument("--device", type=str, default="auto")
    parser.add_argument("--dump-all", action="store_true", default=False)
    parser.add_argument("--max-layers", type=int, default=None)
    parser.add_argument("--dtype", choices=config.dump_dtype_choices, default=config.dump_dtype)
    parser.add_argument("--include-activations", action="store_true", help="Also dump ReLU outputs.")
    parser.add_argument("--include-pool", action="store_true", help="Also dump MaxPool2d outputs.")
    parser.add_argument("--module-types", type=str, default=config.default_module_types)
    parser.add_argument("--emit-bitmask", action="store_true", help="Emit hw_bitmask sparse values + 64-bit bitmask files for GEMM A/B/output.")
    return parser.parse_args()


def resolve_module_types(args: argparse.Namespace) -> list[str]:
    if args.module_types.strip().lower() == "all":
        module_types = ["all"]
    else:
        module_types = [item.strip() for item in args.module_types.split(",") if item.strip()]
    lowered = {item.lower() for item in module_types}
    if "all" not in lowered:
        if args.include_activations and "ReLU" not in module_types:
            module_types.append("ReLU")
        if args.include_pool and "MaxPool2d" not in module_types:
            module_types.append("MaxPool2d")
    return module_types


def shape_text(shape) -> tuple[int, ...]:
    return tuple(int(v) for v in shape)


def safe_name(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9_]+", "_", name.replace(".", "_")).strip("_")


def layer_suffix(layer_type: str) -> str:
    return {
        "Conv2d": "conv",
        "Linear": "linear",
        "ReLU": "relu",
        "MaxPool2d": "maxpool",
    }.get(layer_type, safe_name(layer_type).lower())


def parse_layer_id(layer_name: str, layer_type: str) -> str:
    suffix = layer_suffix(layer_type)
    if layer_name.startswith("features."):
        try:
            return f"layer_{int(layer_name.split('.')[1]):02d}_{suffix}"
        except (IndexError, ValueError):
            pass
    if layer_name.startswith("classifier."):
        try:
            return f"layer_classifier_{int(layer_name.split('.')[1]):02d}_{suffix}"
        except (IndexError, ValueError):
            pass
    if layer_name == "classifier":
        return f"layer_classifier_00_{suffix}"
    return f"layer_{safe_name(layer_name)}_{suffix}"


def layer_dir_name(layer_name: str, layer_type: str) -> str:
    return parse_layer_id(layer_name, layer_type)


def tuple_or_na(shape) -> tuple[int, ...] | str:
    return tuple(int(v) for v in shape) if shape is not None else "not_applicable"


def module_tuple(module, attr: str) -> tuple[int, ...] | str:
    value = getattr(module, attr, None)
    if value is None:
        return "not_applicable"
    if isinstance(value, tuple):
        return tuple(int(v) for v in value)
    return (int(value),)


def input_filename(record) -> str:
    return "input_activation_nchw.txt" if len(record.input_shape) == 4 else "input_activation_nc.txt"


def output_filename(record) -> str:
    return "output_nchw.txt" if len(record.output_shape) == 4 else "output_nc.txt"


def tensor_dtype_name(tensor: torch.Tensor | None) -> str:
    if tensor is None:
        return "not_applicable"
    return str(tensor.dtype).replace("torch.", "")


def bitwidth_for_array(array) -> int | None:
    dtype = np.asarray(array).dtype
    if np.issubdtype(dtype, np.floating):
        return None
    if dtype.itemsize <= 1:
        return 8
    if dtype.itemsize <= 2:
        return 16
    return 32


def predicted_class_index(model_output: torch.Tensor) -> int:
    logits = model_output.dequantize() if model_output.is_quantized else model_output
    return int(logits.argmax().item())


def write_layer_outputs(layer_dir: Path, dump_index: int, record, gemm_data, emit_bitmask: bool = False) -> list[str]:
    generated: list[str] = []
    pytorch_dir = layer_dir / "pytorch"
    ensure_dir(pytorch_dir)

    input_layout = "NCHW" if len(record.input_shape) == 4 else "NC"
    output_layout = "NCHW" if len(record.output_shape) == 4 else "NC"
    in_file = input_filename(record)
    out_file = output_filename(record)

    dump_tensor_txt(pytorch_dir / in_file, tensor_int_repr(record.input_activation), dtype=tensor_dtype_name(record.input_activation), layout=input_layout, tensor_name="input_activation", header=False)
    generated.append(str(Path("pytorch") / in_file))

    if record.weight is not None:
        weight_layout = "OIHW" if record.layer_type == "Conv2d" else "OI"
        weight_file = "weight_oihw.txt" if record.layer_type == "Conv2d" else "weight_oi.txt"
        dump_tensor_txt(pytorch_dir / weight_file, tensor_int_repr(record.weight), dtype=tensor_dtype_name(record.weight), layout=weight_layout, tensor_name="weight", header=False)
        generated.append(str(Path("pytorch") / weight_file))
    if record.bias is not None:
        dump_tensor_txt(pytorch_dir / "bias.txt", record.bias, dtype=tensor_dtype_name(record.bias), layout="channel", tensor_name="bias", header=False)
        generated.append(str(Path("pytorch") / "bias.txt"))

    dump_tensor_txt(pytorch_dir / out_file, tensor_int_repr(record.output_activation), dtype=tensor_dtype_name(record.output_activation), layout=output_layout, tensor_name="output_activation", header=False)
    generated.append(str(Path("pytorch") / out_file))
    dump_meta_txt(pytorch_dir / "local_summary.txt", build_pytorch_local_summary(record, in_file, out_file))
    generated.append(str(Path("pytorch") / "local_summary.txt"))

    if gemm_data is not None:
        generated.extend(write_gemm_outputs(layer_dir / "gemm", record, gemm_data))
        generated.extend(write_hw_outputs(layer_dir / "hw", record, gemm_data))
        if emit_bitmask:
            generated.extend(write_hw_bitmask_outputs(layer_dir / "hw_bitmask", record, gemm_data))
        dump_quant_meta_txt(layer_dir / "quant_meta.txt", gemm_data.quant_meta)
        generated.append("quant_meta.txt")

    dump_meta_txt(layer_dir / "layer_meta.txt", build_layer_meta(dump_index, record, gemm_data))
    generated.append("layer_meta.txt")
    return generated


def write_gemm_outputs(gemm_dir: Path, record, gemm_data) -> list[str]:
    ensure_dir(gemm_dir)
    a_name = "A_im2col_mk.txt" if record.layer_type == "Conv2d" else "A_input_mk.txt"
    files = OrderedDict()
    files[a_name] = gemm_data.A
    files["B_weight_kn.txt"] = gemm_data.B
    if gemm_data.bias is not None:
        files["bias_n.txt"] = gemm_data.bias
    files["psum_mn.txt"] = gemm_data.psum
    files["output_mn.txt"] = gemm_data.output

    for file_name, data in files.items():
        dump_numeric_txt(gemm_dir / file_name, data)
    dump_meta_txt(gemm_dir / "local_summary.txt", build_gemm_local_summary(record, gemm_data))
    return [str(Path("gemm") / name) for name in ["local_summary.txt", *files.keys()]]


def write_hw_outputs(hw_dir: Path, record, gemm_data) -> list[str]:
    ensure_dir(hw_dir)
    files = OrderedDict()
    files["input_A_hex.txt"] = (gemm_data.A, bitwidth_for_array(gemm_data.A))
    files["input_B_hex.txt"] = (gemm_data.B, bitwidth_for_array(gemm_data.B))
    if gemm_data.bias is not None:
        files["input_bias_hex.txt"] = (gemm_data.bias, bitwidth_for_array(gemm_data.bias))
    files["golden_psum_hex.txt"] = (gemm_data.psum, bitwidth_for_array(gemm_data.psum))
    files["golden_output_hex.txt"] = (gemm_data.output, bitwidth_for_array(gemm_data.output))

    for file_name, (data, bitwidth) in files.items():
        if bitwidth is None:
            raise TypeError(f"{file_name} has unsupported dtype for hex dump: {np.asarray(data).dtype}")
        dump_hex_txt(hw_dir / file_name, data, bitwidth)
    extra_files = []
    requant_shift_pc = gemm_data.quant_meta.get("requant_shift_per_channel")
    if isinstance(requant_shift_pc, list) and all(isinstance(item, int) for item in requant_shift_pc):
        dump_numeric_txt(hw_dir / "requant_shift_per_channel.txt", np.asarray(requant_shift_pc, dtype=np.int32))
        extra_files.append("requant_shift_per_channel.txt")
    dump_meta_txt(hw_dir / "local_summary.txt", build_hw_local_summary(record, gemm_data, files))
    return [str(Path("hw") / name) for name in ["local_summary.txt", *files.keys(), *extra_files]]


def write_hw_bitmask_outputs(hw_bitmask_dir: Path, record, gemm_data) -> list[str]:
    ensure_dir(hw_bitmask_dir)
    a_info = dump_sparse_bitmask_tensor(hw_bitmask_dir / "input_A", gemm_data.A, bitwidth_for_array(gemm_data.A))
    b_info = dump_sparse_bitmask_tensor(hw_bitmask_dir / "input_B", gemm_data.B, bitwidth_for_array(gemm_data.B))
    out_info = dump_sparse_bitmask_tensor(hw_bitmask_dir / "golden_output", gemm_data.output, bitwidth_for_array(gemm_data.output))
    dump_meta_txt(hw_bitmask_dir / "local_summary.txt", build_hw_bitmask_local_summary(record, a_info, b_info, out_info))
    files = [
        "local_summary.txt",
        a_info["values_file"],
        a_info["bitmask_file"],
        b_info["values_file"],
        b_info["bitmask_file"],
        out_info["values_file"],
        out_info["bitmask_file"],
    ]
    return [str(Path("hw_bitmask") / name) for name in files]


def build_layer_meta(dump_index: int, record, gemm_data) -> OrderedDict:
    meta = OrderedDict()
    meta["dump_index"] = dump_index
    meta["layer_name"] = record.name
    meta["layer_type"] = record.layer_type
    meta["module_type"] = type(record.module).__name__
    meta["input_shape"] = shape_text(record.input_shape)
    meta["weight_shape"] = tuple_or_na(record.weight.shape if record.weight is not None else None)
    meta["bias_shape"] = tuple_or_na(record.bias.shape if record.bias is not None else None)
    meta["output_shape"] = shape_text(record.output_shape)
    meta["stride"] = module_tuple(record.module, "stride")
    meta["padding"] = module_tuple(record.module, "padding")
    meta["dilation"] = module_tuple(record.module, "dilation")
    meta["groups"] = getattr(record.module, "groups", "not_applicable")
    if gemm_data is not None:
        meta["gemm_M"] = gemm_data.M
        meta["gemm_K"] = gemm_data.K
        meta["gemm_N"] = gemm_data.N
        meta["gemm_A_layout"] = config.gemm_layout
        meta["gemm_B_layout"] = config.gemm_layout
        meta["gemm_C_layout"] = config.gemm_layout
        meta["psum_dtype"] = gemm_data.dtypes["psum"]
    else:
        meta["gemm_M"] = "not_applicable"
        meta["gemm_K"] = "not_applicable"
        meta["gemm_N"] = "not_applicable"
        meta["gemm_A_layout"] = "not_applicable"
        meta["gemm_B_layout"] = "not_applicable"
        meta["gemm_C_layout"] = "not_applicable"
        meta["psum_dtype"] = "not_applicable"
    meta["activation_layout"] = "NCHW" if len(record.input_shape) == 4 else "NC"
    meta["weight_layout"] = "OIHW" if record.layer_type == "Conv2d" else ("OI" if record.layer_type == "Linear" else "not_applicable")
    meta["input_dtype"] = tensor_dtype_name(record.input_activation)
    meta["weight_dtype"] = tensor_dtype_name(record.weight)
    meta["bias_dtype"] = tensor_dtype_name(record.bias)
    meta["output_dtype"] = tensor_dtype_name(record.output_activation)
    return meta


def build_pytorch_local_summary(record, input_file: str, output_file: str) -> OrderedDict:
    summary = OrderedDict()
    summary["layer_name"] = record.name
    summary["layer_type"] = record.layer_type
    summary["file_format"] = "decimal_txt_no_header"
    summary["one_value_per_line"] = True
    summary["input_file"] = input_file
    summary["input_shape"] = shape_text(record.input_shape)
    summary["input_dtype"] = tensor_dtype_name(record.input_activation)
    summary["input_layout"] = "NCHW" if len(record.input_shape) == 4 else "NC"
    if record.weight is not None:
        summary["weight_file"] = "weight_oihw.txt" if record.layer_type == "Conv2d" else "weight_oi.txt"
        summary["weight_shape"] = shape_text(record.weight.shape)
        summary["weight_dtype"] = tensor_dtype_name(record.weight)
        summary["weight_layout"] = "OIHW" if record.layer_type == "Conv2d" else "OI"
    else:
        summary["weight_file"] = "not_applicable"
        summary["weight_shape"] = "not_applicable"
        summary["weight_dtype"] = "not_applicable"
        summary["weight_layout"] = "not_applicable"
    summary["bias_file"] = "bias.txt" if record.bias is not None else "not_applicable"
    summary["bias_shape"] = shape_text(record.bias.shape) if record.bias is not None else "not_applicable"
    summary["bias_dtype"] = tensor_dtype_name(record.bias)
    summary["output_file"] = output_file
    summary["output_shape"] = shape_text(record.output_shape)
    summary["output_dtype"] = tensor_dtype_name(record.output_activation)
    summary["output_layout"] = "NCHW" if len(record.output_shape) == 4 else "NC"
    summary["flatten_order"] = "row-major contiguous"
    return summary


def build_gemm_local_summary(record, gemm_data) -> OrderedDict:
    a_name = "A_im2col_mk.txt" if record.layer_type == "Conv2d" else "A_input_mk.txt"
    summary = OrderedDict()
    summary["layer_name"] = record.name
    summary["layer_type"] = record.layer_type
    summary["file_format"] = "decimal_txt_no_header"
    summary["one_value_per_line"] = True
    summary["layout"] = "row-major"
    summary["gemm_M"] = gemm_data.M
    summary["gemm_K"] = gemm_data.K
    summary["gemm_N"] = gemm_data.N
    summary["A_file"] = a_name
    summary["A_shape"] = (gemm_data.M, gemm_data.K)
    summary["A_dtype"] = gemm_data.dtypes["A"]
    summary["A_flatten_order"] = "A[0][0], A[0][1], ..., A[M-1][K-1]"
    summary["B_file"] = "B_weight_kn.txt"
    summary["B_shape"] = (gemm_data.K, gemm_data.N)
    summary["B_dtype"] = gemm_data.dtypes["B"]
    summary["B_flatten_order"] = "B[0][0], B[0][1], ..., B[K-1][N-1]"
    summary["bias_file"] = "bias_n.txt" if gemm_data.bias is not None else "not_applicable"
    summary["bias_shape"] = (gemm_data.N,) if gemm_data.bias is not None else "not_applicable"
    summary["bias_dtype"] = gemm_data.dtypes["bias"]
    summary["psum_file"] = "psum_mn.txt"
    summary["psum_shape"] = (gemm_data.M, gemm_data.N)
    summary["psum_dtype"] = gemm_data.dtypes["psum"]
    summary["output_file"] = "output_mn.txt"
    summary["output_shape"] = (gemm_data.M, gemm_data.N)
    summary["output_dtype"] = gemm_data.dtypes["output"]
    summary["gemm_definition"] = "M=Hout*Wout, K=Cin*Kh*Kw, N=Cout" if record.layer_type == "Conv2d" else "M=Batch, K=In_features, N=Out_features"
    summary["im2col_order"] = "oh, ow, cin, kh, kw; row=oh*Wout+ow; col=cin*Kh*Kw+kh*Kw+kw"
    summary["weight_order"] = "cin, kh, kw, cout; k=cin*Kh*Kw+kh*Kw+kw; n=cout"
    summary["output_reshape"] = "C[m,n] -> output[0,n,oh,ow], m=oh*Wout+ow" if record.layer_type == "Conv2d" else "C[batch,out_feature]"
    return summary


def build_hw_local_summary(record, gemm_data, hw_files: OrderedDict) -> OrderedDict:
    summary = OrderedDict()
    summary["layer_name"] = record.name
    summary["layer_type"] = record.layer_type
    summary["file_format"] = "hex"
    summary["header"] = "none"
    summary["one_value_per_line"] = True
    summary["signed_representation"] = "two's complement"
    summary["A_matrix_shape"] = (gemm_data.M, gemm_data.K)
    summary["B_matrix_shape"] = (gemm_data.K, gemm_data.N)
    summary["psum_output_shape"] = (gemm_data.M, gemm_data.N)
    summary["flatten_order"] = "row-major"
    summary["requant_granularity"] = gemm_data.quant_meta.get("requant_granularity")
    summary["per_channel_axis"] = gemm_data.quant_meta.get("per_channel_axis")
    summary["channel_count_Cout_or_N"] = gemm_data.quant_meta.get("channel_count")
    summary["requant_channel_mapping"] = "requant_shift_per_channel[i] maps to output channel i, GEMM output N dimension i"
    summary["requant_shift_per_channel_file"] = "requant_shift_per_channel.txt" if isinstance(gemm_data.quant_meta.get("requant_shift_per_channel"), list) else "not_applicable"
    shapes = {
        "input_A_hex.txt": (gemm_data.M, gemm_data.K),
        "input_B_hex.txt": (gemm_data.K, gemm_data.N),
        "input_bias_hex.txt": (gemm_data.N,),
        "golden_psum_hex.txt": (gemm_data.M, gemm_data.N),
        "golden_output_hex.txt": (gemm_data.M, gemm_data.N),
    }
    dtypes = {
        "input_A_hex.txt": gemm_data.dtypes["A"],
        "input_B_hex.txt": gemm_data.dtypes["B"],
        "input_bias_hex.txt": gemm_data.dtypes["bias"],
        "golden_psum_hex.txt": gemm_data.dtypes["psum"],
        "golden_output_hex.txt": gemm_data.dtypes["output"],
    }
    for file_name, (_data, bitwidth) in hw_files.items():
        stem = file_name.replace(".txt", "")
        summary[f"{stem}_shape"] = shapes[file_name]
        summary[f"{stem}_dtype"] = dtypes[file_name]
        summary[f"{stem}_bitwidth"] = bitwidth
        summary[f"{stem}_layout"] = "channel" if "bias" in file_name else "row-major"
    add_quant_fields(summary, gemm_data.quant_meta)
    return summary


def build_hw_bitmask_local_summary(record, a_info: dict, b_info: dict, output_info: dict) -> OrderedDict:
    summary = OrderedDict()
    summary["layer_name"] = record.name
    summary["layer_type"] = record.layer_type
    summary["sparse_format"] = "bitmask_64b_plus_nonzero_values"
    summary["flatten_order"] = "row-major"
    summary["bitmask_word_bits"] = 64
    summary["bit_order"] = "bit i maps to element i in each 64-element block, bit0 is LSB"
    summary["values_order"] = "non-zero values in row-major scan order"
    add_sparse_info(summary, "A", a_info)
    add_sparse_info(summary, "B", b_info)
    add_sparse_info(summary, "output", output_info)
    summary["input_A_values_file"] = a_info["values_file"]
    summary["input_A_bitmask_file"] = a_info["bitmask_file"]
    summary["input_B_values_file"] = b_info["values_file"]
    summary["input_B_bitmask_file"] = b_info["bitmask_file"]
    summary["golden_output_values_file"] = output_info["values_file"]
    summary["golden_output_bitmask_file"] = output_info["bitmask_file"]
    summary["A_bitmask_reconstruct_pass"] = a_info["reconstruct_pass"]
    summary["B_bitmask_reconstruct_pass"] = b_info["reconstruct_pass"]
    summary["output_bitmask_reconstruct_pass"] = output_info["reconstruct_pass"]
    return summary


def add_sparse_info(summary: OrderedDict, prefix: str, info: dict) -> None:
    summary[f"{prefix}_original_shape"] = info["shape"]
    summary[f"{prefix}_total_elements"] = info["total_elements"]
    summary[f"{prefix}_nonzero_count"] = info["nonzero_count"]
    summary[f"{prefix}_zero_count"] = info["zero_count"]
    summary[f"{prefix}_sparsity"] = info["sparsity"]
    summary[f"{prefix}_bitmask_words"] = info["bitmask_words"]
    summary[f"{prefix}_value_bitwidth"] = info["value_bitwidth"]


def write_layer_summary(layer_dir: Path, args, record, gemm_data, verify_result, input_meta: dict, model_output: torch.Tensor, quantized: bool, generated_files: list[str], layer_folder: str) -> None:
    missing_quant = []
    if gemm_data is not None:
        granularity = gemm_data.quant_meta.get("requant_granularity")
        per_channel_optional = {
            "weight_scale_per_channel",
            "weight_zero_point_per_channel",
            "per_channel_axis",
            "per_channel_axis_semantics",
            "power2_weight_exponent_per_channel",
            "requant_scale_per_channel",
            "requant_exponent_per_channel",
            "requant_shift_per_channel",
        }
        per_tensor_optional = {
            "weight_scale",
            "weight_zero_point",
            "requant_scale",
            "power2_weight_scale",
            "power2_weight_exponent",
            "power2_requant_exponent",
            "requant_shift",
        }
        for key, value in gemm_data.quant_meta.items():
            if key == "requant_warning":
                continue
            if granularity == "per_tensor" and key in per_channel_optional:
                continue
            if granularity == "per_channel" and key in per_tensor_optional:
                continue
            if value is None or value == "not_found":
                missing_quant.append(key)
    summary = OrderedDict()
    summary["model_path"] = str(args.model_path)
    summary["image_path"] = str(args.image)
    summary["target_layer"] = args.target_layer
    summary["actual_layer_name"] = record.name
    summary["layer_folder_name"] = layer_folder
    summary["layer_type"] = record.layer_type
    summary["input_image_path"] = input_meta["image_path"]
    summary["input_resized_size"] = input_meta["resized_size"]
    summary["input_crop_method"] = input_meta["crop_method"]
    summary["input_mean"] = input_meta["mean"]
    summary["input_std"] = input_meta["std"]
    summary["input_tensor_shape"] = input_meta["tensor_shape"]
    summary["input_layout"] = input_meta["layout"]
    summary["input_dtype"] = input_meta["dtype"]
    summary["model_output_shape"] = tuple(model_output.shape)
    summary["predicted_class_index"] = predicted_class_index(model_output)
    summary["verify_pass"] = verify_result["pass"]
    summary["max_abs_error"] = verify_result["max_abs_error"]
    summary["mean_abs_error"] = verify_result["mean_abs_error"]
    summary["num_mismatch"] = verify_result["num_mismatch"]
    summary["mismatch_ratio"] = verify_result["mismatch_ratio"]
    summary["quantized_checkpoint"] = quantized
    if gemm_data is not None:
        add_quant_fields(summary, gemm_data.quant_meta)
    summary["missing_quantization_metadata"] = missing_quant if missing_quant else "none"
    if verify_result.get("warning"):
        summary["warning"] = verify_result["warning"]
    summary["generated_files"] = generated_files
    dump_meta_txt(layer_dir / "summary.txt", summary)


def add_quant_fields(summary: OrderedDict, quant_meta: dict) -> None:
    for key in (
        "requant_granularity",
        "input_scale",
        "input_zero_point",
        "weight_scale",
        "weight_zero_point",
        "weight_qscheme",
        "weight_scale_per_channel",
        "weight_zero_point_per_channel",
        "per_channel_axis",
        "per_channel_axis_semantics",
        "channel_count",
        "power2_weight_exponent_per_channel",
        "bias_scale",
        "output_scale",
        "output_zero_point",
        "requant_scale",
        "requant_scale_per_channel",
        "requant_exponent_per_channel",
        "requant_shift_per_channel",
        "power2_input_exponent",
        "power2_weight_exponent",
        "power2_output_exponent",
        "power2_requant_exponent",
        "requant_shift",
        "requant_warning",
    ):
        summary[key] = quant_meta.get(key)


def write_global_summary(output_dir: Path, args, layer_results: list[dict], quantized: bool) -> None:
    summary = OrderedDict()
    summary["model_path"] = str(args.model_path)
    summary["image_path"] = str(args.image)
    summary["target_layer"] = args.target_layer
    summary["module_types"] = args.module_types
    summary["quantized_checkpoint"] = quantized
    summary["num_layers_dumped"] = len(layer_results)
    summary["all_verify_pass"] = all(result["verify"]["pass"] for result in layer_results)
    summary["layers"] = [f"{r['dump_index']}:{r['layer_name']}:{r['layer_type']}:{r['folder']}:pass={r['verify']['pass']}" for r in layer_results]
    dump_meta_txt(output_dir / "global_summary.txt", summary)


def main() -> None:
    args = parse_args()
    module_types = resolve_module_types(args)
    ensure_dir(args.output_dir)
    model, _state_dict, device, quantized = load_model(args.model_path, args.device)
    image, input_meta = load_image_tensor(args.image, dump_input_tensor_file=False)
    image = image.to(device)
    max_layers = args.max_layers
    if args.target_layer != "all" and max_layers is None:
        max_layers = 1

    records, model_output = extract_layer_records(model, image, target_layer=args.target_layer, max_layers=max_layers, module_types=module_types)
    layer_results = []
    for dump_index, (_name, record) in enumerate(records.items()):
        layer_folder = layer_dir_name(record.name, record.layer_type)
        layer_path = Path(args.output_dir) / layer_folder
        ensure_dir(layer_path)
        gemm_data = convert_layer(record) if record.layer_type in GEMM_LAYER_TYPES else None
        verify_result = verify_layer(record, gemm_data, layer_path / "verify.txt")
        generated_files = write_layer_outputs(layer_path, dump_index, record, gemm_data, emit_bitmask=args.emit_bitmask)
        generated_files.append("verify.txt")
        write_layer_summary(layer_path, args, record, gemm_data, verify_result, input_meta, model_output, quantized, generated_files, layer_folder)
        layer_results.append({"dump_index": dump_index, "layer_name": record.name, "layer_type": record.layer_type, "folder": layer_folder, "verify": verify_result})
        print(f"[{dump_index}] {record.name} {record.layer_type} -> {layer_folder}: verify {'PASS' if verify_result['pass'] else 'FAIL'}")

    if len(layer_results) > 1:
        write_global_summary(Path(args.output_dir), args, layer_results, quantized)
    print(f"Done. Outputs written to {args.output_dir}")


if __name__ == "__main__":
    main()
