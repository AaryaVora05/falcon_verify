`timescale 1ns/1ps
module tb_pointwise_mul;
  logic clk=0,rst_n=0,start=0; always #5 clk=~clk;
  logic [13:0] h_data=0,s2_ntt_data=0; logic h_valid=0,s2_ntt_valid=0; wire h_ready,s2_ntt_ready;
  wire [13:0] product_data; wire product_valid; logic product_ready=1; wire done;
  integer i,exp;
  pointwise_mul dut(.clk(clk),.rst_n(rst_n),.start(start),.h_data(h_data),.h_valid(h_valid),.h_ready(h_ready),
    .s2_ntt_data(s2_ntt_data),.s2_ntt_valid(s2_ntt_valid),.s2_ntt_ready(s2_ntt_ready),.product_data(product_data),
    .product_valid(product_valid),.product_ready(product_ready),.done(done));
  initial begin
    repeat(3) @(negedge clk); rst_n=1; start=1; @(negedge clk); start=0;
    for(i=0;i<512;i=i+1) begin
      @(negedge clk); h_data=(i*23)%12289; s2_ntt_data=(i*37)%12289; h_valid=1;s2_ntt_valid=1;
      exp=(((i*23)%12289)*((i*37)%12289))%12289;
      #1;
      if(!product_valid || product_data !== exp) $fatal(1,"pointwise mismatch i=%0d got=%0d expected=%0d",i,product_data,exp);
      @(posedge clk);
    end
    @(negedge clk); h_valid=0;s2_ntt_valid=0; wait(done);
    $display("PASS tb_pointwise_mul"); $finish;
  end
  initial begin #20000000; $fatal(1,"timeout"); end
endmodule
