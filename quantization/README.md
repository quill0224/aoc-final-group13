# quantization/

本目錄存放 Lab 1 / Lab 2 衍生的 VGG-8 量化模型程式碼與權重檔。

## 預期內容
- `vgg8_quantize.py` — 量化主腳本（PTQ / QAT TBD）
- `weights/` — 量化後權重（大檔由 `.gitignore` 排除，使用外部連結或 Git LFS）
- `analysis_quant.ipynb` — Bit-width 對 accuracy 的影響分析

## 進度
- [ ] 從 Lab 1 移植 baseline VGG-8 模型
- [ ] 從 Lab 2 移植量化流程
- [ ] 設定 8-bit / 16-bit 對照實驗
- [ ] 輸出量化後 accuracy / per-layer 統計給 RTL 端使用
