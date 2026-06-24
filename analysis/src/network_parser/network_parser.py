from __future__ import annotations

import sys
from pathlib import Path
from typing import Optional, Sequence

import torch
import torch.nn as nn
import torch.ao.nn.intrinsic.quantized as nniq
import torch.ao.nn.quantized as nnq

try:
    import onnx
except ImportError:  # pragma: no cover
    onnx = None

project_root = Path(__file__).parents[1]
if str(project_root) not in sys.path:
    sys.path.append(str(project_root))

from layer_info import (
    ShapeParam,
    Conv2DShapeParam,
    LinearShapeParam,
    MaxPool2DShapeParam,
)

# ImageNet / ImageNet-100 VGG-style input.
DEFAULT_BATCH_SIZE = 1
DEFAULT_CHANNELS = 3
DEFAULT_IMAGE_SIZE = 224
DEFAULT_INPUT_SHAPE = (DEFAULT_BATCH_SIZE, DEFAULT_CHANNELS, DEFAULT_IMAGE_SIZE, DEFAULT_IMAGE_SIZE)


def normalize_input_shape(
    input_shape: Sequence[int] | None = None,
    *,
    batch_size: int = DEFAULT_BATCH_SIZE,
    channels: int = DEFAULT_CHANNELS,
    image_size: int = DEFAULT_IMAGE_SIZE,
) -> tuple[int, int, int, int]:
    """Return a validated NCHW input shape.

    The analytical model derives Conv2DShapeParam by executing a dummy forward.
    For ImageNet-100 experiments the dummy input must be 1x3x224x224 instead
    of the old CIFAR-style 1x3x32x32.
    """
    if input_shape is None:
        shape = (batch_size, channels, image_size, image_size)
    else:
        shape = tuple(int(v) for v in input_shape)

    if len(shape) != 4:
        raise ValueError(f"input_shape must be NCHW with 4 dims, got {shape}")
    if any(v <= 0 for v in shape):
        raise ValueError(f"input_shape values must be positive, got {shape}")
    return shape  # type: ignore[return-value]


def torch2onnx(
    model: nn.Module,
    output_file_path: str | Path,
    dummy_input: torch.Tensor | None = None,
    input_shape: Sequence[int] | None = None,
) -> None:
    """Export a PyTorch model to ONNX using ImageNet-100 input by default."""
    if dummy_input is None:
        dummy_input = torch.randn(*normalize_input_shape(input_shape))

    model.eval()
    output_file_path = str(output_file_path)
    export_kwargs = dict(
        export_params=True,
        opset_version=11,
        do_constant_folding=True,
        input_names=["input"],
        output_names=["output"],
        dynamic_axes=None,
    )

    try:
        torch.onnx.export(
            model,
            dummy_input,
            output_file_path,
            dynamo=False,
            **export_kwargs,
        )
    except TypeError:
        torch.onnx.export(
            model,
            dummy_input,
            output_file_path,
            **export_kwargs,
        )

    print(f"Model saved as {output_file_path}")


def _conv_module_types() -> tuple[type[nn.Module], ...]:
    types: list[type[nn.Module]] = [nn.Conv2d, nnq.Conv2d]
    for name in ("ConvReLU2d", "ConvBn2d", "ConvBnReLU2d"):
        module_type = getattr(nniq, name, None)
        if module_type is not None:
            types.append(module_type)
    return tuple(types)


def _linear_module_types() -> tuple[type[nn.Module], ...]:
    types: list[type[nn.Module]] = [nn.Linear, nnq.Linear]
    linear_relu = getattr(nniq, "LinearReLU", None)
    if linear_relu is not None:
        types.append(linear_relu)
    return tuple(types)


def _as_pair(value: int | tuple[int, int]) -> tuple[int, int]:
    if isinstance(value, tuple):
        return int(value[0]), int(value[1])
    return int(value), int(value)


def _shape_of(obj) -> tuple[int, ...]:
    """Robustly extract a tensor-like output shape.

    Some models return a tuple/list. The parser only needs the first tensor.
    """
    if isinstance(obj, torch.Tensor):
        return tuple(int(v) for v in obj.shape)
    if isinstance(obj, (tuple, list)) and len(obj) > 0:
        return _shape_of(obj[0])
    raise TypeError(f"Unsupported hook output type: {type(obj)}")


def parse_pytorch(
    model: nn.Module,
    input_shape: Sequence[int] | None = None,
    conv_only: bool = False,
) -> list[ShapeParam]:
    """Parse PyTorch model layers by running a dummy ImageNet-100 forward pass.

    Default dummy input is (1, 3, 224, 224). This is the key change from the
    old CIFAR parser that used (1, 3, 32, 32).
    """
    input_shape = normalize_input_shape(input_shape)
    layers: list[ShapeParam] = []
    conv_types = _conv_module_types()
    linear_types = _linear_module_types()

    def hook_fn(module: nn.Module, inputs, output) -> None:
        x = inputs[0]
        if not isinstance(x, torch.Tensor):
            return

        if isinstance(module, conv_types):
            out_shape = _shape_of(output)
            kh, kw = _as_pair(module.kernel_size)
            sh, _ = _as_pair(module.stride)
            ph, _ = _as_pair(module.padding)
            param = Conv2DShapeParam(
                N=int(x.shape[0]),
                H=int(x.shape[2]),
                W=int(x.shape[3]),
                C=int(module.in_channels),
                M=int(module.out_channels),
                R=kh,
                S=kw,
                U=sh,
                P=ph,
                E=int(out_shape[2]),
                F=int(out_shape[3]),
            )
            layers.append(param)
        elif not conv_only and isinstance(module, nn.MaxPool2d):
            kernel_h, _ = _as_pair(module.kernel_size)
            stride_h, _ = _as_pair(module.stride if module.stride is not None else module.kernel_size)
            param = MaxPool2DShapeParam(
                N=int(x.shape[0]),
                kernel_size=kernel_h,
                stride=stride_h,
            )
            layers.append(param)
        elif not conv_only and isinstance(module, linear_types):
            param = LinearShapeParam(
                N=int(x.shape[0]),
                in_features=int(module.in_features),
                out_features=int(module.out_features),
            )
            layers.append(param)

    hooks = []
    for module in model.modules():
        if isinstance(module, conv_types) or (
            not conv_only and isinstance(module, (nn.MaxPool2d, *linear_types))
        ):
            hooks.append(module.register_forward_hook(hook_fn))

    dummy_input = torch.randn(*input_shape)
    device = next(model.parameters(), torch.empty(0)).device
    dummy_input = dummy_input.to(device)

    was_training = model.training
    model.eval()
    try:
        with torch.no_grad():
            model(dummy_input)
    finally:
        for h in hooks:
            h.remove()
        if was_training:
            model.train()

    return layers


def _get_conv_weight(module: nn.Module) -> Optional[torch.Tensor]:
    weight = getattr(module, "weight", None)
    if callable(weight):
        weight = weight()
    if weight is None or not isinstance(weight, torch.Tensor):
        return None
    return weight.detach()


def _count_nonzero_weights(weight: torch.Tensor) -> int:
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


def profile_conv_weights(model: nn.Module) -> list[dict]:
    """Return per-Conv-layer weight sparsity and INT8 storage estimates."""
    rows = []
    conv_types = _conv_module_types()

    for layer_index, (name, module) in enumerate(
        (item for item in model.named_modules() if isinstance(item[1], conv_types)),
        start=1,
    ):
        weight = _get_conv_weight(module)
        if weight is None:
            continue

        total = int(weight.numel())
        nonzero = _count_nonzero_weights(weight)
        zero = total - nonzero
        dense_bytes = total
        bitmask_bytes = ((total + 63) // 64) * 8
        compressed_value_bytes = nonzero
        compressed_total_bytes = compressed_value_bytes + bitmask_bytes

        rows.append(
            {
                "layer_index": layer_index,
                "module_name": name,
                "weight_shape": "x".join(str(dim) for dim in weight.shape),
                "total_weight_elements": total,
                "nonzero_weight_elements": nonzero,
                "zero_weight_elements": zero,
                "density": nonzero / total if total else 0.0,
                "sparsity": zero / total if total else 0.0,
                "dense_int8_weight_bytes": dense_bytes,
                "bitmask_bytes": bitmask_bytes,
                "compressed_int8_value_bytes": compressed_value_bytes,
                "compressed_total_bytes": compressed_total_bytes,
                "compression_ratio": compressed_total_bytes / dense_bytes if dense_bytes else 0.0,
            }
        )
    return rows


def _load_onnx_model(model_or_path):
    if onnx is None:
        raise ImportError("onnx is not installed; use --format torch or install onnx.")
    if isinstance(model_or_path, (str, Path)):
        return onnx.load(str(model_or_path))
    return model_or_path


def _dim_value(dim) -> int:
    if getattr(dim, "dim_value", 0):
        return int(dim.dim_value)
    # Analytical model needs concrete dimensions. Batch may be symbolic; use 1.
    return 1


def parse_onnx(model_or_path) -> list[ShapeParam]:
    """Parse ONNX Conv/MaxPool/Gemm layers.

    Accepts either an ONNX model object or a path. Shapes must already be fixed
    in the ONNX graph; for ImageNet-100 export with input 1x3x224x224.
    """
    model = _load_onnx_model(model_or_path)
    layers: list[ShapeParam] = []
    inferred_model = onnx.shape_inference.infer_shapes(model)
    graph = inferred_model.graph

    def get_shape(tensor_name: str) -> list[int] | None:
        for info in list(graph.value_info) + list(graph.input) + list(graph.output):
            if info.name == tensor_name:
                dims = info.type.tensor_type.shape.dim
                return [_dim_value(dim) for dim in dims]
        for init in graph.initializer:
            if init.name == tensor_name:
                return [int(v) for v in init.dims]
        return None

    for node in graph.node:
        in_shape = get_shape(node.input[0]) if len(node.input) > 0 else None
        out_shape = get_shape(node.output[0]) if len(node.output) > 0 else None
        attrs = {attr.name: attr for attr in node.attribute}

        if node.op_type == "Conv":
            if in_shape is None or out_shape is None:
                raise ValueError(f"Cannot infer Conv shapes for node {node.name or node.output[0]}")
            weight_shape = get_shape(node.input[1])
            if weight_shape is None:
                raise ValueError(f"Cannot infer Conv weight shape for node {node.name or node.output[0]}")
            padding = int(attrs["pads"].ints[0]) if "pads" in attrs else 0
            stride = int(attrs["strides"].ints[0]) if "strides" in attrs else 1
            kernel = list(attrs["kernel_shape"].ints) if "kernel_shape" in attrs else weight_shape[2:4]
            layers.append(
                Conv2DShapeParam(
                    N=int(in_shape[0]),
                    H=int(in_shape[2]),
                    W=int(in_shape[3]),
                    C=int(weight_shape[1]),
                    M=int(weight_shape[0]),
                    R=int(kernel[0]),
                    S=int(kernel[1]),
                    U=stride,
                    P=padding,
                    E=int(out_shape[2]),
                    F=int(out_shape[3]),
                )
            )
        elif node.op_type == "MaxPool":
            if in_shape is None:
                raise ValueError(f"Cannot infer MaxPool input shape for node {node.name or node.output[0]}")
            kernel = int(attrs["kernel_shape"].ints[0])
            stride = int(attrs["strides"].ints[0])
            layers.append(MaxPool2DShapeParam(N=int(in_shape[0]), kernel_size=kernel, stride=stride))
        elif node.op_type == "Gemm":
            if in_shape is None:
                raise ValueError(f"Cannot infer Gemm input shape for node {node.name or node.output[0]}")
            weight_shape = get_shape(node.input[1])
            if weight_shape is None:
                raise ValueError(f"Cannot infer Gemm weight shape for node {node.name or node.output[0]}")
            layers.append(
                LinearShapeParam(
                    N=int(in_shape[0]),
                    in_features=int(weight_shape[1]),
                    out_features=int(weight_shape[0]),
                )
            )
    return layers


def compare_layers(answer: list[ShapeParam], layers: list[ShapeParam]) -> None:
    if len(answer) != len(layers):
        print(f"Layer count mismatch: answer has {len(answer)}, parsed has {len(layers)}")

    min_len = min(len(answer), len(layers))
    for i in range(min_len):
        ans_layer = vars(answer[i])
        layer = vars(layers[i])
        diffs = {
            k: (ans_layer[k], layer[k])
            for k in ans_layer
            if k in layer and ans_layer[k] != layer[k]
        }
        if diffs:
            print(f"Difference in layer {i + 1} ({type(answer[i]).__name__}):")
            for k, (ans_val, val) in diffs.items():
                print(f"  {k}: answer = {ans_val}, parsed = {val}")

    if len(answer) > len(layers):
        print(f"Extra layers in answer: {answer[len(layers):]}")
    elif len(layers) > len(answer):
        print(f"Extra layers parsed: {layers[len(answer):]}")


def run_tests() -> None:
    """Run a lightweight ImageNet-100 parser smoke test."""
    try:
        from lib.models.vgg import VGG
    except Exception as exc:
        raise RuntimeError("Cannot import VGG for parser tests") from exc

    model = VGG(arch="vgg16")
    layers = parse_pytorch(model, input_shape=DEFAULT_INPUT_SHAPE)
    conv_layers = [layer for layer in layers if isinstance(layer, Conv2DShapeParam)]

    print("PyTorch Network Parser ImageNet-100 smoke test:")
    print(f"  input_shape : {DEFAULT_INPUT_SHAPE}")
    print(f"  conv layers : {len(conv_layers)}")
    if not conv_layers:
        raise AssertionError("No Conv2D layers were parsed")

    first = conv_layers[0]
    print(f"  first conv  : H={first.H}, W={first.W}, E={first.E}, F={first.F}")
    if (first.H, first.W) != (224, 224):
        raise AssertionError(f"Expected first conv input 224x224, got {first.H}x{first.W}")
    print("Correct!")


if __name__ == "__main__":
    run_tests()
