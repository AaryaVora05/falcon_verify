`timescale 1ns / 1ps

module falcon_verifier_top #(
    parameter int N = 512,
    parameter logic [31:0] NORM_BOUND = 32'd34034726
)(
    input  logic clk,
    input  logic rst_n,
    input  logic start,

    // SHAKE input: exact salt || message stream
    input logic [31:0] payload_word,
    input logic payload_valid,
    output logic payload_ready,
    input logic [15:0] payload_bits,

    // Compressed Falcon s2 byte stream MSB first

    input  logic [7:0] s2_byte,
    input  logic       s2_byte_valid,
    output logic       s2_byte_ready,

    // Public key h coefficients
    input  logic [13:0] h_data,
    input  logic        h_valid,
    output logic        h_ready,

    // Final result
    output logic        done,
    output logic        valid_signature,
    output logic        error_s2,
    output logic [31:0] norm_sum
);

    // Memories
    logic [13:0] c_mem  [0:N-1];
    logic signed [11:0] s2_mem [0:N-1];
    logic [13:0] h_mem  [0:N-1];

    // SHAKE to hash2point
    logic [15:0] rand_chunk;
    logic        rand_valid;
    logic        rand_ready;
    logic [13:0] c_coeff;
    logic [8:0]  c_addr;
    logic        c_we;
    logic        c_done;

    falcon_shake256_wrapper u_shake (
        .clk           (clk),
        .rst_n         (rst_n),
        .start         (start),
        .payload_word  (payload_word),
        .payload_valid (payload_valid),
        .payload_ready (payload_ready),
        .payload_bits  (payload_bits),
        .rand_chunk    (rand_chunk),
        .rand_valid    (rand_valid),
        .rand_ready    (rand_ready)
    );

    hash2point u_hash2point (
        .clk        (clk),
        .rst        (~rst_n),
        .rand_chunk (rand_chunk),
        .rand_valid (rand_valid),
        .rand_ready (rand_ready),
        .c_coeff    (c_coeff),
        .c_addr     (c_addr),
        .c_we       (c_we),
        .done       (c_done)
    );

    always_ff @(posedge clk) begin
        if (c_we)
            c_mem[c_addr] <= c_coeff;
    end

    // s2 decompression
    logic signed [11:0] s2_coeff;
    logic [8:0]         s2_addr;
    logic               s2_we;
    logic               s2_done;
    logic               s2_error;

    falcon_decompress u_decompress (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (start),
        .rx_data   (s2_byte),
        .rx_valid  (s2_byte_valid),
        .rx_ready  (s2_byte_ready),
        .s2_coeff  (s2_coeff),
        .s2_addr   (s2_addr),
        .s2_we     (s2_we),
        .done      (s2_done),
        .error     (s2_error)
    );

    always_ff @(posedge clk) begin
        if (s2_we)
            s2_mem[s2_addr] <= s2_coeff;
    end

    assign error_s2 = s2_error;

    // Public-key input storage
    logic [8:0] h_load_count;
    logic       h_load_finished;

    assign h_ready = !h_load_finished;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            h_load_count    <= 9'd0;
            h_load_finished <= 1'b0;
        end
        else begin
            if (start) begin
                h_load_count    <= 9'd0;
                h_load_finished <= 1'b0;
            end
            else if (h_valid && h_ready) begin
                h_mem[h_load_count] <= h_data;

                if (h_load_count == N-1) begin
                    h_load_finished <= 1'b1;
                end
                else begin
                    h_load_count <= h_load_count + 1'b1;
                end
            end
        end
    end

    // Top-level sequencing state
    typedef enum logic [3:0] {
        T_IDLE,
        T_WAIT_INPUTS,
        T_POLY_START,
        T_POLY_LOAD_H,
        T_POLY_LOAD_S2,
        T_POLY_RUN,
        T_FINAL,
        T_RESULT
    } top_state_t;

    top_state_t top_state;

    // Polynomial multiplier
    logic poly_start;
    logic poly_busy;
    logic poly_done;

    logic [13:0] poly_h_data;
    logic        poly_h_valid;
    logic        poly_h_ready;

    logic signed [11:0] poly_s2_data;
    logic               poly_s2_valid;
    logic               poly_s2_ready;

    logic [13:0] poly_t_data;
    logic        poly_t_valid;
    logic        poly_t_ready;

    logic [8:0] poly_load_idx;

    assign poly_h_data = h_mem[poly_load_idx];
    assign poly_s2_data = s2_mem[poly_load_idx];

    // Replay the stored arrays into the reference polynomial multiplier.
    assign poly_h_valid   = (top_state == T_POLY_LOAD_H);
    assign poly_s2_valid  = (top_state == T_POLY_LOAD_S2);

    falcon_poly_mul_ref u_poly (
        .clk            (clk),
        .rst_n          (rst_n),
        .start          (poly_start),
        .h_load_data    (poly_h_data),
        .h_load_valid   (poly_h_valid),
        .h_load_ready   (poly_h_ready),
        .s2_load_data   (poly_s2_data),
        .s2_load_valid  (poly_s2_valid),
        .s2_load_ready  (poly_s2_ready),
        .t_data         (poly_t_data),
        .t_valid        (poly_t_valid),
        .t_ready        (poly_t_ready),
        .done           (poly_done),
        .busy           (poly_busy)
    );

    // s1 calculation and norm
    logic        s1_start;
    logic signed [13:0] s1_data;
    logic        s1_valid;
    logic        s1_ready;
    logic        s1_done;

    logic [8:0] final_idx;
    logic [13:0] final_c_data;
    logic signed [11:0] final_s2_data;

    assign final_c_data  = c_mem[final_idx];
    assign final_s2_data = s2_mem[final_idx];

    s1_calc u_s1 (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (s1_start),
        .c_data    (final_c_data),
        .c_valid   (top_state == T_FINAL),
        .c_ready   (),
        .t_data    (poly_t_data),
        .t_valid   (poly_t_valid),
        .t_ready   (poly_t_ready),
        .s1_data   (s1_data),
        .s1_valid  (s1_valid),
        .s1_ready  (s1_ready),
        .done      (s1_done)
    );

    // The s1 calculator is the consumer of the polynomial output.
    // Its t_ready output is also the poly output ready signal.

    logic norm_start;
    logic norm_done;
    logic norm_valid_signature;
    logic norm_s1_ready;
    logic norm_s2_ready;

    norm_acc #(
        .N     (N),
        .BOUND (NORM_BOUND)
    ) u_norm (
        .clk             (clk),
        .rst_n           (rst_n),
        .start           (norm_start),
        .s1_data         (s1_data),
        .s1_valid        (s1_valid),
        .s1_ready        (norm_s1_ready),
        .s2_data         (final_s2_data),
        .s2_valid        (s1_valid),
        .s2_ready        (norm_s2_ready),
        .done            (norm_done),
        .valid_signature (norm_valid_signature),
        .norm_sum        (norm_sum)
    );

    assign s1_ready = norm_s1_ready;

    // Top-level sequencing
    assign done            = norm_done;
    assign valid_signature = norm_valid_signature;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            top_state      <= T_IDLE;
            poly_start     <= 1'b0;
            poly_load_idx  <= 9'd0;
            s1_start       <= 1'b0;
            norm_start     <= 1'b0;
            final_idx      <= 9'd0;
        end
        else begin
            // All starts are one-cycle pulses.
            poly_start <= 1'b0;
            s1_start   <= 1'b0;
            norm_start <= 1'b0;

            case (top_state)

                T_IDLE: begin
                    if (start) begin
                        top_state <= T_WAIT_INPUTS;
                    end
                end

                T_WAIT_INPUTS: begin
                    // hash2point finished c, decompressor finished s2,public key captured
                    if (c_done && s2_done && h_load_finished) begin
                        poly_start    <= 1'b1;
                        poly_load_idx <= 9'd0;
                        top_state     <= T_POLY_LOAD_H;
                    end
                end

                T_POLY_LOAD_H: begin
                    if (poly_h_valid && poly_h_ready) begin
                        if (poly_load_idx == N-1) begin
                            poly_load_idx <= 9'd0;
                            top_state     <= T_POLY_LOAD_S2;
                        end
                        else begin
                            poly_load_idx <= poly_load_idx + 1'b1;
                        end
                    end
                end

                T_POLY_LOAD_S2: begin
                    if (poly_s2_valid && poly_s2_ready) begin
                        if (poly_load_idx == N-1) begin
                            top_state <= T_POLY_RUN;
                        end
                        else begin
                            poly_load_idx <= poly_load_idx + 1'b1;
                        end
                    end
                end

                T_POLY_RUN: begin
                    if (poly_t_valid) begin
                        final_idx <= 9'd0;
                        s1_start  <= 1'b1;
                        norm_start<= 1'b1;
                        top_state <= T_FINAL;
                    end
                end

                T_FINAL: begin
                    // Norm finish early if the accumulated >bound
                    if (norm_done) begin
                        top_state <= T_RESULT;
                    end
                    else if (s1_valid && s1_ready) begin
                        if (final_idx == N-1) begin
                            top_state <= T_RESULT;
                        end
                        else begin
                            final_idx <= final_idx + 1'b1;
                        end
                    end
                end 

                T_RESULT: begin
                    // norm_done is a one-cycle pulse and already been observed before entering this state.
                    top_state <= T_IDLE;
                end

                default: top_state <= T_IDLE;
            endcase
        end
    end

endmodule
