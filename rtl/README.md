# PE ARRAY RTL Note

## 資料流(MC egress → C 輸出)
紀錄上游 memory controller 如何送整批的資料給 16 條 pe row 算
1. **pe_entry** — 收 MC 封包(1 cycle cfg header + 數cycle NZ data)，組回一條壓縮 fiber，依 header 標記 A/B。
2. **pe_ab_buffer**(16 row 共用) — 存一個 tile 的 16 條 A fiber + 16 欄 B fiber，收滿發出 `tile_ready` 訊號。
3. 16 條 **pe_row** 一起開跑(`start = tile_ready`)，row r 吃自己那條 A(`a_nz[r]`)，16 欄 B 共享。
   分配由位置決定(無排程器): MC 送 A 的順序 = 「A 第幾列 → 第幾條 row」。
4. 每條 row:**pe_mfiu_seq**(批次把 A + B 餵進 `mfiu` 做交集)→ **crossbar**(metadata 將位置資訊轉成實際 A/B 值) → **pe_row_tail**(mac×16 → reduction tree → local buffer 跨 K 累加)。
5. K 全累加完後 controller 廣播 **dump**，逐欄讀出:`c_out[0..15]` = 該欄跨 16 個輸出列的 psum。

握手:`pe_compute_done` = 16 row 的 `done` 全到齊、再延遲 drain margin(等 buffer 累加落定),
controller 等到它才換下一批 tile，避免覆寫 `pe_ab_buffer`。

---

## 目錄結構

```
rtl/
├── trapezoid_pkg.sv              pe 模組共用參數 (package), controller 有的會沿用 ASIC.svh
├── pe_engine.f                   合成用/filelist
├── pe/
│   ├── pe_array.sv               top:entry + 共享 buffer + 16 row + 握手機制
│   ├── pe_row.sv                 單條 row: mfiu_seq → crossbar → tail
│   ├── pe_entry.sv               MC 封包進入點，負責封包處理
│   ├── pe_ab_buffer.sv           A/B buffer(16 A + 16 B / tile)
│   ├── pe_mfiu_seq.sv            per-row MFIU sequencer(批次餵給 mfiu bitmask 資訊)（內含 mfiu.sv）
│   ├── pe_row_tail.sv            mac×16 + reduction + local buffer(把三個 module 包起來)
│   ├── mac_unit.sv               uint8 × int8 乘法器
│   ├── local_buffer_row.sv       per-row psum buffer(4 bank)
│   └── sram_128x32_1r1w.sv       128×32 SRAM (1R1W) wrapper
├── dist/
│   ├── crossbar.sv               meta → A/B 值 gather
│   └── reduction_tree_radix16.sv radix-16 分段加總樹
└── mfiu/
    └── mfiu.sv                   multi-fiber bitmask
```

---

## 階層關係

```
trapezoid_pkg.sv                       import 的共用參數

pe_array.sv                            top
├─ pe_entry.sv                         MC 封包 → 壓縮 fiber
├─ pe_ab_buffer.sv                     共享: 16 A + 16 B / tile → tile_ready
└─ pe_row.sv              × 16         一條輸出列 m
   ├─ pe_mfiu_seq.sv                   批次序列器
   │  └─ mfiu.sv                       bitmask 交集 + prefix-sum → meta
   ├─ crossbar.sv                      meta → 真實 A/B 值(純組合)
   └─ pe_row_tail.sv                   row 尾段
      ├─ mac_unit.sv     × 16          uint8 × int8
      ├─ reduction_tree_radix16.sv     分段加總
      └─ local_buffer_row.sv           輸出累加(4 bank)
         └─ sram_128x32_1r1w.sv × 4    合成用的資訊（實際 ADFP macro 腳位）
```

---

## 共用參數 `trapezoid_pkg.sv`

| 類別 | 參數 | 值 | 說明 |
|------|------|----|------|
| 陣列 | `N_PE_ROW` / `N_MUL_ROW` | 16 / 16 | 16 row × 16 lane = 256 MAC |
| 寬度 | `DATA_W` / `PROD_W` / `ACC_W` | 8 / 16 / 32 | A=uint8、B=int8，乘積 INT16，累加 INT32 |
| B-fiber | `N_B_FIBER` | 4 | 每批動態打包 1..4 欄 B |
| | `LANE_COUNT_W` | 5 | 有效 lane 數(0..16)的寬度 |
| Pipeline | `MUL_STAGES` / `TREE_STAGES` | 1 / 1 | mac / tree latency(tail 對齊控制訊號用) |
| Local buf | `N_BANK_LBUF` / `LOCAL_BUF_DEPTH` / `LOCAL_BUF_AW` | 4 / 512 / 9 | 每 row psum buffer |

> dataflow MODE(Dense/TrIP)編碼**不在**此檔：它在 controller 的 `ASIC.svh`，PE array 只收
> 整合邊界算好的 1-bit `mode`(1 = TrIP)。Packet / AXI / GLB 參數也都在 `rtl/pe` 之外。

---

## 模組說明
### pe/pe_array.sv — top(PE engine)

本模組為 PE 子系統之頂層架構，資料流為：`pe_entry` → `pe_ab_buffer`(共享)→ 16 條 `pe_row`。採用 Tile-based 執行模型，當單一 Tile 資料運算完成後，會同步觸發 16 條 row 進行平行運算。彙整各 row 的完成狀態（`done`），加上管線排空時間 (Drain margin) 後，統整出 pe_compute_done 與 pe_tile_done 兩個訊號以通知 Controller。在 Dump 階段，模組會向 16 條 row 廣播位址，以行為單位輸出跨 16 列之 Partial sum（c_out)。

| 訊號 | 方向 | 寬度 | 說明 |
|------|------|------|------|
| `clk` / `rst_n` | in | 1 | 時脈 / 非同步 reset (active-low) |
| `pe_cfg_valid` / `pe_cfg_ready` | in / out | 1 | MC cfg header 握手 |
| `pe_cfg_length` | in | 16 | `[15]`=is_b、`[4:0]`=len(0..16)長度有多給一些，其實用不到那麼多 |
| `pe_cfg_bitmask` | in | 16 | fiber 的 bitmask |
| `pe_data_valid` / `pe_data_ready` | in / out | 1 | MC data 握手 |
| `pe_data_nzvalue` | in | 32 | 每拍 4 個 NZ(LSB-first) |
| `mode` | in | 1 | 1 = TrIP, 0 = STD IP |
| `first_pass` | in | 1 | 該欄第一個 K-tile(overwrite) |
| `cur_n_base` | in | 9 | 本 N-tile base col(= n_cnt×16) |
| `dump_en` / `dump_addr` | in | 1 / 9 | 逐欄讀出 C |
| `pe_compute_done` | out | 1 | 16 row 算完(controller 等這個訊號換 tile) |
| `pe_tile_done` | out | 1 | 每 tile 算完跳 1 拍 |
| `c_out` / `c_valid` | out | [16][32] / 1 | dump 時一欄跨 16 列的 psum(signed) |
| `dbg_ent_*` | out | — | sim 觀察用: 輸出內部 pe_entry 組好的 fiber |

### pe/pe_row.sv — 一條 PE row

把 `pe_mfiu_seq` → `crossbar` → `pe_row_tail` 串成一條 row 的計算鏈(輸出列 m)。
A 取自己那條(`a_*_row`)，B 16 欄共享。
`done` = 此 row 的 mfiu_seq 把所有 B-group 跑完。

| 訊號 | 方向 | 寬度 | 說明 |
|------|------|------|------|
| `clk` / `rst_n` | in | 1 | 時脈 / reset |
| `mode` / `start` | in | 1 | 1=TrIP / 開始處理本 tile(1 拍) |
| `done` | out | 1 | 本 row 跑完所有 B-group |
| `a_bm_row` / `a_nz_row` | in | 16 / [16][8] | 本 row 的 A bitmask / 壓縮 NZ |
| `b_bm` / `b_nz` | in | [16]×16 / [16][16][8] | 共享的 16 欄 B bitmask / NZ |
| `first_pass` / `cur_n_base` | in | 1 / 9 | 覆寫旗標 / 基底欄 |
| `dump_en` / `dump_addr` | in | 1 / 9 | 讀出 C |
| `c_valid` / `c_out` | out | 1 / 32 | dump 輸出(signed INT32) |

### pe/pe_entry.sv — MC 封包入口端

本模組負責接收並處理來自 MC 的 pe_cfg 與 pe_data 資料流（透過 ready 訊號進行流量控制，避免壅塞），將壓縮後的 fiber 進行重組，重組過程中，將依據 Header 之 A/B tag 來標記 side 屬性，每完成一筆 fiber 的重組，便將 out_valid 訊號拉高一個週期，其中，out_idx 輸出對應於該階段內之處理序號（範圍為 0 至 15）。

| 訊號 | 方向 | 寬度 | 說明 |
|------|------|------|------|
| `clk` / `rst_n` | in | 1 | 時脈 / reset |
| `pe_cfg_valid` / `pe_cfg_ready` | in / out | 1 | cfg 握手 |
| `pe_cfg_length` / `pe_cfg_bitmask` | in | 16 / 16 | `[15]`=is_b、`[4:0]`=len / bitmask |
| `pe_data_valid` / `pe_data_ready` | in / out | 1 | data 握手 |
| `pe_data_nzvalue` | in | 32 | 4 個 NZ,LSB-first |
| `out_bitmask` / `out_nz` / `out_len` | out | 16 / [16][8] / 5 | 組好的壓縮 fiber |
| `out_side` / `out_idx` / `out_valid` | out | 1 / 4 / 1 | A=0 B=1 / phase 內序號 / 1 拍 strobe |

### pe/pe_ab_buffer.sv — 共享 A/B fiber buffer

接收 `pe_entry` 每 cycle 輸出的 fiber，並依 side 寫進 A 或 B buffer 的對應 idx 位置。
一個 tile 包含 16 列 A 與 16 欄 B，每個 entry 儲存了 bitmask（傳給 mfiu）、壓縮的 nz（傳給 crossbar）以及 len（nz 資料長度）。
當 B 段的最後一筆資料 (idx=15) 寫入完成（Buffer 填滿）時，系統將發出一個週期的 tile_ready 訊號。

| 訊號 | 方向 | 寬度 | 說明 |
|------|------|------|------|
| `clk` / `rst_n` | in | 1 | 時脈 / reset |
| `in_bitmask` / `in_nz` / `in_len` | in | 16 / [16][8] / 5 | 來自 pe_entry 的 fiber |
| `in_side` / `in_idx` / `in_valid` | in | 1 / 4 / 1 | A/B / 格號 / 寫入有效 |
| `tile_ready` | out | 1 | 16 A + 16 B 收齊(1 Clock cycle) |
| `a_bm` / `a_nz` / `a_len` | out | [16]×16 / [16][16][8] / [16]×5 | A buffer(by-fiber 讀) |
| `b_bm` / `b_nz` / `b_len` | out | [16]×16 / [16][16][8] / [16]×5 | B buffer(by-col 讀) |

### pe/pe_mfiu_seq.sv — per-row MFIU sequencer

本模組負責執行單一 A 列與 16 欄 B 行之 bitmask 交集運算，硬體採用分批處理機制，將「A 列之 bitmask」與「至多 4 欄之 B bitmask」合併為單一批次，輸入至 mfiu 運算單元。
模組會依據 mfiu 回傳之 b_utilization 狀態來更新行指標 (col_ptr)，當處理至包含最後一欄 B 的批次時，模組將觸發 a_last 訊號，指示 mfiu 結束該列之處理狀態。

此外，當系統處於稠密運算模式 (mode=0, StandardIP) 時，將觸發 Bypass 機制略過 mfiu 。在 mode=1下，每個批次將於單一週期內輸出 metadata 至 Crossbar，其中包含該批次之起始欄位索引 (grp_base)。

> 如果 mfiu 直接跟 crossbar 說這批的第 0 欄跟第 2 欄有交集，但 crossbar 不知道是 16col 中的哪些欄！例：grp_base = 8，那這批的 4 欄就代表實際上的第 8, 9, 10, 11 欄。grp_ncol 表示這批有幾欄有效值

| 訊號 | 方向 | 寬度 | 說明 |
|------|------|------|------|
| `clk` / `rst_n` | in | 1 | 時脈 / reset |
| `mode` / `start` / `done` | in / in / out | 1 | 1=TrIP / 開跑 / 跑完所有 B 欄 |
| `a_bm_row` / `b_bm` | in | 16 / [16]×16 | A bitmask / 16 欄 B bitmask |
| `out_valid` | out | 1 | 本批 meta 有效 |
| `out_effectual` | out | 5 | 本批有效交集數(0..16) |
| `out_a_meta` / `out_b_meta` | out | [16][4] / [16][6] | 各 lane 的 A index / {B 欄號, B index} |
| `out_grp_base` / `out_grp_ncol` | out | 4 / 3 | 本批起始真實欄 / 實際欄數(1..4) |

### mfiu/mfiu.sv — multi-fiber bitmask 交集核心

MFIU 的 FSM(IDLE→LOAD_A→WAIT_B→CAL→OUT):
鎖存 (Latch) 本 row A bitmask，與最多 4 欄 B bitmask，逐欄做 A&B 交集 + prefix-sum，輸出壓縮 meta
- `a_meta` = 壓縮 A index
- `b_meta` = {B 欄號, B 壓縮 index}
動態打包: 只要總有效交集數小於或等於 16 (後端乘法器數限制)，就會將最大數量的連續 B 欄位打包成同一批次輸出，並透過 b_utilization 回報實際消耗的 B 欄數量。
`mode=0` 時略過 mfiu，mfiu 會包在 `pe_mfiu_seq` 中。

| 訊號 | 方向 | 寬度 | 說明 |
|------|------|------|------|
| `clk` / `rst_n` / `en` / `mode` | in | 1 | 時脈 / reset / enable / 1=TrIP |
| `a_in_valid` / `b_in_valid` | in | 1 | A / B 輸入有效(對應 FSM 階段) |
| `a_last` / `b_group_last` | in | 1 | A 結束 / B group 結束(FSM 收尾) |
| `a_bitmask` / `b_bitmask` | in | 16 / [4]×16 | A bitmask / 本批最多 4 欄 B bitmask |
| `b_col_valid` | in | 2 | 本批有效欄數編碼(0..3 → 1..4) |
| `effectual_count` | out | 5 | 本批有效交集數(0..16) |
| `a_meta_data` / `b_meta_data` | out | [16][4] / [16][6] | 壓縮 A index / {B 欄號[5:4], B index[3:0]} |
| `b_utilization` / `meta_valid` | out | 2 / 1 | 實際打包欄數編碼 / meta 有效 |


### pe/pe_row_tail.sv — row 尾段(mac + reduction + accumulate)

本模組負責接收來自 Crossbar 的資訊，並完成乘積累加等尾段處理：

- S6 (MAC)： 執行 16 組之平行乘法運算。
- S7 (Reduction Tree)： 依據 cut_after 邊界訊號，將屬於相同輸出欄位之連續組數據，加總為 Partial sum。
- S8a： 將最多 16 組之結果壓縮至最多 4 筆有效輸出（因 local buffer 只有 4-bank），並計算其對應之本地緩衝區位址（位址 = cur_n_base + 輸出欄號）。
- S8b (Local Buffer)： 執行 K 維度 (K-dimension) 之資料累加，或將最終完成之矩陣結果 (C 矩陣) 卸載 (Offload) 輸出。

為確保控制訊號與運算數據同步，模組內部配置延遲線，將 cut_after (延遲 1 週期)、輸出欄位、first_pass 與 cur_n_base (延遲 2 週期) 等控制訊號，與資料路徑進行 pipeline 對齊。

| 訊號 | 方向 | 寬度 | 說明 |
|------|------|------|------|
| `clk` / `rst_n` | in | 1 | 時脈 / reset |
| `in_valid` | in | 1 | crossbar 本拍有一個 group |
| `a_val` / `b_val` | in | [16][8] / [16][8] | per-lane A(uint8)/ B(int8) |
| `lane_col` / `lane_valid` | in | [16][4] / [16] | 各 lane 的輸出欄 / 有效 |
| `first_pass` / `cur_n_base` | in | 1 / 9 | 覆寫旗標 / 起始欄 |
| `dump_en` / `dump_addr` | in | 1 / 9 | 讀出 C(不可與 acc 同拍) |
| `c_valid` / `c_out` | out | 1 / 32 | dump 輸出(signed INT32) |

### pe/mac_unit.sv — 乘法器

`product = uint8(a) × int8(b)`，registered 成 signed INT16(只乘、不累加)。
A 是 unsigned uint8 [0,255]、B 是 signed int8，對齊 GEMM 量化測資，乘積範圍 [-32640, +32385] 落在 INT16。

| 訊號 | 方向 | 寬度 | 說明 |
|------|------|------|------|
| `clk` / `rst_n` / `en` | in | 1 | 時脈 / reset / output reg enable |
| `a` | in | unsigned 8 | uint8 activation(0..255) |
| `b` | in | signed 8 | int8 weight(二補數) |
| `product` | out | signed 16 | a × b(registered,latency 1) |

### pe/local_buffer_row.sv — per-row psum buffer

本模組負責儲存單一列中所有輸出欄位之 C 矩陣 Partial sum，其硬體配置為 4 個獨立的 SRAM 記憶體庫 (Bank)，總容量可儲存最糟情況下的 512 欄位 (512 cols × 32-bit)。每週期最高有 4 筆平行寫入，並透過位址的低位元 (addr[1:0]) 將寫入請求分派至對應之 Bank，其寫入行為由 first_pass 訊號控制：若為 1，則執行初始覆寫；若為 0，則執行讀取-修改-寫入 (Read-Modify-Write, RMW) 之累加操作，為解決連續對同部位址進行 RMW 操作時，因 SRAM 讀取延遲所引發之 Data Hazard，本模組實作了 Write-forward bypass，確保累加數值之正確性。
此處的 Data Hazard 為 Read-After-Write（RAW Hazard），讀取上一個 cycle 才剛寫入的值可能會讀到舊值，因爲 SRAM 會讀到舊值，那 bypass 機制就是當連續兩筆要寫同一個位址時，直接把上一拍算好的結果拉一條捷徑（Bypass）傳給下一拍，根本不去等 SRAM。

在結果 dump 階段，本模組採用讀後清除 (Read-and-Clear) 機制，於讀取有效數值後之次一週期，硬體將自動對該位址寫入零值，供下一矩陣分塊 (Tile) 運算使用，實作時曾經沒清除，導致輸出仍是舊值。

(架構假設：單一週期內之多筆寫入請求不得發生記憶體庫衝突 (Bank conflict)；此外，因共用讀取 port，結果卸載 (dump_en) 與累加操作 (acc_en) 必須於不同週期執行。)

| 訊號 | 方向 | 寬度 | 說明 |
|------|------|------|------|
| `clk` / `rst_n` / `en` | in | 1 | 時脈 / reset / pipeline enable |
| `wr_valid` / `wr_sum` / `wr_addr` | in | [4] / [4][32] / [4][9] | 最多 4 筆寫入(有效 / 部分和 / 欄址) |
| `first_pass` / `acc_en` | in | 1 / 1 | 覆寫 vs 累加 / 本拍寫入有效 |
| `dump_en` / `dump_addr` | in | 1 / 9 | 讀出請求 / 欄址 |
| `c_valid` / `c_out` | out | 1 / 32 | dump 結果(`dump_en` 後第 2 拍,signed) |

> 實作上要注意避免記憶體衝突: 同拍有效寫入須落在互異 bank
> 避免 Structural Hazard: `dump_en` 不可與 `acc_en` 同拍(共用 read port)。

### pe/sram_128x32_1r1w.sv — SRAM wrapper
128 words × 32-bit 1R1W SRAM，讀寫獨立，讀延遲 1 拍。
- 當定義 USE_SRAM_MACRO 時：系統將實例化 (Instantiate) 真實的 ADFP 記憶體巨集 (Memory Macro)，供實體設計階段使用。
- 未定義時：系統將合成行為級之暫存器陣列 (Behavioral register array)，以支援 RTL 模擬與早期邏輯合成 (Early logic synthesis) 驗證。
兩種介面時序一致，作為 `local_buffer_row` 的 bank(每 row 4 顆)。

| 訊號 | 方向 | 寬度 | 說明 |
|------|------|------|------|
| `clk` | in | 1 | 讀寫共用時脈 |
| `ren` / `raddr` / `rdata` | in / in / out | 1 / 7 / 32 | 讀致能 / 讀址 / 讀資料(次拍有效) |
| `wen` / `waddr` / `wdata` | in | 1 / 7 / 32 | 寫致能 / 寫址 / 寫資料 |

### dist/crossbar.sv — meta → 實際 A/B 值
> 撈出真正的 A/B 值，因為 mfiu 不會傳 value

程式碼:
- `a_val[l] = a_nz_row[a_meta[l]]`
- 實際 col index `= grp_base + b_meta[l][5:4]`,`b_val[l] = b_nz[欄][b_meta[l][3:0]]`。
無效 lane(`l ≥ effectual`)輸出 0、`lane_valid=0`。

本模組為純組合邏輯設計（不用給 Clock 與 Reset），負責將上游 (pe_mfiu_seq) 產生之 metadata 映射並擷取為真實之非零值，以提供給下游之 16 組 MAC 進行運算。其內部之多工路由邏輯如下：
- A 矩陣 data： 透過 a_meta[l] 索引本列之非零陣列，擷取對應數值。
- B 矩陣 data： 透過 b_meta[l] 之高位元 ([5:4]) 加上 grp_base 計算出真實目標欄位，再以低位元 ([3:0]) 擷取對應之非零值。針對閒置之資料通道（比如說只要用到 3 個乘法器，就會讓 lane 0,1,2 有值而已，其他補 0），模組將自動執行補零以屏蔽無效數據，並將其通道有效標誌 (lane_valid) 設為 0。


| 訊號 | 方向 | 寬度 | 說明 |
|------|------|------|------|
| `valid` / `effectual` | in | 1 / 5 | 本 group 有效 / 有效 lane 數 |
| `a_meta` / `b_meta` / `grp_base` | in | [16][4] / [16][6] / 4 | 來自 pe_mfiu_seq 的 meta |
| `a_nz_row` / `b_nz` | in | [16][8] / [16][16][8] | 本 row A / 共享 B 壓縮值 |
| `a_val` / `b_val` | out | [16][8] / [16][8] | gather 後給 mac 的 A / B |
| `lane_col` / `lane_valid` / `valid_out` | out | [16][4] / [16] / 1 | 各 lane 輸出欄 / 有效 / 整體 valid |

### dist/reduction_tree_radix16.sv — 分段加總樹
本模組負責將 1-16 個部分乘積 (Partial products) 依據 cut_after 訊號劃分為多個連續區段 (Sub-trees)，並平行計算各區段的總和。
- 當 cut_after[i] = 1 時，代表 lane i 與 i+1 之間為區段邊界；若全為 0，則將整列 16 個輸入視為單一區段加總。
- 採用 Multi-tap 輸出設計。當 subtree_valid[p] = 1，表示位置 p 為某個區段的末端，對應的 subtree_sums[p] 即為該區段之加總結果。
- 資料型態與時序：輸入的 partial product 會先進行 Sign-extension 擴展至 INT32 後再進行加總，整個模組的運算延遲 (Latency) 為 1 個 Cycle。

| 訊號 | 方向 | 寬度 | 說明 |
|------|------|------|------|
| `clk` / `rst_n` / `en` | in | 1 | 時脈 / reset / enable |
| `partials` | in | [16][16] | 16 個 partial product(signed) |
| `cut_after` | in | 15 | 段邊界(與 partials 同拍) |
| `subtree_sums` | out | [16][32] | 各段總和(signed, registered) |
| `subtree_valid` | out | [16] | 段尾位置標記(registered) |

####  Kogge-Stone Segmented Scan (分段掃描)
- 這段程式碼的核心邏輯 val[lvl][i] = b[lvl-1][i] ? ... 。
- 一般加總樹無法處理動態切斷 (cut_after)，而這裡引入了邊界標記 b，在樹狀折疊的過程中，只要當前計算路徑發現了「段界」，加法器就會被 Bypass 掉，這保證了資料絕對不會跨段污染。

＊用例子比較好想：
假設 MFIU 打包了 4 欄 B：Col 19, Col 20, Col 25, Col 30。
算出來的交集數量分別是：2 個, 1 個, 3 個, 1 個。

分配到 Lane 上的狀態：
- Lane 0, 1: 算 C[2][19] 的部分和
- Lane 2: 算 C[2][20] 的部分和 (只有 1 個)
- Lane 3, 4, 5: 算 C[2][25] 的部分和(有 3 個)
- Lane 6: 算 C[2][30] 的部分和 (只有 1 個)

控制邏輯產生的 cut_after：
- cut_after[0] = 0
- cut_after[1] = 1 ➔ (Lane 1 結算 C[2][19])
- cut_after[2] = 1 ➔ (Lane 2 結算 C[2][20]，這段長度只有 1，照樣結算！)
- cut_after[3] = 0
- cut_after[4] = 0
- cut_after[5] = 1 ➔ (Lane 5 結算 C[2][25])
- cut_after[6] = 1 ➔ (Lane 6 結算 C[2][30])

因此 cut_after 遇到 1 時就結算來自同欄的輸出，也可發現 col 是連續傳的，不會有需要處理不連續和加總的問題