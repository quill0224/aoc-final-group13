# AOC 2026 Spring — Final Project (Group 13)
# Trapezoid-Lite: A Versatile Edge Accelerator for Dense and Sparse Matrices

This repository contains the implementation of **Trapezoid-Lite**, an EPU-style dense/sparse matrix accelerator inspired by the Trapezoid (ISCA'24) TrIP architecture. It integrates a system-level SoC environment including a CPU, Watchdog Timer, DRAM, DMA, Memory Controller, Global Buffer (GLB), and a 16×16 PE Array running sparse matrix computations (TrIP mode) and dense computations (Standard IP mode).

---

## 📂 Repository Directory Structure

This repository is split into two directories to facilitate seamless verification and replication across different environments:

1. **`AIOC_SYSTEM/` (Recommended for TAs / School SOC Workstation)**
   * **Target Environment**: Standard school SOC workstations (CIC/TSRI environment).
   * **Path Configuration**: All standard library and technology files are pre-configured to point to the official `/usr/cad/CBDK/...` mount points on the workstation.
   * **Replication**: Zero-configuration required. TAs can directly navigate here to compile, synthesize, and run simulations.

2. **`AIOC_SYSTEM_lab/` (For Lab Workstation / Local Server)**
   * **Target Environment**: The development team's private laboratory server.
   * **Path Configuration**: Configured with private mount points (such as `/nas0/proc/virtual/ADFP/...` and `/home/113_Lichtck03/...`).
   * **Usage**: Used for active development and local simulations.

---

## 🛠️ Environment Prerequisites

To compile, synthesize, and simulate this project, the following CAD tools are required (standard on the school's workstation):
* **Synopsys VCS** (v2020.12 or compatible)
* **Synopsys Design Compiler** (T-2022.03)
* **Cadence Innovus** (v21.19-s058_1 with Stylus Common UI support)
* **Verilator** (optional, for standalone module verification)

---

## 🚀 Execution & Replication Steps (on School SOC Workstation)

To reproduce the demo and simulation results, please navigate to the pre-configured school workstation directory:
```bash
cd AIOC_SYSTEM
```

### 1. RTL Simulation
Run all 5 integration test workloads (`prog0` to `prog4`) to verify the functional behavior of the system:
```bash
make rtl_all
```
Or run a specific workload (e.g., the EPU MMIO integration test `prog4`):
```bash
make rtl4
```
All simulation outputs and comparison results will be compiled and executed inside the `build/` directory.

### 2. Logic Synthesis
Perform logic synthesis using Synopsys Design Compiler. The design is constrained at **200 MHz (5.0 ns period)**:
```bash
make synthesize
```
This command copies the setup file and compiles the design, outputting the gate-level netlist `CHIP_syn.v` and standard delay file `CHIP_syn.sdf` to the `syn/` directory. Synthesis execution log is saved in `build/syn_compile.log`.

### 3. Post-Synthesis Gate-Level Simulation
Run timing-annotated gate-level simulations using VCS with back-annotated SDF:
```bash
make syn_all
```
Or run a specific post-synthesis case (e.g., `syn4` for the EPU workload):
```bash
make syn4
```
This ensures the synthesized design operates correctly under the worst-case delays (`ss0p72vm40c` corner) with zero mismatches against the Golden model.

### 4. Physical Design (APR)
The physical design flow runs on Cadence Innovus. 

#### Step A: Generate Custom SRAM LEFs
Before running Innovus, execute the custom LEF generation script to resolve physical frame mismatches and filter out extra SRAM pins not defined in the logical `.lib` file (this filters `Q`, `D`, `BWEB` down to 32-bit and sets correct physical boundaries):
```bash
cd APR_new/innovus_stylus/APR
tclsh generate_custom_lefs.tcl
```
Expected output: Custom LEFs generated under `file_preparation/design/`.

#### Step B: Run Innovus Flow
Start Innovus in Stylus common UI mode:
```bash
innovus -stylus
```
Inside the Innovus command prompt, source the APR runset script:
```tcl
source lab_script/runset.tcl
```
This executes the physical design flow including Design Import, Floorplanning, Powerplanning, Endcap/Welltap Insertion, and Placement/Legalization.

### 5. Post-Layout Simulation
After physical routing and extraction, run post-layout timing simulations:
```bash
cd ../../.. # Back to AIOC_SYSTEM
make pr_all
```
This compiles the post-route netlist (`CHIP_pr.v`) and verifies the design with routed physical delays.
