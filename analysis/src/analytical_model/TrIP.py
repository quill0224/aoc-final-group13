from __future__ import annotations

from dataclasses import dataclass
from math import ceil, floor
from typing import Union

from layer_info import Conv2DShapeParam, MaxPool2DShapeParam

# Memory
DATA_SIZE = 1  # Byte, INT8 value
PSUM_DATA_SIZE = 4  # Byte, INT32 partial sum
BUS_BANDWIDTH = 4  # Byte/cycle, default fallback

# Time
CLOCK_RATE = 200 * 1e6  # 200 MHz
TIME_UNIT = 1  # cycle
SPAD_ACCESS_TIME = 1 * TIME_UNIT
GLB_ACCESS_TIME = 2 * TIME_UNIT
DRAM_ACCESS_TIME = 5 * TIME_UNIT

# Energy
ENERGY_UNIT = 1e-6  # 1 pJ = 10^-6 uJ in this model's scale
ENERGY_PER_MAC = 2 * ENERGY_UNIT
ENERGY_PER_GLB_ACCESS = 10 * ENERGY_UNIT
ENERGY_PER_DRAM_ACCESS = 200 * ENERGY_UNIT
POWER_UNIT = 1  # 1 uW
POWER_LEAKAGE = 50 * POWER_UNIT

# TrIP analytical knobs. They are intentionally simple because this is not a
# cycle-accurate MFIU simulator.
MAX_PACKED_A_ROWS = 4
MAX_PACKED_B_COLS = 4
MIN_TRIP_UTILIZATION = 0.05
INTERSECTION_BITMASK_WORD_BYTES = 1
INTERSECTION_BW_WORDS_PER_CYCLE = 16
ROUTING_BW_VALUES_PER_CYCLE_FACTOR = 1.0


@dataclass
class TrIPHardwareParam:
    pe_array_h: int
    pe_array_w: int
    glb_size: int
    bus_bw: int
    noc_bw: int


@dataclass
class TrIPTilingParam:
    tile_m: int
    tile_n: int
    tile_k: int


AnalysisResult = dict[str, Union[str, int, float]]


class TrIPAnalyzer:
    """Analytical model for a small TrIP-like sparse IP accelerator.

    Conv2D is lowered to GEMM:
        A / ifmap : [M_gemm, K_gemm]
        B / weight: [K_gemm, N_gemm]
        C / psum  : [M_gemm, N_gemm]

    The sparse MAC model is a first-order layer-level approximation:
        effectual_macs = dense_macs * act_density * filter_density

    The DRAM model follows activation-stationary-ish loop order:
        for m_tile:
            for k_tile:
                load sparse A tile once
                for n_tile:
                    load sparse B tile
                    compute
    """

    def __init__(
        self,
        layer_name: str,
        conv_shape: Conv2DShapeParam,
        hardware: TrIPHardwareParam,
        tile: TrIPTilingParam,
        act_density: float = 1.0,
        filter_density: float = 1.0,
    ) -> None:
        self.layer_name = layer_name
        self.conv_shape = conv_shape
        self.hardware = hardware
        self.tiling = tile
        self.act_density = act_density
        self.filter_density = filter_density
        self.maxpool_shape = None

    @staticmethod
    def _clamp_density(value: float) -> float:
        return max(0.0, min(1.0, float(value)))

    @property
    def act_density(self) -> float:
        return self._act_density

    @act_density.setter
    def act_density(self, value: float) -> None:
        self._act_density = self._clamp_density(value)

    @property
    def filter_density(self) -> float:
        return self._filter_density

    @filter_density.setter
    def filter_density(self, value: float) -> None:
        self._filter_density = self._clamp_density(value)

    @property
    def hardware(self) -> TrIPHardwareParam:
        return self._hardware

    @hardware.setter
    def hardware(self, hardware_param: TrIPHardwareParam) -> None:
        assert isinstance(hardware_param, TrIPHardwareParam)
        self._hardware = hardware_param

    @property
    def conv_shape(self) -> Conv2DShapeParam:
        return self._conv_shape

    @conv_shape.setter
    def conv_shape(self, conv_param: Conv2DShapeParam) -> None:
        assert isinstance(conv_param, Conv2DShapeParam)
        self._conv_shape = conv_param

    @property
    def maxpool_shape(self) -> MaxPool2DShapeParam | None:
        return self._maxpool_shape

    @maxpool_shape.setter
    def maxpool_shape(self, maxpool_param: MaxPool2DShapeParam | None) -> None:
        assert isinstance(maxpool_param, (MaxPool2DShapeParam, type(None)))
        self._maxpool_shape = maxpool_param

    @property
    def tiling(self) -> TrIPTilingParam:
        return self._tile

    @tiling.setter
    def tiling(self, tiling_param: TrIPTilingParam) -> None:
        assert isinstance(tiling_param, TrIPTilingParam)
        self._tile = tiling_param
        self.tile = tiling_param

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
    def dense_macs(self) -> int:
        return self.m_gemm * self.n_gemm * self.k_gemm

    @property
    def effectual_macs(self) -> float:
        return self.dense_macs * self.act_density * self.filter_density

    @property
    def macs_per_layer(self) -> float:
        return self.effectual_macs

    @property
    def sparse_mac_reduction_ratio(self) -> float:
        if self.dense_macs == 0:
            return 0.0
        return self.effectual_macs / self.dense_macs

    @staticmethod
    def _bitmask_bytes(num_fibers: int, fiber_len: int) -> int:
        return num_fibers * ceil(fiber_len / 8)

    @staticmethod
    def _sparse_value_bytes(num_values: int, density: float, data_size: int = DATA_SIZE) -> int:
        return ceil(num_values * density * data_size)

    def _ifmap_tile_bytes(self, tm: int, tk: int) -> tuple[int, int, int]:
        value = self._sparse_value_bytes(tm * tk, self.act_density)
        bitmask = self._bitmask_bytes(tm, tk)
        return value, bitmask, value + bitmask

    def _filter_tile_bytes(self, tk: int, tn: int) -> tuple[int, int, int]:
        value = self._sparse_value_bytes(tk * tn, self.filter_density)
        bitmask = self._bitmask_bytes(tn, tk)
        return value, bitmask, value + bitmask

    @property
    def min_glb_breakdown(self) -> dict[str, int]:
        tm = self.tile.tile_m
        tn = self.tile.tile_n
        tk = self.tile.tile_k
        ifmap_value, ifmap_bitmask, ifmap_total = self._ifmap_tile_bytes(tm, tk)
        filter_value, filter_bitmask, filter_total = self._filter_tile_bytes(tk, tn)
        psum = tm * self.n_gemm * PSUM_DATA_SIZE
        total = ifmap_total + filter_total + psum
        return {
            "activation": ifmap_value,
            "activation_bitmask": ifmap_bitmask,
            "filter": filter_value,
            "filter_bitmask": filter_bitmask,
            "psum": psum,
            "filter_total": filter_total,
            "activation_total": ifmap_total,
            "total": total,
        }

    @property
    def dense_full_filter_bytes(self) -> int:
        return self.k_gemm * self.n_gemm * DATA_SIZE

    @property
    def sparse_full_filter_value_bytes(self) -> int:
        return self._sparse_value_bytes(self.k_gemm * self.n_gemm, self.filter_density)

    @property
    def sparse_full_filter_bitmask_bytes(self) -> int:
        return self._bitmask_bytes(self.n_gemm, self.k_gemm)

    @property
    def sparse_full_filter_total_bytes(self) -> int:
        return self.sparse_full_filter_value_bytes + self.sparse_full_filter_bitmask_bytes

    @property
    def enough_glb_breakdown(self) -> dict[str, int]:
        tm = self.tile.tile_m
        tk = self.tile.tile_k
        ifmap_value, ifmap_bitmask, ifmap_total = self._ifmap_tile_bytes(tm, tk)
        psum = tm * self.n_gemm * PSUM_DATA_SIZE
        dense_total = ifmap_total + self.dense_full_filter_bytes + psum
        sparse_total = ifmap_total + self.sparse_full_filter_total_bytes + psum
        return {
            "activation": ifmap_value,
            "activation_bitmask": ifmap_bitmask,
            "psum": psum,
            "dense_filter": self.dense_full_filter_bytes,
            "sparse_filter_value": self.sparse_full_filter_value_bytes,
            "sparse_filter_bitmask": self.sparse_full_filter_bitmask_bytes,
            "sparse_filter_total": self.sparse_full_filter_total_bytes,
            "dense_total": dense_total,
            "sparse_total": sparse_total,
            "total": sparse_total,
        }

    @property
    def min_glb_size(self) -> int:
        return self.min_glb_breakdown["total"]

    @property
    def enough_glb_size(self) -> int:
        return self.enough_glb_breakdown["sparse_total"]

    @property
    def enough_glb_size_dense_filter(self) -> int:
        return self.enough_glb_breakdown["dense_total"]

    @property
    def enough_glb_size_sparse_filter(self) -> int:
        return self.enough_glb_breakdown["sparse_total"]

    @property
    def glb_meets_min(self) -> bool:
        return self.hardware.glb_size >= self.min_glb_size

    @property
    def glb_meets_enough(self) -> bool:
        return self.hardware.glb_size >= self.enough_glb_size

    @property
    def filter_fits_in_glb(self) -> bool:
        return self.glb_meets_enough

    @property
    def glb_usage_per_tile(self) -> dict[str, int]:
        min_glb = self.min_glb_breakdown
        return {
            "ifmap_value": min_glb["activation"],
            "ifmap_bitmask": min_glb["activation_bitmask"],
            "ifmap": min_glb["activation_total"],
            "filter_value": min_glb["filter"],
            "filter_bitmask": min_glb["filter_bitmask"],
            "filter": min_glb["filter_total"],
            "psum": min_glb["psum"],
            "activation_psum": min_glb["activation_total"] + min_glb["psum"],
            "total": min_glb["total"],
        }

    @property
    def output_shape_after_pool(self) -> tuple[int, int]:
        if self.maxpool_shape is None:
            return self.conv_shape.E, self.conv_shape.F
        out_h = (self.conv_shape.E - self.maxpool_shape.kernel_size) // self.maxpool_shape.stride + 1
        out_w = (self.conv_shape.F - self.maxpool_shape.kernel_size) // self.maxpool_shape.stride + 1
        return out_h, out_w

    def glb_access_per_layer(self) -> dict[str, int]:
        """On-chip GLB traffic for TrIP sparse values, bitmasks, and psums."""
        res: dict[str, int] = {}

        num_m_tiles = ceil(self.m_gemm / self.tile.tile_m)
        num_k_tiles = ceil(self.k_gemm / self.tile.tile_k)
        num_n_tiles = ceil(self.n_gemm / self.tile.tile_n)

        ifmap_value_read = 0
        ifmap_bitmask_read = 0
        filter_value_read = 0
        filter_bitmask_read = 0
        bias_read = 0
        psum_read_conv = 0
        psum_write_conv = 0
        psum_read_pool = 0

        for mi in range(num_m_tiles):
            tm = min(self.tile.tile_m, self.m_gemm - mi * self.tile.tile_m)

            for ni in range(num_n_tiles):
                tn = min(self.tile.tile_n, self.n_gemm - ni * self.tile.tile_n)
                bias_read += tn * PSUM_DATA_SIZE
                c_tile_bytes = tm * tn * PSUM_DATA_SIZE

                for ki in range(num_k_tiles):
                    tk = min(self.tile.tile_k, self.k_gemm - ki * self.tile.tile_k)

                    # A tile can be loaded once per (m, k) and reused across n in
                    # the DRAM model, but GLB-to-array traffic is counted at each
                    # compute pass because each n tile consumes it.
                    a_value, a_bitmask, _ = self._ifmap_tile_bytes(tm, tk)
                    b_value, b_bitmask, _ = self._filter_tile_bytes(tk, tn)
                    ifmap_value_read += a_value
                    ifmap_bitmask_read += a_bitmask
                    filter_value_read += b_value
                    filter_bitmask_read += b_bitmask

                    if ki > 0:
                        psum_read_conv += c_tile_bytes
                    psum_write_conv += c_tile_bytes

                psum_read_pool += c_tile_bytes

        out_h, out_w = self.output_shape_after_pool
        ofmap_write_pool = self.conv_shape.N * self.conv_shape.M * out_h * out_w * DATA_SIZE

        res["ifmap_value_read"] = ifmap_value_read
        res["ifmap_bitmask_read"] = ifmap_bitmask_read
        res["ifmap_read"] = ifmap_value_read + ifmap_bitmask_read
        res["filter_value_read"] = filter_value_read
        res["filter_bitmask_read"] = filter_bitmask_read
        res["filter_read"] = filter_value_read + filter_bitmask_read
        res["bias_read"] = bias_read
        res["psum_read_conv"] = psum_read_conv
        res["psum_write_conv"] = psum_write_conv
        res["psum_read_pool"] = psum_read_pool
        res["ofmap_write_pool"] = ofmap_write_pool
        res["psum_read"] = psum_read_conv + psum_read_pool
        res["psum_write"] = psum_write_conv
        res["read"] = res["ifmap_read"] + res["filter_read"] + bias_read + res["psum_read"]
        res["write"] = res["psum_write"] + ofmap_write_pool
        res["total"] = res["read"] + res["write"]
        return res

    @property
    def dram_access_compulsory_per_layer(self) -> dict[str, int]:
        """Ideal sparse compulsory DRAM traffic lower bound."""
        res: dict[str, int] = {}

        ifmap_value = self._sparse_value_bytes(self.m_gemm * self.k_gemm, self.act_density)
        ifmap_bitmask = self._bitmask_bytes(self.m_gemm, self.k_gemm)
        filter_value = self._sparse_value_bytes(self.k_gemm * self.n_gemm, self.filter_density)
        filter_bitmask = self._bitmask_bytes(self.n_gemm, self.k_gemm)
        bias_read = self.dense_bias_bytes
        out_h, out_w = self.output_shape_after_pool
        ofmap_write = self.conv_shape.N * self.conv_shape.M * out_h * out_w * DATA_SIZE

        res["ifmap_value_read"] = ifmap_value
        res["ifmap_bitmask_read"] = ifmap_bitmask
        res["ifmap_read"] = ifmap_value + ifmap_bitmask
        res["filter_value_read"] = filter_value
        res["filter_bitmask_read"] = filter_bitmask
        res["filter_read"] = filter_value + filter_bitmask
        res["bias_read"] = bias_read
        res["psum_read"] = 0
        res["psum_write"] = 0
        res["ofmap_write"] = ofmap_write
        res["read"] = res["ifmap_read"] + res["filter_read"] + bias_read
        res["write"] = ofmap_write
        res["total"] = res["read"] + res["write"]
        return res

    @property
    def dram_access_per_layer(self) -> dict[str, int]:
        """Tiled sparse DRAM traffic using activation-stationary-ish order."""
        res: dict[str, int] = {}

        num_m_tiles = ceil(self.m_gemm / self.tile.tile_m)
        num_k_tiles = ceil(self.k_gemm / self.tile.tile_k)
        num_n_tiles = ceil(self.n_gemm / self.tile.tile_n)

        ifmap_value_read = 0
        ifmap_bitmask_read = 0
        filter_value_read = 0
        filter_bitmask_read = 0
        bias_read = 0

        for mi in range(num_m_tiles):
            tm = min(self.tile.tile_m, self.m_gemm - mi * self.tile.tile_m)

            for ki in range(num_k_tiles):
                tk = min(self.tile.tile_k, self.k_gemm - ki * self.tile.tile_k)
                a_value, a_bitmask, _ = self._ifmap_tile_bytes(tm, tk)

                # Activation-stationary-ish: load sparse A once for this (m, k)
                # and reuse it across all n tiles.
                ifmap_value_read += a_value
                ifmap_bitmask_read += a_bitmask

                for ni in range(num_n_tiles):
                    tn = min(self.tile.tile_n, self.n_gemm - ni * self.tile.tile_n)
                    b_value, b_bitmask, _ = self._filter_tile_bytes(tk, tn)

                    # Filter may not be retained across m tiles, so each
                    # (m, k, n) compute pass reloads the B tile.
                    filter_value_read += b_value
                    filter_bitmask_read += b_bitmask

        for mi in range(num_m_tiles):
            for ni in range(num_n_tiles):
                tn = min(self.tile.tile_n, self.n_gemm - ni * self.tile.tile_n)
                bias_read += tn * PSUM_DATA_SIZE

        out_h, out_w = self.output_shape_after_pool
        ofmap_write = self.conv_shape.N * self.conv_shape.M * out_h * out_w * DATA_SIZE

        res["ifmap_value_read"] = ifmap_value_read
        res["ifmap_bitmask_read"] = ifmap_bitmask_read
        res["ifmap_read"] = ifmap_value_read + ifmap_bitmask_read
        res["filter_value_read"] = filter_value_read
        res["filter_bitmask_read"] = filter_bitmask_read
        res["filter_read"] = filter_value_read + filter_bitmask_read
        res["bias_read"] = bias_read
        res["psum_read"] = 0
        res["psum_write"] = 0
        res["ofmap_write"] = ofmap_write
        res["read"] = res["ifmap_read"] + res["filter_read"] + bias_read
        res["write"] = ofmap_write
        res["total"] = res["read"] + res["write"]
        return res

    @property
    def dense_ifmap_bytes(self) -> int:
        return self.conv_shape.N * self.conv_shape.C * self.conv_shape.H * self.conv_shape.W * DATA_SIZE

    @property
    def dense_weight_bytes(self) -> int:
        return self.conv_shape.M * self.conv_shape.C * self.conv_shape.R * self.conv_shape.S * DATA_SIZE

    @property
    def dense_bias_bytes(self) -> int:
        return self.conv_shape.M * PSUM_DATA_SIZE

    @property
    def dense_psum_bytes(self) -> int:
        return self.conv_shape.N * self.conv_shape.M * self.conv_shape.E * self.conv_shape.F * PSUM_DATA_SIZE

    @property
    def ppu_latency_per_layer(self) -> int:
        ofmap_size = self.conv_shape.N * self.conv_shape.M * self.conv_shape.E * self.conv_shape.F
        ppu_latency_per_elem = 1 if self.maxpool_shape is None else 5
        return ofmap_size * ppu_latency_per_elem

    @property
    def peak_performance(self) -> float:
        return float(self.pe_count)

    @property
    def peak_bandwidth(self) -> float:
        return float(self.hardware.bus_bw if self.hardware.bus_bw > 0 else BUS_BANDWIDTH)

    @property
    def expected_intersections_per_pair(self) -> float:
        return self.tile.tile_k * self.act_density * self.filter_density

    @property
    def packed_a_rows(self) -> int:
        return max(1, min(MAX_PACKED_A_ROWS, self.tile.tile_m))

    @property
    def packed_b_cols(self) -> int:
        # Pick as many B columns as possible without overflowing one PE row on
        # average. This approximates TrIP's dynamic B-column packing.
        per_pair = max(self.expected_intersections_per_pair, 1e-9)
        max_cols_by_capacity = max(1, floor(self.hardware.pe_array_w / (self.packed_a_rows * per_pair)))
        return max(1, min(MAX_PACKED_B_COLS, self.tile.tile_n, max_cols_by_capacity))

    @property
    def trip_utilization(self) -> float:
        expected_ops = self.packed_a_rows * self.packed_b_cols * self.expected_intersections_per_pair
        util = expected_ops / max(1, self.hardware.pe_array_w)
        return max(MIN_TRIP_UTILIZATION, min(1.0, util))

    @property
    def issued_slots(self) -> float:
        if self.effectual_macs <= 0:
            return 0.0
        return self.effectual_macs / self.trip_utilization

    @property
    def compute_cycles(self) -> int:
        return ceil(self.issued_slots / self.peak_performance)

    @property
    def intersection_cycles(self) -> int:
        num_m_tiles = ceil(self.m_gemm / self.tile.tile_m)
        num_k_tiles = ceil(self.k_gemm / self.tile.tile_k)
        num_n_tiles = ceil(self.n_gemm / self.tile.tile_n)
        num_tiles = num_m_tiles * num_k_tiles * num_n_tiles
        bitmask_words = ceil(self.tile.tile_k / INTERSECTION_BITMASK_WORD_BYTES)
        pairwise_intersections = min(self.tile.tile_m, MAX_PACKED_A_ROWS) * min(self.tile.tile_n, MAX_PACKED_B_COLS)
        words = num_tiles * pairwise_intersections * bitmask_words
        return ceil(words / INTERSECTION_BW_WORDS_PER_CYCLE)

    @property
    def routing_cycles(self) -> int:
        routing_bw = max(1.0, self.peak_performance * ROUTING_BW_VALUES_PER_CYCLE_FACTOR)
        return ceil(self.effectual_macs / routing_bw)

    @property
    def memory_cycles(self) -> int:
        glb_access = self.glb_access_per_layer()
        dram_access = self.dram_access_per_layer
        glb_cycles = ceil(glb_access["total"] * GLB_ACCESS_TIME / max(1, self.hardware.noc_bw))
        dram_cycles = ceil(dram_access["total"] * DRAM_ACCESS_TIME / max(1, self.hardware.bus_bw))
        return glb_cycles + dram_cycles

    @property
    def sparse_compute_cycles(self) -> int:
        return self.compute_cycles + self.intersection_cycles + self.routing_cycles

    @property
    def total_cycles_trip(self) -> int:
        return max(self.sparse_compute_cycles, self.memory_cycles) + self.ppu_latency_per_layer

    @property
    def total_cycles_dense(self) -> int:
        # Kept for compatibility with existing mapper/roofline code.
        return self.total_cycles_trip

    @property
    def latency_per_layer(self) -> int:
        return self.total_cycles_trip

    @property
    def bound_by(self) -> str:
        if self.sparse_compute_cycles > self.memory_cycles:
            return "compute"
        if self.sparse_compute_cycles < self.memory_cycles:
            return "memory"
        return "balanced"

    @property
    def dense_bound_by(self) -> str:
        return self.bound_by

    @property
    def energy_per_layer(self) -> dict[str, float]:
        glb_access = self.glb_access_per_layer()
        dram_access = self.dram_access_per_layer
        compute_energy = self.effectual_macs * ENERGY_PER_MAC
        intersection_energy = self.intersection_cycles * self.hardware.pe_array_h * ENERGY_PER_MAC * 0.25
        routing_energy = self.routing_cycles * self.hardware.pe_array_h * ENERGY_PER_MAC * 0.25
        memory_energy = (
            glb_access["total"] * ENERGY_PER_GLB_ACCESS
            + dram_access["total"] * ENERGY_PER_DRAM_ACCESS
        )
        leakage_energy = POWER_LEAKAGE * self.latency_per_layer / CLOCK_RATE
        total_energy = compute_energy + intersection_energy + routing_energy + memory_energy + leakage_energy
        return {
            "compute": compute_energy,
            "intersection": intersection_energy,
            "routing": routing_energy,
            "memory": memory_energy,
            "leakage": leakage_energy,
            "total": total_energy,
        }

    @property
    def power_per_layer(self) -> dict[str, float]:
        latency = max(1, self.latency_per_layer)
        compute_power = self.energy_per_layer["compute"] / latency * CLOCK_RATE
        memory_power = self.energy_per_layer["memory"] / latency * CLOCK_RATE
        leakage_power = POWER_LEAKAGE
        total_power = compute_power + memory_power + leakage_power
        return {
            "compute": compute_power,
            "memory": memory_power,
            "leakage": leakage_power,
            "total": total_power,
        }

    @property
    def operational_intensity(self) -> float:
        dram_total = self.dram_access_per_layer["total"]
        if dram_total == 0:
            return 0.0
        return self.effectual_macs / dram_total

    @property
    def is_compute_bound(self) -> bool:
        return self.bound_by == "compute"

    @property
    def is_memory_bound(self) -> bool:
        return self.bound_by == "memory"

    @property
    def is_balanced(self) -> bool:
        return self.bound_by == "balanced"

    @property
    def metadata_bytes_per_tile(self) -> int:
        usage = self.glb_usage_per_tile
        return usage["ifmap_bitmask"] + usage["filter_bitmask"]

    @property
    def metadata_overhead_ratio_per_tile(self) -> float:
        usage = self.glb_usage_per_tile
        value_bytes = usage["ifmap_value"] + usage["filter_value"]
        if value_bytes == 0:
            return 0.0
        return self.metadata_bytes_per_tile / value_bytes

    @property
    def summary(self) -> AnalysisResult:
        if not hasattr(self, "mode"):
            self.mode = None

        glb_usage = self.glb_usage_per_tile
        glb_access = self.glb_access_per_layer()
        dram_compulsory = self.dram_access_compulsory_per_layer
        dram_tiled = self.dram_access_per_layer
        energy = self.energy_per_layer
        power = self.power_per_layer
        min_glb = self.min_glb_breakdown
        enough_glb = self.enough_glb_breakdown
        dram_actual_total = dram_tiled["total"]
        oi_compulsory = self.effectual_macs / dram_compulsory["total"] if dram_compulsory["total"] else 0.0
        oi_actual = self.effectual_macs / dram_actual_total if dram_actual_total else 0.0
        balance_point = self.peak_performance / self.peak_bandwidth if self.peak_bandwidth else float("inf")

        def roofline_bound(intensity: float) -> str:
            if intensity > balance_point:
                return "compute"
            if intensity < balance_point:
                return "memory"
            return "balanced"

        return {
            "layer": self.layer_name,
            "mode": "trip",
            "act_density": self.act_density,
            "filter_density": self.filter_density,
            "act_sparsity": 1.0 - self.act_density,
            "filter_sparsity": 1.0 - self.filter_density,

            "m_gemm": self.m_gemm,
            "k_gemm": self.k_gemm,
            "n_gemm": self.n_gemm,
            "m_tile_compute": self.tile.tile_m,
            "k_tile_compute": self.tile.tile_k,
            "n_tile_compute": self.tile.tile_n,
            "psum_resident_n": self.n_gemm,
            "glb_size": self.hardware.glb_size,
            "min_glb_activation_bytes": min_glb["activation"],
            "min_glb_activation_bitmask_bytes": min_glb["activation_bitmask"],
            "min_glb_filter_bytes": min_glb["filter"],
            "min_glb_filter_bitmask_bytes": min_glb["filter_bitmask"],
            "min_glb_psum_bytes": min_glb["psum"],
            "min_glb_size": min_glb["total"],
            "dense_full_filter_bytes": self.dense_full_filter_bytes,
            "sparse_full_filter_value_bytes": self.sparse_full_filter_value_bytes,
            "sparse_full_filter_bitmask_bytes": self.sparse_full_filter_bitmask_bytes,
            "sparse_full_filter_total_bytes": self.sparse_full_filter_total_bytes,
            "enough_glb_activation_bytes": enough_glb["activation"],
            "enough_glb_activation_bitmask_bytes": enough_glb["activation_bitmask"],
            "enough_glb_psum_bytes": enough_glb["psum"],
            "enough_glb_size_dense_filter": enough_glb["dense_total"],
            "enough_glb_size_sparse_filter": enough_glb["sparse_total"],
            "enough_glb_size": enough_glb["sparse_total"],
            "glb_meets_min": self.glb_meets_min,
            "glb_meets_enough": self.glb_meets_enough,
            "filter_fits_in_glb": self.filter_fits_in_glb,
            "glb_usage": glb_usage["total"],
            "glb_ifmap_usage": glb_usage["ifmap"],
            "glb_filter_usage": glb_usage["filter"],
            "glb_psum_usage": glb_usage["psum"],
            "glb_activation_psum_usage": glb_usage["activation_psum"],
            "metadata_bytes_per_tile": self.metadata_bytes_per_tile,
            "metadata_overhead_ratio_per_tile": self.metadata_overhead_ratio_per_tile,

            "glb_ifmap_value_read": glb_access["ifmap_value_read"],
            "glb_ifmap_bitmask_read": glb_access["ifmap_bitmask_read"],
            "glb_ifmap_read": glb_access["ifmap_read"],
            "glb_filter_value_read": glb_access["filter_value_read"],
            "glb_filter_bitmask_read": glb_access["filter_bitmask_read"],
            "glb_filter_read": glb_access["filter_read"],
            "glb_bias_read": glb_access["bias_read"],
            "glb_psum_read_conv": glb_access["psum_read_conv"],
            "glb_psum_read_pool": glb_access["psum_read_pool"],
            "glb_psum_read": glb_access["psum_read"],
            "glb_psum_write_conv": glb_access["psum_write_conv"],
            "glb_ofmap_write_pool": glb_access["ofmap_write_pool"],
            "glb_psum_write": glb_access["psum_write"],
            "glb_read": glb_access["read"],
            "glb_write": glb_access["write"],
            "glb_access": glb_access["total"],

            "dram_compulsory_ifmap_value_read": dram_compulsory["ifmap_value_read"],
            "dram_compulsory_ifmap_bitmask_read": dram_compulsory["ifmap_bitmask_read"],
            "dram_compulsory_ifmap_read": dram_compulsory["ifmap_read"],
            "dram_compulsory_filter_value_read": dram_compulsory["filter_value_read"],
            "dram_compulsory_filter_bitmask_read": dram_compulsory["filter_bitmask_read"],
            "dram_compulsory_filter_read": dram_compulsory["filter_read"],
            "dram_compulsory_bias_read": dram_compulsory["bias_read"],
            "dram_compulsory_ofmap_write": dram_compulsory["ofmap_write"],
            "dram_compulsory_total": dram_compulsory["total"],

            "dram_ifmap_value_read": dram_tiled["ifmap_value_read"],
            "dram_ifmap_bitmask_read": dram_tiled["ifmap_bitmask_read"],
            "dram_ifmap_read": dram_tiled["ifmap_read"],
            "dram_filter_value_read": dram_tiled["filter_value_read"],
            "dram_filter_bitmask_read": dram_tiled["filter_bitmask_read"],
            "dram_filter_read": dram_tiled["filter_read"],
            "dram_bias_read": dram_tiled["bias_read"],
            "dram_psum_read": dram_tiled["psum_read"],
            "dram_psum_write": dram_tiled["psum_write"],
            "dram_ofmap_write": dram_tiled["ofmap_write"],
            "dram_read": dram_tiled["read"],
            "dram_write": dram_tiled["write"],
            "dram_access": dram_tiled["total"],
            "dram_total": dram_tiled["total"],
            "dram_actual_total": dram_actual_total,
            "oi_compulsory": oi_compulsory,
            "oi_actual": oi_actual,
            "bound_by_compulsory": roofline_bound(oi_compulsory),
            "bound_by_actual": roofline_bound(oi_actual),

            "macs": self.effectual_macs,
            "dense_macs": self.dense_macs,
            "effectual_macs": self.effectual_macs,
            "issued_slots": self.issued_slots,
            "sparse_mac_reduction_ratio": self.sparse_mac_reduction_ratio,
            "trip_utilization": self.trip_utilization,
            "packed_a_rows": self.packed_a_rows,
            "packed_b_cols": self.packed_b_cols,
            "expected_intersections_per_pair": self.expected_intersections_per_pair,

            "dense_ifmap_bytes": self.dense_ifmap_bytes,
            "dense_weight_bytes": self.dense_weight_bytes,
            "dense_bias_bytes": self.dense_bias_bytes,
            "dense_psum_bytes": self.dense_psum_bytes,
            "dense_dram_bytes": self.dense_ifmap_bytes + self.dense_weight_bytes + self.dense_bias_bytes + dram_tiled["ofmap_write"],
            "sparse_dram_bytes": dram_tiled["total"],
            "dense_glb_bytes": glb_access["total"],
            "sparse_glb_bytes": glb_access["total"],

            "compute_cycles": self.compute_cycles,
            "intersection_cycles": self.intersection_cycles,
            "routing_cycles": self.routing_cycles,
            "sparse_compute_cycles": self.sparse_compute_cycles,
            "memory_cycles": self.memory_cycles,
            "total_cycles_trip": self.total_cycles_trip,
            "total_cycles_dense": self.total_cycles_dense,
            "total_cycles": self.total_cycles_trip,
            "latency": self.latency_per_layer,

            "energy_compute": energy["compute"],
            "energy_intersection": energy["intersection"],
            "energy_routing": energy["routing"],
            "energy_memory": energy["memory"],
            "energy_total": energy["total"],
            "power_total": power["total"],

            "peak_performance": self.peak_performance,
            "peak_bandwidth": self.peak_bandwidth,
            "intensity": oi_actual,
            "operational_intensity": oi_actual,
            "bound_by": roofline_bound(oi_actual),
        }

# from __future__ import annotations

# from dataclasses import dataclass
# from math import ceil
# from typing import Optional, Union

# from layer_info import Conv2DShapeParam, MaxPool2DShapeParam

# # Memory
# DATA_SIZE = 1  # Byte
# PSUM_DATA_SIZE = 4  # Byte
# BUS_BANDWIDTH = 4  # Byte

# # Time
# CLOCK_RATE = 200 * 1e6  # 200 MHz
# TIME_UNIT = 1  # cycle
# SPAD_ACCESS_TIME = 1 * TIME_UNIT
# GLB_ACCESS_TIME = 2 * TIME_UNIT
# DRAM_ACCESS_TIME = 5 * TIME_UNIT

# # Energy
# ENERGY_UNIT = 1e-6  # 1 pJ = 10^6 uJ
# ENERGY_PER_MAC = 2 * ENERGY_UNIT
# ENERGY_PER_GLB_ACCESS = 10 * ENERGY_UNIT
# ENERGY_PER_DRAM_ACCESS = 200 * ENERGY_UNIT
# POWER_UNIT = 1  # 1 uW
# POWER_LEAKAGE = 50 * POWER_UNIT
# ######################################################################################################
# # N: number of ifmaps/ofmaps
# # M: number of filters
# # H/W: ifmap height/width
# # R/S: filter height/width
# # E/F: ofmap height/width
# # U: stride
# ######################################################################################################
# @dataclass
# class TrIPHardwareParam:
#     pe_array_h: int 
#     pe_array_w: int 
#     glb_size: int
#     bus_bw: int
#     noc_bw: int

# @dataclass
# class TrIPTilingParam:
#     tile_m: int 
#     tile_n: int 
#     tile_k: int

# AnalysisResult = dict[str, Union[str, int, float]]

# class TrIPAnalyzer:
#     def __init__(
#         self,
#         layer_name: str,
#         conv_shape: Conv2DShapeParam,
#         hardware: TrIPHardwareParam,
#         tile: TrIPTilingParam,
#         act_density: float = 1.0,
#         filter_density: float = 1.0,
#     ) -> None:
#         self.layer_name = layer_name
#         self.conv_shape = conv_shape
#         self.hardware = hardware
#         self.tile = tile
#         self.act_density = act_density
#         self.filter_density = filter_density

#     @property
#     def hardware(self) -> TrIPHardwareParam:
#         return self._hardware

#     @hardware.setter
#     def hardware(self, hardware_param: TrIPHardwareParam) -> None:
#         assert isinstance(hardware_param, TrIPHardwareParam)
#         self._hardware = hardware_param

#     @property
#     def conv_shape(self) -> Conv2DShapeParam:
#         return self._conv_shape

#     @conv_shape.setter
#     def conv_shape(self, conv_param: Conv2DShapeParam) -> None:
#         assert isinstance(conv_param, Conv2DShapeParam)
#         self._conv_shape = conv_param

#     @property
#     def maxpool_shape(self) -> MaxPool2DShapeParam:
#         return self._maxpool_shape

#     @maxpool_shape.setter
#     def maxpool_shape(self, maxpool_param: MaxPool2DShapeParam | None) -> None:
#         assert isinstance(maxpool_param, (MaxPool2DShapeParam, type(None)))
#         self._maxpool_shape = maxpool_param

#     @property
#     def tiling(self) -> TrIPTilingParam:
#         return self._tile

#     @tiling.setter
#     def tiling(self, tiling_param: TrIPTilingParam) -> None:
#         self._tile = tiling_param

#     @property
#     def pe_count(self) -> int:
#         return self.hardware.pe_array_h * self.hardware.pe_array_w

#     @property
#     def m_gemm(self) -> int:
#         return self.conv_shape.N * self.conv_shape.E * self.conv_shape.F

#     @property
#     def k_gemm(self) -> int:
#         return self.conv_shape.C * self.conv_shape.R * self.conv_shape.S

#     @property
#     def n_gemm(self) -> int:
#         return self.conv_shape.M

#     @property
#     def dense_macs(self) -> int:
#         return self.m_gemm * self.n_gemm * self.k_gemm

#     @property
#     def effectual_macs(self) -> float:
#         return self.dense_macs * self.act_density * self.filter_density

#     @property
#     def macs_per_layer(self) -> float:
#         return self.effectual_macs

#     @property
#     def compute_cycles(self) -> int:
#         return ceil(self.effectual_macs / self.peak_performance)

#     @property
#     def glb_usage_per_tile(self) -> dict[str, int]:
#         sizes: dict[str, int] = {}
        
#         bitmask_m_overhead = self.tile.tile_m * ceil(self.tile.tile_k / 8)
#         bitmask_n_overhead = self.tile.tile_n * ceil(self.tile.tile_k / 8)

#         sizes["ifmap"] = ceil(self.tile.tile_m * self.tile.tile_k * DATA_SIZE * self.act_density) + bitmask_m_overhead
#         sizes["filter"] = ceil(self.tile.tile_k * self.tile.tile_n * DATA_SIZE * self.filter_density) + bitmask_n_overhead
#         sizes["psum"] = self.tile.tile_m * self.tile.tile_n * PSUM_DATA_SIZE
        
#         sizes["total"] = sizes["ifmap"] + sizes["filter"] + sizes["psum"]
#         return sizes

#     @property
#     def glb_access_per_layer(self) -> dict[str, int]:
#         res: dict[str, int] = {}
        
#         num_m_tiles = ceil(self.m_gemm / self.tile.tile_m)
#         num_n_tiles = ceil(self.n_gemm / self.tile.tile_n)
#         num_k_tiles = ceil(self.k_gemm / self.tile.tile_k)
#         num_tiles = num_m_tiles * num_n_tiles * num_k_tiles 
        
#         tile_usage = self.glb_usage_per_tile
        
#         res["ifmap_read"] = num_tiles * tile_usage["ifmap"]
#         res["filter_read"] = num_tiles * tile_usage["filter"]
#         res["bias_read"] = num_m_tiles * num_n_tiles * self.tile.tile_n * PSUM_DATA_SIZE
#         res["psum_read_conv"] = num_m_tiles * num_n_tiles * (num_k_tiles - 1) * self.tile.tile_m * self.tile.tile_n * PSUM_DATA_SIZE
#         res["psum_write_conv"] = num_tiles * tile_usage["psum"]
#         res["psum_read_pool"] = num_m_tiles * num_n_tiles * self.tile.tile_m * self.tile.tile_n * PSUM_DATA_SIZE
        
#         if self.maxpool_shape is None:
#             out_h, out_w = self.conv_shape.E, self.conv_shape.F
#         else:
#             out_h = (self.conv_shape.E - self.maxpool_shape.kernel_size) // self.maxpool_shape.stride + 1
#             out_w = (self.conv_shape.F - self.maxpool_shape.kernel_size) // self.maxpool_shape.stride + 1
            
#         res["ofmap_write_pool"] = self.conv_shape.N * self.conv_shape.M * out_h * out_w * DATA_SIZE
#         res["psum_read"] = res["psum_read_conv"] + res["psum_read_pool"]
#         res["psum_write"] = res["psum_write_conv"]
#         res["read"] = res["ifmap_read"] + res["filter_read"] + res["bias_read"] + res["psum_read"]
#         res["write"] = res["psum_write"] + res["ofmap_write_pool"]
#         res["total"] = res["read"] + res["write"]
#         return res

#     @property
#     def dram_access_per_layer(self) -> dict[str, int]:
#         res: dict[str, int] = {}

#         num_m_tiles = ceil(self.m_gemm / self.tile.tile_m)
#         num_k_tiles = ceil(self.k_gemm / self.tile.tile_k)
#         num_n_tiles = ceil(self.n_gemm / self.tile.tile_n)

#         ifmap_read = 0
#         filter_read = 0
#         bias_read = 0

#         for mi in range(num_m_tiles):
#             tm = min(self.tile.tile_m, self.m_gemm - mi * self.tile.tile_m)
#             for ki in range(num_k_tiles):
#                 tk = min(self.tile.tile_k, self.k_gemm - ki * self.tile.tile_k)
#                 ifmap_read += ceil(tm * tk * DATA_SIZE * self.act_density) + (tm * ceil(tk / 8))

#                 for ni in range(num_n_tiles):
#                     tn = min(self.tile.tile_n, self.n_gemm - ni * self.tile.tile_n)
#                     filter_read += ceil(tk * tn * DATA_SIZE * self.filter_density) + (tn * ceil(tk / 8))

#         for mi in range(num_m_tiles):
#             for ni in range(num_n_tiles):
#                 tn = min(self.tile.tile_n, self.n_gemm - ni * self.tile.tile_n)
#                 bias_read += tn * PSUM_DATA_SIZE

#         res["ifmap_read"] = ifmap_read
#         res["filter_read"] = filter_read
#         res["bias_read"] = bias_read
#         res["psum_read"] = 0
#         res["psum_write"] = 0

#         if self.maxpool_shape is None:
#             out_h, out_w = self.conv_shape.E, self.conv_shape.F
#         else:
#             out_h = (self.conv_shape.E - self.maxpool_shape.kernel_size) // self.maxpool_shape.stride + 1
#             out_w = (self.conv_shape.F - self.maxpool_shape.kernel_size) // self.maxpool_shape.stride + 1

#         res["ofmap_write"] = self.conv_shape.N * self.conv_shape.M * out_h * out_w * DATA_SIZE
#         res["read"] = res["ifmap_read"] + res["filter_read"] + res["bias_read"] + res["psum_read"]
#         res["write"] = res["psum_write"] + res["ofmap_write"]
#         res["total"] = res["read"] + res["write"]

#         return res

#     @property
#     def latency_per_layer(self) -> int:
#         return max(self.compute_cycles, self.memory_cycles) + self.ppu_latency_per_layer

#     @property
#     def dense_ifmap_bytes(self) -> int:
#         return (
#             self.conv_shape.N
#             * self.conv_shape.C
#             * self.conv_shape.H
#             * self.conv_shape.W
#             * DATA_SIZE
#         )

#     @property
#     def dense_weight_bytes(self) -> int:
#         return (
#             self.conv_shape.M
#             * self.conv_shape.C
#             * self.conv_shape.R
#             * self.conv_shape.S
#             * DATA_SIZE
#         )

#     @property
#     def dense_bias_bytes(self) -> int:
#         return self.conv_shape.M * PSUM_DATA_SIZE

#     @property
#     def dense_psum_bytes(self) -> int:
#         return (
#             self.conv_shape.N
#             * self.conv_shape.M
#             * self.conv_shape.E
#             * self.conv_shape.F
#             * PSUM_DATA_SIZE
#         )

#     @property
#     def ppu_latency_per_layer(self) -> int:
#         ofmap_size = (
#             self.conv_shape.N
#             * self.conv_shape.M
#             * self.conv_shape.E
#             * self.conv_shape.F
#         )
#         ppu_latency_per_elem = 1 if self.maxpool_shape is None else 5
#         return ofmap_size * ppu_latency_per_elem

#     @property
#     def compute_cycles(self) -> int:
#         return ceil(self.macs_per_layer / self.peak_performance)

#     @property
#     def memory_cycles(self) -> int:
#         glb_cycles = ceil(
#             self.glb_access_per_layer["total"] * GLB_ACCESS_TIME / self.hardware.noc_bw
#         )
#         dram_cycles = ceil(
#             self.dram_access_per_layer["total"]
#             * DRAM_ACCESS_TIME
#             / self.hardware.bus_bw
#         )
#         return glb_cycles + dram_cycles

#     @property
#     def total_cycles_dense(self) -> int:
#         return max(self.compute_cycles, self.memory_cycles) + self.ppu_latency_per_layer

#     @property
#     def dense_bound_by(self) -> str:
#         if self.compute_cycles > self.memory_cycles:
#             return "compute"
#         if self.compute_cycles < self.memory_cycles:
#             return "memory"
#         return "balanced"

#     @property
#     def energy_per_layer(self) -> dict[str, float]:
#         compute_energy = self.macs_per_layer * ENERGY_PER_MAC
#         memory_energy = (
#             self.glb_access_per_layer["total"] * ENERGY_PER_GLB_ACCESS
#             + self.dram_access_per_layer["total"] * ENERGY_PER_DRAM_ACCESS
#         )
#         leakage_energy = POWER_LEAKAGE * self.latency_per_layer / CLOCK_RATE
#         total_energy = compute_energy + memory_energy + leakage_energy
#         return {
#             "compute": compute_energy,
#             "memory": memory_energy,
#             "leakage": leakage_energy,
#             "total": total_energy,
#         }

#     @property
#     def power_per_layer(self) -> dict[str, float]:
#         compute_power = (
#             self.energy_per_layer["compute"] / self.latency_per_layer * CLOCK_RATE
#         )
#         memory_power = (
#             self.energy_per_layer["memory"] / self.latency_per_layer * CLOCK_RATE
#         )
#         leakage_power = POWER_LEAKAGE
#         total_power = compute_power + memory_power + leakage_power
#         return {
#             "compute": compute_power,
#             "memory": memory_power,
#             "leakage": leakage_power,
#             "total": total_power,
#         }

#     @property
#     def operational_intensity(self) -> float:
#         return self.macs_per_layer / self.dram_access_per_layer["total"]

#     @property
#     def peak_performance(self) -> float:
#         return self.hardware.pe_array_h * self.hardware.pe_array_w  # MACs per cycle

#     @property
#     def peak_bandwidth(self) -> float:
#         return self.hardware.bus_bw  # bytes per cycle

#     @property
#     def bound_by(self) -> str:
#         machine_blance_point = self.peak_performance / self.peak_bandwidth
#         if self.operational_intensity > machine_blance_point:
#             return "compute"
#         elif self.operational_intensity < machine_blance_point:
#             return "memory"
#         else:
#             return "balanced"

#     @property
#     def is_compute_bound(self) -> bool:
#         return self.bound_by == "compute"

#     @property
#     def is_memory_bound(self) -> bool:
#         return self.bound_by == "memory"

#     @property
#     def is_balanced(self) -> bool:
#         return self.bound_by == "balanced"
    
#     @property
#     def summary(self) -> AnalysisResult:  # 這裡也可以依照你原本的 AnalysisResult Type Hint
#         if not hasattr(self, "mode"):
#             self.mode = None

#         # 先計算並暫存，避免在字典裡重複呼叫消耗效能
#         glb_access = self.glb_access_per_layer
#         dram_compulsory = self.dram_access_compulsory_per_layer
#         dram_tiled = self.dram_access_per_layer
#         return {
#             "layer": self.layer_name,  # 修正為 layer_name
#             "glb_usage": self.glb_usage_per_tile["total"],  # 更新為 glb_usage_per_tile

#             # GLB Access (從暫存的字典抓取)
#             "glb_ifmap_read": glb_access["ifmap_read"],  
#             "glb_filter_read": glb_access["filter_read"],  
#             "glb_bias_read": glb_access["bias_read"],  
#             "glb_psum_read_conv": glb_access["psum_read_conv"],  
#             "glb_psum_read_pool": glb_access["psum_read_pool"],  
#             "glb_psum_read": glb_access["psum_read"],  
#             "glb_psum_write_conv": glb_access["psum_write_conv"],  
#             "glb_ofmap_write_pool": glb_access["ofmap_write_pool"],  
#             "glb_psum_write": glb_access["psum_write"],  
#             "glb_read": glb_access["read"],  
#             "glb_write": glb_access["write"],  
#             "glb_access": glb_access["total"],  

#             # DRAM Access (從暫存的 property 抓取)
#             "dram_compulsory_ifmap_read": dram_compulsory["ifmap_read"],
#             "dram_compulsory_filter_read": dram_compulsory["filter_read"],
#             "dram_compulsory_bias_read": dram_compulsory["bias_read"],
#             "dram_compulsory_ofmap_write": dram_compulsory["ofmap_write"],
#             "dram_compulsory_total": dram_compulsory["total"],

#             "dram_ifmap_read": dram_tiled["ifmap_read"],
#             "dram_filter_read": dram_tiled["filter_read"],
#             "dram_bias_read": dram_tiled["bias_read"],
#             "dram_psum_read": dram_tiled["psum_read"],
#             "dram_psum_write": dram_tiled["psum_write"],
#             "dram_ofmap_write": dram_tiled["ofmap_write"],
#             "dram_total": dram_tiled["total"],
            
#             # 其他 Metrics
#             "macs": self.macs_per_layer,
#             "dense_macs": self.macs_per_layer,
#             "dense_ifmap_bytes": self.dense_ifmap_bytes,
#             "dense_weight_bytes": self.dense_weight_bytes,
#             "dense_bias_bytes": self.dense_bias_bytes,
#             "dense_psum_bytes": self.dense_psum_bytes,
#             "compute_cycles": self.compute_cycles,
#             "memory_cycles": self.memory_cycles,
#             "total_cycles_dense": self.total_cycles_dense,
#             "latency": self.latency_per_layer,  
#             "energy_total": self.energy_per_layer["total"],  
#             "power_total": self.power_per_layer["total"],  
            
#             # Hardware & Roofline Info
#             "peak_performance": self.peak_performance,
#             "peak_bandwidth": self.peak_bandwidth,
#             "intensity": self.operational_intensity,
#             "operational_intensity": self.operational_intensity,
#             "bound_by": self.dense_bound_by,
#         }