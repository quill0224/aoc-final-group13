# Proposal Review — Gap Analysis vs Trapezoid (ISCA'24)

> **目的**：在動 RTL 之前，把組長提的三個技術疑慮（PE array 大小、FC layer 記憶體、NoC 配置）寫清楚，並對應到 Trapezoid 論文的設計事實，作為提案 v2 修訂與後續分工的依據。
>
> **資料來源**：
> - 我們的提案：`reference/AOC_Final_Proposal_第13組.pdf`
> - 論文：M. Yan et al., "Trapezoid: A Versatile Accelerator for Dense and Sparse Matrix Multiplications," ISCA 2024.

---

## 1. PE Array Sizing

### 提案內容
- **16×16 PE array @ 0.5 GHz → 256 GOPS peak**（提案 §4.2 / §5.1）
- 理由：搭配 Lab 2 analytical model 可分析的尺度
- **缺**：沒有 sensitivity analysis（為什麼是 16×16 而不是 8×8 或 32×32）

### Trapezoid 論文事實
- **128×128 PE 陣列**，組織為 **4 cluster × 32 row**（論文 §III, Fig. 6/13）
- 每個 row 有自己的 local buffer (MFIU)、distribution networks、merge-reduction tree
- TrIP 的核心優勢來自於「在多個 row 上同時 pack 多個 sparse fiber 增加 multiplier utilization」——row 數越少，攤提空間越小

### Gap
- 我們的 16×16 比論文小 **80×**
- 在 16 row 的尺度上，TrIP 的 sparse fiber packing 效益會嚴重退化（intersection unit 利用率下降）
- **沒有實驗證據說明小尺度仍能保留 TrIP 的優勢**

### 建議行動（誰做、何時做）
- [x] **analysis/sweeps/pe_sweep.py** — 已實作；包含 `(6,8) / (12,8) / (16,16) / (8,8) / (32,16)` 五組
- [ ] 跑 `python -m analysis.sweeps.pe_sweep` 並把 CSV / latency.png 貼進 proposal v2
- [ ] 結論寫進 proposal v2 §4.2 作為設計選擇依據
- 主責：TBD（建議由負責 analysis 的人做）
- Deadline：Week 2 結束前

---

## 2. FC Layer 記憶體瓶頸

### 提案內容
- GLB（Global Buffer）= **16 KiB**（128 entries × 64-bit, two-port SRAM）（提案 §4.2）
- Local buffers = 8 KiB / row
- **完全沒提 FC layer 怎麼處理**——只討論 conv layer 與 sparse bitmap

### 事實
- 課程 baseline GLB = **64 KiB**（我們提案的 16 KiB **比 baseline 還小**！）
- VGG-8 FC1 約 25 M weights：
  - INT8 → 25 MB
  - FP16 → 50 MB
  - 都遠超過 16 KiB（差 1500× 以上）
- Trapezoid 用 **clustered cache 16 MB（4× 4 MB cluster）**，其中每個 cluster 32×32 crossbar 連 PE row 跟 banks，避免 128×128 全互聯

### Gap
1. 提案 GLB 容量設計**比課程 baseline 還少**——直接 NG
2. **完全沒 tiling 策略**：FC layer 必須 weight streaming + output stationary，但提案沒寫
3. Roofline 估出 ridge point ≈ 2 OP/Byte → 多數 layer 是 memory-bound，**FC 會是最大瓶頸**

### 建議行動
- [x] **analysis/sweeps/glb_sweep.py** — 已實作；含 GLB 16/32/64/128/256/512 KiB 對 conv DRAM access 的影響
- [x] **analysis/sweeps/fc_analysis.py** — 已實作；計算 FC6/FC7/FC8 在不同 GLB 下需要的 tile 數
- [ ] 跑 `python -m analysis.sweeps.run_all` 收集數據
- [ ] 把結果寫進 **proposal v2 §4「FC layer 處理策略」**：
  - GLB 拉回 ≥ 64 KiB（與課程 baseline 同等或更大）
  - Tiling 公式（依 fc_analysis.py 的 output stationary + weight streaming）
  - Worst-case bandwidth 估算
- [ ] **討論：FC layer 是否要走 host CPU fallback？**（accelerator 只負責 conv 部分）
- 主責：TBD
- Deadline：Week 2 結束前

---

## 3. NoC 拓樸缺失

### 提案內容
- §4.2 列出元件：
  - Multi-Fiber Intersection Unit (MFIU)
  - Distribution Networks
  - Merge-Reduction Tree
- §6.1 RTL 計畫：「16×16 PE Array + MFIU + Memory Controller」
- **完全沒有 NoC topology 圖、沒有路由規則、沒有頻寬估算**

### Trapezoid 論文事實
- **Distribution network**：Benes network（A row values + B column bitmasks 各一份）（Fig. 11）
- **Merge-Reduction tree**：在 cluster mode 下做 partial-product accumulation（Fig. 13）
- **多層記憶體**：local buffer → merge tree → cluster cache → global cache
- TrIP 的正確性依賴**每 cycle 動態 pack B 個 column 給每個 PE row**（§III）——這需要緊密的 NoC 協調

### Gap
- 沒寫 router topology → 不知道 input data 怎麼到 PE
- 沒寫 partial-sum reduction tree fan-in → 不知道 output 怎麼回收
- 沒寫 PE↔GLB 頻寬 → 不知道是否會 stall
- 沒寫 cluster 概念 → 16×16 PE 是否需要 cluster 化也不清楚

### 建議行動
- [ ] **proposal v2 §4 補一張 NoC block diagram**，至少包含：
  - PE array ↔ GLB 路由方式（broadcast / multicast / point-to-point）
  - Reduction tree fan-in / depth
  - Local buffer ↔ MFIU 連接
- [ ] 估算各 link 頻寬需求（bytes/cycle），確認不超過 hardware 限制
- [ ] 因為我們是 16×16（不是 128×128），可考慮**單一 cluster** 設計，省去 cluster-level crossbar
- 主責：TBD（建議由負責 RTL 的人做）
- Deadline：RTL 啟動前（Week 4 結束前）

---

## 4. 其他發現

### 4.1 量化計畫過於模糊
- 提案 §6.4 timeline 把「Lab 1/2 Quantization」放第 1–2 週，方向正確
- 但**沒指定**：
  - Bit-width（INT8 / INT4 / mixed）
  - PTQ vs QAT
  - 是否包含 sparse training（Trapezoid 的賣點之一）
- **建議**：Week 1 結束前團隊內部敲定一個方案，寫進 `quantization/README.md`

### 4.2 Roofline 顯示偏 memory-bound
- 提案 §5.2 算出 ridge point ≈ 2 OP/Byte
- 表示**多數 layer 是 memory-bound**——這恰恰放大了 §2 FC 問題
- 必須先解決記憶體配置才談得上 256 GOPS 的 peak compute

### 4.3 Timeline 緊（標紅 debug 階段）
- §6.4 把 Week 5–8 標紅
- 建議定義 **MVP / stretch goal**：
  - **MVP**：dense conv only，跳過 sparse 與 FC
  - **Stretch**：sparse + FC + end-to-end VGG-8
- 防止全組陷在 sparse RTL debug 而沒交得出 demo

### 4.4 缺 baseline 比較
- 提案沒設定明確的 baseline 對照（例如 Eyeriss v1 same-PE-count 在同 workload 上的 latency）
- 建議在 `analysis/` 加一份 baseline 數據，方便最終 evaluation 章節

---

## 5. 修案 v2 建議優先順序

| 優先級 | 修正項目 | 估時 |
|--------|----------|------|
| P0 | GLB 容量拉回 ≥ 64 KiB | ✅ done — 改採 128 KiB（見 [proposal-v2-patch.md](proposal-v2-patch.md) §4.2 GLB） |
| P0 | NoC topology 圖 + 路由說明 | 仍待 RTL phase（[v2-patch §6.1](proposal-v2-patch.md#§61-noc-architecture仍待補)）|
| P0 | FC layer tiling 策略 | ✅ done — host fallback for FC6（見 [v2-patch §4-NEW](proposal-v2-patch.md#§4-new-fully-connected-layer-處理策略新增章節)）|
| P1 | PE sweep 實驗 + 結論 | ✅ done — sweep 5 種配置 + ROI 分析（見 [v2-patch §4.2 PE](proposal-v2-patch.md#§42-pe-array-sizing改寫)）|
| P1 | Quantization 方案具體化 | TBD — 已有 power-of-2 INT8 PTQ baseline，待團隊敲定 bit-width 變化方案 |
| P2 | MVP / stretch goal 切分 | TBD |
| P2 | Baseline 比較設定 | TBD |

---

## 6. Open Questions（要去問 PI / TA）

1. 課程 baseline 是不是必須維持 6×8 / 64 KiB？我們的 16×16 是否合課程規範？
2. FC layer 是否可以由 host CPU fallback、加速器只負責 conv？是否符合課程評分標準？
3. Sparse training 的 dataset 是課程提供，還是要自己準備？

— Last updated: 2026-05-08 by @quill0224
