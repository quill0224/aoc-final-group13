import argparse
import csv
from pathlib import Path
import sys

SRC_DIR = Path(__file__).resolve().parents[1]
if str(SRC_DIR) not in sys.path:
    sys.path.insert(0, str(SRC_DIR))

import torch
import torch.ao.quantization as tq

from layer_info import Conv2DShapeParam
from lib.models import VGG
from lib.models.qconfig import CustomQConfig
from network_parser import parse_pytorch, profile_conv_weights

if "qnnpack" in torch.backends.quantized.supported_engines:
    torch.backends.quantized.engine = "qnnpack"
elif "fbgemm" in torch.backends.quantized.supported_engines:
    torch.backends.quantized.engine = "fbgemm"


def load_vgg16_model(model_path, backend: str, num_classes: int, conv_only: bool):
    model = VGG(arch="vgg16", in_channels=3, in_size=224, num_classes=num_classes)
    if backend in ("power2", "dyadic", "qnnpack"):
        model.eval()
        model.fuse_modules()
        model.qconfig = CustomQConfig[backend.upper()].value
        tq.prepare(model, inplace=True)
        tq.convert(model, inplace=True)

    state_dict = torch.load(model_path, map_location="cpu")
    try:
        model.load_state_dict(state_dict)
    except RuntimeError:
        if not conv_only:
            raise
        current = model.state_dict()
        matched = {}
        for key, value in state_dict.items():
            if key not in current:
                continue
            current_value = current[key]
            if hasattr(value, "shape") and hasattr(current_value, "shape"):
                if tuple(value.shape) != tuple(current_value.shape):
                    continue
            matched[key] = value
        model.load_state_dict(matched, strict=False)
    return model


def parse_args() -> argparse.Namespace:
    default_model = SRC_DIR / "weights" / "vgg16_imagenet100_pruned_power2_int8.pth"
    parser = argparse.ArgumentParser(
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
    )
    parser.add_argument("--model-path", type=Path, default=default_model)
    parser.add_argument("--output", type=Path, default=Path("layer_sparsity.csv"))
    parser.add_argument("--backend", choices=["power2", "dyadic", "qnnpack", "none"], default="power2")
    parser.add_argument("--input-size", type=int, default=224)
    parser.add_argument("--num-classes", type=int, default=100)
    parser.add_argument("--conv-only", action="store_true")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    model = load_vgg16_model(
        args.model_path,
        backend=args.backend,
        num_classes=args.num_classes,
        conv_only=args.conv_only,
    )

    layers = parse_pytorch(
        model,
        input_shape=(1, 3, args.input_size, args.input_size),
        conv_only=True,
    )
    for idx, layer in enumerate(layers, start=1):
        if isinstance(layer, Conv2DShapeParam):
            print(
                f"conv{idx}: N={layer.N}, C={layer.C}, M={layer.M}, "
                f"HxW={layer.H}x{layer.W}, K={layer.R}x{layer.S}, "
                f"out={layer.E}x{layer.F}"
            )

    rows = profile_conv_weights(model)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with open(args.output, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()) if rows else [])
        writer.writeheader()
        writer.writerows(rows)
    print(f"Sparsity profile is saved to {args.output}.")


if __name__ == "__main__":
    main()
