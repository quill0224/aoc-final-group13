# baseline — first canonical sweep run

第一份正式跑出來的 sweep 結果。**committed 進 repo 是為了讓全組共享數據**，不用每個人都重跑一次。

## 來源
- 跑於：2026-05-08
- 跑者：@quill0224
- 環境：AOC Docker (`aoc2026-container`)
- 命令：`python -m analysis.sweeps.run_all`
- Code commit: PR #5 merged (含 `fix/fc_analysis-overhead` bugfix)

## 包含什麼

| 檔 | 內容 |
|---|---|
| `pe_sweep.csv` / `pe_latency.png` | PE array 配置 6×8 / 8×8 / 12×8 / 16×16 / 32×16 對 conv latency 的影響 |
| `glb_sweep.csv` / `glb_dram.png` | GLB 16/32/64/128/256/512 KiB 對 DRAM access 的影響（fix PE=6×8） |
| `fc_analysis.csv` / `fc_tiles.png` | VGG-8 三個 FC layer 在不同 GLB 下的 tile 數 |

## 三句話結論

1. **PE 16×16** 比 baseline 6×8 快 **1.56×**；32×16 進一步到 1.79× 但 area 翻倍
2. **GLB**：conv 從 16 KiB → 64 KiB 省 17% DRAM；128 KiB saturate
3. **FC6 (1 MiB INT8)** 在任何合理 on-chip GLB 都需要 streaming，連 1 MiB GLB 都還要 2 tile

完整解讀見 `docs/proposal-review.md`。

## 如果要更新 baseline

- 不要直接覆蓋這個資料夾——開新 PR、寫 changelog
- 或把舊版搬到 `baseline-archive-YYYYMMDD/`（這類 archive 由 .gitignore 排除）
