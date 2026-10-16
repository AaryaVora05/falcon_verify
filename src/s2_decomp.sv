`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: AV
// 
// Create Date: 09/21/2026 11:03:28 AM
// Design Name:
// Module Name: s2_decomp
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

module falcon_decompress (
    input logic clk,
    input logic rst_n,
    input logic start,
    // Input byte stream
    input logic [7:0] rx_data,
    input logic rx_valid,
    output logic rx_ready,
    // BRAM write interface
    output logic signed [11:0] s2_coeff,
    output logic [8:0]  s2_addr,
    output logic s2_we,
    output logic done,
    output logic error
);

    // State machine
    typedef enum logic [2:0] {
        IDLE,
        GET_SIGN,
        GET_LOW7,
        GET_UNARY,
        WRITE_BRAM,
        CHECK_TRAILING,
        DONE,
        ERROR_STATE
    } state_t;

    state_t state;

    // Bits read MSB first
    logic [31:0] bit_buffer;
    logic [31:0] next_bit_buffer;

    logic [5:0] bit_count;
    logic [5:0] next_bit_count;

    logic consume_bit;

    // Decoder registers
    logic is_negative;
    logic [11:0] magnitude;
    logic [2:0] low7_count;
    logic [9:0] coeff_count;

    // Accept bytes while the decoder is reading bits. Keep at least 8 free bits in the buffer.
    assign rx_ready = (state == GET_SIGN || state == GET_LOW7 || state == GET_UNARY) && (bit_count <= 6'd24);

    // bit cosume check
    always_comb begin
        consume_bit = 1'b0;
        if ((state == GET_SIGN || state == GET_LOW7 || state == GET_UNARY) && bit_count > 6'd0) begin
            consume_bit = 1'b1;
        end
    end

    // Update the bit buffer. A cycle can consume one bit and receive one byte.
    always_comb begin
        next_bit_buffer = bit_buffer;
        next_bit_count = bit_count;

        //next bit
        if (consume_bit) begin
            next_bit_buffer = next_bit_buffer << 1;
            next_bit_count = next_bit_count - 6'd1;
        end

        // Append a received byte.
        // Use the updated count if a bit was consumed this cycle.
        if (rx_valid && rx_ready) begin
            next_bit_buffer = next_bit_buffer | ({{24{1'b0}}, rx_data} << (5'd24 - next_bit_count[4:0]));
            next_bit_count = next_bit_count + 6'd8;
        end
    end

    // Store bit buffer and count
    always_ff @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            bit_buffer <= 32'd0;
            bit_count <= 6'd0;

        end
        else if (start && (state == IDLE || state == DONE || state == ERROR_STATE)) begin

            // Clear any leftover bits before starting a new stream
            bit_buffer <= 32'd0;
            bit_count <= 6'd0;

        end
        else begin

            bit_buffer <= next_bit_buffer;
            bit_count <= next_bit_count;

        end
    end

    // Status
    assign done = (state == DONE);
    assign error = (state == ERROR_STATE);

    // Decode
    always_ff @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            state <= IDLE;

            coeff_count <= 10'd0;

            is_negative <= 1'b0;
            magnitude <= 12'd0;
            low7_count <= 3'd0;

            s2_coeff <= 12'sd0;
            s2_addr <= 9'd0;
            s2_we <= 1'b0;

        end
        else begin

            // BRAM write enable is high for one cycle.
            s2_we <= 1'b0;

            case (state)

                IDLE: begin

                    if (start) begin

                        coeff_count <= 10'd0;
                        is_negative <= 1'b0;
                        magnitude <= 12'd0;
                        low7_count <= 3'd0;

                        state <= GET_SIGN;

                    end
                end

                // Read the sign bit

                GET_SIGN: begin

                    if (bit_count > 6'd0) begin

                        is_negative <= bit_buffer[31];

                        magnitude <= 12'd0;
                        low7_count <= 3'd0;

                        state <= GET_LOW7;

                    end
                end

                // Read the seven low bits 
                GET_LOW7: begin
                    if (bit_count > 6'd0) begin

                        magnitude <= {magnitude[10:0], bit_buffer[31]};

                        if (low7_count == 3'd6) begin
                            state <= GET_UNARY;
                        end
                        else begin
                            low7_count <= low7_count + 3'd1;
                        end
                    end
                end

                // Read the unary part of the magnitude.
                // Each zero adds 128 to the magnitude; a one ends the unary part.
                GET_UNARY: begin

                    if (bit_count > 6'd0) begin

                        if (bit_buffer[31] == 1'b0) begin

                            // Reject values that would exceed 2047.

                            if (magnitude > 12'd1919) begin
                                state <= ERROR_STATE;
                            end
                            else begin

                                magnitude <= magnitude + 12'd128;

                            end
                        end
                        else begin
                            // The terminating one ends this coefficient.
                            state <= WRITE_BRAM;
                        end
                    end
                end

                // Write the decoded signed coefficient to BRAM.

                WRITE_BRAM: begin

                    // A negative zero is not a valid coefficient.
                    if (is_negative && magnitude == 12'd0) begin

                        state <= ERROR_STATE;

                    end
                    else begin

                        // Update the address and data together for synchronous BRAM.

                        s2_addr <= coeff_count[8:0];

                        if (is_negative) begin
                            s2_coeff <= -$signed(magnitude);
                        end
                        else begin
                            s2_coeff <= $signed(magnitude);
                        end

                        s2_we <= 1'b1;

                        // next coefficient.
                        coeff_count <= coeff_count + 10'd1;

                        // 512 coeffs
                        if (coeff_count == 10'd511) begin

                            state <= CHECK_TRAILING;

                        end
                        else begin
                            state <= GET_SIGN;
                        end
                    end
                end

                // Check the remaining bits after the last coefficient.

                // Any unused bits in final byte =0
                CHECK_TRAILING: begin
                    if (bit_buffer == 32'd0) begin
                        state <= DONE;
                    end
                    else begin
                        state <= ERROR_STATE;
                    end
                end

                // Finished decoding.
                DONE: begin

                    if (start) begin
                        coeff_count <= 10'd0;

                        is_negative <= 1'b0;
                        magnitude <= 12'd0;
                        low7_count <= 3'd0;

                        state <= GET_SIGN;
                    end
                end

                // Stay here until a new start signal arrives.

                ERROR_STATE: begin

                    if (start) begin
                        coeff_count <= 10'd0;

                        is_negative <= 1'b0;
                        magnitude <= 12'd0;
                        low7_count <= 3'd0;

                        state <= GET_SIGN;
                    end
                end

                default: begin
                    state <= IDLE;
                end

            endcase
        end
    end

endmodule
