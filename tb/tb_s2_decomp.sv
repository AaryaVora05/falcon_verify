`timescale 1ns/1ps

// Reproducible edge-case testbench for falcon_decompress.
// Checks all 512 coefficients, write order/count, valid-stream completion,
// and timeout. Uses a fixed-seed LCG instead of simulator-specific $urandom.
module tb_s2_decomp_edge;
  localparam integer N = 512;
  localparam integer MAX_BITS = 24*N;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic rst_n = 1'b0;
  logic start = 1'b0;
  logic [7:0] rx_data = 8'h00;
  logic rx_valid = 1'b0;
  wire rx_ready;
  wire signed [11:0] s2_coeff;
  wire [8:0] s2_addr;
  wire s2_we, done, error;

  falcon_decompress dut (
    .clk(clk), .rst_n(rst_n), .start(start),
    .rx_data(rx_data), .rx_valid(rx_valid), .rx_ready(rx_ready),
    .s2_coeff(s2_coeff), .s2_addr(s2_addr), .s2_we(s2_we),
    .done(done), .error(error)
  );

  // Each array element stores one bit; only [0:bit_len-1] is used.
  reg stream_bits [0:MAX_BITS-1];
  integer expected [0:N-1];

  integer bit_len = 0;
  integer writes = 0;
  integer i, b, mag, byte_idx;
  reg [7:0] tx_byte;
  reg accepted;

  // Deterministic 32-bit LCG:
  // state[n+1] = state[n]*1664525 + 1013904223 modulo 2^32.
  reg [31:0] rng_state;
  localparam [31:0] RNG_SEED = 32'h1234ABCD;

  function automatic [31:0] lcg_next(input [31:0] x);
    begin
      lcg_next = x * 32'd1664525 + 32'd1013904223;
    end
  endfunction

  task automatic append_bit(input bit value);
    begin
      if (bit_len >= MAX_BITS)
        $fatal(1, "FAIL: test encoder bit buffer overflow at bit %0d", bit_len);
      stream_bits[bit_len] = value;
      bit_len = bit_len + 1;
    end
  endtask

  task automatic append_coeff(input integer value);
    integer m, k, quotient, low_bits;
    begin
      m = (value < 0) ? -value : value;
      if (m > 2047)
        $fatal(1, "FAIL: out-of-range test coefficient %0d", value);

      append_bit(value < 0);                  // sign
      low_bits = m & 127;
      for (k = 6; k >= 0; k = k - 1)
        append_bit((low_bits >> k) & 1);       // low 7 bits

      quotient = m >> 7;
      for (k = 0; k < quotient; k = k + 1)
        append_bit(1'b0);                     // unary quotient
      append_bit(1'b1);                       // unary terminator
    end
  endtask

  // DUT registers s2_we/address/data. Check each asserted write with case
  // inequality, which treats X/Z as a failure.
  always @(posedge clk) begin
    if (rst_n && s2_we) begin
      if ((^s2_addr) === 1'bx)
        $fatal(1, "FAIL: s2_addr contains X/Z");
      if (s2_addr >= N)
        $fatal(1, "FAIL: out-of-range address %0d", s2_addr);
      if (s2_coeff !== expected[s2_addr])
        $fatal(1, "FAIL: addr=%0d expected=%0d got=%0d (0x%03h)",
               s2_addr, expected[s2_addr], s2_coeff, s2_coeff);
      if (s2_addr !== writes[8:0])
        $fatal(1, "FAIL: write #%0d had address %0d; expected sequential address",
               writes, s2_addr);
      writes = writes + 1;
    end
  end

  initial begin
    rng_state = RNG_SEED;

    // Explicit boundary cases.
    expected[0]  = 0;
    expected[1]  = 1;
    expected[2]  = -1;
    expected[3]  = 127;
    expected[4]  = -127;
    expected[5]  = 128;
    expected[6]  = -128;
    expected[7]  = 129;
    expected[8]  = -129;
    expected[9]  = 255;
    expected[10] = -255;
    expected[11] = 256;
    expected[12] = -256;
    expected[13] = 1919;
    expected[14] = -1919;
    expected[15] = 1920;
    expected[16] = -1920;
    expected[17] = 2046;
    expected[18] = -2046;
    expected[19] = 2047;
    expected[20] = -2047;

    // Deterministic pseudo-random values; same sequence each run.
    // Zero is always positive, so the test never emits invalid negative zero.
    for (i = 21; i < N; i = i + 1) begin
      rng_state = lcg_next(rng_state);
      mag = rng_state % 2048;
      if (mag == 0) begin
        expected[i] = 0;
      end else begin
        rng_state = lcg_next(rng_state);
        expected[i] = rng_state[0] ? -mag : mag;
      end
    end

    // Pack all coefficient fields MSB-first.
    bit_len = 0;
    for (i = 0; i < N; i = i + 1)
      append_coeff(expected[i]);

    // Strict decoder requires zero padding to the next byte boundary.
    while ((bit_len % 8) != 0)
      append_bit(1'b0);

    if ((bit_len/8) <= 0 || bit_len > MAX_BITS)
      $fatal(1, "FAIL: invalid encoded stream length %0d bits", bit_len);

    $display("[TB] Fixed PRNG seed = 0x%08h", RNG_SEED);
    $display("[TB] Encoded %0d coefficients into %0d bytes (%0d bits including padding)",
             N, bit_len/8, bit_len);

    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;

    // Send one byte at a time and hold valid/data until handshake.
    for (byte_idx = 0; byte_idx < bit_len/8; byte_idx = byte_idx + 1) begin
      tx_byte = 8'h00;
      for (b = 0; b < 8; b = b + 1)
        tx_byte[7-b] = stream_bits[byte_idx*8 + b];

      @(negedge clk);
      rx_data = tx_byte;
      rx_valid = 1'b1;
      accepted = 1'b0;

      while (!accepted) begin
        @(posedge clk);
        accepted = (rx_valid && rx_ready);
      end

      @(negedge clk);
      rx_valid = 1'b0;
    end

    wait (done || error);
    repeat (2) @(negedge clk);

    if (error)
      $fatal(1, "FAIL: decompressor asserted error for a valid stream");
    if (done !== 1'b1)
      $fatal(1, "FAIL: done was not known-high at completion");
    if (writes != N)
      $fatal(1, "FAIL: expected %0d writes, observed %0d", N, writes);

    $display("PASS tb_s2_decomp_edge: all %0d mixed-sign coefficients matched", N);
    $display("[TB] Boundary and deterministic pseudo-random cases passed.");
    $display("[TB] Encoded bytes=%0d; checked writes=%0d", bit_len/8, writes);
    $finish;
  end

  initial begin
    #2000000;
    $fatal(1, "FAIL: timeout waiting for decompressor");
  end
endmodule
