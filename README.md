# AOC 2026 Spring — Final Project (Group 13)

> Trapezoid (ISCA'24) TrIP-style sparse accelerator implementation, scaled and adapted to the AOC course's Eyeriss-style baseline (VGG-8 / 6×8 PE / 64 KiB GLB).

**Reference paper**: M. Yan et al., "Trapezoid: A Versatile Accelerator for Dense and Sparse Matrix Multiplications," ISCA 2024.
**Course**: NCKU EE — Architecture of Computing Systems (AOC), Spring 2026.

---

## 📂 目錄結構

```
Final_project/
├── README.md                  # ← 你正在看這個
├── .gitignore                 # macOS / Python / EDA artefacts
├── docs/
│   ├── git-workflow.md        # 團隊整合 (push/PR) 細流程
│   └── proposal-review.md     # 提案 vs Trapezoid 論文 gap 分析
├── quantization/              # Lab 1/2 衍生 VGG-8 量化模型
├── analysis/                  # Lab 2 analytical model 延伸（PE sweep / roofline）
├── rtl/                       # Verilog RTL（之後加入）
├── sim/                       # 模擬腳本 / testbench
└── reference/                 # 提案 PDF、論文 PDF
```

---

## 🚀 Quick Start

### 1. 啟動 AOC Docker 環境

```bash
cd /Users/<你>/aoc-workspace/projects
./docker.sh run
# 進到容器後
cd ~/projects/Final_project
```

容器內已有 `git`、`openssh`、Python、Verilator、Vivado tools 等。

> ⚠️ **Git 操作建議在 host 端執行**（容器內的 git config 是另一份，commit 作者可能跑掉）。

### 2. Clone（給新組員看）

```bash
gh repo clone quill0224/aoc-final-group13 ~/aoc-workspace/projects/Final_project
# 或用 https
git clone https://github.com/quill0224/aoc-final-group13.git ~/aoc-workspace/projects/Final_project
```

### 3. 第一次 commit 的最短路徑

```bash
git switch main
git pull --rebase
git switch -c feat/<你的名字>-<topic>     # 例：feat/po-fc-tiling-analysis
# ... 改 code ...
git add <files>
git commit -m "feat: <一句話描述做了什麼>"
git push -u origin feat/<你的名字>-<topic>
gh pr create --fill --web                  # 開瀏覽器發 PR
```

完整流程與救援指令見 [`docs/git-workflow.md`](docs/git-workflow.md)。

---

## 🛣️ Milestones (8-week schedule, per proposal)

| Week | 內容 | 主責 |
|------|------|------|
| 1–2  | Lab 1/2 quantization model 移植 + 分析 | TBD |
| 3–4  | Analytical model 延伸（PE sweep / roofline） | TBD |
| 5–6  | RTL 主要模組（PE array, MFIU, GLB） | TBD |
| 7    | RTL 整合 + simulation debug | TBD |
| 8    | End-to-end inference + 報告 | TBD |

里程碑與分工填入請改 PR 不要直接 push 到 main。

---

## ⚠️ 已知技術疑慮

組長在 proposal 階段提出三個關鍵問題，已彙整在 [`docs/proposal-review.md`](docs/proposal-review.md)：

1. **PE array 大小**：提案 16×16 vs 論文 128×128（縮 80×），缺 sensitivity 分析
2. **FC layer 記憶體**：GLB 16 KiB 完全不足，未提 tiling 策略
3. **NoC 拓樸**：提案無拓樸設計，論文用 4-cluster × 32-row + Benes distribution

請在動 RTL 之前，先看完 `docs/proposal-review.md`，並在 `analysis/` 跑出對應數據，再決定是否修 v2 提案。

---

## 👥 隊員

| GitHub | 姓名 | 主責 |
|--------|------|------|
| @quill0224 | Quill | TBD |
| @JackyPeng066 | 彭俞凱 | Architecture/Dataflow/MFIU |
| TBD | TBD | TBD |
| TBD | TBD | TBD |

