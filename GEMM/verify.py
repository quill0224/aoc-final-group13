from __future__ import annotations

from pathlib import Path

import torch

import config
from dump_writer import dump_meta_txt


def verify_layer(record, gemm_data, output_path: Path) -> dict:
    if gemm_data is None:
        result = {
            "layer_name": record.name,
            "layer_type": record.layer_type,
            "verify_method": "hook_only",
            "compare_domain": "hook_output_present",
            "max_abs_error": 0.0,
            "mean_abs_error": 0.0,
            "num_mismatch": 0,
            "mismatch_ratio": 0.0,
            "pass": record.output_activation is not None,
            "first_mismatch_indices": "none",
        }
        dump_meta_txt(output_path, result)
        return result

    pytorch_output = record.output_activation
    gemm_output = gemm_data.output_for_verify

    if pytorch_output.is_quantized:
        pytorch_cmp = pytorch_output.int_repr().cpu().to(torch.int32)
        gemm_cmp = gemm_output.cpu().to(torch.int32)
        atol = config.int_exact_atol
        rtol = config.int_exact_rtol
        compare_domain = "quantized_int_repr"
    else:
        pytorch_cmp = pytorch_output.cpu().float()
        gemm_cmp = gemm_output.cpu().float()
        atol = config.fp32_atol
        rtol = config.fp32_rtol
        compare_domain = "fp32"

    diff = (pytorch_cmp - gemm_cmp).abs()
    max_abs_error = float(diff.max().item()) if diff.numel() else 0.0
    mean_abs_error = float(diff.float().mean().item()) if diff.numel() else 0.0
    tolerance = atol + rtol * pytorch_cmp.abs().float()
    mismatch = diff.float() > tolerance
    num_mismatch = int(mismatch.sum().item())
    total = int(diff.numel())
    mismatch_ratio = float(num_mismatch / total) if total else 0.0
    passed = num_mismatch == 0

    first_mismatches = []
    if not passed:
        indices = mismatch.nonzero(as_tuple=False)[:10]
        for idx in indices:
            idx_tuple = tuple(int(v) for v in idx.tolist())
            first_mismatches.append(
                f"{idx_tuple}: pytorch={pytorch_cmp[idx_tuple].item()} gemm={gemm_cmp[idx_tuple].item()}"
            )

    result = {
        "layer_name": record.name,
        "layer_type": record.layer_type,
        "verify_method": "gemm_vs_pytorch",
        "compare_domain": compare_domain,
        "max_abs_error": max_abs_error,
        "mean_abs_error": mean_abs_error,
        "num_mismatch": num_mismatch,
        "mismatch_ratio": mismatch_ratio,
        "atol": atol,
        "rtol": rtol,
        "pass": passed,
        "first_mismatch_indices": first_mismatches if first_mismatches else "none",
    }
    warning = gemm_data.quant_meta.get("requant_warning") if gemm_data is not None else None
    if warning:
        result["warning"] = warning
    dump_meta_txt(output_path, result)
    return result
