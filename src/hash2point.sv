`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: AV
// 
// Create Date: 08/30/2026 05:04:48 PM
// Design Name: 
// Module Name: hash2point
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

module hash2point #(
    parameter integer N = 512,
    parameter integer Q = 12289
) (
    input logic clk,
    input logic rst,

    input logic [15:0] rand_chunk,
    input logic rand_valid,
    output logic rand_ready,

    output logic [13:0] c_coeff,
    output logic [8:0] c_addr,
    output logic c_we,
    output logic done
);

    localparam logic [15:0] FIVE_Q = 16'd61445;

    logic [9:0] count;
    logic [13:0] reduced;

    assign rand_ready = (count < N);
    assign done = (count == N);

    always_comb begin
        if (rand_chunk >= 16'd49156)
            reduced = rand_chunk - 16'd49156;
        else if (rand_chunk >= 16'd36867)
            reduced = rand_chunk - 16'd36867;
        else if (rand_chunk >= 16'd24578)
            reduced = rand_chunk - 16'd24578;
        else if (rand_chunk >= 16'd12289)
            reduced = rand_chunk - 16'd12289;
        else
            reduced = rand_chunk[13:0];
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            count <= 10'd0;
            c_coeff <= 14'd0;
            c_addr <= 9'd0;
            c_we <= 1'b0;
        end else begin
            c_we <= 1'b0;

            if (rand_valid && rand_ready) begin
                if (rand_chunk < FIVE_Q) begin
                    c_addr <= count[8:0];
                    c_coeff <= reduced;
                    c_we <= 1'b1;
                    count <= count + 10'd1;
                end
            end
        end
    end

endmodule