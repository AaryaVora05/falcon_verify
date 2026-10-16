
`timescale 1ns/1ps

module tb_falcon_shake256_wrapper;

  localparam integer OUT_BYTES  = 2048;
  localparam integer EXPECT_CHUNKS = OUT_BYTES/2; // 2 bytes per chunk
  localparam integer INPUT_BYTES = 43;
  localparam integer INPUT_BITS  = INPUT_BYTES * 8;
  localparam integer INPUT_WORDS = (INPUT_BITS + 31) / 32;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic rst_n = 1'b0;
  logic start = 1'b0;

  logic [31:0] payload_word = 32'd0;
  logic payload_valid = 1'b0;
  wire  payload_ready;
  logic [15:0] payload_bits = INPUT_BITS;

  wire [15:0] rand_chunk;
  wire rand_valid;
  logic rand_ready = 1'b1;

  integer chunks = 0;
  integer input_words_sent = 0;
  integer timeout_cycles = 0;
  integer i;

  logic [31:0] input_data [0:INPUT_WORDS-1];

  falcon_shake256_wrapper #(
    .SHAKE_OUT_BYTES(OUT_BYTES)
  ) dut (
    .clk(clk),
    .rst_n(rst_n),
    .start(start),

    .payload_word(payload_word),
    .payload_valid(payload_valid),
    .payload_ready(payload_ready),
    .payload_bits(payload_bits),

    .rand_chunk(rand_chunk),
    .rand_valid(rand_valid),
    .rand_ready(rand_ready)
  );

  // Count only actual output handshakes.
  always @(posedge clk) begin
    if (rst_n && rand_valid && rand_ready) begin
      chunks <= chunks + 1;

      if (((chunks + 1) % 256) == 0) begin
        $display("[SHAKE TB] Output chunks: %0d / %0d at %0t",
                 chunks + 1, EXPECT_CHUNKS, $time);
      end
    end
  end

  // Main test.
  initial begin
    // 43-byte payload represented as 11 32-bit words.
    // All zeros make a simple transport test input.
    for (i = 0; i < INPUT_WORDS; i = i + 1)
      input_data[i] = 32'd0;

    $display("[SHAKE TB] Starting");
    $display("[SHAKE TB] Input: %0d bytes (%0d bits, %0d words)",
             INPUT_BYTES, INPUT_BITS, INPUT_WORDS);
    $display("[SHAKE TB] Expected output: %0d bytes (%0d chunks)",
             OUT_BYTES, EXPECT_CHUNKS);

    repeat (4) @(negedge clk);
    rst_n = 1'b1;

    repeat (2) @(negedge clk);
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;

    // Send each word with ready/valid backpressure handled correctly.
    for (i = 0; i < INPUT_WORDS; i = i + 1) begin
      @(negedge clk);
      payload_word  = input_data[i];
      payload_valid = 1'b1;

      // Hold valid and data until a rising edge accepts the word.
      do begin
        @(posedge clk);
      end while (payload_ready !== 1'b1);

      input_words_sent = input_words_sent + 1;

      @(negedge clk);
      payload_valid = 1'b0;
    end

    $display("[SHAKE TB] All %0d input words accepted at %0t",
             input_words_sent, $time);

    // Wait for exactly the requested output count.
    // The independent watchdog below will terminate a stalled simulation.
    wait (chunks == EXPECT_CHUNKS);

    // Let the last nonblocking assignments settle.
    @(negedge clk);

    if (input_words_sent != INPUT_WORDS)
      $fatal(1, "[SHAKE TB] Wrong input word count: %0d",
             input_words_sent);

    if (chunks != EXPECT_CHUNKS)
      $fatal(1, "[SHAKE TB] Wrong output count: %0d",
             chunks);

    $display("PASS tb_falcon_shake256_wrapper");
    $display("[SHAKE TB] Input words accepted: %0d", input_words_sent);
    $display("[SHAKE TB] Output chunks received: %0d", chunks);
    $display("[SHAKE TB] Output bytes represented: %0d", chunks * 2);
    $display("[SHAKE TB] Transport/length test only; output bytes not yet verified.");
    $finish;
  end

  // Watchdog: 3 ms at a 10 ns clock period.
  initial begin
    #3000000;

    $fatal(1,
      "[SHAKE TB] TIMEOUT at %0t: input_words=%0d/%0d, output_chunks=%0d/%0d",
      $time, input_words_sent, INPUT_WORDS, chunks, EXPECT_CHUNKS);
  end

endmodule
