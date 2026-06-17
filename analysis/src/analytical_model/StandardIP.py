from __future__ import annotations

from dataclasses import dataclass
from math import ceil
from typing import Optional, Union

from layer_info import Conv2DShapeParam, MaxPool2DShapeParam

# Memory
DATA_SIZE = 1  # Byte
PSUM_DATA_SIZE = 4  # Byte
BUS_BANDWIDTH = 4  # Byte

# Time
CLOCK_RATE = 200 * 1e6  # 200 MHz
TIME_UNIT = 1  # cycle
SPAD_ACCESS_TIME = 1 * TIME_UNIT
GLB_ACCESS_TIME = 2 * TIME_UNIT
DRAM_ACCESS_TIME = 5 * TIME_UNIT

# Energy
ENERGY_UNIT = 1e-6  # 1 pJ = 10^6 uJ
ENERGY_PER_MAC = 2 * ENERGY_UNIT
ENERGY_PER_GLB_ACCESS = 10 * ENERGY_UNIT
ENERGY_PER_DRAM_ACCESS = 200 * ENERGY_UNIT
POWER_UNIT = 1  # 1 uW
POWER_LEAKAGE = 50 * POWER_UNIT
######################################################################################################
# N: number of ifmaps/ofmaps
# M: number of filters
# H/W: ifmap height/width
# R/S: filter height/width
# E/F: ofmap height/width
# U: stride
######################################################################################################
@dataclass
class StandardIPHardwareParam:
    pe_array_h: int 
    pe_array_w: int 
    glb_size: int
    bus_bw: int
    noc_bw: int

@dataclass
class StandardIPTilingParam:
    tile_m: int 
    tile_n: int 
    tile_k: int

AnalysisResult = dict[str, Union[str, int, float]]

class StandardIPAnalyzer:
    """Standard-IP dense GEMManalytical model.

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
        hardware: StandardIPHardwareParam,
        tile: StandardIPTilingParam,
    ) -> None:
        self.layer_name = layer_name
        self.conv_shape = conv_shape
        self.hardware = hardware
        self.tiling = tile
        self.maxpool_shape = None

    @property
    def hardware(self) -> StandardIPHardwareParam:
        return self._hardware

    @hardware.setter
    def hardware(self, hardware_param: StandardIPHardwareParam) -> None:
        assert isinstance(hardware_param, StandardIPHardwareParam)
        self._hardware = hardware_param

    @property
    def conv_shape(self) -> Conv2DShapeParam:
        return self._conv_shape

    @conv_shape.setter
    def conv_shape(self, conv_param: Conv2DShapeParam) -> None:
        assert isinstance(conv_param, Conv2DShapeParam)
        self._conv_shape = conv_param

    @property
    def maxpool_shape(self) -> MaxPool2DShapeParam:
        return self._maxpool_shape

    @maxpool_shape.setter
    def maxpool_shape(self, maxpool_param: MaxPool2DShapeParam | None) -> None:
        assert isinstance(maxpool_param, (MaxPool2DShapeParam, type(None)))
        self._maxpool_shape = maxpool_param

    @property
    def tiling(self) -> StandardIPTilingParam:
        return self._tile

    @tiling.setter
    def tiling(self, tiling_param: StandardIPTilingParam) -> None:
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
    def min_glb_breakdown(self) -> dict[str, int]:
        activation = self.tile.tile_m * self.tile.tile_k * DATA_SIZE
        filter_tile = self.tile.tile_k * self.tile.tile_n * DATA_SIZE
        psum = self.tile.tile_m * self.n_gemm * PSUM_DATA_SIZE
        total = activation + filter_tile + psum
        return {
            "activation": activation,
            "activation_bitmask": 0,
            "filter": filter_tile,
            "filter_bitmask": 0,
            "psum": psum,
            "total": total,
        }

    @property
    def enough_glb_breakdown(self) -> dict[str, int]:
        activation = self.tile.tile_m * self.tile.tile_k * DATA_SIZE
        full_filter = self.k_gemm * self.n_gemm * DATA_SIZE
        psum = self.tile.tile_m * self.n_gemm * PSUM_DATA_SIZE
        total = activation + full_filter + psum
        return {
            "activation": activation,
            "activation_bitmask": 0,
            "filter": full_filter,
            "filter_bitmask": 0,
            "psum": psum,
            "total": total,
        }

    @property
    def min_glb_size(self) -> int:
        return self.min_glb_breakdown["total"]

    @property
    def enough_glb_size(self) -> int:
        return self.enough_glb_breakdown["total"]

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
        sizes = self.min_glb_breakdown.copy()
        sizes["ifmap"] = sizes["activation"]
        sizes["filter"] = sizes["filter"] + sizes["filter_bitmask"]
        sizes["psum"] = sizes["psum"]
        sizes["total"] = sizes["total"]
        return sizes
    
    @property
    def glb_access_per_layer(self) -> dict[str, int]:
        from math import ceil
        res: dict[str, int] = {}
        
        # 計算各個維度切出來的 Tile 數量
        num_m_tiles = ceil(self.m_gemm / self.tile.tile_m)
        num_n_tiles = ceil(self.n_gemm / self.tile.tile_n)
        num_k_tiles = ceil(self.k_gemm / self.tile.tile_k)
        num_tiles = num_m_tiles * num_n_tiles * num_k_tiles 
        
        # 每個 Pass 都從 GLB 載入到 Spad (以 Tile size 為單位計算)
        res["ifmap_read"] = num_tiles * self.tile.tile_m * self.tile.tile_k * DATA_SIZE
        res["filter_read"] = num_tiles * self.tile.tile_k * self.tile.tile_n * DATA_SIZE
        
        # Bias 只在每組 (M, N) 開始算第一圈 k=0 時讀取
        res["bias_read"] = num_m_tiles * num_n_tiles * self.tile.tile_n * PSUM_DATA_SIZE
        
        # 第一圈 k == 0 的時候不讀 Psum (由 Bias 初始化)，所以扣掉一圈 (num_k_tiles - 1)
        res["psum_read_conv"] = num_m_tiles * num_n_tiles * (num_k_tiles - 1) * self.tile.tile_m * self.tile.tile_n * PSUM_DATA_SIZE
        
        # 每一圈 Pass 都會把算完的 Psum 寫回 GLB
        res["psum_write_conv"] = num_tiles * self.tile.tile_m * self.tile.tile_n * PSUM_DATA_SIZE
        
        # PPU 階段：Requant, ReLU, MaxPool
        # 讀出完整 32-bit 的 Psum 做處理 (所有 (M, N) Tiles 的最終輸出)
        res["psum_read_pool"] = num_m_tiles * num_n_tiles * self.tile.tile_m * self.tile.tile_n * PSUM_DATA_SIZE
        
        if self.maxpool_shape is None:
            out_h = self.conv_shape.E
            out_w = self.conv_shape.F
        else:
            out_h = (self.conv_shape.E - self.maxpool_shape.kernel_size) // self.maxpool_shape.stride + 1
            out_w = (self.conv_shape.F - self.maxpool_shape.kernel_size) // self.maxpool_shape.stride + 1
            
        # PPU 處理完後轉 8-bit 寫回
        res["ofmap_write_pool"] = self.conv_shape.N * self.conv_shape.M * out_h * out_w * DATA_SIZE
        
        res["psum_read"] = res["psum_read_conv"] + res["psum_read_pool"]
        res["psum_write"] = res["psum_write_conv"]
        
        res["read"] = res["ifmap_read"] + res["filter_read"] + res["bias_read"] + res["psum_read"]
        res["write"] = res["psum_write"] + res["ofmap_write_pool"]
        res["total"] = res["read"] + res["write"]
        return res

    @property
    def dram_access_compulsory_per_layer(self) -> dict[str, int]:
        """
        Ideal compulsory DRAM traffic.

        This is the lower bound of DRAM traffic:
        - ifmap is read once from DRAM
        - weight is read once from DRAM
        - bias is read once from DRAM
        - final ofmap is written once to DRAM

        It does not include repeated filter reloads caused by GLB capacity
        or tiling loop order.
        """
        res: dict[str, int] = {}

        res["ifmap_read"] = self.dense_ifmap_bytes
        res["filter_read"] = self.dense_weight_bytes
        res["bias_read"] = self.dense_bias_bytes

        if self.maxpool_shape is None:
            out_h = self.conv_shape.E
            out_w = self.conv_shape.F
        else:
            out_h = (
                self.conv_shape.E - self.maxpool_shape.kernel_size
            ) // self.maxpool_shape.stride + 1
            out_w = (
                self.conv_shape.F - self.maxpool_shape.kernel_size
            ) // self.maxpool_shape.stride + 1

        res["ofmap_write"] = (
            self.conv_shape.N
            * self.conv_shape.M
            * out_h
            * out_w
            * DATA_SIZE
        )

        # In this ideal model, psum is assumed to stay on-chip.
        res["psum_read"] = 0
        res["psum_write"] = 0

        res["read"] = (
            res["ifmap_read"]
            + res["filter_read"]
            + res["bias_read"]
            + res["psum_read"]
        )
        res["write"] = res["ofmap_write"] + res["psum_write"]
        res["total"] = res["read"] + res["write"]

        return res

    @property
    def dram_access_per_layer(self) -> dict[str, int]:
        """
        Tiled DRAM traffic using activation-stationary-ish loop order.

        Loop order:
            for m_tile:
                for k_tile:
                    load A tile once
                    for n_tile:
                        load B tile
                        compute

        GEMM definition:
            A / ifmap : [M_gemm, K_gemm]
            B / weight: [K_gemm, N_gemm]
            C / psum  : [M_gemm, N_gemm]

        Assumptions:
        - GLB can hold activation tile and psum tile.
        - Psum is accumulated on-chip across k tiles, so no intermediate
            psum DRAM read/write is needed.
        - Filter tile may not be fully cached across m tiles, so B / weight
            is loaded for every (m_tile, k_tile, n_tile) compute pass.
        - Final output is written once after all k tiles are accumulated.
        """
        res: dict[str, int] = {}

        num_m_tiles = ceil(self.m_gemm / self.tile.tile_m)
        num_k_tiles = ceil(self.k_gemm / self.tile.tile_k)
        num_n_tiles = ceil(self.n_gemm / self.tile.tile_n)

        ifmap_read = 0
        filter_read = 0
        bias_read = 0
        psum_read = 0
        psum_write = 0

        # Case B:
        # for m_tile:
        #   for k_tile:
        #     load A tile once
        #     for n_tile:
        #       load B tile
        #       compute
        for mi in range(num_m_tiles):
            tm = min(
                self.tile.tile_m,
                self.m_gemm - mi * self.tile.tile_m,
            )

            for ki in range(num_k_tiles):
                tk = min(
                    self.tile.tile_k,
                    self.k_gemm - ki * self.tile.tile_k,
                )

                # Activation tile A[m, k] is loaded once for this (m_tile, k_tile),
                # then reused across all n_tiles.
                ifmap_read += tm * tk * DATA_SIZE

                for ni in range(num_n_tiles):
                    tn = min(
                        self.tile.tile_n,
                        self.n_gemm - ni * self.tile.tile_n,
                    )

                    # Weight tile B[k, n] is loaded for each n_tile under this
                    # m_tile and k_tile. Since the GLB may not hold all filters,
                    # the same filter tile can be reloaded when m_tile changes.
                    filter_read += tk * tn * DATA_SIZE

        # Bias initializes each output channel for each output tile.
        # Since C tile is [tile_m, tile_n], bias length is tile_n.
        for mi in range(num_m_tiles):
            for ni in range(num_n_tiles):
                tn = min(
                    self.tile.tile_n,
                    self.n_gemm - ni * self.tile.tile_n,
                )
                bias_read += tn * PSUM_DATA_SIZE

        # Psum is assumed to stay on-chip across k tiles.
        # Therefore, no intermediate DRAM psum traffic.
        psum_read = 0
        psum_write = 0

        if self.maxpool_shape is None:
            out_h = self.conv_shape.E
            out_w = self.conv_shape.F
        else:
            out_h = (
                self.conv_shape.E - self.maxpool_shape.kernel_size
            ) // self.maxpool_shape.stride + 1
            out_w = (
                self.conv_shape.F - self.maxpool_shape.kernel_size
            ) // self.maxpool_shape.stride + 1

        ofmap_write = (
            self.conv_shape.N
            * self.conv_shape.M
            * out_h
            * out_w
            * DATA_SIZE
        )

        res["ifmap_read"] = ifmap_read
        res["filter_read"] = filter_read
        res["bias_read"] = bias_read
        res["psum_read"] = psum_read
        res["psum_write"] = psum_write
        res["ofmap_write"] = ofmap_write

        res["read"] = (
            res["ifmap_read"]
            + res["filter_read"]
            + res["bias_read"]
            + res["psum_read"]
        )
        res["write"] = res["psum_write"] + res["ofmap_write"]
        res["total"] = res["read"] + res["write"]

        return res

    @property
    def latency_per_layer(self) -> int:
        return max(self.compute_cycles, self.memory_cycles) + self.ppu_latency_per_layer

    @property
    def macs_per_layer(self) -> int:
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
            * DATA_SIZE
        )

    @property
    def dense_weight_bytes(self) -> int:
        return (
            self.conv_shape.M
            * self.conv_shape.C
            * self.conv_shape.R
            * self.conv_shape.S
            * DATA_SIZE
        )

    @property
    def dense_bias_bytes(self) -> int:
        return self.conv_shape.M * PSUM_DATA_SIZE

    @property
    def dense_psum_bytes(self) -> int:
        return (
            self.conv_shape.N
            * self.conv_shape.M
            * self.conv_shape.E
            * self.conv_shape.F
            * PSUM_DATA_SIZE
        )

    @property
    def ppu_latency_per_layer(self) -> int:
        ofmap_size = (
            self.conv_shape.N
            * self.conv_shape.M
            * self.conv_shape.E
            * self.conv_shape.F
        )
        ppu_latency_per_elem = 1 if self.maxpool_shape is None else 5
        return ofmap_size * ppu_latency_per_elem

    @property
    def compute_cycles(self) -> int:
        return ceil(self.macs_per_layer / self.peak_performance)

    @property
    def memory_cycles(self) -> int:
        glb_cycles = ceil(
            self.glb_access_per_layer["total"] * GLB_ACCESS_TIME / self.hardware.noc_bw
        )
        dram_cycles = ceil(
            self.dram_access_per_layer["total"]
            * DRAM_ACCESS_TIME
            / self.hardware.bus_bw
        )
        return glb_cycles + dram_cycles

    @property
    def total_cycles_dense(self) -> int:
        return max(self.compute_cycles, self.memory_cycles) + self.ppu_latency_per_layer

    @property
    def dense_bound_by(self) -> str:
        if self.compute_cycles > self.memory_cycles:
            return "compute"
        if self.compute_cycles < self.memory_cycles:
            return "memory"
        return "balanced"

    @property
    def energy_per_layer(self) -> dict[str, float]:
        compute_energy = self.macs_per_layer * ENERGY_PER_MAC
        memory_energy = (
            self.glb_access_per_layer["total"] * ENERGY_PER_GLB_ACCESS
            + self.dram_access_per_layer["total"] * ENERGY_PER_DRAM_ACCESS
        )
        leakage_energy = POWER_LEAKAGE * self.latency_per_layer / CLOCK_RATE
        total_energy = compute_energy + memory_energy + leakage_energy
        return {
            "compute": compute_energy,
            "memory": memory_energy,
            "leakage": leakage_energy,
            "total": total_energy,
        }

    @property
    def power_per_layer(self) -> dict[str, float]:
        compute_power = (
            self.energy_per_layer["compute"] / self.latency_per_layer * CLOCK_RATE
        )
        memory_power = (
            self.energy_per_layer["memory"] / self.latency_per_layer * CLOCK_RATE
        )
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
        return self.macs_per_layer / self.dram_access_per_layer["total"]

    @property
    def peak_performance(self) -> float:
        return self.hardware.pe_array_h * self.hardware.pe_array_w  # MACs per cycle

    @property
    def peak_bandwidth(self) -> float:
        return self.hardware.bus_bw  # bytes per cycle

    @property
    def bound_by(self) -> str:
        machine_blance_point = self.peak_performance / self.peak_bandwidth
        if self.operational_intensity > machine_blance_point:
            return "compute"
        elif self.operational_intensity < machine_blance_point:
            return "memory"
        else:
            return "balanced"

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
    def summary(self) -> AnalysisResult:  # 這裡也可以依照你原本的 AnalysisResult Type Hint
        if not hasattr(self, "mode"):
            self.mode = None

        # 先計算並暫存，避免在字典裡重複呼叫消耗效能
        glb_access = self.glb_access_per_layer
        dram_compulsory = self.dram_access_compulsory_per_layer
        dram_tiled = self.dram_access_per_layer
        min_glb = self.min_glb_breakdown
        enough_glb = self.enough_glb_breakdown
        dram_actual_total = dram_tiled["total"]
        oi_compulsory = self.macs_per_layer / dram_compulsory["total"] if dram_compulsory["total"] else 0.0
        oi_actual = self.macs_per_layer / dram_actual_total if dram_actual_total else 0.0
        balance_point = self.peak_performance / self.peak_bandwidth if self.peak_bandwidth else float("inf")

        def roofline_bound(intensity: float) -> str:
            if intensity > balance_point:
                return "compute"
            if intensity < balance_point:
                return "memory"
            return "balanced"

        return {
            "layer": self.layer_name,  # 修正為 layer_name
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
            "enough_glb_activation_bytes": enough_glb["activation"],
            "enough_glb_filter_bytes": enough_glb["filter"],
            "enough_glb_psum_bytes": enough_glb["psum"],
            "enough_glb_size": enough_glb["total"],
            "glb_meets_min": self.glb_meets_min,
            "glb_meets_enough": self.glb_meets_enough,
            "filter_fits_in_glb": self.filter_fits_in_glb,
            "glb_usage_per_tile": self.glb_usage_per_tile["total"],  # min resident footprint

            # GLB Access (從暫存的字典抓取)
            "glb_ifmap_read": glb_access["ifmap_read"],  
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

            # DRAM Access (從暫存的 property 抓取)
            "dram_compulsory_ifmap_read": dram_compulsory["ifmap_read"],
            "dram_compulsory_filter_read": dram_compulsory["filter_read"],
            "dram_compulsory_bias_read": dram_compulsory["bias_read"],
            "dram_compulsory_ofmap_write": dram_compulsory["ofmap_write"],
            "dram_compulsory_total": dram_compulsory["total"],

            "dram_ifmap_read": dram_tiled["ifmap_read"],
            "dram_filter_read": dram_tiled["filter_read"],
            "dram_bias_read": dram_tiled["bias_read"],
            "dram_psum_read": dram_tiled["psum_read"],
            "dram_psum_write": dram_tiled["psum_write"],
            "dram_ofmap_write": dram_tiled["ofmap_write"],
            "dram_total": dram_tiled["total"],
            "dram_actual_total": dram_actual_total,
            "oi_compulsory": oi_compulsory,
            "oi_actual": oi_actual,
            "bound_by_compulsory": roofline_bound(oi_compulsory),
            "bound_by_actual": roofline_bound(oi_actual),
            
            # 其他 Metrics
            "macs": self.macs_per_layer,
            "dense_macs": self.macs_per_layer,
            "dense_ifmap_bytes": self.dense_ifmap_bytes,
            "dense_weight_bytes": self.dense_weight_bytes,
            "dense_bias_bytes": self.dense_bias_bytes,
            "dense_psum_bytes": self.dense_psum_bytes,
            "compute_cycles": self.compute_cycles,
            "memory_cycles": self.memory_cycles,
            "total_cycles_dense": self.total_cycles_dense,
            "latency": self.latency_per_layer,  
            "energy_total": self.energy_per_layer["total"],  
            "power_total": self.power_per_layer["total"],  
            
            # Hardware & Roofline Info
            "peak_performance": self.peak_performance,
            "peak_bandwidth": self.peak_bandwidth,
            "intensity": oi_actual,
            "operational_intensity": oi_actual,
            "bound_by": roofline_bound(oi_actual),
        }