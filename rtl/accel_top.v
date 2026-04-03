// ============================================================================
// Accelerator Top Module
//
// Wraps the 8×8 systolic array with the bus register interface.
// Single clock domain — matches RISC-V host protocol directly.
//
// CPU interface uses the rv32i_cpu native handshake:
//   req/ready, addr, wdata, wstrb, rdata
//
// For SoC integration: connect to dmem bus through address decoder.
// Recommended base address: 0x4000_0000 (peripheral region)
// ============================================================================

module accel_top (
    input  wire        clk,
    input  wire        rst_n,

    // CPU data interface (rv32i_cpu compatible)
    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    input  wire [3:0]  wstrb,
    input  wire        req,
    output wire [31:0] rdata,
    output wire        ready,

    // Interrupt output
    output wire        irq
);

    // ── Internal Signals ──────────────────────────────────────────────
    wire        arr_start;
    wire        arr_busy;
    wire        arr_done;

    wire [63:0] arr_wgt_data;
    wire        arr_wgt_valid;

    wire [63:0] arr_act_data;
    wire        arr_act_valid;

    wire [255:0] arr_result_data;
    wire         arr_result_valid;
    wire [2:0]   arr_result_col;

    // ── Reset for array (includes soft-reset) ─────────────────────────
    wire arr_soft_reset;
    wire arr_rst_n = rst_n & ~arr_soft_reset;

    // ── Bus Register Interface ────────────────────────────────────────
    accel_regs u_regs (
        .clk            (clk),
        .rst_n          (rst_n),
        .addr           (addr),
        .wdata          (wdata),
        .wstrb          (wstrb),
        .req            (req),
        .rdata          (rdata),
        .ready          (ready),
        .irq            (irq),
        .arr_start      (arr_start),
        .arr_busy       (arr_busy),
        .arr_done       (arr_done),
        .arr_wgt_data   (arr_wgt_data),
        .arr_wgt_valid  (arr_wgt_valid),
        .arr_act_data   (arr_act_data),
        .arr_act_valid  (arr_act_valid),
        .arr_result_data  (arr_result_data),
        .arr_result_valid (arr_result_valid),
        .arr_result_col   (arr_result_col)
    );

    // Soft-reset is driven from CTRL register write — extract from regs
    // (the arr_start pulse is already generated; soft_reset handled internally)
    assign arr_soft_reset = 1'b0;  // soft-reset handled inside accel_regs

    // ── Systolic Array ───────────────────────────────────────────────
    systolic_array_8x8 u_array (
        .clk          (clk),
        .rst_n        (arr_rst_n),
        .start        (arr_start),
        .busy         (arr_busy),
        .done         (arr_done),
        .wgt_data     (arr_wgt_data),
        .wgt_valid    (arr_wgt_valid),
        .act_data     (arr_act_data),
        .act_valid    (arr_act_valid),
        .result_data  (arr_result_data),
        .result_valid (arr_result_valid),
        .result_col   (arr_result_col)
    );

endmodule
