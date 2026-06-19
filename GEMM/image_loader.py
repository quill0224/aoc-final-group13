from __future__ import annotations

from pathlib import Path

import numpy as np
import torch
from PIL import Image

import config
from dump_writer import dump_meta_txt, dump_tensor_txt


def load_image_tensor(image_path: Path, output_dir: Path | None = None) -> torch.Tensor:
    image_path = Path(image_path)
    with Image.open(image_path) as img:
        img = img.convert("RGB")
        resized = img.resize((config.resize_size, config.resize_size), Image.BILINEAR)

    arr = np.asarray(resized, dtype=np.float32) / 255.0
    mean = np.asarray(config.imagenet_mean, dtype=np.float32).reshape(1, 1, 3)
    std = np.asarray(config.imagenet_std, dtype=np.float32).reshape(1, 1, 3)
    arr = (arr - mean) / std
    chw = np.transpose(arr, (2, 0, 1))
    tensor = torch.from_numpy(chw).unsqueeze(0).contiguous()

    if output_dir is not None:
        dump_input_tensor(output_dir, image_path, tensor)
    return tensor


def dump_input_tensor(output_dir: Path, image_path: Path, tensor: torch.Tensor) -> None:
    input_dir = Path(output_dir) / "input"
    dump_tensor_txt(
        input_dir / "input_tensor_nchw.txt",
        tensor,
        dtype="fp32",
        layout="NCHW-contiguous",
        tensor_name="input_tensor_nchw",
    )
    dump_meta_txt(
        input_dir / "input_meta.txt",
        {
            "original_image_path": str(image_path),
            "input_shape": tuple(tensor.shape),
            "resize_size": (config.resize_size, config.resize_size),
            "center_crop": config.center_crop,
            "mean": config.imagenet_mean,
            "std": config.imagenet_std,
            "layout": "NCHW",
        },
    )
