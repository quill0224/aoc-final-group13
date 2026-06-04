# ADFP 合成工作手冊

> 本文件記錄硬體電路實作 / 伺服器(四樓電腦教室)使用方式。
> 之前只寫過 RTL + Verilator/iverilog 測試,沒跑過合成;以此文件記錄學習過程。
> 標 `<...>` 的是**到現場要填的實際值**。

---

## 0. 出發前確認(在自己電腦做好)

- [ ] 8 個 unit testbench 全綠(`make tb_mac / tb_tree_flexagon / tb_lbuf / tb_mfiu_row / tb_dist_net / tb_pe_row_full / tb_pe_array`)
- [ ] RTL 已 commit + push(工作站直接 `git clone` 最省事)
- [ ] 手邊有 ADFP hard macro 規格表(7.5 那張)
- [ ] 知道助教給的 SRAM 路徑:
      `/usr/cad/CBDK/Executable_Package/Collaterals/IP/sram/N16ADFP_SRAM/N16ADFP_SRAM/VERILOG/N16ADFP_SRAM_100a.v`

---

## 1. Workflow 總覽

**自己電腦能做(已完成)**
1. RTL(SystemVerilog)
2. Functional sim(iverilog,`make tb_*`)
3. Lint(Verilator,`make lint`)

**要到電腦教室 server 才能做**
4. 連 server + 找 ADFP library / macro
5. 把 buffer 的行為陣列改寫成 **SRAM macro instantiate**
6. 寫 SDC constraint(Synopsys Design Constraint,設 500 MHz)
7. 跑合成(Synopsys DC / Cadence Genus)→ 看 timing / area / power

---

## 2. 為什麼本機跑不了合成

| 缺的東西 | 說明 |
|---|---|
| **EDA 工具**(Synopsys DC / Cadence Genus)| 商業軟體,要連 license server(每跑抓 1 個 license)|
| **N16ADFP 標準 cell + SRAM library**(`.lib`/`.db`/`.lef`/`.gds`)| 受 NDA 保護,不能下載到個人電腦,只在 server |
| **工具環境設定**(PATH / license server IP / setup script)| 由 server 統一設定,要 source |

---

## 3. 到工作站:照順序跑(邊跑邊填 §5 表格)

```bash
# 0) 連 server(位址問助教/學長)
ssh <帳號>@<lab-server>

# 1) 進可寫的工作目錄,把專案拉下來
cd <work-dir>            # 例:/scratch/<帳號>/
git clone <repo-url> Final_project && cd Final_project

# 2) 看 SRAM macro 有哪些 view(.v 模擬 / .db,.lib 合成 / .lef P&R)
ls /usr/cad/CBDK/Executable_Package/Collaterals/IP/sram/N16ADFP_SRAM/N16ADFP_SRAM/
find /usr/cad/CBDK/Executable_Package/Collaterals/IP/sram/N16ADFP_SRAM -name "*.db"  | head
find /usr/cad/CBDK/Executable_Package/Collaterals/IP/sram/N16ADFP_SRAM -name "*.lib" | head

# 3) 找出 macro 的 module 名稱 + port(instantiate 要用)
grep -n "^module" /usr/cad/.../VERILOG/N16ADFP_SRAM_100a.v
#    再打開那個 module,把 port(CLK / CEN / WEN / A / D / Q ...)抄到 §5

# 4) 找標準 cell 的 .db(合成 target_library 用)
find /usr/cad/CBDK -name "*.db" | grep -iE "tt|typical|stdcell|sc" | head

# 5) 載入 EDA 工具環境(setup script 問助教/學長)
source <synopsys-setup-script>
which dc_shell || which genus       # 確認抓得到工具

# 6) 跑合成
dc_shell -f synth.tcl | tee synth.log

# 7) 看報告
cat reports/timing.rpt   # 看 slack:正數=過,負數=fail
cat reports/area.rpt
```

> 💡 **第一次別直接合整個 `top`**。先單獨合 `pe_row_full`(或更小的 `mac_unit`)把流程跑通,再往上合。

---

## 4. SRAM macro 怎麼用(重點)

行為模型(`logic [..] mem [..]`)在合成會變成一堆 flip-flop。要真的用 SRAM,得**換成 macro instantiate**:

1. 在 `local_buffer_row.sv` 把 `mem` 陣列換成 macro instance(port 對照 §5 抄到的)。
2. 合成 script 把 macro 的 `.db` 加進 `link_library`。
3. macro 對合成是 **black box**,要 `set_dont_touch`,不要讓工具去優化它。

**初步選用方案**(對照 7.5 規格表):
- Global Buffer 16 KB / 16 bank → **16 顆 Single Port 128×64**(每顆 1 KB)
- per-row local buffer 2 KB(512×INT32)→ **Single Port 512×45**(45-bit = 32-bit 值 + metadata)
- B FIFO(小)→ Two Port 16×32 之類

**instantiate 範本**(實際 module 名 / port 以 §5 為準):
```systemverilog
// 假設 macro 叫 N16ADFP_SRAM_512x45(現場確認真名)
N16ADFP_SRAM_512x45 u_sram (
    .CLK (clk),
    .CEN (~en),      // chip enable,多半 active-low
    .WEN (~we),      // write enable,多半 active-low
    .A   (addr),     // [8:0]
    .D   (din),      // [44:0]
    .Q   (dout)      // [44:0],下一拍出
);
```

---

## 5. 要記下來的東西(★現場填★)

| 項目 | 值 |
|---|---|
| server 位址 / 帳號 | `<...>` |
| 工作目錄(可寫的 scratch) | `<...>` |
| EDA 工具(DC / Genus)+ setup script | `<...>` |
| license server | `<...>` |
| **SRAM macro module 名稱** | `<...>` |
| **SRAM macro port**(CLK/CEN/WEN/A/D/Q…/極性) | `<...>` |
| SRAM `.db` / `.lib` 路徑 | `<...>` |
| 標準 cell `.db` 路徑(target_library) | `<...>` |

---

## 6. 範本檔(到現場填路徑後可直接用)

**`synth.tcl`**
```tcl
set search_path  [list . <stdcell_db_dir> <sram_db_dir>]
set target_library "<stdcell>.db"
set link_library   "* <stdcell>.db <sram_macro>.db"

analyze -format sverilog [glob rtl/*.sv rtl/*/*.sv]
elaborate pe_row_full           ;# 先合單一 module,通了再合 top
read_sdc constraints.sdc
compile_ultra

report_timing -max_paths 10 > reports/timing.rpt
report_area                 > reports/area.rpt
report_power                > reports/power.rpt
write -format verilog -hierarchy -output netlist.v
```

**`constraints.sdc`**(500 MHz)
```tcl
create_clock -name clk -period 2.0 [get_ports clk]   ;# 2 ns = 500 MHz
set_clock_uncertainty 0.1 [get_clocks clk]
set_input_delay  0.5 -clock clk [remove_from_collection [all_inputs] [get_ports clk]]
set_output_delay 0.5 -clock clk [all_outputs]
set_false_path -from [get_ports rst_n]
# SRAM macro 當 black box,不要被優化掉
set_dont_touch [get_cells -hier -filter "ref_name =~ N16ADFP_SRAM*"]
```

---

## 7. 常見雷(先有心理準備)

- **inferred latch / multi-driver**:always_comb 漏 default、或一條訊號被多源 drive → 合成 warning,要回去改 RTL。
- **unsupported construct**:某些 SV 寫法工具不吃(例如 `int` 要改 `integer`)→ 看 log 改。
- **SRAM 沒換 macro**:還是 `logic mem[]` 的話,會合成成大量 flip-flop、area 爆炸 → 一定要換 macro。
- **timing fail(slack 負)**:flexagon tree 純組合估 ~285 MHz,可能過不了 500 MHz → 把 tree 切成 2 級 pipeline 再合。

---

## 8. 完成的判準

- [ ] `pe_row_full` 合成跑完、無 error
- [ ] `reports/timing.rpt` 的 slack ≥ 0(或記下差多少,作為要不要切 pipeline 的依據)
- [ ] `reports/area.rpt` 有面積數字(report 用)
- [ ] 把實際指令 / 路徑回填 §3、§5(下次不用重查)
