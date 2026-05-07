"""Power-of-2 PTQ for VGG-8.

The key trick: approximate scale s as 2^(-c) so that dequantization becomes
a hardware-friendly arithmetic right-shift instead of float division.
Energy savings of ~370x per multiply (Lab 1 measurement).
"""

from __future__ import annotations

import math
from enum import Enum

import torch
import torch.ao.quantization as tq

from .model import VGG


class PowerOfTwoObserver(tq.MinMaxObserver):
    """MinMaxObserver that rounds the scale factor to the nearest power of two."""

    def scale_approximate(self, scale: float, max_shift_amount: int = 8) -> float:
        """Snap a positive scale to the nearest 2^(-c), c clamped to ±max_shift_amount.

        max_shift_amount=8 keeps c within byte-shift hardware range.
        """
        if scale == 0:
            return 1.0
        c = round(-math.log2(scale))
        c = max(min(c, max_shift_amount), -max_shift_amount)
        return 2.0 ** (-c)

    def calculate_qparams(self):  # type: ignore[override]
        min_val, max_val = self.min_val.item(), self.max_val.item()
        max_val_pos = max(abs(min_val), abs(max_val))

        if self.dtype == torch.quint8:
            quant_min, quant_max = 0, 255
            zero_point = 128  # uint8 with zero-point=128 → maps to int8 via XOR bit 7
        else:  # torch.qint8
            quant_min, quant_max = -128, 127
            zero_point = 0

        scale = (
            2 * max_val_pos / (quant_max - quant_min)
            if (quant_max - quant_min) > 0
            else 1.0
        )
        scale = self.scale_approximate(scale)
        return torch.tensor(scale, dtype=torch.float32), torch.tensor(zero_point, dtype=torch.int64)


class CustomQConfig(Enum):
    POWER2 = tq.QConfig(
        activation=PowerOfTwoObserver.with_args(
            dtype=torch.quint8,
            qscheme=torch.per_tensor_symmetric,
        ),
        weight=PowerOfTwoObserver.with_args(
            dtype=torch.qint8,
            qscheme=torch.per_tensor_symmetric,
        ),
    )
    DEFAULT = None


def calibrate(model, loader, device: str = "cpu") -> None:
    """One-pass calibration to populate observer statistics.

    Lab 1 takes the first batch only; in practice ~1% of train data is enough.
    """
    model.eval().to(device)
    with torch.no_grad():
        for x, _ in loader:
            model(x.to(device))
            break


def ptq_quantization(
    fp32_weights_path: str,
    int8_weights_path: str,
    val_loader,
):
    """End-to-end PTQ on VGG-8.

    Steps: load FP32 -> fuse -> prepare -> calibrate -> convert -> save.
    Returns the converted INT8 model.
    """
    from .utils import load_model, save_model

    model_fp32 = load_model(VGG(), fp32_weights_path)
    model_fp32.eval().cpu()
    model_fp32.fuse_model()

    model_fp32.qconfig = CustomQConfig.POWER2.value
    model_prepared = tq.prepare(model_fp32)
    calibrate(model_prepared, val_loader, device="cpu")
    model_int8 = tq.convert(model_prepared)

    save_model(model_int8, int8_weights_path, existed="overwrite")
    return model_int8
