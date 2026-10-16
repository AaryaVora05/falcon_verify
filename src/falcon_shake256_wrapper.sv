`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: AV
// 
// Create Date: 09/28/2026 11:57:36 AM
// Design Name: 
// Module Name: falcon_shake256_wrapper
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

module falcon_shake256_wrapper #(
    parameter int unsigned SHAKE_OUT_BYTES = 2048
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,

    // ============================================================
    // INPUT: salt || message
    //
    // 32-bit words, supplied MSB/LSB ordering according to the
    // existing cshake-core protocol.
    //
    // payload_bits specifies the exact number of valid bits.
    // ============================================================

    input  logic [31:0] payload_word,
    input  logic        payload_valid,
    output logic        payload_ready,
    input  logic [15:0] payload_bits,

    // ============================================================
    // OUTPUT: interface to hash2point
    // ============================================================

    output logic [15:0] rand_chunk,
    output logic        rand_valid,
    input  logic        rand_ready
);

    // ============================================================
    // SHAKE output request
    //
    // cshake-core calls this requested_bytes, but the RTL actually
    // consumes PARALLEL_SLICES bits per squeeze tick.
    //
    // 2048 bytes = 16384 bits.
    // ============================================================

    localparam logic [29:0] SHAKE_OUT_BITS =
        SHAKE_OUT_BYTES * 8;

    // ============================================================
    // cshake-core interface
    // ============================================================

    logic        k_din_valid;
    logic        k_din_ready;
    logic [31:0] k_din;

    logic        k_dout_valid;
    logic        k_dout_ready;
    logic [31:0] k_dout;

    // ============================================================
    // FSM
    // ============================================================

    typedef enum logic [2:0] {
        S_IDLE,
        S_SEND_HEADER,
        S_SEND_LENGTH,
        S_SEND_PAYLOAD,
        S_SQUEEZE
    } state_t;

    state_t state;

    // ============================================================
    // Payload bookkeeping
    // ============================================================

    logic [11:0] num_words;
    logic [11:0] word_count;

    // ============================================================
    // Output holding register
    //
    // One 32-bit Keccak output becomes two 16-bit values.
    // ============================================================

    logic [31:0] hold_reg;
    logic        upper_half;


    // ============================================================
    // Instantiate the EXISTING cshake-core
    // ============================================================

    keccak_top u_keccak (
        .clk        (clk),
        .rst        (~rst_n),

        .din_valid  (k_din_valid),
        .din_ready  (k_din_ready),
        .din        (k_din),

        .dout_valid (k_dout_valid),
        .dout_ready (k_dout_ready),
        .dout       (k_dout)
    );


    // ============================================================
    // INPUT SIDE
    // ============================================================

    always_comb begin

        k_din_valid = 1'b0;
        k_din       = 32'd0;

        payload_ready = 1'b0;

        case (state)

            // ----------------------------------------------------
            // Command header
            //
            // bit 31 = 0 : SHAKE
            // bit 30 = 1 : SHAKE256
            // bits 29:0 = requested output bits
            // ----------------------------------------------------

            S_SEND_HEADER: begin

                k_din_valid = 1'b1;

                k_din = {
                    1'b0,
                    1'b1,
                    SHAKE_OUT_BITS
                };

            end


            // ----------------------------------------------------
            // Input length
            //
            // Existing cshake-core command format:
            //
            // {EOF, reserved, payload_bits}
            // ----------------------------------------------------

            S_SEND_LENGTH: begin

                k_din_valid = 1'b1;

                k_din = {
                    1'b1,
                    15'd0,
                    payload_bits
                };

            end


            // ----------------------------------------------------
            // Actual salt || message words
            // ----------------------------------------------------

            S_SEND_PAYLOAD: begin

                k_din_valid = payload_valid;
                k_din       = payload_word;

                payload_ready = k_din_ready;

            end

            default: begin

                k_din_valid = 1'b0;
                k_din       = 32'd0;
                payload_ready = 1'b0;

            end

        endcase

    end


    // ============================================================
    // OUTPUT SIDE
    //
    // Only accept a new 32-bit word when the previous one has
    // completely been consumed by hash2point.
    // ============================================================

    always_comb begin

        k_dout_ready = 1'b0;

        if (state == S_SQUEEZE) begin

            // No pending 16-bit output.
            if (!rand_valid) begin

                k_dout_ready = 1'b1;

            end

            // Upper 16-bit half has just been consumed.
            else if (upper_half && rand_ready) begin

                k_dout_ready = 1'b1;

            end

        end

    end


    // ============================================================
    // FSM
    // ============================================================

    always_ff @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            state      <= S_IDLE;

            num_words  <= 12'd0;
            word_count <= 12'd0;

            hold_reg   <= 32'd0;
            upper_half <= 1'b0;

            rand_valid <= 1'b0;

        end

        else begin

            case (state)

                // =================================================
                // IDLE
                // =================================================

                S_IDLE: begin

                    word_count <= 12'd0;

                    rand_valid <= 1'b0;
                    upper_half <= 1'b0;

                    if (start) begin

                        // ceil(payload_bits / 32)
                        num_words <=
                            (payload_bits + 16'd31) >> 5;

                        state <= S_SEND_HEADER;

                    end

                end


                // =================================================
                // SEND HEADER
                // =================================================

                S_SEND_HEADER: begin

                    if (k_din_ready) begin

                        state <= S_SEND_LENGTH;

                    end

                end


                // =================================================
                // SEND LENGTH
                // =================================================

                S_SEND_LENGTH: begin

                    if (k_din_ready) begin

                        word_count <= 12'd0;

                        if (num_words == 0)
                            state <= S_SQUEEZE;
                        else
                            state <= S_SEND_PAYLOAD;

                    end

                end


                // =================================================
                // SEND PAYLOAD
                // =================================================

                S_SEND_PAYLOAD: begin

                    if (payload_valid && k_din_ready) begin

                        if (word_count == num_words - 1) begin

                            state <= S_SQUEEZE;

                        end

                        else begin

                            word_count <= word_count + 1'b1;

                        end

                    end

                end


                // =================================================
                // SQUEEZE
                // =================================================

                S_SQUEEZE: begin

                    // ------------------------------------------------
                    // New 32-bit SHAKE output
                    // ------------------------------------------------

                    if (k_dout_valid && k_dout_ready) begin

                        hold_reg <= k_dout;

                        rand_valid <= 1'b1;

                        // First 16-bit value
                        upper_half <= 1'b0;

                    end

                    // ------------------------------------------------
                    // Current 16-bit value consumed
                    // ------------------------------------------------

                    else if (rand_valid && rand_ready) begin

                        if (!upper_half) begin

                            // Lower half consumed.
                            // Present upper half next.
                            upper_half <= 1'b1;

                        end

                        else begin

                            // Entire 32-bit word consumed.
                            rand_valid <= 1'b0;
                            upper_half <= 1'b0;

                        end

                    end

                end


                default: begin

                    state <= S_IDLE;

                end

            endcase

        end

    end


    // ============================================================
    // 32-bit → 16-bit serializer
    //
    // cshake-core output:
    //
    //   dout[7:0]   = SHAKE byte 0
    //   dout[15:8]  = SHAKE byte 1
    //   dout[23:16] = SHAKE byte 2
    //   dout[31:24] = SHAKE byte 3
    //
    // Therefore:
    //
    //   first candidate  = dout[15:0]
    //   second candidate = dout[31:16]
    // ============================================================

    always_comb begin

        if (upper_half)
            rand_chunk = hold_reg[31:16];
        else
            rand_chunk = hold_reg[15:0];

    end

endmodule