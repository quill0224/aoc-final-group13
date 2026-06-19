from __future__ import annotations

from collections import OrderedDict
from dataclasses import dataclass
from typing import Iterable

import torch
import torch.nn as nn


@dataclass
class LayerRecord:
    name: str
    module: nn.Module
    layer_type: str
    input_activation: torch.Tensor
    output_activation: torch.Tensor
    weight: torch.Tensor | None
    bias: torch.Tensor | None

    @property
    def input_shape(self) -> tuple[int, ...]:
        return tuple(self.input_activation.shape)

    @property
    def output_shape(self) -> tuple[int, ...]:
        return tuple(self.output_activation.shape)


def normalize_module_types(module_types: list[str] | tuple[str, ...] | None) -> set[str]:
    if not module_types:
        return {"Conv2d", "Linear"}
    cleaned = {item.strip() for item in module_types if item.strip()}
    if "all" in {item.lower() for item in cleaned}:
        return {"Conv2d", "Linear", "ReLU", "MaxPool2d"}
    return cleaned


def is_supported_layer(module: nn.Module, module_types: set[str] | None = None) -> bool:
    type_name = type(module).__name__
    canonical = canonical_layer_type(module)
    allowed = normalize_module_types(None) if module_types is None else module_types
    return canonical in allowed or type_name in allowed


def canonical_layer_type(module: nn.Module) -> str:
    if "Conv" in type(module).__name__:
        return "Conv2d"
    if "Linear" in type(module).__name__:
        return "Linear"
    if isinstance(module, nn.ReLU) or type(module).__name__ == "ReLU":
        return "ReLU"
    if isinstance(module, nn.MaxPool2d) or type(module).__name__ == "MaxPool2d":
        return "MaxPool2d"
    return type(module).__name__


def iter_target_layers(
    model: nn.Module,
    target_layer: str = "all",
    module_types: list[str] | tuple[str, ...] | None = None,
) -> Iterable[tuple[str, nn.Module]]:
    allowed = normalize_module_types(module_types)
    for name, module in model.named_modules():
        if not name or not is_supported_layer(module, allowed):
            continue
        if target_layer != "all" and name != target_layer:
            continue
        yield name, module


def get_module_weight(module: nn.Module) -> torch.Tensor | None:
    weight = getattr(module, "weight", None)
    if weight is None:
        return None
    if callable(weight):
        return weight().detach().cpu().clone()
    return weight.detach().cpu().clone()


def get_module_bias(module: nn.Module) -> torch.Tensor | None:
    bias = getattr(module, "bias", None)
    if callable(bias):
        bias = bias()
    if bias is None:
        return None
    return bias.detach().cpu().clone()


def extract_layer_records(
    model: nn.Module,
    input_tensor: torch.Tensor,
    target_layer: str = "all",
    max_layers: int | None = None,
    module_types: list[str] | tuple[str, ...] | None = None,
) -> tuple[OrderedDict[str, LayerRecord], torch.Tensor]:
    records: OrderedDict[str, LayerRecord] = OrderedDict()
    handles = []

    targets = list(iter_target_layers(model, target_layer, module_types))
    if max_layers is not None:
        targets = targets[:max_layers]
    if not targets:
        raise ValueError(f"No requested module type matched target_layer={target_layer!r}")

    def make_hook(layer_name: str, module: nn.Module):
        def hook(mod: nn.Module, inputs: tuple[torch.Tensor, ...], output: torch.Tensor) -> None:
            if layer_name in records:
                return
            records[layer_name] = LayerRecord(
                name=layer_name,
                module=mod,
                layer_type=canonical_layer_type(mod),
                input_activation=inputs[0].detach().cpu().clone(),
                output_activation=output.detach().cpu().clone(),
                weight=get_module_weight(mod),
                bias=get_module_bias(mod),
            )

        return hook

    for name, module in targets:
        handles.append(module.register_forward_hook(make_hook(name, module)))

    with torch.no_grad():
        output = model(input_tensor)

    for handle in handles:
        handle.remove()
    return records, output.detach().cpu()
