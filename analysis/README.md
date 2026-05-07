# analysis/

Eyeriss-style analytical performance model + DSE, ported from AOC Lab 2.
Used to estimate **latency / energy / DRAM access** of VGG-8 on different (mapping, hardware) configurations.

## 目錄結構

```
analysis/
├── __init__.py
├── run_dse.py                  CLI entry: parse VGG-8 → DSE → CSV/MD/roofline
├── eyeriss/
│   ├── __init__.py             re-exports core API
│   ├── layer_info.py           Conv2DShapeParam / MaxPool2DShapeParam / LinearShapeParam
│   ├── eyeriss.py              EyerissAnalyzer (per-layer cost model)
│   ├── mapper.py               EyerissMapper (DSE over m,n,e,p,q,r,t)
│   ├── network_parser.py       parse_pytorch / parse_onnx
│   └── roofline.py             roofline plotting
├── results/                    output dir (gitignored, created at runtime)
└── README.md                   this file
```

## Quick Start

需要先跑過 PR 2 並把 Lab 1 weights 放好：
```bash
bash quantization/scripts/copy_lab1_weights.sh
```

然後從 `Final_project/` 根目錄跑：
```bash
# DSE on FP32 baseline
python -m analysis.run_dse --backend none \
  --model ./quantization/weights/best_vgg_cifar10.pth

# DSE on INT8 quantized model
python -m analysis.run_dse --backend power2 \
  --model ./quantization/weights/PTQ_vgg_cifar10.pth

# Skip roofline plot
python -m analysis.run_dse --no-plot
```

每次執行會在 `analysis/results/<timestamp>/` 產出：
- `output.csv` — 每層 Conv2D 的最佳 mapping + 各種 access count / latency / energy
- `output.md` — 同上，markdown 表格
- `roofline.png` — DSE 出來的硬體 roofline + 各 layer 的 OI 點

## 預期結果（依 Lab 2）

5 個 conv layer 全部收斂到 `(e, p, q, r, t) = (8, 4, 4, 1, 2)`，只有 `m` 隨 output channel 變動：
- conv1 (M=64)  → m=64
- conv2 (M=192) → m=64 or 96
- conv3 (M=384) → m=96
- conv4 (M=256) → m=64 or 128
- conv5 (M=256) → m=64 or 128

Latency: 627K – 3.6M cycles per layer。
Conv2D 整體偏 **compute-bound**（OI ≈ 25.16 > machine balance 12）。

## 在程式內 import 用法

```python
from analysis.eyeriss import (
    EyerissMapper, EyerissHardwareParam, EyerissMappingParam,
    Conv2DShapeParam, MaxPool2DShapeParam,
    parse_pytorch, plot_roofline_from_df,
)

mapper = EyerissMapper(name="my_layer")
results = mapper.run(conv2d_shape, maxpool_shape, num_solutions=5)
# results 是 list of dict，每個 dict 含 latency/energy/glb_*/dram_*/intensity 等
```

## 與 Final_project 其他模組的關係

- 直接 `from quantization.model import VGG` 拿 PR 2 寫的模型，**不要重新定義** VGG
- 後續 PR 4 會在 `analysis/sweeps/` 加上 PE-array sweep / GLB sweep / FC-layer 分析，回應提案 review 的三大疑慮（見 `docs/proposal-review.md`）
- 輸出的 CSV 會被 RTL 端的 testbench 用來產生 reference data
