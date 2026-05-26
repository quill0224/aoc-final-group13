# Spec 待討論清單

> 規格沒定就動工 = 把整合災難往 Week 5 推。**先吵完再寫 code。**

---

## 1. Quantization scheme 是 symmetric 還是 asymmetric?

**為什麼重要**:bitmask sparsity 的「skip 0」邏輯只有在 **zero-point = 0** (symmetric) 時才正確。
若用 asymmetric (zero-point ≠ 0),INT8 中的「0」其實代表某個非零實數,bitmask 跳掉就答錯。

**提議**:採 **symmetric quantization**(`USE_SYMMETRIC_QUANT = 1` 已寫入 `trapezoid_pkg.sv`)。
楊承豫的 Python golden 必須用同一 scheme。

**待 owner**:楊承豫 + 黃妍心 confirm。

---

## 2. Partial sum 住在哪?Loop ordering 怎麼定?

**現況**:Proposal 4.4 算 C tile = 4 KB 在 SRAM。但:
- 256 PE × INT32 acc = 1 KB 在 register
- 32×32 output tile = 1024 個 cell,需 4 個 sub-pass 才填滿

**選項 A**:K-loop 跑完才 dump 16×16 → 換下一個 sub-tile
- SRAM 寫入頻率低,但要重讀 A/B (因為 A/B 在不同 sub-tile 對應不同範圍)

**選項 B**:每個 K cycle 累進 SRAM 中
- SRAM 讀寫負擔大
- PE accumulator 不用大 INT32,可以做小

**提議**:選 A。直接影響黃妍心的 acc_clear/acc_dump 訊號設計。

**待 owner**:黃妍心 + 陳秉弘 confirm,影響 Memory Controller。

---

## 3. 16 banks 給 Dense IP 同時 16 A + 16 B = 32 個 stream,怎麼解?

**現況**:Proposal 沒明寫 layout。

**選項**:
- (a) A/B 分時:throughput 砍半
- (b) A 複製到 8 個 bank,B 複製到 8 個 bank:浪費 SRAM 一半
- (c) 對 Dense IP 用 layout X,對 TrIP 用 layout Y(因為 TrIP 走 distribution net,本來就比較彈性)

**提議**:選 (c)。Dense IP 反正是 baseline,TrIP 才是主推。

**待 owner**:陳秉弘 主推。

---

## 4. Dataflow Controller (FSM) 由誰寫?

**現況**:Proposal 6.2 沒分到任何人。但 `top.v` 不能少這個。

**提議**:
- (a) 彭俞凱 兼(他做 MFIU,本來就要決定何時切 mode)
- (b) 楊承豫 兼(Python golden 要決定 mode,FSM 是它的 RTL 對應)
- (c) 拉一個小 timeline,每週輪人 review

**待決定**:Week 1 sync 必須 lock。

---

## 5. Top-level (`top.v`) 由誰主導?

**現況**:Proposal 6.2 沒分到任何人。

**提議**:**黃妍心** 主導。理由:
- PE Array 是中央,大部分內部訊號從 PE 進出
- 第一週寫 stub 版本(全模組 instantiate,空殼),確認 lint pass
- 之後每位隊友 PR 自己模組時,top.v 不太需要動

**待 owner**:黃妍心 confirm 接下來。

---

## 6. 測試 workload 要在 Week 1 就鎖定

**現況**:Proposal 提了 `ca-CondMat`(HS×HS 給 TrGT),但 Dense IP / TrIP 用什麼?

**提議**:鎖定 1-2 個小 workload,Week 1 就交給楊承豫產 golden:

| Mode      | Workload                            | 規模          |
|-----------|-------------------------------------|---------------|
| Dense IP  | 一層 FC (256 → 128, INT8)           | 32 KB weights |
| TrIP      | 同上 + ReLU + 50% pruning           | 16 KB weights |
| TrGT      | ca-CondMat (SuiteSparse)            | 已知          |

**待 owner**:楊承豫 主推。

---

## 紀律

- 每個項目必須 **指定 owner + 在某週前決定**
- 決定後寫進 `trapezoid_pkg.sv` 或 `interfaces.md`,不要只留在群組對話
- 還沒決定的不要先寫 code(會白工)
