
`timescale 1ns / 1ps

module tb_falcon_verifier_top;

    localparam int N = 512;
    localparam int PAYLOAD_WORDS = 11;
    localparam int PAYLOAD_BITS  = 344;
    localparam int S2_BYTES      = 576;

    logic clk;
    logic rst_n;
    logic start;

    logic [31:0] payload_word;
    logic        payload_valid;
    logic        payload_ready;
    logic [15:0] payload_bits;

    logic [7:0] s2_byte;
    logic       s2_byte_valid;
    logic       s2_byte_ready;

    logic [13:0] h_data;
    logic        h_valid;
    logic        h_ready;

    logic        done;
    logic        valid_signature;
    logic        error_s2;
    logic [31:0] norm_sum;

    logic [S2_BYTES*8-1:0] s2_bits;

    integer payload_count;
    integer h_count;
    integer s2_count;

    logic [3:0] previous_state;

    // ------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------
    falcon_verifier_top #(
        .N(N)
    ) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .start            (start),

        .payload_word     (payload_word),
        .payload_valid    (payload_valid),
        .payload_ready    (payload_ready),
        .payload_bits     (payload_bits),

        .s2_byte          (s2_byte),
        .s2_byte_valid    (s2_byte_valid),
        .s2_byte_ready    (s2_byte_ready),

        .h_data           (h_data),
        .h_valid          (h_valid),
        .h_ready          (h_ready),

        .done             (done),
        .valid_signature  (valid_signature),
        .error_s2         (error_s2),
        .norm_sum         (norm_sum)
    );

    // ------------------------------------------------------------
    // Clock
    // ------------------------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    
    // ------------------------------------------------------------
    // Debug monitor: print events, not continuously asserted levels
    // ------------------------------------------------------------
    logic [3:0] previous_state;
    logic       previous_s2_done;

    initial begin
        previous_state   = 4'hF;
        previous_s2_done = 1'b0;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            previous_state   <= 4'hF;
            previous_s2_done <= 1'b0;
        end else begin

            // FSM state transitions only
            if (dut.top_state !== previous_state) begin
                $display(
                    "[DBG][FSM] t=%0t state %0d -> %0d",
                    $time, previous_state, dut.top_state
                );
                previous_state <= dut.top_state;
            end

            // s2_done only once, when it first asserts
            if ((dut.s2_done === 1'b1) &&
                (previous_s2_done !== 1'b1)) begin
                $display(
                    "[DBG] t=%0t s2 decompression completed",
                    $time
                );
            end
            previous_s2_done <= dut.s2_done;

            // Polynomial output becomes valid
            if (dut.poly_t_valid === 1'b1 &&
                dut.poly_t_ready === 1'b1) begin
                $display(
                    "[DBG] t=%0t polynomial output handshake",
                    $time
                );
            end

            // s1/norm processing handshake
            if (dut.s1_valid === 1'b1 &&
                dut.s1_ready === 1'b1) begin
                $display(
                    "[DBG] t=%0t s1/norm handshake norm_sum=%0d",
                    $time, norm_sum
                );
            end

            // Norm check completion
            if (dut.norm_done === 1'b1) begin
                $display(
                    "[DBG] t=%0t norm_done=1 norm_sum=%0d valid_signature=%b",
                    $time, norm_sum, valid_signature
                );
            end

            if (error_s2 === 1'b1) begin
                $display("[DBG] t=%0t error_s2=1", $time);
            end
        end
    end


    // ------------------------------------------------------------
    // Main stimulus
    // ------------------------------------------------------------
    initial begin
        rst_n          = 1'b0;
        start          = 1'b0;

        payload_word   = '0;
        payload_valid  = 1'b0;
        payload_bits   = PAYLOAD_BITS;

        s2_byte        = '0;
        s2_byte_valid  = 1'b0;

        h_data         = '0;
        h_valid        = 1'b0;

        payload_count  = 0;
        h_count        = 0;
        s2_count       = 0;

        s2_bits        = '0;

        // Each zero coefficient is encoded as:
        // sign = 0, low 7 magnitude bits = 0000000,
        // unary quotient = 1.
        //
        // Nine bits per coefficient, MSB-first.
        // 512 * 9 = 4608 bits = 576 bytes.
        for (integer i = 0; i < N; i = i + 1)
            s2_bits[i*9 + 8] = 1'b1;

        repeat (5) @(negedge clk);
        rst_n = 1'b1;

        repeat (2) @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        $display("[TB] Start pulse sent");

        // Drive the three input streams concurrently.
        fork

            // ----------------------------------------------------
            // SHAKE payload: 11 zero words = 352 transmitted bits.
            // The declared message length is 344 bits.
            // ----------------------------------------------------
            begin : send_payload
                for (integer i = 0; i < PAYLOAD_WORDS; i = i + 1) begin
                    @(negedge clk);
                    payload_word  = 32'h00000000;
                    payload_valid = 1'b1;
                    payload_bits  = PAYLOAD_BITS;

                    do begin
                        @(posedge clk);
                    end while (payload_ready !== 1'b1);

                    payload_count = payload_count + 1;

                    @(negedge clk);
                    payload_valid = 1'b0;
                end

                $display("[TB] Payload stream accepted: %0d words",
                         payload_count);
            end

            // ----------------------------------------------------
            // Public key h: 512 zero coefficients
            // ----------------------------------------------------
            begin : send_h
                for (integer i = 0; i < N; i = i + 1) begin
                    @(negedge clk);
                    h_data  = 14'd0;
                    h_valid = 1'b1;

                    do begin
                        @(posedge clk);
                    end while (h_ready !== 1'b1);

                    h_count = h_count + 1;
                end

                @(negedge clk);
                h_valid = 1'b0;

                $display("[TB] Public-key stream accepted: %0d coefficients",
                         h_count);
            end

            // ----------------------------------------------------
            // Compressed s2: 576 bytes
            // Pack each byte MSB-first from s2_bits.
            // Hold valid until the byte is accepted.
            // ----------------------------------------------------
            begin : send_s2
                for (integer i = 0; i < S2_BYTES; i = i + 1) begin
                    @(negedge clk);

                    s2_byte = {
                        s2_bits[i*8 + 0],
                        s2_bits[i*8 + 1],
                        s2_bits[i*8 + 2],
                        s2_bits[i*8 + 3],
                        s2_bits[i*8 + 4],
                        s2_bits[i*8 + 5],
                        s2_bits[i*8 + 6],
                        s2_bits[i*8 + 7]
                    };

                    s2_byte_valid = 1'b1;

                    do begin
                        @(posedge clk);
                    end while (s2_byte_ready !== 1'b1);

                    s2_count = s2_count + 1;
                end

                @(negedge clk);
                s2_byte_valid = 1'b0;

                $display("[TB] Compressed s2 stream accepted: %0d bytes",
                         s2_count);
            end

        join

        $display("[TB] All input streams accepted");
        $display("[TB] payload=%0d h=%0d s2_bytes=%0d",
                 payload_count, h_count, s2_count);

        // --------------------------------------------------------
        // Wait 1: decompression completion or decompression error
        // --------------------------------------------------------
        $display("[TB] Waiting for s2_done or error_s2...");

        wait ((dut.s2_done === 1'b1) || (error_s2 === 1'b1));

        if (error_s2 === 1'b1)
            $fatal(1, "[TB] FAIL: s2 decompression error");

        $display("[TB] s2 decompression completed successfully");

        // --------------------------------------------------------
        // Wait 2: top-level verification completion
        // --------------------------------------------------------
        $display("[TB] Waiting for top-level done...");

        wait (done === 1'b1);

        $display("[TB] Top-level done asserted");
        $display("[TB] valid_signature=%b norm_sum=%0d",
                 valid_signature, norm_sum);

        if (valid_signature === 1'b1) begin
            $display("[TB] Signature accepted");
        end else begin
            $display("[TB] Signature rejected");
        end

        $display("PASS: top-level transaction completed without hanging");
        $finish;
    end

    // ------------------------------------------------------------
    // Global timeout
    // ------------------------------------------------------------
    initial begin
        #200000000;
        $fatal(1,
            "[TB] TIMEOUT: done=%b state=%0d s2_done=%b error_s2=%b norm_done=%b poly_t_valid=%b s1_valid=%b norm_sum=%0d",
            done,
            dut.top_state,
            dut.s2_done,
            error_s2,
            dut.norm_done,
            dut.poly_t_valid,
            dut.s1_valid,
            norm_sum
        );
    end

endmodule
