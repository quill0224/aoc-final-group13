# Lightweight imports (no torch / matplotlib).
from .eyeriss import (
    AnalysisResult,
    EyerissAnalyzer,
    EyerissHardwareParam,
    EyerissMappingParam,
)
from .layer_info import (
    Conv2DShapeParam,
    LinearShapeParam,
    MaxPool2DShapeParam,
    ShapeParam,
)
from .mapper import EyerissMapper

# Heavy submodules (torch, matplotlib) are loaded lazily so the analytical model
# is usable in environments without those dependencies (e.g. verification tests).
_LAZY = {
    "parse_onnx":              ("network_parser", "parse_onnx"),
    "parse_pytorch":           ("network_parser", "parse_pytorch"),
    "plot_roofline":           ("roofline", "plot_roofline"),
    "plot_roofline_from_csv":  ("roofline", "plot_roofline_from_csv"),
    "plot_roofline_from_df":   ("roofline", "plot_roofline_from_df"),
}


def __getattr__(name: str):
    if name in _LAZY:
        from importlib import import_module
        mod_name, attr = _LAZY[name]
        return getattr(import_module(f".{mod_name}", __name__), attr)
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")


__all__ = [
    "AnalysisResult",
    "Conv2DShapeParam",
    "EyerissAnalyzer",
    "EyerissHardwareParam",
    "EyerissMapper",
    "EyerissMappingParam",
    "LinearShapeParam",
    "MaxPool2DShapeParam",
    "ShapeParam",
    "parse_onnx",
    "parse_pytorch",
    "plot_roofline",
    "plot_roofline_from_csv",
    "plot_roofline_from_df",
]
