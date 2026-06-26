# Trapezoid-Lite Accelerator Hardware Architecture

## 1. System Architecture Overview

The Trapezoid-Lite accelerator is designed for dense and sparse matrix multiplications, utilizing a TSMC 16nm (N16ADFP) technology node. The system architecture consists of a top-level wrapper (`integration.sv`) that orchestrates multiple hardware intellectual property (IP) blocks across distinct functional domains.

The core components include:
* **Controller (`controller.sv`)**: The central finite state machine (FSM) governing the operational scheduling and module synchronization.
* **Memory Controller (`MC.sv`)**: Decodes compressed sparse packets and dispatches metadata and payloads to the processing elements.
* **Direct Memory Access (`DMA.sv`)**: An AXI4 Master responsible for transferring data between external DRAM and the internal Global Buffer.
* **Global Buffer (`GLB.sv`)**: A 16 KB on-chip SRAM array acting as a shared buffer for input feature maps (IFMAP), filters, and output feature maps (OFMAP).
* **PE Array (`pe_array.sv`)**: A 16x16 computational array comprising Multi-Fiber Intersection Units (MFIU), multiplication lanes, and a segmented reduction tree.

## 2. Control Flow

The control mechanism is driven by a unified 32-bit command register (`asic_cmd_in`) and executes an Input Stationary (IS) dataflow.

### Command-Driven Initialization
The `asic_cmd_in` register encapsulates the operational parameters:
* **Start**: Trigger execution.
* **Mode**: Selects between Dense (Standard IP) and Sparse (TrIP) execution.
* **Matrix Dimensions ($M, K, N$)**: Defines the tile iteration bounds.

### Input Stationary (IS) FSM Scheduling
The `controller` implements a 14-state hierarchical FSM that manages a nested loop order of $M \rightarrow K \rightarrow N$.
1.  **Outer Loop ($M$)**: Spatial mapping tile.
2.  **Middle Loop ($K$)**: Input channel depth. Psums are accumulated in the PE local buffer during this loop.
3.  **Inner Loop ($N$)**: Output channel sliding. IFMAP ($A$) remains stationary in the GLB while Filter ($B$) streams across the $N$ iterations.

### Module Synchronization
The `controller` dispatches synchronization signals to downstream modules:
* `DMA_en` / `DMA_mode`: Triggers DMA fetch or writeback phases.
* `mc_start` / `k_done`: Initiates MC packet dispatch and monitors loop completion.
* `pe_first_pass`: Instructs the PE local buffer to overwrite previous values during the initial $K$-tile iteration.
* `pe_cur_n_base`: Specifies the base column offset in the local buffer for the current $N$-tile.

## 3. Data Flow and Memory Subsystem

The data path forms a continuous pipeline: External DRAM $\rightarrow$ GLB $\rightarrow$ MC $\rightarrow$ PE Array $\rightarrow$ GLB $\rightarrow$ External DRAM.

### AXI4 DMA Transfers
The `DMA` module operates as an AXI4 Master executing INCR bursts.
* **Read (Fetch)**: Direct sequential write to the GLB without buffering.
* **Write (Writeback)**: Utilizes a 16-deep FIFO to decouple the 1-cycle GLB read latency from AXI `WREADY` stalls, ensuring bus compliance.
* **Chunking**: Automatically fragments requests exceeding 1024 bytes into compliant 256-beat bursts.

### Global Buffer (GLB) Allocation
The `GLB` is constructed from 16 instantiated TSMC N16ADFP `SRAM_rtl` macros (128 words $\times$ 64 bits).
* It supports byte-addressing via a 4-bit write strobe (`WSTRB`) and outputs 32-bit aligned data (`DO`).
* An internal arbiter grants read priority to the `MC` over the `DMA` to prevent PE starvation during operation.

### Memory Controller (MC) Packet Processing
The `MC` fetches data from the GLB and unpacks it for the PE array. Data is structured in 160-bit packets (20 bytes, 5 AXI beats).
* **Header (Word 0)**: Contains the 16-bit effective Length and 16-bit Bitmask.
* **Payload (Words 1-4)**: Contains up to 16 INT8 non-zero (NZ) values, packed four per 32-bit word.
* **Bypass Routing**: To mitigate the 1-cycle SRAM read latency, the `MC` bypasses the GLB read data (`glb_rdata_A`) directly to the `pe_data_nzvalue` output port during the data payload phase.

## 4. Sub-system Port Mappings

The `integration.sv` wrapper defines the signal contracts between major intellectual property blocks.

### AXI4 Memory Interface (DMA to External DRAM)
| Port Group | Signals | Description |
| :--- | :--- | :--- |
| **AR Channel** | `araddr`, `arlen`, `arsize`, `arburst`, `arvalid`, `arready` | Read address and control for DMA fetch. |
| **R Channel** | `rdata`, `rresp`, `rlast`, `rvalid`, `rready` | Read data payload from DRAM. |
| **AW Channel** | `awaddr`, `awlen`, `awsize`, `awburst`, `awvalid`, `awready` | Write address and control for DMA writeback. |
| **W / B Channels** | `wdata`, `wstrb`, `wlast`, `wvalid`, `wready`, `bresp` | Write data payload and completion response. |

### MC to PE Array Interface
The communication between the Memory Controller and the PE Array employs two independent AXI-Stream-style channels utilizing `valid`/`ready` backpressure.

| Signal Name | Width | Direction (MC view) | Description |
| :--- | :--- | :--- | :--- |
| `pe_cfg_valid` / `ready` | 1 | Output / Input | Handshake for packet metadata. |
| `pe_cfg_length` | 16 | Output | Effective non-zero element count. |
| `pe_cfg_bitmask` | 16 | Output | Sparsity representation for MFIU processing. |
| `pe_data_valid` / `ready` | 1 | Output / Input | Handshake for packed non-zero data. |
| `pe_data_nzvalue` | 32 | Output | Bypassed GLB payload containing four INT8 values. |
