"""Training loop and evaluation for VGG-8."""

from __future__ import annotations

from typing import Tuple

import numpy as np
import torch
import torch.nn as nn
import torch.optim as optim
from sklearn.metrics import confusion_matrix
from tqdm import tqdm

from .utils import DEFAULT_DEVICE, plot_loss_accuracy, save_model


def evaluate(model, dataloader, criterion, device: str = DEFAULT_DEVICE) -> Tuple[float, float, np.ndarray]:
    running_loss = 0.0
    total, correct = 0, 0
    all_preds, all_labels = [], []

    model.eval()
    with torch.no_grad():
        for images, labels in tqdm(dataloader, desc="Evaluating", leave=True):
            images, labels = images.to(device), labels.to(device)
            output = model(images)
            running_loss += criterion(output, labels).item()
            predicted = torch.argmax(output, 1)
            total += labels.size(0)
            correct += (predicted == labels).sum().item()
            all_preds.extend(predicted.cpu().numpy())
            all_labels.extend(labels.cpu().numpy())

    return (
        running_loss / len(dataloader),
        correct / total * 100,
        confusion_matrix(np.array(all_labels), np.array(all_preds)),
    )


def train_model(
    model,
    train_loader,
    val_loader,
    epochs: int = 200,
    lr: float = 0.01,
    device: str = DEFAULT_DEVICE,
    save_path: str = "./quantization/weights/best_vgg_cifar10.pth",
    plot_path: str = "./quantization/results/loss_accuracy.png",
):
    """SGD + cosine annealing trainer; saves best-val checkpoint."""
    criterion = nn.CrossEntropyLoss()
    optimizer = optim.SGD(model.parameters(), lr=lr, momentum=0.9, weight_decay=5e-4)
    scheduler = optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=epochs)

    best_val_acc = 0.0
    train_loss_h, train_acc_h, val_loss_h, val_acc_h = [], [], [], []

    for epoch in range(epochs):
        model.train()
        running_loss, correct, total = 0.0, 0, 0
        pbar = tqdm(train_loader, desc=f"Epoch {epoch + 1}/{epochs}")
        for images, labels in pbar:
            images, labels = images.to(device), labels.to(device)
            optimizer.zero_grad()
            outputs = model(images)
            loss = criterion(outputs, labels)
            loss.backward()
            optimizer.step()

            running_loss += loss.item() * images.size(0)
            _, predicted = outputs.max(1)
            total += labels.size(0)
            correct += predicted.eq(labels).sum().item()
            pbar.set_postfix({"loss": running_loss / total})

        epoch_train_loss = running_loss / total
        epoch_train_acc = correct / total

        val_loss, val_acc, _ = evaluate(model, val_loader, criterion, device)

        train_loss_h.append(epoch_train_loss)
        train_acc_h.append(epoch_train_acc)
        val_loss_h.append(val_loss)
        val_acc_h.append(val_acc / 100.0)

        print(
            f"Epoch {epoch + 1} | Train Loss: {epoch_train_loss:.4f} | "
            f"Train Acc: {epoch_train_acc * 100:.2f}% | "
            f"Val Loss: {val_loss:.4f} | Val Acc: {val_acc:.2f}%"
        )

        if val_acc > best_val_acc:
            best_val_acc = val_acc
            save_model(model, save_path, existed="overwrite")

        scheduler.step()

    plot_loss_accuracy(train_loss_h, train_acc_h, val_loss_h, val_acc_h, filename=plot_path)
    return model
