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
) -> None:
    arr = _to_numpy(tensor)
    dump_matrix_txt(
        path=path,
        matrix=arr,
        dtype=dtype or str(arr.dtype),
        layout=layout,
        tensor_name=tensor_name,
        extra_header=extra_header,
    )


def dump_matrix_txt(
    path: Path,
    matrix: Any,
    dtype: str | None = None,
    layout: str = "row-major",
    tensor_name: str | None = None,
    extra_header: Mapping[str, Any] | None = None,
) -> None:
    arr = _to_numpy(matrix)
    ensure_dir(path.parent)
    with path.open("w", encoding="utf-8") as f:
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
