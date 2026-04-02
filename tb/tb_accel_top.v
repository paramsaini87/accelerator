// ============================================================================
// Testbench: accel_top — Bus Integration Verification
//
// Tests the accelerator through the CPU-native memory interface:
//   1. Reset + status check
//   2. Identity matrix (A × I = A)
//   3. All-ones matrix
//   4. Signed negatives
//   5. Random matrices (5 tests)
//   6. Back-to-back operations
//   7. Config register test
//
// Protocol: req/ready handshake with addr/wdata/wstrb/rdata
// ============================================================================

`timescale 1ns / 1ps

module tb_accel_top;

    // ── Clock / Reset ────────────────────────────────────────────────
    reg        clk;
    reg        rst_n;
    initial    clk = 0;
    always #5  clk = ~clk;  // 100 MHz

    // ── Bus Signals ──────────────────────────────────────────────────
    reg  [31:0] addr;
    reg  [31:0] wdata;
    reg  [3:0]  wstrb;
    reg         req;
    wire [31:0] rdata;
    wire        ready;
    wire        irq;

    // ── DUT ──────────────────────────────────────────────────────────
    accel_top dut (
        .clk    (clk),
        .rst_n  (rst_n),
        .addr   (addr),
        .wdata  (wdata),
        .wstrb  (wstrb),
        .req    (req),
        .rdata  (rdata),
        .ready  (ready),
        .irq    (irq)
    );

    // ── Register Addresses ───────────────────────────────────────────
    localparam CTRL     = 32'h000;
    localparam STATUS   = 32'h004;
    localparam CONFIG   = 32'h008;
    localparam A_BASE   = 32'h100;  // A matrix: 0x100-0x13C
    localparam B_BASE   = 32'h200;  // B matrix: 0x200-0x23C
    localparam R_BASE   = 32'h300;  // Results:  0x300-0x3FC

    // ── Test Infrastructure ──────────────────────────────────────────
    integer pass_count, fail_count, test_num;
    integer i, j, k;

    reg signed [7:0]  mat_a [0:7][0:7];
    reg signed [7:0]  mat_b [0:7][0:7];
    reg signed [31:0] mat_c [0:7][0:7];  // golden
    reg signed [31:0] mat_r [0:7][0:7];  // DUT result

    // ── Bus Tasks ────────────────────────────────────────────────────
    task bus_write(input [31:0] a, input [31:0] d);
    begin
        @(posedge clk); #1;
        addr  = a;
        wdata = d;
        wstrb = 4'hF;
        req   = 1;
        @(posedge clk); #1;
        while (!ready) @(posedge clk);
        #1;
        req = 0;
    end
    endtask

    task bus_read(input [31:0] a, output [31:0] d);
    begin
        @(posedge clk); #1;
        addr  = a;
        wstrb = 4'h0;
        req   = 1;
        @(posedge clk); #1;
        while (!ready) @(posedge clk);
        #1;
        d = rdata;
        req = 0;
    end
    endtask

    // ── Golden Model ─────────────────────────────────────────────────
    task compute_golden;
        integer gi, gj, gk;
    begin
        for (gi = 0; gi < 8; gi = gi + 1)
            for (gj = 0; gj < 8; gj = gj + 1) begin
                mat_c[gi][gj] = 0;
                for (gk = 0; gk < 8; gk = gk + 1)
                    mat_c[gi][gj] = mat_c[gi][gj] +
                        ($signed(mat_a[gi][gk]) * $signed(mat_b[gk][gj]));
            end
    end
    endtask

    // ── Load A matrix via bus ────────────────────────────────────────
    task load_a_matrix;
        integer row;
    begin
        for (row = 0; row < 8; row = row + 1) begin
            // Low 4 bytes: A[row][0..3]
            bus_write(A_BASE + row * 8,
                      {mat_a[row][3], mat_a[row][2], mat_a[row][1], mat_a[row][0]});
            // High 4 bytes: A[row][4..7]
            bus_write(A_BASE + row * 8 + 4,
                      {mat_a[row][7], mat_a[row][6], mat_a[row][5], mat_a[row][4]});
        end
    end
    endtask

    // ── Load B matrix via bus ────────────────────────────────────────
    task load_b_matrix;
        integer row;
    begin
        for (row = 0; row < 8; row = row + 1) begin
            bus_write(B_BASE + row * 8,
                      {mat_b[row][3], mat_b[row][2], mat_b[row][1], mat_b[row][0]});
            bus_write(B_BASE + row * 8 + 4,
                      {mat_b[row][7], mat_b[row][6], mat_b[row][5], mat_b[row][4]});
        end
    end
    endtask

    // ── Read Result matrix via bus ───────────────────────────────────
    task read_results;
        integer ri, ci;
        reg [31:0] val;
    begin
        for (ri = 0; ri < 8; ri = ri + 1)
            for (ci = 0; ci < 8; ci = ci + 1) begin
                bus_read(R_BASE + (ri * 8 + ci) * 4, val);
                mat_r[ri][ci] = $signed(val);
            end
    end
    endtask

    // ── Full Matrix Multiply via Bus ─────────────────────────────────
    task bus_matmul;
        reg [31:0] status;
    begin
        // Load matrices
        load_a_matrix;
        load_b_matrix;

        // Start
        bus_write(CTRL, 32'h01);

        // Poll for done
        status = 32'd0;
        while (!status[1]) begin
            repeat(10) @(posedge clk);
            bus_read(STATUS, status);
        end

        // Read results
        read_results;

        // Clear done
        bus_write(STATUS, 32'h02);
    end
    endtask

    // ── Compare Results ─────────────────────────────────────────────
    task check_results(input [255:0] test_name);
        integer ci, cj;
        integer local_fail;
    begin
        local_fail = 0;
        for (ci = 0; ci < 8; ci = ci + 1)
            for (cj = 0; cj < 8; cj = cj + 1)
                if (mat_r[ci][cj] !== mat_c[ci][cj]) begin
                    if (local_fail < 10)
                        $display("  FAIL [%0d,%0d]: expected %0d, got %0d",
                                 ci, cj, mat_c[ci][cj], mat_r[ci][cj]);
                    local_fail = local_fail + 1;
                end
        if (local_fail == 0) begin
            pass_count = pass_count + 1;
            $display("  PASS: %0s", test_name);
        end else begin
            fail_count = fail_count + 1;
            $display("  FAIL: %0s (%0d mismatches)", test_name, local_fail);
        end
    end
    endtask

    // ── Reset ────────────────────────────────────────────────────────
    task reset_system;
    begin
        rst_n = 0;
        addr  = 0;
        wdata = 0;
        wstrb = 0;
        req   = 0;
        repeat(4) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);
        #1;
    end
    endtask

    // ── LFSR ─────────────────────────────────────────────────────────
    reg [31:0] lfsr;
    function [7:0] rand8;
        input dummy;
    begin
        lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
        rand8 = lfsr[7:0];
    end
    endfunction

    // ── Main Test ────────────────────────────────────────────────────
    initial begin
        pass_count = 0;
        fail_count = 0;
        lfsr = 32'hCAFE_BABE;

        $display("========================================");
        $display("  Accelerator Bus Integration TB");
        $display("========================================");

        // ── TEST 1: Reset + Status ──────────────────────────────────
        test_num = 1;
        $display("\n[Test 1] Reset and status check");
        reset_system;
        begin
            reg [31:0] status;
            bus_read(STATUS, status);
            if (status[0] !== 1'b0) begin
                $display("  FAIL: busy after reset: %08h", status);
                fail_count = fail_count + 1;
            end else begin
                $display("  PASS: Status clean after reset");
                pass_count = pass_count + 1;
            end
        end

        // ── TEST 2: Identity matrix ─────────────────────────────────
        test_num = 2;
        $display("\n[Test 2] Identity matrix: A × I = A");
        reset_system;
        for (i = 0; i < 8; i = i + 1)
            for (j = 0; j < 8; j = j + 1) begin
                mat_a[i][j] = i * 8 + j + 1;
                mat_b[i][j] = (i == j) ? 8'd1 : 8'd0;
            end
        compute_golden;
        bus_matmul;
        check_results("Identity via bus");

        // ── TEST 3: All-ones ────────────────────────────────────────
        test_num = 3;
        $display("\n[Test 3] All-ones: A[3] × B[2]");
        reset_system;
        for (i = 0; i < 8; i = i + 1)
            for (j = 0; j < 8; j = j + 1) begin
                mat_a[i][j] = 8'd3;
                mat_b[i][j] = 8'd2;
            end
        compute_golden;
        bus_matmul;
        check_results("All-ones via bus");

        // ── TEST 4: Signed negatives ────────────────────────────────
        test_num = 4;
        $display("\n[Test 4] Signed: A=-1, B=sequential");
        reset_system;
        for (i = 0; i < 8; i = i + 1)
            for (j = 0; j < 8; j = j + 1) begin
                mat_a[i][j] = -8'd1;
                mat_b[i][j] = j + 1;
            end
        compute_golden;
        bus_matmul;
        check_results("Signed negatives via bus");

        // ── TEST 5: Edge values ─────────────────────────────────────
        test_num = 5;
        $display("\n[Test 5] Edge: A=127, B=-128");
        reset_system;
        for (i = 0; i < 8; i = i + 1)
            for (j = 0; j < 8; j = j + 1) begin
                mat_a[i][j] = 8'd127;
                mat_b[i][j] = -8'd128;
            end
        compute_golden;
        bus_matmul;
        check_results("INT8 edge via bus");

        // ── TEST 6-10: Random matrices ──────────────────────────────
        for (k = 0; k < 5; k = k + 1) begin
            test_num = 6 + k;
            $display("\n[Test %0d] Random matrix %0d", test_num, k+1);
            reset_system;
            for (i = 0; i < 8; i = i + 1)
                for (j = 0; j < 8; j = j + 1) begin
                    mat_a[i][j] = rand8(0);
                    mat_b[i][j] = rand8(0);
                end
            compute_golden;
            bus_matmul;
            check_results("Random via bus");
        end

        // ── TEST 11-12: Back-to-back ────────────────────────────────
        test_num = 11;
        $display("\n[Test 11] Back-to-back #1");
        reset_system;
        for (i = 0; i < 8; i = i + 1)
            for (j = 0; j < 8; j = j + 1) begin
                mat_a[i][j] = i + j;
                mat_b[i][j] = i - j;
            end
        compute_golden;
        bus_matmul;
        check_results("Back-to-back #1");

        test_num = 12;
        $display("\n[Test 12] Back-to-back #2 (no reset)");
        for (i = 0; i < 8; i = i + 1)
            for (j = 0; j < 8; j = j + 1) begin
                mat_a[i][j] = (i * j) & 8'h7F;
                mat_b[i][j] = ((i+1) * (j+1)) & 8'h7F;
            end
        compute_golden;
        bus_matmul;
        check_results("Back-to-back #2");

        // ── RESULTS ─────────────────────────────────────────────────
        $display("\n========================================");
        $display("  RESULTS: %0d passed, %0d failed", pass_count, fail_count);
        $display("========================================");
        if (fail_count == 0)
            $display("  *** ALL TESTS PASSED ***");
        else
            $display("  *** %0d FAILURES ***", fail_count);
        $display("");
        $finish;
    end

    // Timeout
    initial begin
        #50_000_000;
        $display("TIMEOUT after 50ms");
        $finish;
    end

endmodule
