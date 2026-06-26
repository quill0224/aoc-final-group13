# 個人負責項目：Multi-Fiber Intersection Unit

我主要負責 Multi-Fiber Intersection Unit（MFIU）的 RTL 設計、功能驗證與 PE row 整合。MFIU 是 TrIP 稀疏運算路徑的前端模組，負責比較一條 A fiber 與多條 B fiber 的 bitmask，找出兩者在相同 K 位置上共同非零的元素。只有這些有效交集會被送往後端計算，因此可以減少不必要的零值乘法。

由於每條 PE row 配置 16 個乘法器，MFIU 會根據各 B fiber 的交集數量進行動態分組。每批最多接收 4 條 B fiber，並在總交集數不超過 16 的條件下，盡可能將多條 B fiber 打包至同一批次，以提升乘法器的使用率。MFIU 同時利用 prefix count 將原始 bitmask 位置轉換成壓縮資料索引，產生 A 與 B 的 metadata，並回報本批實際使用的 B fiber 數量。

產生的 metadata 會交由 crossbar 讀取正確的 A、B 壓縮值，再送入 MAC 與 reduction tree 完成乘法及分段加總。此模組已透過 `pe_mfiu_seq` 整合至 PE row，並使用 Verilator 檢查 RTL 寫法與執行相關功能測試。驗證結果未發現非預期 latch、組合迴路或多重驅動等問題，稀疏動態分組、metadata 產生及 PE row 整合測試皆可正常通過。

## 面積最佳化紀錄

### Gather-in-MFIU（主要最佳化，約 -29%）

**問題**：原本 `pe_mfiu_seq` 在 `always_comb` 中同時對 16 個 lane 執行 gather（每個 lane 各做一個 4-to-1 × 16-to-1 × 8-bit MUX），共約 10,000 MUX cell/instance × 16 rows ≈ 160,000 MUX cells。

**作法**：將 gather 移進 MFIU 的 FILL_COL 狀態。每個 clock cycle 只處理一個 hit，直接從 `a_nz_row_i` 與 `b_nz_batch_i` 讀取當前 prefix 對應的值，儲存進 `a_lane_r[lane_count_q]` 與 `b_lane_r[lane_count_q]`，同時記錄 `lane_col_r` 與 `lane_valid_r`。這樣一組共用的 4-to-1 + 16-to-1 mux 取代了 16 組並行的 gather mux。

**`mfiu.sv` 新增介面**：
- 輸入：`a_nz_row_i [N_MUL_ROW*8-1:0]`、`b_nz_batch_i [N_B_FIBER*N_MUL_ROW*8-1:0]`、`col_ptr_i [3:0]`
- 輸出：`a_lane_data_o`、`b_lane_data_o`、`lane_col_o`、`lane_valid_o`

**`pe_mfiu_seq.sv` 簡化**：移除原本 16-lane 的 `always_comb` gather block 與 output `always_ff`，改成 `out_valid` 僅 register mfiu 的 `meta_valid`，輸出直接接 mfiu 的 lane data registers。

**驗證**：tb_pe_mfiu_seq（PASS）、tb_pe_row（PASS）、tb_pe_row_tail（PASS）

**面積結果（Yosys synth -noabc, pe_array top, 16 rows）**：

| 指標         | 最佳化前       | 最佳化後       | 減少量         |
|------------|------------|------------|------------|
| Total cells | ~885,568   | 625,902    | -259,666 (-29.3%) |
| MUX cells   | ~328,000   | 234,871    | -93,000 (-28.5%) |
| pe_mfiu_seq | ~15,000+   | 7,086      |             |
| mfiu        | ~2,500     | 4,375      | (含 lane registers) |

### 其他已完成最佳化

- **SRAM Blackbox**：local_buffer_row 的 SRAM 在合成時使用 blackbox，避免展開成 FF。
- **Crossbar 移除**：去除 crossbar 模組，改由 MFIU 直接輸出 gathered 值。
- **BUCKET_REDUCE**：以 4 個 bucket 累加取代 general reduction_tree_radix16。
