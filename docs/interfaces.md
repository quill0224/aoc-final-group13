# Trapezoid-Lite 模組間訊號契約

> 改任何一條訊號定義之前,**請先在群組講** —— 因為你會打到接這條線的隊友。

對齊 ISCA 2024 paper Fig 5/Fig 6 的整體資料流向 (Phase 1 Dense IP MVP):

```
DRAM ↔ Memory Controller (陳秉弘) ↔ Cache: 16 SRAM Banks (陳秉弘)
                                          │
                                          ↓
                              (cache 切片給 a_grid + b_vec_top)
                                          │
                                          ↓
                                PE Array (黃妍心)         ← 16 條 PE row,B 跨 row 垂直 forwarding
                                  ├─ pe_row[0]              row 內含: 16 mac_unit + radix-16 merge tree + acc + B-forward latch
                                  ├─ pe_row[1] ←B 從 row 0 forward 進來
                                  ├─ ...
                                  └─ pe_row[15]
                                          │
                                          ↓
                                    16 個 c_out (each INT32)
                                          │
                                          ↓
                                  寫回 SRAM (陳秉弘)
```

**Phase 2 (TrIP+) 才會在 pe_row 內加**:MFIU、A/B Distribution Network、per-row Local Buf。
這些目前是 **per-row** 設計 (對齊 paper Fig 6),不是 global module。

每段介面用 ✅ 標示已 lock 的、❓ 標示待討論的。

---

## §1 Cache → PE Array (陳秉弘 → 黃妍心)

✅ **訊號 (Phase 1 Dense IP MVP)**:

| 訊號          | 方向       | 寬度                       | 說明 |
|---------------|-----------|----------------------------|------|
| `a_grid[r][m]` | 給 PE    | `[16][16][7:0]` signed     | row r 的第 m 個 INT8 a (row-stationary,跨 K-tile 不變) |
| `b_vec_top[m]` | 給 PE    | `[16][7:0]` signed         | row 0 此 cycle 的 16 個 INT8 b;會自動 forward 給 row 1, 2, ... |

❓ **a_grid 怎麼從 16 個 SRAM bank 切出來** → 陳秉弘 設計 layout:
- 16 row × 16 entry × INT8 = 2048 bit/cycle 讀出
- 16 banks × 64-bit/word/cycle = 1024 bit/cycle bandwidth
- **不夠** → 用 bank-replication 或 K-stationary register file (黃妍心 在 top.v 內加)
- 第一週 sync 必須鎖

❓ **b_vec_top 從 SRAM 讀的 layout**:也要陳秉弘 設計

---

## §2 PE Array → Cache (黃妍心 → 陳秉弘)

✅ **訊號**:

| 訊號         | 方向    | 寬度                 | 說明 |
|--------------|---------|----------------------|------|
| `c_valid[r]` | 從 PE 出 | `[16]` 1 bit each    | row r 的 dot product 完成,本 cycle 寫回有效 |
| `c_out[r]`   | 從 PE 出 | `[16][31:0]` signed  | row r 的 INT32 dot product |

❓ **寫回時機**:`c_valid` 由 `acc_dump` 控制,目前廣播給所有 row。
若要做 staggered output (各 row 不同時 dump),要把 acc_dump 改 per-row signal (`[16]` 寬度)。

---

## §3 PE Row 內部 (黃妍心 自己一條 row 的契約)

✅ **訊號 (對齊 paper Fig 6)**:

| 訊號           | 方向 | 寬度                | 說明 |
|----------------|------|---------------------|------|
| `in_valid`     | in   | 1 bit               | a_vec / b_vec_in 此 cycle 有效 |
| `acc_clear`    | in   | 1 bit               | 清零 row 內 accumulator (新 dot product 開始前用) |
| `acc_dump`     | in   | 1 bit               | 此 cycle 把 acc 倒給 c_out (對齊到 in_valid 拉起後第 7 拍) |
| `a_vec`        | in   | `[16][7:0]` signed  | row 內 16 個 INT8 a,row-stationary |
| `b_vec_in`     | in   | `[16][7:0]` signed  | 從上一條 row 來,1 cycle 後 forward 給下一條 |
| `b_vec_out`    | out  | `[16][7:0]` signed  | 給下一條 row;= b_vec_in 延 1 cycle |
| `b_valid_out`  | out  | 1 bit               | b_vec_out 對應的 valid (= in_valid 延 1 cycle) |
| `c_valid`      | out  | 1 bit               | c_out 此 cycle 有效 |
| `c_out`        | out  | `[31:0]` signed     | INT32 dot product (acc 在 dump 拍倒出) |

✅ **Pipeline (Dense IP, 7 stages)**:
```
S1 latch_in → S2 mul → S3 tree[1] → S4 tree[2] → S5 tree[3] → S6 tree[4] → S7 acc/out
```

---

## §4 Dataflow Controller → PE Array (待認領 → 黃妍心)

❓ **Owner 待認領** (見 spec_open_questions.md #4)。介面契約:

| 訊號           | 方向 | 寬度  | 說明 |
|----------------|------|-------|------|
| `pe_in_valid`  | out  | 1 bit | 廣播給 pe_array 所有 row (Phase 1) |
| `pe_acc_clear` | out  | 1 bit | 廣播 |
| `pe_acc_dump`  | out  | 1 bit | 廣播。**必須對齊 in_valid 拉起後第 7 拍**,否則 c_out 抓到舊 acc |
| `dataflow_sel` | out  | 2 bit | `2'b00` Dense IP / `2'b01` TrIP / `2'b10` TrGT / `2'b11` TrGS |

❓ **K > 16 的 K-tile loop 怎麼做**:K-tile 起點 `acc_clear`,K-tile 結束 `acc_dump`,
中間每拍 `in_valid`。FSM 裡的 cycle counter 由 dataflow_ctrl owner 設計。

---

## §5 SRAM ↔ DRAM (陳秉弘 內部)

❓ **大塊待討論** (見 spec_open_questions.md #3):
- Dense IP 同時要 16 個 A row + 16 個 B col stream,16 banks 怎麼分?
- 解法:layout 預先 replication 還是 time-mux?

---

## §6 Phase 2 預留:per-row MFIU + Distribution Network + Local Buf

對齊 paper Fig 6,這些都是 **per-row** module,在 pe_row 內 instantiate (不是 global)。

### MFIU (彭俞凱) — per-row

| 訊號                   | 方向 | 寬度          | 說明 |
|------------------------|------|---------------|------|
| `a_bitmask[N_A_FIBER]` | in   | `[4][16]` bit | 4 列 A 的 bitmask |
| `b_bitmask[N_B_FIBER]` | in   | `[4][16]` bit | 4 行 B 的 bitmask |
| `effectual_idx`        | out  | `[16][4:0]`   | 每位有效運算的索引 (給 dist net 路由) |
| `effectual_count`      | out  | `[4:0]`       | 此 cycle 有效運算數 (給 dynamic B packing) |

### Distribution Network (施柏安) — per-row × 2 (A/B 各一)

❓ **位寬待定**:依 fiber packing 數而變。
❓ **Benes 還是 crossbar**:第二版決定。

### per-row Local Buf (黃妍心 / 陳秉弘 共決) — per-row

❓ **位置**:在 pe_row 內 (paper) 還是切到 cache 內模擬 (簡化分工)。
- (a) pe_row 內加:最貼 paper,黃妍心 owner
- (b) global_buffer 內切 16 個 sub-region:分工最少,陳秉弘 owner

---

## 使用本文件的紀律

1. PR 動到任何一個 module 的 port,必須同步動到本文件對應條目
2. 每週 sync meeting 第一件事:walk through 還沒 ✅ 的條目
3. ✅ 表示「兩個 owner 都同意了」,不是「我自己覺得這樣可以」
