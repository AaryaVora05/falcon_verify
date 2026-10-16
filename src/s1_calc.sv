`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: AV
// 
// Create Date: 09/28/2026 12:13:56 PM
// Design Name: 
// Module Name: s1_calc
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


module s1_calc #(
    parameter int Q = 12289,
    parameter int N = 512
)(
    input  logic        clk,
    input  logic        rst_n,

    input  logic        start,

    // Challenge c[i]
    input logic [13:0] c_data,
    input logic c_valid,
    output logic c_ready,

    // t[i] = h*s2 after INTT
    input logic [13:0] t_data,
    input logic t_valid,
    output logic t_ready,

    // s1[i]
    output logic signed [13:0] s1_data,
    output logic s1_valid,
    input logic s1_ready,

    output logic done
);

    logic [8:0] count;
    logic busy;

    logic signed [14:0] diff;
    logic signed [13:0] centered;

    assign c_ready = busy && t_valid && s1_ready;
    assign t_ready = busy && c_valid && s1_ready;

    always_comb begin
        // Compute c - t using signed 15-bit arithmetic.
        diff = $signed({1'b0, c_data}) - $signed({1'b0, t_data});
    
        // Reduce into [0, Q-1].
        if (diff < 0)
            diff = diff + Q;
    
        // Center into [-6144, 6144].
        if (diff > Q/2)
            centered = $signed(diff) - Q;
        else
            centered = $signed(diff);
    end

    assign s1_data  = centered;
    assign s1_valid = busy && c_valid && t_valid;

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

            else if (s1_valid && s1_ready) begin

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
