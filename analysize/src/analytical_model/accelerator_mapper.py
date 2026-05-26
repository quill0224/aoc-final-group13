from __future__ import annotations

from itertools import product
from typing import Optional

from analytical_model.accelerator import (
    AcceleratorHardwareParam,
    AcceleratorTileParam,
    SparseDenseAcceleratorAnalyzer,
)
from analytical_model.sparsity_model import LayerSparsityProfile
from layer_info import Conv2DShapeParam


class SparseDenseAcceleratorMapper:
    def __init__(
        self,
        name: str = "sparse_dense",
        sparsity_profile: Optional[LayerSparsityProfile] = None,
        glb_sizes: Optional[list[int]] = None,
        tile_m_list: Optional[list[int]] = None,
        tile_n_list: Optional[list[int]] = None,
        tile_k_list: Optional[list[int]] = None,
        dram_bw_list: Optional[list[int]] = None,
        glb_bw_list: Optional[list[int]] = None,
        decode_bw: int = 16,
    ) -> None:
        self.name = name
        self.sparsity_profile = sparsity_profile
        self.glb_sizes = glb_sizes or [1 * 1024,2 * 1024, 4 * 1024, 8 * 1024 ]
        self.tile_m_list = tile_m_list or [16, 32, 64]
        self.tile_n_list = tile_n_list or [16, 32, 64]
        self.tile_k_list = tile_k_list or [32, 64, 128]
        self.dram_bw_list = dram_bw_list or [16]
        self.glb_bw_list = glb_bw_list or [64]
        self.decode_bw = decode_bw

    def run(
        self,
        conv2d: Conv2DShapeParam,
        mode: str = "dense",
        num_solutions: int = 0,
    ) -> list[dict]:
        results = []
        for hardware in self.generate_hardware():
            for tile in self.generate_tiles():
                analyzer = SparseDenseAcceleratorAnalyzer(
                    layer_name=self.name,
                    conv_shape=conv2d,
                    hardware=hardware,
                    tile=tile,
                    sparsity_profile=self.sparsity_profile,
                    analysis_mode=mode,
                )
                row = analyzer.summary
                row["analysis_mode"] = mode
                row["dram_bw"] = hardware.dram_bw
                row["glb_bw"] = hardware.glb_bw
                row["decode_bw"] = hardware.decode_bw
                row["pe_array_h"] = hardware.pe_array_h
                row["pe_array_w"] = hardware.pe_array_w
                results.append(row)

        if num_solutions > 0:
            key = "dense_total_cycles" if mode == "dense" else "sparse_total_cycles"
            legal_key = "dense_glb_legal" if mode == "dense" else "sparse_glb_legal"
            legal_results = [row for row in results if row[legal_key]]
            candidates = legal_results if legal_results else results
            return sorted(candidates, key=lambda row: row[key])[:num_solutions]
        return results

    def run_layer(
        self,
        layer_name: str,
        conv_shape: Conv2DShapeParam,
        sparsity_profile: Optional[LayerSparsityProfile],
        analysis_mode: str,
    ) -> list[dict]:
        rows = []
        for hardware in self.generate_hardware():
            for tile in self.generate_tiles():
                analyzer = SparseDenseAcceleratorAnalyzer(
                    layer_name=layer_name,
                    conv_shape=conv_shape,
                    hardware=hardware,
                    tile=tile,
                    sparsity_profile=sparsity_profile,
                    analysis_mode=analysis_mode,
                )
                row = analyzer.summary
                row["analysis_mode"] = analysis_mode
                row["dram_bw"] = hardware.dram_bw
                row["glb_bw"] = hardware.glb_bw
                row["decode_bw"] = hardware.decode_bw
                row["pe_array_h"] = hardware.pe_array_h
                row["pe_array_w"] = hardware.pe_array_w
                rows.append(row)
        return rows

    def run_network(
        self,
        layers: list[Conv2DShapeParam],
        sparsity_profiles: list[Optional[LayerSparsityProfile]],
        analysis_mode: str,
    ):
        rows = []
        for idx, conv in enumerate(layers):
            profile = sparsity_profiles[idx] if idx < len(sparsity_profiles) else None
            layer_name = (
                profile.layer_name
                if profile is not None
                else f"{self.name}.conv{idx}"
            )
            rows.extend(
                self.run_layer(
                    layer_name=layer_name,
                    conv_shape=conv,
                    sparsity_profile=profile,
                    analysis_mode=analysis_mode,
                )
            )

        try:
            import pandas as pd

            return pd.DataFrame(rows)
        except ImportError:
            return rows

    def generate_hardware(self) -> list[AcceleratorHardwareParam]:
        return [
            AcceleratorHardwareParam(
                glb_size=glb_size,
                dram_bw=dram_bw,
                glb_bw=glb_bw,
                decode_bw=self.decode_bw,
            )
            for glb_size, dram_bw, glb_bw in product(
                self.glb_sizes,
                self.dram_bw_list,
                self.glb_bw_list,
            )
        ]

    def generate_tiles(self) -> list[AcceleratorTileParam]:
        return [
            AcceleratorTileParam(tile_m=tile_m, tile_n=tile_n, tile_k=tile_k)
            for tile_m, tile_n, tile_k in product(
                self.tile_m_list,
                self.tile_n_list,
                self.tile_k_list,
            )
        ]
