"""Run all 3 sweeps end-to-end and place outputs under analysis/results/sweeps_<ts>/.

Usage:
    python -m analysis.sweeps.run_all
"""

from __future__ import annotations

import argparse
import time
from pathlib import Path

from analysis.sweeps import fc_analysis, glb_sweep, pe_sweep


def main() -> None:
    parser = argparse.ArgumentParser(description="Run pe / glb / fc sweeps end-to-end")
    parser.add_argument(
        "--output", type=str,
        default=f"./analysis/results/sweeps_{time.strftime('%Y%m%d-%H%M%S')}",
    )
    args = parser.parse_args()

    base = Path(args.output).absolute()
    base.mkdir(parents=True, exist_ok=True)

    # PE sweep
    print("\n=== [1/3] PE-array sweep ===\n")
    pe_df = pe_sweep.run_sweep(pe_sweep.DEFAULT_PE_CONFIGS, glb_kib=64, bus_bw=4)
    pe_df.to_csv(base / "pe_sweep.csv", index=False)
    pe_sweep.plot_latency_per_config(pe_df, base / "pe_latency.png")

    # GLB sweep (use course baseline PE)
    print("\n=== [2/3] GLB-size sweep (PE 6x8) ===\n")
    glb_df = glb_sweep.run_sweep(pe_h=6, pe_w=8, glb_list=glb_sweep.DEFAULT_GLB_KIB, bus_bw=4)
    glb_df.to_csv(base / "glb_sweep.csv", index=False)
    glb_sweep.plot_dram_per_glb(glb_df, base / "glb_dram.png")

    # FC analysis
    print("\n=== [3/3] FC-layer memory analysis ===\n")
    fc_df = fc_analysis.run([16, 32, 64, 128, 256, 512, 1024])
    fc_df.to_csv(base / "fc_analysis.csv", index=False)
    fc_analysis.plot_tiles(fc_df, base / "fc_tiles.png")

    print(f"\n✓ All sweeps complete. Outputs at {base}")


if __name__ == "__main__":
    main()
