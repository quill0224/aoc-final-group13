"""DSE over Eyeriss mapping space (lifted from AOC Lab 2).

Generates the Cartesian product of (m, n, e, p, q, r, t) under hardware
constraints, scores each candidate by latency (energy as tie-breaker),
returns the top-K.
"""

from __future__ import annotations

from heapq import nsmallest
from itertools import product

from .eyeriss import (
    PSUM_DATA_SIZE,
    AnalysisResult,
    EyerissAnalyzer,
    EyerissHardwareParam,
    EyerissMappingParam,
)
from .layer_info import Conv2DShapeParam, MaxPool2DShapeParam


class EyerissMapper:
    cnt = 0

    def __init__(self, name: str | None = None) -> None:
        self.name = name if name is not None else f"mapping_{EyerissMapper.cnt}"
        self.analyzer = EyerissAnalyzer(name=self.name)
        EyerissMapper.cnt += 1

    def run(
        self,
        conv2d: Conv2DShapeParam,
        maxpool: MaxPool2DShapeParam | None = None,
        num_solutions: int = 1,
        mode: str | None = None,
    ) -> list[AnalysisResult]:
        self.analyzer.conv_shape = conv2d
        self.analyzer.maxpool_shape = maxpool
        self.analyzer.mode = self.mode = mode

        results: list[AnalysisResult] = []
        for hardware in self.generate_hardware():
            self.hardware = hardware
            for mapping in self.generate_mappings():
                self.analyzer.mapping = mapping
                results.append(self.analyzer.summary)

        if num_solutions > 0:
            results = nsmallest(num_solutions, results, key=self.evaluate)
        return results

    def evaluate(self, metrics: AnalysisResult) -> float:
        # Primary: latency. Secondary (tie-breaker): energy with tiny weight.
        latency = metrics.get("latency", float("inf"))
        energy = metrics.get("energy_total", 0)
        return latency + energy * 1e-6

    @property
    def hardware(self) -> EyerissHardwareParam:
        return self.analyzer.hardware

    @hardware.setter
    def hardware(self, hardware_param: EyerissHardwareParam) -> None:
        assert isinstance(hardware_param, EyerissHardwareParam)
        self.analyzer.hardware = hardware_param

    # ----- per-parameter feasible ranges -----
    def p_avaliable(self) -> list[int]:
        p_max = self.hardware.psum_spad_size // PSUM_DATA_SIZE
        return list(range(1, p_max + 1))

    def q_avaliable(self) -> list[int]:
        q_max = self.hardware.ifmap_spad_size // self.analyzer.conv_shape.S
        return list(range(1, q_max + 1))

    def e_available(self) -> list[int]:
        hw_strips = self.hardware.pe_array_h // self.analyzer.conv_shape.R
        e_max = self.hardware.pe_array_w * hw_strips
        return list(range(1, min(e_max, self.analyzer.conv_shape.E) + 1))

    def r_available(self) -> list[int]:
        r_max = self.hardware.pe_array_h // self.analyzer.conv_shape.R
        return list(range(1, r_max + 1))

    def t_available(self) -> list[int]:
        num_pes = self.hardware.pe_array_h * self.hardware.pe_array_w
        t_max = num_pes // self.analyzer.conv_shape.R
        return list(range(1, t_max + 1))

    def m_available(self) -> list[int]:
        m_max = self.analyzer.conv_shape.M
        return [m for m in range(1, m_max + 1) if self.analyzer.conv_shape.M % m == 0]

    def validate(self, mapping) -> bool:
        m, n, e, p, q, r, t = mapping
        self.analyzer.mapping = EyerissMappingParam(*mapping)

        if p * q > self.hardware.filter_spad_size // self.analyzer.conv_shape.S:
            return False
        if (
            e % self.hardware.pe_array_w != 0
            and e != self.hardware.pe_array_w // 2
            and self.analyzer.conv_shape.E != e
        ):
            return False
        if (
            r * t
            != self.hardware.pe_array_h
            * self.hardware.pe_array_w
            // self.analyzer.conv_shape.R
            // e
        ):
            return False
        if m % p != 0:
            return False
        return self.analyzer.glb_size_legal

    def generate_mappings(self, verbose: bool = False) -> list[EyerissMappingParam]:
        n_avail = [1]
        m_avail = self.m_available()
        e_avail = self.e_available()
        p_avail = self.p_avaliable()
        q_avail = self.q_avaliable()
        r_avail = self.r_available()
        t_avail = self.t_available()

        all_combos = product(m_avail, n_avail, e_avail, p_avail, q_avail, r_avail, t_avail)
        valid = [EyerissMappingParam(*combo) for combo in all_combos if self.validate(combo)]
        if verbose:
            print(f"Found {len(valid)} valid mappings")
        return valid

    def generate_hardware(self) -> list[EyerissHardwareParam]:
        # Default DSE space (matches Lab 2). Override by subclassing or
        # passing a one-element list for fixed-hardware analysis.
        pe_array_h_list = [6, 9, 12]
        pe_array_w_list = [8]
        ifmap_spad_size_list = [12]
        filter_spad_size_list = [48]
        psum_spad_size_list = [16]
        glb_size_list = [64 * 2**10, 128 * 2**10]
        bus_bw_list = [4, 8]
        noc_bw_list = [4]

        combos = product(
            pe_array_h_list, pe_array_w_list,
            ifmap_spad_size_list, filter_spad_size_list, psum_spad_size_list,
            glb_size_list, bus_bw_list, noc_bw_list,
        )
        return [EyerissHardwareParam(*c) for c in combos]
