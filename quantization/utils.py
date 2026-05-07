"""I/O and plotting helpers (lifted from Lab 1)."""

from __future__ import annotations

import copy
import os

import matplotlib.pyplot as plt
import seaborn as sns
import torch
import torch.ao.quantization as tq

DEFAULT_DEVICE = "cuda" if torch.cuda.is_available() else "cpu"


def preprocess_filename(filename: str, existed: str = "keep_both") -> str:
    if existed == "overwrite":
        return filename
    if existed == "keep_both":
        base, ext = os.path.splitext(filename)
        cnt = 1
        while os.path.exists(filename):
            filename = f"{base}-{cnt}{ext}"
            cnt += 1
        return filename
    if existed == "raise" and os.path.exists(filename):
        raise FileExistsError(f"{filename} already exists.")
    return filename


def save_model(model, filename: str, verbose: bool = True, existed: str = "keep_both") -> None:
    filename = preprocess_filename(filename, existed)
    os.makedirs(os.path.dirname(filename) or ".", exist_ok=True)
    torch.save(model.state_dict(), filename)
    if verbose:
        size_mb = os.path.getsize(filename) / 1e6
        print(f"Model saved at {filename} ({size_mb:.2f} MB)")


def load_model(model, filename: str, qconfig=None, fuse: bool = False, verbose: bool = True):
    """Load FP32 or INT8 weights into `model`.

    If `qconfig` is provided, the model is fused, prepared, and converted to INT8
    before loading the state dict (matches the Lab 1 reload-INT8 path).
    """
    if fuse and hasattr(model, "fuse_model"):
        model.to("cpu").eval()
        model.fuse_model()

    if qconfig is not None:
        model.qconfig = qconfig
        model2 = copy.deepcopy(model)
        model_prepared = tq.prepare(model2)
        model_int8 = tq.convert(model_prepared)
        model_int8.load_state_dict(torch.load(filename, map_location="cpu", weights_only=False))
        model_int8.eval()
        if verbose:
            print(f"INT8 model loaded from {filename} ({os.path.getsize(filename) / 1e6:.2f} MB)")
        return model_int8

    device = DEFAULT_DEVICE
    model.load_state_dict(torch.load(filename, map_location=device, weights_only=False))
    if verbose:
        print(f"Model loaded from {filename} ({os.path.getsize(filename) / 1e6:.2f} MB)")
    return model


def plot_loss_accuracy(train_loss, train_acc, val_loss, val_acc, filename: str = "loss_accuracy.png") -> None:
    fig, (ax1, ax2) = plt.subplots(1, 2)
    ax1.plot(train_loss, color="tab:blue")
    ax1.plot(val_loss, color="tab:red")
    ax1.legend(["Training", "Validation"])
    ax1.set_xlabel("Epoch"); ax1.set_ylabel("Loss"); ax1.set_title("Loss")
    ax2.plot(train_acc, color="tab:blue")
    ax2.plot(val_acc, color="tab:red")
    ax2.legend(["Training", "Validation"])
    ax2.set_xlabel("Epoch"); ax2.set_ylabel("Accuracy"); ax2.set_title("Accuracy")
    fig.tight_layout()
    filename = preprocess_filename(filename)
    os.makedirs(os.path.dirname(filename) or ".", exist_ok=True)
    plt.savefig(filename)
    print(f"Plot saved at {filename}")


CIFAR10_CLASSES = ("airplane", "automobile", "bird", "cat", "deer",
                   "dog", "frog", "horse", "ship", "truck")


def plot_confusion_matrix(conf_matrix, filename: str = "confusion_matrix.png") -> None:
    plt.figure(figsize=(10, 8))
    sns.heatmap(
        conf_matrix, annot=True, fmt="d", cmap="Blues",
        xticklabels=CIFAR10_CLASSES, yticklabels=CIFAR10_CLASSES,
    )
    plt.xlabel("Predicted"); plt.ylabel("True")
    plt.title("Confusion Matrix for CIFAR-10")
    plt.tight_layout()
    filename = preprocess_filename(filename)
    os.makedirs(os.path.dirname(filename) or ".", exist_ok=True)
    plt.savefig(filename)
    print(f"Confusion matrix saved at {filename}")
