// ============================================================================
// Accelerator Bus Slave — Memory-Mapped Register Interface
//
// Matches the RISC-V CPU's native handshake protocol:
//   req/ready, addr, wdata, wstrb, rdata
//
// Architecture: CPU loads full A[8×8] and B[8×8] matrices into internal
// register files, then triggers start. The controller auto-generates the
// diagonal-skewed streaming pattern for the systolic array over 22 cycles.
// Results are captured into an output buffer for sequential CPU reads.
//
// Register Map (byte addresses relative to base, 32-bit aligned):
//   0x000       CTRL    [W]   bit 0: start, bit 1: soft-reset (auto-clear)
//   0x004       STATUS  [R]   bit 0: busy, bit 1: done (W1C), bit 2: irq_en
//   0x008       CONFIG  [RW]  bits [4:0]: compute_cycles (default 22)
//
//   0x100-0x13C A_MAT   [W]   A matrix, 16 words (row-major, 4 bytes/word)
//                              word k = {A[row][3], A[row][2], A[row][1], A[row][0]}
//                              row = k/2, half = k%2
//   0x200-0x23C B_MAT   [W]   B matrix, 16 words (same packing)
//
//   0x300-0x3FC RESULT  [R]   64 result words, C[row][col] as signed 32-bit
//                              address offset = (row*8 + col) * 4
//                              Auto-populated after done
// ============================================================================

module accel_regs (
    input  wire        clk,
    input  wire        rst_n,

    // CPU data memory interface (matches rv32i_cpu)
    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    input  wire [3:0]  wstrb,
    input  wire        req,
    output reg  [31:0] rdata,
    output reg         ready,

    // Interrupt
    output wire        irq,

    // Array control signals
    output reg         arr_start,
    input  wire        arr_busy,
    input  wire        arr_done,

    // Array weight interface
    output reg  [7:0]  arr_wgt_data [0:7],
    output reg         arr_wgt_valid,

    // Array activation interface
    output reg  [7:0]  arr_act_data [0:7],
    output reg         arr_act_valid,

    // Array result interface
    input  wire [31:0] arr_result_data [0:7],
    input  wire        arr_result_valid,
    input  wire [2:0]  arr_result_col
);

    // ── Input Matrix Buffers ─────────────────────────────────────────
    reg [7:0] a_buf [0:7][0:7];   // A matrix (activations)
    reg [7:0] b_buf [0:7][0:7];   // B matrix (weights)

    // ── Output Result Buffer ─────────────────────────────────────────
    reg [31:0] c_buf [0:7][0:7];  // C = A × B results

    // ── Control/Status ───────────────────────────────────────────────
    reg        done_sticky;
    reg        irq_en;
    reg        arr_done_prev;
    reg [4:0]  config_cycles;      // configurable compute cycles

    assign irq = done_sticky & irq_en;

    // ── Streaming Controller FSM ─────────────────────────────────────
    // After CPU writes start, this FSM feeds the array from buffers
    localparam SC_IDLE    = 3'd0,
               SC_LOAD    = 3'd1,   // feed 8 cycles of weights (for FSM)
               SC_COMPUTE = 3'd2,   // feed 22 cycles of skewed A + B
               SC_WAIT    = 3'd3;   // wait for array drain + done

    reg [2:0]  sc_state;
    reg [4:0]  sc_cnt;

    // ── Done Capture ─────────────────────────────────────────────────
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done_sticky   <= 1'b0;
            arr_done_prev <= 1'b0;
        end else begin
            arr_done_prev <= arr_done;
            if (arr_done & ~arr_done_prev)
                done_sticky <= 1'b1;
            // W1C: clear when CPU writes 1 to STATUS bit 1
            if (req & |wstrb & (addr[11:0] == 12'h004) & wdata[1])
                done_sticky <= 1'b0;
            if (arr_start)
                done_sticky <= 1'b0;
        end
    end

    // ── Result Capture ───────────────────────────────────────────────
    always @(posedge clk) begin
        if (arr_result_valid) begin
            c_buf[0][arr_result_col] <= arr_result_data[0];
            c_buf[1][arr_result_col] <= arr_result_data[1];
            c_buf[2][arr_result_col] <= arr_result_data[2];
            c_buf[3][arr_result_col] <= arr_result_data[3];
            c_buf[4][arr_result_col] <= arr_result_data[4];
            c_buf[5][arr_result_col] <= arr_result_data[5];
            c_buf[6][arr_result_col] <= arr_result_data[6];
            c_buf[7][arr_result_col] <= arr_result_data[7];
        end
    end

    // ── Streaming Controller ─────────────────────────────────────────
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sc_state      <= SC_IDLE;
            sc_cnt        <= 5'd0;
            arr_wgt_valid <= 1'b0;
            arr_act_valid <= 1'b0;
            arr_start     <= 1'b0;
        end else begin
            arr_start     <= 1'b0;
            arr_wgt_valid <= 1'b0;
            arr_act_valid <= 1'b0;

            case (sc_state)
                SC_IDLE: begin
                    if (req & |wstrb & (addr[11:0] == 12'h000) & wdata[0]) begin
                        arr_start <= 1'b1;
                        sc_state  <= SC_LOAD;
                        sc_cnt    <= 5'd0;
                    end
                end

                SC_LOAD: begin
                    // Feed weight rows to array (required by FSM's LOAD state)
                    arr_wgt_valid <= 1'b1;
                    begin : load_wgt_gen
                        integer ci;
                        for (ci = 0; ci < 8; ci = ci + 1)
                            arr_wgt_data[ci] <= b_buf[sc_cnt[2:0]][ci];
                    end

                    sc_cnt <= sc_cnt + 5'd1;
                    if (sc_cnt == 5'd7)  begin
                        sc_state <= SC_COMPUTE;
                        sc_cnt   <= 5'd0;
                    end
                end

                SC_COMPUTE: begin
                    // Generate diagonal-skewed activations and weights
                    arr_act_valid <= 1'b1;
                    arr_wgt_valid <= 1'b1;

                    begin : compute_skew_gen
                        integer ri, rj, idx;
                        // Activations: A[ri][sc_cnt - ri] at row ri
                        for (ri = 0; ri < 8; ri = ri + 1) begin
                            idx = sc_cnt - ri;
                            if (idx >= 0 && idx < 8)
                                arr_act_data[ri] <= a_buf[ri][idx[2:0]];
                            else
                                arr_act_data[ri] <= 8'd0;
                        end
                        // Weights: B[sc_cnt - rj][rj] at column rj
                        for (rj = 0; rj < 8; rj = rj + 1) begin
                            idx = sc_cnt - rj;
                            if (idx >= 0 && idx < 8)
                                arr_wgt_data[rj] <= b_buf[idx[2:0]][rj];
                            else
                                arr_wgt_data[rj] <= 8'd0;
                        end
                    end

                    sc_cnt <= sc_cnt + 5'd1;
                    if (sc_cnt == config_cycles - 1) begin
                        sc_state <= SC_WAIT;
                        sc_cnt   <= 5'd0;
                    end
                end

                SC_WAIT: begin
                    // Wait for array to finish drain + done
                    if (arr_done)
                        sc_state <= SC_IDLE;
                end

                default: sc_state <= SC_IDLE;
            endcase
        end
    end

    // ── Bus Read/Write Logic ─────────────────────────────────────────
    wire [11:0] byte_addr = addr[11:0];

    // Single-cycle ready
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            ready <= 1'b0;
        else
            ready <= req & ~ready;
    end

    // Write logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            irq_en        <= 1'b0;
            config_cycles <= 5'd22;
        end else if (req & |wstrb & ~ready) begin
            // CONFIG register
            if (byte_addr == 12'h008) begin
                config_cycles <= wdata[4:0];
                irq_en        <= wdata[8];
            end

            // A matrix: 0x100-0x13C (16 words)
            if (byte_addr >= 12'h100 && byte_addr <= 12'h13C) begin
                // word index within A region
                begin : a_write
                    reg [3:0] widx;
                    reg [2:0] row;
                    reg       half;
                    widx = byte_addr[5:2];
                    row  = widx[3:1];
                    half = widx[0];
                    if (!half) begin
                        if (wstrb[0]) a_buf[row][0] <= wdata[7:0];
                        if (wstrb[1]) a_buf[row][1] <= wdata[15:8];
                        if (wstrb[2]) a_buf[row][2] <= wdata[23:16];
                        if (wstrb[3]) a_buf[row][3] <= wdata[31:24];
                    end else begin
                        if (wstrb[0]) a_buf[row][4] <= wdata[7:0];
                        if (wstrb[1]) a_buf[row][5] <= wdata[15:8];
                        if (wstrb[2]) a_buf[row][6] <= wdata[23:16];
                        if (wstrb[3]) a_buf[row][7] <= wdata[31:24];
                    end
                end
            end

            // B matrix: 0x200-0x23C (16 words)
            if (byte_addr >= 12'h200 && byte_addr <= 12'h23C) begin
                begin : b_write
                    reg [3:0] widx;
                    reg [2:0] row;
                    reg       half;
                    widx = byte_addr[5:2];
                    row  = widx[3:1];
                    half = widx[0];
                    if (!half) begin
                        if (wstrb[0]) b_buf[row][0] <= wdata[7:0];
                        if (wstrb[1]) b_buf[row][1] <= wdata[15:8];
                        if (wstrb[2]) b_buf[row][2] <= wdata[23:16];
                        if (wstrb[3]) b_buf[row][3] <= wdata[31:24];
                    end else begin
                        if (wstrb[0]) b_buf[row][4] <= wdata[7:0];
                        if (wstrb[1]) b_buf[row][5] <= wdata[15:8];
                        if (wstrb[2]) b_buf[row][6] <= wdata[23:16];
                        if (wstrb[3]) b_buf[row][7] <= wdata[31:24];
                    end
                end
            end
        end
    end

    // Read logic (combinational)
    always @(*) begin
        rdata = 32'd0;

        if (byte_addr == 12'h004) begin
            // STATUS
            rdata = {28'd0, done_sticky, arr_result_valid, done_sticky, arr_busy};
        end
        else if (byte_addr == 12'h008) begin
            // CONFIG
            rdata = {23'd0, irq_en, 3'd0, config_cycles};
        end
        else if (byte_addr >= 12'h300 && byte_addr <= 12'h3FC) begin
            // RESULT buffer: address = 0x300 + (row*8 + col)*4
            begin : result_read
                reg [5:0] ridx;
                reg [2:0] rrow, rcol;
                ridx = byte_addr[7:2];
                rrow = ridx[5:3];
                rcol = ridx[2:0];
                rdata = c_buf[rrow][rcol];
            end
        end
    end

endmodule
