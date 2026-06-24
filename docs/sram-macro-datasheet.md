# N16ADFP SRAM Macro 自製 Datasheet(組內查詢用)

> 給之後要用記憶體 macro 的組員**快速查**:有哪些尺寸可選、怎麼接腳、`.db` 在哪。
> 整理自 superdome1 上 `N16ADFP_SRAM` library 的實際探索(2026-06)。
> 對應流程教學見 `docs/adfp-synth-handbook.md` §9。

---

## 1. 快速查詢(最常用)

| 項目 | 值 |
|---|---|
| corner（合成用）| **`tt0p8v25c`**（typical, 0.8V, 25°C）|
| SRAM `.db` | `/usr/cad/CBDK/.../IP/sram/N16ADFP_SRAM/NLDM/N16ADFP_SRAM_tt0p8v0p8v25c_100a.db` |
| stdcell `.db` | `/usr/cad/CBDK/.../IP/stdcell/N16ADFP_StdCell/NLDM/N16ADFP_StdCelltt0p8v25c.db` |
| SRAM `.v`（模擬）| `/usr/cad/CBDK/.../IP/sram/N16ADFP_SRAM/VERILOG/N16ADFP_SRAM_100a.v` |
| view 資料夾 | `NLDM`=時序庫(.db/.lib,合成用) · `VERILOG`=.v 模擬 · `LEF`=P&R · `GDS`=layout |

> 完整路徑前綴都是 `/usr/cad/CBDK/Executable_Package/Collaterals/`。

---

## 2. 可選的 SRAM macro 一覽 ★查這張★

（`Int_Array` 結尾的是內部子模組,**不要拿來 instantiate**;下表是可用的頂層 macro）

| Module 名稱 | 埠別 | words × bits | 容量 | 適合 |
|---|---|---|---|---|
| `TS1N16ADFPCLLLVTA128X64M4SWSHOD` | 單埠 (1RW) | 128 × 64 | **1 KB** | GLB / 大塊單埠 |
| `TS1N16ADFPCLLLVTA512X45M4SWSHOD` | 單埠 | 512 × 45 | ~2.8 KB | 深、含 metadata 的 buffer |
| `TS1N16ADFPCLLLVTA16X88M2SWSHOD` | 單埠 | 16 × 88 | 176 B | 小、寬 |
| `TS1N16ADFPCLLLVTA16X96M2SWSHOD` | 單埠 | 16 × 96 | 192 B | 小、寬 |
| `TS6N16ADFPCLLLVTA128X32M4FWSHOD` | **雙埠 1R1W** | 128 × 32 | 512 B | **累加器 bank（我們在用）** |
| `TS6N16ADFPCLLLVTA128X64M4FWSHOD` | 雙埠 1R1W | 128 × 64 | 1 KB | 雙埠、寬 |
| `TS6N16ADFPCLLLVTA32X32M2FWSHOD` | 雙埠 | 32 × 32 | 128 B | 小 FIFO |
| `TS6N16ADFPCLLLVTA16X120M2FWSHOD` | 雙埠 | 16 × 120 | 240 B | 小、很寬 |
| `TS6N16ADFPCLLLVTA16X72M2FWSHOD` | 雙埠 | 16 × 72 | 144 B | 小 |
| `TS6N16ADFPCLLLVTA16X32M2FWSHOD` | 雙埠 | 16 × 32 | 64 B | 小 FIFO |

**命名解碼**:`TS1`=單埠 / `TS6`=雙埠(1R1W);`...A<深>X<寬>M...`(如 `128X32`=128 字 × 32 bit)。

**湊容量的小抄**:
- 需要 **512 × 32(2KB)** → 4× `TS6...128X32`(分 bank、雙埠;我們的 local buffer)或 1× `TS1...512X45`(單埠,用 32/45 bit)。
- 需要 **16 KB / 16 bank GLB** → 16× `TS1...128X64`(每顆 1KB)。
- 需要 **小 FIFO** → 16~64 筆其實用 **register** 比開 macro 划算。

---

## 3. `TS6...128X32`(雙埠 1R1W)完整接腳表

| Port | 方向 | 寬度 | 作用 | 接法（wrapper 內）|
|---|---|---|---|---|
| `AA` | in | [6:0] | **寫**址 | `waddr` |
| `D` | in | [31:0] | 寫資料 | `wdata` |
| `BWEB` | in | [31:0] | 逐位元寫遮罩,**active-low**(0=寫該位元)| `{32{1'b0}}`（全寫）|
| `WEB` | in | 1 | 寫致能,**active-low** | `~wen` |
| `CLKW` | in | 1 | 寫時鐘 | `clk` |
| `AB` | in | [6:0] | **讀**址 | `raddr` |
| `REB` | in | 1 | 讀致能,**active-low** | `~ren` |
| `CLKR` | in | 1 | 讀時鐘 | `clk` |
| `Q` | out | [31:0] | 讀資料 | `rdata` |
| `RCT` | in | [1:0] | timing margin | `2'b00` |
| `WCT` | in | [1:0] | timing margin | `2'b00` |
| `KP` | in | [2:0] | test | `3'b000` |
| `SLP` | in | 1 | sleep | `1'b0` |
| `DSLP` | in | 1 | deep sleep | `1'b0` |
| `SD` | in | 1 | shutdown | `1'b0` |
| `PUDELAY` | **out** | 1 | power-up delay | **留空 `()`** |

讀延遲 1 拍(同步 SRAM)。參數:`N=32`(寬)、`W=128`(深)、`M=7`(位址)。

---

## 4. Instantiate 慣例(任何這家的 macro 都通用)

- **名字帶 `B`**(`WEB`/`REB`/`BWEB`)= active-low → **取反**(`~wen`、`~ren`)。
- **電源/睡眠**(`SLP`/`DSLP`/`SD`)、**margin/test**(`RCT`/`WCT`/`KP`)→ **綁 0**(正常運作)。
- **output 腳**(`PUDELAY`)→ **留空**;input 腳**不能浮空**。
- 包一層 **wrapper**(`` `ifdef USE_SRAM_MACRO `` 切換 macro / behavioral),上層不碰醜腳位,模擬合成同一份碼(範例見 `rtl/pe/sram_128x32_1r1w.sv`)。
- **synth.tcl 開 macro 模式 3 處**:`link_library` 加 SRAM `.db`、`search_path` 加 SRAM dir、`analyze ... -define {USE_SRAM_MACRO}`。

---

## 5. 附錄:怎麼查(換顆 / 別堂課照抄,改路徑即可)

```bash
SRAM=/usr/cad/CBDK/Executable_Package/Collaterals/IP/sram/N16ADFP_SRAM

# (1) 有哪些 macro
grep -n "^module" $SRAM/VERILOG/N16ADFP_SRAM_100a.v

# (2) 某顆的 port + 寬度 + 方向（行號用 (1) 的結果）
awk 'NR>=17213 && NR<=17400' $SRAM/VERILOG/N16ADFP_SRAM_100a.v \
  | grep -iE "^[[:space:]]*(input|output|inout)"

# (3) 合成用的 .db（挑 tt corner）
ls $SRAM/NLDM/
find /usr/cad/CBDK/Executable_Package/Collaterals/IP/stdcell -name "*tt*.db" 2>/dev/null
```
> 探索時用 `ls` 一層層看,**別用大範圍 `find /usr/cad`(會卡很久)**。
