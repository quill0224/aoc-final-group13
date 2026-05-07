"""Eyeriss-style per-layer analytical model (lifted from AOC Lab 2).

Conventions
-----------
*_per_pass  : one PE-array execution unit (one set of m / n / e / p / q / r / t)
*_per_layer : aggregate over all passes that cover a single Conv2D layer
"""

from __future__ import annotations

from dataclasses import dataclass
from math import ceil

from .layer_info import Conv2DShapeParam, MaxPool2DShapeParam

# Memory
DATA_SIZE = 1  # Byte (int8)
PSUM_DATA_SIZE = 4  # Byte (int32)
BUS_BANDWIDTH = 4  # Byte/cycle

# Time (in cycles)
CLOCK_RATE = 200 * 1e6  # 200 MHz
TIME_UNIT = 1
SPAD_ACCESS_TIME = 1 * TIME_UNIT
GLB_ACCESS_TIME = 2 * TIME_UNIT
DRAM_ACCESS_TIME = 5 * TIME_UNIT

# Energy
ENERGY_UNIT = 1e-6  # 1 pJ = 1e-6 uJ
ENERGY_PER_MAC = 2 * ENERGY_UNIT
ENERGY_PER_GLB_ACCESS = 10 * ENERGY_UNIT
ENERGY_PER_DRAM_ACCESS = 200 * ENERGY_UNIT
POWER_UNIT = 1  # 1 uW
POWER_LEAKAGE = 50 * POWER_UNIT


@dataclass
class EyerissHardwareParam:
    pe_array_h: int
    pe_array_w: int
    ifmap_spad_size: int
    filter_spad_size: int
    psum_spad_size: int
    glb_size: int
    bus_bw: int
    noc_bw: int


@dataclass
class EyerissMappingParam:
    m: int  # ofmap channels in GLB
    n: int  # ifmap batch per pass
    e: int  # PE-set width
    p: int  # filters per PE set
    q: int  # ifmap/filter channels per PE set
    r: int  # PE sets for different channels
    t: int  # PE sets for different filters


AnalysisResult = dict[str, "str | int | float"]


class EyerissAnalyzer:
    cnt = 0

    def __init__(
        self,
        name: str | None = None,
        hardware_param: EyerissHardwareParam | None = None,
    ) -> None:
        self.name = name if name is not None else f"mapping_{EyerissAnalyzer.cnt}"
        self._hardware = hardware_param
        self._conv_shape: Conv2DShapeParam | None = None
        self._maxpool_shape: MaxPool2DShapeParam | None = None
        self._mapping: EyerissMappingParam | None = None
        self.mode = None
        EyerissAnalyzer.cnt += 1

    @property
    def hardware(self) -> EyerissHardwareParam:
        return self._hardware

    @hardware.setter
    def hardware(self, hardware_param: EyerissHardwareParam) -> None:
        assert isinstance(hardware_param, EyerissHardwareParam)
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
    def mapping(self) -> EyerissMappingParam:
        return self._mapping

    @mapping.setter
    def mapping(self, mapping_param: EyerissMappingParam) -> None:
        self._mapping = mapping_param

    # ----- Scratchpad -----
    def filter_used(self) -> int:
        return self.mapping.q * self.conv_shape.S * self.mapping.p

    def ifmap_used(self) -> int:
        return self.mapping.q * self.conv_shape.S

    def psum_used(self) -> int:
        return self.mapping.p

    @property
    def spad_size_legal(self) -> dict[str, bool]:
        return {
            "ifmap": self.ifmap_used() <= self.hardware.ifmap_spad_size,
            "filter": self.filter_used() <= self.hardware.filter_spad_size,
            "psum": self.psum_used() <= self.hardware.psum_spad_size,
        }

    @property
    def spad_usage(self) -> dict[str, int]:
        return {
            "ifmap": self.ifmap_used(),
            "filter": self.filter_used(),
            "psum": self.psum_used(),
        }

    # ----- GLB -----
    @property
    def glb_usage_per_pass(self) -> dict[str, int]:
        mp = self.mapping
        cs = self.conv_shape
        sizes: dict[str, int] = {}
        # ifmap: n batch × qr channels × (U(e-1)+R) rows × W cols × DATA_SIZE
        sizes["ifmap"] = mp.n * (mp.q * mp.r) * (cs.U * (mp.e - 1) + cs.R) * cs.W * DATA_SIZE
        # filter: pt filters × qr channels × R × S × DATA_SIZE
        sizes["filter"] = (mp.p * mp.t) * (mp.q * mp.r) * cs.R * cs.S * DATA_SIZE
        # bias: one per filter, 32-bit
        sizes["bias"] = (mp.p * mp.t) * PSUM_DATA_SIZE
        # psum: only segment that grows with m (output-channel tile)
        sizes["psum"] = mp.n * mp.m * mp.e * cs.F * PSUM_DATA_SIZE
        sizes["total"] = sum(sizes.values())
        return sizes

    @property
    def glb_size_legal(self) -> bool:
        return self.glb_usage_per_pass["total"] <= self.hardware.glb_size

    # ----- DRAM accesses -----
    @property
    def dram_access_per_layer(self) -> dict[str, int]:
        mp = self.mapping
        cs = self.conv_shape
        res: dict[str, int] = {}

        num_m = ceil(cs.M / mp.m)
        num_e = ceil(cs.E / mp.e)
        num_n = ceil(cs.N / mp.n)
        num_c = ceil(cs.C / (mp.q * mp.r))
        num_m_inner = ceil(mp.m / (mp.p * mp.t))

        tile_ifmap = mp.n * (mp.q * mp.r) * (cs.U * (mp.e - 1) + cs.R) * cs.W * DATA_SIZE
        res["ifmap_read"] = num_m * num_e * num_n * num_c * tile_ifmap

        tile_filter = (mp.p * mp.t) * (mp.q * mp.r) * cs.R * cs.S * DATA_SIZE
        res["filter_read"] = num_m * num_e * num_n * num_c * num_m_inner * tile_filter

        tile_bias = (mp.p * mp.t) * PSUM_DATA_SIZE
        res["bias_read"] = num_m * num_e * num_n * num_m_inner * tile_bias

        if self.maxpool_shape is not None:
            pool_k = self.maxpool_shape.kernel_size
            ofmap_write = cs.N * cs.M * (cs.E // pool_k) * (cs.F // pool_k) * DATA_SIZE
        else:
            ofmap_write = cs.N * cs.M * cs.E * cs.F * DATA_SIZE
        res["ofmap_write"] = ofmap_write

        res["read"] = res["ifmap_read"] + res["filter_read"] + res["bias_read"]
        res["write"] = res["ofmap_write"]
        res["total"] = res["read"] + res["write"]
        return res

    # ----- GLB accesses (Spad ↔ GLB) -----
    @property
    def glb_access_per_layer(self) -> dict[str, int]:
        mp = self.mapping
        cs = self.conv_shape
        res: dict[str, int] = {}

        num_m = ceil(cs.M / mp.m)
        num_e = ceil(cs.E / mp.e)
        num_n = ceil(cs.N / mp.n)
        num_c = ceil(cs.C / (mp.q * mp.r))
        num_m_inner = ceil(mp.m / (mp.p * mp.t))
        glb_reuse = num_m_inner

        tile_ifmap = mp.n * (mp.q * mp.r) * (cs.U * (mp.e - 1) + cs.R) * cs.W * DATA_SIZE
        res["ifmap_read"] = num_m * num_e * num_n * num_c * glb_reuse * tile_ifmap

        tile_filter = (mp.p * mp.t) * (mp.q * mp.r) * cs.R * cs.S * DATA_SIZE
        res["filter_read"] = num_m * num_e * num_n * num_c * num_m_inner * tile_filter

        tile_bias = (mp.p * mp.t) * PSUM_DATA_SIZE
        res["bias_read"] = num_m * num_e * num_n * num_m_inner * tile_bias

        tile_psum = mp.n * (mp.p * mp.t) * mp.e * cs.F * PSUM_DATA_SIZE
        num_c_minus_first = max(num_c - 1, 0)
        res["psum_read_conv"] = num_m * num_e * num_n * num_c_minus_first * num_m_inner * tile_psum
        res["psum_write_conv"] = num_m * num_e * num_n * num_c * num_m_inner * tile_psum

        if self.maxpool_shape is not None:
            pool_k = self.maxpool_shape.kernel_size
            res["psum_read_pool"] = cs.N * cs.M * cs.E * cs.F * PSUM_DATA_SIZE
            res["ofmap_write_pool"] = cs.N * cs.M * (cs.E // pool_k) * (cs.F // pool_k) * DATA_SIZE
        else:
            res["psum_read_pool"] = cs.N * cs.M * cs.E * cs.F * PSUM_DATA_SIZE
            res["ofmap_write_pool"] = cs.N * cs.M * cs.E * cs.F * DATA_SIZE

        res["psum_read"] = res["psum_read_conv"] + res["psum_read_pool"]
        res["psum_write"] = res["psum_write_conv"] + res["ofmap_write_pool"]
        res["read"] = res["ifmap_read"] + res["filter_read"] + res["bias_read"] + res["psum_read"]
        res["write"] = res["psum_write"]
        res["total"] = res["read"] + res["write"]
        return res

    # ----- Latency / Energy / Power -----
    @property
    def latency_per_layer(self) -> int:
        ofmap_size = self.conv_shape.N * self.conv_shape.M * self.conv_shape.E * self.conv_shape.F
        ppu_latency_per_elem = 1 if self.maxpool_shape is None else 5
        return (
            ceil(self.glb_access_per_layer["total"] * GLB_ACCESS_TIME / self.hardware.noc_bw)
            + ceil(self.dram_access_per_layer["total"] * DRAM_ACCESS_TIME / self.hardware.bus_bw)
            + ofmap_size * ppu_latency_per_elem
        )

    @property
    def macs_per_layer(self) -> int:
        cs = self.conv_shape
        return cs.N * cs.M * cs.E * cs.F * cs.C * cs.R * cs.S

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
        compute_power = self.energy_per_layer["compute"] / self.latency_per_layer * CLOCK_RATE
        memory_power = self.energy_per_layer["memory"] / self.latency_per_layer * CLOCK_RATE
        return {
            "compute": compute_power,
            "memory": memory_power,
            "leakage": POWER_LEAKAGE,
            "total": compute_power + memory_power + POWER_LEAKAGE,
        }

    # ----- Roofline metrics -----
    @property
    def operational_intensity(self) -> float:
        return self.macs_per_layer / self.dram_access_per_layer["total"]

    @property
    def peak_performance(self) -> float:
        return self.hardware.pe_array_h * self.hardware.pe_array_w  # MACs/cycle

    @property
    def peak_bandwidth(self) -> float:
        return self.hardware.bus_bw  # bytes/cycle

    @property
    def bound_by(self) -> str:
        balance = self.peak_performance / self.peak_bandwidth
        if self.operational_intensity > balance:
            return "compute"
        if self.operational_intensity < balance:
            return "memory"
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
    def summary(self) -> AnalysisResult:
        glb = self.glb_access_per_layer
        dram = self.dram_access_per_layer
        return {
            "layer": self.name,
            "glb_usage": self.glb_usage_per_pass["total"],
            "glb_ifmap_read": glb["ifmap_read"],
            "glb_filter_read": glb["filter_read"],
            "glb_bias_read": glb["bias_read"],
            "glb_psum_read_conv": glb["psum_read_conv"],
            "glb_psum_read_pool": glb["psum_read_pool"],
            "glb_psum_read": glb["psum_read"],
            "glb_psum_write_conv": glb["psum_write_conv"],
            "glb_ofmap_write_pool": glb["ofmap_write_pool"],
            "glb_psum_write": glb["psum_write"],
            "glb_read": glb["read"],
            "glb_write": glb["write"],
            "glb_access": glb["total"],
            "dram_ifmap_read": dram["ifmap_read"],
            "dram_filter_read": dram["filter_read"],
            "dram_bias_read": dram["bias_read"],
            "dram_read": dram["read"],
            "dram_write": dram["write"],
            "dram_access": dram["total"],
            "macs": self.macs_per_layer,
            "latency": self.latency_per_layer,
            "energy_total": self.energy_per_layer["total"],
            "power_total": self.power_per_layer["total"],
            # Roofline columns (added vs Lab 2 to make plot_roofline_from_df work end-to-end)
            "intensity": self.operational_intensity,
            "peak_performance": self.peak_performance,
            "peak_bandwidth": self.peak_bandwidth,
            "bound_by": self.bound_by,
        }
