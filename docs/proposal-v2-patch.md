# Proposal v2 — Numbers Patch

> **用途**：把 `analysis/results/baseline/` 的 sweep 數據整理成 ready-to-paste 段落，依 v1 proposal 章節編號排好。
> 寫 v2 時直接複製對應段落（中文敘述 + 表格 + 圖檔路徑）。
> 數據來源：PR #6 (`analysis/results/baseline/`)，跑於 2026-05-08。

---

## §4.2 PE Array Sizing（改寫）

> 取代 v1 §4.2「16×16 PE 0.5 GHz 256 GOPS」一段（缺 sensitivity 分析）。

我們以課程 baseline 6×8 為對照組，針對 VGG-8 5 個 conv layer 在 analytical model 上做 PE array 尺寸 sweep。GLB 固定 64 KiB、bus bandwidth 固定 4 bytes/cycle。

| PE 配置 | 總 PE 數 | 5-layer 總 latency (cycles) | 相對 baseline |
|---|---:|---:|---:|
| 6×8（課程 baseline） | 48 | 17,523,904 | 1.00× |
| 8×8 | 64 | 17,523,904 | 1.00× ⚠ |
| 12×8 | 96 | 12,928,704 | 1.36× |
| **16×16（v2 採用）** | **256** | **11,204,336** | **1.56×** |
| 32×16 | 512 | 9,758,310 | 1.79× |

**設計選擇理由**：
- 8×8 與 6×8 完全相同 latency——因為 R=3（filter height）必須整除 PE_h，`8/3=2 餘 2` 跟 `6/3=2 餘 0` 在 PE strip 數上一致。**未來若要再放大 PE_h，務必選 3 的倍數**（9, 12, 15, 18）。
- 16×16 相對 baseline 提供 **1.56× speedup**，PE 數 5.3×，邊際效益約 0.29 speedup/PE doubling。
- 32×16 進一步推到 1.79×，但 area 翻倍、佈局複雜度增加。**16×16 為 ROI sweet spot**。

> 圖：見 `analysis/results/baseline/pe_latency.png`

---

## §4.2 / §4.4 Global Buffer 容量（改寫）

> 取代 v1 §4.2「GLB 16 KiB / 128 entries × 64-bit」一段。

我們在 PE = 6×8 baseline 下對 GLB 做 size sweep（16, 32, 64, 128, 256, 512 KiB），量測 5 個 conv layer 的 DRAM access 總量。

| GLB | 5-layer 總 DRAM access (bytes) | vs 16 KiB |
|---|---:|---:|
| 16 KiB（v1 提案） | 3,168,768 | 1.00× |
| 32 KiB | 2,809,600 | 0.89× |
| 64 KiB（課程 baseline） | 2,627,840 | 0.83× |
| **128 KiB（v2 採用）** | **2,536,960** | **0.80× (saturate)** |
| 256 KiB | 2,536,960 | 0.80× |
| 512 KiB | 2,536,960 | 0.80× |

**設計選擇理由**：
- v1 提案的 16 KiB 比課程 baseline 64 KiB **還小**，這是設計失誤；DRAM access 比 baseline 多 21%，不合理。
- 128 KiB 是 conv layer 的 saturation 點；再大不會有 conv-side 收益。
- v2 採 **128 KiB GLB**：對 conv 已飽和、對 FC 仍嫌不足（見 §4-NEW），是 area / utility 折衷。

> 圖：見 `analysis/results/baseline/glb_dram.png`

---

## §4-NEW Fully-Connected Layer 處理策略（新增章節）

> v1 完全沒寫 FC layer。組長提出此疑慮後，我們對 VGG-8 三個 FC layer 量化分析。

### Weight footprint（INT8）

| Layer | shape | weights | bytes |
|---|---|---:|---:|
| FC6 | 4096 → 256 | 1,048,576 | **1.0 MiB** |
| FC7 | 256 → 128 | 32,768 | 32 KiB |
| FC8 | 128 → 10 | 1,280 | 1.25 KiB |

### Tile 數 vs GLB 大小

採 output-stationary streaming（GLB 同時容納 ifmap INT8 + bias INT32 + psum INT32 + active weight tile）：

| GLB | FC6 tiles | FC7 tiles | FC8 tiles |
|---|---:|---:|---:|
| 16 KiB | 103 | 3 | 1 |
| 64 KiB | 18 | 1 | 1 |
| 128 KiB | 9 | 1 | 1 |
| 256 KiB | 5 | 1 | 1 |
| 512 KiB | 3 | 1 | 1 |
| **1 MiB** | **2** ❌ | 1 | 1 |

**關鍵觀察**：FC6 即便配 **1 MiB on-chip GLB 仍需 2 tile**（因為 ifmap + accumulators 也佔空間），任何合理面積預算都無法 single-shot 跑 FC6。

### v2 採用策略：Host fallback + accelerator 雙路徑

| Layer | 處理方式 | 理由 |
|---|---|---|
| FC6 | **Host CPU 處理** | 1 MiB weights 無法 on-chip，weight streaming 反而複雜化 RTL 並增加 DRAM port 壓力；CPU 跑一次 4096×256 矩陣乘法亦僅 ~1 ms |
| FC7, FC8 | Accelerator 處理 | 兩者皆可 fit 64 KiB GLB 內單 tile 完成 |

**邊界**：accelerator output 為 conv5 後 maxpool 結果（256 ch × 4 × 4 = 4096 元素 INT8 = 4 KiB）→ 經 host CPU 跑 FC6 → 結果送回 accelerator 跑 FC7 / FC8。或者更簡：FC6/FC7/FC8 全交 host。

> 圖：見 `analysis/results/baseline/fc_tiles.png`

---

## §5.2 Roofline 分析（補強）

> v1 §5.2 只算了 baseline ridge point；v2 補上 v2 hardware 的 ridge point 變化。

### Operational intensity（VGG-8 conv layers, 不變）
- 平均 OI ≈ **25.16 MAC/byte**（compute-bound under 6×8 baseline）

### Machine balance point 隨 PE size 變動

| PE 配置 | Peak compute (MAC/cycle) | Bus BW (B/cycle) | Balance point | bound_by (vs OI=25) |
|---|---:|---:|---:|---|
| 6×8 (baseline) | 48 | 4 | 12 | **compute-bound** |
| 16×16 (v2) | 256 | 4 | 64 | **memory-bound** ⚠ |
| 16×16 (v2 + 8 B/cycle bus) | 256 | 8 | 32 | **memory-bound** (slight) |
| 16×16 + 16 B/cycle bus | 256 | 16 | 16 | compute-bound（再次）|

**設計意涵**：
- 把 PE 從 6×8 升到 16×16 (5.3×) 之後，design 從 compute-bound **滑入 memory-bound**（balance pt 12 → 64 vs OI=25）。
- 雖然 latency 仍改善 1.56× （因為 latency formula 的 memory-time 也 benefit from 更大的 e tile），但更大的 compute roof 並沒有完全被利用。
- **建議**：v2 至少把 bus bandwidth 從 4 B/cycle 拉到 8 B/cycle（平衡點 32），讓 bigger PE 配 bigger bus 才合理。

---

## §6.1 NoC Architecture（仍待補）

> sweep 數據無法直接給 NoC 答案；這部分需要 RTL phase 同步設計。

組長疑慮 #3「NoC 拓樸缺失」**仍未在本份 patch 中解決**。建議 v2 在 §6.1 加入以下內容（這部分要 RTL 主責的同學設計後才能填）：

1. **PE ↔ GLB 路由方式**：建議走 broadcast / multicast 三層 NoC（Eyeriss-style：3 GIN + 1 GON + LN）；16×16 不需要 cluster 化，比 Trapezoid 128×128 簡化很多。
2. **Reduction tree fan-in**：建議 fan-in = pe_array_h = 16，depth = 4。
3. **Bandwidth budget**：每 cycle 至少需 (q × r × DATA_SIZE) B/cycle for ifmap broadcast + (p × t × DATA_SIZE) B/cycle for filter broadcast + (m × PSUM_DATA_SIZE) B/cycle for psum drain。最差情況須估算後決定 NoC link width。

---

## §6.4 Timeline 影響

新加的「FC strategy」章節需要在 §6.4 的 RTL phase 加上：
- **Week 5**：定義 accelerator ↔ host 的記憶體介面（DMA descriptor、AXI control register）
- **Week 6**：實作 FC7 / FC8 的 GLB tiling logic
- **Week 7**：integration test (conv5 ofmap → host FC6 → accelerator FC7/FC8 → result)

---

## 圖檔（給 v2 的 figure list）

```
analysis/results/baseline/
├── pe_latency.png       Fig 4-1: VGG-8 per-layer latency vs PE array size
├── glb_dram.png         Fig 4-2: VGG-8 per-layer DRAM access vs GLB size
└── fc_tiles.png         Fig 4-3: FC layer tile count vs GLB size (INT8)
```

PowerPoint 直接 insert image 引用即可；解析度足夠（300 DPI 等級）。

---

## v1 → v2 變更摘要（給組長 / PI 看）

| 章節 | v1 | v2 |
|---|---|---|
| §4.2 PE size | 16×16，無 sensitivity | 16×16，附 5 種配置 sweep（含 6×8 baseline 對照）+ 1.56× speedup 數據 |
| §4.2 GLB | 16 KiB | **128 KiB**（從 6 個 GLB 大小 sweep 找出 saturate 點）|
| §4 FC strategy | 完全沒寫 | **新章節**：FC6 → host CPU、FC7/FC8 → accelerator，附 1 MiB on-chip 也不夠的量化證據 |
| §5.2 Roofline | 僅 baseline ridge pt | 補 v2 hardware 的 balance pt 計算，揭示 16×16 + 4 B/cycle = memory-bound 風險 |
| §6.1 NoC | 元件清單，無拓樸 | 仍需補（RTL phase 給）|
| §6.4 timeline | conv-only | 加 host-FC integration testing |

---

— Last updated: 2026-05-08 by @quill0224
— Data commit: PR #6 baseline; analytical model: PR #5 (含 fc_analysis fix)
