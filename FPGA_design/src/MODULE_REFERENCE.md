# TrIP MVP 硬體模組說明

本文件說明 `FPGA_design/src/` 下所有 RTL 模組的功能、參數、輸入輸出介面，以及各模組之間的連接關係。

---

## 模組層級總覽

```
trip_tile_compute_engine          ← 最上層：K-chunk tiling + C-tile 累加
└── trip_compute_top              ← 單次 K-chunk 端到端 compute path
    ├── trip_intersection_top     ← Intersection 前端（含 FSM）
    │   ├── bitmask_buffer (A)   ← A-side sparse fiber 儲存
    │   ├── bitmask_buffer (B)   ← B-side sparse fiber 儲存
    │   └── mfiu                 ← Bitmask intersection → lane metadata
    ├── trip_distribution_network ← A/B value 路由到各乘法器 lane
    ├── pe_lane × LANES           ← 乘法器 lane
    ├── trip_reduction_tree       ← 依 output coordinate 累加 partial products
    └── row_local_buffer          ← 輸出 partial sum 暫存
```

資料流向：

```
bitmask_buffer
    │  (mask + values)
    ▼
mfiu  ────────────────────────────────────────────────────────────┐
    │  (lane_valid, a_row_sel, b_col_sel, k_sel)                 │
    ▼                                                             │
trip_distribution_network                                         │
    │  (lane_a, lane_b, lane_valid)                              │
    ▼                                                             │ (sel routing)
pe_lane × LANES                                                   │
    │  (products, valid)                                          │
    ▼                                                             │
trip_reduction_tree ◄─────────────────────────────────────────────┘
    │  (out_value[r][c], out_valid[r][c])
    ▼
row_local_buffer
    │  (rd_data_o, rd_valid_o)
    ▼
  輸出
```

---

## 1. `bitmask_buffer`

**檔案：** [bitmask_buffer.v](bitmask_buffer.v)

### 功能

儲存 TrIP sparse fiber 的 metadata 與 values。每筆 entry 包含：

- `fiber id`：此 fiber 對應的 row/column id
- `bitmask`：哪些 k slot 非零（`K_BITS` 位元）
- `values`：fixed-slot value 陣列（共 `K_BITS` 個槽，每槽 `DATA_WIDTH` 位元）

採用 **fixed-slot layout**：即使某 k slot 為零，仍保留對應的 value slot，讓 MFIU 輸出的 `k_sel` 可直接索引，無需 prefix-sum。

### 參數

| 參數 | 預設值 | 說明 |
|---|---|---|
| `NUM_FIBERS` | 4 | buffer 中 fiber entry 數量 |
| `K_BITS` | 4 | fiber 維度（bitmask 寬度） |
| `DATA_WIDTH` | 16 | 每個 value slot 的位元數 |
| `ID_WIDTH` | 4 | fiber ID 位元數 |
| `ADDR_WIDTH` | `clog2(NUM_FIBERS)` | 讀寫地址位元數（自動計算） |
| `K_IDX_W` | `clog2(K_BITS)` | k slot 索引位元數（自動計算） |

### 輸入

| 訊號 | 寬度 | 說明 |
|---|---|---|
| `clk` | 1 | 時脈 |
| `reset` | 1 | 同步重置，清空所有 entry |
| `wr_en_i` | 1 | 寫入致能 |
| `wr_addr_i` | `ADDR_WIDTH` | 寫入地址 |
| `wr_id_i` | `ID_WIDTH` | 寫入的 fiber ID |
| `wr_mask_i` | `K_BITS` | 寫入的 bitmask |
| `wr_values_i` | `K_BITS × DATA_WIDTH` | 寫入的 fixed-slot values（packed） |
| `rd_addr_i` | `ADDR_WIDTH` | 讀取地址 |
| `k_sel_i` | `K_IDX_W` | indexed value 的 k 索引 |

### 輸出

| 訊號 | 寬度 | 說明 |
|---|---|---|
| `rd_id_o` | `ID_WIDTH` | 讀出的 fiber ID（**1-cycle latency**） |
| `rd_mask_o` | `K_BITS` | 讀出的 bitmask（**1-cycle latency**） |
| `rd_values_o` | `K_BITS × DATA_WIDTH` | 讀出的完整 values（**1-cycle latency**） |
| `k_value_o` | `DATA_WIDTH` | 由 `k_sel_i` 索引的單一 value（combinational，從 `rd_values_o` 取出） |

### 時序特性

- **寫入**：`posedge clk` 時，若 `wr_en_i=1` 則寫入 `wr_addr_i` 指定的 entry。
- **讀取**：Registered read，第 N 個 cycle 設定 `rd_addr_i`，第 N+1 個 cycle 讀到 `rd_id_o` / `rd_mask_o` / `rd_values_o`。
- **`k_value_o`**：Combinational，從目前 registered 的 `rd_values_o` 中取出 `k_sel_i` 對應的 slot。

---

## 2. `mfiu`

**檔案：** [mfiu.v](mfiu.v)

### 功能

Multi-Fiber Intersection Unit。對所有 (row, column) fiber pair 做 bitmask AND，找出雙方皆非零的 k slot（effectual MAC），依掃描順序填入輸出 lane。

掃描順序：`r` → `c` → `k`（r 最外層，k 最內層）

### 參數

| 參數 | 預設值 | 說明 |
|---|---|---|
| `NUM_ROWS` | 2 | A-side fiber 數量 |
| `NUM_COLS` | 2 | B-side fiber 數量 |
| `K_BITS` | 4 | bitmask 寬度 |
| `LANES` | 4 | 最多輸出幾個 effectual MAC |

### 輸入

| 訊號 | 寬度 | 說明 |
|---|---|---|
| `a_mask_i` | `NUM_ROWS × K_BITS` | 所有 A row bitmask（packed，row r 在 `[r*K_BITS +: K_BITS]`） |
| `b_mask_i` | `NUM_COLS × K_BITS` | 所有 B column bitmask（packed，col c 在 `[c*K_BITS +: K_BITS]`） |

### 輸出

| 訊號 | 寬度 | 說明 |
|---|---|---|
| `lane_valid_o` | `LANES` | 每個 lane 是否有有效的 effectual MAC |
| `a_row_sel_o` | `LANES × ROW_IDX_W` | 每個 lane 對應的 A row index（packed） |
| `b_col_sel_o` | `LANES × COL_IDX_W` | 每個 lane 對應的 B column index（packed） |
| `k_sel_o` | `LANES × K_IDX_W` | 每個 lane 對應的 k slot index（packed） |
| `match_count_o` | `clog2(LANES+1)` | 填入 lane 的數量（上限 LANES，不是總 effectual MAC 數） |
| `overflow_o` | 1 | 實際 effectual MAC 數量超過 LANES 時為 1 |

### 時序特性

全 **combinational** 電路，無時脈。輸出在輸入改變後一個 delta 時間內穩定。

### Packing 規則範例

```
a_mask_i = { A1_mask, A0_mask }   // A0 在低位
b_mask_i = { B1_mask, B0_mask }   // B0 在低位

a_row_sel_o 的 lane L 在 [L*ROW_IDX_W +: ROW_IDX_W]
```

---

## 3. `pe_lane`

**檔案：** [pe_lane.v](pe_lane.v)

### 功能

單一乘法器 lane。接受 valid 旗標與 A、B 兩個運算元，輸出乘積。支援 signed/unsigned 模式。

### 參數

| 參數 | 預設值 | 說明 |
|---|---|---|
| `DATA_WIDTH` | 16 | 輸入運算元位元數 |
| `PRODUCT_WIDTH` | `DATA_WIDTH × 2` | 輸出乘積位元數 |
| `SIGNED_DATA` | 0 | 0 = unsigned，1 = signed |

### 輸入

| 訊號 | 寬度 | 說明 |
|---|---|---|
| `valid_i` | 1 | 此 lane 本 cycle 有有效 MAC |
| `a_i` | `DATA_WIDTH` | A 運算元 |
| `b_i` | `DATA_WIDTH` | B 運算元 |

### 輸出

| 訊號 | 寬度 | 說明 |
|---|---|---|
| `valid_o` | 1 | 直通 `valid_i`（無 pipeline 延遲） |
| `product_o` | `PRODUCT_WIDTH` | `a_i × b_i`；若 `valid_i=0` 則輸出 0 |

### 時序特性

全 **combinational**，無 pipeline register。

---

## 4. `trip_distribution_network`

**檔案：** [trip_distribution_network.v](trip_distribution_network.v)

### 功能

A/B value 路由網路（小型 crossbar）。根據 MFIU 輸出的 `(a_row_sel, b_col_sel, k_sel)` metadata，從 A/B fiber 的 fixed-slot values 中取出對應的單一 value，分配給各個乘法器 lane。

### 參數

| 參數 | 預設值 | 說明 |
|---|---|---|
| `NUM_ROWS` | 2 | A fiber 數量 |
| `NUM_COLS` | 2 | B fiber 數量 |
| `K_BITS` | 4 | fiber 維度 |
| `LANES` | 4 | 乘法器 lane 數量 |
| `DATA_WIDTH` | 16 | value 位元數 |

### 輸入

| 訊號 | 寬度 | 說明 |
|---|---|---|
| `a_values_i` | `NUM_ROWS × K_BITS × DATA_WIDTH` | 所有 A fiber 的 fixed-slot values（row r 在 `[r*K_BITS*DW +: K_BITS*DW]`） |
| `b_values_i` | `NUM_COLS × K_BITS × DATA_WIDTH` | 所有 B fiber 的 fixed-slot values |
| `lane_valid_i` | `LANES` | 來自 MFIU 的 lane valid |
| `a_row_sel_i` | `LANES × ROW_IDX_W` | 來自 MFIU，每 lane 的 A row index |
| `b_col_sel_i` | `LANES × COL_IDX_W` | 來自 MFIU，每 lane 的 B column index |
| `k_sel_i` | `LANES × K_IDX_W` | 來自 MFIU，每 lane 的 k slot index |

### 輸出

| 訊號 | 寬度 | 說明 |
|---|---|---|
| `lane_valid_o` | `LANES` | 直通 `lane_valid_i` |
| `lane_a_o` | `LANES × DATA_WIDTH` | 每個 lane 取到的 A value（`valid=0` 時輸出 0） |
| `lane_b_o` | `LANES × DATA_WIDTH` | 每個 lane 取到的 B value（`valid=0` 時輸出 0） |

### 時序特性

全 **combinational**。用 `generate` 展開 lane，每 lane 的定址公式：

```
a_slot = row_sel * K_BITS + k_sel
b_slot = col_sel * K_BITS + k_sel
```

---

## 5. `trip_reduction_tree`

**檔案：** [trip_reduction_tree.v](trip_reduction_tree.v)

### 功能

依 output coordinate `(row, col)` 把各 lane 的 partial product 累加。對每個輸出座標，掃描所有 lane，若 lane 的 `(a_row_sel, b_col_sel)` 符合此座標且 valid，則加入累加器。

### 參數

| 參數 | 預設值 | 說明 |
|---|---|---|
| `NUM_ROWS` | 2 | 輸出矩陣的 row 數 |
| `NUM_COLS` | 2 | 輸出矩陣的 column 數 |
| `LANES` | 4 | 輸入 lane 數量 |
| `DATA_WIDTH` | 16 | 原始運算元寬度 |
| `PRODUCT_WIDTH` | `DATA_WIDTH × 2` | 乘積寬度 |
| `ACC_WIDTH` | `PRODUCT_WIDTH + clog2(LANES+1)` | 累加器寬度（防止加法溢位） |
| `SIGNED_DATA` | 0 | 0 = unsigned 符號擴展，1 = signed 符號擴展 |

### 輸入

| 訊號 | 寬度 | 說明 |
|---|---|---|
| `lane_valid_i` | `LANES` | 每個 lane 的 valid |
| `a_row_sel_i` | `LANES × ROW_IDX_W` | 每個 lane 的 A row index（output tag） |
| `b_col_sel_i` | `LANES × COL_IDX_W` | 每個 lane 的 B column index（output tag） |
| `lane_product_i` | `LANES × PRODUCT_WIDTH` | 每個 lane 的乘積 |

### 輸出

| 訊號 | 寬度 | 說明 |
|---|---|---|
| `out_valid_o` | `NUM_ROWS × NUM_COLS` | 每個輸出座標是否有非零結果 |
| `out_value_o` | `NUM_ROWS × NUM_COLS × ACC_WIDTH` | 每個輸出座標的累加結果（`[r*NUM_COLS+c]` 對應 C[r][c]） |

### 注意事項

- **全 combinational**，無暫存器。
- `out_valid_o[r*NUM_COLS+c]` 只在 `sum != 0` 時為 1。在 signed 模式下若 partial products 正好抵銷為 0，valid 會錯誤為 0（已知限制）。

---

## 6. `row_local_buffer`

**檔案：** [row_local_buffer.v](row_local_buffer.v)

### 功能

輸出座標暫存器。每個輸出座標 `C[r][c]` 各有一個 `DATA_WIDTH` 位元的暫存器。在 `wr_en_i=1` 時，依照 `wr_valid_i` 逐一寫入；`wr_valid_i[i]=0` 的座標會被清零。

### 參數

| 參數 | 預設值 | 說明 |
|---|---|---|
| `NUM_ROWS` | 2 | 輸出矩陣 row 數 |
| `NUM_COLS` | 2 | 輸出矩陣 column 數 |
| `DATA_WIDTH` | 35 | 每個輸出的位元數（通常等於 `ACC_WIDTH`） |
| `NUM_OUTPUTS` | `NUM_ROWS × NUM_COLS` | 輸出座標總數（自動計算） |

### 輸入

| 訊號 | 寬度 | 說明 |
|---|---|---|
| `clk` | 1 | 時脈 |
| `reset` | 1 | 同步重置，清空所有暫存器 |
| `wr_en_i` | 1 | 寫入致能（通常由 `intersection_done` 驅動） |
| `wr_valid_i` | `NUM_OUTPUTS` | 哪些座標有有效結果 |
| `wr_data_i` | `NUM_OUTPUTS × DATA_WIDTH` | 寫入的資料（packed，座標 i 在 `[i*DW +: DW]`） |

### 輸出

| 訊號 | 寬度 | 說明 |
|---|---|---|
| `rd_valid_o` | `NUM_OUTPUTS` | 哪些座標有效（combinational，直接讀 `valid_mem`） |
| `rd_data_o` | `NUM_OUTPUTS × DATA_WIDTH` | 各座標的儲存值（combinational，直接讀 `data_mem`） |

### 注意事項

當 `wr_en_i=1` 且 `wr_valid_i[i]=0` 時，`data_mem[i]` 被清為 0（非保留舊值）。這意味每次 `intersection_done` 都會完整更新 buffer，適合 single-chunk MVP，不直接支援跨 chunk 的 scatter-accumulate（此功能由 `trip_tile_compute_engine` 的外層 accumulator 實作）。

---

## 7. `trip_intersection_top`

**檔案：** [trip_intersection_top.v](trip_intersection_top.v)

### 功能

Intersection 前端整合層。包含：

- A/B 各一個 `bitmask_buffer`
- 一個 `mfiu`
- 一個 FSM

FSM 負責在 `start_i` 觸發後，依序從 A/B buffer 讀出所有 fiber mask，capture 後送入 MFIU，最後以 `done_o` pulse 通知輸出有效。

### 參數

| 參數 | 說明 |
|---|---|
| `NUM_ROWS` | A fiber 數量（A buffer 的 entry 數） |
| `NUM_COLS` | B fiber 數量（B buffer 的 entry 數） |
| `K_BITS` | bitmask 寬度 |
| `LANES` | MFIU lane 數量 |
| `DATA_WIDTH` | value 位元數 |
| `ID_WIDTH` | fiber ID 位元數 |

### 輸入

#### A buffer 寫入埠

| 訊號 | 說明 |
|---|---|
| `a_wr_en_i` | A buffer 寫入致能 |
| `a_wr_addr_i` | A buffer 寫入地址 |
| `a_wr_id_i` | A fiber ID |
| `a_wr_mask_i` | A fiber bitmask |
| `a_wr_values_i` | A fiber fixed-slot values |

#### B buffer 寫入埠

| 訊號 | 說明 |
|---|---|
| `b_wr_en_i` | B buffer 寫入致能 |
| `b_wr_addr_i` | B buffer 寫入地址 |
| `b_wr_id_i` | B fiber ID |
| `b_wr_mask_i` | B fiber bitmask |
| `b_wr_values_i` | B fiber fixed-slot values |

#### 控制

| 訊號 | 說明 |
|---|---|
| `clk`, `reset` | 時脈與重置 |
| `start_i` | 拉高一個 cycle 觸發 FSM 開始讀 fiber |

### 輸出

| 訊號 | 說明 |
|---|---|
| `done_o` | One-cycle pulse，表示 MFIU 輸出有效 |
| `lane_valid_o` | MFIU 輸出：各 lane 是否有效 |
| `a_row_sel_o` | MFIU 輸出：各 lane 的 A row index |
| `b_col_sel_o` | MFIU 輸出：各 lane 的 B column index |
| `k_sel_o` | MFIU 輸出：各 lane 的 k index |
| `match_count_o` | MFIU 輸出：有效 lane 數量 |
| `overflow_o` | MFIU 輸出：effectual MAC 是否超過 LANES |
| `a_values_o` | 所有 A fiber 的 fixed-slot values（captured，供 distribution network 使用） |
| `b_values_o` | 所有 B fiber 的 fixed-slot values（captured） |

### FSM 狀態說明

```
S_IDLE
  rd_addr = 0（持續 pre-read fiber 0）
  收到 start_i → prefetch addr 1，進入 S_READ

S_READ（循環 MAX_FIBERS 次）
  每 cycle capture 目前 buffer 輸出的 mask 與 values
  prefetch 下一筆地址
  全部 capture 完畢 → 進入 S_DONE

S_DONE
  done_o = 1（one-cycle pulse）
  重置 rd_addr，回到 S_IDLE
```

### 時序圖（NUM_ROWS = NUM_COLS = 2）

```
posedge T   : start_i 被 sample → IDLE → S_READ，prefetch addr 1
posedge T+1 : S_READ，capture mask[0]
posedge T+2 : S_READ，capture mask[1]（最後一筆）→ S_DONE
posedge T+3 : S_DONE，done_o = 1，MFIU 輸出有效
```

---

## 8. `trip_compute_top`

**檔案：** [trip_compute_top.v](trip_compute_top.v)

### 功能

單次 K-chunk 的端到端 compute path。串接：

```
trip_intersection_top
  → trip_distribution_network
  → pe_lane × LANES
  → trip_reduction_tree
  → row_local_buffer
```

`start_i` 觸發 intersection，intersection 完成後（`intersection_done`）：
- `trip_distribution_network` 取出對應的 A/B values 並路由到各 lane
- `pe_lane` 執行乘法
- `trip_reduction_tree` 依 output coordinate 累加
- `row_local_buffer` 儲存結果
- 一個 cycle 後 `done_o` pulse

### 參數

| 參數 | 說明 |
|---|---|
| `NUM_ROWS`, `NUM_COLS` | 矩陣 tile 大小 |
| `K_BITS` | fiber 維度 |
| `LANES` | 乘法器 lane 數量 |
| `DATA_WIDTH` | 運算元位元數 |
| `SIGNED_DATA` | 0 = unsigned，1 = signed |
| `ACC_WIDTH` | `PRODUCT_WIDTH + clog2(LANES+1)` |

### 輸入

A/B fiber 寫入埠（同 `trip_intersection_top` 的 A/B 寫入埠），加上：

| 訊號 | 說明 |
|---|---|
| `clk`, `reset` | 時脈與重置 |
| `start_i` | 觸發一次完整的 K-chunk compute |

### 輸出

| 訊號 | 說明 |
|---|---|
| `done_o` | One-cycle pulse，表示本次 K-chunk 計算完成 |
| `result_valid_o` | `NUM_OUTPUTS` 位元，哪些輸出座標有效 |
| `result_o` | `NUM_OUTPUTS × ACC_WIDTH`，各輸出座標的 partial sum |
| `match_count_o` | 本次有效 lane 數量 |
| `overflow_o` | 是否發生 overflow |

### 時序

`done_o` 在 `intersection_done` 後一個 cycle pulse（給 `row_local_buffer` 時間寫入）。讀取 `result_o` 應在 `done_o=1` 的 cycle 進行。

---

## 9. `trip_tile_compute_engine`

**檔案：** [trip_tile_compute_engine.v](trip_tile_compute_engine.v)

### 功能

最上層模組。在 `trip_compute_top` 之外加了一層 **C-tile accumulator**，支援多個 K-chunk 的累加，以完成 `C = A × B` 中 K 維度的完整累加。

每次 `start_i` 觸發一個 K-chunk：
- 若 `clear_accum_i=1`：清空 C-tile accumulator，再累加本次結果
- 若 `clear_accum_i=0`：直接將本次結果疊加到現有 accumulator 上

### 參數

| 參數 | 說明 |
|---|---|
| `NUM_ROWS`, `NUM_COLS` | C-tile 大小 |
| `K_BITS` | 每個 K-chunk 的 fiber 維度 |
| `LANES` | 乘法器 lane 數量 |
| `DATA_WIDTH` | 運算元位元數 |
| `SIGNED_DATA` | 0 = unsigned，1 = signed |
| `TILE_ACC_WIDTH` | `ACC_WIDTH + 8`，C-tile accumulator 的位元數 |
| `CHUNK_CNT_W` | 8，chunk 計數器位元數 |

### 輸入

A/B fiber 寫入埠（同 `trip_compute_top`），加上：

| 訊號 | 說明 |
|---|---|
| `clk`, `reset` | 時脈與重置 |
| `start_i` | 觸發一次 K-chunk compute |
| `clear_accum_i` | 本次 chunk 開始前是否清空 C-tile |

### 輸出

| 訊號 | 說明 |
|---|---|
| `busy_o` | 模組正在執行時為 1 |
| `done_o` | One-cycle pulse，表示本次 K-chunk 計算完成並已累加至 C-tile |
| `partial_valid_o` | 本次 K-chunk 各輸出座標是否有效 |
| `partial_result_o` | 本次 K-chunk 的各輸出座標 partial sum（`ACC_WIDTH` 寬） |
| `match_count_o` | 本次有效 lane 數量 |
| `overflow_o` | 本次是否 overflow |
| `overflow_seen_o` | 從 `clear_accum_i` 後是否曾發生過 overflow |
| `tile_valid_o` | C-tile 中哪些座標已有累加結果 |
| `tile_result_o` | C-tile 累加結果（`TILE_ACC_WIDTH` 寬） |
| `chunk_count_o` | 自上次 clear 後已執行幾個 K-chunk |

### FSM 狀態

```
S_IDLE
  收到 start_i：
    - 若 clear_accum_i=1：清空 tile_accum、overflow_seen、chunk_count
    - 觸發 inner_start → trip_compute_top 開始執行
    - 進入 S_RUN

S_RUN
  等待 inner_done（trip_compute_top 完成）
  → 進入 S_ACCUM

S_ACCUM（持續一個 cycle）
  從 partial_result_o 讀取各座標結果
  valid 的座標疊加到 tile_accum
  更新 overflow_seen、chunk_count
  發出 done_o = 1
  → 回到 S_IDLE
```

### 使用範例（K = 8，切成兩個 K-chunk = 4）

```
// Chunk 0：clear accumulator
load A/B chunk 0 into buffers;
start_i=1, clear_accum_i=1;
wait done_o;

// Chunk 1：累加到同一個 C-tile
load A/B chunk 1 into buffers;
start_i=1, clear_accum_i=0;
wait done_o;

// 讀取最終結果
C[r][c] = tile_result_o[r*NUM_COLS+c];
```

---

## 模組間連線摘要

| 上游模組 | 訊號 | 下游模組 |
|---|---|---|
| `bitmask_buffer` | `rd_mask_o`, `rd_values_o` | `trip_intersection_top` FSM（capture） |
| `mfiu` | `lane_valid`, `a_row_sel`, `b_col_sel`, `k_sel` | `trip_distribution_network`, `trip_reduction_tree` |
| `trip_intersection_top` | `a_values_o`, `b_values_o` | `trip_distribution_network` |
| `trip_distribution_network` | `lane_a_o`, `lane_b_o`, `lane_valid_o` | `pe_lane` × LANES |
| `pe_lane` | `product_o`, `valid_o` | `trip_reduction_tree` |
| `trip_reduction_tree` | `out_value_o`, `out_valid_o` | `row_local_buffer` |
| `row_local_buffer` | `rd_data_o`, `rd_valid_o` | 輸出（`result_o` / `partial_result_o`） |
| `trip_intersection_top` | `done_o`（`intersection_done`） | `row_local_buffer` `wr_en_i` |
| `trip_compute_top` | `done_o`（delayed 1 cycle） | `trip_tile_compute_engine` S_ACCUM |

---

## 位元 Packing 規則

所有 packed bus 都採用 **低 index 在低位元** 的規則：

```
a_mask_i[r*K_BITS +: K_BITS]          → row r 的 bitmask
a_values_i[r*K_BITS*DW +: K_BITS*DW]  → row r 的所有 value slots
values[k*DW +: DW]                     → k slot 的 value（即 slot k）
result_o[i*ACC_WIDTH +: ACC_WIDTH]     → 輸出座標 i = r*NUM_COLS+c
```

Value bus 的 slot 排列（以 K_BITS=4, DATA_WIDTH=16 為例）：

```verilog
{16'hAAAA, 16'h0000, 16'h5555, 16'h0000}
//  slot3    slot2    slot1    slot0
```

→ `values[15:0] = slot0`，`values[63:48] = slot3`

---

## 10. 實際矩陣數字走查範例

本節以 `tb_trip_compute_top.v TC1` 的數值為基礎，完整追蹤每個硬體階段的訊號狀態。
參數設定：`NUM_ROWS=2, NUM_COLS=2, K_BITS=4, LANES=4, DATA_WIDTH=16`。

---

### 10.1 輸入矩陣定義

**矩陣 A（2 行 × K=4）：A[row][k]**

| row \ k | k=0 | k=1 | k=2 | k=3 | bitmask    |
|---------|-----|-----|-----|-----|------------|
| row 0   |  0  |  2  |  0  |  3  | `4'b1010`  |
| row 1   |  0  | 17  | 19  |  0  | `4'b0110`  |

**矩陣 B（K=4 × 2 列，以 column fiber 表示）：B[k][col]**

| k \ col | col 0 | col 1 |
|---------|-------|-------|
| k=0     |   7   |   0   |
| k=1     |   0   |  11   |
| k=2     |   0   |   0   |
| k=3     |   5   |  13   |

B col 0 bitmask = `4'b1001`（k0, k3 非零）；B col 1 bitmask = `4'b1010`（k1, k3 非零）

**預期結果 C = A × B（2×2）：**

```
C[0][0] = A[0]·B[:,0] = 0×7 + 2×0 + 0×0 + 3×5 = 15
C[0][1] = A[0]·B[:,1] = 0×0 + 2×11 + 0×0 + 3×13 = 22 + 39 = 61
C[1][0] = A[1]·B[:,0] = 0×7 + 17×0 + 19×0 + 0×5 = 0
C[1][1] = A[1]·B[:,1] = 0×0 + 17×11 + 19×0 + 0×13 = 187
```

---

### 10.2 Stage 1：bitmask_buffer — 寫入 Fiber 資料

**硬體模組：** `bitmask_buffer.v`（A 與 B 各一個實例）

寫入於 `posedge clk`，`wr_en_i=1`。值依位元封裝規則 `values[k*DW +: DW]` 儲存。

**寫入 A buffer：**

```verilog
write_a_fiber(addr=0, id=0, mask=4'b1010, values={16'd3, 16'd0, 16'd2, 16'd0});
// [63:48]=3 → k3 slot=3,  [31:16]=2 → k1 slot=2,  [15:0]=0 → k0 slot=0

write_a_fiber(addr=1, id=1, mask=4'b0110, values={16'd0, 16'd19, 16'd17, 16'd0});
// [47:32]=19 → k2 slot=19, [31:16]=17 → k1 slot=17
```

**寫入 B buffer：**

```verilog
write_b_fiber(addr=0, id=0, mask=4'b1001, values={16'd5, 16'd0, 16'd0, 16'd7});
// [63:48]=5 → k3 slot=5,  [15:0]=7 → k0 slot=7

write_b_fiber(addr=1, id=1, mask=4'b1010, values={16'd13, 16'd0, 16'd11, 16'd0});
// [63:48]=13 → k3 slot=13, [31:16]=11 → k1 slot=11
```

---

### 10.3 Stage 2：trip_intersection_top FSM — 讀取 mask 並送交 MFIU

**硬體模組：** `trip_intersection_top.v`

```
negedge     : start_i = 1
posedge T+0 : FSM IDLE → S_READ，read_idx=0
posedge T+1 : S_READ 讀取 A[0].mask=1010, B[0].mask=1001，read_idx=1
posedge T+2 : S_READ 讀取 A[1].mask=0110, B[1].mask=1010
posedge T+3 : S_DONE，done_o=1，輸出累積 mask 給 MFIU
```

**送出至 MFIU 的 mask bus：**

```
a_mask_i = {A[row1].mask, A[row0].mask} = {4'b0110, 4'b1010}  // row1 在高位
b_mask_i = {B[col1].mask, B[col0].mask} = {4'b1010, 4'b1001}  // col1 在高位
```

---

### 10.4 Stage 3：mfiu — 交集掃描，指派 Lane

**硬體模組：** `mfiu.v`（純組合邏輯）

對所有 (r, c) pair 做 bitwise AND，依掃描順序 r↑→c↑→k↑ 填入 Lane：

| pair (r, c) | A mask   | B mask   | AND 結果   | 命中 k 位 |
|-------------|----------|----------|-----------|----------|
| (0, 0)      | `4'b1010`| `4'b1001`| `4'b1000` | k3       |
| (0, 1)      | `4'b1010`| `4'b1010`| `4'b1010` | k1, k3   |
| (1, 0)      | `4'b0110`| `4'b1001`| `4'b0000` | （無）   |
| (1, 1)      | `4'b0110`| `4'b1010`| `4'b0010` | k1       |

**Lane 分配結果（共 4 個 effectual MAC）：**

| Lane | row_sel | col_sel | k_sel | 代表哪一項乘法         |
|------|---------|---------|-------|----------------------|
| 0    | 0       | 0       | 3     | A[0][k3] × B[0][k3] |
| 1    | 0       | 1       | 1     | A[0][k1] × B[1][k1] |
| 2    | 0       | 1       | 3     | A[0][k3] × B[1][k3] |
| 3    | 1       | 1       | 1     | A[1][k1] × B[1][k1] |

```
lane_valid_o  = 4'b1111
match_count_o = 4
overflow_o    = 0
```

---

### 10.5 Stage 4：trip_distribution_network — 依索引從 values bus 取值

**硬體模組：** `trip_distribution_network.v`（純組合邏輯）

定址公式：`values_i[row_sel * K_BITS * DW + k_sel * DW +: DW]`

| Lane | row | col | k | A 取值計算                         | A值 | B 取值計算                          | B值 |
|------|-----|-----|---|------------------------------------|-----|-------------------------------------|-----|
| 0    | 0   | 0   | 3 | A_values[0×64 + 3×16 +: 16] → k3 slot of A[0] | **3**  | B_values[0×64 + 3×16 +: 16] → k3 slot of B[0] | **5**  |
| 1    | 0   | 1   | 1 | A_values[0×64 + 1×16 +: 16] → k1 slot of A[0] | **2**  | B_values[1×64 + 1×16 +: 16] → k1 slot of B[1] | **11** |
| 2    | 0   | 1   | 3 | A_values[0×64 + 3×16 +: 16] → k3 slot of A[0] | **3**  | B_values[1×64 + 3×16 +: 16] → k3 slot of B[1] | **13** |
| 3    | 1   | 1   | 1 | A_values[1×64 + 1×16 +: 16] → k1 slot of A[1] | **17** | B_values[1×64 + 1×16 +: 16] → k1 slot of B[1] | **11** |

---

### 10.6 Stage 5：pe_lane × 4 — 乘法

**硬體模組：** `pe_lane.v`（純組合邏輯，各 Lane 獨立）

```
lane0: 3  × 5  = 15
lane1: 2  × 11 = 22
lane2: 3  × 13 = 39
lane3: 17 × 11 = 187
```

`valid_i=1` → 輸出乘積；`valid_i=0` → 強制輸出 0（避免累加雜訊）。

---

### 10.7 Stage 6：trip_reduction_tree — 依 (row, col) 歸約加總

**硬體模組：** `trip_reduction_tree.v`（純組合邏輯）

輸出槽索引：`out_idx = row_sel × NUM_COLS + col_sel`

| Lane | (row, col) | out_idx | product | 寫入輸出槽 |
|------|-----------|---------|---------|-----------|
| 0    | (0, 0)    | 0       | 15      | C[0][0]   |
| 1    | (0, 1)    | 1       | 22      | C[0][1]   |
| 2    | (0, 1)    | 1       | 39      | C[0][1]   |
| 3    | (1, 1)    | 3       | 187     | C[1][1]   |

```
sum_o[0] = 15         → C[0][0]
sum_o[1] = 22 + 39    → C[0][1] = 61
sum_o[2] = 0          → C[1][0] = 0（無 Lane 命中此槽）
sum_o[3] = 187        → C[1][1]

out_valid_o = 4'b1011  （sum≠0 才置 1；C[1][0]=0 故 valid[2]=0）
```

> ⚠️ 已知限制：若有號數加總真的等於 0（非空），`out_valid_o` 仍會誤報為 0。MVP 範疇內暫不修正。

---

### 10.8 Stage 7：row_local_buffer — 儲存結果

**硬體模組：** `row_local_buffer.v`

`trip_compute_top.v` 在 `intersection_done` 後一個 cycle 寫入：

```
wr_data  = {187, 0, 61, 15}   // 各 ACC_WIDTH=35 bits
wr_valid = 4'b1011
```

讀出結果（`done_o` 後可直接讀）：

| out_idx | 對應 C 元素 | 值   | valid |
|---------|------------|------|-------|
| 0       | C[0][0]    | 15   | 1     |
| 1       | C[0][1]    | 61   | 1     |
| 2       | C[1][0]    | 0    | 0     |
| 3       | C[1][1]    | 187  | 1     |

---

### 10.9 完整訊號流圖

```
bitmask_buffer (A)                    bitmask_buffer (B)
  addr0: mask=1010, values=[0,2,0,3]    addr0: mask=1001, values=[7,0,0,5]
  addr1: mask=0110, values=[0,17,19,0]  addr1: mask=1010, values=[0,11,0,13]
            │  (FSM 讀 3 個 clock)                │
            └─────────────────────────────────────┘
                    trip_intersection_top
              a_mask={0110,1010}, b_mask={1010,1001}
                         │ (純組合邏輯)
                        mfiu
         lane0(r0,c0,k3) lane1(r0,c1,k1) lane2(r0,c1,k3) lane3(r1,c1,k1)
                         │ (純組合邏輯)
              trip_distribution_network
         a_data=[3,   2,   3,   17 ]
         b_data=[5,   11,  13,  11 ]
                         │ (純組合邏輯)
                    pe_lane × 4
              products=[15,  22,  39,  187]
                         │ (純組合邏輯)
               trip_reduction_tree
         C[0][0]=15  C[0][1]=61  C[1][0]=0  C[1][1]=187
                         │ (1 個 clock write)
                  row_local_buffer
          result=[15, 61, 0, 187], valid=4'b1011
```

**本次計算摘要：**

- 總延遲（start_i → done_o）：**3 個時脈週期**
- 有效 MAC 數：**4**（16 個 k 組合中僅計算雙方非零的交集）
- 跳過項目：C[1][0]（A[1] 與 B[col0] 無共同非零 k，MFIU 自動略過，節省該 pair 的全部乘加算力）
