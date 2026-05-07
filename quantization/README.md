# quantization/

VGG-8 + Power-of-2 INT8 PTQ pipeline, ported from AOC Lab 1 (`Q36144200_Lab1.ipynb`) into clean, importable Python modules.

## 目錄結構

```
quantization/
├── __init__.py             package marker
├── model.py                VGG-8 with QuantStub/DeQuantStub + fuse_model()
├── quantize.py             PowerOfTwoObserver + CustomQConfig + ptq_quantization()
├── data.py                 CIFAR-10 dataloaders
├── trainer.py              training loop + evaluate()
├── utils.py                save/load + plot helpers
├── run_train.py            entry: train VGG-8 from scratch
├── run_ptq.py              entry: PTQ + FP32/INT8 benchmark
├── scripts/
│   └── copy_lab1_weights.sh  copy pre-trained Lab 1 weights here
├── weights/                .gitignore'd; populated by script or run_train.py
├── requirements.txt        Python deps (already in AOC Docker)
└── README.md               this file
```

## Quick Start

### Option A — 用 Lab 1 既有 weights（快）

```bash
cd ~/aoc-workspace/projects/Final_project
bash quantization/scripts/copy_lab1_weights.sh
python -m quantization.run_ptq
```

預期輸出（節錄）：
```
=== Accuracy ===
FP32  Acc 91.79%
INT8  Acc 91.58%
=== Latency (CPU, 1 sample, 1000 runs) ===
FP32 4.7 ms | INT8 2.6 ms | speedup 1.81x
=== Size ===
FP32 13.37 MB | INT8 3.35 MB | compression 3.99x
```

### Option B — 從頭訓練（慢，~1 hr on GPU）

```bash
python -m quantization.run_train --epochs 200 --lr 0.01 --batch-size 32
python -m quantization.run_ptq
```

## 量化方案核心

- **Bit-width**: INT8 (symmetric)
- **Scale**: power-of-2 — `s ≈ 2^(-c)` 讓 dequantization 從 float division 變成 arithmetic right-shift
- **Granularity**: per-tensor
- **Zero-point**: 0 for weights, 128 for activations (uint8) → 後者搭配 XOR bit 7 trick 在硬體變成 int8
- **Fusion**: Conv-BN-ReLU 必須在量化前合併，否則 BN folding 後的中間量化 truncation 會累積誤差

完整解釋見 [Concepts/Quantization Tricks](../docs/proposal-review.md) 的對應段落（後續會搬進來）。

## 核心程式碼節點

| 想找... | 看這個 |
|---|---|
| VGG 架構（5 conv + 3 fc, 3.3M params） | `model.py::VGG` |
| Power-of-2 scale 邏輯 | `quantize.py::PowerOfTwoObserver.scale_approximate` |
| PTQ 入口（fuse → prepare → calibrate → convert） | `quantize.py::ptq_quantization` |
| 訓練 loop（SGD + cosine annealing） | `trainer.py::train_model` |
| FP32 vs INT8 benchmark（accuracy + latency + size） | `run_ptq.py::main` |

## 與 Final_project 其他模組的關係

- `quantization/` 產出的 `.pth` 將被 `analysis/` 讀取，作為 analytical model 的輸入（layer shapes、bit-widths）
- `quantization/` 的硬體無關設定（symmetric INT8、power-of-2 scale）將決定 `rtl/` 端 PE/PostQuant 的 bit-width 與 shifter 設計
- 提案中提到的 FC layer 大小：FC6 = 1,048,832 params（1 MB INT8）；這是 `docs/proposal-review.md` § 2 FC memory bottleneck 的根因之一
