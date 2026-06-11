# PE Row RTL 程式碼導讀

> 對象:修過數位電路 / Verilog 的人(知道 register、mux、adder、FSM、pipeline)。
> 目的:把 `local_buffer_row.sv`、`merge_tree_radix16_flexagon.sv`、`pe_row_full.sv`
> 三個檔的**功能、結構、用到的 SystemVerilog 語法、以及「為什麼這樣寫」**講清楚。
>
> 三個檔的關係(由小到大):
>
> ```
> pe_row_full.sv  ── instantiate ──┬─ mac_unit.sv              (×16,乘法)
>  (8-stage 組裝)                  ├─ mfiu_row.sv              (交集,介面)
>                                  ├─ dist_net_row.sv          (routing, Benes)
>                                  ├─ merge_tree_radix16_flexagon.sv  (化簡)★
>                                  └─ local_buffer_row.sv      (輸出緩衝)★
> ```
>
> 本文詳述標 ★ 的兩個 + 最外層的 `pe_row_full`。

---

## 0. 先看共通的 SystemVerilog 語法

這三個檔用到一些跟大學「Verilog-2001」課堂不太一樣的寫法,先集中講,後面就不重複。

### 0.1 `logic` 取代 `reg` / `wire`

SV 的 `logic` 是 4-state 型別,可以同時被 `assign`(組合)或 `always` 區塊驅動,
編譯器自己判斷。**不用再煩惱該宣告 `reg` 還是 `wire`**。唯一限制:同一條 `logic`
不能被兩個來源同時 drive(multi-driver),這點跟 `wire` 一樣。

### 0.2 packed array vs unpacked array(最容易混淆,務必搞懂)

```systemverilog
logic signed [N_MUL_ROW-1:0][PROD_W-1:0] partials;  // packed 2-D
logic signed [ACC_W-1:0]                 mem [LOCAL_BUF_DEPTH];  // unpacked
```

| | packed `[A][B] name` | unpacked `name [A]` |
|---|---|---|
| 維度寫的位置 | 在名稱**前面** | 在名稱**後面** |
| 物理意義 | 連續 bit 擠在一條匯流排(`partials` = 256 bit 一整包)| 一組獨立的變數/記憶體格 |
| 可否整包傳給 port | ✅ 可(當一個大向量)| ❌ 不行(要逐格)|
| 可否對「整包」做算術 | ✅(`partials + x`)| ❌ |
| 適合 | 訊號匯流排、要 bit-select 的資料 | 記憶體陣列、pipeline 各級暫存 |

**為什麼三個檔混用兩種**:port 上的資料(`partials`、`subtree_sums`)要當匯流排傳,
用 packed;內部的 SRAM、pipeline 各級暫存用 unpacked。

### 0.3 ⚠️ iverilog 的雷:packed array + 變數 index + always 區塊

模擬器 iverilog 對「在 `always` 區塊裡,用**變數**(迴圈變數)去 index packed array、
再做 bit-select」會報錯。三個檔都用同一個**安全 pattern** 避開:

```systemverilog
// 先用 generate(常數 index)把 packed 轉成 unpacked
genvar g;
generate
    for (g = 0; g < N_MUL_ROW; g = g + 1) begin : g_unpack
        assign sums_u[g] = subtree_sums[g];   // g 是常數,安全
    end
endgenerate
// 之後 always 區塊只碰 unpacked 的 sums_u[i],i 是變數也沒事
```

看到 `g_unpack` 這種 generate-assign 區塊,就是在做這件事。

### 0.4 `genvar`/`generate` vs `integer`/`for`

- **`genvar` + `generate`**:**編譯期(elaboration)**展開,等於把迴圈手寫攤平。
  index 是常數 → 用來複製硬體結構(16 個 mul、sign-extend 16 條線)。
- **`integer` + `for`(在 `always` 裡)**:**行為描述**,模擬時跑的迴圈。
  用在有 if/else 條件的邏輯。

兩者都會合成成電路,差別在可讀性與 iverilog 相容性。

### 0.5 `always_ff` / `always_comb` / 阻塞與非阻塞

- `always_ff @(posedge clk ...)`:時序邏輯,內部用**非阻塞 `<=`**。
- `always_comb`:組合邏輯,內部用**阻塞 `=`**。
- 這是鐵則,混用會出 race 或合出 latch。

### 0.6 其他小語法

| 寫法 | 意思 |
|---|---|
| `import trapezoid_pkg::*;` | 把共用 parameter(`N_MUL_ROW`、`ACC_W`…)引入 |
| `'0` | 全 0(寬度自動配合左邊),`'1` 全 1 |
| `{{(ACC_W-PROD_W){x}}, y}` | replication:把 `x` 複製 `(ACC_W-PROD_W)` 次,再接 `y` |
| `localparam int DLY = ...;` | 模組內部常數(不可從外部覆寫)|
| `$clog2(512)` | ⌈log₂512⌉ = 9(算 address 寬度用)|
| `wire _unused = &{1'b0, sig};` | 把暫時沒用到的訊號「假裝用一下」,壓掉 lint warning |

---

## 1. `local_buffer_row.sv` — 輸出緩衝(scatter / accumulate）

### 1.1 功能

PE row 算完的 C(部分和)要存起來。這顆 buffer 做兩件事:

1. **Scatter**:merge tree 一拍可能吐出多個 sub-tree 結果(TrIP),各自要寫到不同的
   C column;`out_addr[p]` 指定第 p 個結果寫去哪格。
2. **K-tile 累加**:K 很大時拆成多個 K-tile,每個 tile 的部分和要**讀-加-寫**累進去,
   全部累完才 dump 出去。

對應 paper §III.B 的 banked local buffer。

### 1.2 介面

| 訊號 | 方向 | 型別 | 說明 |
|---|---|---|---|
| `subtree_sums` | in | `[16][32]` packed | 從 tree 來的 16 個 sub-tree 值 |
| `subtree_valid` | in | `[16]` | 哪些位置有有效結果 |
| `out_addr` | in | `[16][9]` packed | 每個位置要寫到 buffer 第幾格 |
| `clear` | in | 1 | 清整顆 buffer(新 output region 開始)|
| `acc_en` | in | 1 | 這拍做 scatter-accumulate |
| `dump_en` / `dump_addr` | in | 1 / `[9]` | 讀出某格 |
| `c_valid` / `c_out` | out | 1 / `[32]` | 讀出的 C(registered)|

### 1.3 結構

```systemverilog
logic signed [ACC_W-1:0] mem [LOCAL_BUF_DEPTH];   // 512 格 × INT32 = 2KB
```

`mem` 是 unpacked 陣列 = 一塊 SRAM 的行為模型。合成時換成 ADFP 的 SRAM macro。
前面那段 `g_unpack` generate 是 §0.3 的安全 pattern,把 packed 的 `subtree_sums` /
`subtree_valid` / `out_addr` 轉成 unpacked 的 `sums_u` / `val_u` / `addr_u`。

### 1.4 行為(核心 `always_ff`)

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin … 全清 0 … end
    else if (en) begin
        if (clear)            // 優先序 1:清整塊
            for (i…) mem[i] <= '0;
        else if (acc_en)      // 優先序 2:scatter-accumulate
            for (i = 0; i < N_MUL_ROW; i++)
                if (val_u[i])
                    mem[addr_u[i]] <= mem[addr_u[i]] + sums_u[i];

        c_valid <= dump_en;          // dump 跟 clear/acc 獨立,每拍都評估
        c_out   <= mem[dump_addr];
    end
end
```

讀程式時要抓住三個點:

**(a) clear / acc 是 if-else(互斥),但 dump 是獨立的。**
`c_valid <= dump_en; c_out <= mem[dump_addr];` 寫在 if-else **外面**,所以不管那拍
在 clear 還是 acc,dump 的 registered read 都會發生。

**(b) scatter-accumulate 的「同拍多筆寫入」與 NBA 的微妙點。**
迴圈裡 `mem[addr_u[i]] <= mem[addr_u[i]] + sums_u[i]`:非阻塞賦值的右側
讀的是**這拍 posedge 之前**的 `mem` 舊值。
- 不同 `i` 寫**不同** address → 各寫各的,沒問題。
- 萬一兩個 `i` 寫**同一** address → 不會兩筆相加,而是「後寫的贏」(race)。
  所以介面有個**前提**:同一拍 valid 的 `out_addr` 必須互異。
  TrIP 不同 sub-tree → 不同 C 元素,這前提自然成立(註解第 8 行寫的就是這個)。

**(c) registered read 的時序意義。**
`c_out <= mem[dump_addr]` 讀的也是 posedge 前的舊值。所以「最後一拍 accumulate」
跟「dump」**不能同一拍**——必須等 accumulate 寫進去後的**下一拍**才 dump,
讀到的才是含最後一個 K-tile 的最終值。這就是 §1.1 K-tile loop 的時序安排。

### 1.5 合成對應

`mem` 行為模型上有「一拍最多 16 筆寫入」(16 個 valid sub-tree),
這在 synth 對應 paper 的 **4 bank × 4-word wide = 16 寫埠**;單顆 SRAM 沒 16 埠,
靠分 bank 拆。Behavioral 階段不用管,synth 換 macro 時再處理(見 `docs/memory-mapping`)。

---

## 2. `merge_tree_radix16_flexagon.sv` — 化簡樹(這份最難)

### 2.1 功能

把 16 個 partial products 化簡成 C。
- **Dense IP**(`cut_after = 0`):16 個全加 → 1 個 C。
- **TrIP**:依 `cut_after` 把樹切成多棵 **contiguous sub-tree**,每棵獨立加總、
  各產出一個 C 元素(對應 paper Fig 10)。

### 2.2 核心觀念:為什麼 binary tree 需要「node 帶狀態」(全檔的靈魂)

普通 16→1 加法樹很簡單,但 sub-tree slicing 有個結構性難題:

```
binary tree 的配對是硬體固定的:Stage1 配 (0,1)(2,3)(4,5)…
但 sub-tree 邊界是 runtime 動態的。
若某棵 sub-tree = {leaf 1, leaf 2}:
  leaf 1 在 pair(0,1) 的右邊、leaf 2 在 pair(2,3) 的左邊
  → 它們要相加,但 Stage 1 的固定配對不讓它們相遇!
```

解法:**每個 node 不能只往上吐一個值**,它要記住:
- 「我這段範圍裡,**最左邊**那棵還沒收尾的 sub-tree」(`val_l`)
- 「**最右邊**那棵」(`val_r`)
- 中間那些「左右都被夾住、確定完整」的 sub-tree → 立刻 **dump**(寫進輸出)

一棵 sub-tree 在「**第一次被左右兩邊夾住**」的瞬間被 dump。這是整個演算法的關鍵直覺。

### 2.3 每個 node 的 7 個 state

```systemverilog
val_l, val_r        // 最左 / 最右 sub-tree 的累加值
mask_l, mask_r      // 兩者的 sub-tree 編號(用來比邊界)
pos_l, pos_r        // 各自結束在哪個 leaf 位置(決定 dump 到 subtree_sums 的哪格)
is_single           // 整個 node 範圍是不是同一棵 sub-tree
```

程式裡用「一群平行陣列」表達(`s1_val_l[8]`、`s1_mask_l[8]`…),
因為 iverilog 對 struct 支援不友善,所以不用 `struct` 而是拆成多條訊號。

### 2.4 演算法分段

**Stage 0(組合):算 leaf_mask + sign-extend**

```systemverilog
assign leaf_mask[gm] = leaf_mask[gm-1] + {3'd0, cut_after[gm-1]};
```
`leaf_mask[i]` = `cut_after[0..i-1]` 裡有幾個 1 = **leaf i 的 sub-tree 編號**。
**兩個 leaf 的 mask 相同 ⟺ 它們之間沒切 ⟺ 同一棵 sub-tree** —— 後面所有 node
只要比左右 mask 是否相等,就能判斷邊界。

sign-extend(§0.6 replication):
```systemverilog
assign partials_ext[gk] = {{(ACC_W-PROD_W){partials[gk][PROD_W-1]}}, partials[gk]};
```
把 INT16 補符號位到 INT32(複製最高位 16 次)。負數補 1、正數補 0,數值不變。

**Stage 1~4(組合):8-case 合併**

每個 node 合併左右兩個子節點(L、R),先看 `L.mask_r` 跟 `R.mask_l`:

```
Case A:相同(boundary 兩側是同一棵 sub-tree,要合併)
  A1 都 single        → 整段合成一棵 single
  A2 L single,R 不是  → L 併進 R 的最左 sub-tree
  A3 R single,L 不是  → R 併進 L 的最右 sub-tree
  A4 都不 single       → 中間那棵被夾住、完整 → DUMP（= L.val_r + R.val_l）

Case B:不同(真的有切,兩側是不同 sub-tree)
  B1 都 single        → 兩棵都可能再延伸,不 dump
  B2 L single,R 不是  → R.val_l 被夾住 → DUMP R.val_l
  B3 L 不是,R single  → L.val_r 被夾住 → DUMP L.val_r
  B4 都不 single       → 兩棵都被夾住 → DUMP 兩次
```

程式裡每個 stage 就是這 8 個 case 的 if-else(Stage 1 因為 leaf 一定 single,
只有兩種,省略掉)。Stage 1 有 8 個 node、Stage 2 有 4、Stage 3 有 2、Stage 4 有 1(root)。

**Final flush(組合):root 之後**
root 出來後,最左 `val_l`、最右 `val_r` 沒有更上層可夾了 → 兩個都 dump
(若 `is_single` 則兩者相同,只 dump 一次)。

**Output collection(組合):把所有 dump 收進 `subtree_sums[16]`**
各 stage 的 dump 帶著「位置 `pos` + 值」,寫進 `subtree_sums[pos]`、`subtree_valid[pos]`。
因為每棵 sub-tree 的結束位置唯一,所以每格最多被一個 stage 寫(無衝突)。

**Output register(唯一的時序):**
```systemverilog
always_ff @(posedge clk …) subtree_sums[ko] <= sums_comb[ko];
```
⚠️ 重點:**Stage 1~4 全是 `always_comb`(組合),不是 pipeline register**。
「Stage」指的是樹的**邏輯層數**,不是時脈級。整顆樹是**組合邏輯 + 1 個輸出 register
= 1 cycle latency**(組員決議先不切 pipeline)。所以在 `pe_row_full` 裡,
tree 只算 1 個 stage(`TREE_STAGES = 1`)。

### 2.5 用 Fig 10 範例跑一遍(驗證理解)

`partials = [1,2,3,4]`,切成 `{p0} / {p1,p2} / {p3}`,`leaf_mask = [0,1,1,2]`:
- Stage 1:node(0,1) mask 0≠1 → not single,val_l=1,val_r=2;node(2,3) → val_l=3,val_r=4
- Stage 2 (root):L.mask_r=1 == R.mask_l=1 → Case A,都 not single → **A4 DUMP** C21 = 2+3 = 5
- Final flush:dump val_l=1(C20)、val_r=4(C31)
- 結果 `subtree_sums[0]=1, [2]=5, [3]=4` ✅ 跟 paper Fig 10 一致。

### 2.6 驗證 / timing

- `sim/tb_merge_tree_flexagon.sv`:17 個 sub-check(含 Fig 10、全切、不切、號數、邊界值)全過。
- Timing:組合 1-cycle,估 critical path ~3.5 ns → ~285 MHz,**撐不過 500 MHz**。
  synth 後若 fail,再把樹切成 2 個 pipeline stage(這是預留的退路)。

---

## 3. `pe_row_full.sv` — 8-stage 組裝(難點在 pipeline 對齊)

### 3.1 功能

把所有 per-row 硬體串成一條 8-stage pipeline(paper Fig 6):

```
S1 latch → S2-4 MFIU → S5 dist → S6 mul×16 → S7 tree → S8 buffer
```

Dense IP 跟 TrIP **共用同一條物理 pipeline**(Δ5 Option A):Dense IP 模式下
MFIU/dist 變成 pass-through delay。

### 3.2 結構總覽

模組本身幾乎只做兩件事:**instantiate 子模組** + **接線 + 對齊延遲**。
`wire en = 1'b1;` 讓 pipeline 自由推進(不 stall)。

```systemverilog
localparam int DLY_AB   = MFIU_STAGES;                            // 3
localparam int DLY_CUT  = DIST_STAGES + MUL_STAGES;               // 2
localparam int DLY_ADDR = DIST_STAGES + MUL_STAGES + TREE_STAGES; // 3
```
這三個 `localparam` 是本檔的核心 —— delay line 的深度。

### 3.3 控制訊號對齊(本檔最難的點)

MFIU 在 S4 一次算出三組 metadata,但它們在**不同 stage 才被用到**,
所以要各自延遲,讓它跟到達同一 stage 的資料對齊:

| metadata | 被誰用 | 在 MFIU 後幾拍 | delay |
|---|---|---|---|
| `effectual_idx` | S5 dist | 立刻 | 0(直接接)|
| `cut_after` | S7 tree | 過了 dist + mul | `DLY_CUT = 2` |
| `out_addr` | S8 buffer | 過了 dist + mul + tree | `DLY_ADDR = 3` |

另外 **A/B 的「值」** 在 S1 latch 後,要延 `MFIU_STAGES` 拍,才能跟 MFIU 算完的
`effectual_idx` 在 dist 入口對齊(因為 MFIU 花了 3 拍算 metadata,值不能先到)。

### 3.4 delay line 怎麼寫(語法重點)

延遲線是「unpacked 陣列,每格是一個 packed 向量」:

```systemverilog
logic signed [N_MUL_ROW-1:0][DATA_W-1:0] a_dly [DLY_AB];   // 3 格,每格 128 bit
always_ff @(posedge clk …) begin
    a_dly[0] <= a_q;                       // 最新的進第 0 格
    for (da = 1; da < DLY_AB; da++)
        a_dly[da] <= a_dly[da-1];          // 其餘往後推一格(shift register)
end
wire signed [...] a_aligned = a_dly[DLY_AB-1];  // 最舊的(延了 3 拍)拿出來用
```

`cut_dly`、`addr_dly` 同理,只是深度與資料寬度不同。
這就是教科書的 **shift-register 延遲線**,只是每格存的是一整包向量。

### 3.5 valid 訊號的傳遞

資料有沒有效,要一路跟著 pipeline 走。本檔用一條 valid 鏈:

```
v_q (S1) ── MFIU 內部延 3 ──▶ mfiu_vld
         ── dist 內部延 1 ──▶ dist_vld
         ── mul_vld 暫存 1 ──▶ mul_vld
         ── tree_out_vld 暫存 1 ──▶ tree_out_vld ── 當 buffer 的 acc_en
```

`mul_vld`、`tree_out_vld` 是兩個 1-bit register,補足 mul、tree 那兩拍的延遲。
最後 `acc_en = tree_out_vld`,確保 buffer 只在「真的有資料到達 S8」那拍累加。

### 3.6 逐 stage 對照程式

| Stage | 程式 | 在做什麼 |
|---|---|---|
| S1 | 第一個 `always_ff`(`a_q`/`b_q`/`a_bm_q`…)| 輸入打一拍對齊 |
| S2-4 | `mfiu_row u_mfiu(...)` | 交集 + 壓縮,輸出 metadata + `mfiu_vld` |
| (對齊) | `a_dly`/`b_dly` shift | A/B 值延 3 拍 |
| S5 | `dist_net_row u_dist(...)` | 依 idx gather a/b |
| S6 | `generate … mac_unit u_mul` ×16 | 16 個乘法 |
| (對齊) | `cut_dly` shift | cut_after 延 2 拍 |
| S7 | `merge_tree_radix16_flexagon u_tree(...)` | 化簡 |
| (對齊) | `addr_dly` shift | out_addr 延 3 拍 |
| S8 | `local_buffer_row u_buf(...)` | scatter-accumulate + C out |
| 旁路 | 最後 `always_ff`(`b_vec_out`)| B 延 1 拍 forward 給下一條 row |

### 3.7 latency 推導(為什麼是 8)

```
S1 latch(1) + MFIU(3) + dist(1) + mul(1) + tree(1) + buffer(1) = 8 = PE_ROW_STAGES
```

`in_valid` 拉起後第 8 拍,結果累加進 buffer;dump 再 +1 拍(buffer 的 registered read)。
所以上層 `dataflow_ctrl` 要在「最後一拍 `in_valid` 之後第 9 拍」才拉 `dump_en`。

### 3.8 兩個小語法

- `wire _unused = &{1'b0, mfiu_cnt};`:`effectual_count` 在 Dense IP 沒用到
  (恆 = 16),這行把它「假用」一下壓掉 Verilator 的 unused warning。
- `b_vec_out <= b_vec_in;`:B forwarding 就是一個 1-cycle latch,把這拍進來的 B
  下一拍交給下一條 row(`pe_array` 把 16 條 row 串成 chain)。

---

## 4. 小結:三個檔怎麼合起來

```
                    ┌─────────────── pe_row_full ───────────────┐
 a_vec/b_vec ─S1──▶ latch ─┐                                     │
 bitmask ──────────────────┴─S2-4─▶ mfiu_row ─idx/cut/addr─┐     │
                                                            │     │
 a/b 值 ─(延3)─────────────────────────────▶ dist ─S5─▶ mul ×16 ─S6─▶
   merge_tree_radix16_flexagon ─S7─▶ local_buffer_row ─S8─▶ c_out
                    └────────────────────────────────────────────┘
```

| 檔 | 角色 | 一句話 |
|---|---|---|
| `merge_tree_radix16_flexagon` | S7 | binary tree + node 帶狀態,做 sub-tree slicing |
| `local_buffer_row` | S8 | scatter-accumulate,跨 K-tile 累加後 dump |
| `pe_row_full` | 組裝 | instantiate 全部 + 用 delay line 把控制訊號對齊資料路徑 |

### 驗證狀態

| TB | 數量 |
|---|---|
| `tb_merge_tree_flexagon` | 17 sub-check ✅ |
| `tb_local_buffer` | 9 sub-check ✅ |
| `tb_pe_row_full`(端到端 vs 手算 dot product)| 7 sub-check ✅ |

### 讀程式的順序建議

1. 先讀 `local_buffer_row`(最短、概念單純)。
2. 再讀 `merge_tree_radix16_flexagon` 的 §2.2 觀念 + Fig 10 trace,再回去看 8-case。
3. 最後讀 `pe_row_full`,重點放 §3.3 的對齊表 + §3.4 的 delay line。
