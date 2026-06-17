# 單 fiber → 多 fiber 切換指南

> Owner: QuillQ（distribution / NoC）
> 目的：整合目前跑**單 fiber**；若團隊要升**多 fiber**（貼 paper 4×4），這份列出「要改哪些檔」。
> **重點：distribution 這側（我）已經 ready，缺的是 MFIU/adapter + 2D 餵料（上游）。**

---

## 現況 vs 目標

| | 現況（單 fiber） | 目標（多 fiber） |
|---|---|---|
| MFIU 引擎 | `mfiu` 設 1×1 | `mfiu` 設 4×4（`N_A_FIBER`×`N_B_FIBER`） |
| routing 索引 | 單一 `effectual_idx` | 三條 `a_row_sel`/`b_col_sel`/`k_sel` |
| distribution | `dist_net_row`（1D gather） | **`dist_net_row_trip`（2D gather，已寫好測過）** |
| a/b 值來源 | `a_vec_in[16]`（1D） | `a_values[4][16]`（2D，fiber×k） |
| PE 利用率 | 稀疏時 ~25% | 可到 100% |

---

## 要改的檔（依負責人）

### ① distribution —— ✅ 我已 ready，不用改
- 直接用 `rtl/dist/dist_net_row_trip.sv`（已測：gather / 廣播 / invalid / **4 輸出 packing 100%**，`make tb_dist_net_trip` 全過）。
- 它吃三條 sel + 2D `a_values`/`b_values`，吐 registered `a_lane_out`/`b_lane_out`。

### ② MFIU adapter（`rtl/mfiu/mfiu_adapter.sv`）—— MFIU owner 改
- 把內部 `mfiu` 核心從 `NUM_ROWS=1, NUM_COLS=1` 改成 `NUM_ROWS=N_A_FIBER, NUM_COLS=N_B_FIBER`（4×4）。
- **輸出改成吐三條** `a_row_sel`/`b_col_sel`/`k_sel`（現在被壓成單一 `effectual_idx`）。
- `cut_after`/`out_addr` 要由 `a_row_sel`/`b_col_sel` 變化推出（相鄰 lane 座標變了就剪 sub-tree）。
- ⚠️ K_BITS / LANES / overflow 的確切尺寸要 MFIU owner 定（4×4 一拍候選變多，可能要分批）。

### ③ pe_row_full（`rtl/pe/pe_row_full.sv`）—— Iris 改
- 把 `dist_net_row u_dist` 換成 `dist_net_row_trip`。
- port 對應（楊的 flat bus → 我的多維 port，lane l 取 `[l*W +: W]`）：

| 楊 MFIU 輸出 | 接到 dist_net_row_trip |
|---|---|
| `lane_valid_o[LANES]` | `lane_valid` |
| `a_row_sel_o[LANES*ROW_IDX_W]` | `a_row_sel[LANES][ROW_IDX_W]` |
| `b_col_sel_o[LANES*COL_IDX_W]` | `b_col_sel[LANES][COL_IDX_W]` |
| `k_sel_o[LANES*K_IDX_W]` | `k_sel[LANES][K_IDX_W]` |

- 值的接法從 `a_vec_in(1D)` 改成 `a_values(2D)`（見 ④）。

### ④ 2D 值餵料（local buffer / 值來源）—— buffer owner 新增
- distribution 現在要整個 `a_values[N_A_FIBER][BITMASK_W]`（4 fiber × 16 k）、`b_values` 同理。
- 單 fiber 只餵一條 fiber 的 16 值；多 fiber 要同時供 4 條 A fiber + 4 條 B fiber。
- 這條膠水現在沒人做，是升多 fiber 的真正新工作。

---

## 一句話

- **distribution（我）：ready，換 module + 接線即可。**
- **缺口在上游**：MFIU adapter 開 4×4 + 吐三條 sel、2D 餵料。
- 要不要做是團隊決定；distribution 不是瓶頸。
