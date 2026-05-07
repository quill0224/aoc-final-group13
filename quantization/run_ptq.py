"""Run PTQ on a trained VGG-8 checkpoint and benchmark FP32 vs INT8.

Usage:
    python -m quantization.run_ptq --fp32 ./quantization/weights/best_vgg_cifar10.pth \
                                   --int8 ./quantization/weights/PTQ_vgg_cifar10.pth

Expected result (from Lab 1):
    FP32 91.79% / INT8 91.58% / 1.81x latency speedup / 3.99x compression.
"""

from __future__ import annotations

import argparse
import os
import platform
import time

import torch
import torch.nn as nn

from .data import get_cifar10_loaders
from .model import VGG
from .quantize import ptq_quantization
from .trainer import evaluate
from .utils import DEFAULT_DEVICE, load_model, plot_confusion_matrix


def _setup_quantized_engine() -> None:
    machine = platform.machine().lower()
    if "x86" in machine or "amd64" in machine:
        torch.backends.quantized.engine = "fbgemm"
    elif "arm" in machine or "aarch64" in machine:
        torch.backends.quantized.engine = "qnnpack"


def benchmark_latency(model, dummy_input, n: int = 1000) -> float:
    model.eval()
    t0 = time.time()
    with torch.no_grad():
        for _ in range(n):
            _ = model(dummy_input)
    return (time.time() - t0) / n


def main() -> None:
    parser = argparse.ArgumentParser(description="VGG-8 PTQ + FP32/INT8 benchmark")
    parser.add_argument("--fp32", default="./quantization/weights/best_vgg_cifar10.pth")
    parser.add_argument("--int8", default="./quantization/weights/PTQ_vgg_cifar10.pth")
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--data-root", type=str, default="data/cifar10")
    parser.add_argument("--results-dir", type=str, default="./quantization/results")
    args = parser.parse_args()

    _setup_quantized_engine()
    os.makedirs(args.results_dir, exist_ok=True)

    _, val_loader, test_loader = get_cifar10_loaders(batch_size=args.batch_size, root=args.data_root)

    model_int8 = ptq_quantization(args.fp32, args.int8, val_loader)

    criterion = nn.CrossEntropyLoss()
    model_fp32 = load_model(VGG(), args.fp32, verbose=True)

    print("\n=== Accuracy ===")
    print("FP32 ...")
    loss_fp32, acc_fp32, _ = evaluate(model_fp32, test_loader, criterion, device=DEFAULT_DEVICE)
    print(f"  Loss {loss_fp32:.4f} | Acc {acc_fp32:.2f}%")

    print("INT8 ...")
    loss_int8, acc_int8, conf_int8 = evaluate(model_int8, test_loader, criterion, device="cpu")
    print(f"  Loss {loss_int8:.4f} | Acc {acc_int8:.2f}%")
    plot_confusion_matrix(conf_int8, filename=os.path.join(args.results_dir, "confusion_matrix_int8.png"))

    print("\n=== Latency (CPU, 1 sample, 1000 runs) ===")
    model_fp32.cpu()
    dummy = torch.randn(1, 3, 32, 32)
    t_fp32 = benchmark_latency(model_fp32, dummy)
    t_int8 = benchmark_latency(model_int8, dummy)
    print(f"  FP32 {t_fp32 * 1000:.3f} ms | INT8 {t_int8 * 1000:.3f} ms | speedup {t_fp32 / t_int8:.2f}x")

    if os.path.exists(args.fp32) and os.path.exists(args.int8):
        sz_fp32 = os.path.getsize(args.fp32) / 1e6
        sz_int8 = os.path.getsize(args.int8) / 1e6
        print(f"\n=== Size ===\n  FP32 {sz_fp32:.2f} MB | INT8 {sz_int8:.2f} MB | compression {sz_fp32 / sz_int8:.2f}x")


if __name__ == "__main__":
    main()
