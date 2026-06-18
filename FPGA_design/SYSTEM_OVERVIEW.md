# FPGA TrIP 系統功能總整理

本文整理 `FPGA_design/src/` 內的 TrIP MVP 硬體功能、資料流、各 testbench 驗證內容，最後用一個實際矩陣乘法例子說明資料經過每個硬體模組時的作用。

## 1. 系統目標

此 FPGA design 實作一個以 TrIP sparse datapath 為核心的矩陣乘法加速器原型。它主要處理稀疏矩陣乘法：

```text
C = A x B
```

目前 MVP 預設 tile/chunk 參數如下：

| 參數 | 預設值 | 意義 |
|---|---:|---|
| `NUM_ROWS` | 2 | 一次處理 A 的 2 個 row fiber，也對應 C tile 的 2 列 |
| `NUM_COLS` | 2 | 一次處理 B 的 2 個 column fiber，也對應 C tile 的 2 欄 |
| `K_BITS` | 4 | 每個 K chunk 有 4 個 k slot |
| `LANES` | 4 | 最多同時送出 4 個有效 MAC |
| `DATA_WIDTH` | 16 | A/B value 為 16-bit |
| `ACC_WIDTH` | `2*DATA_WIDTH + clog2(LANES+1)` | 單 chunk partial sum 寬度 |
| `TILE_ACC_WIDTH` | `ACC_WIDTH + 8` | 跨 K chunk 的 C tile accumulator 寬度 |

核心想法是：A row fiber 和 B column fiber 先用 bitmask 表示哪些 k 位置非零。硬體只對 A 與 B 在同一個 k 都非零的位置做乘法，跳過零值 MAC。

## 2. 硬體層級

```text
trip_tile_compute_engine
└── trip_compute_top
    ├── trip_intersection_top
    │   ├── bitmask_buffer (A side)
    │   ├── bitmask_buffer (B side)
    │   └── mfiu
    ├── trip_distribution_network
    ├── pe_lane x LANES
    ├── trip_reduction_tree
    └── row_local_buffer
```

整體資料流：

```text
A/B sparse fiber write
        |
        v
bitmask_buffer
        |
        v
trip_intersection_top FSM 讀出所有 A/B masks 與 values
        |
        v
mfiu 找出有效 (row, col, k)
        |
        v
trip_distribution_network 依 (row, col, k) 取出 A/B value
        |
        v
pe_lane 做乘法
        |
        v
trip_reduction_tree 依 C[row][col] 分組加總
        |
        v
row_local_buffer 保存單一 K chunk 結果
        |
        v
trip_tile_compute_engine 累加多個 K chunk 成完整 C tile
```

## 3. 各硬體模組功能

### 3.1 `bitmask_buffer.v`

`bitmask_buffer` 是 sparse fiber 的本地儲存。每筆 entry 包含：

```text
fiber id
K_BITS-bit bitmask
K_BITS 個 fixed-slot values
```

例如 `K_BITS=4` 時，一條 fiber 的 values 永遠有 4 個 slot：

```text
values = {slot3, slot2, slot1, slot0}
```

即使某個 slot 對應的 mask bit 是 0，該 value slot 仍存在。這樣 MFIU 產生 `k_sel` 後，distribution network 可以直接用 `row*K_BITS + k` 或 `col*K_BITS + k` 抽 value，不需要 prefix sum 或 compact sparse index。

主要作用：

- 接收 testbench 或上層 controller 寫入 A/B fiber。
- 提供 1-cycle registered read。
- 額外提供 `k_value_o`，可直接從目前讀出的 values 取指定 k slot。

### 3.2 `mfiu.v`

`mfiu` 是 Multi-Fiber Intersection Unit。它接收所有 A row masks 與 B column masks，對每組 `(row, col)` 做：

```text
intersection_mask = A_row_mask & B_col_mask
```

若某個 k bit 為 1，就代表：

```text
A[row][k] != 0 且 B[k][col] != 0
```

這是一個 effectual MAC，才需要送到 PE lane。

掃描順序固定為：

```text
row -> col -> k
```

MFIU 輸出每個 lane 的 metadata：

```text
lane_valid
a_row_sel
b_col_sel
k_sel
match_count
overflow
```

若有效 MAC 數量超過 `LANES`，只輸出前 `LANES` 筆，`overflow_o=1`。

### 3.3 `trip_intersection_top.v`

`trip_intersection_top` 把 A/B `bitmask_buffer` 和 `mfiu` 包起來，並用 FSM 控制讀取流程。

流程：

1. 上層先把 A/B fiber 寫入 buffer。
2. `start_i` 拉高一個 cycle。
3. FSM 依序讀出 A/B buffer 中的所有 masks 和 values。
4. captured masks 送入 `mfiu`。
5. `done_o` pulse 時，MFIU 的 lane metadata 和 captured values 有效。

以 `NUM_ROWS=NUM_COLS=2` 為例，`start_i` 後約 3 個 posedge 會看到 `done_o=1`。

### 3.4 `trip_distribution_network.v`

Distribution network 根據 MFIU 的 metadata 從 fixed-slot values 中取 operands。

對每個 lane：

```text
a_slot = a_row_sel * K_BITS + k_sel
b_slot = b_col_sel * K_BITS + k_sel
lane_a = A values[a_slot]
lane_b = B values[b_slot]
```

若 `lane_valid=0`，輸出 value 為 0。此模組本身不做乘法，只做 value routing。

### 3.5 `pe_lane.v`

每個 `pe_lane` 是一個乘法器 lane。

```text
product = lane_a * lane_b
```

功能特性：

- `valid_i=1` 時輸出乘積。
- `valid_i=0` 時輸出 0。
- 支援 unsigned 和 signed mode，由 `SIGNED_DATA` 控制。
- combinational，沒有 pipeline register。

### 3.6 `trip_reduction_tree.v`

Reduction tree 依照 output coordinate `(row, col)` 把各 lane 的 product 加總。

例如 lane metadata 分別是：

```text
lane0 -> C[0][1]
lane1 -> C[0][1]
lane2 -> C[1][0]
```

則 reduction tree 會輸出：

```text
C[0][1] partial = lane0_product + lane1_product
C[1][0] partial = lane2_product
```

目前是 combinational 的 reduction-by-output-coordinate MVP，不是完整 MRN-style tree。

注意：`out_valid_o` 目前用 `sum != 0` 判斷。signed 模式下若正負數剛好抵銷為 0，valid 可能為 0，這是目前實作限制。

### 3.7 `row_local_buffer.v`

`row_local_buffer` 保存單一 K chunk 的 partial C 結果。

特性：

- 每個 output coordinate 一個暫存器。
- `wr_en_i=1` 時寫入 reduction 結果。
- 對 `wr_valid_i=0` 的座標會清成 0。
- 適合保存單 chunk 結果，不負責跨 chunk 累加。

### 3.8 `trip_compute_top.v`

`trip_compute_top` 是單一 K chunk 的端到端 datapath：

```text
intersection -> distribution -> PE multiply -> reduction -> row buffer
```

它完成：

```text
A_tile[:, K_chunk] x B_tile[K_chunk, :] = partial C tile
```

輸出：

- `result_valid_o`
- `result_o`
- `match_count_o`
- `overflow_o`
- `done_o`

`done_o` 比 `trip_intersection_top` 的 done 晚一個 cycle，讓 `row_local_buffer` 有時間寫入。

### 3.9 `trip_tile_compute_engine.v`

這是目前最上層模組。它把 `trip_compute_top` 當成每個 K chunk 的計算引擎，再外加 C tile accumulator。

每次啟動：

```text
start_i = 1
```

若：

```text
clear_accum_i = 1
```

表示這是該 C tile 的第一個 K chunk，先清空 accumulator 再累加。

若：

```text
clear_accum_i = 0
```

表示這是同一個 C tile 的後續 K chunk，把 partial result 疊加到目前 accumulator。

重要輸出：

| 訊號 | 功能 |
|---|---|
| `busy_o` | engine 正在跑 |
| `done_o` | 本 chunk 已經累加進 tile accumulator |
| `partial_valid_o` / `partial_result_o` | 單 chunk partial C |
| `tile_valid_o` / `tile_result_o` | 已累加的 C tile |
| `chunk_count_o` | 目前 tile 已累加幾個 K chunk |
| `overflow_o` | 當前 chunk 是否 overflow |
| `overflow_seen_o` | 目前 tile 過程中是否曾 overflow |

## 4. Testbench 驗證內容

### 4.0 TB 分工總表

整套 testbench 是由低階模組一路驗到系統層。低階 TB 先確認單一功能正確，再往上驗證整合後的資料流。

| Testbench | 主要 DUT | 負責驗證的層級 | 主要驗證功能 |
|---|---|---|---|
| `tb_bitmask_buffer.v` | `bitmask_buffer` | sparse fiber 儲存 | reset、write/read、fixed-slot values、`k_sel` indexed read、overwrite |
| `tb_mfiu.v` | `mfiu` | intersection combinational logic | mask AND、lane metadata、scan order、`match_count`、`overflow` |
| `tb_trip_intersection_top.v` | `trip_intersection_top` | buffer + FSM + MFIU | start/done 時序、buffer capture、intersection output、overwrite、consecutive run |
| `tb_trip_compute_top.v` | `trip_compute_top` | 單一 K chunk 完整 datapath | intersection、value routing、PE multiply、reduction、row buffer result |
| `tb_trip_tile_compute_engine.v` | `trip_tile_compute_engine` | 多 K chunk tile accumulation | `clear_accum_i`、chunk 累加、`chunk_count`、`overflow_seen`、no-intersection clear |
| `tb_trip_tile_random.v` | `trip_tile_compute_engine` | 隨機系統測試 | 隨機 M/N/K tiling、golden matrix multiply 比對、跨 tile/chunk 結果正確性 |
| `tb_trip_tile_regression.v` | 多個 top module | regression / corner cases | 隨機 accumulation、held start、active reset、write during compute、overflow split replay、大矩陣 tiling、signed、非預設參數 |

驗證鏈可以理解成：

```text
tb_bitmask_buffer
  -> 驗證資料有正確存進 buffer

tb_mfiu
  -> 驗證 mask 能正確轉成 MAC 任務清單

tb_trip_intersection_top
  -> 驗證 buffer 讀取和 MFIU 接起來後，start/done 和 lane output 正確

tb_trip_compute_top
  -> 驗證 lane output 能真的取值、乘法、加總，產生單 chunk C partial

tb_trip_tile_compute_engine
  -> 驗證多個 K chunk 的 partial C 能累加成完整 C tile

tb_trip_tile_random / tb_trip_tile_regression
  -> 驗證更多矩陣大小、隨機資料、控制時序和 corner cases
```

### 4.1 `tb_bitmask_buffer.v`

驗證 `bitmask_buffer` 的儲存與讀取行為：

- reset 後 buffer entry 會清為 0。
- 單筆 fiber 寫入後可讀回 id、mask、values。
- `k_sel_i` 能正確從 fixed-slot values 取出 slot0 到 slot3。
- 連續寫滿 4 個 entry 後，各 entry 可獨立讀回。
- 覆寫既有 entry 只影響該地址，其他地址不變。
- 再次 reset 會清空資料與 values。

它主要回答的問題是：

```text
Sparse fiber 的 metadata 和 values 有沒有正確存取？
fixed-slot packing 之後，硬體能不能用 k_sel 直接拿到對應 value？
```

### 4.2 `tb_mfiu.v`

驗證 `mfiu` 的 bitmask intersection 與 lane metadata：

- 全 mask 為 0 時，沒有有效 MAC。
- 單一 `(row, col, k)` intersection 會出現在 lane0。
- 標準範例 `A0=1010, A1=0110, B0=1001, B1=1010` 產生 4 個有效 MAC：
  - lane0 = `(0,0,k3)`
  - lane1 = `(0,1,k1)`
  - lane2 = `(0,1,k3)`
  - lane3 = `(1,1,k1)`
- 有效 MAC 超過 `LANES=4` 時，`match_count` capped at 4 且 `overflow=1`。
- A 或 B 有全零 fiber 時，只輸出真正有交集的 pair。
- 所有 pair 都只共享同一 k bit 時，4 個 lane 都指向同一個 k。

它主要回答的問題是：

```text
MFIU 能不能只找出 A/B 共同非零的 k？
找出的 MAC 任務有沒有依照固定 scan order 放到 lane？
超過 lane 數量時 overflow 有沒有被偵測？
```

### 4.3 `tb_trip_intersection_top.v`

驗證 A/B buffer 加 MFIU 加 FSM 的整合：

- 寫入 A/B masks 後，`start_i` 能啟動 intersection 流程。
- `done_o` pulse 時 lane metadata 正確。
- no-intersection case 輸出 `lane_valid=0`、`match_count=0`。
- overflow case 正確拉高 `overflow_o`。
- overwrite buffer 後重新 run，會使用新資料。
- consecutive runs 不重新寫入資料時，FSM 能回到 IDLE 並重複產生同樣結果。

它主要回答的問題是：

```text
start_i 進來後，FSM 能不能正確把 A/B buffer 的 masks 和 values 抓出來？
抓出的 masks 送進 MFIU 後，done_o 那一拍 lane output 是否有效？
連續執行或覆寫資料後，狀態機會不會卡住或讀錯舊資料？
```

### 4.4 `tb_trip_compute_top.v`

驗證單一 K chunk 的端到端計算：

- 寫入 A/B sparse fiber。
- 跑完整 datapath：intersection、value routing、multiply、reduction、row buffer。
- 標準 chunk 結果驗證：

```text
C00 = 15
C01 = 61
C10 = 0
C11 = 187
```

- no-intersection case 會清空 row buffer，`result_valid_o=0000` 且輸出為 0。

它主要回答的問題是：

```text
MFIU 輸出的 lane metadata 能不能正確導到真實 A/B values？
PE lane 乘完後，reduction tree 能不能把同一個 C[row][col] 的 product 加在一起？
row_local_buffer 有沒有保存本 chunk 的 partial C？
```

### 4.5 `tb_trip_tile_compute_engine.v`

驗證跨 K chunk 的 C tile 累加：

- Chunk 0 使用 `clear_accum_i=1`，得到 partial/final：

```text
[[15, 61],
 [ 0,187]]
```

- Chunk 1 使用 `clear_accum_i=0` 累加到同一個 C tile：

```text
chunk1 partial = [[14, 0],
                  [ 0,83]]

final C = [[29, 61],
           [ 0,270]]
```

- no-intersection tile 搭配 `clear_accum_i=1` 時，會清空 accumulator 並輸出 invalid/0。
- 驗證 `chunk_count_o` 和 `overflow_seen_o`。

它主要回答的問題是：

```text
第一個 K chunk 能不能用 clear_accum_i 清空 accumulator 後寫入？
後續 K chunk 能不能在不清空的情況下加到同一個 C tile？
如果新 tile 沒有 intersection，舊結果會不會被正確清掉？
```

### 4.6 `tb_trip_tile_random.v`

驗證較接近系統層的隨機矩陣乘法：

- 隨機選擇 M tile 數、N tile 數、K chunk 數。
- 產生稀疏 A/B 矩陣。
- 軟體端以一般矩陣乘法算 golden result。
- 硬體端對每個 `(M tile, N tile)` 掃過所有 K chunks。
- 比對每個 C tile element 和 golden result。
- 資料產生時限制每個 fiber 每個 K chunk 最多一個 nonzero，使每 chunk intersection 數不超過 `LANES`，避免 overflow 干擾正確性檢查。

它主要回答的問題是：

```text
不是只測手寫固定例子時，整個 tile engine 是否仍能對上軟體 golden？
不同 M/N tile 數和 K chunk 數組合下，外層 tiling loop 是否能正確餵資料和累加？
```

### 4.7 `tb_trip_tile_regression.v`

這個檔案內有多個 regression top module。

`tb_trip_tile_regression` 驗證：

- 多個隨機 K chunk 的 self-checking accumulation。
- `start_i` 連續維持多個 cycle 時，不應重複啟動多次，`chunk_count=1`。
- active run 中途 reset 會清除 engine 狀態、busy、done、chunk_count、tile accumulator。
- compute active 時寫入相同資料，結果仍可和 golden 對上。
- overflow detect 和 manual split replay：dense chunk 造成 overflow 後，手動拆成兩個不 overflow chunk 可得到正確 C。
- 4x8 乘 8x4 的大矩陣 tiling 迴圈，檢查每個 C tile。

`tb_trip_signed_compute` 驗證：

- `SIGNED_DATA=1` 時 signed multiplication 與 signed reduction。
- 範例：

```text
C00 = (-2)*3 + 4*(-5) = -26
C11 = (-7)*(-8) = 56
match_count = 3
```

`tb_trip_param_shapes` 驗證：

- 非預設 shape 可以 elaboration 並正確運作。
- 1x1、K=1、LANES=1 edge case：`6*7=42`。
- 4x4、K=8、LANES=8 case：檢查 diagonal-like 結果，例如 `C00=6, C05=12, C10=20, C15=30`。

它主要回答的問題是：

```text
控制訊號異常一點時，例如 start_i 拉太久或 run 中 reset，engine 是否仍有定義好的行為？
資料太 dense 造成 overflow 時，overflow_seen 是否能記錄？
把 dense chunk 手動拆開重跑後，結果是否能回到正確 golden？
SIGNED_DATA 和非預設參數是否真的可用，而不是只支援 2x2/K4/LANES4？
```

### 4.8 目前 TB 沒有完整覆蓋的項目

目前 TB 已經覆蓋功能正確性、基本控制時序、overflow 偵測、signed mode 和參數變形，但仍有幾類不是這批 TB 的重點：

- 沒有做 synthesis timing 或 FPGA resource utilization 檢查。
- 沒有驗證大型參數下 MFIU combinational path 的 timing closure。
- 沒有做 AXI、DMA 或外部記憶體介面測試，因為目前 `FPGA_design/src` 是 compute datapath MVP。
- 沒有測完整 CNN layer controller，只測 sparse matrix/tile compute path。
- signed mode 已測乘法與 reduction，但 `trip_reduction_tree` 用 `sum != 0` 當 valid，因此「正負剛好抵銷成 0 但實際有 MAC」這種 valid semantic 還沒被修正。

## 5. 實際矩陣例子：2x8 乘 8x2

以下例子正是 `tb_trip_tile_compute_engine.v` 使用的矩陣。硬體每次只能處理 4 個 K slot，因此 K=8 會拆成兩個 K chunks。

### 5.1 原始矩陣

```text
A 是 2x8：

A row0 = [0,  2,  0, 3, 1, 0, 4, 0]
A row1 = [0, 17, 19, 0, 0, 5, 0, 6]

B 是 8x2：

B col0 = [7, 0, 0, 5, 2, 0, 3, 0]^T
B col1 = [0,11, 0,13, 0, 7, 0, 8]^T
```

完整答案：

```text
C = A x B

C00 = 0*7 + 2*0 + 0*0 + 3*5 + 1*2 + 0*0 + 4*3 + 0*0 = 29
C01 = 0*0 + 2*11 + 0*0 + 3*13 + 1*0 + 0*7 + 4*0 + 0*8 = 61
C10 = 0*7 +17*0 +19*0 + 0*5 + 0*2 + 5*0 + 0*3 + 6*0 = 0
C11 = 0*0 +17*11+19*0 + 0*13+ 0*0 + 5*7 + 0*0 + 6*8 = 270

C = [[29, 61],
     [ 0,270]]
```

### 5.2 Chunk 0：k0 到 k3

Chunk 0 取前 4 個 K：

```text
A0 chunk0 = [0,  2,  0, 3]  mask = 1010
A1 chunk0 = [0, 17, 19, 0]  mask = 0110

B0 chunk0 = [7, 0, 0, 5]    mask = 1001
B1 chunk0 = [0,11,0,13]     mask = 1010
```

寫入 `bitmask_buffer` 時採 fixed-slot packing：

```text
A0 values = {k3=3,  k2=0,  k1=2,  k0=0}
A1 values = {k3=0,  k2=19, k1=17, k0=0}
B0 values = {k3=5,  k2=0,  k1=0,  k0=7}
B1 values = {k3=13, k2=0,  k1=11, k0=0}
```

`mfiu` 做 intersection：

| Pair | Mask AND | 有效 k | 對應 MAC |
|---|---|---|---|
| A0 x B0 | `1010 & 1001 = 1000` | k3 | `C00 += A0[k3] * B0[k3] = 3*5` |
| A0 x B1 | `1010 & 1010 = 1010` | k1, k3 | `C01 += 2*11`, `C01 += 3*13` |
| A1 x B0 | `0110 & 1001 = 0000` | none | no MAC |
| A1 x B1 | `0110 & 1010 = 0010` | k1 | `C11 += 17*11` |

MFIU lane output：

| Lane | `(row, col, k)` | Distribution network 取值 | PE product |
|---:|---|---|---:|
| 0 | `(0,0,3)` | A0[k3]=3, B0[k3]=5 | 15 |
| 1 | `(0,1,1)` | A0[k1]=2, B1[k1]=11 | 22 |
| 2 | `(0,1,3)` | A0[k3]=3, B1[k3]=13 | 39 |
| 3 | `(1,1,1)` | A1[k1]=17, B1[k1]=11 | 187 |

`trip_reduction_tree` 依 output coordinate 加總：

```text
C00 partial = lane0 = 15
C01 partial = lane1 + lane2 = 22 + 39 = 61
C10 partial = 0
C11 partial = lane3 = 187
```

`row_local_buffer` 保存單 chunk 結果：

```text
chunk0 partial C = [[15, 61],
                    [ 0,187]]
```

`trip_tile_compute_engine` 因為這是第一個 chunk，`clear_accum_i=1`，所以 tile accumulator 變成：

```text
tile C after chunk0 = [[15, 61],
                       [ 0,187]]
chunk_count = 1
```

### 5.3 Chunk 1：k4 到 k7

Chunk 1 取後 4 個 K，局部 k slot 重新編號為 k0 到 k3：

```text
global k4 -> local k0
global k5 -> local k1
global k6 -> local k2
global k7 -> local k3
```

```text
A0 chunk1 = [1,0,4,0]  mask = 0101
A1 chunk1 = [0,5,0,6]  mask = 1010

B0 chunk1 = [2,0,3,0]  mask = 0101
B1 chunk1 = [0,7,0,8]  mask = 1010
```

MFIU intersection：

| Pair | Mask AND | 有效 local k | 對應 MAC |
|---|---|---|---|
| A0 x B0 | `0101 & 0101 = 0101` | k0, k2 | `C00 += 1*2`, `C00 += 4*3` |
| A0 x B1 | `0101 & 1010 = 0000` | none | no MAC |
| A1 x B0 | `1010 & 0101 = 0000` | none | no MAC |
| A1 x B1 | `1010 & 1010 = 1010` | k1, k3 | `C11 += 5*7`, `C11 += 6*8` |

Lane 與 PE product：

| Lane | `(row, col, local k)` | Distribution network 取值 | PE product |
|---:|---|---|---:|
| 0 | `(0,0,0)` | A0[k0]=1, B0[k0]=2 | 2 |
| 1 | `(0,0,2)` | A0[k2]=4, B0[k2]=3 | 12 |
| 2 | `(1,1,1)` | A1[k1]=5, B1[k1]=7 | 35 |
| 3 | `(1,1,3)` | A1[k3]=6, B1[k3]=8 | 48 |

Reduction 結果：

```text
C00 partial = 2 + 12 = 14
C01 partial = 0
C10 partial = 0
C11 partial = 35 + 48 = 83
```

`row_local_buffer` 保存：

```text
chunk1 partial C = [[14, 0],
                    [ 0,83]]
```

`trip_tile_compute_engine` 這次 `clear_accum_i=0`，所以把 chunk1 加到既有 accumulator：

```text
tile C after chunk1 =
[[15, 61],   +   [[14, 0],   =   [[29, 61],
 [ 0,187]]        [ 0,83]]        [ 0,270]]

chunk_count = 2
```

### 5.4 每個硬體對應到例子的作用

| 硬體 | 在例子中的作用 |
|---|---|
| `bitmask_buffer` | 保存 A0/A1/B0/B1 每個 chunk 的 mask 與 fixed-slot values |
| `trip_intersection_top` | 啟動後依序讀出 A/B fibers，capture masks/values，送給 MFIU |
| `mfiu` | 用 mask AND 找出真正需要做的 MAC，例如 chunk0 的 `(0,1,k1)` 與 `(0,1,k3)` |
| `trip_distribution_network` | 根據 lane metadata 取出正確 operands，例如 lane2 取 A0[k3]=3 和 B1[k3]=13 |
| `pe_lane` | 執行乘法，例如 `3*13=39` |
| `trip_reduction_tree` | 把同一個 C 座標的 product 加起來，例如 `C01=22+39=61` |
| `row_local_buffer` | 保存單 chunk partial C，例如 chunk0 的 `[[15,61],[0,187]]` |
| `trip_compute_top` | 將以上模組串成單 chunk 完整計算 |
| `trip_tile_compute_engine` | 對 chunk0、chunk1 做跨 K 累加，得到最終 `[[29,61],[0,270]]` |

## 6. 目前設計限制與注意事項

- `LANES=4` 時，單 chunk 若 effectual MAC 超過 4，只會保留前 4 筆並拉高 `overflow_o`。正確完整結果需要上層重新切分或降低單 chunk density。
- `row_local_buffer` 只保存單 chunk 結果，跨 chunk 累加由 `trip_tile_compute_engine` 負責。
- `trip_reduction_tree` 的 valid 判斷是 `sum != 0`，signed mode 若抵銷成 0，valid 可能不代表「曾有 MAC」。
- 目前 `trip_distribution_network` 是小型 direct routing，適合 MVP 參數；若未來擴大 rows/cols/lanes，可能需要真正 NoC 或更分層的 routing。
- `mfiu` 是 combinational 掃描所有 `(row,col,k)`，參數變大時 critical path 會增加。

## 7. 建議模擬指令

可用 Icarus Verilog 執行主要 TB，例如：

```bash
cd FPGA_design/src

iverilog -g2012 -o tb_bitmask_buffer.vvp bitmask_buffer.v tb_bitmask_buffer.v
vvp tb_bitmask_buffer.vvp

iverilog -g2012 -o tb_mfiu.vvp mfiu.v tb_mfiu.v
vvp tb_mfiu.vvp

iverilog -g2012 -o tb_trip_compute_top.vvp \
  bitmask_buffer.v mfiu.v trip_intersection_top.v trip_distribution_network.v \
  pe_lane.v trip_reduction_tree.v row_local_buffer.v trip_compute_top.v \
  tb_trip_compute_top.v
vvp tb_trip_compute_top.vvp

iverilog -g2012 -o tb_trip_tile_compute_engine.vvp \
  bitmask_buffer.v mfiu.v trip_intersection_top.v trip_distribution_network.v \
  pe_lane.v trip_reduction_tree.v row_local_buffer.v trip_compute_top.v \
  trip_tile_compute_engine.v tb_trip_tile_compute_engine.v
vvp tb_trip_tile_compute_engine.vvp
```

Regression 檔案內有多個 top module，需用 `-s` 指定：

```bash
iverilog -g2012 -s tb_trip_tile_regression -o tb_trip_tile_regression.vvp \
  bitmask_buffer.v mfiu.v trip_intersection_top.v trip_distribution_network.v \
  pe_lane.v trip_reduction_tree.v row_local_buffer.v trip_compute_top.v \
  trip_tile_compute_engine.v tb_trip_tile_regression.v
vvp tb_trip_tile_regression.vvp

iverilog -g2012 -s tb_trip_signed_compute -o tb_trip_signed_compute.vvp \
  bitmask_buffer.v mfiu.v trip_intersection_top.v trip_distribution_network.v \
  pe_lane.v trip_reduction_tree.v row_local_buffer.v trip_compute_top.v \
  trip_tile_compute_engine.v tb_trip_tile_regression.v
vvp tb_trip_signed_compute.vvp

iverilog -g2012 -s tb_trip_param_shapes -o tb_trip_param_shapes.vvp \
  bitmask_buffer.v mfiu.v trip_intersection_top.v trip_distribution_network.v \
  pe_lane.v trip_reduction_tree.v row_local_buffer.v trip_compute_top.v \
  trip_tile_compute_engine.v tb_trip_tile_regression.v
vvp tb_trip_param_shapes.vvp
```
