# ADFP 合成工作手冊(實證版)

> 記錄在 superdome1 跑 Synopsys DC 合成的**實際**流程(2026-06-04 跑通 mac / tree / local_buffer)。
> 這份是「照著做就會動」的 runbook,不是猜測模板。

---

## 0. 環境速查(已確認)

| 項目 | 值 |
|---|---|
| Server | `superdome1`(140.116.156.11),帳號 `aoc2620`,用 MobaXterm SSH |
| 預設 shell | **csh**(提示字元 `%`)→ 一進去先打 **`bash`**(後面指令才順) |
| 合成工具 | `dc_shell` **已在 PATH**(`/usr/cad/synopsys/synthesis/2025.06/amd64/syn/bin/dc_shell`)→ **不用 source 環境** |
| 專案位置 | `~/aoc-final`(⚠️ 新開終端機會在家目錄 `~`,要先 `cd ~/aoc-final`)|
| 檔案傳輸 | **superdome1 連不到 GitHub** → 用瀏覽器下載 repo ZIP → MobaXterm 左邊面板 SFTP 上傳 |

---

## 1. 已確認的 library 路徑(不用再查)

```
標準 cell .db : /usr/cad/CBDK/Executable_Package/Collaterals/IP/stdcell/N16ADFP_StdCell/NLDM/N16ADFP_StdCelltt0p8v25c.db
SRAM .db      : /usr/cad/CBDK/Executable_Package/Collaterals/IP/sram/N16ADFP_SRAM/NLDM/N16ADFP_SRAM_tt0p8v0p8v25c_100a.db
SRAM .v(模擬): /usr/cad/CBDK/Executable_Package/Collaterals/IP/sram/N16ADFP_SRAM/VERILOG/N16ADFP_SRAM_100a.v
corner       : tt0p8v25c(typical, 0.8V, 25°C)
```

view 資料夾:`NLDM`=時序庫(.db/.lib)、`VERILOG`=模擬模型、`LEF`=P&R、`GDS`=layout。

---

## 2. 我們用到的 macro

| 用途 | macro | 說明 |
|---|---|---|
| local buffer 累加器 | **`TS6N16ADFPCLLLVTA128X32M4FWSHOD`** × 4 | two-port 1R1W,128 深 × 32-bit;4 顆 = 4 bank = 512×32 = 2KB |
| B FIFO | **用 register**(不開 macro)| 太小(~16 筆),flip-flop 比 macro 划算 |
| Global Buffer | (之後再做)| 16KB/16-bank,可用 SP 128×64 × 16 |

---

## 3. 跑合成的實際步驟(每次照這個)

```bash
# 1) 進去先換 bash
bash

# 2) 進專案(新終端機在家目錄,一定要 cd)
cd ~/aoc-final

# 3) 選要合哪個 module:改 synth.tcl 的 set TOP
nano synth/synth.tcl     # set TOP local_buffer_row(或 mac_unit / merge_tree_radix16_flexagon / pe_row_full)
#    Ctrl+O Enter 存、Ctrl+X 離開

# 4) 跑(tee 存 log)
dc_shell -f synth/synth.tcl | tee synth/log.log

# 5) 讀報告(看 §5)
cat reports/qor.rpt
```

- **第一次先合最小的 `mac_unit`** 確認流程通(幾秒),再合大的。
- 合成在 server 上跑,**起跑後可以離開**(SSH 連線開著就好),回來看結果。

---

## 4. SRAM macro 怎麼接(實證版)

### 4a. 用 wrapper 包一層(sram_128x32_1r1w.sv)

不要在 `local_buffer_row` 直接綁醜醜的 macro 腳位,包一層乾淨介面 +
`` `ifdef USE_SRAM_MACRO `` 切換「合成接 macro / 模擬用 behavioral」:

```systemverilog
module sram_128x32_1r1w (
    input clk, input ren, input [6:0] raddr, output [31:0] rdata,
    input wen, input [6:0] waddr, input [31:0] wdata );
`ifdef USE_SRAM_MACRO
    TS6N16ADFPCLLLVTA128X32M4FWSHOD u_macro ( ...見 4b... );
`else
    logic [31:0] mem [0:127];          // 模擬用(iverilog),讀延遲 1 拍
    always_ff @(posedge clk) begin
        if (wen) mem[waddr] <= wdata;
        if (ren) rdata      <= mem[raddr];
    end
`endif
endmodule
```

### 4b. macro 的真實 port 對應(已確認)

```systemverilog
TS6N16ADFPCLLLVTA128X32M4FWSHOD u_macro (
    // 寫埠
    .AA   (waddr),       // Address WRITE bus [6:0]
    .D    (wdata),       // 寫資料 [31:0]
    .BWEB ({32{1'b0}}),  // 逐位元寫遮罩,active-low(0=寫該位元)→ 全 0 = 全寫
    .WEB  (~wen),        // 寫致能,active-low → 取反
    .CLKW (clk),         // 寫時鐘
    // 讀埠
    .AB   (raddr),       // Address READ bus [6:0]
    .REB  (~ren),        // 讀致能,active-low → 取反
    .CLKR (clk),         // 讀時鐘
    .Q    (rdata),       // 讀資料 [31:0]
    // 電源/測試腳:綁正常運作值
    .RCT (2'b00), .WCT (2'b00), .KP (3'b000),
    .SLP (1'b0),  .DSLP(1'b0),  .SD (1'b0),
    .PUDELAY ( )         // output,不接
);
```
> 重點:`WEB`/`REB`/`BWEB` 都是 **active-low**(取反);`PUDELAY` 是 **output**(留空);
> 其餘 input 腳一定要綁值不能浮空。

### 4c. synth.tcl 要打開 macro 模式(3 處)

```tcl
set SRAM_DB_DIR  "/usr/cad/.../sram/N16ADFP_SRAM/NLDM"
set SRAM_DB      "N16ADFP_SRAM_tt0p8v0p8v25c_100a.db"
set search_path  [concat "." $STDCELL_DB_DIR $SRAM_DB_DIR]
set link_library "* $STDCELL_DB $SRAM_DB"
analyze -format sverilog -define {USE_SRAM_MACRO} $RTL_FILES   ;# ← 關鍵:定義 macro
```
不定義 `USE_SRAM_MACRO` → 走 behavioral(SRAM 變 flip-flop,合成慢、面積大,但不用 macro 也能跑)。

---

## 5. 怎麼讀報告(看 `reports/qor.rpt`)

| 欄位 | 看什麼 |
|---|---|
| **Critical Path Slack** | **正數 = 過 500MHz**;負數 = 太慢 |
| **No. of Violating Paths**(setup)| **0 = 沒問題** |
| **Macro Count** | 用真 macro 應該是 **4**(=0 代表沒接到 macro,還是 behavioral)|
| **Cell Area** | 總面積(µm²);Macro 版裡 SRAM 佔 `Macro/Black Box area` |
| Hold Violation | **合成階段一堆 hold 違規是正常的,P&R 會修,先不管**;只看 setup slack |

**behavioral vs macro 對比(local_buffer 實測):**

| | behavioral(SRAM=FF)| macro(真 SRAM)|
|---|---|---|
| Macro Count | 0 | **4** |
| Sequential cells | 16869 | **361** |
| Cell Area | 27857 µm² | **13733 µm²**(12808 是 4 顆 SRAM)|
| Slack | +0.63 | **+0.53** |
| 編譯時間 | 5.5 分 | **60 秒**(macro 是黑盒子,不用合內部 → 快)|

> 「跑超快」是因為 macro 是黑盒子(對的),不是出錯。

**已合過的結果(報告用):**
- `mac_unit`:88 µm²,slack +0.91 ✅
- `merge_tree_radix16_flexagon`:2034 µm²,slack +0.60(realistic constraint)✅
- `local_buffer_row`(macro):13733 µm²,Macro Count 4,slack +0.53 ✅

---

## 6. 現在 repo 裡的合成檔(已可用)

- `synth/synth.tcl` — 已填好路徑、macro 模式、`RTL_FILES` 明列(不 glob,避免掃到組員 WIP)
- `synth/constraints.sdc` — 500MHz(period 2.0),input/output delay 0.5(偏保守,單塊看 timing 可改 0.2)

跑法就是 §3:改 `set TOP` → `dc_shell -f synth/synth.tcl`。

---

## 7. 踩過的雷(實證,先有心理準備)

| 雷 | 解法 |
|---|---|
| 提示字元是 `%`、指令怪怪 | 先打 `bash` |
| `could not open script ...synth.tcl` | 新終端機在家目錄 → 先 `cd ~/aoc-final` |
| MobaXterm 左邊面板**卡死/點不開** | 不是當機,是被合成 + NFS 拖慢在等。**用終端機 `cat`/`nano` 就好**;把面板的 **Follow terminal folder 取消勾選** |
| `git clone` timeout | superdome1 連不到 GitHub → 改 **ZIP 下載 + SFTP 上傳** |
| 合成跑 2 小時 / 記憶體爆 | **行為模型大記憶體**(512 深 + 多寫埠)→ 換 SRAM macro 就又快又小 |
| Hold Violation 一大堆 | 合成階段正常,P&R 修,**只看 setup slack** |
| `dc_shell>` 提示卡住 | 它跳到互動模式了 → 打 `quit` 離開 |

---

## 8. 進度 / 下一步

- [x] `mac_unit` 合成 ✅
- [x] `merge_tree_radix16_flexagon` 合成 ✅(確認過 500MHz,不用切 pipeline)
- [x] `local_buffer_row`(真 macro)合成 ✅
- [ ] **pe_row 整合**:把 tree 的 16-lane 輸出**壓成 4 筆 banked write** 餵 buffer(`clear`→`first_pass`);接真 MFIU/dist 時要對齊 latency
- [ ] 接真 MFIU(楊承豫)/ dist(QuillQ):確認 port + **latency 幾拍**(pe_row 延遲對齊要用)
- [ ] 整條 pe_row → 16 條 array(hierarchical,不用 16 條各合)

---

## 9. 附錄:怎麼「找一顆 macro + 確認怎麼用」(通用流程,可帶到別堂課)

任何 PDK 的 hard macro 都長得差不多:有一個 `.v`(模擬模型)、一個 `.db/.lib`(時序庫)、`.lef`(P&R)。找一顆陌生 macro,照這 5 步:

### Step 1 — 找 library 在哪 + 有哪些 view(用 `ls` 一層層看,別用大範圍 `find` 會卡)
```bash
ls <PDK根>/.../Collaterals/IP/            # 看有哪些 IP:sram / stdcell / io / pll ...
ls <PDK根>/.../IP/sram/<某顆>/             # 看 view 資料夾
```
**view 對照**:`VERILOG`=`.v` 模擬模型 · `NLDM`(或 `DB`)=`.lib`/`.db` 時序庫(**合成用**)· `LEF`=P&R · `GDS`=layout · `SPICE`=電晶體。

### Step 2 — 列出 `.v` 裡有哪些 macro(挑你要的尺寸 / 埠數)
```bash
grep -n "^module" .../VERILOG/<lib>.v
```
看名字挑(TSMC 命名解碼):
- `TS1...` = **單埠** · `TS6...` = **雙埠(1R1W)**
- 名字裡 `...A128X32M...` = **128 字 × 32 bit**(深度 × 位寬)
- 行號(grep 給的)→ 下一步要用

### Step 3 — 抓那顆 macro 的 port + 寬度 + 方向(寫 instantiate 一定要)
```bash
awk 'NR>=<module行號> && NR<=<+60>' .../VERILOG/<lib>.v | grep -iE "input|output|inout"
```
→ 印出像 `input [6:0] AA;  // Address write bus`。**看 comment + 寬度**就知道每根腳幹嘛、幾 bit。

### Step 4 — 找合成用的 `.db`(挑 corner)
```bash
ls .../IP/<lib>/<macro>/NLDM/        # 看有哪些 corner
```
**corner 解碼**:`tt`=typical(最常用) · `ss`=slow-slow(setup 最壞情況) · `ff`=fast-fast(hold);
`.db` 名 `tt0p8v25c` = typical 製程、0.8V、25°C。

### Step 5 — 接腳慣例(寫 instance 時)
- **名字帶 `B`**(`WEB`/`REB`/`BWEB`/`CEB`/`CSB`)= **active-low** → 通常要 **取反**(`~wen`)。
- **電源/睡眠腳**(`SLP`/`DSLP`/`SD`/`PD`)→ 綁 `0`(正常運作);**margin/test 腳**(`RCT`/`WCT`/`KP`)→ 綁 `0`(預設)。
- **output 腳**(如 `PUDELAY`)→ **留空**(`.PUDELAY()`)。input 腳**不能浮空**,一定要給值。
- 包一層 **wrapper**(`` `ifdef `` 切換 macro / behavioral)→ 上層不用碰醜腳位,模擬合成同一份碼(見 §4)。

### 完整實例(今晚這顆,對照著看)
```
找到:TS6N16ADFPCLLLVTA128X32M4FWSHOD(TS6=雙埠, 128X32)
port :AA=寫址 / AB=讀址 / D=寫資料 / Q=讀資料 / BWEB,WEB,REB=active-low 致能 / CLKW,CLKR=讀寫時鐘
.db  :NLDM/N16ADFP_SRAM_tt0p8v0p8v25c_100a.db(tt corner)
tie  :SLP/DSLP/SD/RCT/WCT/KP=0,PUDELAY 留空
```

> 換別顆 SRAM(例如要 512 深、或單埠)→ 同樣 Step 1~5,只是 Step 2 挑不同名字、Step 3 重抓 port。
> 別堂課別的 PDK → 結構一樣(view 資料夾 / `^module` 列名 / `.db` corner / active-low + tie-off 慣例),照搬即可。
