# TrIP / MFIU Testbench 說明

本文整理以下三個 testbench：

- `tb_bitmask_buffer.v`
- `tb_mfiu.v`
- `tb_trip_intersection_top.v`

這三個 testbench 是由低階到高階逐步驗證 TrIP sparse datapath 前端：

```text
tb_bitmask_buffer
    驗證 sparse fiber metadata / value storage

tb_mfiu
    驗證多 fiber bitmask intersection 與 lane metadata packing

tb_trip_intersection_top
    驗證 bitmask_buffer + MFIU 整合後，能正確讀出 A/B masks 並產生 effectual MAC metadata
```

整體設計目前採用最小可行版本：

```text
NUM_ROWS   = 2
NUM_COLS   = 2
K_BITS     = 4
LANES      = 4
DATA_WIDTH = 16
ID_WIDTH   = 4
```

其中：

- `NUM_ROWS = 2`：一次處理 2 條 A-side fiber，也就是 2 條 A rows。
- `NUM_COLS = 2`：一次處理 2 條 B-side fiber，也就是 2 條 B columns。
- `K_BITS = 4`：每條 fiber 的 bitmask 寬度是 4，代表 k0 到 k3。
- `LANES = 4`：MFIU 最多輸出 4 個 effectual MAC metadata。
- `DATA_WIDTH = 16`：每個 value slot 是 16-bit。

---

## 1. `tb_bitmask_buffer.v`

### 1.1 測試目標

`tb_bitmask_buffer.v` 測試 `bitmask_buffer.v`。

`bitmask_buffer` 的用途是儲存 TrIP sparse fiber 的 metadata 與 values。每個 fiber entry 包含：

```text
fiber id
bitmask[K_BITS-1:0]
values[K_BITS-1:0]
```

目前採用 fixed-slot value layout。也就是說，即使某個 k slot 是 zero，也仍然保留 value slot。舉例：

```text
mask = 4'b1010
values = {slot3, slot2, slot1, slot0}
```

若：

```text
slot3 = 16'hAAAA
slot2 = 16'h0000
slot1 = 16'h5555
slot0 = 16'h0000
```

則 `values` 寫成：

```verilog
{16'hAAAA, 16'h0000, 16'h5555, 16'h0000}
```

這種設計讓 MFIU 產生的 `k_sel` 可以直接索引 value slot，不需要 prefix-sum 或 compact-value lookup。

### 1.2 參數設定

```verilog
localparam NUM_FIBERS = 4;
localparam K_BITS     = 4;
localparam DATA_WIDTH = 16;
localparam ID_WIDTH   = 4;
localparam ADDR_WIDTH = $clog2(NUM_FIBERS);   // 2
```

代表 buffer 共有 4 筆 fiber entry：

```text
addr 0
addr 1
addr 2
addr 3
```

每筆 entry：

```text
id      : 4-bit
mask    : 4-bit
values  : 4 * 16 = 64-bit
```

### 1.3 DUT 介面

Testbench 宣告的 DUT port 分成四類。

#### Clock / Reset

```verilog
reg clk;
reg reset;
```

`clk` 是 10 ns period：

```verilog
initial clk = 0;
always #5 clk = ~clk;
```

`reset` 用來清空 buffer 內部 memory 與 registered read outputs。

#### Write port

```verilog
reg                             wr_en_i;
reg  [ADDR_WIDTH-1:0]           wr_addr_i;
reg  [ID_WIDTH-1:0]             wr_id_i;
reg  [K_BITS-1:0]               wr_mask_i;
reg  [K_BITS*DATA_WIDTH-1:0]    wr_values_i;
```

寫入一筆 fiber entry 時：

```text
wr_en_i    = 1
wr_addr_i  = 要寫入的 entry index
wr_id_i    = row_id 或 col_id
wr_mask_i  = bitmask
wr_values_i = fixed-slot values
```

#### Read port

```verilog
reg  [ADDR_WIDTH-1:0]           rd_addr_i;
wire [ID_WIDTH-1:0]             rd_id_o;
wire [K_BITS-1:0]               rd_mask_o;
wire [K_BITS*DATA_WIDTH-1:0]    rd_values_o;
```

`bitmask_buffer` 是 registered read，也就是讀取有 1-cycle latency：

```text
cycle N    : 設定 rd_addr_i
cycle N+1  : rd_id_o / rd_mask_o / rd_values_o 有效
```

#### Indexed value output

```verilog
reg  [$clog2(K_BITS)-1:0]       k_sel_i;
wire [DATA_WIDTH-1:0]           k_value_o;
```

`k_value_o` 會從目前 registered `rd_values_o` 中取出指定 slot：

```text
k_sel_i = 0 -> slot0
k_sel_i = 1 -> slot1
k_sel_i = 2 -> slot2
k_sel_i = 3 -> slot3
```

### 1.4 Helper Task

#### `write_fiber`

```verilog
task write_fiber;
    input [ADDR_WIDTH-1:0]        addr;
    input [ID_WIDTH-1:0]          id;
    input [K_BITS-1:0]            mask;
    input [K_BITS*DATA_WIDTH-1:0] values;
```

功能：寫入一筆 fiber entry。

流程：

```text
1. 等 negedge clk
2. 設定 wr_en_i = 1
3. 放入 wr_addr_i / wr_id_i / wr_mask_i / wr_values_i
4. 等 posedge clk，讓 DUT 寫入
5. #1 後關閉 wr_en_i
```

使用 negedge 設定 input 的原因是避免在 posedge 附近改變 input，讓 DUT 在下一個 posedge 看到穩定訊號。

#### `read_fiber`

```verilog
task read_fiber;
    input  [ADDR_WIDTH-1:0]       addr;
    output [ID_WIDTH-1:0]         id;
    output [K_BITS-1:0]           mask;
    output [K_BITS*DATA_WIDTH-1:0] values;
```

功能：讀出一筆 fiber entry。

流程：

```text
1. 等 negedge clk
2. 設定 rd_addr_i
3. 等下一個 posedge clk
4. #1 等待 registered output 穩定
5. 把 rd_id_o / rd_mask_o / rd_values_o 存到 output variables
```

這個 task 明確反映 `bitmask_buffer` 的 1-cycle read latency。

#### `check`

```verilog
task check;
    input [127:0] name;
    input         got;
    input         expected;
```

功能：比較一個 boolean 條件是否符合預期。

在此 testbench 中，通常不是直接把 64-bit data 丟進 `check`，而是先寫成：

```verilog
(cap_values === expected_values)
```

所以 `got` 是 1-bit 的比較結果。

### 1.5 Test Cases

#### TC1：Reset 後內容應該清空

```verilog
read_fiber(2'd0, cap_id, cap_mask, cap_values);
check("TC1 id=0 after reset  ", (cap_id   === 4'h0), 1'b1);
check("TC1 mask=0 after reset", (cap_mask  === 4'b0000), 1'b1);
```

驗證：

- reset 後 `id_mem[0] = 0`
- reset 後 `mask_mem[0] = 0`

此案例確保 reset path 有清 memory。

#### TC2：單筆寫入與讀回

寫入：

```verilog
write_fiber(2'd0, 4'd3, 4'b1010,
            {16'hAAAA, 16'h0000, 16'h5555, 16'h0000});
```

代表：

```text
addr  = 0
id    = 3
mask  = 1010
slot3 = AAAA
slot2 = 0000
slot1 = 5555
slot0 = 0000
```

驗證：

- `id` 正確讀回 3
- `mask` 正確讀回 `1010`
- `values` 64-bit 完整讀回

#### TC3：`k_sel_i` indexed value extraction

測試：

```verilog
k_sel_i = 2'd1;  // expect slot1 = 16'h5555
k_sel_i = 2'd3;  // expect slot3 = 16'hAAAA
k_sel_i = 2'd0;  // expect slot0 = 16'h0000
```

驗證 `k_value_o` 的 part-select 是否正確：

```text
k=1 -> 0x5555
k=3 -> 0xAAAA
k=0 -> 0x0000
```

這對後續 TrIP 很重要，因為 MFIU 會輸出 `k_sel`，distribution network 或 compute datapath 必須能根據 `k` 取到正確 value。

#### TC4：寫滿 4 筆 entry 並逐筆讀回

寫入 4 筆：

```text
addr0: id=0, mask=0001
addr1: id=1, mask=0011
addr2: id=2, mask=0101
addr3: id=3, mask=1111
```

驗證每個 address 對應的 `id` 和 `mask` 都正確。

這個案例確認：

- address decode 正確
- 多筆 entry 不會互相覆蓋
- memory array indexing 正確

#### TC5：覆寫單一 entry，其他 entry 不變

覆寫：

```verilog
write_fiber(2'd2, 4'd9, 4'b1100, {16'hDEAD, 16'hBEEF, 16'h0000, 16'h0000});
```

驗證：

```text
addr2 被更新成 id=9, mask=1100
addr3 保持 id=3, mask=1111
```

這確認 write operation 只影響 `wr_addr_i` 指到的 entry。

#### TC6：再次 reset，所有內容應清空

流程：

```verilog
@(negedge clk); reset = 1'b1;
@(posedge clk); #1;
@(negedge clk); reset = 1'b0;
```

再讀 `addr3`：

```text
mask   = 0000
values = 0
```

這確認 reset 不只一開始有效，後續執行中也能重新清空 buffer。

### 1.6 `tb_bitmask_buffer` 驗證重點總結

此 testbench 覆蓋：

- reset 清空 memory
- 單筆寫入與讀回
- registered read latency
- fixed-slot value layout
- `k_sel` value extraction
- 多 address 寫入
- overwrite 行為
- reset 後再次清空

---

## 2. `tb_mfiu.v`

### 2.1 測試目標

`tb_mfiu.v` 測試 `mfiu.v`。

`mfiu` 的功能是：

```text
給定多條 A row bitmask
給定多條 B column bitmask
對每一組 A row / B column 做 AND
找出同一個 k 上 A 與 B 都非零的位置
把有效 MAC 壓進 LANES 個 output lane
```

effectual MAC 定義：

```text
A_mask[row][k] == 1 且 B_mask[col][k] == 1
```

也就是：

```text
A[row][k] * B[col][k]
```

才需要真的送去 multiplier。

### 2.2 參數設定

```verilog
localparam NUM_ROWS  = 2;
localparam NUM_COLS  = 2;
localparam K_BITS    = 4;
localparam LANES     = 4;
localparam ROW_IDX_W = 1;
localparam COL_IDX_W = 1;
localparam K_IDX_W   = 2;
localparam CNT_W     = 3;
```

代表：

```text
2 條 A rows
2 條 B columns
每條 bitmask 4-bit
最多輸出 4 個 matched MAC
```

`ROW_IDX_W = 1` 因為 row 只有 0 和 1。

`COL_IDX_W = 1` 因為 column 只有 0 和 1。

`K_IDX_W = 2` 因為 k 有 0, 1, 2, 3。

`CNT_W = 3` 因為 match count 可能是 0 到 4，需要 3-bit 表示。

### 2.3 DUT input packing

```verilog
reg [NUM_ROWS*K_BITS-1:0] a_mask_i;
reg [NUM_COLS*K_BITS-1:0] b_mask_i;
```

在此設定下：

```text
a_mask_i = 8-bit
b_mask_i = 8-bit
```

packing 規則：

```text
a_mask_i[3:0] = A0 mask
a_mask_i[7:4] = A1 mask

b_mask_i[3:0] = B0 mask
b_mask_i[7:4] = B1 mask
```

所以 testbench 常寫：

```verilog
apply({4'b0110, 4'b1010},
      {4'b1010, 4'b1001});
```

代表：

```text
A1 = 0110
A0 = 1010

B1 = 1010
B0 = 1001
```

### 2.4 DUT outputs

```verilog
wire [LANES-1:0]             lane_valid_o;
wire [LANES*ROW_IDX_W-1:0]  a_row_sel_o;
wire [LANES*COL_IDX_W-1:0]  b_col_sel_o;
wire [LANES*K_IDX_W-1:0]    k_sel_o;
wire [CNT_W-1:0]            match_count_o;
wire                        overflow_o;
```

含義：

- `lane_valid_o[lane]`：該 lane 是否有有效 MAC。
- `a_row_sel_o[lane]`：該 lane 使用哪條 A row。
- `b_col_sel_o[lane]`：該 lane 使用哪條 B column。
- `k_sel_o[lane]`：該 lane 使用哪個 k slot。
- `match_count_o`：填入幾個 lane，上限為 `LANES`。
- `overflow_o`：實際 effectual MAC 數量是否超過 `LANES`。

### 2.5 Helper Functions

#### `get_row`

```verilog
get_row(a_row_sel_o, lane)
```

從 packed `a_row_sel_o` 中取出某個 lane 的 row index。

#### `get_col`

```verilog
get_col(b_col_sel_o, lane)
```

從 packed `b_col_sel_o` 中取出某個 lane 的 column index。

#### `get_k`

```verilog
get_k(k_sel_o, lane)
```

從 packed `k_sel_o` 中取出某個 lane 的 k index。

這三個 function 讓 testbench 不需要手動寫 part-select。

### 2.6 Helper Tasks

#### `apply`

```verilog
task apply;
    input [NUM_ROWS*K_BITS-1:0] am;
    input [NUM_COLS*K_BITS-1:0] bm;
```

功能：

```text
設定 a_mask_i / b_mask_i
等待 #1 讓 combinational MFIU output settle
```

因為 `mfiu.v` 是 combinational scanner，沒有 clock，所以每個 test case 只需要改 input 並等待一個 delta/time step。

#### `check`

檢查 1-bit condition。

#### `check_int`

檢查 integer 數值，例如 row、col、k、match count。

### 2.7 MFIU scan order

`mfiu.v` 的 scan order 是：

```text
for r = 0 .. NUM_ROWS-1
  for c = 0 .. NUM_COLS-1
    for k = 0 .. K_BITS-1
```

也就是：

```text
(r0,c0,k0)
(r0,c0,k1)
(r0,c0,k2)
(r0,c0,k3)
(r0,c1,k0)
...
(r1,c1,k3)
```

如果某個位置 match，就依序塞進 lane0、lane1、lane2、lane3。

這個順序會影響 testbench 對 lane metadata 的預期。

### 2.8 Test Cases

#### TC1：全 0，沒有 intersection

輸入：

```verilog
apply(8'h00, 8'h00);
```

代表：

```text
A0 = 0000
A1 = 0000
B0 = 0000
B1 = 0000
```

預期：

```text
lane_valid_o = 0000
match_count_o = 0
overflow_o = 0
```

#### TC2：單一 intersection

輸入：

```verilog
A0 = 0001
A1 = 0000
B0 = 0001
B1 = 0000
```

只有：

```text
A0[k0] & B0[k0] = 1
```

預期：

```text
lane0 valid = 1
lane0 row = 0
lane0 col = 0
lane0 k   = 0
lane1 valid = 0
match_count = 1
overflow = 0
```

#### TC3：`HARDWARE_STRUCTURE.md §29` worked example

輸入：

```text
A0 = 1010
A1 = 0110
B0 = 1001
B1 = 1010
```

逐組 AND：

```text
pair(0,0): A0 & B0 = 1010 & 1001 = 1000 -> k3
pair(0,1): A0 & B1 = 1010 & 1010 = 1010 -> k1, k3
pair(1,0): A1 & B0 = 0110 & 1001 = 0000 -> none
pair(1,1): A1 & B1 = 0110 & 1010 = 0010 -> k1
```

依 scan order：

```text
lane0 = (row=0, col=0, k=3)
lane1 = (row=0, col=1, k=1)
lane2 = (row=0, col=1, k=3)
lane3 = (row=1, col=1, k=1)
```

預期：

```text
lane_valid = 1111
match_count = 4
overflow = 0
```

這是最重要的 golden case，因為它同時驗證：

- 多 row
- 多 column
- 同一 pair 多個 k match
- 有些 pair 完全無 match
- lane packing order

#### TC4：Overflow case

輸入：

```text
A0 = 1111
A1 = 1111
B0 = 1111
B1 = 0000
```

effectual MAC：

```text
pair(0,0): 4 hits
pair(0,1): 0 hits
pair(1,0): 4 hits
pair(1,1): 0 hits
total = 8
```

但 `LANES = 4`，所以只能輸出前 4 個 lanes。

預期：

```text
match_count = 4
overflow = 1
lane_valid = 1111
```

此案例驗證：

- MFIU 可以偵測實際 match 數量超過 lanes。
- `match_count_o` 是 capped count，不是 total count。
- `overflow_o` 會提醒 controller 需要 replay 或降低 B columns。

#### TC5：一條 A fiber 全 0、一條 B fiber 全 0

輸入：

```text
A0 = 0000
A1 = 1111
B0 = 1111
B1 = 0000
```

實際 match：

```text
pair(0,0): none
pair(0,1): none
pair(1,0): k0,k1,k2,k3
pair(1,1): none
```

預期：

```text
match_count = 4
overflow = 0
lane0 row = 1
lane0 col = 0
```

此案例驗證 MFIU 不會被 empty fiber 影響，且能跳到後面的 `(row=1,col=0)` pair。

#### TC6：所有 pair 共用同一個 k

輸入：

```text
A0 = 1000
A1 = 1000
B0 = 1000
B1 = 1000
```

所有 pair 都只在 `k=3` match：

```text
(0,0,k3)
(0,1,k3)
(1,0,k3)
(1,1,k3)
```

預期：

```text
match_count = 4
overflow = 0
lane0 k = 3
lane1 k = 3
lane2 k = 3
lane3 k = 3
```

此案例驗證：

- 多個 pair 可以共享同一個 k index。
- `k_sel_o` 對每個 lane 都能正確輸出。

### 2.9 `tb_mfiu` 驗證重點總結

此 testbench 覆蓋：

- 無 match
- 單一 match
- 多 match
- lane packing order
- overflow detection
- empty fiber
- 多 pair 共用同一 k

---

## 3. `tb_trip_intersection_top.v`

### 3.1 測試目標

`tb_trip_intersection_top.v` 測試 `trip_intersection_top.v`。

`trip_intersection_top` 是整合層，內部包含：

```text
A bitmask_buffer
B bitmask_buffer
MFIU
FSM
```

它的任務是：

```text
1. 由 testbench 寫入 A/B sparse fibers
2. start_i 觸發後，FSM 依序讀出 A/B buffer 中的 masks
3. capture 所有 masks
4. 將 packed masks 送進 MFIU
5. done_o pulse 時輸出 MFIU metadata
```

此 testbench 不驗證乘法，也不驗證 value distribution。它只驗證 intersection front-end。

### 3.2 參數設定

```verilog
localparam NUM_ROWS   = 2;
localparam NUM_COLS   = 2;
localparam K_BITS     = 4;
localparam LANES      = 4;
localparam DATA_WIDTH = 16;
localparam ID_WIDTH   = 4;
localparam ADDR_W_A   = 1;
localparam ADDR_W_B   = 1;
localparam ROW_IDX_W  = 1;
localparam COL_IDX_W  = 1;
localparam K_IDX_W    = 2;
localparam CNT_W      = 3;
localparam MAX_FIBERS = 2;
localparam VAL_W      = K_BITS * DATA_WIDTH;
```

與前兩個 testbench 相比，這裡多了：

```text
ADDR_W_A
ADDR_W_B
MAX_FIBERS
VAL_W
```

因為 top 需要真的寫入 buffer，再由 FSM 讀出 buffer。

### 3.3 DUT input ports

#### A buffer write port

```verilog
reg  a_wr_en_i;
reg  [ADDR_W_A-1:0]  a_wr_addr_i;
reg  [ID_WIDTH-1:0]  a_wr_id_i;
reg  [K_BITS-1:0]    a_wr_mask_i;
reg  [VAL_W-1:0]     a_wr_values_i;
```

寫入 A-side fiber。

在 TrIP 語意中：

```text
a_wr_addr_i -> A fiber buffer address
a_wr_id_i   -> A row id
a_wr_mask_i -> A row bitmask
a_wr_values_i -> A fixed-slot values
```

#### B buffer write port

```verilog
reg  b_wr_en_i;
reg  [ADDR_W_B-1:0]  b_wr_addr_i;
reg  [ID_WIDTH-1:0]  b_wr_id_i;
reg  [K_BITS-1:0]    b_wr_mask_i;
reg  [VAL_W-1:0]     b_wr_values_i;
```

寫入 B-side fiber。

在 TrIP 語意中：

```text
b_wr_addr_i -> B fiber buffer address
b_wr_id_i   -> B column id
b_wr_mask_i -> B column bitmask
b_wr_values_i -> B fixed-slot values
```

#### Control

```verilog
reg start_i;
wire done_o;
```

`start_i` 拉高一個 cycle，觸發 top FSM 開始讀 buffer。

`done_o` 是 one-cycle pulse。當 `done_o = 1` 時：

```text
lane_valid_o
a_row_sel_o
b_col_sel_o
k_sel_o
match_count_o
overflow_o
```

都是 valid。

### 3.4 DUT output ports

```verilog
wire [LANES-1:0]            lane_valid_o;
wire [LANES*ROW_IDX_W-1:0] a_row_sel_o;
wire [LANES*COL_IDX_W-1:0] b_col_sel_o;
wire [LANES*K_IDX_W-1:0]   k_sel_o;
wire [CNT_W-1:0]           match_count_o;
wire                       overflow_o;
```

這些輸出直接來自 MFIU。

### 3.5 Top-level timing

Testbench 註解中的 timing：

```text
negedge      : start_i = 1
posedge T    : FSM IDLE -> S_READ
posedge T+1  : S_READ capture mask[0]
posedge T+2  : S_READ capture mask[1]
posedge T+3  : S_DONE done_o = 1
```

重點是 `bitmask_buffer` 有 registered read latency，所以 top 必須提前設定 read address。

目前 top 的設計是：

```text
IDLE:
  rd_addr = 0
  buffer 持續 pre-read fiber 0

start_i 被 sample:
  capture 流程開始
  同時 prefetch addr 1

S_READ cycle 1:
  capture fiber 0

S_READ cycle 2:
  capture fiber 1

S_DONE:
  done_o = 1
```

這個 testbench 會驗證整合後是否真的能在 `done_o` 時看到正確 MFIU outputs。

### 3.6 Helper Functions

與 `tb_mfiu.v` 一樣：

```verilog
get_row
get_col
get_k
```

用來從 packed lane metadata 中取出指定 lane 的欄位。

### 3.7 Helper Tasks

#### `write_a_fiber`

```verilog
task write_a_fiber;
    input [ADDR_W_A-1:0] addr;
    input [ID_WIDTH-1:0] id;
    input [K_BITS-1:0]   mask;
    input [VAL_W-1:0]    values;
```

功能：寫入 A buffer。

流程：

```text
1. negedge clk 設定 A write signals
2. a_wr_en_i = 1
3. posedge clk 寫入 A bitmask_buffer
4. #1 後 a_wr_en_i = 0
```

#### `write_b_fiber`

與 `write_a_fiber` 相同，但寫入 B buffer。

#### `run_intersection`

```verilog
task run_intersection;
    integer i;
    begin
        @(negedge clk); start_i = 1;
        @(posedge clk); #1;
        start_i = 0;
        for (i = 0; i < MAX_FIBERS + 1; i = i + 1)
            @(posedge clk);
        #1;
    end
endtask
```

功能：啟動一次 intersection run，並等到 `done_o` 穩定。

以 `MAX_FIBERS = 2` 來說：

```text
start_i sampled 後
等待 2 個 read cycles
再等待 1 個 done cycle
```

最後 `#1` 讓 outputs settle。

#### `check_lane`

```verilog
task check_lane;
    input [199:0] prefix;
    input integer lane;
    input integer exp_row, exp_col, exp_k;
```

一次檢查某個 lane 的完整 metadata：

```text
a_row_sel_o[lane]
b_col_sel_o[lane]
k_sel_o[lane]
```

### 3.8 Test Cases

#### TC1：`§29 worked example`

寫入 A buffer：

```verilog
write_a_fiber(0, 0, 4'b1010, {VAL_W{1'b0}});
write_a_fiber(1, 1, 4'b0110, {VAL_W{1'b0}});
```

代表：

```text
A0 = 1010
A1 = 0110
```

寫入 B buffer：

```verilog
write_b_fiber(0, 0, 4'b1001, {VAL_W{1'b0}});
write_b_fiber(1, 1, 4'b1010, {VAL_W{1'b0}});
```

代表：

```text
B0 = 1001
B1 = 1010
```

交集：

```text
pair(0,0): A0 & B0 = 1010 & 1001 = 1000 -> k3
pair(0,1): A0 & B1 = 1010 & 1010 = 1010 -> k1, k3
pair(1,0): A1 & B0 = 0110 & 1001 = 0000 -> none
pair(1,1): A1 & B1 = 0110 & 1010 = 0010 -> k1
```

預期：

```text
done_o = 1
lane_valid = 1111
match_count = 4
overflow = 0

lane0 = (0,0,3)
lane1 = (0,1,1)
lane2 = (0,1,3)
lane3 = (1,1,1)
```

此案例驗證 top 是否能：

- 正確寫入 A/B buffers
- 正確讀回兩條 A masks 和兩條 B masks
- 正確送入 MFIU
- 在 `done_o` 時輸出正確 lane metadata

#### TC2：沒有 intersection

寫入：

```text
A0 = 1010
A1 = 1010
B0 = 0101
B1 = 0101
```

因為：

```text
1010 & 0101 = 0000
```

所有 pairwise AND 都是 0。

預期：

```text
lane_valid = 0000
match_count = 0
overflow = 0
```

此案例驗證 top 不會產生 false positive matches。

#### TC3：Overflow

寫入：

```text
A0 = 1111
A1 = 1111
B0 = 1111
B1 = 0000
```

實際 effectual MAC：

```text
pair(0,0): 4
pair(1,0): 4
total = 8
```

但 `LANES = 4`。

預期：

```text
match_count = 4
overflow = 1
lane_valid = 1111
```

此案例驗證 overflow signal 能通過 top 正確傳出。

#### TC4：覆寫 buffers 後重新執行

寫入：

```text
A0 = 0001
A1 = 0001
B0 = 0001
B1 = 0001
```

所有 pair 只在 `k=0` match。

預期 scan order：

```text
lane0 = (0,0,0)
lane1 = (0,1,0)
lane2 = (1,0,0)
lane3 = (1,1,0)
```

此案例驗證：

- buffer 可以被覆寫
- top 第二次執行時讀到的是新資料
- MFIU metadata 會根據新 masks 更新

#### TC5：連續執行，不重新寫入資料

TC5 不寫新 fiber，直接再次呼叫：

```verilog
run_intersection;
```

資料仍然是 TC4 的：

```text
A0 = 0001
A1 = 0001
B0 = 0001
B1 = 0001
```

預期結果與 TC4 相同。

此案例驗證：

- top FSM 可以連續 start
- done 後回到 IDLE 狀態正確
- buffer 中保留的資料可重複使用
- read address 在下一輪開始前有回到預期狀態

### 3.9 `tb_trip_intersection_top` 驗證重點總結

此 testbench 覆蓋：

- A/B buffers 寫入
- top FSM 啟動與完成 timing
- registered read latency handling
- MFIU output metadata
- no-match case
- overflow case
- buffer overwrite
- consecutive runs

---

## 4. 三個 Testbench 的關係

### 4.1 驗證層級

```text
Level 1: tb_bitmask_buffer
    單獨驗證 metadata/value storage

Level 2: tb_mfiu
    單獨驗證 bitmask intersection 與 lane packing

Level 3: tb_trip_intersection_top
    整合 bitmask_buffer + MFIU + FSM
```

### 4.2 為什麼要分三層測

如果只測 top，當結果錯誤時很難判斷問題來自：

```text
buffer 寫錯
buffer 讀 latency 錯
MFIU intersection 錯
lane packing 錯
FSM done timing 錯
```

分層 testbench 可以讓 debug 更容易：

- `tb_bitmask_buffer` 過了，代表 storage 基礎可靠。
- `tb_mfiu` 過了，代表 bitmask matching 邏輯可靠。
- `tb_trip_intersection_top` 過了，代表 top-level integration timing 可靠。

---

## 5. 執行方式

如果使用 repo 裡已安裝的 `.eda-tools`：

```bash
cd /home/jeter/CNN-Accelerator-Based-on-Eyeriss-v2
export PATH=/home/jeter/CNN-Accelerator-Based-on-Eyeriss-v2/.eda-tools/bin:$PATH
```

### 5.1 執行 `tb_bitmask_buffer`

```bash
mkdir -p build/sim
iverilog -g2012 \
  -o build/sim/tb_bitmask_buffer.vvp \
  FPGA_design/src/bitmask_buffer.v \
  FPGA_design/src/tb_bitmask_buffer.v

vvp build/sim/tb_bitmask_buffer.vvp
```

預期結果：

```text
Result: 22 passed, 0 failed
ALL PASS
```

### 5.2 執行 `tb_mfiu`

```bash
mkdir -p build/sim
iverilog -g2012 \
  -o build/sim/tb_mfiu.vvp \
  FPGA_design/src/mfiu.v \
  FPGA_design/src/tb_mfiu.v

vvp build/sim/tb_mfiu.vvp
```

預期結果：

```text
Result: 38 passed, 0 failed
```

### 5.3 執行 `tb_trip_intersection_top`

```bash
mkdir -p build/sim
iverilog -g2012 \
  -o build/sim/tb_trip_intersection_top.vvp \
  FPGA_design/src/bitmask_buffer.v \
  FPGA_design/src/mfiu.v \
  FPGA_design/src/trip_intersection_top.v \
  FPGA_design/src/tb_trip_intersection_top.v

vvp build/sim/tb_trip_intersection_top.vvp
```

預期結果：

```text
Result: 44 passed, 0 failed
```

---

## 6. 目前測試仍未覆蓋的部分

這三個 testbench 主要驗證 TrIP intersection front-end，尚未覆蓋完整論文版 TrIP datapath。

未覆蓋項目包括：

- A/B distribution network 是否把 values route 到 multiplier lanes
- multiplier lane 實際乘法
- reduction tree 是否把同一 output coordinate 的 partial products 加總
- row-local buffer scatter write
- dynamic B-column packing
- prefix-sum / shift-unit 版本 MFIU
- compact sparse value layout
- multi-cycle replay when `overflow_o = 1`

若要驗證已新增的 compute MVP，應另外執行：

```bash
iverilog -g2012 \
  -o build/sim/tb_trip_compute_top.vvp \
  FPGA_design/src/bitmask_buffer.v \
  FPGA_design/src/mfiu.v \
  FPGA_design/src/trip_intersection_top.v \
  FPGA_design/src/trip_distribution_network.v \
  FPGA_design/src/pe_lane.v \
  FPGA_design/src/trip_reduction_tree.v \
  FPGA_design/src/row_local_buffer.v \
  FPGA_design/src/trip_compute_top.v \
  FPGA_design/src/tb_trip_compute_top.v

vvp build/sim/tb_trip_compute_top.vvp
```

---

## 7. 重要實作細節補充

### 7.1 Bit ordering 與 slot 對應

這組設計最容易搞錯的是 bit ordering。

在 `bitmask_buffer` 中：

```text
mask[0] 對應 k0
mask[1] 對應 k1
mask[2] 對應 k2
mask[3] 對應 k3
```

在 values bus 中：

```text
values[15:0]   = slot0 = k0
values[31:16]  = slot1 = k1
values[47:32]  = slot2 = k2
values[63:48]  = slot3 = k3
```

所以 Verilog 寫：

```verilog
{16'hAAAA, 16'h0000, 16'h5555, 16'h0000}
```

實際對應是：

```text
slot3 = 16'hAAAA
slot2 = 16'h0000
slot1 = 16'h5555
slot0 = 16'h0000
```

這也是 `tb_bitmask_buffer` TC3 為什麼會測：

```text
k_sel = 1 -> 0x5555
k_sel = 3 -> 0xAAAA
```

如果未來 debug 時發現 `k_sel` 正確但 value 錯，第一個要檢查的就是 value packing 順序是否反了。

### 7.2 Fiber packing 規則

在 `mfiu.v` 中，A/B mask bus 是 packed vector。

以 `NUM_ROWS = 2`、`K_BITS = 4` 為例：

```text
a_mask_i[3:0] = A0
a_mask_i[7:4] = A1
```

所以：

```verilog
apply({4'b0110, 4'b1010}, ...);
```

不是代表 A0 在左邊，而是：

```text
A1 = 0110
A0 = 1010
```

B 也是同樣規則：

```text
b_mask_i[3:0] = B0
b_mask_i[7:4] = B1
```

這個 packing style 是因為 RTL 用：

```verilog
a_mask_i[r*K_BITS +: K_BITS]
b_mask_i[c*K_BITS +: K_BITS]
```

也就是 low bits 放 index 0，高 bits 放 index 1。

### 7.3 MFIU lane packing 順序

`mfiu.v` 掃描順序是：

```text
r outer loop
c middle loop
k inner loop
```

也就是：

```text
(r0,c0,k0)
(r0,c0,k1)
(r0,c0,k2)
(r0,c0,k3)
(r0,c1,k0)
(r0,c1,k1)
...
(r1,c1,k3)
```

只要遇到 bitmask AND 結果是 1，就依序塞進下一個 lane。

例如：

```text
A0 = 1010
A1 = 0110
B0 = 1001
B1 = 1010
```

pairwise AND：

```text
A0 & B0 = 1000 -> k3
A0 & B1 = 1010 -> k1, k3
A1 & B0 = 0000
A1 & B1 = 0010 -> k1
```

依 scan order，lane 順序是：

```text
lane0 = (0,0,3)
lane1 = (0,1,1)
lane2 = (0,1,3)
lane3 = (1,1,1)
```

注意：`A0 & B1 = 1010` 中 k1 會在 k3 前面，因為 k loop 是由小到大。

### 7.4 `match_count_o` 與 `overflow_o` 的語意

目前 `match_count_o` 表示「已填入 lane 的數量」，不是所有 effectual MAC 的總數。

當 total matches 小於或等於 `LANES`：

```text
match_count_o = total_matches
overflow_o = 0
```

當 total matches 大於 `LANES`：

```text
match_count_o = LANES
overflow_o = 1
```

例如 TC4：

```text
total matches = 8
LANES = 4
```

輸出：

```text
match_count_o = 4
overflow_o = 1
```

這表示目前這一拍只保留前 4 個 matches，後面的 matches 需要未來 controller replay 或重新切分 B columns。

### 7.5 `done_o` 的取樣時間

`trip_intersection_top` 的輸出只在 `done_o = 1` 的 cycle 被視為 valid。

Testbench 中：

```verilog
run_intersection;
check(... lane_valid_o ...);
```

`run_intersection` 會等到 `done_o` 穩定後才返回，所以後面的 check 是在正確時間點讀 output。

如果未來手動寫新 test，不要在 `start_i` 拉高後立刻檢查 `lane_valid_o`，因為 FSM 還在讀 buffer。

### 7.6 為什麼 testbench 在 negedge 設定 input

多數 task 都在 negedge 設 input：

```verilog
@(negedge clk);
wr_en_i = 1;
...
@(posedge clk); #1;
```

這樣做是為了讓 DUT 在 posedge 取樣時看到穩定 input。

如果在 posedge 附近改 input，模擬可能仍能跑，但語意上比較接近 race condition，不利於 debug。

### 7.7 為什麼 check 後面常用 `===`

Testbench 多數比較使用 case equality：

```verilog
cap_mask === 4'b1010
```

`===` 會把 `X` 和 `Z` 也納入比較。

如果 DUT 輸出是 unknown：

```text
got = 1'bx
```

使用 `==` 有時會產生不明確結果；使用 `===` 可以更嚴格抓到未初始化或未驅動的訊號。

### 7.8 為什麼 `check` task 只吃 1-bit

`tb_bitmask_buffer` 的 `check` 寫法是：

```verilog
task check;
    input [127:0] name;
    input         got;
    input         expected;
```

所以它適合檢查 boolean condition。

因此 testbench 寫：

```verilog
check("TC2 values readback", (cap_values === expected), 1'b1);
```

而不是：

```verilog
check("TC2 values readback", cap_values, expected);
```

若未來要比較寬 bus，建議新增專用 task，例如：

```verilog
task check_hex64;
    input [199:0] label;
    input [63:0] got;
    input [63:0] exp;
```

這樣 fail 時可以直接印出完整 hex 值，debug 會更清楚。

---

## 8. Debug 指南

### 8.1 `tb_bitmask_buffer` fail 時怎麼判斷

| 失敗位置 | 可能原因 | 優先檢查 |
|---|---|---|
| TC1 reset fail | reset 沒清 memory 或 read output | `always @(posedge clk)` reset branch |
| TC2 readback fail | write port 沒寫進正確 address | `wr_en_i`、`wr_addr_i`、memory index |
| TC3 k_sel fail | value slot part-select 錯 | `rd_values_o[k_sel_i * DATA_WIDTH +: DATA_WIDTH]` |
| TC4 多 address fail | memory indexing 錯 | `id_mem[wr_addr_i]` / `mask_mem[wr_addr_i]` |
| TC5 overwrite 影響 addr3 | write address decode 錯 | 是否寫到多個 entry |
| TC6 reset second time fail | reset path 只初始化 output，沒清 memory | reset loop 是否包含全部 memory |

### 8.2 `tb_mfiu` fail 時怎麼判斷

| 失敗位置 | 可能原因 | 優先檢查 |
|---|---|---|
| TC1 false match | lane_valid 沒清 0 | combinational always block default assignment |
| TC2 row/col/k 錯 | packing 解讀錯 | `a_mask_i[r*K_BITS+k]` 與 bus packing |
| TC3 lane order 錯 | scan order 改變 | r/c/k loop 順序 |
| TC4 overflow 錯 | total count 沒算所有 matches | `total` 是否在 overflow 後仍繼續加 |
| TC5 row/col 錯 | empty fiber handling 錯 | zero mask 是否仍產生 lane |
| TC6 k 錯 | k bit order 錯 | `k[K_IDX_W-1:0]` 與 bit index |

### 8.3 `tb_trip_intersection_top` fail 時怎麼判斷

| 失敗位置 | 可能原因 | 優先檢查 |
|---|---|---|
| `done_o` 沒拉高 | FSM 沒從 `S_READ` 到 `S_DONE` | `fiber_cnt`、`MAX_FIBERS` |
| TC1 lane metadata 像重複 A0/B0 | buffer read latency 沒處理好 | `rd_addr_a/b` prefetch timing |
| TC2 有 false match | top capture 到舊 mask | `a_mask_reg`、`b_mask_reg` |
| TC3 overflow 沒傳出 | MFIU output 沒接對 | `overflow_o` connection |
| TC4 overwrite 後仍是舊結果 | buffer write 沒成功或 top 沒重新讀 | write task timing、FSM read |
| TC5 consecutive run fail | FSM 回 IDLE 後 read address 沒重置 | `S_DONE` 是否把 `rd_addr` 設回 0 |

### 8.4 建議加 waveform

若未來要用 GTKWave 或 Vivado xsim debug，可在 testbench 加：

```verilog
initial begin
    $dumpfile("tb_trip_intersection_top.vcd");
    $dumpvars(0, tb_trip_intersection_top);
end
```

然後用：

```bash
gtkwave tb_trip_intersection_top.vcd
```

建議觀察的訊號：

```text
clk
reset
start_i
done_o
dut.state
dut.fiber_cnt
dut.rd_addr_a
dut.rd_addr_b
dut.buf_a_mask
dut.buf_b_mask
dut.a_mask_reg[0]
dut.a_mask_reg[1]
dut.b_mask_reg[0]
dut.b_mask_reg[1]
lane_valid_o
a_row_sel_o
b_col_sel_o
k_sel_o
match_count_o
overflow_o
```

---

## 9. Coverage Matrix

### 9.1 已覆蓋功能

| 功能 | `tb_bitmask_buffer` | `tb_mfiu` | `tb_trip_intersection_top` |
|---|---:|---:|---:|
| reset 清空 | yes | N/A | indirectly |
| single fiber write/read | yes | N/A | yes |
| multiple entries | yes | N/A | yes |
| overwrite | yes | N/A | yes |
| fixed-slot value read | yes | N/A | not checked |
| no intersection | N/A | yes | yes |
| single intersection | N/A | yes | indirectly |
| multi intersection | N/A | yes | yes |
| lane metadata | N/A | yes | yes |
| overflow | N/A | yes | yes |
| consecutive run | N/A | N/A | yes |
| buffer read latency | yes | N/A | yes |

### 9.2 還沒覆蓋或覆蓋不足

| 功能 | 目前狀態 | 建議新增測試 |
|---|---|---|
| values 經 top capture 後正確輸出 | 覆蓋不足 | 在 `tb_trip_intersection_top` 檢查 `a_values_o` / `b_values_o` |
| values route 到 multiplier lane | 不在這三個 testbench | 用 `tb_trip_compute_top` 或 `tb_trip_distribution_network` |
| signed data | 未覆蓋 | 加負數乘法或 signed mode 決策 |
| non-default parameters | 未覆蓋 | `NUM_ROWS=3/4`、`NUM_COLS=3/4`、`K_BITS=8` |
| reset during active run | 未覆蓋 | start 後中途 reset |
| start_i held high 多 cycle | 未覆蓋 | start 拉高 2 到 3 cycles |
| write while run active | 未覆蓋 | 定義是否允許，若不允許需 assert 或 ignore |
| overflow replay | 未實作 | controller 多 cycle replay test |
| compact values | 未實作 | prefix count / compact index test |
| random tests | 未覆蓋 | generate random masks，比對 software golden model |

---

## 10. 未來需要補充的 RTL 功能

### 10.1 完整 TrIP datapath

目前三個 testbench 只到：

```text
mask storage -> MFIU metadata
```

完整 TrIP 至少還需要：

```text
MFIU metadata
  -> A/B distribution network
  -> multiplier lanes
  -> reduction tree
  -> row-local buffer
```

你目前已經新增 MVP 方向的：

```text
trip_distribution_network.v
pe_lane.v
trip_reduction_tree.v
row_local_buffer.v
trip_compute_top.v
tb_trip_compute_top.v
```

但這仍是 proof-of-concept，和論文完整硬體仍有差距。

### 10.2 論文版 MFIU

目前 `mfiu.v` 是 combinational scanner：

```text
for r
  for c
    for k
```

未來若要更接近論文，需要拆成：

```text
pairwise_and_array
prefix_sum_tree
effectual_compute_index_generator
shift_unit
route_metadata_generator
```

應補的輸出不只 row/col/k，還包括：

```text
A value route index
B value route index
output coordinate / reduction tag
valid per lane
overflow / replay metadata
```

### 10.3 Compact sparse value layout

目前是 fixed-slot：

```text
mask = 1010
values = [slot0, slot1, slot2, slot3]
```

未來可改成 compact：

```text
mask = 1010
compact_values = [value_at_k1, value_at_k3]
```

這會省 memory，但需要：

```text
prefix count
k -> compact index
zero-count / shift logic
```

也就是論文 Fig. 12 類似的 shift unit。

### 10.4 Dynamic B-column packing

論文 TrIP 會根據每個 PE row 的 effectual MAC 數量，決定一次 stream 幾個 B columns。

目前設計：

```text
matches > LANES -> overflow_o = 1
```

但還沒有處理 overflow。

未來 controller 應該做：

```text
1. 預估或計算 A/B bitmask pair 的 popcount
2. 選擇一次放入幾個 B columns
3. 保證 effectual MAC 不超過 lanes
4. 若仍 overflow，拆成多 cycle replay
```

### 10.5 真正的 distribution network

目前 MVP 可以用 small crossbar。

論文中比較接近的是 Benes network，優點是：

```text
non-blocking
area 比 full crossbar 更可控
適合大量 lanes
```

未來若 `LANES` 從 4 擴到 16、32、128，small crossbar 會變得不划算，需要換成更結構化的 network。

### 10.6 Merge-reduction tree

目前 MVP reduction 可以用簡單 group-by tag 累加。

論文中的 merge-reduction tree 需要支援：

```text
reduction mode: TrIP / dense IP
merge mode: TrGT / TrGS
```

未來至少要補：

- 多 output coordinate 同時 reduction
- subtree slicing
- invalid lane masking
- output coordinate compare
- merge mode comparator / mux path

### 10.7 Row-local buffer

目前 row-local buffer 可以先存 output results。

未來要接近論文，需要：

```text
banked local buffer
multi-write scatter
multi-read gather
bank conflict handling
output coordinate mapping
```

TrIP 用它存 output partial results。

TrGT / TrGS 未來可能重用它來暫存 B rows。

### 10.8 Dataflow controller

目前 testbench 直接控制：

```text
write fibers
start_i
等待 done_o
```

真正硬體需要 controller：

```text
LOAD_FIBERS
INTERSECT
DISPATCH
MAC
REDUCE
WRITEBACK
NEXT_TILE
DONE
```

controller 還需要處理：

- tile descriptor
- matrix shape
- dense / sparse mode
- overflow replay
- buffer ready / valid
- output writeback address

---

## 11. 未來需要補充的 Testbench

### 11.1 `tb_trip_distribution_network.v`

目的：單獨驗證 A/B value routing。

必測：

- lane0/lane1/lane2/lane3 取不同 row/col/k
- 同一個 A value 被多個 lanes 重用
- 同一個 B value 被多個 lanes 重用
- invalid lane 輸出 zero
- `k_sel` 對 fixed-slot values 的 indexing 正確

### 11.2 `tb_pe_lane.v`

目的：驗證 multiplier lane。

必測：

- valid = 0 時 product = 0 或 output invalid
- valid = 1 時 product 正確
- 最大值乘法
- signed / unsigned 決策
- pipeline latency 若未來加入 register

### 11.3 `tb_trip_reduction_tree.v`

目的：驗證同 output coordinate 的 partial products 能正確合併。

必測：

- 全部 lane tag 不同
- 兩個 lane tag 相同
- 三個以上 lane tag 相同
- invalid lane 混入
- zero product 是否影響 valid
- overflow / accumulator width 是否足夠

### 11.4 `tb_row_local_buffer.v`

目的：驗證 row-local output buffer。

必測：

- 單一 write
- 多 output 同時 write
- invalid output 不寫或清零
- reset 清空
- overwrite
- 未來 bank conflict

### 11.5 `tb_trip_compute_top.v`

目的：end-to-end 驗證：

```text
bitmask_buffer
MFIU
distribution
MAC
reduction
row-local buffer
```

必測：

- no intersection
- one intersection
- multiple outputs
- same output 多個 partial products reduction
- overflow case
- consecutive run
- overwrite buffer 再 run
- random masks + software golden result

### 11.6 Randomized self-checking testbench

未來最有價值的是 random test。

流程：

```text
1. 隨機產生 A masks / B masks
2. 隨機產生 fixed-slot A values / B values
3. 用 testbench function 算 golden result
4. 寫入 DUT
5. run
6. 比對 lane metadata 或 final C output
```

Golden model pseudo-code：

```text
for r in rows:
  for c in cols:
    sum = 0
    for k in K:
      if A_mask[r][k] & B_mask[c][k]:
        sum += A_value[r][k] * B_value[c][k]
```

如果只測 MFIU metadata，golden model 是：

```text
matches = []
for r in rows:
  for c in cols:
    for k in K:
      if A_mask[r][k] & B_mask[c][k]:
        matches.append((r,c,k))
```

然後比對前 `LANES` 個 matches 與 `overflow`。

### 11.7 Parameterized regression

目前只測 2x2, K=4, LANES=4。

未來應至少測：

```text
NUM_ROWS=1, NUM_COLS=1
NUM_ROWS=2, NUM_COLS=2
NUM_ROWS=4, NUM_COLS=4
K_BITS=1
K_BITS=4
K_BITS=8
LANES=1
LANES=4
LANES=8
```

特別要測 edge cases：

- `NUM_ROWS = 1`
- `NUM_COLS = 1`
- `K_BITS = 1`

因為 `$clog2(1)` 容易造成 zero-width signal 問題。你現在 RTL 用：

```verilog
(NUM_ROWS > 1) ? $clog2(NUM_ROWS) : 1
```

這是為了避免 zero-width，但仍應用 testbench 驗證。

---

## 12. 建議的開發順序

如果接下來要把設計推向完整 TrIP，我建議順序是：

```text
1. 保持現有三個 testbench 全過
2. 補 tb_trip_distribution_network
3. 補 tb_trip_reduction_tree
4. 強化 tb_trip_compute_top
5. 加 random self-checking test
6. 擴 parameter regression
7. 實作 overflow replay controller
8. 再把 mfiu_v0 換成 prefix-sum / shift-unit MFIU
9. 最後再考慮 Benes network 與完整 MRN
```

這樣每一步都有可驗證的 checkpoint，不會一次改太多導致 debug 困難。

---

## 13. 總結

三個 testbench 的定位如下：

| Testbench | 驗證對象 | 核心目的 |
|---|---|---|
| `tb_bitmask_buffer.v` | `bitmask_buffer.v` | 確認 sparse fiber metadata/value storage 正確 |
| `tb_mfiu.v` | `mfiu.v` | 確認 A/B bitmask intersection 與 lane metadata packing 正確 |
| `tb_trip_intersection_top.v` | `trip_intersection_top.v` | 確認 buffer read timing、FSM、MFIU 整合正確 |

這三個 testbench 合起來證明：

```text
固定 slot sparse fiber 可以被寫入與讀出
MFIU 可以從 A/B bitmasks 找出 effectual MACs
top-level front-end 可以在正確 timing 下輸出 row/col/k metadata
```

也就是 TrIP MVP 前端已具備可驗證的基礎。
