"""Shared utilities for sweep scripts."""

from __future__ import annotations

from itertools import product
from typing import Iterable

from analysis.eyeriss import EyerissHardwareParam, EyerissMapper
from analysis.eyeriss.eyeriss import EyerissAnalyzer
from analysis.eyeriss.layer_info import Conv2DShapeParam, MaxPool2DShapeParam


class FixedHardwareMapper(EyerissMapper):
    """EyerissMapper that locks the hardware to a single configuration.

    Use this when you want to sweep mappings *given* a fixed hardware,
    instead of also DSE-ing over hardware (which is the default behavior).
    """

    def __init__(self, name: str, hardware: EyerissHardwareParam) -> None:
        super().__init__(name=name)
        self._fixed_hardware = hardware

    def generate_hardware(self) -> list[EyerissHardwareParam]:
        return [self._fixed_hardware]


def make_hardware(
    pe_h: int = 6,
    pe_w: int = 8,
    glb_kib: int = 64,
    bus_bw: int = 4,
    noc_bw: int = 4,
    ifmap_spad: int = 12,
    filter_spad: int = 48,
    psum_spad: int = 16,
) -> EyerissHardwareParam:
    """Convenience builder. Defaults match the AOC course baseline."""
    return EyerissHardwareParam(
        pe_array_h=pe_h,
        pe_array_w=pe_w,
        ifmap_spad_size=ifmap_spad,
        filter_spad_size=filter_spad,
        psum_spad_size=psum_spad,
        glb_size=glb_kib * 1024,
        bus_bw=bus_bw,
        noc_bw=noc_bw,
    )


def vgg8_conv_layers() -> list[tuple[Conv2DShapeParam, MaxPool2DShapeParam | None]]:
    """5 Conv2D layers of VGG-8 paired with their adjacent MaxPool (or None).

    Hard-coded so sweeps can run without loading a checkpoint.
    """
    pool22 = MaxPool2DShapeParam(N=1, kernel_size=2, stride=2)
    return [
        # conv1: 32x32 -> 32x32, then pool to 16x16
        (Conv2DShapeParam(N=1, H=32, W=32, R=3, S=3, E=32, F=32, C=3,   M=64,  U=1, P=1), pool22),
        # conv2: 16x16 -> 16x16, then pool to 8x8
        (Conv2DShapeParam(N=1, H=16, W=16, R=3, S=3, E=16, F=16, C=64,  M=192, U=1, P=1), pool22),
        # conv3: 8x8 -> 8x8 (no pool here)
        (Conv2DShapeParam(N=1, H=8,  W=8,  R=3, S=3, E=8,  F=8,  C=192, M=384, U=1, P=1), None),
        # conv4: 8x8 -> 8x8 (no pool)
        (Conv2DShapeParam(N=1, H=8,  W=8,  R=3, S=3, E=8,  F=8,  C=384, M=256, U=1, P=1), None),
        # conv5: 8x8 -> 8x8, then pool to 4x4
        (Conv2DShapeParam(N=1, H=8,  W=8,  R=3, S=3, E=8,  F=8,  C=256, M=256, U=1, P=1), pool22),
    ]


def best_for_each_layer(
    hardware: EyerissHardwareParam,
    layers: Iterable[tuple[Conv2DShapeParam, MaxPool2DShapeParam | None]] | None = None,
) -> list[dict]:
    """Return the best (lowest latency) mapping per layer for a fixed hardware."""
    if layers is None:
        layers = vgg8_conv_layers()

    out = []
    for i, (conv, pool) in enumerate(layers):
        mapper = FixedHardwareMapper(name=f"conv{i + 1}", hardware=hardware)
        results = mapper.run(conv, pool, num_solutions=1)
        if not results:
            out.append({"layer": f"conv{i + 1}", "infeasible": True})
        else:
            res = results[0]
            res["infeasible"] = False
            out.append(res)
    return out
