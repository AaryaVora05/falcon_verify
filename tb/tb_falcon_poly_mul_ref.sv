`timescale 1ns/1ps
module tb_falcon_poly_mul_ref;
  localparam N=512,Q=12289;
  logic clk=0,rst_n=0,start=0; always #5 clk=~clk;
  logic [13:0] h_load_data=0; logic h_load_valid=0; wire h_load_ready;
  logic signed [11:0] s2_load_data=0; logic s2_load_valid=0; wire s2_load_ready;
  wire [13:0] t_data; wire t_valid; logic t_ready=1; wire done,busy;
  integer i,j,k,expected;
  integer h[N],s2[N],gold[N];
  falcon_poly_mul_ref dut(.clk(clk),.rst_n(rst_n),.start(start),.h_load_data(h_load_data),.h_load_valid(h_load_valid),.h_load_ready(h_load_ready),
    .s2_load_data(s2_load_data),.s2_load_valid(s2_load_valid),.s2_load_ready(s2_load_ready),.t_data(t_data),.t_valid(t_valid),.t_ready(t_ready),.done(done),.busy(busy));
  initial begin
    for(i=0;i<N;i=i+1) begin h[i]=(i*7+3)%29; s2[i]=(i%9)-4; gold[i]=0; end
    // Direct negacyclic convolution reference.
    for(i=0;i<N;i=i+1) for(j=0;j<N;j=j+1) begin
      k=i+j; if(k>=N) gold[k-N]=gold[k-N]-h[i]*s2[j]; else gold[k]=gold[k]+h[i]*s2[j];
    end
    for(i=0;i<N;i=i+1) begin gold[i]=gold[i]%Q; if(gold[i]<0) gold[i]=gold[i]+Q; end
    repeat(3) @(negedge clk); rst_n=1; start=1; @(negedge clk); start=0;
    for(i=0;i<N;i=i+1) begin @(negedge clk); h_load_data=h[i];h_load_valid=1; do @(posedge clk); while(!h_load_ready); end
    @(negedge clk); h_load_valid=0;
    for(i=0;i<N;i=i+1) begin @(negedge clk); s2_load_data=s2[i];s2_load_valid=1; do @(posedge clk); while(!s2_load_ready); end
    @(negedge clk); s2_load_valid=0;
    i=0;
    while(i<N) begin
      @(negedge clk);
      if(t_valid && t_ready) begin
        if(t_data !== gold[i]) $fatal(1,"poly mismatch i=%0d got=%0d expected=%0d",i,t_data,gold[i]);
        @(posedge clk); // accept this coefficient after checking pre-edge data
        i=i+1;
      end else begin
        @(posedge clk);
      end
    end
    wait(done); $display("PASS tb_falcon_poly_mul_ref: 512 outputs match direct convolution"); $finish;
  end
  initial begin #200000000; $fatal(1,"timeout"); end
endmodule
