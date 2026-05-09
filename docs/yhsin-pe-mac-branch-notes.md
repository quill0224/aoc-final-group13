# `feat/yhsin-pe_mac` Branch Notes

> Branch owner: 黃妍心
> 用途: 給自己 / 組員 / 助教 review。**這不是正式 README**,
> 只是把這條 branch 目前做到哪、沒做到哪講清楚。

---

## 1. Branch Scope

這條 branch 的範圍是 **PE / MAC / PE row / PE array 的初步 RTL 架構**,
對應 proposal §6.2 的「16 × 16 PE Array 內部乘加單元與 Pipeline 管線設計」。

**範圍包含**:
- `mac_unit`、`pe_row`、`pe_array`、merge-reduction tree (per-row) 的 RTL 骨架
- `trapezoid_pkg.sv` 全域 parameter 與 pipeline stage 數
- `top.v` 把上述模組接起來,含其他組員的 stub 占位
- 模組間的 signal contract (`docs/interfaces.md`)
- 跟 ISCA 2024 paper 的對齊狀況 (`docs/architecture-deltas.md`)

**範圍不包含 (重要)**:
- ❌ Cache (16 SRAM bank) 到 PE array input 的 data layout / slicing 設計 — 由陳秉弘負責的 §1 待決議題
- ❌ Multi-Fiber Intersection Unit (MFIU) 真實邏輯 — 第二版 (TrIP) 才加,owner 彭俞凱
- ❌ A / B Distribution Network 真實邏輯 — 第二版才加,owner 施柏安
- ❌ Per-row Local Buffer (TrIP scatter buf) — Phase 2 處理 (見 architecture-deltas Δ4)
- ❌ Dataflow Controller FSM 真實邏輯 — orphan,Phase 1 結束前要認領
- ❌ End-to-end inference 跑通 — 目前 top.v 接到 cache 的線是 dummy (見 §4 Limitation)

換句話說:**這 branch 證明的是「PE row 內部結構與 16 條 row 之間的 B forwarding 寫對了」,不是「整個系統可以跑 VGG-8」。**

---

## 2. Files Changed

| 檔案 | 用途 | 狀態 |
|---|---|---|
| `rtl/pe/mac_unit.v` | INT8 × INT8 → INT16 multiplier (registered output)。**沒有 accumulator**。 | 新檔 |
| `rtl/pe/merge_tree_radix16.v` | 16-input pipelined adder tree,4 stage (16→8→4→2→1),per-row 用。 | 新檔 |
| `rtl/pe/pe_row.v` | 一條 PE row:16 個 mac_unit + 1 棵 merge tree + 1 個 INT32 accumulator + B-forward latch。 | 新檔 |
| `rtl/pe/pe_array.v` | 16 條 pe_row,B 從 row 0 進、垂直串到 row 15。 | 新檔 |
| `rtl/trapezoid_pkg.sv` | 全域 parameter (尺寸、位寬、tile size、ADFP SRAM 規格、pipeline stage 數)。 | 新檔 |
| `rtl/top.v` | 系統 top-level,instantiate dataflow_ctrl + global_buffer + pe_array,DRAM port 對外。 | 新檔 |
| `rtl/mfiu/mfiu_top.v` | MFIU 空殼 (彭俞凱 之後填)。Phase 1 不接線,占位用。 | 新檔 (stub) |
| `rtl/dist/distribution_net.v` | Distribution net 空殼 (施柏安)。Phase 1 不接線。 | 新檔 (stub) |
| `rtl/mem/global_buffer.v` | Cache 空殼 (陳秉弘)。Phase 1 輸出全 0。 | 新檔 (stub) |
| `rtl/ctrl/dataflow_ctrl.v` | Dataflow FSM 空殼 (orphan,待認領)。Phase 1 永遠 idle。 | 新檔 (stub) |
| `sim/tb_mac_unit.sv` | mac_unit 單元測試,12 個 testcase (mul-only 行為)。 | 新檔 (本機未跑通) |
| `docs/interfaces.md` | 模組間訊號契約 §1-§6,新架構版本。 | 新檔 |
| `docs/architecture-deltas.md` | 跟 ISCA paper 的差異紀錄,Δ1/Δ2/Δ3 已修,Δ4 deferred。 | 新檔 |
| `docs/spec_open_questions.md` | Phase 1 待決議題 6 條 (從 trapezoid-lite 帶過來)。 | 新檔 |
| `Makefile` | 根目錄 Makefile,提供 `make tb_mac` 與 `make lint`。 | 新檔 (本機未驗證) |
| `.gitignore` | 把 Python 慣例的 `dist/` 改成 anchor 到 repo 根 (`/dist/`),避免吃掉 `rtl/dist/`。 | 修改 |
| `rtl/.gitkeep`, `sim/.gitkeep` | 原本占位用,現在有實質檔案了所以刪掉。 | 刪除 |

---

## 3. Architecture Summary

### mac_unit (rtl/pe/mac_unit.v)
只做 INT8 × INT8 → INT16 乘法,registered output (1 cycle latency)。**沒有 accumulator**。
這個決定來自比對 paper Fig 6:paper 的累加是在 row 層級的 merge tree 之後,不是每個 multiplier 自帶一個 accumulator。
之前 (`trapezoid-lite` 初稿) 的 per-mul accumulator 設計對 Dense IP 還能 work,但 TrIP 模式下 multiplier 跟 (a_row, b_col) 的對應每 cycle 都會變,per-mul acc 會把不同 C cell 的部分結果混在一起,所以拿掉。

### pe_row (rtl/pe/pe_row.v)
一條 PE row 內部包含:
- 16 個 mac_unit 並排 (S2)
- 1 棵 radix-16 pipelined merge tree,4 stage (S3-S6)
- 1 個 INT32 row-level accumulator (S7)
- B-forwarding latch:把 `b_vec_in` 延 1 cycle 變成 `b_vec_out` 給下一條 row

加上輸入 latch (S1),Dense IP 一條 row 的 pipeline 共 7 stage,對齊 PPTX p.13 的設計圖。
A 是 row-stationary (從外部 register 直接接到 `a_vec`),不參與 forwarding。
`acc_clear` 用來開始新 dot product 時清零,`acc_dump` 用來在 K-tile 結束時把 acc 倒給 `c_out`,兩者由上層 dataflow_ctrl 對齊到 pipeline 第 7 拍。

### pe_array (rtl/pe/pe_array.v)
16 條 `pe_row` 上下疊起來。重點是 **B forwarding chain**:
- 外部只給 `b_vec_top`(16 個 INT8,送進 row 0)
- row 0 的 `b_vec_out` 接到 row 1 的 `b_vec_in`,row 1 接 row 2,以此類推
- 等於 B value 從 row 0 開始,每 cycle 往下傳一條 (Fig 4b TPU + Fig 7 step ④)

A 則由外部直接給每條 row 的 `a_grid[r]`,row-stationary 不串。
每條 row 各自輸出一個 INT32 dot product (`c_out[r]`),16 條 row → 16 個 C 元素 / cycle (穩態下)。

### Global merge tree 被移除
原本 `trapezoid-lite` 把 merge tree 放在 PE array 後面當 global module,接整個 16×16 partial sums。這個結構不對:
- Paper Fig 5 / Fig 6 都把 merge tree 畫在 **每條 PE row 內**,共 16 棵
- Global tree 在 TrIP 模式下無法每 cycle 同時產出多個不同 C 元素 (TrIP 的 effectual count 隨 bitmask 動態變,可能 1~16 個都有)

所以這版把舊的 `rtl/dist/merge_tree.v` 刪除,新增 `rtl/pe/merge_tree_radix16.v` 由 pe_row 內 instantiate。`rtl/dist/` 底下現在只剩 distribution_net stub。

---

## 4. Current Limitation

### 4.1 top.v 接到 cache 的線是 dummy

`rtl/top.v` 內,送進 `pe_array` 的兩條主要 data 線目前 hard-tied 為 0:

```verilog
assign a_grid    = '0;   // TODO 陳秉弘 + 黃妍心:從 bank_rdata 切片
assign b_vec_top = '0;   // TODO 陳秉弘 + 黃妍心:從 bank_rdata 切片
```

這代表:
- ✅ Verilator `--lint-only` 可以過 (語法、port 連接、unused 訊號都對)
- ✅ Synthesis 可以 elaborate (timing 不會錯,因為 datapath 完整)
- ❌ Functional simulation **不會跑出真實 inference 結果** —— PE array 只會收到全 0 → 永遠輸出 0
- ❌ 無法用「跑 VGG-8 看 accuracy」當作驗證

### 4.2 為什麼 cache → PE array 還沒接

這是 `docs/interfaces.md §1` 的待決議題:
- PE array 一拍要 16 row × 16 entry × INT8 = **2048 bits 的 A** + 16 × 8 = **128 bits 的 B**
- Global buffer 規格 16 banks × 64 bit/word = **每 cycle 最多 1024 bits**
- A 的需求 (2048 b) 超過 cache bandwidth 一倍,**需要陳秉弘設計 A register file (K-stationary) 或 bank replication 策略**
- 這部分由陳秉弘主導,黃妍心 配合在 top.v 加對應的 wiring

### 4.3 Phase 2 模組目前是 stub
`mfiu_top.v` / `distribution_net.v` / `global_buffer.v` / `dataflow_ctrl.v` 都是空殼。`top.v` 有 instantiate 它們是為了讓 `--lint-only` pass,真實邏輯在後續 PR 補上。

### 4.4 Testbench 本機沒跑通
`sim/tb_mac_unit.sv` 已寫 12 個 testcase,但筆者 (macOS) 還沒裝 iverilog 在本機跑通。需要在 Linux / Docker 環境用 `make tb_mac` 驗證,**這是 PR 進去前要做的事**。

---

## 5. How to Test

### 已寫
- ✅ `sim/tb_mac_unit.sv` — `mac_unit` 12 個 testcase:正/負/邊界 (`±127`, `−128`, `0`)、連續 16 拍序列、`en=0` hold、async reset。
  - 跑法:`make tb_mac` (需 iverilog)
  - **狀態:本機未跑通,需 Linux 驗證**

### TODO (Phase 1 結束前要補)
- ⏳ `tb_merge_tree.sv` — 餵已知 16 個 INT16,確認 4-stage 後 sum 對 (含正負混合、最大值不溢位、async reset 行為)
- ⏳ `tb_pe_row.sv` — 餵 deterministic A/B vector,確認:
  - 17 cycle 對應 (S1-S7 + 10 cycle K-tile),最後 `c_out` 等於 numpy `dot(a, b)`
  - `acc_clear` → 新 dot product 從 0 開始累加
  - `acc_dump` 對齊正確
  - `b_vec_out` = `b_vec_in` 延 1 cycle (forwarding 行為)
- ⏳ `tb_pe_array.sv` — 餵一條 B 進 row 0,確認:
  - 16 拍後 row 15 才看到 row 0 那一拍的 B (forwarding chain 累計 16 cycle 延遲)
  - 16 條 row 各自輸出獨立的 `c_out[r]`,且 `c_out[r]` 等於 numpy 的 `A[r,:] · B[:, n]`

### TODO (Phase 2 才加)
- 端到端跑 32×32 矩陣乘法 → 對 numpy 黃金模型 (需 `a_grid` / `b_vec_top` 接到 cache,屬 §1)
- 跑 VGG-8 一個 layer 的 inference (需要 dataflow_ctrl FSM 寫好)

---

## 6. Meeting Talking Points

### 投影片 1 — 「我這條 branch 寫了什麼」

**主題**: PE Array 內部 RTL 對齊 ISCA 2024 paper Fig 5/6 的初版

- **架構決策**
  - mac_unit 只做 INT8 mul,不做累加 (對齊 paper Fig 6;per-mul acc 在 TrIP 模式下不能用)
  - pe_row 內部含 16 mul + radix-16 merge tree (4 stage) + INT32 row-level acc
  - pe_array 用 B-forwarding chain:B 從 row 0 進、每 cycle 往下傳一條,符合 paper Fig 7 step ④
  - 移除原本錯誤的 global merge tree,改成 per-row 16 棵 (paper 是這樣畫的)
- **Pipeline**
  - Dense IP 7 stage (S1 latch / S2 mul / S3-S6 tree / S7 acc),對齊 PPTX p.13
  - 規模:256 MAC,500 MHz,256 GOPS peak (跟 proposal 一致)
- **規模**
  - 改檔: 16 個檔(11 個新 RTL/tb + 4 個新 docs + 1 個 .gitignore tweak)
  - 跟 paper 的 4 條 delta: Δ1/Δ2/Δ3 修了,Δ4 (per-row local buf) 留 Phase 2

### 投影片 2 — 「還沒做的事 + 待決議」

- **這 branch 還沒做**
  - top.v 裡 `a_grid`、`b_vec_top` 是 dummy (hard-tied 為 0) → lint 過,但 functional sim 跑不出真值
  - tb_pe_row、tb_pe_array、tb_merge_tree 還沒寫
  - 本機 (macOS) 沒裝 iverilog,連 `tb_mac_unit` 都還沒實際跑通,要 Linux / Docker 驗證
- **要全組決議的 4 件事 (Phase 1 結尾前必鎖)**
  1. `interfaces.md §1` — Cache 16 banks × 64 bit 怎麼切出 2048-bit/cycle 的 A?(陳秉弘 主推)
  2. `spec_open_questions.md §4` — `dataflow_ctrl` orphan FSM 認領 (建議彭俞凱兼)
  3. `architecture-deltas.md Δ4` — Per-row local buf 第幾週加?(影響 Phase 2 排程)
  4. K > 16 時 acc_clear / acc_dump 的 cycle counter 由誰寫 (建議 dataflow_ctrl owner)
- **這 branch 不宣稱什麼**
  - **不**宣稱 end-to-end inference 跑通
  - **不**宣稱完整對齊 paper (TrIP / Gustavson 的 MFIU、dist net、local buf 都還沒寫)
  - **不**宣稱效能數據 — peak 256 GOPS 是理論值,沒有 RTL sim 的實測
