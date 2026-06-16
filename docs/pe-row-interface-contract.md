# pe_row 資料路徑介面契約 — 要跟組員釘死的問題

> **目的**:`pe_row_full` 內的 **16→4 壓縮層** + **4-bank local buffer** 要做「正確版」,
> 必須先確定真 MFIU(楊承豫)/ 真 dist(QuillQ)的行為契約。
> 在這些答案確定前,壓縮層**只對 Dense IP 正確**(1 筆/拍);TrIP 一拍多筆時會**掉資料或撞 bank**。
>
> **對應程式**:`rtl/pe/pe_row_full.sv` 的 S8a(16→4 壓縮)、`rtl/pe/local_buffer_row.sv`(4-bank,每 bank 1 寫埠)。
> **狀態**:Dense IP 路徑已驗證(`make tb_pe_row_full` 全過 + 合成過 500MHz);以下是接真模組前要對齊的契約。

---

## ★ 最關鍵的一個數字(先問這個)

> **一拍最多會產生幾筆要寫進 local buffer 的結果(sub-tree sum)?**

- 這個數字決定 **bank 數 / 寫埠數 / 要不要序列化**。
- 目前壓縮層硬上限 = **4**(4 banks × 各 1 寫埠)。
- 若 **> 4** → 第 5 筆以後**被丟掉**(掉資料);若 **兩筆撞同一 bank** → 後者**寫不進去**。

---

## A. MFIU(`mfiu_adapter`)— 楊承豫

| # | 問題 | 為什麼要問 / 影響 |
|---|---|---|
| **A1** | `in_valid` → `meta_valid` 幾拍延遲? | 設 `trapezoid_pkg::MFIU_STAGES`,對齊我的延遲線(目前假設 **3**) |
| **A2** | 一拍最多幾個 `out_addr` 有效(= 幾個 sub-tree 結果)? | 見上方關鍵數字;> 4 必須序列化 |
| **A3** | 同一拍的有效 `out_addr`,會不會落在**同一個 bank**(`addr[1:0]` 相同)? | 撞 bank → 1 個寫埠寫不完 → 要序列化,或改 bank 映射保證不撞 |
| **A4** | `out_addr[i]` 跟 tree 的 `subtree_valid[i]` 是否**位置對齊**(第 i 個 sub-tree 的結果寫到 `out_addr[i]`)? | 壓縮層假設位置對齊(`ts_addr[i] = addr_aligned[i]`),不對齊就要改 |
| **A5** | `cut_after[i]=1` = 「位置 i 之後是子樹邊界」(Flexagon color/boundary)嗎? | 對齊 `reduction_tree_radix16` 的 cut 語意 |
| **A6** | `out_addr` 寬度 / 範圍 = output column index(0~511)? | 對齊 `LOCAL_BUF_AW` 與 buffer column |
| **A7** | `dataflow_sel` 編碼(IP / TrIP / TrGS / TrGT 的值)跟 `trapezoid_pkg` 一致? | 模式解碼正確 |

---

## B. Distribution(`dist_net_row`)— QuillQ

| # | 問題 | 影響 |
|---|---|---|
| **B1** | `in_valid` → `out_valid` 幾拍?(目前假設 `DIST_STAGES`) | 對齊延遲線 |
| **B2** | dist 會把 effectual 元素**壓到低 lane(compact)**,還是**原位散布**? | 影響 tree 的 sub-tree 落在哪個位置 → 是否還跟 `out_addr` 對齊(扣回 A4) |
| **B3** | Dense 是 **identity pass-through** 嗎?(目前這樣假設) | Dense 正確性 |
| **B4** | 純組合(0 cycle,我在外面打 1 拍)還是內含 pipeline? | 對齊 `DIST_STAGES` |

---

## C. 共同(決定壓縮層**架構**怎麼做)

| # | 問題 | 影響 |
|---|---|---|
| **C1** | pe_row 可不可以對上游**反壓**(stall MFIU/dist)? | 可 → 遇 >4 / 撞 bank 就序列化;不可 → 必須有夠多 bank/埠 |
| **C2** | 若要序列化,上游能不能**停拍等**(ready/valid 握手)? | 決定要加的 FSM + 握手介面長相 |

---

## 釘完之後我(妍心)要做的

1. 依 **A1 / B1** 真實 latency 改 `trapezoid_pkg::MFIU_STAGES` / `DIST_STAGES`,重跑 `make tb_pe_row_full` 確認功能還對。
2. 依 **A2 / A3 / C1** 把 16→4 壓縮層改成正確版:
   - 若契約**保證**「≤4 筆且不撞 bank」→ 直接接(現在這版就對,只要補保證)。
   - 若**可能 >4 或撞 bank** → 加序列化 FSM + 對上游反壓。
3. 擴充 testbench,涵蓋 **TrIP 一拍多筆** 的情況(目前只測 Dense 1 筆/拍)。
4. 接真模組後再合成一次 → 拿**真實面積 / timing**(stand-in 版數字嚴重低估,不能當終版)。

---

## 附:目前壓縮層的暫時假設(寫死在 `pe_row_full.sv` S8a)

```
// v1:依序收前 4 個 valid sub-tree → 4 lanes;buffer 用 addr[1:0] 路由到 4 banks
// 假設:同拍 ≤4 個 valid 且落不同 bank
// TODO:TrIP >4 / 同 bank → 序列化(等本契約 A2/A3/C1 答案確定)
```

這份問題清單的答案,就是把上面 TODO 變成正確實作的依據。
