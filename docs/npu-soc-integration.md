# NPU(Trapezoid-Lite 加速器)掛上 AIOC SoC — 整合筆記

> 記錄「我們的稀疏矩陣加速器(NPU)」要怎麼掛上組員(LichtExtx)建的 RISC-V SoC。
> 來源:組員系統 PR(系統架構圖 + AIOC System Spec)。
> 狀態:放在 `feat/yhsin-pe_mac`,**還沒 merge** —— 整合動工前先用來對齊全組認知。

---

## 1. 兩層架構(最關鍵的認知)

我們的加速器**不是獨立晶片**,而是掛在一整套 SoC 上的一個 **AXI slave**:

```
┌─ Host SoC(LichtExtx 的 PR,已寫好)──────────────────────┐
│  CPU(RV32IMF + Zbb,5-stage)+ L1 I/D cache + branch pred │
│  AXI4 BUS ──┬── DMA(scatter-gather)── WDT ── ROM ── DRAM │
│  (4 時脈域:cpu/axi/rom/dram_clk + CDC FIFO)              │
│             └── AXI Slave S6「EPU/NPU」槽 ───────┐        │
│                 (0x0005_0000~FFFF,現 tied-off)  │        │
└──────────────────────────────────────────────────┼────────┘
                                                    │ 掛上去
                          ┌─────────────────────────┴──────────┐
                          │  NPU = Trapezoid-Lite(我們團隊)     │
                          │  PE array + MFIU + dist + tree       │
                          │  + buffer + GLB + 控制 + AXI wrapper │
                          └──────────────────────────────────────┘
```

- **SoC = 平台**(組員建);**NPU = 我們的加速器**。
- **連接點 = AXI bus 上的 slave S6**(memory map `0x0005_0000 ~ 0x0005_FFFF`,目前 tied-off,就是留給我們掛的)。

---

## 2. 誰負責什麼

| 層 | 模組 | 負責 | 狀態 |
|---|---|---|---|
| **SoC** | CPU / AXI / DMA / WDT / ROM / DRAM / L1 cache / branch pred | LichtExtx | PR 已發 |
| **NPU 計算** | `mac_unit` / `merge_tree` / `local_buffer`(+SRAM macro)| 妍心 | ✅ 完成 + 合成過 500MHz |
| **NPU 計算** | MFIU | 楊承豫 | 🔶 妍心有 stand-in,等真版 |
| **NPU 計算** | distribution(Benes 16×16)| QuillQ | 🔶 stand-in,等真版 |
| **NPU 整合** | `pe_row_full` → PE array(16×)| 妍心 | ⬜ 待做 |
| **NPU 對外** | **`NPU_wrapper`(AXI slave 介面)** | ❓ 待分工 | ⬜ **新增、必須** |
| **NPU 控制** | top controller(dataflow FSM / tile loop)/ GLB(16KB)| ❓ 待分工 | ⬜ |

---

## 3. 兩層記憶體(不衝突,別搞混)

| 記憶體 | 屬於 | 用途 |
|---|---|---|
| ROM / DRAM(2MB)/ IM·DM SRAM / L1 cache | **SoC**(組員)| CPU 程式 + 資料最終存放 |
| **GLB(16KB)/ local buffer / B FIFO** | **NPU**(我們)| 加速器內部運算用的快取 / 累加器 |

資料流:**DRAM →(DMA over AXI)→ NPU 的 GLB → 算 → 寫回 DRAM**。
組員寫的「memory」是 SoC 那層(DRAM/ROM/SRAM/cache),跟我的 buffer 是**不同層、互補、不重複**。

---

## 4. NPU 怎麼掛上去(AXI Slave S6)

- NPU 當 **AXI slave**,位址 `0x0005_xxxx`(ADDR[31:16] 解碼路由)。
- **CPU 寫控制暫存器**(start / mode / tile 維度 / GLB 位址 / config)到 NPU、讀 status / done。
- **資料搬運**:用 SoC 的 **DMA(Master M2,scatter-gather + 16-word FIFO)** 把 DRAM 的 A/B tile 搬進 NPU 的 GLB,算完再搬回 DRAM。
- **時脈 / CDC**:NPU 掛在 `axi_clk` 域(或自己 npu_clk),AXI 邊界要 CDC(SoC 已有 `async_CDC_1/4/16`、`ONE_CDC` 可參考)。

> ❓ 關鍵設計問題:NPU **只當 slave**(被 CPU/DMA 餵資料),還是**也要一個 AXI master port**(自己去 DRAM 抓大 tile)?大矩陣的話 master 較有效率,但較複雜。要團隊決定。

---

## 5. 因此「新增」要做的(NPU 對外接口)

1. **`NPU_wrapper.sv`(AXI slave)** — 解 AXI 讀寫 → 對應 NPU 的控制暫存器 + 資料介面。**「掛上去」的核心,目前沒人認領。**
2. **控制暫存器定義** — start / mode(IP/TrIP/TrGS/TrGT)/ tile 維度(M,N,K)/ GLB 位址 / done 中斷。
3. **(可能)AXI master port** — 若 NPU 要自己抓 DRAM(見 §4 問題)。
4. **目錄**:加速器搬進 `src/NPU/`(組員建議)。

---

## 6. 我(妍心)目前狀態 + 剩下的

- ✅ **完成 + 合成過 500MHz**:`mac_unit`(88µm²)、`reduction_tree_radix16`(2034µm²)、`local_buffer_row` + `sram_128x32_1r1w`(macro 版 13733µm²,Macro Count 4)
- ⬜ **剩下**:`pe_row_full` 整合(tree 16-lane → buffer 4-lane 的壓縮 + `clear→first_pass`)、PE array(16× pe_row + B 縱向鏈)
- ⏳ 接真 MFIU(楊承豫)/ dist(QuillQ)時:對齊 latency(改 `trapezoid_pkg::MFIU_STAGES`)

---

## 7. 要跟組員確認的問題(整合前釘死)

1. **`NPU_wrapper`(AXI slave)誰寫?** 控制暫存器怎麼定義?
2. **資料路徑**:DMA 把 DRAM→GLB 搬好餵 NPU,還是 NPU 自己當 master 去抓?
3. **NPU 時脈域 + AXI 邊界 CDC** 誰處理?
4. **目錄 + merge 順序**:加速器搬 `src/NPU/`?怎麼跟我的 `feat/yhsin-pe_mac` branch 不衝突?
5. **GLB(16KB)/ top controller** 誰負責?

---

## 8. 整合順序(組員建議)

> 「新增系統及架構模組… 請把 AI 加速器(NPU)掛在這個系統上面… 等到功能寫完之後再一起進行 RTL 驗證、合成、APR 會比較方便。」

1. 各自把功能寫完(NPU 計算元件 + `NPU_wrapper` + SoC)。
2. 把 NPU 掛上 AXI **S6**(`0x0005_xxxx`)。
3. 整顆一起:RTL 驗證 → 合成 → APR。

---

## 重點摘要

- 我的計算元件(MAC / tree / buffer)是 **NPU 的運算心臟,沒白做**;SoC 再完整也要靠這塊算。
- 改變的只是:**外面多了一層 SoC,NPU 要透過 AXI(slave S6)掛上去** → 多一個 `NPU_wrapper` 接口要寫(待分工)。
- 我的下一步仍是 **pe_row 整合 + PE array**;整合進 SoC 是更後面、全組一起的事。
