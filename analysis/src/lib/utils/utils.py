import os
from collections import OrderedDict
from collections.abc import Mapping

import matplotlib.pyplot as plt
import numpy as np
import torch
import torch.ao.quantization as tq

from tqdm import tqdm

DEFAULT_DEVICE = "cuda" if torch.cuda.is_available() else "cpu"


def evaluate(model, loader, criterion, device=DEFAULT_DEVICE):
    running_loss = 0
    total, correct = 0, 0
    all_preds, all_labels = [], []

    model.eval()
    with torch.no_grad():
        loop = tqdm(loader, desc="Evaluating", leave=True)

        for images, labels in loop:
            images, labels = images.to(device), labels.to(device)
            output = model(images)
            loss = criterion(output, labels)

            running_loss += loss.item()
            predicted = torch.argmax(output, 1)
            total += labels.size(0)
            correct += (predicted == labels).sum().item()

            all_preds.extend(predicted.cpu().numpy())
            all_labels.extend(labels.cpu().numpy())

        loop.set_postfix(
            loss=running_loss / (total / images.shape[0]), accuracy=correct / total
        )

    avg_loss = running_loss / len(loader)
    accuracy = correct / total
    all_preds = np.array(all_preds)
    all_labels = np.array(all_labels)
    return avg_loss, accuracy


def preprocess_filename(filename: str, existed: str = "keep_both") -> str:
    if existed == "overwrite":
        pass
    elif existed == "keep_both":
        base, ext = os.path.splitext(filename)
        cnt = 1
        while os.path.exists(filename):
            filename = f"{base}-{cnt}{ext}"
            cnt += 1
    elif existed == "raise" and os.path.exists(filename):
        raise FileExistsError(f"{filename} already exists.")
    else:
        raise ValueError(f"Unknown value for 'existed': {existed}")
    return filename


def plot_loss_accuracy(
    train_loss, train_acc, val_loss, val_acc, filename="loss_accuracy.png"
):
    fig, (ax1, ax2) = plt.subplots(1, 2)

    ax1.set_xlabel("Epoch")
    ax1.set_ylabel("Loss")
    ax1.plot(train_loss, color="tab:blue")
    ax1.plot(val_loss, color="tab:red")
    ax1.legend(["Training", "Validation"])
    ax1.set_title("Loss")

    ax2.set_xlabel("Epoch")
    ax2.set_ylabel("Accuracy")
    ax2.plot(train_acc, color="tab:blue")
    ax2.plot(val_acc, color="tab:red")
    ax2.legend(["Training", "Validation"])
    ax2.set_title("Accuracy")

    fig.tight_layout()
    filename = preprocess_filename(filename)
    os.makedirs(os.path.dirname(filename), exist_ok=True)
    plt.savefig(filename)
    print(f"Plot saved at {filename}")


def save_model(
    model, filename: str, verbose: bool = True, existed: str = "keep_both"
) -> None:
    filename = preprocess_filename(filename, existed)

    os.makedirs(os.path.dirname(filename), exist_ok=True)
    torch.save(model.state_dict(), filename)
    if verbose:
        print(f"Model saved at {filename} ({os.path.getsize(filename) / 1e6} MB)")
    else:
        print(f"Model saved at {filename}")


def is_float_model(model: torch.nn.Module) -> bool:
    """Return True when a model has no quantized modules."""
    for module in model.modules():
        module_name = module.__class__.__module__
        if ".quantized" in module_name:
            return False
    return True


def sanitize_state_dict_for_float_model(state_dict):
    """Dequantize quantized tensors so they can load into float modules."""
    sanitized = {}
    dequantized = False
    for key, value in state_dict.items():
        if torch.is_tensor(value) and value.is_quantized:
            sanitized[key] = value.dequantize()
            dequantized = True
        else:
            sanitized[key] = value
    if dequantized:
        print("Quantized checkpoint tensors were dequantized for analytical profiling.")
    return sanitized


def _looks_like_state_dict(value) -> bool:
    if not isinstance(value, Mapping):
        return False
    return any(torch.is_tensor(item) or isinstance(item, (tuple, list)) for item in value.values())


def extract_state_dict(ckpt):
    """Return the state_dict from a checkpoint, unwrapping common containers."""
    if not isinstance(ckpt, Mapping):
        raise TypeError(f"Expected checkpoint mapping, got {type(ckpt).__name__}")

    for key in ("state_dict", "model_state_dict", "model", "net", "module"):
        value = ckpt.get(key)
        if _looks_like_state_dict(value):
            return value, key

    if _looks_like_state_dict(ckpt):
        return ckpt, None

    raise ValueError("Could not find a state_dict in checkpoint.")


def strip_or_add_module_prefix(state_dict, model_state_dict):
    """Align a checkpoint state_dict with the model's module. prefix convention."""
    ckpt_keys = list(state_dict.keys())
    model_keys = list(model_state_dict.keys())
    ckpt_has_module = any(key.startswith("module.") for key in ckpt_keys)
    model_has_module = any(key.startswith("module.") for key in model_keys)

    if ckpt_has_module and not model_has_module:
        return OrderedDict(
            (key.removeprefix("module."), value) for key, value in state_dict.items()
        ), "stripped"

    if model_has_module and not ckpt_has_module:
        return OrderedDict((f"module.{key}", value) for key, value in state_dict.items()), "added"

    return state_dict, "unchanged"


def infer_checkpoint_format(state_dict) -> str:
    """Classify checkpoint weights as quantized, float_or_fused, or unknown."""
    keys = [str(key) for key in state_dict.keys()]
    has_quant_keys = any(
        "_packed_params" in key
        or key.endswith(".scale")
        or key.endswith(".zero_point")
        or key in {"scale", "zero_point"}
        for key in keys
    )
    has_quant_tensors = any(
        torch.is_tensor(value) and value.is_quantized for value in state_dict.values()
    )
    if has_quant_keys or has_quant_tensors:
        return "quantized"

    has_conv_weights = any(
        key.endswith(".weight")
        and torch.is_tensor(state_dict[key])
        and state_dict[key].dim() == 4
        for key in state_dict.keys()
    )
    if has_conv_weights:
        return "float_or_fused"

    return "unknown"


def count_conv_weight_tensors(state_dict) -> int:
    return sum(
        str(key).endswith(".weight")
        and torch.is_tensor(value)
        and value.dim() == 4
        for key, value in state_dict.items()
    )


def _first_feature_module_type(model) -> str:
    features = getattr(model, "features", None)
    if features is None or len(features) == 0:
        return "unavailable"
    return type(features[0]).__name__


def _prepare_quantized_model(model, qconfig, fuse_modules: bool) -> torch.nn.Module:
    model.eval()
    if fuse_modules and hasattr(model, "fuse_modules"):
        model.fuse_modules()
    elif fuse_modules:
        print("Model does not have 'fuse_modules' method. Skipping fusion.")

    model.qconfig = qconfig
    tq.prepare(model, inplace=True)
    tq.convert(model, inplace=True)
    return model


def load_model(
    model, filename: str, qconfig=None, fuse_modules: bool = False, verbose: bool = True
) -> torch.nn.Module:
    device = DEFAULT_DEVICE if qconfig is None else "cpu"
    ckpt = torch.load(filename, map_location=device)
    state_dict, wrapper_key = extract_state_dict(ckpt)
    checkpoint_format = infer_checkpoint_format(state_dict)
    conv_weight_count = count_conv_weight_tensors(state_dict)

    if verbose:
        wrapper_msg = wrapper_key if wrapper_key is not None else "none"
        print(f"[INFO] Checkpoint wrapper: {wrapper_msg}")
        print(f"[INFO] Checkpoint format: {checkpoint_format}")
        print(f"[INFO] Checkpoint conv weight tensors: {conv_weight_count}")
        print(f"[INFO] features.0 before load: {_first_feature_module_type(model)}")

    if qconfig is not None and checkpoint_format == "quantized":
        model = _prepare_quantized_model(model, qconfig, fuse_modules)
        state_dict, prefix_action = strip_or_add_module_prefix(state_dict, model.state_dict())
        if verbose:
            print(f"[INFO] module. prefix adjustment: {prefix_action}")
            print(f"[INFO] features.0 load target: {_first_feature_module_type(model)}")
        model.load_state_dict(state_dict)
    elif qconfig is None and checkpoint_format == "quantized":
        model = _prepare_quantized_model(model, tq.get_default_qconfig(torch.backends.quantized.engine), fuse_modules)
        state_dict, prefix_action = strip_or_add_module_prefix(state_dict, model.state_dict())
        if verbose:
            print(f"[INFO] module. prefix adjustment: {prefix_action}")
            print("[INFO] Built quantized parse model for quantized checkpoint with backend none.")
        model.load_state_dict(state_dict)
    else:
        state_dict, prefix_action = strip_or_add_module_prefix(state_dict, model.state_dict())
        if verbose:
            print(f"[INFO] module. prefix adjustment: {prefix_action}")

        if is_float_model(model):
            state_dict = sanitize_state_dict_for_float_model(state_dict)
        model.load_state_dict(state_dict)

        if qconfig is not None:
            try:
                model = _prepare_quantized_model(model, qconfig, fuse_modules)
                if verbose:
                    print("[INFO] Float checkpoint loaded before quantization convert.")
            except Exception as exc:
                print(
                    "[WARN] Quantization convert failed after loading float checkpoint; "
                    f"continuing with float model for analytical parsing. Reason: {exc}"
                )

    if verbose:
        print(f"Model loaded from {filename} ({os.path.getsize(filename) / 1e6} MB)")
    return model


def reset_seed(seed: int = 42):
    torch.manual_seed(seed)
    np.random.seed(seed)
    torch.backends.cudnn.deterministic = True
    torch.backends.cudnn.benchmark = False
