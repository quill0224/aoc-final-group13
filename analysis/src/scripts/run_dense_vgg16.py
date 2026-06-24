import argparse
import csv
from pathlib import Path
import sys

SRC_DIR = Path(__file__).resolve().parents[1]
if str(SRC_DIR) not in sys.path:
    sys.path.insert(0, str(SRC_DIR))

from analytical_model import SparseDenseAcceleratorMapper
from layer_info import Conv2DShapeParam
from lib.models import VGG
from network_parser import parse_pytorch


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
    )
    parser.add_argument("--output", type=Path, default=Path("dense_output.csv"))
    parser.add_argument("--input-size", type=int, default=224)
    parser.add_argument("--num-classes", type=int, default=100)
    return parser.parse_args()


def conv_layers(parsed_layers: list) -> list:
    layers = []
    for layer in parsed_layers:
        if isinstance(layer, Conv2DShapeParam):
            layers.append(layer)
    return layers


def write_csv(rows: list, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = list(rows[0].keys()) if rows else []
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def main() -> None:
    args = parse_args()
    model = VGG(arch="vgg16", in_channels=3, in_size=args.input_size, num_classes=args.num_classes)
    parsed_layers = parse_pytorch(
        model,
        input_shape=(1, 3, args.input_size, args.input_size),
        conv_only=False,
    )

    results = []
    for idx, conv in enumerate(conv_layers(parsed_layers)):
        mapper = SparseDenseAcceleratorMapper(name=f"vgg16.conv{idx}")
        results.extend(mapper.run(conv, mode="dense", num_solutions=0))

    write_csv(results, args.output)
    print(f"Dense VGG-16 analytical results are saved to {args.output}.")


if __name__ == "__main__":
    main()
