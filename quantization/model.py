"""VGG-8 model definition with PTQ support.

Architecture (matches Lab 1):
    5 conv blocks (Conv-BN-ReLU) + 3 maxpools  ->  3 FC layers
    Total params: 3,336,906 (~12.7 MB FP32)
    Input: 3x32x32 CIFAR-10
"""

from __future__ import annotations

import torch
import torch.ao.quantization as tq
import torch.nn as nn


class VGG(nn.Module):
    """VGG-8 with QuantStub/DeQuantStub for post-training quantization."""

    def __init__(self, in_channels: int = 3, in_size: int = 32, num_classes: int = 10) -> None:
        super().__init__()

        self.quant = tq.QuantStub()
        self.dequant = tq.DeQuantStub()

        self.features = nn.Sequential(
            # Conv1: 3 -> 64, 32x32
            nn.Conv2d(in_channels, 64, kernel_size=3, stride=1, padding=1),
            nn.BatchNorm2d(64),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(kernel_size=2, stride=2),  # 16x16
            # Conv2: 64 -> 192, 16x16
            nn.Conv2d(64, 192, kernel_size=3, stride=1, padding=1),
            nn.BatchNorm2d(192),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(kernel_size=2, stride=2),  # 8x8
            # Conv3: 192 -> 384, 8x8
            nn.Conv2d(192, 384, kernel_size=3, stride=1, padding=1),
            nn.BatchNorm2d(384),
            nn.ReLU(inplace=True),
            # Conv4: 384 -> 256, 8x8
            nn.Conv2d(384, 256, kernel_size=3, stride=1, padding=1),
            nn.BatchNorm2d(256),
            nn.ReLU(inplace=True),
            # Conv5: 256 -> 256, 8x8
            nn.Conv2d(256, 256, kernel_size=3, stride=1, padding=1),
            nn.BatchNorm2d(256),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(kernel_size=2, stride=2),  # 4x4
        )

        self.classifier = nn.Sequential(
            nn.Linear(256 * 4 * 4, 256),  # FC6
            nn.ReLU(inplace=True),
            nn.Linear(256, 128),  # FC7
            nn.ReLU(inplace=True),
            nn.Linear(128, num_classes),  # FC8
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.quant(x)
        x = self.features(x)
        x = torch.flatten(x, 1)
        x = self.classifier(x)
        x = self.dequant(x)
        return x

    def fuse_model(self) -> None:
        # Conv-BN-ReLU fusion is required before PTQ to prevent
        # intermediate quantization truncation across BN folding.
        tq.fuse_modules(self.features, ["0", "1", "2"], inplace=True)
        tq.fuse_modules(self.features, ["4", "5", "6"], inplace=True)
        tq.fuse_modules(self.features, ["8", "9", "10"], inplace=True)
        tq.fuse_modules(self.features, ["11", "12", "13"], inplace=True)
        tq.fuse_modules(self.features, ["14", "15", "16"], inplace=True)
        tq.fuse_modules(self.classifier, ["0", "1"], inplace=True)
        tq.fuse_modules(self.classifier, ["2", "3"], inplace=True)
