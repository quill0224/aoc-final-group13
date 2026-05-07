"""Per-layer shape descriptors.

Notation follows the Eyeriss paper:
    N batch, H/W ifmap H/W, R/S filter H/W, E/F ofmap H/W, C in-ch, M out-ch.
"""

from __future__ import annotations

from abc import ABC
from dataclasses import asdict, dataclass


class ShapeParam(ABC):
    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, data: dict):
        return cls(**data)


@dataclass(frozen=True)
class Conv2DShapeParam(ShapeParam):
    N: int  # batch size
    H: int  # input height
    W: int  # input width
    R: int  # filter height
    S: int  # filter width
    E: int  # output height
    F: int  # output width
    C: int  # input channels
    M: int  # output channels
    U: int = 1  # stride
    P: int = 1  # padding


@dataclass(frozen=True)
class LinearShapeParam(ShapeParam):
    N: int
    in_features: int
    out_features: int


@dataclass(frozen=True)
class MaxPool2DShapeParam(ShapeParam):
    N: int
    kernel_size: int
    stride: int
