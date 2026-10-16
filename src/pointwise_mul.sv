`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 09/28/2026 12:12:57 PM
// Design Name: 
// Module Name: pointwise_mul
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


module pointwise_mul #(
    parameter int Q = 12289,
    parameter int N = 512
)(
    input logic clk,
    input logic rst_n,

    input logic start,

    // h in NTT domain
    input logic [13:0] h_data,
    input logic h_valid,
    output logic h_ready,

    // NTT(s2) output
    input logic [13:0] s2_ntt_data,
    input logic s2_ntt_valid,
    output logic s2_ntt_ready,

    // Product INTT
    output logic [13:0] product_data,
    output logic product_valid,
    input logic product_ready,

    output logic done
);

    logic [8:0] count;

    logic [27:0] mult_result;
    logic [13:0] reduced_result;

    logic busy;

    assign h_ready = busy && s2_ntt_valid && product_ready;
    assign s2_ntt_ready = busy && h_valid && product_ready;

    assign mult_result = h_data * s2_ntt_data;

    always_comb begin
        reduced_result = mult_result % Q;
    end

    assign product_data  = reduced_result;
    assign product_valid = busy && h_valid && s2_ntt_valid;

    always_ff @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin
            count <= 9'd0;
            busy <= 1'b0;
            done <= 1'b0;
        end

        else begin

            done <= 1'b0;

            if (start) begin
                count <= 9'd0;
                busy <= 1'b1;
            end

            else if (product_valid && product_ready) begin

                if (count == N-1) begin
                    count <= 9'd0;
                    busy <= 1'b0;
                    done <= 1'b1;
                end

                else begin
                    count <= count + 1'b1;
                end

            end
        end
    end

endmodule
