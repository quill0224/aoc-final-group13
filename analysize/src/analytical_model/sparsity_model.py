from __future__ import annotations

from dataclasses import dataclass
from math import ceil

import torch
import torch.nn as nn
import torch.ao.nn.intrinsic.quantized as nniq
import torch.ao.nn.quantized as nnq


@dataclass(frozen=True)
class LayerSparsityProfile:
    layer_name: str
    total_weights: int
    nonzero_weights: int
    zero_weights: int
    density: float
    sparsity: float
    dense_weight_bytes: int
    sparse_weight_value_bytes: int
    weight_bitmask_bytes: int
    sparse_weight_total_bytes: int
    compression_ratio: float


def _clamp(value: float, lower: float, upper: float) -> float:
    return max(lower, min(upper, value))


def bitmask_bytes(num_elements, mask_word_bits=64):
    return ceil(num_elements / mask_word_bits) * 8


def conv_module_types() -> tuple:
    types = [nn.Conv2d, nnq.Conv2d]
    for name in ("ConvReLU2d", "ConvBn2d", "ConvBnReLU2d"):
        module_type = getattr(nniq, name, None)
        if module_type is not None:
            types.append(module_type)
    return tuple(types)


def _get_conv_weight(module):
    weight = getattr(module, "weight", None)
    if callable(weight):
        weight = weight()
    if weight is None:
        return None
    return weight.detach()


def _count_nonzero(weight: torch.Tensor) -> int:
    if not weight.is_quantized:
        return int(torch.count_nonzero(weight).item())

    try:
        int_weight = weight.int_repr()
        if weight.qscheme() in (torch.per_channel_affine, torch.per_channel_symmetric):
            zero_points = weight.q_per_channel_zero_points().to(int_weight.device)
            axis = weight.q_per_channel_axis()
            view_shape = [1] * int_weight.dim()
            view_shape[axis] = -1
            zero_points = zero_points.reshape(view_shape)
            return int(torch.count_nonzero(int_weight != zero_points).item())
        return int(torch.count_nonzero(int_weight != weight.q_zero_point()).item())
    except RuntimeError:
        return int(torch.count_nonzero(weight.dequantize()).item())


def profile_conv_weight(module, layer_name):
    weight = _get_conv_weight(module)
    if weight is None:
        raise ValueError(f"Module {layer_name} does not expose a Conv weight tensor.")

    total = int(weight.numel())
    nonzero = _count_nonzero(weight)
    zero = total - nonzero
    dense_weight_bytes = total
    sparse_weight_value_bytes = nonzero
    weight_bitmask_bytes = bitmask_bytes(total)
    sparse_weight_total_bytes = sparse_weight_value_bytes + weight_bitmask_bytes
    compression_ratio = (
        sparse_weight_total_bytes / dense_weight_bytes if dense_weight_bytes else 0.0
    )

    return LayerSparsityProfile(
        layer_name=layer_name,
        total_weights=total,
        nonzero_weights=nonzero,
        zero_weights=zero,
        density=nonzero / total if total else 0.0,
        sparsity=zero / total if total else 0.0,
        dense_weight_bytes=dense_weight_bytes,
        sparse_weight_value_bytes=sparse_weight_value_bytes,
        weight_bitmask_bytes=weight_bitmask_bytes,
        sparse_weight_total_bytes=sparse_weight_total_bytes,
        compression_ratio=compression_ratio,
    )


def estimate_trip_utilization(density):
    if density >= 0.80:
        return 0.95
    if density >= 0.30:
        return _clamp(0.35 + 0.75 * density, 0.35, 0.95)
    return _clamp(0.25 + 0.50 * density, 0.20, 0.50)


def recommend_mode(density):
    if density > 0.80:
        return "standard_ip"
    if density >= 0.05:
        return "trip"
    return "too_sparse_for_trip_future_trgt_trgs"
