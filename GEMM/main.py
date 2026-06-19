from __future__ import annotations

import argparse
from collections import OrderedDict
from pathlib import Path

import torch

import config
from dump_writer import dump_matrix_txt, dump_meta_txt, dump_quant_meta_txt, dump_tensor_txt, ensure_dir
from gemm_converter import convert_layer, tensor_int_repr
from hook_extractor import extract_layer_records
from image_loader import load_image_tensor
from model_loader import load_model
from verify import verify_layer


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
    return parser.parse_args()


def shape_text(shape) -> tuple[int, ...]:
    return tuple(int(v) for v in shape)


def layer_dir_name(index: int, layer_type: str) -> str:
    suffix = "conv" if layer_type == "Conv2d" else "linear"
    return f"layer_{index:02d}_{suffix}"


def tuple_or_none(shape) -> tuple[int, ...] | str:
    return tuple(int(v) for v in shape) if shape is not None else "not_found"


def module_tuple(module, attr: str) -> tuple[int, ...] | str:
    value = getattr(module, attr, None)
    if value is None:
        return "not_found"
    if isinstance(value, tuple):
        return tuple(int(v) for v in value)
    return (int(value),)


def write_layer_outputs(base_dir: Path, index: int, record, gemm_data, verify_result) -> None:
    layer_dir = base_dir / layer_dir_name(index, record.layer_type)
    pytorch_dir = layer_dir / "pytorch"
    gemm_dir = layer_dir / "gemm"
    hw_dir = layer_dir / "hw"
    ensure_dir(pytorch_dir)
    ensure_dir(gemm_dir)
    ensure_dir(hw_dir)

    weight_layout = "OIHW" if record.layer_type == "Conv2d" else "OI"
    input_layout = "NCHW" if record.layer_type == "Conv2d" else "NC"
    output_layout = "NCHW" if record.layer_type == "Conv2d" else "NC"
    weight_file = "weight_oihw.txt" if record.layer_type == "Conv2d" else "weight_oi.txt"
    input_file = "input_activation_nchw.txt" if record.layer_type == "Conv2d" else "input_activation_nc.txt"
    output_file = "output_nchw.txt" if record.layer_type == "Conv2d" else "output_nc.txt"

    dump_tensor_txt(pytorch_dir / input_file, tensor_int_repr(record.input_activation), dtype=gemm_data.dtypes["input"], layout=input_layout, tensor_name="input_activation")
    dump_tensor_txt(pytorch_dir / weight_file, tensor_int_repr(record.weight), dtype=gemm_data.dtypes["weight"], layout=weight_layout, tensor_name="weight")
    if record.bias is not None:
        dump_tensor_txt(pytorch_dir / "bias.txt", record.bias, dtype=str(record.bias.dtype).replace("torch.", ""), layout="channel", tensor_name="bias")
    dump_tensor_txt(pytorch_dir / output_file, tensor_int_repr(record.output_activation), dtype=gemm_data.dtypes["output"], layout=output_layout, tensor_name="output_activation")

    dump_matrix_txt(gemm_dir / ("A_im2col_mk.txt" if record.layer_type == "Conv2d" else "A_input_mk.txt"), gemm_data.A, dtype=gemm_data.dtypes["A"], tensor_name="A_im2col_mk" if record.layer_type == "Conv2d" else "A_input_mk")
    dump_matrix_txt(gemm_dir / "B_weight_kn.txt", gemm_data.B, dtype=gemm_data.dtypes["B"], tensor_name="B_weight_kn")
    if gemm_data.bias is not None:
        dump_matrix_txt(gemm_dir / "bias_n.txt", gemm_data.bias, dtype=gemm_data.dtypes["bias"], layout="channel", tensor_name="bias_n")
    dump_matrix_txt(gemm_dir / "psum_mn.txt", gemm_data.psum, dtype=gemm_data.dtypes["psum"], tensor_name="psum_mn")
    dump_matrix_txt(gemm_dir / "output_mn.txt", gemm_data.output, dtype=gemm_data.dtypes["output"], tensor_name="output_mn")

    dump_matrix_txt(hw_dir / "input_A_txt.txt", gemm_data.A, dtype=gemm_data.dtypes["A"], tensor_name="input_A")
    dump_matrix_txt(hw_dir / "input_B_txt.txt", gemm_data.B, dtype=gemm_data.dtypes["B"], tensor_name="input_B")
    if gemm_data.bias is not None:
        dump_matrix_txt(hw_dir / "input_bias_txt.txt", gemm_data.bias, dtype=gemm_data.dtypes["bias"], layout="channel", tensor_name="input_bias")
    dump_matrix_txt(hw_dir / "golden_psum_txt.txt", gemm_data.psum, dtype=gemm_data.dtypes["psum"], tensor_name="golden_psum")
    dump_matrix_txt(hw_dir / "golden_output_txt.txt", gemm_data.output, dtype=gemm_data.dtypes["output"], tensor_name="golden_output")

    dump_meta_txt(layer_dir / "layer_meta.txt", build_layer_meta(index, record, gemm_data))
    dump_quant_meta_txt(layer_dir / "quant_meta.txt", gemm_data.quant_meta)


def build_layer_meta(index: int, record, gemm_data) -> OrderedDict:
    meta = OrderedDict()
    meta["layer_index"] = index
    meta["layer_name"] = record.name
    meta["layer_type"] = record.layer_type
    meta["module_type"] = type(record.module).__name__
    meta["input_shape"] = shape_text(record.input_shape)
    meta["weight_shape"] = shape_text(record.weight.shape)
    meta["bias_shape"] = tuple_or_none(record.bias.shape if record.bias is not None else None)
    meta["output_shape"] = shape_text(record.output_shape)
    if record.layer_type == "Conv2d":
        meta["stride"] = module_tuple(record.module, "stride")
        meta["padding"] = module_tuple(record.module, "padding")
        meta["dilation"] = module_tuple(record.module, "dilation")
        meta["groups"] = getattr(record.module, "groups", 1)
    else:
        meta["stride"] = "not_found"
        meta["padding"] = "not_found"
        meta["dilation"] = "not_found"
        meta["groups"] = "not_found"
    meta["gemm_M"] = gemm_data.M
    meta["gemm_K"] = gemm_data.K
    meta["gemm_N"] = gemm_data.N
    meta["activation_layout"] = "NCHW" if record.layer_type == "Conv2d" else "NC"
    meta["weight_layout"] = "OIHW" if record.layer_type == "Conv2d" else "OI"
    meta["gemm_A_layout"] = config.gemm_layout
    meta["gemm_B_layout"] = config.gemm_layout
    meta["gemm_C_layout"] = config.gemm_layout
    meta["input_dtype"] = gemm_data.dtypes["input"]
    meta["weight_dtype"] = gemm_data.dtypes["weight"]
    meta["bias_dtype"] = gemm_data.dtypes["bias"]
    meta["psum_dtype"] = gemm_data.dtypes["psum"]
    meta["output_dtype"] = gemm_data.dtypes["output"]
    return meta


def write_summary(output_dir: Path, args, model_output: torch.Tensor, layer_results: list[dict], quantized: bool) -> None:
    missing_quant = []
    for result in layer_results:
        for key, value in result.get("quant_meta", {}).items():
            if value is None or value == "not_found":
                missing_quant.append(f"{result['layer_name']}.{key}")
    summary = OrderedDict()
    summary["model_path"] = str(args.model_path)
    summary["image_path"] = str(args.image)
    summary["target_layer"] = args.target_layer
    summary["quantized_checkpoint"] = quantized
    summary["num_layers_dumped"] = len(layer_results)
    summary["model_output_shape"] = tuple(model_output.shape)
    summary["predicted_class_index"] = int(model_output.dequantize().argmax().item() if model_output.is_quantized else model_output.argmax().item())
    summary["all_verify_pass"] = all(result["verify"]["pass"] for result in layer_results)
    summary["layers"] = [f"{r['layer_index']}:{r['layer_name']}:{r['layer_type']}:pass={r['verify']['pass']}" for r in layer_results]
    summary["missing_quantization_metadata"] = missing_quant if missing_quant else "none"
    dump_meta_txt(output_dir / "summary.txt", summary)


def main() -> None:
    args = parse_args()
    ensure_dir(args.output_dir)
    model, _state_dict, device, quantized = load_model(args.model_path, args.device)
    image = load_image_tensor(args.image, args.output_dir).to(device)
    max_layers = args.max_layers
    if args.target_layer != "all" and max_layers is None:
        max_layers = 1

    records, model_output = extract_layer_records(model, image, target_layer=args.target_layer, max_layers=max_layers)
    layer_results = []
    for index, (_name, record) in enumerate(records.items()):
        gemm_data = convert_layer(record)
        layer_path = Path(args.output_dir) / layer_dir_name(index, record.layer_type)
        verify_result = verify_layer(record, gemm_data, layer_path / "verify.txt")
        write_layer_outputs(Path(args.output_dir), index, record, gemm_data, verify_result)
        layer_results.append(
            {
                "layer_index": index,
                "layer_name": record.name,
                "layer_type": record.layer_type,
                "verify": verify_result,
                "quant_meta": gemm_data.quant_meta,
            }
        )
        print(f"[{index}] {record.name} {record.layer_type}: verify {'PASS' if verify_result['pass'] else 'FAIL'}")

    write_summary(Path(args.output_dir), args, model_output, layer_results, quantized)
    print(f"Done. Outputs written to {args.output_dir}")


if __name__ == "__main__":
    main()
