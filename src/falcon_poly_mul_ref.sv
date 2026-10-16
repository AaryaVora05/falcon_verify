`timescale 1ns / 1ps
// llm written, need to change to NTT/INTT
// ============================================================================
// Falcon polynomial multiplication reference
//
// Computes, for N=512 and q=12289:
//
//     t = h * s2  in Z_q[x] / (x^N + 1)
//
// using the actual sequence:
//
//     NTT(h) -> NTT(s2) -> pointwise multiply -> INTT
//
// This is intentionally UNOPTIMIZED.  The NTT/INTT are direct O(N^2)
// negacyclic transforms.  It is meant as a functional reference, not as the
// final ASIC architecture.
//
// Direct negacyclic transform used here:
//
//   A[j] = sum_k a[k] * psi^((2*j+1)*k)
//
//   a[k] = N^-1 * sum_j A[j] * psi^-((2*k+1)*j)
//
// with psi = 49, psi^-1 = 1254, N^-1 = 12265 modulo 12289.
// ============================================================================

module falcon_poly_mul_ref #(
    parameter int N = 512,
    parameter int Q = 12289
)(
    input  logic clk,
    input  logic rst_n,
    input  logic start,

    // Load public key h, one coefficient at a time.
    input  logic [13:0] h_load_data,
    input  logic        h_load_valid,
    output logic        h_load_ready,

    // Load decompressed s2, one signed coefficient at a time.
    input  logic signed [11:0] s2_load_data,
    input  logic               s2_load_valid,
    output logic               s2_load_ready,

    // Result t = h*s2, one coefficient at a time.
    output logic [13:0] t_data,
    output logic        t_valid,
    input  logic        t_ready,

    output logic        done,
    output logic        busy
);

    localparam int PSI     = 49;
    localparam int PSI_INV = 1254;
    localparam int N_INV   = 12265;

    localparam int CW = $clog2(N);

    typedef enum logic [3:0] {
        S_IDLE,
        S_LOAD_H,
        S_LOAD_S2,
        S_NTT_H,
        S_NTT_S2,
        S_POINTWISE,
        S_INTT,
        S_OUTPUT,
        S_DONE
    } state_t;

    state_t state;

    logic [13:0] h_mem      [0:N-1];
    logic [13:0] s2_mem     [0:N-1];
    logic [13:0] h_ntt      [0:N-1];
    logic [13:0] s2_ntt     [0:N-1];
    logic [13:0] prod_ntt   [0:N-1];
    logic [13:0] t_mem      [0:N-1];

    logic [CW:0] load_idx;
    logic [CW-1:0] out_idx;
    logic [CW-1:0] inner_idx;

    logic [13:0] acc;
    logic [13:0] twiddle;
    logic [13:0] twiddle_step;

    // ------------------------------------------------------------------------
    // Modular helpers.
    // `% Q` is deliberately used here.  It is expensive hardware, which is
    // exactly why this module is a reference implementation only.
    // ------------------------------------------------------------------------
    function automatic [13:0] mod_q(input integer x);
        integer r;
        begin
            r = x % Q;
            if (r < 0)
                r = r + Q;
            mod_q = r[13:0];
        end
    endfunction

    function automatic [13:0] mul_mod_q(
        input [13:0] a,
        input [13:0] b
    );
        integer p;
        begin
            p = a * b;
            mul_mod_q = p % Q;
        end
    endfunction

    
    function automatic [13:0] pow_mod_q(
        input integer base,
        input integer exponent
    );
        integer b;
        integer e;
        integer r;
        integer i;
        begin
            b = base % Q;
            if (b < 0)
                b = b + Q;

            e = exponent;
            r = 1;

            // Bounded loop: avoids synthesis convergence errors.
            // Supports nonnegative 32-bit exponents.
            for (i = 0; i < 32; i = i + 1) begin
                if (e > 0) begin
                    if ((e & 1) != 0)
                        r = (r * b) % Q;

                    b = (b * b) % Q;
                    e = e >> 1;
                end
            end

            pow_mod_q = r[13:0];
        end
    endfunction


    function automatic [13:0] add_mod_q(
        input [13:0] a,
        input [13:0] b
    );
        integer s;
        begin
            s = a + b;
            if (s >= Q)
                s = s - Q;
            add_mod_q = s[13:0];
        end
    endfunction

    // Normalize signed Falcon s2 coefficient into [0,Q-1].
    function automatic [13:0] normalize_s2(input logic signed [11:0] x);
        integer v;
        begin
            v = x;
            if (v < 0)
                v = v + Q;
            normalize_s2 = v[13:0];
        end
    endfunction

    assign h_load_ready  = (state == S_LOAD_H);
    assign s2_load_ready = (state == S_LOAD_S2);
    assign busy          = (state != S_IDLE) && (state != S_DONE);

    assign t_valid = (state == S_OUTPUT);
    assign t_data  = t_mem[out_idx];

    // ------------------------------------------------------------------------
    // Main FSM
    // ------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            load_idx    <= '0;
            out_idx     <= '0;
            inner_idx   <= '0;
            acc         <= 14'd0;
            twiddle     <= 14'd0;
            twiddle_step<= 14'd0;
            done        <= 1'b0;
        end
        else begin
            done <= 1'b0;

            case (state)

                // ============================================================
                // IDLE
                // ============================================================
                S_IDLE: begin
                    if (start) begin
                        load_idx <= '0;
                        state    <= S_LOAD_H;
                    end
                end

                // ============================================================
                // LOAD H
                // ============================================================
                S_LOAD_H: begin
                    if (h_load_valid && h_load_ready) begin
                        h_mem[load_idx] <= mod_q(h_load_data);

                        if (load_idx == N-1) begin
                            load_idx <= '0;
                            state    <= S_LOAD_S2;
                        end
                        else begin
                            load_idx <= load_idx + 1'b1;
                        end
                    end
                end

                // ============================================================
                // LOAD S2
                // ============================================================
                S_LOAD_S2: begin
                    if (s2_load_valid && s2_load_ready) begin
                        s2_mem[load_idx] <= normalize_s2(s2_load_data);

                        if (load_idx == N-1) begin
                            load_idx     <= '0;
                            out_idx      <= '0;
                            inner_idx    <= '0;
                            acc          <= 14'd0;
                            twiddle      <= 14'd1;
                            twiddle_step <= pow_mod_q(PSI, 1);
                            state        <= S_NTT_H;
                        end
                        else begin
                            load_idx <= load_idx + 1'b1;
                        end
                    end
                end

                // ============================================================
                // DIRECT NEGACYCLIC NTT OF H
                //
                // output j = sum_k h[k] * psi^((2j+1)k)
                // ============================================================
                S_NTT_H: begin
                    if (inner_idx == N-1) begin
                        h_ntt[out_idx] <=
                            add_mod_q(acc,
                                      mul_mod_q(h_mem[inner_idx], twiddle));

                        inner_idx <= '0;
                        acc       <= 14'd0;
                        twiddle   <= 14'd1;

                        if (out_idx == N-1) begin
                            out_idx      <= '0;
                            inner_idx    <= '0;
                            acc          <= 14'd0;
                            twiddle      <= 14'd1;
                            twiddle_step <= pow_mod_q(PSI, 1);
                            state        <= S_NTT_S2;
                        end
                        else begin
                            out_idx      <= out_idx + 1'b1;
                            twiddle_step <=
                                pow_mod_q(PSI, 2*(out_idx + 1) + 1);
                        end
                    end
                    else begin
                        acc       <= add_mod_q(
                            acc,
                            mul_mod_q(h_mem[inner_idx], twiddle)
                        );
                        inner_idx <= inner_idx + 1'b1;
                        twiddle   <= mul_mod_q(twiddle, twiddle_step);
                    end
                end

                // ============================================================
                // DIRECT NEGACYCLIC NTT OF S2
                // ============================================================
                S_NTT_S2: begin
                    if (inner_idx == N-1) begin
                        s2_ntt[out_idx] <=
                            add_mod_q(acc,
                                      mul_mod_q(s2_mem[inner_idx], twiddle));

                        inner_idx <= '0;
                        acc       <= 14'd0;
                        twiddle   <= 14'd1;

                        if (out_idx == N-1) begin
                            out_idx <= '0;
                            state   <= S_POINTWISE;
                        end
                        else begin
                            out_idx      <= out_idx + 1'b1;
                            twiddle_step <=
                                pow_mod_q(PSI, 2*(out_idx + 1) + 1);
                        end
                    end
                    else begin
                        acc       <= add_mod_q(
                            acc,
                            mul_mod_q(s2_mem[inner_idx], twiddle)
                        );
                        inner_idx <= inner_idx + 1'b1;
                        twiddle   <= mul_mod_q(twiddle, twiddle_step);
                    end
                end

                // ============================================================
                // POINTWISE MULTIPLICATION
                // ============================================================
                S_POINTWISE: begin
                    prod_ntt[out_idx] <=
                        mul_mod_q(h_ntt[out_idx], s2_ntt[out_idx]);

                    if (out_idx == N-1) begin
                        out_idx      <= '0;
                        inner_idx    <= '0;
                        acc          <= 14'd0;
                        twiddle      <= pow_mod_q(PSI_INV, 0);
                        twiddle_step <= pow_mod_q(PSI_INV, 0);
                        state        <= S_INTT;
                    end
                    else begin
                        out_idx <= out_idx + 1'b1;
                    end
                end

                // ============================================================
                // DIRECT INVERSE NEGACYCLIC NTT
                //
                // t[k] = N^-1 * sum_j prod[j] * psi^-((2k+1)j)
                // ============================================================
                S_INTT: begin
                    if (inner_idx == N-1) begin
                        t_mem[out_idx] <=
                            mul_mod_q(
                                add_mod_q(
                                    acc,
                                    mul_mod_q(prod_ntt[inner_idx], twiddle)
                                ),
                                N_INV[13:0]
                            );

                        inner_idx <= '0;
                        acc       <= 14'd0;
                        twiddle   <= 14'd1;

                        if (out_idx == N-1) begin
                            out_idx <= '0;
                            state   <= S_OUTPUT;
                        end
                        else begin
                            out_idx      <= out_idx + 1'b1;
                            twiddle      <= pow_mod_q(PSI_INV, out_idx + 1);
                            twiddle_step <=
                                pow_mod_q(PSI_INV, 2*(out_idx + 1));
                        end
                    end
                    else begin
                        acc       <= add_mod_q(
                            acc,
                            mul_mod_q(prod_ntt[inner_idx], twiddle)
                        );
                        inner_idx <= inner_idx + 1'b1;
                        twiddle   <= mul_mod_q(twiddle, twiddle_step);
                    end
                end

                // ============================================================
                // OUTPUT
                // ============================================================
                S_OUTPUT: begin
                    if (t_ready) begin
                        if (out_idx == N-1) begin
                            state <= S_DONE;
                        end
                        else begin
                            out_idx <= out_idx + 1'b1;
                        end
                    end
                end

                // ============================================================
                // DONE pulse
                // ============================================================
                S_DONE: begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
