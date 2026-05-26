import sys
from pathlib import Path
from typing import Optional

import torch
import torch.nn as nn
import torch.ao.nn.intrinsic.quantized as nniq
import torch.ao.nn.quantized as nnq
try:
    import onnx
except ImportError:
    onnx = None

project_root = Path(__file__).parents[1]
sys.path.append(str(project_root))

from layer_info import (
    ShapeParam,
    Conv2DShapeParam,
    LinearShapeParam,
    MaxPool2DShapeParam,
)

from lib.models.vgg import VGG
from network_parser import torch2onnx
# def torch2onnx(model, output_file_path, dummy_input):
#     export_kwargs = dict(
#         export_params=True,
#         opset_version=11,
#         do_constant_folding=True,
#         input_names=["input"],
#         output_names=["output"],
#         dynamic_axes=None,
#     )

#     try:
#         torch.onnx.export(
#             model,
#             dummy_input,
#             output_file_path,
#             dynamo=False,
#             **export_kwargs,
#         )
#     except TypeError:
#         torch.onnx.export(
#             model,
#             dummy_input,
#             output_file_path,
#             **export_kwargs,
#         )

#     print(f"Model saved as {output_file_path}")


def _conv_module_types() -> tuple:
    types = [nn.Conv2d, nnq.Conv2d]
    for name in ("ConvReLU2d", "ConvBn2d", "ConvBnReLU2d"):
        module_type = getattr(nniq, name, None)
        if module_type is not None:
            types.append(module_type)
    return tuple(types)


def parse_pytorch(
    model: nn.Module,
    input_shape=(1, 3, 32, 32),
    conv_only: bool = False,
) -> list[ShapeParam]:
    layers = []
    #! <<<========= Implement here =========>>>
    conv_types = _conv_module_types()
    linear_types = (nn.Linear, nnq.Linear, nniq.LinearReLU)

    def hook_fn(module: nn.Module, inputs: torch.Tensor, output: torch.Tensor) -> None:
        x = inputs[0]
        # 根據不同的層類型，提取對應的 ShapeParam
        if isinstance(module, conv_types):
            param = Conv2DShapeParam(
                N=x.shape[0],
                H=x.shape[2],
                W=x.shape[3],
                C=module.in_channels,
                M=module.out_channels,
                R=module.kernel_size[0],
                S=module.kernel_size[1],
                U=module.stride[0],
                P=module.padding[0],
                E=output.shape[2],
                F=output.shape[3]
            )
            layers.append(param)
        elif not conv_only and isinstance(module, nn.MaxPool2d):
            param = MaxPool2DShapeParam(
                N=x.shape[0],
                kernel_size=module.kernel_size,
                stride=module.stride
            )
            layers.append(param)
        elif not conv_only and isinstance(module, linear_types):
            param = LinearShapeParam(
                N=x.shape[0],
                in_features=module.in_features,
                out_features=module.out_features
            )
            layers.append(param)

    # 1 & 2. 註冊 Hooks 到子模組 (Leaf Modules)
    hooks = []
    for module in model.modules():
        # 只針對我們有興趣的運算層進行 Hook
        if isinstance(module, conv_types) or (
            not conv_only and isinstance(module, (nn.MaxPool2d, *linear_types))
        ):
            hooks.append(module.register_forward_hook(hook_fn))

    # 3. 觸發 Forward Pass
    dummy_input = torch.randn(*input_shape)
    model.eval() # 確保是在推論模式
    with torch.no_grad():
        model(dummy_input)

    # 移除 Hooks 清理現場
    for h in hooks:
        h.remove()
    return layers


def _get_conv_weight(module: nn.Module) -> Optional[torch.Tensor]:
    weight = getattr(module, "weight", None)
    if callable(weight):
        weight = weight()
    if weight is None:
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
                "compression_ratio": (
                    compressed_total_bytes / dense_bytes if dense_bytes else 0.0
                ),
            }
        )
    return rows


def parse_onnx(model) -> list[ShapeParam]:
    if onnx is None:
        raise ImportError("onnx is not installed; use --format torch or install onnx.")

    layers = []
    #! <<<========= Implement here =========>>>
    inferred_model = onnx.shape_inference.infer_shapes(model)
    graph = inferred_model.graph

    # 輔助函式：從 Graph 中尋找 Tensor 的 Shape
    def get_shape(tensor_name):
        # 優先找 value_info (Activations)
        for info in list(graph.value_info) + list(graph.input) + list(graph.output):
            if info.name == tensor_name:
                return [dim.dim_value for dim in info.type.tensor_type.shape.dim]
        # 再找 initializer (Weights)
        for init in graph.initializer:
            if init.name == tensor_name:
                return list(init.dims)
        return None

    # 遍歷節點
    for node in graph.node:
        in_shape = get_shape(node.input[0])
        out_shape = get_shape(node.output[0])
        
        # 將 ONNX Attribute 轉換為 Dictionary 方便讀取
        attrs = {attr.name: attr for attr in node.attribute}

        if node.op_type == "Conv":
            # ONNX pads 通常是 [top, left, bottom, right]
            # 這裡簡化取第一個值 (對稱 padding)
            padding = attrs["pads"].ints[0] if "pads" in attrs else 0
            stride = attrs["strides"].ints[0] if "strides" in attrs else 1
            kernel = attrs["kernel_shape"].ints
            
            # 從權重 tensor (input[1]) 獲取通道數
            weight_shape = get_shape(node.input[1]) # [M, C, R, S]
            
            layers.append(Conv2DShapeParam(
                N=in_shape[0], H=in_shape[2], W=in_shape[3],
                C=weight_shape[1], M=weight_shape[0],
                R=kernel[0], S=kernel[1],
                U=stride, P=padding,
                E=out_shape[2], F=out_shape[3]
            ) )
        elif node.op_type == "MaxPool":
            kernel = attrs["kernel_shape"].ints[0]
            stride = attrs["strides"].ints[0]
            layers.append(MaxPool2DShapeParam(N=in_shape[0], kernel_size=kernel, stride=stride))
        elif node.op_type == "Gemm": # ONNX 的 Linear 通常對應 Gemm
            # Gemm input B (weight) shape is [out_features, in_features]
            weight_shape = get_shape(node.input[1])
            layers.append(LinearShapeParam(
                N=in_shape[0], 
                in_features=weight_shape[1], 
                out_features=weight_shape[0]
            ))
    return layers


def compare_layers(answer, layers):
    if len(answer) != len(layers):
        print(
            f"Layer count mismatch: answer has {len(answer)}, but ONNX has {len(layers)}"
        )

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
                print(f"  {k}: answer = {ans_val}, onnx = {val}")

    if len(answer) > len(layers):
        print(f"Extra layers in answer: {answer[len(layers) :]}")
    elif len(layers) > len(answer):
        print(f"Extra layers in yours: {layers[len(answer) :]}")


def run_tests() -> None:
    """Run tests on the network parser functions."""
    answer = [
        Conv2DShapeParam(N=1, H=32, W=32, R=3, S=3, E=32, F=32, C=3, M=64, U=1, P=1),
        MaxPool2DShapeParam(N=1, kernel_size=2, stride=2),
        Conv2DShapeParam(N=1, H=16, W=16, R=3, S=3, E=16, F=16, C=64, M=192, U=1, P=1),
        MaxPool2DShapeParam(N=1, kernel_size=2, stride=2),
        Conv2DShapeParam(N=1, H=8, W=8, R=3, S=3, E=8, F=8, C=192, M=384, U=1, P=1),
        Conv2DShapeParam(N=1, H=8, W=8, R=3, S=3, E=8, F=8, C=384, M=256, U=1, P=1),
        Conv2DShapeParam(N=1, H=8, W=8, R=3, S=3, E=8, F=8, C=256, M=256, U=1, P=1),
        MaxPool2DShapeParam(N=1, kernel_size=2, stride=2),
        LinearShapeParam(N=1, in_features=4096, out_features=256),
        LinearShapeParam(N=1, in_features=256, out_features=128),
        LinearShapeParam(N=1, in_features=128, out_features=10),
    ]

    # Test with the PyTorch model.
    model = VGG()
    layers_pth = parse_pytorch(model)

    # Define the input shape.
    dummy_input = torch.randn(1, 3, 32, 32)
    # Save the model to ONNX.
    torch2onnx(model, "parser_onnx.onnx", dummy_input)
    # Load the ONNX model.
    model_onnx = onnx.load("parser_onnx.onnx")
    layers_onnx = parse_onnx(model_onnx)

    # Display results.
    print("PyTorch Network Parser:")
    if layers_pth == answer:
        print("Correct!")
    else:
        print("Wrong!")
        compare_layers(answer, layers_pth)

    print("ONNX Network Parser:")
    if layers_onnx == answer:
        print("Correct!")
    else:
        print("Wrong!")
        compare_layers(answer, layers_onnx)


if __name__ == "__main__":
    run_tests()
