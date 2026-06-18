`timescale 1ns/1ps

module tb_bitmask_buffer;

    // Parameters (match DUT)
    localparam NUM_FIBERS = 4;
    localparam K_BITS     = 4;
    localparam DATA_WIDTH = 16;
    localparam ID_WIDTH   = 4;
    localparam ADDR_WIDTH = $clog2(NUM_FIBERS);   // 2

    // DUT ports
    reg                             clk;
    reg                             reset;
    reg                             wr_en_i;
    reg  [ADDR_WIDTH-1:0]           wr_addr_i;
    reg  [ID_WIDTH-1:0]             wr_id_i;
    reg  [K_BITS-1:0]               wr_mask_i;
    reg  [K_BITS*DATA_WIDTH-1:0]    wr_values_i;
    reg  [ADDR_WIDTH-1:0]           rd_addr_i;
    wire [ID_WIDTH-1:0]             rd_id_o;
    wire [K_BITS-1:0]               rd_mask_o;
    wire [K_BITS*DATA_WIDTH-1:0]    rd_values_o;
    reg  [$clog2(K_BITS)-1:0]       k_sel_i;
    wire [DATA_WIDTH-1:0]           k_value_o;

    // Instantiate DUT
    bitmask_buffer #(
        .NUM_FIBERS (NUM_FIBERS),
        .K_BITS     (K_BITS),
        .DATA_WIDTH (DATA_WIDTH),
        .ID_WIDTH   (ID_WIDTH)
    ) dut (
        .clk        (clk),
        .reset      (reset),
        .wr_en_i    (wr_en_i),
        .wr_addr_i  (wr_addr_i),
        .wr_id_i    (wr_id_i),
        .wr_mask_i  (wr_mask_i),
        .wr_values_i(wr_values_i),
        .rd_addr_i  (rd_addr_i),
        .rd_id_o    (rd_id_o),
        .rd_mask_o  (rd_mask_o),
        .rd_values_o(rd_values_o),
        .k_sel_i    (k_sel_i),
        .k_value_o  (k_value_o)
    );

    // Clock: 10 ns period
    initial clk = 0;
    always #5 clk = ~clk;

    // Test counter
    integer pass_cnt = 0;
    integer fail_cnt = 0;

    // Helper task: write one fiber entry
    task write_fiber;
        input [ADDR_WIDTH-1:0]        addr;
        input [ID_WIDTH-1:0]          id;
        input [K_BITS-1:0]            mask;
        input [K_BITS*DATA_WIDTH-1:0] values;
        begin
            @(negedge clk);
            wr_en_i    = 1'b1;
            wr_addr_i  = addr;
            wr_id_i    = id;
            wr_mask_i  = mask;
            wr_values_i = values;
            @(posedge clk); #1;
            wr_en_i = 1'b0;
        end
    endtask

    // Helper task: read fiber (2-cycle total: set addr, wait 1 rising edge, sample)
    task read_fiber;
        input  [ADDR_WIDTH-1:0]       addr;
        output [ID_WIDTH-1:0]         id;
        output [K_BITS-1:0]           mask;
        output [K_BITS*DATA_WIDTH-1:0] values;
        begin
            @(negedge clk);
            rd_addr_i = addr;
            @(posedge clk); #1;
            id     = rd_id_o;
            mask   = rd_mask_o;
            values = rd_values_o;
        end
    endtask

    // Helper task: check and print result
    task check;
        input [127:0] name;   // test label (packed string)
        input         got;
        input         expected;
        begin
            if (got === expected) begin
                $display("PASS  %s", name);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL  %s  got=%0b expected=%0b", name, got, expected);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // Captured read-back variables
    reg [ID_WIDTH-1:0]          cap_id;
    reg [K_BITS-1:0]            cap_mask;
    reg [K_BITS*DATA_WIDTH-1:0] cap_values;

    initial begin
        // ---------- initialise ----------
        reset      = 1'b1;
        wr_en_i    = 1'b0;
        wr_addr_i  = '0;
        wr_id_i    = '0;
        wr_mask_i  = '0;
        wr_values_i = '0;
        rd_addr_i  = '0;
        k_sel_i    = '0;

        repeat (3) @(posedge clk);
        @(negedge clk); reset = 1'b0;

        // =========================================================
        // TC1: reset clears all entries
        // =========================================================
        read_fiber(2'd0, cap_id, cap_mask, cap_values);
        check("TC1 id=0 after reset  ", (cap_id   === 4'h0), 1'b1);
        check("TC1 mask=0 after reset", (cap_mask  === 4'b0000), 1'b1);

        // =========================================================
        // TC2: write and read back — single entry
        //   addr=0, id=3, mask=4'b1010, values={16'hAAAA,16'h0,16'h5555,16'h0}
        //   slot3=0xAAAA slot2=0x0000 slot1=0x5555 slot0=0x0000
        // =========================================================
        write_fiber(2'd0, 4'd3, 4'b1010,
                    {16'hAAAA, 16'h0000, 16'h5555, 16'h0000});
        read_fiber(2'd0, cap_id, cap_mask, cap_values);
        check("TC2 id readback       ", (cap_id   === 4'd3),   1'b1);
        check("TC2 mask readback     ", (cap_mask  === 4'b1010), 1'b1);
        check("TC2 values readback   ", (cap_values=== {16'hAAAA,16'h0000,16'h5555,16'h0000}), 1'b1);

        // =========================================================
        // TC3: k_sel indexed value extraction
        //   slot1 should be 0x5555, slot3 should be 0xAAAA
        // =========================================================
        @(negedge clk); rd_addr_i = 2'd0; k_sel_i = 2'd1;
        @(posedge clk); #1;
        check("TC3 k_sel=1 => 0x5555 ", (k_value_o === 16'h5555), 1'b1);

        @(negedge clk); k_sel_i = 2'd3;
        @(posedge clk); #1;
        check("TC3 k_sel=3 => 0xAAAA ", (k_value_o === 16'hAAAA), 1'b1);

        @(negedge clk); k_sel_i = 2'd0;   // slot0 is zero
        @(posedge clk); #1;
        check("TC3 k_sel=0 => 0x0000 ", (k_value_o === 16'h0000), 1'b1);

        // =========================================================
        // TC4: write all 4 entries, read each back
        // =========================================================
        write_fiber(2'd0, 4'd0, 4'b0001, {16'h0001, 16'h0000, 16'h0000, 16'h0010});
        write_fiber(2'd1, 4'd1, 4'b0011, {16'h0000, 16'h0000, 16'h0020, 16'h0030});
        write_fiber(2'd2, 4'd2, 4'b0101, {16'h0000, 16'h0040, 16'h0000, 16'h0050});
        write_fiber(2'd3, 4'd3, 4'b1111, {16'h0060, 16'h0070, 16'h0080, 16'h0090});

        read_fiber(2'd0, cap_id, cap_mask, cap_values);
        check("TC4 addr0 id          ", (cap_id   === 4'd0),   1'b1);
        check("TC4 addr0 mask        ", (cap_mask  === 4'b0001), 1'b1);

        read_fiber(2'd1, cap_id, cap_mask, cap_values);
        check("TC4 addr1 id          ", (cap_id   === 4'd1),   1'b1);
        check("TC4 addr1 mask        ", (cap_mask  === 4'b0011), 1'b1);

        read_fiber(2'd2, cap_id, cap_mask, cap_values);
        check("TC4 addr2 id          ", (cap_id   === 4'd2),   1'b1);
        check("TC4 addr2 mask        ", (cap_mask  === 4'b0101), 1'b1);

        read_fiber(2'd3, cap_id, cap_mask, cap_values);
        check("TC4 addr3 id          ", (cap_id   === 4'd3),   1'b1);
        check("TC4 addr3 mask=4'b1111", (cap_mask  === 4'b1111), 1'b1);

        // =========================================================
        // TC5: overwrite existing entry, check other entries untouched
        // =========================================================
        write_fiber(2'd2, 4'd9, 4'b1100, {16'hDEAD, 16'hBEEF, 16'h0000, 16'h0000});

        read_fiber(2'd2, cap_id, cap_mask, cap_values);
        check("TC5 addr2 overwrite id  ", (cap_id   === 4'd9),   1'b1);
        check("TC5 addr2 overwrite mask", (cap_mask  === 4'b1100), 1'b1);

        // addr3 should be unchanged
        read_fiber(2'd3, cap_id, cap_mask, cap_values);
        check("TC5 addr3 untouched id  ", (cap_id   === 4'd3),   1'b1);
        check("TC5 addr3 untouched mask", (cap_mask  === 4'b1111), 1'b1);

        // =========================================================
        // TC6: reset clears everything again
        // =========================================================
        @(negedge clk); reset = 1'b1;
        @(posedge clk); #1;
        @(negedge clk); reset = 1'b0;

        read_fiber(2'd3, cap_id, cap_mask, cap_values);
        check("TC6 reset clears addr3 mask  ", (cap_mask === 4'b0000), 1'b1);
        check("TC6 reset clears addr3 values", (cap_values === {(K_BITS*DATA_WIDTH){1'b0}}), 1'b1);

        // =========================================================
        // Summary
        // =========================================================
        $display("----------------------------------");
        $display("Result: %0d passed, %0d failed", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("ALL PASS");
        else
            $display("SOME FAILURES");
        $display("----------------------------------");
        $finish;
    end

endmodule
