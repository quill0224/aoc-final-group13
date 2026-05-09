# 架構與 ISCA 2024 論文的對齊狀況

> Owner: 黃妍心  ·  最後更新: feat/yhsin-pe_mac PR
>
> **本檔記錄 RTL 架構跟 paper (Yang et al., ISCA 2024) 的差異與處理。**
> 初稿時發現 4 個結構性落差;本 PR 修掉了其中 3 個 (Δ1/Δ2/Δ3 部分),
> Δ4 留到 Phase 2 (TrIP 上線時) 一起處理。

---

## ✅ Δ1 — PE row 範圍 [部分修正]

| | 論文 (Fig 6) | 修正後現況 |
|---|---|---|
| **mul array** | 在 PE row 內 | ✅ 在 pe_row 內 (16 個 mac_unit) |
| **merge-reduction tree** | 在 PE row 內 | ✅ 在 pe_row 內 (新檔 `rtl/pe/merge_tree_radix16.v`) |
| **accumulator** | 在 PE row 內 | ✅ 在 pe_row 內 (1 個 INT32 acc register) |
| MFIU | 在 PE row 內 | ❌ Phase 2 才 instantiate per-row (彭俞凱) |
| A/B Distribution Network | 在 PE row 內 | ❌ Phase 2 才 instantiate per-row (施柏安) |
| Local Buf | 在 PE row 內 | ❌ Phase 2 才加 (Δ4) |

**修正內容**:
- `rtl/dist/merge_tree.v` 刪除 (那個 global tree 是錯的)
- 新增 `rtl/pe/merge_tree_radix16.v` (per-row,4-stage pipelined,radix-16)
- pe_row.v 重寫,內部 instantiate 16 mul + 1 tree + 1 acc

**未修正**:Phase 2 才會在 pe_row 內加 MFIU / Dist / Buf;這些 module 的 stub 還在 `rtl/mfiu/`、`rtl/dist/`、`rtl/mem/` 裡,但**還沒被 pe_row instantiate**(top.v 也還沒接)。等 Phase 2 開始時,owner 把 stub 改成真的 module,黃妍心 把它們 wrap 進 pe_row。

---

## ✅ Δ2 — B 跨 row vertical forwarding [已修正]

| | 論文 (Fig 7 step ④) | 修正後現況 |
|---|---|---|
| B 路徑 | row 0 → row 1 → row 2 → ...(垂直 link) | ✅ pe_array 內加了 `b_chain[]`,row r 的 b 從 row r-1 的 b_vec_out 來 |
| dist net 負擔 | 1 條 B 進 row 0 即可 | ✅ pe_array 介面從 `b_grid[16][16][8]` (2048b) 縮成 `b_vec_top[16][8]` (128b) |

**修正內容**:
- pe_row 加 `b_vec_in` / `b_vec_out` / `b_valid_out` 三個 port
- pe_row 內加 1-cycle latch 把 b_vec_in 延 1 拍給 b_vec_out
- pe_array 在 generate loop 把 16 條 row 的 B 串成 chain:
  ```verilog
  pe_row u_row[r] (.b_vec_in(b_chain[r]), .b_vec_out(b_chain[r+1]), ...);
  ```

---

## ✅ Δ3 — Merge-Reduction Tree 位置 [已修正]

| | 論文 (Fig 5/6) | 修正後現況 |
|---|---|---|
| MR tree 數量 | 16 棵 (per-row) | ✅ 16 棵 (`merge_tree_radix16` 在每條 pe_row 內) |
| 觸發頻率 | 每 cycle 推進 (4-stage pipelined) | ✅ 每 cycle 推進,4 stage |
| Dense IP 觸發 | 每 cycle reduce 16 個 partial → 1 個 dot product element | ✅ 對應 pe_row 內部 acc 累加 4 stage 之後的 tree_sum |

**修正內容**:
- 刪掉 `rtl/dist/merge_tree.v`(global tree,本來就不對)
- 新增 `rtl/pe/merge_tree_radix16.v` per-row,4 stage 16→8→4→2→1
- 位寬正確處理:partial INT16 → s1 INT17 → s2 INT18 → s3 INT19 → sum INT32 (sign-extend)

**TrIP 預留**:tree 第二版要支援 sub-tree slicing (radix-2/4/8 切片產出 N 個 C 元素)。
目前只支援單一 16→1 模式,Phase 2 才加。

---

## ⏸️ Δ4 — Per-row Local Buffer [Phase 2 處理]

| | 論文 (§III.B) | 現況 |
|---|---|---|
| Local Buf | 4 banks × 16-word wide,在每 PE row 內 | ❌ 沒實作 |

**為什麼可以延後**:
- Dense IP 用 1 個 acc register per row 就夠 (paper 在 Fig 6 也只畫 1 個 buf 入口),
  所以 Phase 1 MVP 不需要 buf
- TrIP/TrGT/TrGS 才需要 4-bank scatter buf

**Phase 2 要決議**:
- (a) 黃妍心 在 pe_row 內加 (最貼 paper)
- (b) 陳秉弘 在 global_buffer 內切 16 個 sub-region 模擬 per-row (分工最少)

---

## 其他次要差異 (不修,記錄即可)

| 項目 | 論文 | 我們 | 狀態 |
|---|---|---|---|
| 量化精度 | FP32 | INT8 | ✅ proposal 已縮 |
| Cache 大小 | 16 MB / 4-cluster | 16 KB single-tier | ✅ proposal 已縮 |
| Pipeline stage 數 (IP) | 沒明寫 | ✅ 7 stages,對齊 PPTX p.13 | ✅ pkg.sv 已更新 |
| Pipeline stage 數 (TrIP) | 沒明寫 | ✅ 9 stages,對齊 PPTX p.14 | ✅ pkg.sv 已更新 |
| MFIU 規模 | 4 rows × 4 cols / 128-bit bitmask | 4×4 / 16-bit bitmask | ✅ 對齊 |
| MAC 累加位置 | tree 後一個 acc per row | ✅ 改對 (本來在 mac_unit 內,已搬到 pe_row) | ✅ 已修 |

---

## 本週 sync 要決議的事 (Phase 1 結尾前必鎖)

1. **§1 a_grid layout**:陳秉弘 設計 SRAM bank → a_grid 切片邏輯 (16 banks × 64-bit 不夠 2048-bit/cycle)
2. **§4 dataflow_ctrl owner**:orphan FSM 認領
3. **Δ4 timing**:Phase 2 哪週開始加 local buf
4. **K-tile loop**:K > 16 時 acc_clear / acc_dump 的 cycle counter 由誰寫 (建議 dataflow_ctrl owner)
