from __future__ import annotations

from dataclasses import dataclass
from math import ceil
from typing import Optional

from analytical_model.sparsity_model import (
    LayerSparsityProfile,
    estimate_trip_utilization,
    recommend_mode,
)
from layer_info import Conv2DShapeParam


@dataclass(frozen=True)
class AcceleratorHardwareParam:
    pe_array_h: int = 16
    pe_array_w: int = 16
    int8_bytes: int = 1
    psum_bytes: int = 4
    mask_word_bits: int = 64
    mask_word_bytes: int = 8
    glb_size: int = 64 * 1024
    dram_bw: int = 16
    glb_bw: int = 64
    decode_bw: int = 16


@dataclass(frozen=True)
class AcceleratorTileParam:
    tile_m: int
    tile_n: int
    tile_k: int


class SparseDenseAcceleratorAnalyzer:
    """Standard-IP dense GEMM and TrIP-like sparse-weight analytical model.

    Conv2D is lowered as GEMM with:
      M_gemm = N * E * F  (activation/im2col rows)
      K_gemm = C * R * S  (reduction dimension)
      N_gemm = M          (output channels)
    The dense activation matrix is not materialized in DRAM in this first model;
    dense_ifmap_bytes counts the original activation tensor.
    """

    def __init__(
        self,
        layer_name: str,
        conv_shape: Conv2DShapeParam,
        hardware: AcceleratorHardwareParam,
        tile: AcceleratorTileParam,
        sparsity_profile: Optional[LayerSparsityProfile],
        analysis_mode: str = "dense",
        routing_penalty_ratio: float = 0.05,
        reduction_penalty_ratio: float = 0.03,
    ) -> None:
        self.layer_name = layer_name
        self.conv_shape = conv_shape
        self.hardware = hardware
        self.tile = tile
        self.sparsity_profile = sparsity_profile
        self.analysis_mode = analysis_mode
        self.routing_penalty_ratio = routing_penalty_ratio
        self.reduction_penalty_ratio = reduction_penalty_ratio

    @property
    def pe_count(self) -> int:
        return self.hardware.pe_array_h * self.hardware.pe_array_w

    @property
    def m_gemm(self) -> int:
        return self.conv_shape.N * self.conv_shape.E * self.conv_shape.F

    @property
    def k_gemm(self) -> int:
        return self.conv_shape.C * self.conv_shape.R * self.conv_shape.S

    @property
    def n_gemm(self) -> int:
        return self.conv_shape.M

    @property
    def total_weights(self) -> int:
        if self.sparsity_profile is not None:
            return self.sparsity_profile.total_weights
        return self.dense_weight_elements

    @property
    def nonzero_weights(self) -> int:
        if self.sparsity_profile is not None:
            return self.sparsity_profile.nonzero_weights
        return self.dense_weight_elements

    @property
    def zero_weights(self) -> int:
        if self.sparsity_profile is not None:
            return self.sparsity_profile.zero_weights
        return 0

    @property
    def density(self) -> float:
        if self.sparsity_profile is not None:
            return self.sparsity_profile.density
        return 1.0

    @property
    def sparsity(self) -> float:
        if self.sparsity_profile is not None:
            return self.sparsity_profile.sparsity
        return 0.0

    @property
    def dense_weight_elements(self) -> int:
        return self.conv_shape.M * self.conv_shape.C * self.conv_shape.R * self.conv_shape.S

    @property
    def dense_macs(self) -> int:
        return (
            self.conv_shape.N
            * self.conv_shape.M
            * self.conv_shape.E
            * self.conv_shape.F
            * self.conv_shape.C
            * self.conv_shape.R
            * self.conv_shape.S
        )

    @property
    def dense_ifmap_bytes(self) -> int:
        return (
            self.conv_shape.N
            * self.conv_shape.C
            * self.conv_shape.H
            * self.conv_shape.W
            * self.hardware.int8_bytes
        )

    @property
    def dense_weight_bytes(self) -> int:
        if self.sparsity_profile is not None:
            return self.sparsity_profile.dense_weight_bytes
        return self.dense_weight_elements * self.hardware.int8_bytes

    @property
    def dense_bias_bytes(self) -> int:
        return self.conv_shape.M * self.hardware.psum_bytes

    @property
    def dense_psum_bytes(self) -> int:
        return (
            self.conv_shape.N
            * self.conv_shape.M
            * self.conv_shape.E
            * self.conv_shape.F
            * self.hardware.psum_bytes
        )

    @property
    def dense_ofmap_bytes(self) -> int:
        return (
            self.conv_shape.N
            * self.conv_shape.M
            * self.conv_shape.E
            * self.conv_shape.F
            * self.hardware.int8_bytes
        )

    @property
    def dense_dram_bytes(self) -> int:
        return (
            self.dense_ifmap_bytes
            + self.dense_weight_bytes
            + self.dense_bias_bytes
            + self.dense_ofmap_bytes
        )

    @property
    def tile_ifmap_bytes(self) -> int:
        return self.tile.tile_m * self.tile.tile_k * self.hardware.int8_bytes

    @property
    def tile_weight_dense_bytes(self) -> int:
        return self.tile.tile_k * self.tile.tile_n * self.hardware.int8_bytes

    @property
    def tile_weight_mask_bytes(self) -> int:
        elems = self.tile.tile_k * self.tile.tile_n
        return ceil(elems / self.hardware.mask_word_bits) * self.hardware.mask_word_bytes

    @property
    def tile_weight_sparse_value_bytes(self) -> int:
        elems = self.tile.tile_k * self.tile.tile_n
        return ceil(elems * self.density) * self.hardware.int8_bytes

    @property
    def tile_psum_bytes(self) -> int:
        return self.tile.tile_m * self.tile.tile_n * self.hardware.psum_bytes

    @property
    def tile_bias_bytes(self) -> int:
        return self.tile.tile_n * self.hardware.psum_bytes

    @property
    def dense_glb_working_set(self) -> int:
        return (
            self.tile_ifmap_bytes
            + self.tile_weight_dense_bytes
            + self.tile_psum_bytes
            + self.tile_bias_bytes
        )

    @property
    def sparse_glb_working_set(self) -> int:
        return (
            self.tile_ifmap_bytes
            + self.tile_weight_sparse_value_bytes
            + self.tile_weight_mask_bytes
            + self.tile_psum_bytes
        )

    @property
    def dense_glb_legal(self) -> bool:
        return self.dense_glb_working_set <= self.hardware.glb_size

    @property
    def sparse_glb_legal(self) -> bool:
        return self.sparse_glb_working_set <= self.hardware.glb_size

    @property
    def dense_compute_cycles(self) -> int:
        return ceil(self.dense_macs / self.pe_count)

    @property
    def dense_memory_cycles(self) -> int:
        return ceil(self.dense_dram_bytes / self.hardware.dram_bw)

    @property
    def dense_total_cycles(self) -> int:
        return max(self.dense_compute_cycles, self.dense_memory_cycles)

    @property
    def dense_intensity(self) -> float:
        if self.dense_dram_bytes == 0:
            return 0.0
        return self.dense_macs / self.dense_dram_bytes

    @property
    def effective_sparse_macs(self) -> int:
        return ceil(self.dense_macs * self.density)

    @property
    def skipped_macs(self) -> int:
        return self.dense_macs - self.effective_sparse_macs

    @property
    def sparse_weight_value_bytes(self) -> int:
        if self.sparsity_profile is not None:
            return self.sparsity_profile.sparse_weight_value_bytes
        return self.nonzero_weights * self.hardware.int8_bytes

    @property
    def mask_words(self) -> int:
        return ceil(self.total_weights / self.hardware.mask_word_bits)

    @property
    def weight_bitmask_bytes(self) -> int:
        if self.sparsity_profile is not None:
            return self.sparsity_profile.weight_bitmask_bytes
        return self.mask_words * self.hardware.mask_word_bytes

    @property
    def sparse_weight_total_bytes(self) -> int:
        if self.sparsity_profile is not None:
            return self.sparsity_profile.sparse_weight_total_bytes
        return self.sparse_weight_value_bytes + self.weight_bitmask_bytes

    @property
    def compression_ratio(self) -> float:
        if self.sparsity_profile is not None:
            return self.sparsity_profile.compression_ratio
        return (
            self.sparse_weight_total_bytes / self.dense_weight_bytes
            if self.dense_weight_bytes
            else 0.0
        )

    @property
    def sparse_dram_bytes(self) -> int:
        return (
            self.dense_ifmap_bytes
            + self.sparse_weight_total_bytes
            + self.dense_bias_bytes
            + self.dense_ofmap_bytes
        )

    @property
    def sparse_dram_reduction_ratio(self) -> float:
        if self.dense_dram_bytes == 0:
            return 0.0
        return self.sparse_dram_bytes / self.dense_dram_bytes

    @property
    def dram_reduction_ratio(self) -> float:
        return self.sparse_dram_reduction_ratio

    @property
    def decode_cycles(self) -> int:
        return ceil(self.mask_words / self.hardware.decode_bw)

    @property
    def routing_cycles(self) -> int:
        return ceil(self.effective_sparse_macs * self.routing_penalty_ratio / self.pe_count)

    @property
    def reduction_cycles(self) -> int:
        return ceil(self.effective_sparse_macs * self.reduction_penalty_ratio / self.pe_count)

    @property
    def trip_utilization(self) -> float:
        return estimate_trip_utilization(self.density)

    @property
    def recommended_mode(self) -> str:
        return recommend_mode(self.density)

    @property
    def sparse_compute_cycles(self) -> int:
        return ceil(self.effective_sparse_macs / (self.pe_count * self.trip_utilization))

    @property
    def sparse_memory_cycles(self) -> int:
        return ceil(self.sparse_dram_bytes / self.hardware.dram_bw)

    @property
    def sparse_total_cycles(self) -> int:
        return (
            max(self.sparse_compute_cycles, self.sparse_memory_cycles)
            + self.decode_cycles
            + self.routing_cycles
            + self.reduction_cycles
        )

    @property
    def speedup_sparse_over_dense(self) -> float:
        if self.sparse_total_cycles == 0:
            return 0.0
        return self.dense_total_cycles / self.sparse_total_cycles

    @property
    def sparse_intensity(self) -> float:
        if self.sparse_dram_bytes == 0:
            return 0.0
        return self.effective_sparse_macs / self.sparse_dram_bytes

    @property
    def selected_intensity(self) -> float:
        return self.sparse_intensity if self.analysis_mode == "sparse" else self.dense_intensity

    @property
    def roofline_name(self) -> str:
        return "TrIP-like 16x16" if self.analysis_mode == "sparse" else "Standard IP 16x16"

    @property
    def summary(self) -> dict:
        return {
            "layer": self.layer_name,
            "mode": self.analysis_mode,
            "recommended_mode": self.recommended_mode,
            "tile_m": self.tile.tile_m,
            "tile_n": self.tile.tile_n,
            "tile_k": self.tile.tile_k,
            "glb_size": self.hardware.glb_size,
            "density": self.density,
            "sparsity": self.sparsity,
            "dense_macs": self.dense_macs,
            "dense_ops": self.dense_macs,
            "effective_sparse_macs": self.effective_sparse_macs,
            "skipped_macs": self.skipped_macs,
            "dense_ifmap_bytes": self.dense_ifmap_bytes,
            "dense_weight_bytes": self.dense_weight_bytes,
            "dense_bias_bytes": self.dense_bias_bytes,
            "dense_psum_bytes": self.dense_psum_bytes,
            "dense_ofmap_bytes": self.dense_ofmap_bytes,
            "sparse_weight_value_bytes": self.sparse_weight_value_bytes,
            "weight_bitmask_bytes": self.weight_bitmask_bytes,
            "sparse_weight_total_bytes": self.sparse_weight_total_bytes,
            "compression_ratio": self.compression_ratio,
            "dense_dram_bytes": self.dense_dram_bytes,
            "sparse_dram_bytes": self.sparse_dram_bytes,
            "sparse_dram_reduction_ratio": self.sparse_dram_reduction_ratio,
            "dram_reduction_ratio": self.sparse_dram_reduction_ratio,
            "dense_compute_cycles": self.dense_compute_cycles,
            "dense_memory_cycles": self.dense_memory_cycles,
            "dense_total_cycles": self.dense_total_cycles,
            "sparse_compute_cycles": self.sparse_compute_cycles,
            "sparse_memory_cycles": self.sparse_memory_cycles,
            "decode_cycles": self.decode_cycles,
            "routing_cycles": self.routing_cycles,
            "reduction_cycles": self.reduction_cycles,
            "sparse_total_cycles": self.sparse_total_cycles,
            "speedup_sparse_over_dense": self.speedup_sparse_over_dense,
            "trip_utilization": self.trip_utilization,
            "dense_glb_working_set": self.dense_glb_working_set,
            "sparse_glb_working_set": self.sparse_glb_working_set,
            "dense_glb_legal": self.dense_glb_legal,
            "sparse_glb_legal": self.sparse_glb_legal,
            "peak_performance": self.pe_count,
            "peak_bandwidth": self.hardware.dram_bw,
            "dense_intensity": self.dense_intensity,
            "sparse_intensity": self.sparse_intensity,
            "intensity": self.selected_intensity,
            "roofline_name": self.roofline_name,
        }
