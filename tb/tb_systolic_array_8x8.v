// ============================================================================
// Testbench: systolic_array_8x8 — Matrix Multiply Verification
//
// Tests:
//   1. Identity matrix: A × I = A
//   2. All-ones: ones(8) × ones(8) = 8 × ones(8)
//   3. Known small matrix: hand-computed result
//   4. Random matrices: compare against golden model
//   5. Signed edge cases: max/min INT8 values
//   6. Sequential operations: back-to-back multiplies
// ============================================================================

`timescale 1ns / 1ps

module tb_systolic_array_8x8;

    // ── Clock / Reset ───────────────────────────────────────────────────
    reg        clk;
    reg        rst_n;
    initial clk = 0;
    always #5 clk = ~clk;  // 100 MHz

    // ── DUT Signals ─────────────────────────────────────────────────────
    reg        start;
    wire       busy, done;

    reg  [7:0] wgt_data [0:7];
    reg        wgt_valid;

    reg  [7:0] act_data [0:7];
    reg        act_valid;

    wire [31:0] result_data [0:7];
    wire        result_valid;
    wire [2:0]  result_col;

    // ── DUT ─────────────────────────────────────────────────────────────
    systolic_array_8x8 dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .start        (start),
        .busy         (busy),
        .done         (done),
        .wgt_data     (wgt_data),
        .wgt_valid    (wgt_valid),
        .act_data     (act_data),
        .act_valid    (act_valid),
        .result_data  (result_data),
        .result_valid (result_valid),
        .result_col   (result_col)
    );

    // ── Test Matrices ───────────────────────────────────────────────────
    reg signed [7:0]  mat_a [0:7][0:7];  // Activation matrix (A)
    reg signed [7:0]  mat_b [0:7][0:7];  // Weight matrix (B)
    reg signed [31:0] mat_c [0:7][0:7];  // Expected result (C = A × B)
    reg signed [31:0] mat_r [0:7][0:7];  // Actual result from DUT

    integer pass_count, fail_count, test_num;
    integer i, j, k;

    // ── Golden Model: C = A × B ─────────────────────────────────────────
    task compute_golden;
        integer gi, gj, gk;
    begin
        for (gi = 0; gi < 8; gi = gi + 1)
            for (gj = 0; gj < 8; gj = gj + 1) begin
                mat_c[gi][gj] = 0;
                for (gk = 0; gk < 8; gk = gk + 1)
                    mat_c[gi][gj] = mat_c[gi][gj] + (mat_a[gi][gk] * mat_b[gk][gj]);
            end
    end
    endtask

    // ── Run one matrix multiply through the array ───────────────────────
    // Output-stationary: C[i][j] = Σ_k A[i][k] * B[k][j]
    // A enters from left with row skewing: A[i][k] at time k+i
    // B enters from top with column skewing: B[k][j] at time k+j
    // At PE[i][j], both arrive at time k+i+j (matched)
    // Total compute cycles: 8 + 7 + 7 = 22 (k=0..7, max skew=7+7)
    task run_matmul;
        integer ri, rj, cycle;
        integer max_cycles;
    begin
        max_cycles = 22;  // 8 data + 14 skew/pipeline

        // Phase 1: Start (clears accumulators)
        start = 1;
        @(posedge clk); #1;
        start = 0;

        // Phase 2: Skip weight loading (output-stationary uses streaming)
        // Wait for FSM to move through LOAD state
        // Feed zeros during the 8 LOAD cycles (required by FSM)
        for (ri = 0; ri < 8; ri = ri + 1) begin
            wgt_valid = 1;
            for (rj = 0; rj < 8; rj = rj + 1)
                wgt_data[rj] = 8'd0;
            @(posedge clk); #1;
        end
        wgt_valid = 0;

        // Phase 3: Compute — stream both A (left) and B (top) with skewing
        // Feed 22 cycles total: 15 with data + 7 flush with zeros
        for (cycle = 0; cycle < max_cycles; cycle = cycle + 1) begin
            act_valid = 1;
            wgt_valid = 1;

            // Activations: A[row][k] enters row `row` at cycle k+row
            // At this cycle, row `ri` gets A[ri][cycle - ri]
            for (ri = 0; ri < 8; ri = ri + 1) begin
                rj = cycle - ri;
                if (rj >= 0 && rj < 8)
                    act_data[ri] = mat_a[ri][rj];
                else
                    act_data[ri] = 8'd0;
            end

            // Weights: B[k][col] enters column `col` at cycle k+col
            // At this cycle, column `rj` gets B[cycle - rj][rj]
            for (rj = 0; rj < 8; rj = rj + 1) begin
                ri = cycle - rj;
                if (ri >= 0 && ri < 8)
                    wgt_data[rj] = mat_b[ri][rj];
                else
                    wgt_data[rj] = 8'd0;
            end

            @(posedge clk); #1;
        end
        act_valid = 0;
        wgt_valid = 0;

        // Phase 4: Drain results (8 cycles, one column per cycle)
        for (ri = 0; ri < 8; ri = ri + 1) begin
            @(posedge clk); #1;
            if (result_valid) begin
                for (rj = 0; rj < 8; rj = rj + 1)
                    mat_r[rj][result_col] = $signed(result_data[rj]);
            end
        end

        // Wait for DONE
        while (!done) @(posedge clk);
        #1;
    end
    endtask

    // ── Compare results ─────────────────────────────────────────────────
    task check_results(input [255:0] test_name);
        integer ci, cj;
        integer local_fail;
    begin
        local_fail = 0;
        for (ci = 0; ci < 8; ci = ci + 1)
            for (cj = 0; cj < 8; cj = cj + 1) begin
                if (mat_r[ci][cj] !== mat_c[ci][cj]) begin
                    if (local_fail < 10)
                        $display("  FAIL [%0d,%0d]: expected %0d, got %0d",
                                 ci, cj, mat_c[ci][cj], mat_r[ci][cj]);
                    local_fail = local_fail + 1;
                end
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

    // ── Reset Task ──────────────────────────────────────────────────────
    task reset_dut;
    begin
        rst_n = 0;
        start = 0;
        wgt_valid = 0;
        act_valid = 0;
        for (i = 0; i < 8; i = i + 1) begin
            wgt_data[i] = 0;
            act_data[i] = 0;
        end
        @(posedge clk);
        @(posedge clk);
        rst_n = 1;
        @(posedge clk); #1;
    end
    endtask

    // ── LFSR for pseudo-random generation ───────────────────────────────
    reg [31:0] lfsr;
    function [7:0] rand8;
        input dummy;
    begin
        lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
        rand8 = lfsr[7:0];
    end
    endfunction

    // ── Main Test ───────────────────────────────────────────────────────
    initial begin
        pass_count = 0;
        fail_count = 0;
        lfsr = 32'hDEAD_BEEF;

        $display("========================================");
        $display("  8x8 Systolic Array Matrix Multiply TB");
        $display("========================================");

        // ── TEST 1: Identity matrix (A × I = A) ────────────────────────
        test_num = 1;
        $display("\n[Test 1] Identity matrix: A × I = A");
        reset_dut;

        // A = sequential values
        for (i = 0; i < 8; i = i + 1)
            for (j = 0; j < 8; j = j + 1)
                mat_a[i][j] = i * 8 + j + 1;  // 1..64

        // B = identity
        for (i = 0; i < 8; i = i + 1)
            for (j = 0; j < 8; j = j + 1)
                mat_b[i][j] = (i == j) ? 8'd1 : 8'd0;

        compute_golden;
        run_matmul;
        check_results("Identity");

        // ── TEST 2: All-ones ────────────────────────────────────────────
        test_num = 2;
        $display("\n[Test 2] All-ones: A[all=3] × B[all=2]");
        reset_dut;

        for (i = 0; i < 8; i = i + 1)
            for (j = 0; j < 8; j = j + 1) begin
                mat_a[i][j] = 8'd3;
                mat_b[i][j] = 8'd2;
            end

        compute_golden;  // Each element: 8 × (3×2) = 48
        run_matmul;
        check_results("All-ones (3*2*8=48)");

        // ── TEST 3: Negative values ─────────────────────────────────────
        test_num = 3;
        $display("\n[Test 3] Signed: A=-1, B=sequential");
        reset_dut;

        for (i = 0; i < 8; i = i + 1)
            for (j = 0; j < 8; j = j + 1) begin
                mat_a[i][j] = -8'd1;
                mat_b[i][j] = j + 1;  // 1..8 per row
            end

        compute_golden;
        run_matmul;
        check_results("Signed negatives");

        // ── TEST 4: Max/Min INT8 ────────────────────────────────────────
        test_num = 4;
        $display("\n[Test 4] Edge: A=127, B=-128");
        reset_dut;

        for (i = 0; i < 8; i = i + 1)
            for (j = 0; j < 8; j = j + 1) begin
                mat_a[i][j] = 8'd127;
                mat_b[i][j] = -8'd128;
            end

        compute_golden;  // Each element: 8 × (127 × -128) = 8 × -16256 = -130048
        run_matmul;
        check_results("Max/Min INT8");

        // ── TEST 5-14: Random matrices (10 iterations) ──────────────────
        for (test_num = 5; test_num <= 14; test_num = test_num + 1) begin
            $display("\n[Test %0d] Random matrix %0d", test_num, test_num - 4);
            reset_dut;

            for (i = 0; i < 8; i = i + 1)
                for (j = 0; j < 8; j = j + 1) begin
                    mat_a[i][j] = $signed(rand8(0));
                    mat_b[i][j] = $signed(rand8(0));
                end

            compute_golden;
            run_matmul;
            check_results("Random");
        end

        // ── TEST 15: Back-to-back operations ────────────────────────────
        test_num = 15;
        $display("\n[Test 15] Back-to-back multiply");

        // First multiply
        for (i = 0; i < 8; i = i + 1)
            for (j = 0; j < 8; j = j + 1) begin
                mat_a[i][j] = i + j;
                mat_b[i][j] = i - j;
            end
        compute_golden;
        run_matmul;
        check_results("Back-to-back #1");

        // Second multiply immediately after
        test_num = 16;
        for (i = 0; i < 8; i = i + 1)
            for (j = 0; j < 8; j = j + 1) begin
                mat_a[i][j] = (i * j) & 8'h7F;
                mat_b[i][j] = ((i + 1) * (j + 1)) & 8'h7F;
            end
        compute_golden;
        run_matmul;
        check_results("Back-to-back #2");

        // ── RESULTS ─────────────────────────────────────────────────────
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
        #500_000;
        $display("TIMEOUT after 500us");
        $finish;
    end

endmodule
