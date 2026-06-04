# 完整 PE Row 微架構(paper Fig 6 對齊版)

> Owner: 黃妍心 · 2026-05-28 sprint
>
> **目標**:把 pe_row 寫成 paper Fig 6 完整版(包進所有 per-row 硬體),
> 單一物理 pipeline(Δ5 Option A),Dense IP 端到端跑得起來,
> 組員 module(MFIU / dist)一到位 TrIP 直接亮,pe_row 不用改。
>
> **本檔是全組介面契約** —— 改 pe_row 內部 sub-module 的 port 前,先更新這裡 + 通知 owner。

---

## 資料流(bottom-to-top,對齊 paper Fig 6)

```
   cache (a_grid, b_vec, bitmask)
        │
        ▼
┌──────────────────────── pe_row ────────────────────────┐
│ S1  A Reg (stationary) + B FIFO          [黃妍心]        │
│        a_vec / b_vec / a_bitmask / b_bitmask 打拍        │
│        │                                                 │
│ S2-S4  MFIU (intersect + prefix sum + shift) [楊承豫]    │
│        out: effectual_idx[16], effectual_count, cut_after│
│        │   (Dense IP: cut_after=0, idx=identity)         │
│        ▼                                                 │
│ S5  A/B Distribution crossbar             [NoC: 我+QuillQ]│
│        依 effectual_idx 把 a/b routing 到對的 mul         │
│        │   (Dense IP: identity pass-through)             │
│        ▼                                                 │
│ S6  Mul × 16 (mac_unit)                   [黃妍心]        │
│        16 × INT8×INT8 → INT16 partials                   │
│        ▼                                                 │
│ S7  Merge-Reduction Tree (flexagon)       [黃妍心] ✅     │
│        sub-tree slicing,依 cut_after 切;出 16 subtree_sums│
│        ▼                                                 │
│ S8  Local Buffer (4-bank scatter) + C out [黃妍心]        │
│        scatter-accumulate subtree_sums → C partial sums   │
│        K-tile 累加;dump 時寫回 cache                      │
└──────────────────────────────────────────────────────────┘
        │ b_vec_out → 下一條 row (B vertical chain, Fig 7 ④)
```

---

## Pipeline:8 stage 單一物理管線(Δ5 Option A)

| Stage | 名稱 | 元件 | latency | Owner |
|-------|------|------|---------|-------|
| S1 | latch | A Reg + B FIFO 輸入打拍 | 1 | 黃妍心 |
| S2-S4 | MFIU | intersect + prefix sum + shift | 3(暫定)| 楊承豫 |
| S5 | dist | A/B crossbar registered out | 1 | NoC |
| S6 | mul | mac_unit registered | 1 | 黃妍心 |
| S7 | tree | flexagon(combinational + 1 reg)| 1 | 黃妍心 |
| S8 | buf | local buffer RMW + C out | 1 | 黃妍心 |
| | | **PE_ROW_STAGES** | **= 8** | |

- **Dense IP 也走 8 stage**:MFIU + dist 在 Dense 模式是 pass-through delay(不做事但延遲還在)。
- MFIU_STAGES=3 是暫定值,**待 楊承豫 確認**;改了只要更新 `trapezoid_pkg::MFIU_STAGES`,pe_row 的 valid pipeline 會跟著對齊。
- tree 從 4 stage 改 1 cycle(組員決議:先不切 stage,synth 後 critical path 太長再切)。

---

## 各 sub-module 介面契約

### S8 Local Buffer(`local_buffer_row.sv`,黃妍心)✅ Block 1

| 訊號 | 方向 | 寬度 | 說明 |
|------|------|------|------|
| `subtree_sums[16]` | in | `[16][31:0]` signed | 從 tree 來,每 sub-tree 的 reduction 值 |
| `subtree_valid[16]` | in | `[16]` | 哪些 position 有 valid sub-tree |
| `out_addr[16]` | in | `[16][8:0]` | 每 sub-tree position → 寫進 buffer 的哪個 C column |
| `clear` | in | 1 | 清零整個 buffer(新 output tile 開始)|
| `acc_en` | in | 1 | 此 cycle scatter-accumulate |
| `dump_en` | in | 1 | 此 cycle 讀出 C 寫回 |
| `dump_addr` | in | `[8:0]` | 讀哪個 C column |
| `c_valid` | out | 1 | dump 有效 |
| `c_out` | out | `[31:0]` signed | dump 出的 C 值 |

- **scatter-accumulate**:`for p: if valid[p]: mem[out_addr[p]] += subtree_sums[p]`
- 假設同 cycle 內不同 valid position 的 `out_addr` 互異(TrIP 不同 sub-tree → 不同 C,成立)。
- 容量 `LOCAL_BUF_DEPTH=512`(VGG-16 max output channels N)。

### S2-S4 MFIU(`mfiu_row.sv`,介面黃妍心定 / body 楊承豫)Block 2

| 訊號 | 方向 | 寬度 | 說明 |
|------|------|------|------|
| `a_bitmask` | in | `[16]` | 此 row 的 A bitmask |
| `b_bitmask` | in | `[16]` | 此 row 的 B bitmask |
| `dataflow_sel` | in | `[1:0]` | Dense / TrIP / ... |
| `effectual_idx[16]` | out | `[16][4:0]` | 每有效運算的原 index(給 dist 路由)|
| `effectual_count` | out | `[4:0]` | 此 cycle 有效運算數 |
| `cut_after[14:0]` | out | 15 bit | sub-tree 邊界(給 tree)|
| `out_addr[16]` | out | `[16][8:0]` | 每 sub-tree → C column(給 local buffer)|

- **Dense IP 行為**:cut_after=0,effectual_idx=identity(0,1,...,15),count=16,out_addr[15]=current_n。
- TrIP body 由 楊承豫 填(intersect AND + prefix sum + shift)。

### S5 Distribution network(`dist_net_row.sv`,Benes,我+QuillQ)Block 3

| 訊號 | 方向 | 寬度 | 說明 |
|------|------|------|------|
| `a_vec_in[16]` / `b_vec_in[16]` | in | `[16][7:0]` | 原始 a/b |
| `effectual_idx[16]` | in | `[16][4:0]` | 從 MFIU |
| `dataflow_sel` | in | `[1:0]` | mode |
| `a_vec_out[16]` / `b_vec_out[16]` | out | `[16][7:0]` | routing 後給 mul |

- **Dense IP**:identity(a_vec_out=a_vec_in)。
- TrIP:`a_vec_out[m] = a_vec_in[effectual_idx[m]]`(crossbar mux)。

---

## Build checklist(每塊測完才下一塊)

- [x] Block 0:flexagon tree(17 tests pass)
- [ ] Block 1:`local_buffer_row` + tb
- [ ] Block 2:`mfiu_row`(Dense pass-through)+ tb
- [ ] Block 3:`dist_net_row`(Dense identity)+ tb
- [ ] Block 4:`a_reg_file` + `b_fifo` + tb
- [ ] Block 5:`pe_row` v2(全組起來)+ tb_pe_row(vs numpy)
- [ ] Block 6:`pe_array` v2 + tb_pe_array(Dense IP 端到端 vs numpy)

---

## 不在這次範圍(明確不做)

- TrGT / TrGS(merge mode,comparator)— stretch goal
- MFIU / dist 的 TrIP 真實 body(等 楊承豫 / QuillQ)
- Real cache + DMA(tb 用 `$readmemh` 灌資料)
- Synth(Phase 後段,問 TA 拿 ADFP library)
