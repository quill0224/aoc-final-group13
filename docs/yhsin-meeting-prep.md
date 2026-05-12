# 黃妍心 開會稿(個人用,不 commit)

> 開會時打開這份。上半「我講什麼」、下半「要全組決議的事」。

---

## 🗣️ 我這部分做了什麼(2 分鐘講完)

我把 16×16 PE Array 的初版 RTL 寫在 `feat/yhsin-pe_mac`,**已 push、還沒開 PR**。
比照 ISCA 2024 paper Fig 5/6 對齊,核心 4 個決定:

1. **`mac_unit`** 只做 INT8 mul,**不做累加** — 因為 per-mul acc 對 TrIP 模式不能用
2. **`pe_row`** 內部:16 mul + radix-16 merge tree(per-row)+ 1 個 INT32 row-level acc + B-forwarding latch
3. **`pe_array`** 用 B vertical forwarding(B 從 row 0 進、每 cycle 往下傳一條),省 16× input bandwidth
4. **Pipeline 7-stage**(Dense IP):S1 latch / S2 mul / S3-S6 tree / S7 acc;對齊 PPTX p.13

額外:`merge_tree_radix16` skeleton 我先寫了讓 lint pass,**module body owner 是施柏安**(per proposal §6.2),搬到了 `rtl/dist/`。

詳細看 `docs/yhsin-pe-mac-branch-notes.md` + `docs/architecture-deltas.md`。

---

## 🧪 目前狀態 / 之後怎麼測(30 秒)

| 已做 | 待做(Phase 1 結束前) |
|---|---|
| `tb_mac_unit.sv` 12 testcase 寫好(本機未跑通) | 在 Linux/Docker 跑 `make tb_mac` 確認 mac_unit 過 |
| RTL Verilator lint pass(預期) | 寫 `tb_pe_row.sv`(deterministic A·B vector vs numpy) |
| top.v 骨架接好 | 寫 `tb_pe_array.sv`(驗 B forwarding chain 16-cycle delay) |

⚠️ **重要 caveat**:`top.v` 裡 `a_grid` / `b_vec_top` 目前 hard-tied 為 0(等陳秉弘的 cache layout),所以 **functional sim 還跑不出真值**,只能 lint pass。要真正 end-to-end demo 必須等 §1 解。

---

## ❓ 要全組決議的事(我會主動帶討論)

### Q1 ★優先★ `dataflow_ctrl` FSM 誰認領?
- 是 orphan 模組(proposal §6.2 沒分配),但 top.v 不能少
- 我的提議:**彭俞凱兼**(他做 MFIU 最清楚 mode 切換時機)
- 不要拖,這條卡住 K-tile loop、acc_clear/dump 對齊、整個 demo flow

### Q2 ★優先★ Cache → PE Array 怎麼切片?(`interfaces.md §1`)
- PE array 一拍要 **2048 bits A** + 128 bits B,但 16 banks × 64-bit = 只有 1024 bits/cycle
- Owner: **陳秉弘** 主推
- 兩個方向:
  - (a) 在 cache 做 bank replication(浪費 SRAM 一半)
  - (b) 我在 top.v 加 K-stationary register file(A 一次 load,K-tile 內不重抓)
- 提議用 (b),但這部分要他點頭、可能他寫 / 我寫都行

### Q3 Δ4 per-row local buf 第幾週加?
- 第一版 Dense IP 不需要(我用 1 個 row-level acc 就夠)
- TrIP/TrGT/TrGS 才需要 4-bank scatter buf
- 兩個 owner 候選:**(a) 我在 pe_row 內加 / (b) 陳秉弘 在 global_buffer 切 sub-region**
- 不用今天決,但 Phase 2 開始(W5)前要鎖

### Q4 acc_dump timing 怎麼對齊 7-stage pipeline?
- pe_row 規定 acc_dump 必須在 in_valid 拉起後第 7 拍
- 這個 cycle counter 邏輯誰寫?跟 Q1 連動(dataflow_ctrl owner 寫)

### Q5 K > 16 時 K-tile loop 怎麼設計?
- 我 pe_row 已支援(acc_clear + 多次 acc_dump 可累加跨 K-tile)
- 但 K-tile 起點 / 終點訊號由誰產?也跟 Q1 連動

---

## 👤 直接 ping 各組員(會後私訊也行)

- **施柏安**:`rtl/dist/merge_tree_radix16.v` 我起草 skeleton,**body owner 是你**,可保留 / 重寫,port 不變即可。`tb_merge_tree.sv` 你寫。Phase 2 sub-tree slicing 給 TrIP 用,你設計。
- **彭俞凱**:`mfiu_top.v` 你的領土還是 stub。另外 dataflow_ctrl 認領請考慮(Q1)。
- **陳秉弘**:Q2 cache layout 需要你主推,以及 Δ4 (Q3) 你的選項。
- **楊承豫**:Python golden model 輸出格式請對齊 — 我這版每 row 出 1 個 INT32 dot product / cycle。
- **王柏弘**:`top.v` 對外 port 在 `rtl/top.v:23-37`,DRAM 細節你定我改。
- **組長**:我這 PR 還沒開(我自己再 review 一次),Q1-Q2 鎖了再開。

---

## 🛡️ 我不宣稱什麼(防被挑戰)

- 不宣稱 end-to-end inference 跑通(top.v cache 接線是 dummy)
- 不宣稱完整對齊 paper(MFIU/dist/local-buf 是 Phase 2)
- 不宣稱效能數據 — 256 GOPS 是理論值,沒 sim 實測
- 不宣稱寫了組員的 module — merge_tree 是 skeleton,body owner 是施柏安

---

## ⏱️ 開會節奏建議

1. (3 分鐘)我講「做了什麼 + 狀態」
2. (5 分鐘)Q1 dataflow_ctrl 認領 — 確認到人
3. (10 分鐘)Q2 cache layout — 跟陳秉弘鎖大方向
4. (5 分鐘)Q3-Q5 列出來但不今天解,訂下次要鎖的時間
5. (3 分鐘)各組員自己這週的 plan
