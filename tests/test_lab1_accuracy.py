"""End-to-end PTQ accuracy parity check (Lab 1).

Slow (~5-10 min on CPU). Loads FP32 weights, runs our PTQ pipeline, evaluates
on CIFAR-10 test set. Asserts FP32 / INT8 accuracy thresholds.

Usage:
    python tests/test_lab1_accuracy.py
    python tests/test_lab1_accuracy.py --fp32-min 91.5 --int8-min 91.3
    python tests/test_lab1_accuracy.py --quick     # eval only 1000 samples
    python tests/test_lab1_accuracy.py --copy-weights   # auto-pull from Lab 1

What it catches:
    - BN folding broken (typically drops accuracy by 5-10%)
    - PowerOfTwoObserver wrong scale (NaN or accuracy collapse)
    - QuantStub / DeQuantStub mis-placed
    - Conv-BN-ReLU fusion list out of sync with model.py architecture
    - Eval transform Normalize() drift vs Lab 1 (means / stds)
    - Wrong quantized engine (fbgemm on M-series Mac will crash)

Defaults match Lab 1 published numbers:
    FP32 91.79%, INT8 91.58%, 4x compression (Lab 1 README).
"""
from __future__ import annotations

import argparse
import platform
import shutil
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT))

# ----- CONFIG -----
CONFIG = {
    "fp32_path": str(PROJECT_ROOT / "quantization/weights/best_vgg_cifar10.pth"),
    "int8_path": str(PROJECT_ROOT / "quantization/weights/PTQ_vgg_cifar10.pth"),
    "lab1_weights_dir": "/Users/quillq/EE/碩ㄧ課/AOC/aoc2026-lab1/weights",
    "data_root": str(PROJECT_ROOT / "data/cifar10"),
    "batch_size": 128,
    "fp32_min_acc": 91.0,   # generous floor; Lab 1 was 91.79
    "int8_min_acc": 91.0,   # generous floor; Lab 1 was 91.58
    "fp32_int8_drop_max": 0.5,  # INT8 should not lose more than 0.5% vs FP32
}


def setup_quantized_engine() -> None:
    machine = platform.machine().lower()
    if "x86" in machine or "amd64" in machine:
        import torch
        torch.backends.quantized.engine = "fbgemm"
    elif "arm" in machine or "aarch64" in machine:
        import torch
        torch.backends.quantized.engine = "qnnpack"


def maybe_copy_weights(fp32_path: Path, lab1_dir: Path) -> bool:
    if fp32_path.exists():
        return True
    src = lab1_dir / "best_vgg_cifar10.pth"
    if not src.exists():
        print(f"FAIL  Lab 1 weights not found at {src}")
        return False
    fp32_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, fp32_path)
    print(f"  Copied {src} -> {fp32_path}")
    return True


def main(
    fp32_path: str, int8_path: str, lab1_dir: str, data_root: str,
    batch_size: int, fp32_min: float, int8_min: float, drop_max: float,
    quick: bool, copy_weights: bool,
) -> int:
    fp32_p, int8_p, lab1_p = Path(fp32_path), Path(int8_path), Path(lab1_dir)

    if copy_weights or not fp32_p.exists():
        if not maybe_copy_weights(fp32_p, lab1_p):
            return 1

    # Imports deferred so the unit test bundle doesn't pull torch needlessly
    import torch
    import torch.nn as nn
    from quantization.data import get_cifar10_loaders
    from quantization.model import VGG
    from quantization.quantize import ptq_quantization
    from quantization.trainer import evaluate
    from quantization.utils import load_model

    setup_quantized_engine()

    # Load data
    print(f"\n[Loading CIFAR-10 from {data_root}]")
    _, val_loader, test_loader = get_cifar10_loaders(
        batch_size=batch_size, root=data_root, num_workers=2,
    )
    if quick:
        # Subset test loader for fast smoke check
        from torch.utils.data import DataLoader, Subset
        n = min(1000, len(test_loader.dataset))
        test_loader = DataLoader(
            Subset(test_loader.dataset, list(range(n))),
            batch_size=batch_size, shuffle=False,
        )
        print(f"  --quick: limited test set to {n} samples")

    fails = 0

    # ----- 1. Evaluate FP32 -----
    print(f"\n[Evaluating FP32 from {fp32_p}]")
    model_fp32 = load_model(VGG(), str(fp32_p), verbose=False)
    criterion = nn.CrossEntropyLoss()
    _, fp32_acc, _ = evaluate(model_fp32, test_loader, criterion, device="cpu")
    ok = fp32_acc >= fp32_min
    marker = "OK  " if ok else "FAIL"
    print(f"  [{marker}] FP32 acc = {fp32_acc:.2f}%   (threshold >= {fp32_min}%)")
    fails += 0 if ok else 1

    # ----- 2. Run our PTQ + evaluate -----
    print(f"\n[Running our PTQ pipeline]")
    model_int8 = ptq_quantization(str(fp32_p), str(int8_p), val_loader)
    _, int8_acc, _ = evaluate(model_int8, test_loader, criterion, device="cpu")
    ok = int8_acc >= int8_min
    marker = "OK  " if ok else "FAIL"
    print(f"  [{marker}] INT8 acc = {int8_acc:.2f}%   (threshold >= {int8_min}%)")
    fails += 0 if ok else 1

    # ----- 3. FP32 vs INT8 drop -----
    drop = fp32_acc - int8_acc
    ok = drop <= drop_max
    marker = "OK  " if ok else "FAIL"
    print(f"  [{marker}] FP32 - INT8 drop = {drop:.2f}%   (max allowed {drop_max}%)")
    fails += 0 if ok else 1

    # ----- 4. Compression ratio (sanity, doesn't fail test) -----
    if fp32_p.exists() and int8_p.exists():
        sz_fp32 = fp32_p.stat().st_size / 1e6
        sz_int8 = int8_p.stat().st_size / 1e6
        ratio = sz_fp32 / sz_int8
        print(f"\n  [INFO] Size: FP32 {sz_fp32:.2f}MB / INT8 {sz_int8:.2f}MB  -> {ratio:.2f}x compression")
        if ratio < 3.5:
            print(f"  [WARN] expected ~4x compression; got {ratio:.2f}x")

    print()
    print("PASS  test_lab1_accuracy" if fails == 0 else f"FAIL  test_lab1_accuracy ({fails} fail)")
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--fp32",       default=CONFIG["fp32_path"])
    p.add_argument("--int8",       default=CONFIG["int8_path"])
    p.add_argument("--lab1-dir",   default=CONFIG["lab1_weights_dir"])
    p.add_argument("--data-root",  default=CONFIG["data_root"])
    p.add_argument("--batch-size", type=int, default=CONFIG["batch_size"])
    p.add_argument("--fp32-min",   type=float, default=CONFIG["fp32_min_acc"])
    p.add_argument("--int8-min",   type=float, default=CONFIG["int8_min_acc"])
    p.add_argument("--drop-max",   type=float, default=CONFIG["fp32_int8_drop_max"])
    p.add_argument("--quick",         action="store_true", help="eval only 1000 test samples")
    p.add_argument("--copy-weights",  action="store_true", help="copy weights from Lab 1 if missing")
    args = p.parse_args()
    sys.exit(main(
        args.fp32, args.int8, args.lab1_dir, args.data_root,
        args.batch_size, args.fp32_min, args.int8_min, args.drop_max,
        args.quick, args.copy_weights,
    ))
