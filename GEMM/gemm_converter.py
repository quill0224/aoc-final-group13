from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F


@dataclass
class GemmData:
    A: np.ndarray
    B: np.ndarray
    bias: np.ndarray | None
    psum: np.ndarray
    output: np.ndarray
    output_for_verify: torch.Tensor
    M: int
    K: int
    N: int
    dtypes: dict[str, str]
    quant_meta: dict[str, Any]


def tensor_int_repr(tensor: torch.Tensor) -> torch.Tensor:
    return tensor.int_repr() if tensor.is_quantized else tensor


def tensor_scale(tensor: torch.Tensor) -> float | None:
    if not isinstance(tensor, torch.Tensor) or not tensor.is_quantized:
        return None
    if tensor.qscheme() in (torch.per_tensor_affine, torch.per_tensor_symmetric):
        return float(tensor.q_scale())
    return None


def tensor_zero_point(tensor: torch.Tensor) -> int | None:
    if not isinstance(tensor, torch.Tensor) or not tensor.is_quantized:
        return None
    if tensor.qscheme() in (torch.per_tensor_affine, torch.per_tensor_symmetric):
        return int(tensor.q_zero_point())
    return None


def module_output_scale(module: nn.Module) -> float | None:
    scale = getattr(module, "scale", None)
    if isinstance(scale, torch.Tensor):
        return float(scale.detach().cpu().reshape(-1)[0])
    if scale is not None:
        return float(scale)
    return None


def module_output_zero_point(module: nn.Module) -> int | None:
    zero_point = getattr(module, "zero_point", None)
    if isinstance(zero_point, torch.Tensor):
        return int(zero_point.detach().cpu().reshape(-1)[0])
    if zero_point is not None:
        return int(zero_point)
    return None


def power2_exponent(scale: float | None) -> int | str:
    if scale is None or scale <= 0:
        return "not_found"
    exp = int(round(np.log2(scale)))
    if np.isclose(scale, 2.0**exp):
        return exp
    return "not_found"


def _quant_dtype_name(tensor: torch.Tensor) -> str:
    if tensor.is_quantized:
        return str(tensor.dtype).replace("torch.", "")
    return str(tensor.dtype).replace("torch.", "")


def _as_float_tensor(tensor: torch.Tensor) -> torch.Tensor:
    return tensor.dequantize() if tensor.is_quantized else tensor.float()


def _raw_int_tensor(tensor: torch.Tensor) -> torch.Tensor:
    if tensor.is_quantized:
        return tensor.int_repr().to(torch.int32)
    return tensor


def _centered_int_tensor(tensor: torch.Tensor) -> torch.Tensor:
    if not tensor.is_quantized:
        return tensor
    zp = tensor_zero_point(tensor) or 0
    return tensor.int_repr().to(torch.int32) - int(zp)


def _quantized_bias_int32(bias: torch.Tensor | None, input_scale: float | None, weight_scale: float | None) -> np.ndarray | None:
    if bias is None:
        return None
    if input_scale is None or weight_scale is None:
        return bias.detach().cpu().numpy().astype(np.float32)
    denom = input_scale * weight_scale
    return torch.round(bias.detach().cpu().float() / denom).to(torch.int32).numpy()


def _requantize(accum: np.ndarray, input_scale: float, weight_scale: float, output_scale: float, output_zero_point: int, out_dtype: torch.dtype) -> np.ndarray:
    scaled = np.rint(accum.astype(np.float64) * (input_scale * weight_scale / output_scale))
    q = scaled + int(output_zero_point)
    return _clip_quantized(q, out_dtype)


def _quantize_real(real_values: np.ndarray, output_scale: float, output_zero_point: int, out_dtype: torch.dtype) -> np.ndarray:
    q = np.rint(real_values.astype(np.float64) / output_scale) + int(output_zero_point)
    return _clip_quantized(q, out_dtype)


def _clip_quantized(q: np.ndarray, out_dtype: torch.dtype) -> np.ndarray:
    if out_dtype is torch.quint8:
        q = np.clip(q, 0, 255).astype(np.uint8)
    elif out_dtype is torch.qint8:
        q = np.clip(q, -128, 127).astype(np.int8)
    else:
        q = q.astype(np.int32)
    return q


def convert_layer(record) -> GemmData:
    if record.layer_type == "Conv2d":
        return conv2d_to_gemm(record)
    if record.layer_type == "Linear":
        return linear_to_gemm(record)
    raise ValueError(f"Unsupported layer type: {record.layer_type}")


def conv2d_to_gemm(record) -> GemmData:
    module = record.module
    x = record.input_activation
    w = record.weight
    bias = record.bias

    if tuple(x.shape)[0] != 1:
        raise ValueError("Conv2d GEMM conversion currently supports batch size = 1 only.")

    stride = module.stride
    padding = module.padding
    dilation = module.dilation
    groups = module.groups
    if groups != 1:
        raise ValueError("Grouped Conv2d is not supported by this GEMM converter.")

    weight_for_gemm = _centered_int_tensor(w).to(torch.int32) if w.is_quantized else w.float()
    if x.is_quantized:
        raw_cols = F.unfold(_raw_int_tensor(x).float(), kernel_size=module.kernel_size, dilation=dilation, padding=padding, stride=stride)
        cols = raw_cols - float(tensor_zero_point(x) or 0)
    else:
        raw_cols = None
        cols = F.unfold(x.float(), kernel_size=module.kernel_size, dilation=dilation, padding=padding, stride=stride)
    A_compute = cols.squeeze(0).transpose(0, 1).contiguous()
    Cout = w.shape[0]
    B_compute = weight_for_gemm.reshape(Cout, -1).transpose(0, 1).contiguous()

    if x.is_quantized:
        A_dump = raw_cols.squeeze(0).transpose(0, 1).contiguous().to(torch.uint8).numpy()
    else:
        A_dump = A_compute.numpy().astype(np.float32)

    B_dump = tensor_int_repr(w).detach().cpu().reshape(Cout, -1).transpose(0, 1).contiguous().numpy()
    psum = (A_compute.to(torch.int32) @ B_compute.to(torch.int32)).numpy() if x.is_quantized or w.is_quantized else (A_compute @ B_compute).numpy()

    input_scale = tensor_scale(x)
    input_zp = tensor_zero_point(x)
    weight_scale = tensor_scale(w)
    weight_zp = tensor_zero_point(w)
    output_scale = module_output_scale(module) if x.is_quantized or w.is_quantized else None
    output_zp = module_output_zero_point(module) if x.is_quantized or w.is_quantized else None
    bias_dump = _quantized_bias_int32(bias, input_scale, weight_scale)

    if bias_dump is not None:
        output_accum = psum + bias_dump.reshape(1, -1)
    else:
        output_accum = psum

    if x.is_quantized or w.is_quantized:
        real_accum = psum.astype(np.float64) * (input_scale * weight_scale)
        if bias is not None:
            real_accum = real_accum + bias.detach().cpu().numpy().reshape(1, -1).astype(np.float64)
        q_out = _conv_output_to_mn(record.output_activation)
        output_dump = q_out
        N, Hout, Wout = record.output_activation.shape[1:]
        output_for_verify = torch.from_numpy(q_out.reshape(Hout, Wout, N).transpose(2, 0, 1).reshape(1, N, Hout, Wout))
    else:
        output_dump = output_accum.astype(np.float32)
        N, Hout, Wout = record.output_activation.shape[1:]
        output_for_verify = torch.from_numpy(output_dump.reshape(Hout, Wout, N).transpose(2, 0, 1).reshape(1, N, Hout, Wout))

    quant_meta = build_quant_meta(record, input_scale, input_zp, weight_scale, weight_zp, output_scale, output_zp)
    if input_scale and weight_scale and output_scale:
        quant_meta["requant_scale"] = input_scale * weight_scale / output_scale
        quant_meta["requant_shift"] = _power2_shift(quant_meta["requant_scale"])
        quant_meta["output_mn_source"] = "pytorch_quantized_layer_int_repr"

    return GemmData(
        A=A_dump,
        B=B_dump,
        bias=bias_dump,
        psum=psum,
        output=output_dump,
        output_for_verify=output_for_verify,
        M=int(A_compute.shape[0]),
        K=int(A_compute.shape[1]),
        N=int(B_compute.shape[1]),
        dtypes=_dtype_map(record, A_dump, B_dump, bias_dump, psum, output_dump),
        quant_meta=quant_meta,
    )


def linear_to_gemm(record) -> GemmData:
    x = record.input_activation
    w = record.weight
    bias = record.bias

    A_compute = _centered_int_tensor(x).reshape(x.shape[0], -1).to(torch.int32) if x.is_quantized else x.reshape(x.shape[0], -1).float()
    B_compute = _centered_int_tensor(w).reshape(w.shape[0], -1).transpose(0, 1).contiguous().to(torch.int32) if w.is_quantized else w.reshape(w.shape[0], -1).transpose(0, 1).float()
    A_dump = _raw_int_tensor(x).reshape(x.shape[0], -1).numpy() if x.is_quantized else A_compute.numpy().astype(np.float32)
    B_dump = tensor_int_repr(w).reshape(w.shape[0], -1).transpose(0, 1).contiguous().numpy()
    psum = (A_compute @ B_compute).numpy()

    input_scale = tensor_scale(x)
    input_zp = tensor_zero_point(x)
    weight_scale = tensor_scale(w)
    weight_zp = tensor_zero_point(w)
    output_scale = module_output_scale(record.module) if x.is_quantized or w.is_quantized else None
    output_zp = module_output_zero_point(record.module) if x.is_quantized or w.is_quantized else None
    bias_dump = _quantized_bias_int32(bias, input_scale, weight_scale)
    output_accum = psum + bias_dump.reshape(1, -1) if bias_dump is not None else psum

    if x.is_quantized or w.is_quantized:
        real_accum = psum.astype(np.float64) * (input_scale * weight_scale)
        if bias is not None:
            real_accum = real_accum + bias.detach().cpu().numpy().reshape(1, -1).astype(np.float64)
        q_out = tensor_int_repr(record.output_activation).reshape(record.output_activation.shape[0], -1).numpy()
        output_dump = q_out
        output_for_verify = torch.from_numpy(q_out.reshape(record.output_activation.shape))
    else:
        output_dump = output_accum.astype(np.float32)
        output_for_verify = torch.from_numpy(output_dump.reshape(record.output_activation.shape))

    quant_meta = build_quant_meta(record, input_scale, input_zp, weight_scale, weight_zp, output_scale, output_zp)
    if input_scale and weight_scale and output_scale:
        quant_meta["requant_scale"] = input_scale * weight_scale / output_scale
        quant_meta["requant_shift"] = _power2_shift(quant_meta["requant_scale"])
        quant_meta["output_mn_source"] = "pytorch_quantized_layer_int_repr"

    return GemmData(
        A=A_dump,
        B=B_dump,
        bias=bias_dump,
        psum=psum,
        output=output_dump,
        output_for_verify=output_for_verify,
        M=int(A_compute.shape[0]),
        K=int(A_compute.shape[1]),
        N=int(B_compute.shape[1]),
        dtypes=_dtype_map(record, A_dump, B_dump, bias_dump, psum, output_dump),
        quant_meta=quant_meta,
    )


def build_quant_meta(record, input_scale, input_zp, weight_scale, weight_zp, output_scale, output_zp) -> dict[str, Any]:
    bias_scale = input_scale * weight_scale if input_scale is not None and weight_scale is not None else None
    return {
        "layer_name": record.name,
        "layer_type": record.layer_type,
        "input_scale": input_scale,
        "input_zero_point": input_zp,
        "weight_scale": weight_scale,
        "weight_zero_point": weight_zp,
        "bias_scale": bias_scale,
        "output_scale": output_scale,
        "output_zero_point": output_zp,
        "power2_weight_scale": weight_scale if power2_exponent(weight_scale) != "not_found" else None,
        "power2_weight_exponent": power2_exponent(weight_scale),
        "power2_activation_scale": input_scale if power2_exponent(input_scale) != "not_found" else None,
        "power2_activation_exponent": power2_exponent(input_scale),
        "requant_scale": None,
        "requant_shift": None,
        "output_mn_source": "gemm_plus_bias" if output_scale is None else None,
    }


def _conv_output_to_mn(output_activation: torch.Tensor) -> np.ndarray:
    raw = tensor_int_repr(output_activation)
    return raw.permute(0, 2, 3, 1).reshape(-1, raw.shape[1]).contiguous().numpy()


def _power2_shift(scale: float) -> int | str:
    exp = power2_exponent(scale)
    if exp == "not_found":
        return "not_found"
    return -int(exp)


def _dtype_map(record, A, B, bias, psum, output) -> dict[str, str]:
    return {
        "input": _quant_dtype_name(record.input_activation),
        "weight": _quant_dtype_name(record.weight),
        "bias": str(bias.dtype) if bias is not None else "not_found",
        "psum": str(psum.dtype),
        "output": str(output.dtype),
        "A": str(A.dtype),
        "B": str(B.dtype),
    }
