from __future__ import annotations

from heapq import nsmallest
from itertools import product
from typing import Optional

from analytical_model.StandardIP import (
    StandardIPHardwareParam,
    StandardIPTilingParam,
    StandardIPAnalyzer,
    AnalysisResult,
)
from layer_info import Conv2DShapeParam, MaxPool2DShapeParam

class StandardIPMapper:
    cnt = 0

    def __init__(
        self,
        name: str | None = None,
    ) -> None:
        self.name = name if name is not None else f"mapping_standard_ip_{StandardIPMapper.cnt}"
        
        # 初始化先塞入 Dummy 參數，等 run() 被呼叫時再抽換成真實的參數
        dummy_conv = Conv2DShapeParam(N=1, H=1, W=1, R=1, S=1, E=1, F=1, C=1, M=1)
        dummy_hw = StandardIPHardwareParam(pe_array_h=16, pe_array_w=16, glb_size=1024, bus_bw=4, noc_bw=4)
        dummy_tile = StandardIPTilingParam(tile_m=16, tile_n=1, tile_k=16)
        
        self.analyzer = StandardIPAnalyzer(
            layer_name=self.name,
            conv_shape=dummy_conv,
            hardware=dummy_hw,
            tile=dummy_tile
        )
        StandardIPMapper.cnt += 1

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
        results = []

        for hardware in self.generate_hardware():
            self.analyzer.hardware = hardware

            for tile in self.generate_mappings():
                self.analyzer.tiling = tile
                res = self.analyzer.summary
                
                res.update({
                    "tile_m": tile.tile_m,
                    "tile_n": tile.tile_n,
                    "tile_k": tile.tile_k,

                    "pe_array_h": hardware.pe_array_h,
                    "pe_array_w": hardware.pe_array_w,
                    "glb_size": hardware.glb_size,
                    "bus_bw": hardware.bus_bw,
                    "noc_bw": hardware.noc_bw,
                })

                results.append(res)

        if num_solutions > 0 and results:
            results = nsmallest(num_solutions, results, key=self.evaluate)
        return results

    def evaluate(self, metrics: AnalysisResult) -> float:
        score = 0
        # 依照模式選擇評估標準，Dense 看 Cycle，其他看 EDP (Energy-Delay Product)
        if getattr(self, "mode", None) == "dense":
            score = metrics["total_cycles_dense"]
        else:
            score = metrics["energy_total"] * metrics["latency"]
        return score

    @property
    def hardware(self) -> StandardIPHardwareParam:
        return self.analyzer.hardware

    @hardware.setter
    def hardware(self, hardware_param: StandardIPHardwareParam) -> None:
        assert isinstance(hardware_param, StandardIPHardwareParam)
        self.analyzer.hardware = hardware_param

    # ===== Tiling 搜尋空間產生器 =====
    # 以 PE Array 的長寬作為基本的 Tile 步長，增加硬體使用率 (Utilization)
    
    def tile_m_available(self) -> list[int]:
        return [self.hardware.pe_array_h]

    def tile_n_available(self) -> list[int]:
        return [1]

    def tile_k_available(self) -> list[int]:
        return [self.hardware.pe_array_w]

    def validate(self, tile: StandardIPTilingParam) -> bool:
        self.analyzer.tiling = tile
        return self.hardware.glb_size >= self.analyzer.min_glb_size

    def generate_mappings(self) -> list[StandardIPTilingParam]:
        candidate_solutions = []
        
        m_list = self.tile_m_available()
        n_list = self.tile_n_available()
        k_list = self.tile_k_available()

        # 展開所有 M, N, K 的排列組合
        raw_combinations = product(m_list, n_list, k_list)

        # 濾除會把 GLB 塞爆的非法解
        for sol in raw_combinations:
            tile = StandardIPTilingParam(*sol)
            if self.validate(tile):
                candidate_solutions.append(tile)
                
        return candidate_solutions

    def generate_hardware(self) -> list[StandardIPHardwareParam]:
        # 這裡設定你想要 Explore 的硬體參數空間，數值可以依照需求隨意微調喔！
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
        return [StandardIPHardwareParam(*hw) for hw in candidate_solutions]