`timescale 1ns/1ps
module tb_s1_calc;
  logic clk=0,rst_n=0,start=0; always #5 clk=~clk;
  logic [13:0] c_data=0,t_data=0; logic c_valid=0,t_valid=0; wire c_ready,t_ready;
  wire signed [13:0] s1_data; wire s1_valid; logic s1_ready=1; wire done;
  integer i,got=0; integer exp;
  s1_calc dut(.clk(clk),.rst_n(rst_n),.start(start),.c_data(c_data),.c_valid(c_valid),.c_ready(c_ready),
    .t_data(t_data),.t_valid(t_valid),.t_ready(t_ready),.s1_data(s1_data),.s1_valid(s1_valid),.s1_ready(s1_ready),.done(done));
  initial begin
    repeat(3) @(negedge clk); rst_n=1; start=1; @(negedge clk); start=0;
    for(i=0;i<512;i=i+1) begin
      @(negedge clk); c_data=(i*17)%12289; t_data=(i*31)%12289; c_valid=1; t_valid=1;
      exp=((i*17)%12289)-((i*31)%12289); if(exp<0) exp=exp+12289; if(exp>6144) exp=exp-12289;
      #1;
      if(!s1_valid || s1_data !== exp) $fatal(1,"s1 mismatch i=%0d got=%0d expected=%0d",i,s1_data,exp);
      @(posedge clk);
      got=got+1;
    end
    @(negedge clk); c_valid=0;t_valid=0; wait(done);
    if(got!=512) $fatal(1,"count mismatch");
    $display("PASS tb_s1_calc: 512 coefficients checked"); $finish;
  end
  initial begin #20000000; $fatal(1,"timeout"); end
endmodule
