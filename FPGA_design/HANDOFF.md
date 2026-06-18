# TrIP MFIU / Tile Compute Engine Handoff

這份文件給接手者快速了解目前 RTL 已完成的功能、資料如何在電路中流動，以及 testbench 覆蓋了哪些行為。

## 1. 目前電路能做什麼

這個設計是一個以 Trapezoid / Eyeriss v2 MFIU 概念為核心的 sparse GEMM tile compute engine。

計算目標是：

```text
C[M x N] = A[M x K] * B[K x N]
```

但硬體一次不是吃完整大矩陣，而是吃一個小 tile 的一個 K chunk：

```text
A tile: NUM_ROWS 條 row fiber，每條 fiber 有 K_BITS 個 k positions
B tile: NUM_COLS 條 column fiber，每條 fiber 有 K_BITS 個 k positions
C tile: NUM_ROWS x NUM_COLS 個輸出元素
```

目前主要有兩種配置：

| 模式 | NUM_ROWS | NUM_COLS | K_BITS | LANES | 用途 |
|---|---:|---:|---:|---:|---|
| stable direct / small regression | 2 | 2 | 4 | 16 | 快速驗證、功能基準 |
| paper-aligned packed | 4 | 4 | 32 | 128 | 對齊論文 MFIU 規格：最多 4 rows of A、4 columns of B、128 effectual MAC lanes |

重要觀念：

- `NUM_ROWS` 是一次載入幾條 A row fiber。
- `NUM_COLS` 是一次載入幾條 B column fiber。
- `K_BITS` 是每條 fiber 在這個 K chunk 內的 k positions 數量。
- `LANES` 是這個 cycle/pass 最多能送進乘法器的 effectual MAC 數量。
- effectual MAC 是 `a_mask[row][k] & b_mask[col][k] == 1` 的交集。

目前硬體已經支援 overflow replay：

```text
如果 effectual MACs <= LANES:
    一次 pass 完成

如果 effectual MACs > LANES:
    pass 0 算第 0 ~ LANES-1 個 effectual MAC
    pass 1 算第 LANES ~ 2*LANES-1 個 effectual MAC
    ...
    最後一個 pass 算剩下的 MAC
```

`trip_tile_compute_engine` 會在同一個 K chunk 上自動 replay，並把每一 pass 的 partial C 累加到同一個 C tile。

目前還不是完整 layer-level accelerator：

- 大矩陣的 M/N/K tiling 順序由 TB 或外部 controller 餵資料。
- RTL 沒有自己從 DRAM/SRAM 掃完整 layer。
- RTL 沒有 im2col address generator。
- RTL 沒有完整 DMA / NoC / global buffer scheduler。

所以交接時要說清楚：這份 RTL 是 tile compute datapath，不是完整 SoC accelerator。

## 2. Module 架構

主路徑如下：

```text
bitmask_buffer
    -> trip_intersection_top
        -> mfiu 或 mfiu_pipelined
    -> trip_distribution_network
    -> pe_lane multipliers
    -> trip_reduction_tree
    -> row_local_buffer
    -> trip_tile_compute_engine accumulator
```

### bitmask_buffer.v

儲存一側 fibers：

- A side: 存 `NUM_ROWS` 條 row fiber。
- B side: 存 `NUM_COLS` 條 column fiber。
- 每條 fiber 包含：
  - `id`
  - `mask[K_BITS-1:0]`
  - `values[K_BITS*DATA_WIDTH-1:0]`

### trip_intersection_top.v

負責：

1. 從 A/B buffers 把所有 row/column fibers 讀出來。
2. 把 A masks / B masks 組成 MFIU input。
3. 在 `done_o` 時輸出：
   - 哪些 lanes 有效：`lane_valid_o`
   - 每個 lane 對應的 A row：`a_row_sel_o`
   - 每個 lane 對應的 B column：`b_col_sel_o`
   - 每個 lane 對應的 k：`k_sel_o`
   - 本 pass 實際發出的 MAC 數：`match_count_o`
   - 是否還有 MAC 沒算：`overflow_o`

### mfiu.v

原始 combinational MFIU。

用途：

- 小規模功能驗證。
- direct / early packed baseline。

### mfiu_pipelined.v

目前 packed MFIU 的主力版本。

功能：

1. 找出所有 `(row, col, k)` effectual MAC。
2. 對 effectual MAC 做 rank / packing。
3. 根據 `replay_skip_i` 選出本 pass 要送出的 window。
4. 最多輸出 `LANES` 個 MAC 到 multiplier lanes。

5-stage pipeline：

| Stage | 功能 |
|---|---|
| S1 | capture A/B masks 與 `replay_skip_i` |
| S2a | 每個 `(B col, A row)` 做 AND-popcount |
| S2b | 計算 column prefix、`active_b_cols_o`、完整 event bitmap |
| S3 | group-local prefix rank |
| S4 | group base + gather，輸出 LANES-wide replay window |

Replay 重點：

- `EVENT_CNT_W = clog2(NUM_ROWS*NUM_COLS*K_BITS + 1)`。
- global rank 必須用 `EVENT_CNT_W`，不能只用 `CNT_W=clog2(LANES+1)`。
- `replay_skip_i = replay_pass * LANES`。
- `overflow_o = (total_event_count > replay_skip_i + LANES)`。

### trip_distribution_network.v

根據 MFIU 的 `(row, col, k)` metadata，從 captured A/B values 中取出真正要乘的資料。

Packed mode 下：

```text
A value slot = a_row_sel * K_BITS + k_sel
B value slot = b_col_sel * K_BITS + k_sel
```

### pe_lane.v

每個 lane 一個 multiplier。

目前 unsigned multiplier 有 pipeline latency，`trip_compute_top` 已經把 row/col selector 延遲對齊到 product valid，避免 replay 連續 pass 時 selector/product 錯位。

### trip_reduction_tree.v

把 lanes 的 products 根據 `(A row, B col)` 分組累加，產生 `NUM_ROWS*NUM_COLS` 個 partial C。

Packed mode 下不是靠固定 lane 位置，而是看 MFIU metadata：

```text
if lane belongs to output C[row][col]:
    sum += product[lane]
```

### row_local_buffer.v

存一個 K chunk / replay pass 結束後的 partial C tile。

### trip_tile_compute_engine.v

最上層 tile engine。

負責：

1. 接收外部寫入的 A/B fibers。
2. 啟動 `trip_compute_top` 跑一個 K chunk。
3. 把 partial C 累加到 tile accumulator。
4. 如果 `overflow_o=1`，進入 `S_REPLAY`，同一個 K chunk 再跑一次。
5. replay 全部完成後，輸出 final C tile。

FSM：

```text
S_IDLE
  start_i -> S_RUN

S_RUN
  inner_done -> S_ACCUM

S_ACCUM
  overflow_o=1 -> S_REPLAY
  overflow_o=0 -> S_IDLE, done_o=1

S_REPLAY
  issue inner_start again -> S_RUN
```

## 3. 實際數字例子：2x2, K=4, LANES=16

這是 `tb_trip_compute_top.v` 和 `tb_trip_tile_regression.v` 使用的基本例子。

### Input fibers

A 有 2 條 row fiber：

```text
A0 mask = 4'b1010
A0 values by k:
  k0=0, k1=2, k2=0, k3=3

A1 mask = 4'b0110
A1 values by k:
  k0=0, k1=17, k2=19, k3=0
```

B 有 2 條 column fiber：

```text
B0 mask = 4'b1001
B0 values by k:
  k0=7, k1=0, k2=0, k3=5

B1 mask = 4'b1010
B1 values by k:
  k0=0, k1=11, k2=0, k3=13
```

### MFIU intersection

MFIU 對每個 `(row, col)` 做 mask AND：

```text
C00 uses A0 & B0:
  1010 & 1001 = 1000 -> k3
  MAC: A0[k3] * B0[k3] = 3 * 5 = 15

C01 uses A0 & B1:
  1010 & 1010 = 1010 -> k1, k3
  MACs:
    A0[k1] * B1[k1] = 2 * 11 = 22
    A0[k3] * B1[k3] = 3 * 13 = 39
  C01 partial = 22 + 39 = 61

C10 uses A1 & B0:
  0110 & 1001 = 0000 -> no MAC
  C10 partial = 0

C11 uses A1 & B1:
  0110 & 1010 = 0010 -> k1
  MAC: A1[k1] * B1[k1] = 17 * 11 = 187
```

Packed lane mapping：

```text
lane0 -> (row0, col0, k3)
lane1 -> (row0, col1, k1)
lane2 -> (row0, col1, k3)
lane3 -> (row1, col1, k1)
```

所以 MFIU 輸出：

```text
match_count_o = 4
lane_valid_o  = 0000_0000_0000_1111
overflow_o    = 0
```

### Distribution + multiplier

`trip_distribution_network` 根據 lane metadata 取 values：

```text
lane0: A0[k3]=3,  B0[k3]=5   -> product 15
lane1: A0[k1]=2,  B1[k1]=11  -> product 22
lane2: A0[k3]=3,  B1[k3]=13  -> product 39
lane3: A1[k1]=17, B1[k1]=11  -> product 187
```

### Reduction

`trip_reduction_tree` 依照 `(row, col)` 把 products 加回 C tile：

```text
C00 = lane0        = 15
C01 = lane1+lane2  = 22 + 39 = 61
C10 = no valid MAC = 0
C11 = lane3        = 187
```

最後輸出：

```text
C tile = [[15, 61],
          [ 0,187]]
```

## 4. K-chunk 累加例子

完整 K 可能比 `K_BITS` 大，所以外部 scheduler/TB 會把 K 切成多個 chunks。

`trip_tile_compute_engine` 支援在同一個 C tile 上累加多個 K chunks。

例子：A 是 2x8，B 是 8x2，切成兩個 K=4 chunks。

Chunk 0：

```text
partial C = [[15, 61],
             [ 0,187]]
```

Chunk 1：

```text
partial C = [[14,  0],
             [ 0, 83]]
```

`clear_accum_i=1` 用在第一個 chunk，後續 chunk 用 `clear_accum_i=0`。

最後：

```text
final C = [[15+14, 61+0],
           [ 0+ 0,187+83]]

final C = [[29, 61],
           [ 0,270]]
```

這對應 `tb_trip_tile_compute_engine` 的 TC1/TC2。

## 5. Replay 數字例子：overflow 後補算剩餘 MAC

Replay regression 使用：

```text
NUM_ROWS = 2
NUM_COLS = 2
K_BITS   = 4
LANES    = 6
```

全部 masks 都是 1：

```text
A0 mask = 1111
A1 mask = 1111
B0 mask = 1111
B1 mask = 1111
```

總 candidate/event 數：

```text
TOTAL_CANDIDATES = NUM_ROWS * NUM_COLS * K_BITS
                 = 2 * 2 * 4
                 = 16
```

因為所有交集都有效：

```text
effectual MACs = 16
LANES = 6
```

所以需要 3 pass：

| pass | replay_skip | 發出的 event rank | match_count_o | overflow_o |
|---:|---:|---|---:|---|
| 0 | 0  | 0..5   | 6 | 1 |
| 1 | 6  | 6..11  | 6 | 1 |
| 2 | 12 | 12..15 | 4 | 0 |

`trip_tile_compute_engine` 的行為：

```text
pass 0:
  replay_pass = 0
  replay_skip = 0
  overflow_o = 1 -> S_REPLAY

pass 1:
  replay_pass = 1
  replay_skip = 6
  overflow_o = 1 -> S_REPLAY

pass 2:
  replay_pass = 2
  replay_skip = 12
  overflow_o = 0 -> done_o = 1
```

TB 中所有 values 都是 1，所以每個 C element 都應該累到 4：

```text
C00 = 4
C01 = 4
C10 = 4
C11 = 4
```

這對應 `tb_trip_replay.v`。

## 6. 4x4x32 論文對齊模式

目前 packed 版本可用以下參數對齊論文 MFIU 規格：

```text
NUM_ROWS = 4
NUM_COLS = 4
K_BITS   = 32
LANES    = 128
PACKED_MFIU = 1
```

代表：

```text
A side 一次最多 4 條 row fiber
B side 一次最多 4 條 column fiber
每條 fiber 一個 K chunk 內有 32 個 k positions
最多同時發出 128 個 effectual MAC 到 multiplier lanes
```

總 candidate 數：

```text
TOTAL_CANDIDATES = 4 * 4 * 32 = 512
```

但每 pass 最多只發：

```text
LANES = 128
```

所以 dense worst case 會需要：

```text
512 / 128 = 4 passes
```

如果稀疏度高，例如每條 fiber 只有 4 個 nonzero k positions，常見 event 數會小於 128，不需要 replay。

`tb_trip_tile_4x4x32_vgg` 測的是：

```text
A = 8 x 96
B = 96 x 8
C = 8 x 8
K_BITS = 32
K chunks = 96 / 32 = 3
NUM_ROWS x NUM_COLS = 4 x 4
每個 fiber 每 chunk 只有 4 個 nonzero
每 chunk events 約 64 < LANES 128
```

所以該 TB 驗證的是 4x4x32 packed tile engine 的正常無 overflow 路徑，不是 dense worst-case replay。

## 7. Testbench 覆蓋範圍

| Testbench | Top module | 主要驗證內容 |
|---|---|---|
| `tb_bitmask_buffer.v` | `tb_bitmask_buffer` | buffer write/read、mask/value/id 儲存、overwrite、reset |
| `tb_mfiu.v` | `tb_mfiu` | combinational MFIU packing、match count、active columns、2x2 與 4x4x32 基本 cases |
| `tb_trip_intersection_top.v` | `tb_trip_intersection_top` | buffer + intersection top，驗證 start/done、lane metadata、no-intersection、overwrite、consecutive run |
| `tb_trip_intersection_top.v` | `tb_trip_overflow` | `LANES=6` overflow case、`active_b_cols_o`、overflow 時 first replay window 的 lane mapping |
| `tb_trip_compute_top.v` | `tb_trip_compute_top` | intersection + distribution + multiplier + reduction + row buffer 的 end-to-end partial C |
| `tb_trip_replay.v` | `tb_trip_replay` | overflow replay：16 effective MACs 用 6 lanes 分 3 pass，最後 C tile 完整累加 |
| `tb_trip_tile_regression.v` | `tb_trip_tile_compute_engine` | K chunk accumulation、clear accumulator、no-intersection clear |
| `tb_trip_tile_regression.v` | `tb_trip_signed_compute` | signed multiplication path |
| `tb_trip_tile_regression.v` | `tb_trip_param_shapes` | 其他參數形狀，例如 1x1/K4、4x4/K8 |
| `tb_trip_tile_regression.v` | main regression section | randomized no-overflow K-chunk accumulation、start held high、active reset、compute during writes、manual split |
| `tb_trip_tile_random.v` | `tb_trip_tile_random` | 隨機 sparse matrix tiling，自動 golden C=A*B 比對 |
| `tb_trip_int_4x4x32.v` | `tb_trip_int_4x4x32` | 4x4/K32/LANES128 packed intersection：zero、single event、128 events、64 events、consecutive run |
| `tb_trip_vgg_workload.v` | `tb_trip_vgg_conv1_1_sampled` | VGG16 conv1_1 shape 的 sampled full-shape GEMM，真實 layer 尺寸但抽樣 tiles |
| `tb_trip_vgg_workload.v` | `tb_trip_vgg_layer_gemm` | 8x8 output / 8 channels 的 VGG-like GEMM |
| `tb_trip_vgg_workload.v` | `tb_trip_tile_4x4x32_vgg` | 4x4x32 packed tile engine，A(8x96)*B(96x8)，3 K chunks，4 tiles，golden 比對 |

近期已跑過並通過的重點：

```text
tb_trip_replay:          10 passed, 0 failed
tb_trip_overflow:        25 passed, 0 failed
tb_trip_compute_top:     17 passed, 0 failed
tb_trip_int_4x4x32:      41 passed, 0 failed
tb_trip_tile_4x4x32_vgg: 72 passed, 0 failed
Verilator tb_trip_replay binary simulation: PASS
Verilator lint: PASS
Yosys proc/opt/stat sanity: PASS
```

## 8. 常用模擬指令

先設定 tool path：

```bash
export PATH=$PWD/.eda-tools/bin:$PATH
mkdir -p build/sim
```

共用 source list：

```bash
SRC="FPGA_design/src/bitmask_buffer.v \
FPGA_design/src/mfiu.v \
FPGA_design/src/mfiu_pipelined.v \
FPGA_design/src/pe_lane.v \
FPGA_design/src/row_local_buffer.v \
FPGA_design/src/trip_distribution_network.v \
FPGA_design/src/trip_reduction_tree.v \
FPGA_design/src/trip_intersection_top.v \
FPGA_design/src/trip_compute_top.v \
FPGA_design/src/trip_tile_compute_engine.v"
```

Replay regression：

```bash
iverilog -g2012 -Wall -s tb_trip_replay \
  -o build/sim/tb_trip_replay.vvp \
  $SRC FPGA_design/tb/tb_trip_replay.v
vvp build/sim/tb_trip_replay.vvp
```

4x4x32 intersection：

```bash
iverilog -g2012 -Wall -s tb_trip_int_4x4x32 \
  -o build/sim/tb_trip_int_4x4x32.vvp \
  FPGA_design/src/bitmask_buffer.v \
  FPGA_design/src/mfiu.v \
  FPGA_design/src/mfiu_pipelined.v \
  FPGA_design/src/trip_intersection_top.v \
  FPGA_design/tb/tb_trip_int_4x4x32.v
vvp build/sim/tb_trip_int_4x4x32.vvp
```

4x4x32 tile workload：

```bash
iverilog -g2012 -Wall -s tb_trip_tile_4x4x32_vgg \
  -o build/sim/tb_trip_tile_4x4x32_vgg.vvp \
  $SRC FPGA_design/tb/tb_trip_vgg_workload.v
vvp build/sim/tb_trip_tile_4x4x32_vgg.vvp
```

Verilator replay simulation：

```bash
verilator --binary --timing \
  -Wno-TIMESCALEMOD -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
  -Wno-WIDTH -Wno-PINCONNECTEMPTY -Wno-SYNCASYNCNET -Wno-BLKSEQ \
  --top-module tb_trip_replay \
  $SRC FPGA_design/tb/tb_trip_replay.v \
  -Mdir build/verilator_tb_trip_replay

build/verilator_tb_trip_replay/Vtb_trip_replay
```

Yosys sanity：

```bash
yosys -q -p "read_verilog -sv $SRC; \
hierarchy -top trip_tile_compute_engine; \
chparam -set NUM_ROWS 2 -set NUM_COLS 2 -set K_BITS 4 \
        -set LANES 6 -set PACKED_MFIU 1 trip_tile_compute_engine; \
proc; opt; stat"
```

## 9. 交接注意事項

1. `PACKED_MFIU=1` 是論文對齊方向，4x4x32 應使用此模式。
2. `active_b_cols_o` 目前是 policy visibility/debug 訊號；replay 實作不會丟掉後面的 B columns，而是用 full event stream + `replay_skip_i` 分 pass 發出。
3. 4x4x32 dense worst case 會有 512 candidates，面積與 timing 壓力都很大。
4. 目前已把 MFIU 從 scatter 改成 gather，避免 stage 4 形成很深的 mux chain，但 4x4x32 完整 ABC timing closure 仍是後續工作。
5. 完整 layer 的 tile ordering、K chunk scheduling、資料搬移目前仍在 TB/外部控制，不在 RTL 裡。
6. 若要變成完整 accelerator，下一步要補的是 layer-level scheduler、global buffer address generator、DMA/NoC interface，以及更完整的 4x4x32 timing closure。
