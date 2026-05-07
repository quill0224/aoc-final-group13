"""CIFAR-10 dataloaders for VGG-8 training and quantization."""

from __future__ import annotations

from typing import Callable, Tuple

import torch
from torch.utils.data import DataLoader
from torchvision import datasets, transforms


def _build_loaders(
    source: Callable,
    batch_size: int,
    transform,
    eval_transform=None,
    root: str = "data",
    split_ratio: float = 0.1,
    num_workers: int = 4,
) -> Tuple[DataLoader, DataLoader, DataLoader]:
    if eval_transform is None:
        eval_transform = transform

    trainset = source(root=root, train=True, download=True, transform=transform)
    testset = source(root=root, train=False, download=True, transform=eval_transform)

    val_len = int(split_ratio * len(trainset))
    train_len = len(trainset) - val_len
    trainset, valset = torch.utils.data.random_split(trainset, [train_len, val_len])

    kw = dict(batch_size=batch_size, num_workers=num_workers, pin_memory=True)
    return (
        DataLoader(trainset, shuffle=True, **kw),
        DataLoader(valset, shuffle=True, **kw),
        DataLoader(testset, shuffle=False, **kw),
    )


def get_cifar10_loaders(
    batch_size: int = 32,
    root: str = "data/cifar10",
    split_ratio: float = 0.1,
    num_workers: int = 4,
):
    """CIFAR-10 train/val/test loaders with standard augmentation."""
    train_transform = transforms.Compose(
        [
            transforms.RandomCrop(32, padding=4),
            transforms.RandomHorizontalFlip(),
            transforms.ToTensor(),
            transforms.Normalize((0.4914, 0.4822, 0.4465), (0.2023, 0.1994, 0.2010)),
        ]
    )
    eval_transform = transforms.Compose(
        [
            transforms.ToTensor(),
            transforms.Normalize((0.4914, 0.4822, 0.4465), (0.2023, 0.1994, 0.2010)),
        ]
    )
    return _build_loaders(
        datasets.CIFAR10,
        batch_size,
        train_transform,
        eval_transform=eval_transform,
        root=root,
        split_ratio=split_ratio,
        num_workers=num_workers,
    )
