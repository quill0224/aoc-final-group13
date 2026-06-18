# 如何跑 RTL Testbench

> 對象:第 13 組所有人(主要是 Iris 自己跟之後接手的隊友)
> 目的:在本機 / Docker 跑 `make tb_*` 系列驗證 RTL
> 最後更新:2026-05-12

---

## 0. 你需要的工具

| 工具 | 用途 | 必要性 |
|---|---|---|
| **iverilog** (Icarus Verilog) | 編譯 + 跑 SV testbench | ⭐ 必裝 |
| **vvp** | 執行 iverilog 編出來的 `.vvp` | iverilog 內建,不用另裝 |
| **make** | 跑 Makefile target | ⭐ 必裝(macOS / Linux 內建) |
| **gtkwave** | 看波形 `.vcd` 檔 | 出 bug 才需要 |
| **verilator** | `make lint` 用(不是跑 tb) | 跑 lint 才需要 |

---

## 1. 路徑 A:本機 (macOS) 跑 — **最快,推薦先試**

### 1.1 安裝(只做一次,~5 分鐘)
```bash
# 用 Homebrew
brew install icarus-verilog       # iverilog + vvp
brew install --cask gtkwave       # gtkwave (GUI)
brew install verilator            # optional, lint 用
```

確認裝好:
```bash
which iverilog vvp gtkwave
# 應該看到 /opt/homebrew/bin/iverilog 之類
```

### 1.2 跑測試
```bash
cd ~/aoc-workspace/projects/Final_project

make tb_mac        # 第一個跑,確認 toolchain 通
make tb_tree       # 跑 merge tree 測試
make tb_pe_row     # 跑 PE row 測試
```

### 1.3 看波形(只在 debug 時用)
```bash
gtkwave tb_pe_row.vcd
# 會跳出 GUI,把左邊訊號拖到右邊看波形
```

---

## 2. 路徑 B:AOC Docker — 跟交作業環境一致

### 2.1 啟動 Docker
```bash
docker run -it --rm \
  -v ~/aoc-workspace/projects/Final_project:/work \
  ghcr.io/ai-on-chip-at-ncku-ee/aoc-docker-env:v1.1 \
  bash
```

`-v ~/...:/work` 把本機資料夾掛進 Docker 的 `/work`,改動同步。

### 2.2 確認 iverilog 在 Docker 內(可能要裝)
```bash
# 進 Docker 後
which iverilog
# 如果找不到:
apt update && apt install -y iverilog gtkwave
```

### 2.3 跑測試
```bash
cd /work
make tb_mac
make tb_tree
make tb_pe_row
```

### 2.4 看波形
gtkwave 在 Docker 內**不會顯示 GUI**(因為沒接 X server)。
解法:把 `.vcd` 拷回本機,本機開 gtkwave。
```bash
# 因為 -v 掛載過,.vcd 直接出現在本機資料夾,exit Docker 後:
exit
cd ~/aoc-workspace/projects/Final_project
gtkwave tb_pe_row.vcd
```

---

## 3. 跑測試的**正確順序**(很重要)

從簡單到複雜,**任何一個 fail 就停下來 debug,不要繼續往下跑**:

```
Step 1: make tb_mac     ── 測 mac_unit (最簡單)
                            ↓ 全 PASS 才繼續
Step 2: make tb_tree    ── 測 merge_tree_radix16
                            ↓ 全 PASS 才繼續
Step 3: make tb_pe_row  ── 測 pe_row (用到 mac + tree)
                            ↓ 全 PASS 表示 PE 內部完整 ✓
Step 4: make lint       ── (可選) Verilator 對全 RTL lint
```

**為什麼這個順序**:後面的 module 內部用前面的 module。如果 mac_unit 壞了,pe_row 一定錯,但你會以為是 pe_row 的問題,debug 走錯方向。

---

## 4. 預期輸出範例

### `make tb_mac` 成功:
```
iverilog -g2012 -o tb_mac.vvp -I rtl rtl/pe/mac_unit.v sim/tb_mac_unit.sv
vvp tb_mac.vvp
VCD info: dumpfile tb_mac_unit.vcd opened for output.
[PASS] T1 reset product=0: product=0
[PASS] T2 7*6=42: product=42
[PASS] T3 127*127=16129: product=16129
[PASS] T4 -64*2=-128: product=-128
[PASS] T5 -100*-3=300: product=300
[PASS] T6 hold when en=0 (still 300): product=300
[PASS] T7 5*4=20 after re-enable: product=20
[PASS] T8 -128*127=-16256: product=-16256
[PASS] T9 -128*-128=16384: product=16384
[PASS] T10 0*99=0: product=0
[PASS] T11 16 sequential muls
[PASS] T12 async reset clears product: product=0
==============================
ALL TESTS PASSED
==============================
```

### `make tb_tree` 成功:
```
[PASS] T1 reset sum=0: sum=0
[PASS] T2 all-ones sum=16: sum=16
[PASS] T3 all-neg-one sum=-16: sum=-16
[PASS] T4 1..16 sum=136: sum=136
[PASS] T5 INT16_MAX*16 sum=524272 (no overflow): sum=524272
[PASS] T6 alternating signs sum=0: sum=0
==============================
ALL TESTS PASSED
==============================
```

### `make tb_pe_row` 成功:
```
[PASS] T1 reset state: c_out=0 c_valid=0
[PASS] T2 ones-dot-ones = 16: c_out=16 c_valid=1
[PASS] T3 [1..16]·[16..1] = 816: c_out=816 c_valid=1
[PASS] T4 acc_clear isolates between dot products: c_out=16 c_valid=1
==============================
ALL TESTS PASSED
==============================
```

---

## 5. Debug:常見錯誤跟解法

### 5.1 編譯錯誤(testbench 還沒跑就死)
```
sim/tb_pe_row.sv:42: syntax error
sim/tb_pe_row.sv:42:        : Syntax in assignment statement l-value.
```
- **看行號**,90% 是括號 / 分號漏了
- 對照其他能跑的 tb 看寫法差異
- iverilog 錯誤訊息有時不精準,可能真正的 bug 在前一行

### 5.2 Testcase FAIL
```
[FAIL] T3 [1..16]·[16..1] = 816: c_out=0 expected=816 c_valid=1
```
**可能原因**:
1. **RTL bug** — pe_row 邏輯有問題
2. **TB timing 對齊錯** — acc_dump 沒對齊到 tree_valid
3. **預期數值算錯** — 我寫 testbench 時手算錯了

**Debug 步驟**:
```bash
gtkwave tb_pe_row.vcd
```
看以下訊號:
| 訊號 | 看什麼 |
|---|---|
| `clk` | 確認時脈在跑 |
| `in_valid` | 第幾拍拉起 |
| `tree_valid`(在 dut 內部) | 是否在第 6 拍拉起 |
| `acc_dump` | 是否在第 6 拍拉起跟 tree_valid 對齊 |
| `tree_sum` | 第 6 拍的值是不是預期的 dot product |
| `acc` | accumulator 內部值 |
| `c_out` | 第 7 拍是否抓到正確值 |

gtkwave 操作:左邊樹狀展開 `tb_pe_row → dut`,把訊號拖到中間波形區。

### 5.3 Timeout
```
[ERR] timeout
```
TB 卡死了。**多半是某個 task 在等永遠不會發生的事**。
- 看是不是 `@(posedge clk)` 但 clk 沒在動(`always #1 clk = ~clk;` 漏了)
- 看是不是 reset 沒解開
- 把 `#50000` 暫時改大(`#500000`)看是不是只是跑太慢

### 5.4 `iverilog: command not found`
沒裝 iverilog。回到 Step 1.1 或 2.2。

### 5.5 `Cannot find module trapezoid_pkg`
忘了把 `trapezoid_pkg.sv` 加進 iverilog 命令。檢查 Makefile target,通常是順序:**pkg 要在最前面**,然後 module 依依賴順序。

### 5.6 Verilator lint warning(`make lint` 用)
```
%Warning-UNUSEDSIGNAL: rtl/top.v:138: Bits of signal are not used
```
**警告不是錯誤**。`make lint` 雖然紅字但只要沒 `%Error` 就 ok。我們有些 stub 故意留 `_unused = &{...}` 結構。

---

## 6. 跑完之後

### 6.1 Commit
所有測試 PASS 才 commit:
```bash
git add Makefile rtl/ sim/
git status                         # 確認沒 add 到不該的
git commit -m "test(rtl): verified mac/tree/pe_row, all testbenches passing"
git push
```

### 6.2 不要 commit 的檔案
這些是 build 產物,`.gitignore` 已 exclude:
- `*.vvp`(iverilog 編譯結果)
- `*.vcd`(波形檔)
- `obj_dir/`(Verilator 產物)

### 6.3 Clean(空間夠就不用)
```bash
make clean
# 等同於: rm -f *.vvp *.vcd && rm -rf obj_dir
```

---

## 7. 下一步:你 RTL 新增 module / 新 testbench 怎麼加 target

照 `tb_tree` 的 pattern,在 Makefile 加 5 行:

```makefile
tb_NEW: $(PKG) \
        $(RTL_DIR)/path/dependency1.v \
        $(RTL_DIR)/path/dependency2.v \
        $(TB_DIR)/tb_NEW.sv
	$(IVERILOG) -g2012 -o tb_NEW.vvp \
		-I$(RTL_DIR) \
		$(PKG) \
		$(RTL_DIR)/path/dependency1.v \
		$(RTL_DIR)/path/dependency2.v \
		$(TB_DIR)/tb_NEW.sv
	vvp tb_NEW.vvp
```

**注意點**:
- iverilog 依依賴順序讀檔(被依賴的 module 要在前面)
- pkg 永遠最前面
- testbench 最後

---

## 8. 一頁 cheat sheet(印出來放手邊)

```
裝工具:   brew install icarus-verilog gtkwave    # 一次性
跑測試:   cd ~/aoc-workspace/projects/Final_project
          make tb_mac && make tb_tree && make tb_pe_row
看波形:   gtkwave tb_pe_row.vcd
全清掉:   make clean
Commit:   git add Makefile rtl/ sim/ && git commit && git push
Docker:   docker run -it --rm -v $(pwd):/work \
          ghcr.io/ai-on-chip-at-ncku-ee/aoc-docker-env:v1.1 bash
```

---

## 9. 我需要幫忙時 ping 誰

- **iverilog / SV 語法問題** — Iris 或 Google
- **TB testcase 數字對不對** — 拿 numpy 驗:`python3 -c "import numpy as np; print(np.dot([1]*16, [1]*16))"`
- **RTL 行為對不對** — 看 paper Fig 6 / 7,或對齊 `docs/interfaces.md` 契約
- **波形看不懂** — gtkwave 截圖丟群組討論
