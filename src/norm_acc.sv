`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: AV
// 
// Create Date: 09/28/2026 12:15:42 PM
// Design Name: 
// Module Name: norm_acc
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


module norm_acc #(
    parameter int N = 512,
    parameter logic [31:0] BOUND = 32'd34034726
)(
    input logic clk,
    input logic rst_n,

    input logic start,

    // s1 stream
    input logic signed [13:0] s1_data,
    input logic s1_valid,
    output logic s1_ready,

    // s2 from BRAM
    input logic signed [11:0] s2_data,
    input logic s2_valid,
    output logic s2_ready,

    output logic done,
    output logic valid_signature,

    output logic [31:0] norm_sum
);

    logic [8:0] count;

    logic busy;

    logic signed [28:0] s1_square;
    logic signed [23:0] s2_square;

    logic [31:0] next_sum;

    assign s1_ready = busy && s2_valid;
    assign s2_ready = busy && s1_valid;

    always_comb begin

        s1_square = s1_data * s1_data;
        s2_square = s2_data * s2_data;

        next_sum = norm_sum + {{6{s1_square[25]}}, s1_square} + {{8{s2_square[23]}}, s2_square};

    end

    always_ff @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            count <= 9'd0;
            norm_sum <= 32'd0;
            busy <= 1'b0;

            done <= 1'b0;
            valid_signature <= 1'b0;

        end

        else begin

            done <= 1'b0;

            if (start) begin

                count <= 9'd0;
                norm_sum <= 32'd0;
                busy <= 1'b1;
                valid_signature <= 1'b0;

            end

            else if (s1_valid && s2_valid) begin

                norm_sum <= next_sum;

                // Early rejection
                if (next_sum >= BOUND) begin

                    valid_signature <= 1'b0;
                    busy <= 1'b0;
                    done <= 1'b1;

                end

                else if (count == N-1) begin
                    valid_signature <= 1'b1;
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