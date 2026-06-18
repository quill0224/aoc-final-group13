from __future__ import annotations

from heapq import nsmallest
from itertools import product

from analytical_model.TrIP import (
    AnalysisResult,
    TrIPAnalyzer,
    TrIPHardwareParam,
    TrIPTilingParam,
)
from layer_info import Conv2DShapeParam, MaxPool2DShapeParam

# Estimated VGG16 activation densities for the 13 convolution layers.
# Replace these numbers with calibration-set measurements when available.
VGG16_ACT_DENSITIES = [
    0.60,
    0.55,
    0.50,
    0.45,
    0.40,
    0.35,
    0.30,
    0.25,
    0.25,
    0.20,
    0.20,
    0.15,
    0.10,
]


def _unique_sorted(values: list[int]) -> list[int]:
    return sorted(v for v in set(values) if v > 0)


class TrIPMapper:
    cnt = 0

    def __init__(
        self,
        name: str | None = None,
        layer_idx: int = 0,
        filter_density: float = 1.0,
        act_density: float | None = None,
    ) -> None:
        self.name = name if name is not None else f"mapping_trip_{TrIPMapper.cnt}"
        self.layer_idx = layer_idx

        if act_density is None:
            act_density = VGG16_ACT_DENSITIES[layer_idx] if layer_idx < len(VGG16_ACT_DENSITIES) else 1.0

        dummy_conv = Conv2DShapeParam(N=1, H=1, W=1, R=1, S=1, E=1, F=1, C=1, M=1)
        dummy_hw = TrIPHardwareParam(
            pe_array_h=16,
            pe_array_w=16,
            glb_size=16 * 1024,
            bus_bw=4,
            noc_bw=16,
        )
        dummy_tile = TrIPTilingParam(tile_m=16, tile_n=1, tile_k=16)

        self.analyzer = TrIPAnalyzer(
            layer_name=self.name,
            conv_shape=dummy_conv,
            hardware=dummy_hw,
            tile=dummy_tile,
            act_density=act_density,
            filter_density=filter_density,
        )
        TrIPMapper.cnt += 1

    def run(
        self,
        conv2d: Conv2DShapeParam,
        maxpool: MaxPool2DShapeParam | None = None,
        num_solutions: int = 1,
        mode: str | None = "dense",
    ) -> list[AnalysisResult]:
        self.analyzer.conv_shape = conv2d
        self.analyzer.maxpool_shape = maxpool
        self.analyzer.mode = self.mode = mode

        results: list[AnalysisResult] = []
        for hardware in self.generate_hardware():
            self.analyzer.hardware = hardware
            for tile in self.generate_mappings():
                self.analyzer.tiling = tile
                res = self.analyzer.summary
                res.update(
                    {
                        "tile_m": tile.tile_m,
                        "tile_n": tile.tile_n,
                        "tile_k": tile.tile_k,
                        "pe_array_h": hardware.pe_array_h,
                        "pe_array_w": hardware.pe_array_w,
                        "glb_size": hardware.glb_size,
                        "bus_bw": hardware.bus_bw,
                        "noc_bw": hardware.noc_bw,
                    }
                )
                results.append(res)

        if num_solutions > 0 and results:
            results = nsmallest(num_solutions, results, key=self.evaluate)
        return results

    def evaluate(self, metrics: AnalysisResult) -> float:
        mode = getattr(self, "mode", "dense")
        if mode == "dense":
            return float(metrics.get("total_cycles_trip", metrics.get("total_cycles", 0)))

        # For DSE modes, use EDP with small penalties to avoid metadata-heavy
        # mappings that look good only because the latency model is optimistic.
        latency = float(metrics.get("latency", metrics.get("total_cycles_trip", 1)))
        energy = float(metrics.get("energy_total", 1))
        metadata_ratio = float(metrics.get("metadata_overhead_ratio_per_tile", 0))
        utilization = max(1e-6, float(metrics.get("trip_utilization", 1)))
        return energy * latency * (1.0 + metadata_ratio) / utilization

    @property
    def hardware(self) -> TrIPHardwareParam:
        return self.analyzer.hardware

    @hardware.setter
    def hardware(self, hardware_param: TrIPHardwareParam) -> None:
        assert isinstance(hardware_param, TrIPHardwareParam)
        self.analyzer.hardware = hardware_param

    def tile_m_available(self) -> list[int]:
        return [self.hardware.pe_array_h]

    def tile_n_available(self) -> list[int]:
        max_n = self.analyzer.n_gemm
        return [n for n in range(1, min(4, max_n) + 1)]

    def tile_k_available(self) -> list[int]:
        return [self.hardware.pe_array_w]

    def validate(self, tile: TrIPTilingParam) -> bool:
        self.analyzer.tiling = tile
        return self.hardware.glb_size >= self.analyzer.min_glb_size

    def generate_mappings(self) -> list[TrIPTilingParam]:
        candidate_solutions: list[TrIPTilingParam] = []
        raw_combinations = product(
            self.tile_m_available(),
            self.tile_n_available(),
            self.tile_k_available(),
        )

        for sol in raw_combinations:
            tile = TrIPTilingParam(*sol)
            if self.validate(tile):
                candidate_solutions.append(tile)

        return candidate_solutions

    def generate_hardware(self) -> list[TrIPHardwareParam]:
        pe_array_h_list = [16]
        pe_array_w_list = [16]
        glb_size_list = [32 * 1024, 48 * 1024, 64 * 1024]
        bus_bw_list = [8,16]
        noc_bw_list = [64,128]

        candidate_solutions = product(
            pe_array_h_list,
            pe_array_w_list,
            glb_size_list,
            bus_bw_list,
            noc_bw_list,
        )
        return [TrIPHardwareParam(*hw) for hw in candidate_solutions]
