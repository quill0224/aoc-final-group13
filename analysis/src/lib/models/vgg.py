import torch
import torch.nn as nn
import torch.ao.quantization as tq
from typing import Optional

NUM_CLASSES = 100


class VGG8(nn.Module):
    def __init__(self, in_channels=3, in_size=32, num_classes=10) -> None:
        super().__init__()
        self.arch = "vgg8"
        self.fmap_size = in_size
        self.conv1 = self.make_conv_layer(in_channels, 64, max_pool=True)
        self.conv2 = self.make_conv_layer(64, 192, max_pool=True)
        self.conv3 = self.make_conv_layer(192, 384, max_pool=False)
        self.conv4 = self.make_conv_layer(384, 256, max_pool=False)
        self.conv5 = self.make_conv_layer(256, 256, max_pool=True)

        self.fc6 = nn.Sequential(
            nn.Linear(256 * self.fmap_size**2, 256),
            nn.ReLU(inplace=True),
            nn.Dropout(p=0.5),
        )
        self.fc7 = nn.Sequential(
            nn.Linear(256, 128),
            nn.ReLU(inplace=True),
            nn.Dropout(p=0.5),
        )
        self.fc8 = nn.Linear(128, num_classes)

        self._initialize_weights()

    def make_conv_layer(
        self,
        in_channels: int,
        out_channels: int,
        kernel_size: int = 3,
        max_pool: bool = False,
    ) -> nn.Sequential:
        layers = [
            nn.Conv2d(in_channels, out_channels, kernel_size, padding=1),
            nn.BatchNorm2d(out_channels),
            nn.ReLU(inplace=True),
        ]
        if max_pool:
            self.fmap_size //= 2
            layers.append(nn.MaxPool2d(kernel_size=2, stride=2))
        return nn.Sequential(*layers)

    def _initialize_weights(self) -> None:
        print("Initializing weights")
        for m in self.modules():
            if isinstance(m, nn.Conv2d) or isinstance(m, nn.Linear):
                nn.init.kaiming_normal_(m.weight, mode="fan_in", nonlinearity="relu")
                if m.bias is not None:
                    nn.init.constant_(m.bias, 0)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.conv1(x)
        x = self.conv2(x)
        x = self.conv3(x)
        x = self.conv4(x)
        x = self.conv5(x)
        x = torch.flatten(x, start_dim=1)
        x = self.fc6(x)
        x = self.fc7(x)
        x = self.fc8(x)
        return x

    def fuse_modules(self):
        tq.fuse_modules(
            self.eval(),
            [
                *[[f"conv{i}.0", f"conv{i}.1", f"conv{i}.2"] for i in range(1, 6)],
                *[[f"fc{i}.0", f"fc{i}.1"] for i in range(6, 8)],
            ],
            inplace=True,
        )


class VGG16BN(nn.Module):
    """VGG-16-BN for 224x224 ImageNet-100 with eager-mode quantization stubs."""

    def __init__(self, in_channels: int = 3, num_classes: int = NUM_CLASSES) -> None:
        super().__init__()
        self.arch = "vgg16"
        self.quant = tq.QuantStub()
        self.dequant = tq.DeQuantStub()

        self.features = nn.Sequential(
            nn.Conv2d(in_channels, 64, kernel_size=3, padding=1, bias=False),
            nn.BatchNorm2d(64),
            nn.ReLU(inplace=True),
            nn.Conv2d(64, 64, kernel_size=3, padding=1, bias=False),
            nn.BatchNorm2d(64),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(kernel_size=2, stride=2),
            nn.Conv2d(64, 128, kernel_size=3, padding=1, bias=False),
            nn.BatchNorm2d(128),
            nn.ReLU(inplace=True),
            nn.Conv2d(128, 128, kernel_size=3, padding=1, bias=False),
            nn.BatchNorm2d(128),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(kernel_size=2, stride=2),
            nn.Conv2d(128, 256, kernel_size=3, padding=1, bias=False),
            nn.BatchNorm2d(256),
            nn.ReLU(inplace=True),
            nn.Conv2d(256, 256, kernel_size=3, padding=1, bias=False),
            nn.BatchNorm2d(256),
            nn.ReLU(inplace=True),
            nn.Conv2d(256, 256, kernel_size=3, padding=1, bias=False),
            nn.BatchNorm2d(256),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(kernel_size=2, stride=2),
            nn.Conv2d(256, 512, kernel_size=3, padding=1, bias=False),
            nn.BatchNorm2d(512),
            nn.ReLU(inplace=True),
            nn.Conv2d(512, 512, kernel_size=3, padding=1, bias=False),
            nn.BatchNorm2d(512),
            nn.ReLU(inplace=True),
            nn.Conv2d(512, 512, kernel_size=3, padding=1, bias=False),
            nn.BatchNorm2d(512),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(kernel_size=2, stride=2),
            nn.Conv2d(512, 512, kernel_size=3, padding=1, bias=False),
            nn.BatchNorm2d(512),
            nn.ReLU(inplace=True),
            nn.Conv2d(512, 512, kernel_size=3, padding=1, bias=False),
            nn.BatchNorm2d(512),
            nn.ReLU(inplace=True),
            nn.Conv2d(512, 512, kernel_size=3, padding=1, bias=False),
            nn.BatchNorm2d(512),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(kernel_size=2, stride=2),
        )
        self.avgpool = nn.AdaptiveAvgPool2d((1, 1))
        self.classifier = nn.Linear(512, num_classes)
        self._initialize_weights()

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.quant(x)
        x = self.features(x)
        x = self.avgpool(x)
        x = torch.flatten(x, 1)
        x = self.classifier(x)
        x = self.dequant(x)
        return x

    def fuse_model(self) -> None:
        """Fuse Conv-BN-ReLU modules before static quantization."""
        for idx in range(len(self.features) - 2):
            if (
                isinstance(self.features[idx], nn.Conv2d)
                and isinstance(self.features[idx + 1], nn.BatchNorm2d)
                and isinstance(self.features[idx + 2], nn.ReLU)
            ):
                tq.fuse_modules(
                    self.features,
                    [str(idx), str(idx + 1), str(idx + 2)],
                    inplace=True,
                )

    def fuse_modules(self) -> None:
        self.fuse_model()

    def _initialize_weights(self) -> None:
        for module in self.modules():
            if isinstance(module, nn.Conv2d):
                nn.init.kaiming_normal_(module.weight, mode="fan_out", nonlinearity="relu")
                if module.bias is not None:
                    nn.init.zeros_(module.bias)
            elif isinstance(module, nn.BatchNorm2d):
                nn.init.ones_(module.weight)
                nn.init.zeros_(module.bias)
            elif isinstance(module, nn.Linear):
                nn.init.normal_(module.weight, 0, 0.01)
                nn.init.zeros_(module.bias)


def VGG(
    arch: str = "vgg8",
    num_classes: Optional[int] = None,
    in_channels: int = 3,
    in_size: Optional[int] = None,
) -> nn.Module:
    """Build a VGG model while preserving the historical VGG() default."""
    arch = arch.lower()
    if arch == "vgg8":
        return VGG8(
            in_channels=in_channels,
            in_size=32 if in_size is None else in_size,
            num_classes=10 if num_classes is None else num_classes,
        )
    if arch == "vgg16":
        return VGG16BN(
            in_channels=in_channels,
            num_classes=NUM_CLASSES if num_classes is None else num_classes,
        )
    raise ValueError(f"Unsupported VGG architecture: {arch}")


if __name__ == "__main__":
    model = VGG()
    inputs = torch.randn(1, 3, 32, 32)
    print(model)
    model.fuse_modules()
    print(model)
