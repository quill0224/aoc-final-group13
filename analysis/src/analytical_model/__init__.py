from __future__ import annotations

# Eyeriss baseline
from .eyeriss import EyerissAnalyzer, EyerissHardwareParam, AnalysisResult as EyerissAnalysisResult
from .mapper import EyerissMapper

# StandardIP architecture
from .StandardIP import (
    StandardIPAnalyzer,
    StandardIPHardwareParam,
    StandardIPTilingParam,
    AnalysisResult as StandardIPAnalysisResult,
)
from .StandardIP_mapper import StandardIPMapper

# TrIP architecture
from .TrIP import (
    TrIPAnalyzer,
    TrIPHardwareParam,
    TrIPTilingParam,
    AnalysisResult as TrIPAnalysisResult,
)
from .TrIP_mapper import TrIPMapper

# Backward-compatible alias used by main.py:
# all analyzer modules define AnalysisResult as dict[str, Union[str, int, float]].
AnalysisResult = StandardIPAnalysisResult

__all__ = [
    # Common result type
    "AnalysisResult",
    "EyerissAnalysisResult",
    "StandardIPAnalysisResult",
    "TrIPAnalysisResult",

    # Eyeriss
    "EyerissAnalyzer",
    "EyerissHardwareParam",
    "EyerissMapper",

    # StandardIP
    "StandardIPAnalyzer",
    "StandardIPHardwareParam",
    "StandardIPTilingParam",
    "StandardIPMapper",

    # TrIP
    "TrIPAnalyzer",
    "TrIPHardwareParam",
    "TrIPTilingParam",
    "TrIPMapper",
]