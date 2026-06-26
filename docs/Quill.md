# Distribution / NoC — 多 fiber TrIP 路線（Quill）

本部分負責加速器的 **distribution network（NoC）**：把 MFIU 算出的「有效交集索引」拿去從 fiber buffer 撈出正確的 A / B 值、route 到對的 multiplier lane，是 MFIU(交集) 與 MAC(運算) 之間的橋。

我這條線走的是 **paper 的多 fiber TrIP 路線**（Trapezoid ISCA'24 Fig 6 A/B Distribution + Fig 11/12 MFIU），目標是讓一排 16 個乘法器在稀疏時也能透過「動態打包多個輸出 (r,c)」填滿、逼近 100% 利用率。

> **誠實定位（給組長彙整 report.md 用）**
> 我在 6/16–6/17 先做出「多 fiber TrIP 2D-gather 分配 + 動態多欄 packing」的**端到端可行性驗證（PoC）**：`dist_net_row_trip` + `mfiu_adapter_mf`，並用 testbench 跑通 bitmask → 交集 → 2D gather 值正確。
> 最終整合（6/22）由 Iris 把同一條資料流收斂進 PE datapath，改用她的 `pe_mfiu_seq` + `crossbar`（介面從我的「三條 sel + 2D port」改成「flat meta bus」）。**main 上跑的是她的整合版，我的 PoC 模組留在 `feat/quill-dist-phase2` 分支、沒有 merge 進 main。** 下面每個模組都標了對應關係。

---

## 我做的東西 vs 最終整合對應

| 我的模組（`feat/quill-dist-phase2`） | 做了什麼 | 最終 main 的對應 | 狀態 |
|---|---|---|---|
| `rtl/dist/dist_net_row_trip.sv` | 多 fiber TrIP **2D-gather** 分配網路（三條 sel → a/b lane）| Iris `rtl/dist/crossbar.sv`（grp_base + b_meta 做 2D gather）| 概念被採用、檔案被取代 |
| `rtl/mfiu/mfiu_adapter_mf.sv` | 多 fiber **MFIU adapter**（4×4 packing，吐三條 sel）| Iris `rtl/pe/pe_mfiu_seq.sv`（動態 1–4 B 欄 packing）| 概念被採用、檔案被取代 |
| `docs/multi-fiber-switch-guide.md` | 單→多 fiber 切換介面分析 | —（整合時直接走多 fiber）| 設計文件 |
| `sim/tb_dist_net_row_trip.sv`、`sim/tb_mfiu_mf_chain.sv` | PoC 驗證 | Iris 自己的 tb | 驗證用 |
| Phase-1 dense identity pass-through（最早的 `dist_net_row` 原型）| 驗證 dense IP 退化成 pass-through | 併入整合後由 Iris 重寫 | 早期原型 |

> 一句話：**我開的是「多 fiber TrIP 2D-gather」這條路、並先驗證它可行；最終整合線就是這條路，只是 datapath 介面由 Iris 收斂重寫。**

---

## 設計演進（Phase-1 → 單 fiber → 多 fiber）

```
Phase-1  dense identity pass-through      out[m] = in[m]              先驗證 dense IP 等價 pass-through
   │
   ▼
單 fiber  1D gather (dist_net_row)         out[m] = in[ idx[m] ]      單一 effectual_idx,a/b 共用
   │
   ▼
多 fiber  2D gather (dist_net_row_trip)    a[l]=a[row[l]][k[l]]       三條 sel(row/col/k),a 用 row、
          + mfiu_adapter_mf (4×4 packing)  b[l]=b[col[l]][k[l]]       b 用 col、共用 k → 一排 16 lane
                                                                      同時服務多個輸出 (r,c)
```

關鍵跳躍在第三步：從「單一 index 的 1D gather」升級成「(fiber, k) 兩座標的 2D gather」，才有辦法把多條 A fiber × 多欄 B 動態打包進同一排 lane，這也是 TrIP 100% 利用率的來源。

---

## 模組說明

### dist/dist_net_row_trip.sv — 多 fiber TrIP 2D-gather 分配網路

把 MFIU 算出的有效 `(row, col, k)` 索引，從 fiber value buffer 把對的 a / b 值 gather 到對的 multiplier lane：

```
a_lane[l] = a_values[ a_row_sel[l] ][ k_sel[l] ]
b_lane[l] = b_values[ b_col_sel[l] ][ k_sel[l] ]
```

- **2D gather**：每條 lane 用 `(fiber, k)` 兩個座標取值（不是單一 index），對應 4×4 fiber packing，一排 16 lane 可同時服務多個輸出 `(r,c)`。
- 實作上是 **一排 16 顆 64-to-1 mux**（a/b 各一組，深度 `A_DEPTH = N_A_FIBER × K_SLOTS = 64`）。為了 iverilog 不能用變數 index packed array 的限制，內部先把 2D `a_values[fiber][k]` 攤成 flat `a_flat[fiber*16 + k]`。
- **無效 lane**（`lane_valid[l]=0`）直接吐 0，下游乘法器算 0、不污染 reduction。
- **廣播天然支援**：多條 lane 指同一 `(row,k)` slot 沒問題（對應 TrGT stretch），這是 Benes network 做不到的。
- 補 1 級 output register（`DIST_STAGES=1`）斷開 64-to-1 mux 的長組合路徑，並把 `in_valid` 對齊成 `out_valid`。

| 訊號 | 方向 | 寬度 | 說明 |
|------|------|------|------|
| `clk` / `rst_n` / `en` | in | 1 | 時脈 / reset / pipeline enable |
| `in_valid` / `out_valid` | in / out | 1 | 輸入有效 → 延 1 拍輸出有效 |
| `a_values` / `b_values` | in | [4][16][8] | 4 條 fiber × 16 k-slot 的原始值（上游餵）|
| `a_row_sel` / `b_col_sel` / `k_sel` | in | [16][2] / [16][2] / [16][4] | 各 lane 的 A fiber / B 欄 / k 座標 |
| `lane_valid` | in | [16] | 各 lane 有效 |
| `a_lane_out` / `b_lane_out` | out | [16][8] / [16][8] | gather 後給 MAC 的 a / b（registered）|
| `lane_valid_out` | out | [16] | 各 lane 有效（registered）|

> **最終整合對應**：Iris 的 `crossbar.sv` 做同一件事，但介面不同——她的 MFIU 不傳「三條 sel」而是 `grp_base + a_meta + b_meta`（`b_meta[5:4]` 是本批 B 相對欄號、`[3:0]` 是壓縮 index），crossbar 用 `b_col = grp_base + b_meta[5:4]` 還原實際欄。功能等價，差在 meta 編碼方式。

### mfiu/mfiu_adapter_mf.sv — 多 fiber MFIU adapter（4×4 packing）

把交集核心 `mfiu.v`（楊承豫）設成 `N_A_FIBER × N_B_FIBER = 4×4`、`K_BITS=16`，掃 4×4×16 個候選，把 effectual `(r,c,k)` 壓進 16 lane，再轉成 `dist_net_row_trip` 要的多維 routing metadata。

- **做的事**：(1) instantiate `mfiu` 核心；(2) 把核心的 flat bus 輸出（`a_row_sel_o` / `b_col_sel_o` / `k_sel_o`）轉成多維 port；(3) 延 `MFIU_STAGES` 拍，對齊 `dist_net_row_trip` 被延遲的值路徑。
- **overflow**：一拍 4×4×16 候選遠超 16 lane，核心壓滿 16 後拉 `overflow`；replay（把沒裝完的補下一拍）屬上游 ctrl，本檔只透傳。

| 訊號 | 方向 | 寬度 | 說明 |
|------|------|------|------|
| `clk` / `rst_n` / `en` / `in_valid` | in | 1 | 時脈 / reset / enable / 輸入有效 |
| `a_bitmask` / `b_bitmask` | in | 64 / 64 | 4 條 fiber × 16 bit 的 bitmask |
| `lane_valid` | out | [16] | 各 lane 有效 |
| `a_row_sel` / `b_col_sel` / `k_sel` | out | [16][2] / [16][2] / [16][4] | 各 lane 的 A fiber / B 欄 / k 座標（registered）|
| `match_count` | out | 5 | 本拍有效交集數 |
| `overflow` | out | 1 | 候選 > 16 lane（需 replay）|
| `meta_valid` | out | 1 | metadata 有效 |

> **最終整合對應**：Iris 的 `pe_mfiu_seq.sv` 做同一件事（per-row 把 A 列與 B 欄 bitmask 餵進 `mfiu` 做交集、動態打包 1–4 欄 B），但她把 packing 與 sequencing 做在 datapath 內、輸出 `grp_base / a_meta / b_meta` 給 crossbar，而不是我這版的「三條 sel」。

### dist/dist_net_row.sv（Phase-1 / 單 fiber）— 早期原型

最早驗證用：`out[m] = in[ effectual_idx[m] ]` 的單一 effectual_idx 1D gather，a/b 共用同一條 index。Dense IP 的 identity idx 讓它自動退化成 pass-through（`out[m]=in[m]`），所以不需要 mode 分支。這版確認了「dense 與 sparse 可以共用同一張 crossbar、差別只在 index」這件事，是後面升多 fiber 的起點。

> 此檔在整合時被 Iris 重寫併入 datapath；多 fiber 路線改走 `dist_net_row_trip`。

---

## 端到端驗證（testbench）

| testbench | 測什麼 | 結果 |
|---|---|---|
| `sim/tb_dist_net_row_trip.sv` | T1 一般 gather（lane 拿到 `a=row*16+k`、`b=col*16+k`）/ invalid lane 補 0 / 廣播（兩 lane 指同一 `(row,k)` 拿同值）/ registered 對齊 | Scenario 1 + **多 fiber packing：4 個輸出塞滿 16 lane、100% 利用率** 全過 |
| `sim/tb_mfiu_mf_chain.sv` | 端到端鏈：bitmask → `mfiu_adapter_mf` 交集 → `dist_net_row_trip` 2D gather，比對最終 a/b 值 | ALL PASS（bitmask → MFIU 交集 → 2D gather 值正確）|
| `sim/tb_dist_net_row.sv` | Phase-1 單 fiber gather / dense pass-through | ALL PASS |

---

## 單 → 多 fiber 切換介面分析

整合前我寫了 `docs/multi-fiber-switch-guide.md`，盤點「若團隊要從單 fiber 升多 fiber 要動哪些檔」，結論：

| | 單 fiber | 多 fiber |
|---|---|---|
| MFIU 引擎 | `mfiu` 設 1×1 | `mfiu` 設 4×4 |
| routing 索引 | 單一 `effectual_idx` | 三條 `a_row_sel`/`b_col_sel`/`k_sel` |
| distribution | `dist_net_row`（1D）| **`dist_net_row_trip`（2D，已測）** |
| 值來源 | `a_vec_in[16]`（1D）| `a_values[4][16]`（2D）|
| PE 利用率 | 稀疏 ~25% | 可達 100% |

當時 distribution 這側我已 ready，剩的缺口在上游：MFIU 開 4×4 + 2D 餵料（同時供 4 條 A + 4 條 B fiber 的 bitmask 與 value）。最終整合時這個缺口由 Iris 在 datapath 內一併解掉（`pe_ab_buffer` 餵 16 條 A/B、`pe_mfiu_seq` 做 packing），所以沒有沿用我「三條 sel + 2D port」的介面。

---

## 參考資料

1. M. Yan et al., "Trapezoid: A Versatile Accelerator for Dense and Sparse Matrix Multiplications," ISCA 2024.（Fig 6 A/B Distribution、Fig 11/12 MFIU）
2. F. Muñoz-Martínez et al., "Flexagon: A Multi-Dataflow Sparse-Sparse Matrix Multiplication Accelerator," ASPLOS 2023.（reduction/merge network 參考）
