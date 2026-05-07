"""Extract Conv2D / MaxPool / Linear shapes from a PyTorch or ONNX model.

Uses forward hooks for PyTorch (works with quantized models too).
"""

from __future__ import annotations

import torch
import torch.nn as nn

from .layer_info import (
    Conv2DShapeParam,
    LinearShapeParam,
    MaxPool2DShapeParam,
    ShapeParam,
)


def parse_pytorch(model: nn.Module, input_shape=(1, 3, 32, 32)) -> list[ShapeParam]:
    """Run a dummy forward pass and collect per-layer shapes via hooks."""
    layers: list[ShapeParam] = []

    def hook_fn(module, inp, out):
        input_tensor = inp[0]
        N = input_tensor.shape[0]
        mod_name = type(module).__name__
        # Quantized variants: ConvReLU2d / LinearReLU don't subclass nn.Conv2d/Linear
        is_conv = isinstance(module, nn.Conv2d) or ("Conv" in mod_name and hasattr(module, "in_channels"))
        is_linear = isinstance(module, nn.Linear) or ("Linear" in mod_name and hasattr(module, "in_features"))

        if is_conv:
            H, W = input_tensor.shape[2], input_tensor.shape[3]
            layers.append(
                Conv2DShapeParam(
                    N=N, H=H, W=W,
                    R=module.kernel_size[0], S=module.kernel_size[1],
                    E=out.shape[2], F=out.shape[3],
                    C=module.in_channels, M=module.out_channels,
                    U=module.stride[0], P=module.padding[0],
                )
            )
        elif isinstance(module, nn.MaxPool2d):
            layers.append(
                MaxPool2DShapeParam(
                    N=N,
                    kernel_size=module.kernel_size,
                    stride=module.stride,
                )
            )
        elif is_linear:
            layers.append(
                LinearShapeParam(
                    N=N,
                    in_features=module.in_features,
                    out_features=module.out_features,
                )
            )

    hooks = []
    for module in model.modules():
        mod_name = type(module).__name__
        is_conv = isinstance(module, nn.Conv2d) or ("Conv" in mod_name and hasattr(module, "in_channels"))
        is_linear = isinstance(module, nn.Linear) or ("Linear" in mod_name and hasattr(module, "in_features"))
        is_maxpool = isinstance(module, nn.MaxPool2d)

        if is_conv or is_maxpool:
            # Conv/MaxPool: only hook leaf modules to avoid duplicate firing
            if len(list(module.children())) == 0:
                hooks.append(module.register_forward_hook(hook_fn))
        elif is_linear:
            # LinearReLU has child modules (LinearPackedParams) - don't restrict to leaf
            hooks.append(module.register_forward_hook(hook_fn))

    model.eval()
    with torch.no_grad():
        model(torch.randn(*input_shape))

    for h in hooks:
        h.remove()

    return layers


def parse_onnx(model) -> list[ShapeParam]:
    """Static-shape extraction from an ONNX ModelProto (no forward pass)."""
    import onnx
    from onnx import shape_inference

    inferred = shape_inference.infer_shapes(model)

    def get_tensor_shape(tensor_name: str) -> list[int]:
        for vi in inferred.graph.value_info:
            if vi.name == tensor_name:
                return [d.dim_value for d in vi.type.tensor_type.shape.dim]
        for inp in inferred.graph.input:
            if inp.name == tensor_name:
                return [d.dim_value for d in inp.type.tensor_type.shape.dim]
        for out in inferred.graph.output:
            if out.name == tensor_name:
                return [d.dim_value for d in out.type.tensor_type.shape.dim]
        return []

    init_shapes = {init.name: list(init.dims) for init in inferred.graph.initializer}

    layers: list[ShapeParam] = []
    for node in inferred.graph.node:
        if node.op_type == "Conv":
            in_shape = get_tensor_shape(node.input[0])
            w_shape = init_shapes.get(node.input[1])
            out_shape = get_tensor_shape(node.output[0])
            strides, pads = [1], [0]
            for attr in node.attribute:
                if attr.name == "strides":
                    strides = list(attr.ints)
                elif attr.name == "pads":
                    pads = list(attr.ints)
            layers.append(
                Conv2DShapeParam(
                    N=in_shape[0], H=in_shape[2], W=in_shape[3],
                    R=w_shape[2], S=w_shape[3],
                    E=out_shape[2], F=out_shape[3],
                    C=in_shape[1], M=w_shape[0],
                    U=strides[0], P=pads[0],
                )
            )
        elif node.op_type == "MaxPool":
            in_shape = get_tensor_shape(node.input[0])
            kernel_size, stride = 2, 2
            for attr in node.attribute:
                if attr.name == "kernel_shape":
                    kernel_size = attr.ints[0]
                elif attr.name == "strides":
                    stride = attr.ints[0]
            layers.append(MaxPool2DShapeParam(N=in_shape[0], kernel_size=kernel_size, stride=stride))
        elif node.op_type in ("Gemm", "MatMul"):
            w_shape = init_shapes.get(node.input[1])
            in_shape = get_tensor_shape(node.input[0])
            transB = 0
            for attr in node.attribute:
                if attr.name == "transB":
                    transB = attr.i
            if transB:
                in_features, out_features = w_shape[1], w_shape[0]
            else:
                in_features, out_features = w_shape[0], w_shape[1]
            layers.append(LinearShapeParam(N=in_shape[0], in_features=in_features, out_features=out_features))

    return layers
