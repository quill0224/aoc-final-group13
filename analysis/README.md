# analysis/

本目錄存放 Lab 2 analytical model 的延伸：在課程提供的 Eyeriss-style analytical model 上加上 PE array sweep、memory hierarchy sensitivity、roofline 分析等。

## 預期內容
- `roofline.py` — Roofline plot
- `pe_sweep.py` — 不同 PE array 大小（8×8, 16×16, 32×32）下的 utilization 與 latency
- `mem_hierarchy.py` — GLB 大小 vs FC layer access count
- `figs/` — 產出的圖

## 與 docs/proposal-review.md 的對應
- 「PE array sizing」疑慮 → `pe_sweep.py`
- 「FC layer 記憶體瓶頸」疑慮 → `mem_hierarchy.py`
- 「NoC 配置」疑慮 → 由 RTL/sim 端評估，本目錄只提供記憶體存取統計
