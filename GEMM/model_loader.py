from __future__ import annotations

from collections import OrderedDict
from pathlib import Path
import sys
from typing import Any

import torch
import torch.nn as nn
import torch.ao.quantization as tq

import config


ANALYSIS_SRC = config.REPO_ROOT / "analysis" / "src"
if str(ANALYSIS_SRC) not in sys.path:
    sys.path.insert(0, str(ANALYSIS_SRC))

from lib.models import VGG  # noqa: E402
from lib.models.qconfig import CustomQConfig  # noqa: E402


def resolve_device(device_arg: str) -> torch.device:
    if device_arg == "auto":
        device_arg = "cuda" if torch.cuda.is_available() else "cpu"
    if device_arg.startswith("cuda") and not torch.cuda.is_available():
        print("CUDA requested but not available; falling back to CPU.")
        device_arg = "cpu"
    return torch.device(device_arg)


def extract_state_dict(checkpoint: Any) -> OrderedDict:
    if isinstance(checkpoint, nn.Module):
        return checkpoint.state_dict()
    if isinstance(checkpoint, (dict, OrderedDict)):
        for key in ("model", "state_dict", "model_state_dict"):
            if key in checkpoint and hasattr(checkpoint[key], "keys"):
                return _strip_module_prefix(checkpoint[key])
        if all(isinstance(key, str) for key in checkpoint.keys()):
            return _strip_module_prefix(checkpoint)
        print("Unknown checkpoint dictionary keys:", list(checkpoint.keys()))
    raise TypeError(f"Unsupported checkpoint format: {type(checkpoint)}")


def _strip_module_prefix(state_dict: Any) -> OrderedDict:
    if not any(str(key).startswith("module.") for key in state_dict.keys()):
        return state_dict
    out = OrderedDict()
    for key, value in state_dict.items():
        out[key[7:] if key.startswith("module.") else key] = value
    if hasattr(state_dict, "_metadata"):
        out._metadata = OrderedDict()
        for key, value in state_dict._metadata.items():
            out._metadata[key[7:] if key.startswith("module.") else key] = value
    return out


def has_quantized_tensors(state_dict: OrderedDict) -> bool:
    return any(isinstance(v, torch.Tensor) and v.is_quantized for v in state_dict.values())


def fuse_conv_bn_only(model: nn.Module) -> None:
    features = model.features
    for idx in range(len(features) - 1):
        if isinstance(features[idx], nn.Conv2d) and isinstance(features[idx + 1], nn.BatchNorm2d):
            tq.fuse_modules(features, [str(idx), str(idx + 1)], inplace=True)


def build_vgg16_model(quantized: bool) -> nn.Module:
    model = VGG(arch="vgg16", in_channels=3, in_size=config.input_size, num_classes=100)
    model.eval()
    if quantized:
        fuse_conv_bn_only(model)
        model.qconfig = CustomQConfig.POWER2.value
        tq.prepare(model, inplace=True)
        tq.convert(model, inplace=True)
    return model


def is_conv_or_linear(module: nn.Module) -> bool:
    name = type(module).__name__
    return (
        isinstance(module, (nn.Conv2d, nn.Linear))
        or name in {"Conv2d", "ConvReLU2d", "Linear", "QuantizedConv2d", "QuantizedLinear"}
    )


def count_layers(model: nn.Module) -> tuple[int, int]:
    conv = 0
    linear = 0
    for module in model.modules():
        name = type(module).__name__
        if isinstance(module, nn.Conv2d) or name in {"Conv2d", "ConvReLU2d", "QuantizedConv2d"}:
            conv += 1
        elif isinstance(module, nn.Linear) or name in {"Linear", "QuantizedLinear"}:
            linear += 1
    return conv, linear


def load_model(model_path: Path, device_arg: str = "auto") -> tuple[nn.Module, OrderedDict, torch.device, bool]:
    model_path = Path(model_path)
    checkpoint = torch.load(model_path, map_location="cpu")
    state_dict = extract_state_dict(checkpoint)
    quantized = has_quantized_tensors(state_dict)

    device = resolve_device(device_arg)
    if quantized and device.type != "cpu":
        print("Quantized PyTorch ops are most portable on CPU; using CPU for quantized inference.")
        device = torch.device("cpu")

    model = build_vgg16_model(quantized=quantized)
    load_result = model.load_state_dict(state_dict, strict=False)
    if load_result.missing_keys or load_result.unexpected_keys:
        print("load_state_dict missing keys:", load_result.missing_keys)
        print("load_state_dict unexpected keys:", load_result.unexpected_keys)
    model.eval()
    model.to(device)

    num_conv, num_linear = count_layers(model)
    print(f"model path: {model_path}")
    print(f"device: {device}")
    print(f"number of Conv2d layers: {num_conv}")
    print(f"number of Linear layers: {num_linear}")
    print(f"detected quantized tensors: {quantized}")
    return model, state_dict, device, quantized
