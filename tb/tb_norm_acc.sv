`timescale 1ns/1ps
module tb_norm_acc;
  logic clk=0,rst_n=0,start=0; always #5 clk=~clk;
  logic signed [12:0] s1_data=0; logic s1_valid=0; wire s1_ready;
  logic signed [11:0] s2_data=0; logic s2_valid=0; wire s2_ready;
  wire done,valid_signature; wire [31:0] norm_sum;
  integer i;
  norm_acc #(.BOUND(32'd1000000)) dut(.clk(clk),.rst_n(rst_n),.start(start),.s1_data(s1_data),.s1_valid(s1_valid),.s1_ready(s1_ready),
    .s2_data(s2_data),.s2_valid(s2_valid),.s2_ready(s2_ready),.done(done),.valid_signature(valid_signature),.norm_sum(norm_sum));
  initial begin
    repeat(3) @(negedge clk); rst_n=1; start=1; @(negedge clk); start=0;
    for(i=0;i<512;i=i+1) begin @(negedge clk); s1_data=2; s2_data=-1; s1_valid=1; s2_valid=1; end
    @(negedge clk); s1_valid=0;s2_valid=0; wait(done);
    if(!valid_signature) $fatal(1,"expected accept");
    if(norm_sum !== 32'd2560) $fatal(1,"norm expected 2560 got %0d",norm_sum);
    $display("PASS tb_norm_acc: norm=%0d",norm_sum); $finish;
  end
  initial begin #20000000; $fatal(1,"timeout"); end
endmodule
