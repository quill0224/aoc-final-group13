# tests/ — verification scripts

驗證 Lab 1 量化 + Lab 2 analytical model port 是否正確的 4 個 script。
**目的**：proposal 報告之前確認所有 sweep 數字 (PE 1.56× / GLB 128 KiB saturate / FC6 1 MiB) 站得住。

## Quick start

`test_power2_observer.py` 和 `test_lab1_accuracy.py` 需要 torch（host 沒裝），所以走 AOC docker。
`test_lab2_invariants.py` 和 `test_lab2_baseline.py` 純 Python stdlib，host 直接跑也行。

```bash
# Host (只跑 Lab 2 兩個)
cd ~/aoc-workspace/projects/Final_project
python3 tests/test_lab2_invariants.py
python3 tests/test_lab2_baseline.py

# Docker (推薦，所有 4 個都能跑)
./docker.sh run            # 在 ~/aoc-workspace/ 跑這個
# 進到容器後：
cd ~/projects/Final_project
python3 tests/run_all.py            # 快測 (~5 秒)
python3 tests/run_all.py --full     # +Lab 1 e2e (~5-10 分鐘)
python3 tests/run_all.py --full --quick-lab1  # Lab 1 只跑 1000 樣本 (~1 分鐘)
```

或用 `docker exec`（不用進容器）：
```bash
docker exec aoc2026-container bash -c "cd ~/projects/Final_project && python3 tests/run_all.py"
```

## 4 個 script 各自抓什麼

| Script | 速度 | 抓的 bug | 不需要 |
|---|---|---|---|
| `test_power2_observer.py` | <1s | scale 沒 snap 到 $2^{-c}$、`max_shift_amount` clip 失效、dtype↔zero_point 配對錯 | dataset、weights |
| `test_lab2_invariants.py` | <1s | macs 公式漏維度、Mapper 產出違反 GLB capacity、`bound_by` 跟 OI 對不上、maxpool ofmap 沒縮 $k^2$ | dataset、weights、lab2 reference |
| `test_lab2_baseline.py` | ~5s | 我們的 port 跟 lab2/src 任何 numerical 偏差（per 5 layer × 20 mappings × ~70 fields = ~7000 比對） | dataset、weights |
| `test_lab1_accuracy.py` | 5-10 min | BN folding 壞掉、quantization config 漂移、PTQ pipeline 端到端崩 | — |

## 個別跑

```bash
python tests/test_power2_observer.py
python tests/test_lab2_invariants.py --pe-h 16 --pe-w 16 --glb-kib 128 --bus-bw 8
python tests/test_lab2_baseline.py --max-mappings 50
python tests/test_lab1_accuracy.py --quick --copy-weights
```

每個 script：
- 頂端 docstring 寫用法 + 它能抓什麼 bug
- `CONFIG` block 在頂端，可改 default
- argparse 可命令列覆蓋
- exit code: 0 = pass, 1 = fail
- 輸出 `[OK  ]` / `[FAIL]` 標籤好閱讀

## 對 proposal 報告為何重要

- `test_lab2_baseline.py` PASS → 表示 sweep 數字 (PE 1.56× / GLB saturate / FC6) 跟 Lab 2 助教 reference 算法 byte-equal（5 layer × 20 mapping × ~70 field ≈ 7000 比對），數字可信
- `test_lab2_invariants.py` PASS → 表示 roofline `bound_by` 標籤可信，且揭露一個重要事實：**6×8 PE + 4 B/cy bus 下 5 個 conv 層全部 memory-bound**（OI 3.4–4.7 vs balance 12）。v1 提案以為是 compute-bound 是錯的；v2 把 bus 拉到 8 B/cy 的決策因此立得住
- `test_power2_observer.py` PASS → 表示量化 scale 真的是 $2^{-c}$（hardware 可以用 shift 取代除法）
- `test_lab1_accuracy.py` PASS → 表示 INT8 91.58% 不是空話，而是我們的 pipeline 跑出來的

## 失敗處理

任一 FAIL：
1. 讀錯誤訊息上方那個 `[FAIL]` 行，找出哪個 field / case 對不上
2. 看 `analysis/eyeriss/eyeriss.py` 對應公式 vs `~/aoc-workspace/projects/lab2/src/analytical_model/eyeriss.py`
3. 量化部分對 `quantization/quantize.py` vs Lab 1 notebook (`~/EE/碩ㄧ課/AOC/aoc2026-lab1/Q36144200_Lab1.ipynb`)
4. 修完重跑 `python tests/run_all.py`

## CI 整合（未來）

把 `python tests/run_all.py` 串進 GitHub Actions，每次 PR 自動跑 fast tests，merge 前必過。
