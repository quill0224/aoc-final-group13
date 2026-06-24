from __future__ import annotations

from pathlib import Path
from typing import Any, Mapping, Sequence

import numpy as np
import torch


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def _shape_to_text(shape: Sequence[int]) -> str:
    return " ".join(str(int(dim)) for dim in shape)


def _to_numpy(data: Any) -> np.ndarray:
    if isinstance(data, torch.Tensor):
        if data.is_quantized:
            data = data.int_repr()
        return data.detach().cpu().contiguous().numpy()
    return np.asarray(data)


def _format_value(value: Any) -> str:
    scalar = value.item() if hasattr(value, "item") else value
    if isinstance(scalar, (np.integer, int)):
        return str(int(scalar))
    if isinstance(scalar, (np.floating, float)):
        return f"{float(scalar):.10g}"
    return str(scalar)


def dump_tensor_txt(
    path: Path,
    tensor: Any,
    dtype: str | None = None,
    layout: str = "row-major",
    tensor_name: str | None = None,
    extra_header: Mapping[str, Any] | None = None,
    header: bool = True,
) -> None:
    arr = _to_numpy(tensor)
    dump_matrix_txt(
        path=path,
        matrix=arr,
        dtype=dtype or str(arr.dtype),
        layout=layout,
        tensor_name=tensor_name,
        extra_header=extra_header,
        header=header,
    )


def dump_matrix_txt(
    path: Path,
    matrix: Any,
    dtype: str | None = None,
    layout: str = "row-major",
    tensor_name: str | None = None,
    extra_header: Mapping[str, Any] | None = None,
    header: bool = True,
) -> None:
    arr = _to_numpy(matrix)
    ensure_dir(path.parent)
    with path.open("w", encoding="utf-8") as f:
        if header:
            f.write(f"# shape: {_shape_to_text(arr.shape)}\n")
            f.write(f"# dtype: {dtype or str(arr.dtype)}\n")
            f.write(f"# layout: {layout}\n")
            if tensor_name:
                f.write(f"# tensor: {tensor_name}\n")
            if extra_header:
                for key, value in extra_header.items():
                    f.write(f"# {key}: {value}\n")
        for value in arr.reshape(-1, order="C"):
            f.write(_format_value(value) + "\n")


def dump_numeric_txt(path: Path, tensor: Any) -> None:
    dump_matrix_txt(path, tensor, header=False)


def signed_to_twos_complement_hex(value: Any, bitwidth: int) -> str:
    scalar = int(value.item() if hasattr(value, "item") else value)
    mask = (1 << bitwidth) - 1
    width = bitwidth // 4
    return f"{scalar & mask:0{width}X}"


def dump_hex_txt(path: Path, tensor: Any, bitwidth: int) -> None:
    arr = _to_numpy(tensor)
    if np.issubdtype(arr.dtype, np.floating):
        raise TypeError(f"hex dump does not support floating dtype: {arr.dtype}")
    ensure_dir(path.parent)
    with path.open("w", encoding="utf-8") as f:
        for value in arr.reshape(-1, order="C"):
            f.write(signed_to_twos_complement_hex(value, bitwidth) + "\n")


def flatten_row_major(tensor: Any) -> np.ndarray:
    return _to_numpy(tensor).reshape(-1, order="C")


def build_bitmask_64(flat_values: Any) -> np.ndarray:
    flat = np.asarray(flat_values).reshape(-1)
    num_words = (flat.size + 63) // 64
    masks = np.zeros(num_words, dtype=np.uint64)
    for word_idx in range(num_words):
        mask = 0
        start = word_idx * 64
        block = flat[start : start + 64]
        for bit_idx, value in enumerate(block):
            if value != 0:
                mask |= 1 << bit_idx
        masks[word_idx] = mask
    return masks


def dump_nonzero_values_hex(path: Path, flat_values: Any, bitwidth: int) -> int:
    flat = np.asarray(flat_values).reshape(-1)
    nonzero = flat[flat != 0]
    dump_hex_txt(path, nonzero, bitwidth)
    return int(nonzero.size)


def dump_bitmask_64b_hex(path: Path, flat_values: Any) -> int:
    masks = build_bitmask_64(flat_values)
    ensure_dir(path.parent)
    with path.open("w", encoding="utf-8") as f:
        for mask in masks:
            f.write(f"{int(mask):016X}\n")
    return int(masks.size)


def dump_sparse_bitmask_tensor(prefix: Path, tensor: Any, bitwidth: int) -> dict[str, Any]:
    flat = flatten_row_major(tensor)
    values_path = prefix.parent / f"{prefix.name}_values_hex.txt"
    mask_path = prefix.parent / f"{prefix.name}_bitmask_64b_hex.txt"
    nonzero_count = dump_nonzero_values_hex(values_path, flat, bitwidth)
    bitmask_words = dump_bitmask_64b_hex(mask_path, flat)
    reconstructed = reconstruct_from_bitmask(flat[flat != 0], build_bitmask_64(flat), flat.size)
    return {
        "values_file": values_path.name,
        "bitmask_file": mask_path.name,
        "shape": _to_numpy(tensor).shape,
        "total_elements": int(flat.size),
        "nonzero_count": nonzero_count,
        "zero_count": int(flat.size - nonzero_count),
        "sparsity": float((flat.size - nonzero_count) / flat.size) if flat.size else 0.0,
        "bitmask_words": bitmask_words,
        "value_bitwidth": bitwidth,
        "reconstruct_pass": bool(np.array_equal(reconstructed, flat)),
    }


def reconstruct_from_bitmask(values: Any, bitmask: Any, total_elements: int) -> np.ndarray:
    values_arr = np.asarray(values).reshape(-1)
    masks = np.asarray(bitmask, dtype=np.uint64).reshape(-1)
    dtype = values_arr.dtype if values_arr.size else np.int64
    dense = np.zeros(int(total_elements), dtype=dtype)
    value_idx = 0
    for word_idx, mask_value in enumerate(masks):
        mask_int = int(mask_value)
        base = word_idx * 64
        for bit_idx in range(64):
            dense_idx = base + bit_idx
            if dense_idx >= total_elements:
                break
            if (mask_int >> bit_idx) & 1:
                dense[dense_idx] = values_arr[value_idx]
                value_idx += 1
    if value_idx != values_arr.size:
        return np.array([], dtype=dtype)
    return dense


def dump_meta_txt(path: Path, meta: Mapping[str, Any]) -> None:
    ensure_dir(path.parent)
    with path.open("w", encoding="utf-8") as f:
        for key, value in meta.items():
            f.write(f"{key}: {_meta_value_to_text(value)}\n")


def dump_quant_meta_txt(path: Path, meta: Mapping[str, Any]) -> None:
    dump_meta_txt(path, meta)


def _meta_value_to_text(value: Any) -> str:
    if value is None:
        return "not_found"
    if isinstance(value, torch.Tensor):
        if value.numel() == 1:
            return _format_value(value.detach().cpu().reshape(-1)[0])
        return " ".join(_format_value(v) for v in value.detach().cpu().reshape(-1))
    if isinstance(value, np.ndarray):
        if value.size == 1:
            return _format_value(value.reshape(-1)[0])
        return " ".join(_format_value(v) for v in value.reshape(-1))
    if isinstance(value, (list, tuple)):
        if not value:
            return "not_found"
        return " ".join(_meta_value_to_text(v) for v in value)
    if isinstance(value, bool):
        return "true" if value else "false"
    return _format_value(value)
