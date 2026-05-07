"""Train VGG-8 on CIFAR-10 and save the best-val checkpoint.

Usage:
    python -m quantization.run_train --epochs 200 --lr 0.01 --batch-size 32

Expected result (from Lab 1): ~91.7% top-1 on CIFAR-10 test set.
"""

from __future__ import annotations

import argparse
import platform

import torch

from .data import get_cifar10_loaders
from .model import VGG
from .trainer import train_model
from .utils import DEFAULT_DEVICE


def _setup_quantized_engine() -> None:
    machine = platform.machine().lower()
    if "x86" in machine or "amd64" in machine:
        torch.backends.quantized.engine = "fbgemm"
    elif "arm" in machine or "aarch64" in machine:
        torch.backends.quantized.engine = "qnnpack"


def main() -> None:
    parser = argparse.ArgumentParser(description="Train VGG-8 on CIFAR-10")
    parser.add_argument("--epochs", type=int, default=200)
    parser.add_argument("--lr", type=float, default=0.01)
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--split-ratio", type=float, default=0.1)
    parser.add_argument("--save-path", type=str, default="./quantization/weights/best_vgg_cifar10.pth")
    parser.add_argument("--data-root", type=str, default="data/cifar10")
    args = parser.parse_args()

    _setup_quantized_engine()
    print(f"PyTorch {torch.__version__} | device {DEFAULT_DEVICE} | engine {torch.backends.quantized.engine}")

    train_loader, val_loader, _ = get_cifar10_loaders(
        batch_size=args.batch_size, root=args.data_root, split_ratio=args.split_ratio,
    )

    model = VGG().to(DEFAULT_DEVICE)
    train_model(
        model, train_loader, val_loader,
        epochs=args.epochs, lr=args.lr, device=DEFAULT_DEVICE,
        save_path=args.save_path,
    )


if __name__ == "__main__":
    main()
