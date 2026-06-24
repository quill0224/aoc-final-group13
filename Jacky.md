# Jacky.md — Trapezoid-Lite ASIC 模組速查手冊

> 負責範圍：SRAM / GLB / DMA / Controller / MC / Integration Wrapper / TB 框架
> 不含：PE Array、NoC、PPU（由其他組員負責）
> 設計目標：復刻 Trapezoid 論文，支援 StandardIP（Dense）與 TrIP（Sparse）兩種模式
> Bitmask 與 mode 由外部（軟體）提供，ASIC 內部不做 sparse 判斷

---

## 目錄

1. [專案結構](#1-專案結構)
2. [全域參數 ASIC.svh](#2-全域參數-asicsvh)
3. [AXI_define.svh](#3-axi_definesvh)
4. [SRAM_rtl.sv](#4-sram_rtlsv)
5. [GLB.sv](#5-glbsv)
6. [DMA.sv](#6-dmasv)
7. [controller.sv](#7-controllersv)
8. [MC.sv](#8-mcsv)
9. [integration.sv](#9-integrationsv)
10. [axi_mem_model.sv（TB 專用）](#10-axi_mem_modelsv-tb-專用)
11. [測試框架 tb.cpp / tb.h](#11-測試框架-tbcpp--tbh)
12. [Makefile 指令速查](#12-makefile-指令速查)
13. [已知問題與注意事項](#13-已知問題與注意事項)
14. [組員對接介面清單](#14-組員對接介面清單)

---

## 1. 專案結構

```
PROJECT_ROOT/
├── Makefile ← 根目錄入口，所有 make 指令從這裡下
├── Jacky.md ← 本文件
├── src/
│ ├── AXI/
│ │ └── AXI_define.svh ← AXI 協議參數定義
│ ├── ASIC.svh ← 全域硬體參數（封包格式、GLB 佈局、MMIO map）
│ ├── SRAM_rtl.sv ← 底層 1KB SRAM 行為模型
│ ├── GLB.sv ← Global Buffer（16 bank × 1KB SRAM）
│ ├── DMA.sv ← AXI4 Master DMA（Fetch & Writeback）
│ ├── controller.sv ← 頂層 FSM 控制器（MKN 迴圈）
│ ├── MC.sv ← Memory Controller（GLB → PE 資料派發）
│ ├── integration.sv ← 子系統整合 Wrapper
│ └── axi_mem_model.sv ← TB 專用 AXI Slave DRAM 模型
└── tb/
├── testbench/
│ └── dla/
│ ├── Makefile ← TB 內層 Makefile
│ ├── tb.cpp ← Verilator C++ Harness
│ └── tb.h ← C/C++ 共用 API Header
└── tests/
├── case_SRAM/ ← SRAM 單元測試
│ ├── data.h
│ ├── main.c
│ ├── workload.c
│ └── workload.h
├── case_GLB/
├── case_DMA/
├── case_CTRL/
├── case_MC/
└── case_INTEGRATION/
```

---

## 2. 全域參數 ASIC.svh

路徑：`src/ASIC.svh`
用途：所有模組共用的參數定義，修改此檔案會影響全系統。

### 封包格式

| 參數 | 值 | 說明 |
|------|-----|------|
| `PKT_MODE_BITS` | 2 | mode 欄位寬度 |
| `PKT_BITMASK_BITS` | 16 | bitmask 欄位寬度 |
| `PKT_NZ_BITS` | 128 | NZ values 最大寬度 |
| `PKT_VALID_BITS` | 146 | 有效資料總位元（2+16+128） |
| `PKT_TOTAL_BITS` | 160 | 補齊後的封包大小（20 bytes） |
| `PKT_BYTES` | 20 | 每個封包 20 bytes |
| `PKT_BEATS` | 5 | 每個封包 5 個 AXI beats（20B / 4B） |

> 封包格式：`[ mode 2b ][ bitmask 16b ][ NZ values 128b ]`
> 軟體端負責補 0 至 20 bytes，硬體不做 padding

### Operation Mode

| 值 | 常數名稱 | 說明 |
|----|----------|------|
| `2'b00` | `MODE_STD_IP` | StandardIP，Dense dataflow，MFIU bypass |
| `2'b01` | `MODE_TRIP` | TrIP，Sparse dataflow，MFIU 啟用 |
| `2'b10` | `MODE_RESERVED_2` | 保留 |
| `2'b11` | `MODE_RESERVED_3` | 保留 |

### DMA Transfer Mode

| 值 | 常數名稱 | 說明 |
|----|----------|------|
| `2'd0` | `DMA_MODE_IFMAP` | Fetch A（ifmap） |
| `2'd1` | `DMA_MODE_FILTER` | Fetch B（filter） |
| `2'd2` | `DMA_MODE_BIAS` | 保留（未實作） |
| `2'd3` | `DMA_MODE_OFMAP` | Writeback C（output） |

### PE Array 參數

| 參數 | 值 | 說明 |
|------|-----|------|
| `PE_ARRAY_W` | 16 | PE 陣列寬度 |
| `PE_ARRAY_H` | 16 | PE 陣列高度 |
| `PE_NUMS` | 256 | PE 總數（16×16） |
| `XID_BITS` | 4 | X 座標位元寬 |
| `YID_BITS` | 4 | Y 座標位元寬 |

> PE 座標慣例：右下角 = (XID=0, YID=0)，左下角 = (XID=15, YID=0)，左上角 = (XID=15, YID=15) = index 255

### Tiling 參數（以 VGG8 conv3-512 為最壞情況）

| 參數 | 值 | 說明 |
|------|-----|------|
| `N_TILE_SIZE` | 16 | output channel tile 大小 |
| `K_TILE_SIZE` | 16 | input ch × filter spatial tile 大小 |
| `M_TILE_SIZE` | 16 | output spatial tile 大小 |
| `N_TILES_MAX` | 32 | 最多 N tiles（512/16） |
| `K_TILES_MAX` | 288 | 最多 K tiles（4608/16） |
| `M_TILES_MAX` | 49 | 最多 M tiles（784/16） |
| `N_CNT_BITS` | 6 | n_cnt 計數器位元寬 |
| `K_CNT_BITS` | 10 | k_cnt 計數器位元寬 |
| `M_CNT_BITS` | 7 | m_cnt 計數器位元寬 |
| `PKTS_PER_TILE` | 16 | 每個 tile 的封包數 |
| `PKT_CNT_BITS` | 5 | packet count 計數器位元寬 |

### GLB 佈局

| 區域 | 起始位址 | 大小 | 用途 |
|------|----------|------|------|
| GLB_A | `0x0000` | 320 bytes | ifmap tile（16 pkts × 20 bytes） |
| GLB_B | `0x0140` | 320 bytes | filter tile（16 pkts × 20 bytes） |
| GLB_C | `0x0280` | 256 bytes | output tile（16×16 × 1 byte @ 8bit） |
| 合計 | — | 896 bytes | < 1KB SRAM macro ✓ |

> `GLB_ADDR_BITS = 16`，以 byte 為單位定址；RTL 內部右移 2 bit 取得 word index

### MMIO Register Map（Base: `0x1004_0000`）

| 偏移 | 名稱 | 方向 | 說明 |
|------|------|------|------|
| `+0x00` | `ASIC_ENABLE_OFFSET` | W | asic_en |
| `+0x04` | `ASIC_OP_MODE_OFFSET` | W | operation_mode[1:0] |
| `+0x08` | `ASIC_MAPPING_PARAM_OFFSET` | W | {e[3:0], p[2:0], q[2:0], r[2:0], t[2:0]} |
| `+0x0C` | `ASIC_N_TILES_OFFSET` | W | N_tiles[5:0] |
| `+0x10` | `ASIC_K_TILES_OFFSET` | W | K_tiles[9:0] |
| `+0x14` | `ASIC_M_TILES_OFFSET` | W | M_tiles[6:0] |
| `+0x18` | `ASIC_PKT_COUNT_OFFSET` | W | packet_count[4:0] |
| `+0x1C` | `ASIC_IFMAP_BASE_OFFSET` | W | A fiber DRAM base addr |
| `+0x20` | `ASIC_FILTER_BASE_OFFSET` | W | B fiber DRAM base addr |
| `+0x24` | `ASIC_OPSUM_BASE_OFFSET` | W | C tensor DRAM base addr |
| `+0x28` | `ASIC_COMP_A_LEN_OFFSET` | W | A tile byte length（4B-aligned） |
| `+0x2C` | `ASIC_COMP_B_LEN_OFFSET` | W | B tile byte length（4B-aligned） |
| `+0x30` | `ASIC_GLB_A_BASE_OFFSET` | W | GLB A base addr |
| `+0x34` | `ASIC_GLB_B_BASE_OFFSET` | W | GLB B base addr |
| `+0x38` | `ASIC_GLB_C_BASE_OFFSET` | W | GLB C base addr |
| `+0x3C` | `ASIC_DONE_OFFSET` | R | asic_done[0] |

> 寫入順序：先寫所有參數，最後寫 `ASIC_ENABLE_OFFSET = 1`
> 完成偵測：輪詢 `ASIC_DONE_OFFSET` 或等待中斷

---

## 3. AXI_define.svh

路徑：`src/AXI/AXI_define.svh`

| 參數 | 值 | 說明 |
|------|-----|------|
| `AXI_DATA_BITS` | 32 | 每個 beat 32 bits（4 bytes） |
| `AXI_ADDR_BITS` | 32 | 位址寬度 |
| `AXI_ID_BITS` | 4 | AXI ID 寬度 |
| `AXI_STRB_BITS` | 4 | Write strobe 寬度（32/8） |
| `AXI_LEN_BITS` | 8 | Burst length 欄位寬度 |
| `AXI_SIZE_BITS` | 3 | Transfer size 欄位寬度 |
| `AXI_SIZE_WORD` | `3'b010` | 4 bytes per beat |
| `AXI_BURST_INC` | `2'h1` | INCR burst type |

---

## 4. SRAM_rtl.sv

路徑：`src/SRAM_rtl.sv`
規格：128 Words × 64 bits = 1 KB
模擬目標：TSMC N16ADFP `TS1N16ADFPCLLLVTA128X64M4SWSHOD`

### Port 列表

| 方向 | 寬度 | 名稱 | 說明 |
|------|------|------|------|
| input | 1 | `CLK` | 上升沿觸發 |
| input | 1 | `CEB` | Chip Enable，**Active-Low**（0=選中） |
| input | 1 | `WEB` | Write Enable，**Active-Low**（0=寫入，1=讀取） |
| input | 7 | `A` | Word address（0~127） |
| input | 64 | `D` | Write data |
| input | 64 | `BWEB` | Bit-write mask，**Active-Low**（0=寫入此 bit） |
| output | 64 | `Q` | Read data（同步，1-cycle latency） |
| input | 1 | `SLP` | 測試腳，綁 0 |
| input | 1 | `DSLP` | 測試腳，綁 0 |
| input | 1 | `SD` | 測試腳，綁 0 |
| input | 2 | `RCT` | 測試腳，綁 0 |
| input | 2 | `WTSEL` | 測試腳，綁 0 |
| input | 3 | `KP` | 測試腳，綁 0 |
| output | 1 | `PUDELAY` | 空接（模型固定輸出 0） |

### 行為說明

- **讀取**：`CEB=0, WEB=1`，地址在 `CLK` 上升沿鎖存，資料在**下一個 cycle** 從 `Q` 輸出
- **寫入**：`CEB=0, WEB=0`，`D` 中 `BWEB[i]=0` 的 bit 才寫入
- **閒置**：`CEB=1`，`Q` 保持上次讀取值，不更新
- **Simulation init**：`ifdef SIMULATION` 下 mem 全部初始化為 0，避免 X 傳播

### Simulation Assertions

| 條件 | 類型 | 說明 |
|------|------|------|
| `CEB=0` 時 `WEB` 為 X | `$error` | WEB 不可為 X |
| `CEB=0` 時 `A` 為 X | `$error` | 地址不可為 X |
| 寫入時 `D` 含 X | `$warning` | 資料含 X 可能是 TB bug |
| 寫入時 `BWEB` 含 X | `$warning` | Mask 含 X 可能是 TB bug |

---

## 5. GLB.sv

路徑：`src/GLB.sv`
規格：16 banks × 1KB SRAM = 16KB 物理，實際使用 896 bytes（A+B+C）
外部介面：32-bit data，16-bit byte address，4-bit write strobe

### Port 列表

| 方向 | 寬度 | 名稱 | 說明 |
|------|------|------|------|
| input | 1 | `clk` | 系統時脈 |
| input | 1 | `rst` | Active-High Reset |
| input | 1 | `EN` | Active-High 致能（來自 Controller 或 DMA MUX） |
| input | 1 | `WEB` | Active-Low Write Enable（0=寫入，1=讀取） |
| input | 4 | `WSTRB` | Active-High Byte Enable（1=寫入對應 byte） |
| input | 16 | `A` | Byte address（`GLB_ADDR_BITS=16`） |
| input | 32 | `DI` | Write data |
| output | 32 | `DO` | Read data（1-cycle latency） |

### 地址解碼邏輯

```
A[15:14] 保留
A[13:10] Bank 選擇（0~15）
A[9:3] Word address within bank（0~127，對應 SRAM A[6:0]）
A[2] Half-word 選擇（0=低 32-bit，1=高 32-bit）
A[1:0] Byte offset（由 WSTRB 處理，不用於地址）
```

### 資料對齊與寫入遮罩

每個 SRAM bank 是 64-bit wide；GLB 外部介面是 32-bit。
`A[2]` 決定寫入 64-bit word 的高半部或低半部：

- `A[2]=0`：寫入 `[31:0]`，BWEB `[31:0]` 由 WSTRB 決定
- `A[2]=1`：寫入 `[63:32]`，BWEB `[63:32]` 由 WSTRB 決定

### 讀取路徑

SRAM 有 1-cycle read latency，GLB 內部用暫存器延遲 bank index 和 half-word index：

```
cycle 0: A 輸入，bank_ce_n 驅動，SRAM 收到位址
cycle 1: SRAM 輸出 Q，GLB 根據延遲的 A[13:10] 和 A[2] 選取 DO
```

### 內部 SRAM 實例化

```systemverilog
// 16 個 SRAM_rtl 實例，各自對應一個 bank
generate
for (i = 0; i < 16; i++) begin : gen_sram
SRAM_rtl u_sram ( ... );
end
endgenerate
```

---

## 6. DMA.sv

路徑：`src/DMA.sv`
模組名稱：`DMA`（大寫，Verilator 產生 `VDMA.h`）
功能：AXI4 Master，負責 DRAM ↔ GLB 資料搬移，支援自動 chunking（>1024B 切割）

### Reset 與介面契約

- Reset：**Active-High** `rst`（與 controller 一致）
- `DMA_done`：**1-cycle pulse**，caller 必須用 sticky flag 鎖存
- Re-trigger 防護：DMA 只在 `IDLE` 狀態接受新的 `DMA_en`

### Port 列表

#### Controller 介面

| 方向 | 寬度 | 名稱 | 說明 |
|------|------|------|------|
| input | 1 | `DMA_en` | Level，controller 在目標狀態持續拉高 |
| input | 2 | `DMA_mode` | 0=Fetch A，1=Fetch B，3=Writeback C |
| input | 32 | `DMA_DRAM_ADDR` | DRAM 起始位址 |
| input | 16 | `DMA_GLB_ADDR` | GLB 起始位址 |
| input | 32 | `DMA_len` | 傳輸 byte 數，**必須 4B 對齊** |
| output | 1 | `DMA_done` | 1-cycle pulse，傳輸完成 |

#### GLB 介面

| 方向 | 寬度 | 名稱 | 說明 |
|------|------|------|------|
| output | 1 | `glb_en` | GLB 存取致能 |
| output | 1 | `glb_we` | 1=寫入 GLB（Fetch 路徑），0=讀取 GLB（Writeback 路徑） |
| output | 4 | `glb_wstrb` | 固定 `4'b1111`（整 word 讀寫） |
| output | 16 | `glb_addr` | GLB byte 位址（`cur_glb_addr`） |
| output | 32 | `glb_wdata` | 寫入 GLB 的資料（來自 AXI RDATA） |
| input | 32 | `glb_rdata` | 從 GLB 讀出的資料（給 Writeback FIFO） |

#### AXI4 Master 介面（AR/R/AW/W/B channels）

| 方向 | 寬度 | 名稱 | 說明 |
|------|------|------|------|
| output | 4 | `ARID` | 固定 `4'd2` |
| output | 32 | `ARADDR` | 讀取位址 |
| output | 8 | `ARLEN` | Burst length - 1 |
| output | 3 | `ARSIZE` | `AXI_SIZE_WORD`（4B/beat） |
| output | 2 | `ARBURST` | `AXI_BURST_INC` |
| output | 1 | `ARVALID` | AR channel valid |
| input | 1 | `ARREADY` | AR channel ready |
| input | 4 | `RID` | — |
| input | 32 | `RDATA` | 讀取資料 |
| input | 2 | `RRESP` | 應為 OKAY |
| input | 1 | `RLAST` | Burst 最後一拍 |
| input | 1 | `RVALID` | R channel valid |
| output | 1 | `RREADY` | FETCH_R 狀態下固定 1 |
| output | 4 | `AWID` | 固定 `4'd2` |
| output | 32 | `AWADDR` | 寫入位址 |
| output | 8 | `AWLEN` | Burst length - 1 |
| output | 3 | `AWSIZE` | `AXI_SIZE_WORD` |
| output | 2 | `AWBURST` | `AXI_BURST_INC` |
| output | 1 | `AWVALID` | AW channel valid |
| input | 1 | `AWREADY` | AW channel ready |
| output | 32 | `WDATA` | 來自 Writeback FIFO |
| output | 4 | `WSTRB` | 固定 `4'b1111` |
| output | 1 | `WLAST` | Burst 最後一拍 |
| output | 1 | `WVALID` | FIFO 非空才拉高 |
| input | 1 | `WREADY` | W channel ready |
| input | 4 | `BID` | — |
| input | 2 | `BRESP` | 應為 OKAY |
| input | 1 | `BVALID` | B channel valid |
| output | 1 | `BREADY` | WB_B 狀態下固定 1 |

### FSM 狀態

| 狀態 | 編碼 | 說明 |
|------|------|------|
| `IDLE` | `3'd0` | 等待 `DMA_en`，鎖存參數 |
| `REQ_AR` | `3'd1` | 發送 AXI Read Address |
| `FETCH_R` | `3'd2` | 接收 AXI Read Data，直寫 GLB |
| `REQ_AW` | `3'd3` | 發送 AXI Write Address |
| `WB_FILL` | `3'd4` | 預填 Writeback FIFO |
| `WB_W` | `3'd5` | 發送 AXI Write Data |
| `WB_B` | `3'd6` | 等待 AXI Write Response |
| `DONE` | `3'd7` | 1-cycle，輸出 `DMA_done` pulse，返回 `IDLE` |

### Chunking 邏輯

```
burst_bytes = min(rem_bytes, 1024)
burst_beats_m1 = burst_bytes / 4 - 1 // ARLEN/AWLEN 值（8-bit）
total_beats = {1'b0, burst_beats_m1} + 9'd1 // 9-bit，防溢出
```

大於 1024B 的請求自動分割為多個 256-beat burst。

### Writeback FIFO

- 深度：16 entries × 32-bit
- 用途：解耦 GLB 1-cycle read latency 與 AXI WREADY stall
- `glb_rd_req`：FIFO 有空間且 `beats_transferred < total_beats` 時發出 GLB 讀取請求
- `glb_rd_valid`：`glb_rd_req` 延遲 1 cycle（對應 GLB 的讀取 latency）

---

## 7. controller.sv

路徑：`src/controller.sv`
模組名稱：`controller`（Verilator 產生 `Vcontroller.h`）

### 功能概述

- MKN 三層迴圈控制（M=output spatial，K=input ch×filter，N=output ch）
- A（ifmap）每個 M tile 載入一次，K×N 迭代期間 reuse
- B（filter）每個 N tile 重新載入
- DMA_done 為 1-cycle pulse，controller 用 sticky flag 鎖存

### Port 列表

#### 系統

| 方向 | 寬度 | 名稱 | 說明 |
|------|------|------|------|
| input | 1 | `clk` | 系統時脈 |
| input | 1 | `rst` | Active-High Reset |
| input | 1 | `asic_en` | Level，來自 MMIO（經兩級同步器） |
| output | 1 | `asic_done` | Level，S11_DONE 期間保持高，直到 asic_en 拉低 |

#### DRAM Base Addresses

| 方向 | 寬度 | 名稱 | 說明 |
|------|------|------|------|
| input | 32 | `A_fiber_base_addr` | A fiber DRAM 基底位址 |
| input | 32 | `B_fiber_base_addr` | B fiber DRAM 基底位址 |
| input | 32 | `C_tensor_base_addr` | Output DRAM 基底位址 |

#### GLB Base Addresses

| 方向 | 寬度 | 名稱 | 說明 |
|------|------|------|------|
| input | 16 | `GLB_A_base_addr` | A tile 在 GLB 的起始位址 |
| input | 16 | `GLB_B_base_addr` | B tile 在 GLB 的起始位址 |
| input | 16 | `GLB_C_base_addr` | Output tile 在 GLB 的起始位址 |

#### Tiling & Control

| 方向 | 寬度 | 名稱 | 說明 |
|------|------|------|------|
| input | 32 | `comp_A_len_in` | A tile byte 長度，4B 對齊 |
| input | 32 | `comp_B_len_in` | B tile byte 長度，4B 對齊 |
| input | 32 | `comp_C_len_in` | C tile byte 長度，4B 對齊 |
| input | 6 | `N_tiles_in` | N tile 總數（≥1） |
| input | 10 | `K_tiles_in` | K tile 總數（≥1） |
| input | 7 | `M_tiles_in` | M tile 總數（≥1） |
| input | 5 | `packet_count_in` | 每 tile 封包數（≥1） |
| input | 2 | `operation_mode_in` | 運算模式 |

#### PE Mapping Parameters

| 方向 | 寬度 | 名稱 | 說明 |
|------|------|------|------|
| input | 4 | `e` | mapping 參數 |
| input | 3 | `p` | mapping 參數 |
| input | 3 | `q` | mapping 參數（**q[2] 必須為 0**，只用 q[1:0]） |
| input | 3 | `r` | 保留，tied off |
| input | 3 | `t` | 保留，tied off |

#### DMA 介面

| 方向 | 寬度 | 名稱 | 說明 |
|------|------|------|------|
| output | 1 | `DMA_en` | Flag 置位後自動拉低，防止 DMA re-trigger |
| output | 2 | `DMA_mode` | 0=A，1=B，3=C writeback |
| output | 32 | `DMA_DRAM_ADDR` | base + addr_acc |
| output | 16 | `DMA_GLB_ADDR` | GLB 目標位址 |
| output | 32 | `DMA_len` | 傳輸長度 |
| input | 1 | `DMA_done` | 1-cycle pulse |

#### MC 介面

| 方向 | 寬度 | 名稱 | 說明 |
|------|------|------|------|
| output | 1 | `mc_start` | 1-cycle pulse，S5 狀態 |
| output | 2 | `mc_mode` | 轉發 operation_mode |
| output | 16 | `mc_glb_base_A` | MC 讀取 A 的 GLB 起始位址 |
| output | 16 | `mc_glb_base_B` | MC 讀取 B 的 GLB 起始位址 |
| output | 5 | `mc_packet_count` | 本次 tile 封包數 |
| input | 1 | `k_done` | MC 派發完成 |

#### PE Array 介面

| 方向 | 寬度 | 名稱 | 說明 |
|------|------|------|------|
| output | 2 | `global_mode` | 廣播 operation_mode |
| output | 1 | `global_flush` | 1-cycle pulse，S7 狀態，通知 PE 排空 local buffer |
| output | 256 | `PE_en` | S4~S8 期間全部拉高 |
| output | 11 | `PE_config` | `{mode[1:0], e[3:0], p[2:0], q[1:0]}` |
| input | 1 | `PEA_A_ready` | PE array 可接收新資料 |
| input | 1 | `PEA_B_ready` | PE array 可接收新資料 |

#### Scan Chain（全部 tied off）

| 方向 | 寬度 | 名稱 | 說明 |
|------|------|------|------|
| output | 1 | `set_XID` | 固定 0 |
| output | 1 | `set_YID` | 固定 0 |
| output | 1 | `set_LN` | 固定 0 |
| output | 4 | `ifmap/filter/ipsum/opsum_XID_scan_in` | 固定 0 |
| output | 4 | `ifmap/filter/ipsum/opsum_YID_scan_in` | 固定 0 |
| output | 15 | `LN_config_in` | 固定 0 |

#### PPU 介面

| 方向 | 寬度 | 名稱 | 說明 |
|------|------|------|------|
| input | 1 | `PEA_opsum_valid` | 直接路由到 PPU，controller 不使用（lint suppress） |
| output | 1 | `PEA_opsum_ready` | S8_WAIT_PPU 期間拉高 |
| output | 4 | `opsum_tag_X` | 固定 0（待 tiling 位址計算） |
| output | 4 | `opsum_tag_Y` | 固定 0 |
| output | 1 | `relu_sel` | `operation_mode[0]`（TrIP=1 啟用 ReLU） |
| output | 1 | `Maxpool_en` | 固定 0 |
| output | 1 | `Maxpool_init` | 固定 0 |
| input | 1 | `ppu_done` | PPU 處理完成 |

### FSM 狀態（13 states，4-bit encoding）

| 狀態 | 編碼 | 說明 | 轉移條件 |
|------|------|------|----------|
| `S0_IDLE` | `4'd0` | 等待啟動 | `asic_en_sync → S1` |
| `S1_SHADOW_LATCH` | `4'd1` | 鎖存 MMIO（1 cycle） | `→ S2` |
| `S2_DMA_FETCH_A` | `4'd2` | 載入 A tile（M 邊界才執行） | `dma_a_done_flag → S3` |
| `S3_DMA_FETCH_B` | `4'd3` | 載入 B tile（每個 N tile） | `dma_b_done_flag && PEA_ready → S4` |
| `S4_SEND_PE_CONFIG` | `4'd4` | 廣播 PE config（1 cycle） | `→ S5` |
| `S5_MC_DISPATCH` | `4'd5` | mc_start pulse（1 cycle） | `→ S6` |
| `S6_WAIT_K_DONE` | `4'd6` | 等待 MC 完成派發 | `k_done → S7` |
| `S7_FLUSH` | `4'd7` | global_flush pulse（1 cycle） | `→ S8` |
| `S8_WAIT_PPU` | `4'd8` | 等待 PPU 完成 | `ppu_done → S9` |
| `S9_UPDATE_NK` | `4'd9` | 更新 n_cnt / k_cnt | 見下方邏輯 |
| `S10_DMA_WRITEBACK` | `4'd10` | 寫回 C tile | `dma_wb_done_flag → S9b` |
| `S9b_UPDATE_M` | `4'd11` | 更新 m_cnt，重置 addr_acc_B | `m_cnt < M-1 → S2，else → S11` |
| `S11_DONE` | `4'd12` | 完成，保持 asic_done | `!asic_en_sync → S0` |

### S9_UPDATE_NK 轉移邏輯

```
if n_cnt < N_tiles - 1:
→ S3 (繼續 N 迴圈，A reuse)
elif k_cnt < K_tiles - 1:
→ S3 (N reset，K 遞增，A reuse)
else:
→ S10 (K×N 全完，writeback)
```

### DMA Sticky Flags

| Flag | Set 條件 | Clear 條件 | 說明 |
|------|----------|------------|------|
| `dma_a_done_flag` | `cs==S2 && DMA_done` | `cs==S3` | Set-priority |
| `dma_b_done_flag` | `cs==S3 && DMA_done` | `cs==S4` | Set-priority |
| `dma_wb_done_flag` | `cs==S10 && DMA_done` | `cs==S9b` | Set-priority |

> Set-priority：DMA_done 和 clear 同一 cycle 到達時，set 優先

### Address Accumulators

| 變數 | 更新時機 | 說明 |
|------|----------|------|
| `addr_acc_A` | `S9b_UPDATE_M` | 每個 M tile += `comp_A_len` |
| `addr_acc_B` | `S9_UPDATE_NK` | 每個 N tile += `comp_B_len`；在 `S9b` 重置為 0 |
| `addr_acc_C` | `S9b_UPDATE_M` | 每個 M tile（writeback 後）+= `comp_C_len` |

### Simulation Assertions

| 觸發條件 | 類型 | 說明 |
|----------|------|------|
| S1 進入時 N/K/M_tiles_in = 0 | `$error` | clamp 到 1 但會警告 |
| S1 進入時 comp_*_len 非 4B 對齊或為 0 | `$error` | — |
| S1 進入時 operation_mode 為保留值 | `$error` | — |
| S4 時 q[2] = 1 | `$error` | q[2] 被靜默丟棄 |
| S3 DMA 超過 10000 cycles 未完成 | `$error` | watchdog |
| S3 DMA 完成後 PEA_ready 超過 200 cycles | `$error` | watchdog |
| S2 entry 時 addr_acc_B ≠ 0 | `$error` | B rewind 遺漏 |
| mc_start 連續兩 cycle 高電位 | `$error` | pulse 規範違反 |
| global_flush 連續兩 cycle 高電位 | `$error` | pulse 規範違反 |

---

## 8. MC.sv

路徑：`src/MC.sv`
模組名稱：`MC`（Verilator 產生 `VMC.h`）
功能：從 GLB 讀取封包，按順序送給 PE Array

### Port 列表

| 方向 | 寬度 | 名稱 | 說明 |
|------|------|------|------|
| input | 1 | `clk` | 系統時脈 |
| input | 1 | `rst` | Active-High Reset |
| input | 1 | `mc_start` | 1-cycle pulse（來自 controller S5） |
| input | 2 | `mc_mode` | 運算模式 |
| input | 16 | `mc_glb_base_A` | A tile 在 GLB 的起始位址 |
| input | 16 | `mc_glb_base_B` | B tile 在 GLB 的起始位址 |
| input | 16 | `mc_packet_count` | 本次 tile 封包數（`PKT_CNT_BITS` 寬） |
| output | 1 | `k_done` | 1-cycle pulse，所有封包派發完成 |
| output | 1 | `mc_glb_ren_A` | GLB A 讀取致能 |
| output | 16 | `mc_glb_addr_A` | GLB A 讀取位址 |
| output | 1 | `mc_glb_ren_B` | GLB B 讀取致能 |
| output | 16 | `mc_glb_addr_B` | GLB B 讀取位址 |
| output | 1 | `pe_data_valid` | 資料有效（延遲 1 cycle，對應 GLB read latency） |

### Parameters

```systemverilog
parameter GLB_ADDR_BITS = 16
parameter PKT_CNT_BITS = 16
```

### FSM 狀態

| 狀態 | 說明 | 轉移條件 |
|------|------|----------|
| `MC_IDLE` | 等待 mc_start | `mc_start → MC_RUN` |
| `MC_RUN` | 逐拍發出 GLB 讀取請求，pkt_cnt 遞增 | `pkt_cnt == pkt_max - 1 → MC_DONE` |
| `MC_DONE` | 發出 k_done pulse（1 cycle）；vld_pipe_reg 清 0 | `→ MC_IDLE` |

### 位址產生

```
mc_glb_addr_A = reg_base_A + (pkt_cnt << 2)
mc_glb_addr_B = reg_base_B + (pkt_cnt << 2)
```

> pkt_cnt 在 MC_RUN 期間不超車：`if pkt_cnt < pkt_max - 1: pkt_cnt++`

### 資料有效時序

```
cycle 0: MC_RUN，pkt_cnt=0，mc_glb_ren=1，glb_addr=base+0
cycle 1: pkt_cnt=1，ren=1，vld_pipe_reg=1 → pe_data_valid=1（GLB 資料有效）
...
cycle N: pkt_cnt=N-1 → MC_DONE（此 cycle vld_pipe_reg 仍為 1）
cycle N+1: MC_IDLE，vld_pipe_reg=0
```

> ⚠️ **已知問題**：`mc_glb_ren_A/B` 的讀取結果目前**未連接到 GLB**，
> integration.sv 中連線為空（`.mc_glb_ren_A()`, `.mc_glb_addr_A()`）。
> 待組員整合時修正。

---

## 9. integration.sv

路徑：`src/integration.sv`
模組名稱：`integration`（Verilator 產生 `Vintegration.h`）
功能：整合 controller、DMA、GLB、MC 與 DRAM 模型的子系統 Wrapper

### Port 列表

#### 系統

| 方向 | 寬度 | 名稱 | 說明 |
|------|------|------|------|
| input | 1 | `clk` | — |
| input | 1 | `rst` | Active-High |
| input | 1 | `asic_en` | — |
| output | 1 | `asic_done` | — |

#### MMIO 參數（與 controller 一致）

同 [controller.sv Port 列表](#port-列表-3)，包含所有 base addr、tiling params、mapping params。

> `r` 和 `t` 在 integration.sv 中直接綁為 `3'b0`，不對外暴露。

#### 下游 Mock 訊號（PE Array / PPU 尚未整合）

| 方向 | 寬度 | 名稱 | 說明 |
|------|------|------|------|
| input | 1 | `PEA_A_ready` | TB 驅動，模擬 PE 就緒 |
| input | 1 | `PEA_B_ready` | TB 驅動，模擬 PE 就緒 |
| input | 1 | `ppu_done` | TB 驅動，模擬 PPU 完成 |

#### 觀測腳位（供 TB 監聽）

| 方向 | 寬度 | 名稱 | 說明 |
|------|------|------|------|
| output | 1 | `obs_mc_start` | 映射自 `mc_start` |
| output | 1 | `obs_pe_data_valid` | 映射自 MC 的 `pe_data_valid` |
| output | 1 | `obs_global_flush` | 映射自 controller 的 `global_flush` |

### 內部連線

```
controller u_ctrl ←→ DMA u_dma (DMA_en / DMA_done)
controller u_ctrl ←→ MC u_mc (mc_start / k_done)
DMA u_dma ←→ GLB u_glb (glb_en / glb_we / glb_addr / glb_wdata / glb_rdata)
DMA u_dma ←→ axi_mem_model (全部 AXI AR/R/AW/W/B channels)
```

> ⚠️ **MC 的 GLB 讀取線尚未連到 GLB**，目前 MC 的輸出腳位空接。

---

## 10. axi_mem_model.sv（TB 專用）

路徑：`src/axi_mem_model.sv`
用途：TB 使用的 AXI4 Slave DRAM 模型，不進合成

### Parameters

| 參數 | 預設值 | 說明 |
|------|--------|------|
| `MEM_DEPTH` | 65536 | Word-addressable 深度（256KB） |
| `LATENCY` | 2 | AR → R 第一拍的延遲 cycles |

### Port 列表

完整 AXI4 Slave（AR/R/AW/W/B），資料寬度 32-bit。

### 行為

- **讀取路徑**：AR_IDLE → AR_WAIT（latency 倒數）→ AR_BURST（逐 beat 輸出 mem 資料）
- **寫入路徑**：AW_IDLE → AW_DATA（依 WSTRB 寫入 mem）→ AW_RESP
- **初始化**：`initial` block 全部清 0
- **Preload**：提供 `preload_word(addr, data)` 和 `read_word(addr, data)` tasks

---

## 11. 測試框架 tb.cpp / tb.h

路徑：`tb/testbench/dla/`

### 架構說明

```
main.c ← 呼叫 tb_init, run_workload, tb_close
workload.c ← 測試激勵（純 C）
workload.h ← run_workload 宣告
data.h ← 測試向量
tb.h ← C/C++ 共用 API（extern "C"）
tb.cpp ← Verilator harness（C++）
```

### DUT 選擇（編譯時決定）

| 巨集 | 對應模組 | Verilator Header |
|------|----------|------------------|
| `-Dcase_SRAM` | `SRAM_rtl` | `VSRAM_rtl.h` |
| `-Dcase_GLB` | `GLB` | `VGLB.h` |
| `-Dcase_DMA` | `DMA` | `VDMA.h` |
| `-Dcase_CTRL` | `controller` | `Vcontroller.h` |
| `-Dcase_MC` | `MC` | `VMC.h` |
| `-Dcase_INTEGRATION` | `integration` | `Vintegration.h` |

### 波形輸出

自動在 `tb/testbench/dla/results/fst/` 產生：
```
{test_name}_{YYYYMMDD_HHMMSS}.fst
```

### 核心 API

```c
void tb_init(int argc, char** argv, const char* test_name);
void tb_close(void); // 輸出 PASS/FAIL 統計
void tick(void); // 一個完整 clock cycle
void tick_n(int n);
void do_reset(int cycles); // SRAM: 拉高 CEB/WEB；其他: rst=1 → n cycles → rst=0
```

### 巨集

```c
LOG(msg, ...) // 帶 sim_time 的 printf
CHECK(cond, msg, ...) // 失敗時 fail_count++，成功 pass_count++
```

### 各模組 API 摘要

#### case_SRAM

```c
void set_CEB(uint8_t); void set_WEB(uint8_t);
void set_A(uint8_t); void set_D(uint64_t);
void set_BWEB(uint64_t); uint64_t get_Q(void);
```

#### case_GLB

```c
void glb_set_EN(uint8_t); void glb_set_WEB(uint8_t);
void glb_set_WSTRB(uint8_t); void glb_set_A(uint32_t);
void glb_set_DI(uint32_t); uint32_t glb_get_DO(void);
```

#### case_DMA

```c
// Controller 端
void dma_set_en(uint8_t); void dma_set_mode(uint8_t);
void dma_set_dram_addr(uint32_t); void dma_set_glb_addr(uint32_t);
void dma_set_len(uint32_t); uint8_t dma_get_done(void);

// DMA 輸出觀測
uint8_t dma_get_ARVALID(void); uint32_t dma_get_ARADDR(void);
uint8_t dma_get_AWVALID(void); uint32_t dma_get_AWADDR(void);
uint8_t dma_get_WVALID(void); uint32_t dma_get_WDATA(void);
uint8_t dma_get_WLAST(void); uint8_t dma_get_BREADY(void);

// AXI Slave 驅動（模擬 DRAM）
void axi_set_ARREADY(uint8_t); void axi_set_RVALID(uint8_t);
void axi_set_RDATA(uint32_t); void axi_set_RRESP(uint8_t);
void axi_set_RLAST(uint8_t); void axi_set_AWREADY(uint8_t);
void axi_set_WREADY(uint8_t); void axi_set_BVALID(uint8_t);
void axi_set_BRESP(uint8_t);

// GLB Mock（DMA 單測時 tb.cpp 內建 mock_glb_mem）
void glb_mock_write(uint32_t byte_addr, uint32_t data);
uint32_t glb_mock_read(uint32_t byte_addr);
```

#### case_CTRL（單元測試，DMA / k_done 由 TB 驅動）

```c
void ctrl_set_asic_en(uint8_t);
void ctrl_set_A/B/C_fiber_base_addr(uint32_t);
void ctrl_set_GLB_A/B/C_base_addr(uint32_t);
void ctrl_set_comp_A/B/C_len_in(uint32_t);
void ctrl_set_N/K/M_tiles_in(uint32_t);
void ctrl_set_packet_count_in(uint32_t);
void ctrl_set_operation_mode_in(uint8_t);
void ctrl_set_e/p/q(uint8_t);
void ctrl_set_DMA_done(uint8_t); // 只有 case_CTRL 有效
void ctrl_set_k_done(uint8_t); // 只有 case_CTRL 有效
void ctrl_set_PEA_A_ready(uint8_t); void ctrl_set_PEA_B_ready(uint8_t);
void ctrl_set_ppu_done(uint8_t);
uint8_t ctrl_get_asic_done(void);
uint8_t ctrl_get_DMA_en(void); uint8_t ctrl_get_DMA_mode(void);
uint32_t ctrl_get_DMA_DRAM_ADDR(void); uint32_t ctrl_get_DMA_GLB_ADDR(void);
uint32_t ctrl_get_DMA_len(void);
uint8_t ctrl_get_mc_start(void); uint8_t ctrl_get_global_flush(void);
```

#### case_INTEGRATION（DMA / k_done 已內部化，不可由 TB 直接驅動）

```c
// 設定 API 同 case_CTRL，但 ctrl_set_DMA_done / ctrl_set_k_done 為空函式
// 觀測腳位
uint8_t ctrl_get_mc_start(void); // 映射 obs_mc_start
uint8_t ctrl_get_global_flush(void); // 映射 obs_global_flush
uint8_t ctrl_get_pe_data_valid(void); // 映射 obs_pe_data_valid
```

#### case_MC

```c
void mc_set_start(uint8_t); void mc_set_mode(uint8_t);
void mc_set_glb_base_A(uint32_t); void mc_set_glb_base_B(uint32_t);
void mc_set_packet_count(uint32_t);
uint8_t mc_get_k_done(void);
uint8_t mc_get_glb_ren_A(void); uint32_t mc_get_glb_addr_A(void);
uint8_t mc_get_glb_ren_B(void); uint32_t mc_get_glb_addr_B(void);
uint8_t mc_get_pe_data_valid(void);
```

---

## 12. Makefile 指令速查

### 從根目錄（Jacky.md 同層）執行

```bash
# 單元測試
make run_SRAM # SRAM_rtl 單元測試
make run_GLB # GLB 單元測試
make run_DMA # DMA fetch/writeback 測試
make run_CTRL # controller FSM 測試
make run_MC # MC AGU 與 latency 測試
make run_INTEGRATION # 子系統整合測試

# 批次執行所有測試
make run_unit_all

# 清理
make clean
```

### 從 tb/testbench/dla/ 執行（等效）

```bash
make run CASE=case_SRAM
make run CASE=case_GLB
make run CASE=case_DMA
make run CASE=case_CTRL
make run CASE=case_MC
make run CASE=case_INTEGRATION
make run_unit_all
make clean
```

### 測試執行流程

```
make run CASE=xxx
→ Verilator 編譯 V_SRCS + tb.cpp + workload.c + main.c
→ 產生 OBJ_DIR/V{TOP_MODULE} 執行檔
→ 執行，輸出 results/fst/{name}_{timestamp}.fst
→ 顯示 PASS/FAIL 統計
```

### Makefile 路徑對應

| 層級 | 路徑 | 功能 |
|------|------|------|
| 根目錄 | `./Makefile` | 委派到 `tb/testbench/dla` |
| 內層 | `tb/testbench/dla/Makefile` | 實際 Verilator 編譯與執行 |

### Verilator flags 說明

```makefile
-DSIMULATION # 啟用 RTL 內的 `ifdef SIMULATION 區塊
-I$(SRC_DIR)/AXI # AXI_define.svh include path
-I$(SRC_DIR) # ASIC.svh include path
-I$(OBJ_DIR) # Verilator 產生的 V*.h include path
-D$(CASE) # 傳入 case 巨集（case_SRAM 等）
-DRESULT_DIR="..." # 波形輸出目錄（絕對路徑）
```

---

## 13. 已知問題與注意事項

### ⚠️ 高優先（影響功能）

| 編號 | 位置 | 問題 | 建議修正 |
|------|------|------|----------|
| P1 | `integration.sv` | MC 的 `mc_glb_ren_A/B` 和 `mc_glb_addr_A/B` 空接，未連到 GLB | 待 MC 整合時接上 GLB 讀取線 |
| P2 | 根目錄 `Makefile` | `controller0` target 路徑寫死舊路徑 `src/hardware/dla/ASIC/controller.sv`，實際在 `src/controller.sv` | 修正路徑或移除此 target |

### ⚠️ 中優先（設計確認）

| 編號 | 位置 | 問題 | 說明 |
|------|------|------|------|
| P3 | `controller.sv` | S7_FLUSH 只持續 1 cycle | 需與 PE Array 確認：1 cycle 是否足以排空 local buffer pipeline |
| P4 | `controller.sv` | S3 等待 `PEA_A_ready && PEA_B_ready` | 若 PE Array 永遠不 ready，FSM 死鎖。simulation watchdog 200 cycles 會抓到，但合成後需確認語義 |
| P5 | `MC.sv` | `reg_mode` 被計算但從未用於路由邏輯 | `unused_ok` 已抑制 lint，但未來若需要 mode-based 派發需補邏輯 |

### ℹ️ 低優先（可讀性）

| 編號 | 位置 | 問題 | 說明 |
|------|------|------|------|
| P6 | `controller.sv` | `q[2]` 被丟棄，assertion 驗證 | 確認 mapping 參數 q 永遠不會用到第 2 bit |
| P7 | `DMA.sv` | Writeback chunking：`rem_bytes` 在 `WB_W WLAST` 才更新 | 注意：`WB_B → DONE` 的判斷是 `rem_bytes == burst_bytes`，此時 rem 尚未扣除，邏輯正確但易誤讀 |
| P8 | `integration.sv` | `r`, `t` 綁 `3'b0`，未對外暴露 | 未來若需要 mapping 可擴充 |

---

## 14. 組員對接介面清單

> 以下是 Jacky 負責的模組對外暴露給 PE Array / NoC / PPU 的介面，
> 組員整合時對接此表。

### controller → PE Array（需組員實作接收端）

| 信號 | 方向 | 寬度 | 時序說明 |
|------|------|------|----------|
| `global_mode` | ctrl → PE | 2 | S4 起有效，直到 S8 結束 |
| `global_flush` | ctrl → PE | 1 | **1-cycle pulse**，S7 狀態高電位 |
| `PE_en` | ctrl → PE | 256 | S4~S8 全部 1，其他 0 |
| `PE_config` | ctrl → PE | 11 | S4 廣播，格式：`{mode[1:0], e[3:0], p[2:0], q[1:0]}` |
| `PEA_A_ready` | PE → ctrl | 1 | PE FIFO 未滿時拉高；controller 在 S3 等待此信號 |
| `PEA_B_ready` | PE → ctrl | 1 | 所有 PE B-side FIFO 未滿（AND 邏輯） |

### controller → PPU（需組員實作接收端）

| 信號 | 方向 | 寬度 | 時序說明 |
|------|------|------|----------|
| `PEA_opsum_ready` | ctrl → PPU | 1 | S8_WAIT_PPU 期間高電位，授權 PPU 接收資料 |
| `relu_sel` | ctrl → PPU | 1 | `operation_mode[0]`，TrIP=1 啟用 ReLU |
| `Maxpool_en` | ctrl → PPU | 1 | 目前固定 0，預留 |
| `Maxpool_init` | ctrl → PPU | 1 | 目前固定 0，預留 |
| `ppu_done` | PPU → ctrl | 1 | **1-cycle pulse**，PPU 完成後 controller 進入 S9 |

### MC → PE Array（需組員實作接收端）

| 信號 | 方向 | 寬度 | 時序說明 |
|------|------|------|----------|
| `pe_data_valid` | MC → PE | 1 | GLB 讀取後延遲 1 cycle，資料有效 |
| `mc_glb_ren_A` | MC → GLB | 1 | GLB A 讀取請求（⚠️ 目前未連接到 GLB） |
| `mc_glb_addr_A` | MC → GLB | 16 | GLB A 讀取位址 |
| `mc_glb_ren_B` | MC → GLB | 1 | GLB B 讀取請求（⚠️ 目前未連接到 GLB） |
| `mc_glb_addr_B` | MC → GLB | 16 | GLB B 讀取位址 |

### Scan Chain（保留，目前 tied off）

| 信號 | 方向 | 寬度 | 說明 |
|------|------|------|------|
| `set_XID`, `set_YID`, `set_LN` | ctrl → PE | 1 | 固定 0 |
| `*_XID_scan_in` | ctrl → PE | 4 | 固定 0 |
| `*_YID_scan_in` | ctrl → PE | 4 | 固定 0 |
| `LN_config_in` | ctrl → PE | 15 | 固定 0 |

---

*最後更新：整合前版本，PE Array / NoC / PPU 尚未納入*