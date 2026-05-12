# 第 13 組 — 討論點清單

> **這份文件用途**:整理目前 RTL / Spec / Memory / Workload 等需要全組對齊的討論點。

---

## 📖 0. 背景摘要
ISCA 2024 一篇論文叫 **Trapezoid**(Yang et al.),它做一顆 AI accelerator,主打**同時處理 dense 跟 sparse 矩陣**。我們是從這篇 paper 縮一個簡化版出來,跑 VGG-8 (CIFAR-10 INT8 量化)。

**Trapezoid 的核心想法**:
傳統 systolic array (像 Google TPU) 跑 dense 矩陣很強,但矩陣有 sparsity 時會浪費。Trapezoid 在每個 PE row 加一個「multi-fiber intersection unit (MFIU)」+ 兩個 distribution network,**動態跳過零的計算**。

**4 個 dataflow 模式**:
- `Dense IP` — 純稠密矩陣,跟 TPU 類似(**最容易,我們先做**)
- `TrIP` — 雙邊 mildly sparse(MS×MS),Trapezoid 主打
- `TrGT` — 高度稀疏(HS×HS),靠 Gustavson 切時間
- `TrGS` — 高度稀疏(HS×D),靠 Gustavson 切空間

**主要架構參數**(proposal §4.2):
| 項目 | 數值 | 為什麼 |
|---|---|---|
| PE Array 大小 | **16×16 = 256 MAC** | ADFP 製程 P&R 限制(paper 是 128×128,我們縮 64×) |
| 量化 | **INT8 對稱量化** | proposal 既定;mac_unit 已寫 |
| 時脈 | **500 MHz** | ADFP 28nm 容易過 timing |
| 全域 SRAM | **16 banks × 1 KB = 16 KiB** | ADFP Memory Compiler 給的最大 hard macro 是 1 KB |
| Tile 大小 | **32×32** | 一次算 32×32 的 C tile,working set 6.25 KB |

**RTL 分工**(per proposal §6.2):
| 模組 | Owner |
|---|---|
| MFIU (sparse 用) | 彭俞凱 |
| **PE Array + Pipeline** | **黃妍心 (Iris)** |
| Distribution Network + Merge Tree | 施柏安 |
| Global Buffer + Memory Controller | 陳秉弘 |
| Python Golden Model (量化 + bitmask) | 楊承豫 |
| Verilator Wrapper + Testbench | 王柏弘 |
| Dataflow Controller | **Phase 1 可由 王柏弘 wrapper 兼;Phase 2 待認領(見 Q4)** |

---

## 🔥 討論點

### Q1. Phase 1 / Phase 2 / Phase 3 範圍鎖定

**為什麼是個問題**:
proposal §6.3 列了 3 個範圍 (MVP / 目標 / 挑戰),但**沒明確說「我們組做哪個」**。範圍沒鎖,每個人不知道自己 module 要寫到什麼程度。

**Iris 寫的 RTL 已經默認 Phase 1 = Dense IP MVP**,但這要團隊 confirm。

**選項**:
- **A. 只做 Phase 1 (Dense IP)** — 4-5 週,最保險,proposal 寫的 MVP
- **B. Phase 1 + Phase 2 (Dense IP + TrIP)** — 6-7 週,覆蓋 paper 最大新意,proposal 主推
- **C. 加做 TrGS (Phase 3)** — 8-10 週,雄心壯志但風險高

**Iris 建議**:**先承諾 A,實際做到 B,不公開承諾 C**(進度超前再加碼)。

**今天要決議**:Phase 1 / Phase 2 各週數估算,以及鎖一個版本。

---

### Q2. PE Array 16×16 是不是真的 lock?

**為什麼是個問題**:
Jacky 提過「16×16 對 hz 比較好」,proposal 也這樣寫,但**沒有正式團隊共識說「不能再改」**。如果之後有人想改成 8×8 或 32×32,所有 RTL 跟 spec 都要動。

**目前狀況**:
- `analysis/sweeps/pe_sweep.py` 已跑過 sensitivity sweep,baseline 結果在 `analysis/results/baseline/`
- proposal §4.2 寫了選 16×16 的理由(ADFP 製程 P&R 限制 + 500 MHz timing 容易過)
- Iris 寫的 RTL 已經把 16 hard-code 進 `trapezoid_pkg.sv`(用 parameter 包,改也只改一個地方)

**今天要決議**:**正式宣告 16×16 lock,以後不討論**(除非有強證據要改)。

---

### Q3. FC layer 怎麼處理?

**為什麼是個問題**:
VGG-8 後段有 3 個 FC layer,**memory 行為跟 Conv 完全不同**。團隊目前的 GLB 規格(16 KiB)是按 Conv layer 設計的,FC layer 會撞牆。

**為什麼 Conv 跟 FC 不一樣?關鍵字:weight reuse**

**Conv layer 範例 (VGG-8 Conv6)**:
- Weights 共 576 KiB
- 每個 weight 用幾次?= 8 × 8 = **64 次**(因為輸出 spatial 是 8×8,每個 weight 在不同空間位置都用過)
- 結果:**從 DRAM 抓 1 byte → 做 64 個 MAC**,DRAM 流量被攤掉
- 16 KiB GLB 只要裝下一個 32×32 tile (約 6 KiB) 就好,**不會卡 memory**

**FC layer 範例 (VGG-8 FC6, 4096 → 256)**:
- Weights 共 1 MiB(整整 1 MB,**比 Conv6 大 2 倍**)
- 每個 weight 用幾次?= **1 次**(每個 weight 對一個 input feature 算一次,然後就丟了)
- 結果:**從 DRAM 抓 1 byte → 做 1 個 MAC**,完全沒攤掉
- **GLB 就算放大到 1 MiB(64 倍大),DRAM 流量還是 1 MiB**(因為每張 inference 都要重新抓一次 weight)

**所以 FC 的本質瓶頸是 DRAM 頻寬,不是 GLB 大小。**

**目前團隊狀況**:
- `analysis/sweeps/fc_analysis.py` 已經算過 GLB 16 KiB 跟 64 KiB 兩種的 tile 數量(16 KiB GLB → FC6 需 103 個 tile)
- `docs/proposal-v2-patch.md` 寫了結論,但**沒進深度討論**
- Jacky 5/5 訊息「16 KB 算過後夠用」可能只看了 Conv 那邊

**選項**:
- **A. 接受 FC memory-bound,demo 時就承認「FC 是 DRAM-limited」** — 最務實
- **B. 不跑 FC,只 demo Conv layer** — 簡化但失去完整 inference
- **C. Phase 2 加 weight stationary 模式 (TrGS-like) 讓 FC 跑** — 最理想但工程量大

**Iris 建議**:**A**。報告時直接說 FC layer 跟 Conv layer 是兩個工作模式,FC 是 memory-bound 但這是 VGG-8 的本質,不是我們架構的問題。

**今天要決議**:能不能接受 A?如果不行,誰要主導 B 或 C?

---

### Q4. Phase 1 控制邏輯放哪?(wrapper 還是 RTL FSM?)

**為什麼是個問題**:
PE array 需要 3 個控制訊號:`pe_in_valid`、`pe_acc_clear`(K-tile 起點清零)、`pe_acc_dump`(K-tile 結束倒 c_out)。proposal §6.2 沒人分到 dataflow_ctrl,**但其實 Phase 1 (Dense IP MVP) 不一定要寫 RTL FSM**。

**這 3 個訊號的兩個來源選項**:
- **A. Verilator wrapper 直接驅動**(王柏弘 在 C++ 那邊寫 timing pulse)
  - 例如:`for cycle in range(K): pe_in_valid=1; if cycle==0: acc_clear=1; if cycle==K-1: acc_dump=1`
  - 不寫 RTL FSM,`rtl/ctrl/dataflow_ctrl.v` 留 stub
  - 王柏弘 本來就要寫 testbench driver,加 control pulse 是順手的事
- **B. 寫一個 minimal RTL FSM**(50-100 行)
  - 一個 cycle counter + 3 state(IDLE → COMPUTE → DRAIN)
  - 需要認 owner;Iris 推薦彭俞凱(他做 MFIU,Phase 2 mode 切換也順手)

**Phase 2 (TrIP) 必須寫 RTL FSM**(對 cycle 敏感的決策不能放 wrapper),這條等 W5 開始前再認領就好。

**Iris 建議**:Phase 1 走 A,Phase 2 認 owner 寫 RTL FSM。

**今天要決議**:Phase 1 走 A 還是 B?如果 A,王柏弘 要不要接這部分 C++ driver?

---

### Q5. Cache → PE Array 怎麼連線?(NoC 設計)

**為什麼是個問題**:
PE array 一拍要 **2048 bits 的 A**(16 row × 16 entry × INT8) + 128 bits 的 B,但 GLB 提供 16 banks × 64-bit/word/cycle = **1024 bits/cycle**。**bandwidth 不夠**。

**目前狀況**:
- Iris 的 `top.v` 把 `a_grid` 跟 `b_vec_top` hard-tied 為 0(等這條解才能接線)
- `docs/interfaces.md §1` 把這個列為 ❓

**選項**:
- **A. Cache 內做 weight replication**(把 A 複製 2 份到不同 bank)— 浪費 SRAM 一半
- **B. 在 top.v 加 K-stationary register file**(A 一次 load 進 register,K-tile 內不重抓)— Iris 偏好
- **C. 縮減 throughput 改成 1 PE row at a time**(每拍只算 1 row)— PE 利用率掉 16×

**owner**:陳秉弘 主推(global_buffer 介面);Iris 配合(在 top.v wiring)。

**今天要決議**:
- 至少先決方向(A / B / C),不用今天解到細節
- 或排一個「**陳秉弘 + Iris**」的小會 deep-dive

---

## ⚙️ 第二部分:Iris 寫 RTL 時做了的決定(請確認)

> 這些是 Iris 為了讓 PR 可以 ship 而做的設計決定。
> 動到別人領土 / 影響 spec 的部分,**請確認你能接受**。
> 不接受的可以提替代方案,但要提出時間點。

### S1. INT8 對稱量化(zero-point = 0)
- **影響誰**:楊承豫(Python golden 必須用同 scheme)、彭俞凱(MFIU bitmask 邏輯)
- **為什麼**:**bitmask 跳過零**只在對稱量化時才正確(zero-point = 0 的話,INT8 的 0 真的代表 0)。Asymmetric 的話 INT8 0 可能代表非零實數,跳過會算錯
- **目前**:`trapezoid_pkg.sv` 寫死 `USE_SYMMETRIC_QUANT = 1`
- **替代方案**:asymmetric → bitmask 邏輯要重做

### S2. Pipeline Dense IP = 7 stages, TrIP = 9 stages
- **影響誰**:Phase 1 control 來源(王柏弘 wrapper 或 dataflow_ctrl owner)— 必須對齊 acc_dump 到第 7 拍;施柏安(merge tree 4 stages)
- **為什麼**:對齊 PPTX p.13/p.14。**改了的話 acc_dump timing 邏輯要全重算**
- **目前**:`trapezoid_pkg.sv` 寫 `IP_STAGES=7`, `TRIP_STAGES=9`

### S3. mac_unit 不做累加,累加在 PE row 層級
- **影響誰**:無(只有 Iris 自己的 module)
- **為什麼**:per-mul accumulator 在 TrIP 模式下不能用(動態 mul-to-(a_row, b_col) 對應)
- **替代方案**:無(這是 paper 的標準設計)

### S4. Merge-Reduction Tree 是 per-row(16 棵),不是 global
- **影響誰**:**施柏安**(原本 owner,以為要寫 1 棵 global tree)
- **為什麼**:對齊 paper Fig 5/6(per-row);global tree 在 TrIP 模式下無法每 cycle 多輸出
- **目前**:`rtl/dist/merge_tree_radix16.v` 是 Iris 起草的 skeleton,owner 還是施柏安,他可以保留 / 重寫
- **替代方案**:無(global tree 寫死 dataflow,沒擴充性)

### S5. B 跨 row vertical forwarding(B 從 row 0 進、每 cycle 往下傳一條)
- **影響誰**:**施柏安**(distribution net 不用送 16 條 B,只送 1 條)
- **為什麼**:對齊 paper Fig 4b/Fig 7;**省 16 倍 input bandwidth**
- **替代方案**:fully parallel(每 row 從 cache 直接讀 B)→ cache bandwidth 不夠,行不通

### S6. A row-stationary(A 放在每 row 自己的 register file,不流動)
- **影響誰**:陳秉弘(SRAM bank → A register file 的 load 機制)
- **為什麼**:對齊 paper Fig 4b;A 流動會增加 PE 內部 wiring
- **替代方案**:A streaming + B stationary(symmetric design,但要重寫所有 control)

### S7. acc_clear / acc_dump Phase 1 廣播給所有 row,Phase 2 才改 per-row
- **影響誰**:Phase 1 control 來源(看 Q4 結果決定是 王柏弘 wrapper 還是 RTL FSM)
- **為什麼**:Dense IP 所有 row 同時做完一個 K-tile,可以全 row 同步;TrIP 才會有 staggered 行為
- **替代方案**:Phase 1 直接做 per-row(增加複雜度,沒必要)

### S8. `merge_tree_radix16` skeleton owner = 施柏安
- **歷史**:Iris 為了讓 pe_row 能 lint pass,先起草了一份 4-stage tree 邏輯,放在 `rtl/dist/merge_tree_radix16.v`
- **現在**:**body 屬於施柏安**,他可以:
  - 保留(若認為 OK)
  - 完全重寫(用自己 micro-arch)
  - 加 testbench(`tb_merge_tree.sv` 由施柏安寫)
- **port 不變的話 Iris 這邊的 pe_row 完全不用改**

---

## 🔮 第三部分:Phase 2 之前要決議的事(暫時不急)

### F1. Per-row Local Buffer (paper Fig 6 的 "Buf")
- 何時加:Phase 2 開始前(W5 左右)
- Owner 候選:(a) Iris 在 pe_row 內加 / (b) 陳秉弘 在 global_buffer 切 16 個 sub-region
- 影響:TrIP 的 scatter-write C 結果

### F2. MFIU 規模(per-row 16 棵 vs 1 棵 global)
- 為什麼是個問題:proposal §4.2 寫的是「最大之 Two-port SRAM」,沒明確說 MFIU 是 per-row 還是 global
- paper Fig 6 是 per-row;**這影響 彭俞凱 的 MFIU module 介面 + Iris 把它 wrap 進 pe_row 的方式**
- 何時決議:彭俞凱 開始寫 MFIU body 之前(建議 W3)

### F3. TrIP merge tree sub-tree slicing
- 何時加:Phase 2,當 TrIP 上線
- Owner:施柏安
- 影響:tree 要支援動態切成 radix-2/4/8 的 sub-tree(paper §III.B)
```
---
## 重點圖
| paper Figure | 看什麼 |
|---|---|
| Fig 5 | 整體架構 — 16 條 PE row 上下疊,跟 cache 連 |
| Fig 6 | **PE row 內部** — MFIU + dist net + mul + tree + buf,**這是我們複製的單位** |
| Fig 4b | TPU dense dataflow — A 留 PE,B 往下流(我們抄這個) |
| Fig 7 | Trapezoid 的 Dense IP 跑法 — 步驟 ④ 是 B 跨 row forwarding |
| Fig 11 | TrIP 的 MFIU 內部 — 4×4 bitmask AND + prefix sum + shift |

