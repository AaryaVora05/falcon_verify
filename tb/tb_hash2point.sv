`timescale 1ns/1ps

module tb_hash2point;

    localparam integer Q = 12289;
    localparam integer FIVE_Q = 61445;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst = 1'b1;
    logic [15:0] rand_chunk = 16'd0;
    logic rand_valid = 1'b0;

    wire rand_ready;
    wire [13:0] c_coeff;
    wire [8:0] c_addr;
    wire c_we;
    wire done;

    integer writes = 0;
    integer rejects = 0;
    integer candidates_sent = 0;
    integer expected [0:15];

    hash2point dut (
        .clk        (clk),
        .rst        (rst),
        .rand_chunk (rand_chunk),
        .rand_valid (rand_valid),
        .rand_ready (rand_ready),
        .c_coeff    (c_coeff),
        .c_addr     (c_addr),
        .c_we       (c_we),
        .done       (done)
    );

    // Expected coefficients from the Python reference.
    initial begin
        expected[0]  = 4091;
        expected[1]  = 3533;
        expected[2]  = 2371;
        expected[3]  = 5949;
        expected[4]  = 3660;
        expected[5]  = 1340;
        expected[6]  = 12197;
        expected[7]  = 8733;
        expected[8]  = 6714;
        expected[9]  = 1842;
        expected[10] = 5212;
        expected[11] = 8489;
        expected[12] = 11886;
        expected[13] = 11545;
        expected[14] = 2055;
        expected[15] = 8230;
    end

    // Monitor registered output writes.
    // c_we is observed at the falling edge after its rising-edge update.
    always @(negedge clk) begin
        if (!rst && c_we) begin

            if (writes >= 16)
                $fatal(1, "Unexpected extra coefficient write");

            if (c_addr !== writes[8:0])
                $fatal(1,
                    "Address mismatch: write=%0d addr=%0d",
                    writes, c_addr);

            if (c_coeff !== expected[writes])
                $fatal(1,
                    "Coefficient mismatch at c[%0d]: got=%0d expected=%0d",
                    writes, c_coeff, expected[writes]);

            if (c_coeff >= Q)
                $fatal(1,
                    "Coefficient out of range: %0d", c_coeff);

            $display("PASS c[%0d] = %0d",
                     writes, c_coeff);

            writes = writes + 1;
        end
    end

    // Drive one candidate and hold valid until a rising-edge handshake.
    task automatic send(input logic [15:0] x);
        begin
            @(negedge clk);
            rand_chunk = x;
            rand_valid = 1'b1;

            // At this point the candidate is held stable.
            do begin
                @(posedge clk);
            end while (rand_ready !== 1'b1);

            candidates_sent = candidates_sent + 1;

            if (x >= FIVE_Q) begin
                rejects = rejects + 1;
                $display("REJECT candidate 0x%04h (%0d)", x, x);
            end

            @(negedge clk);
            rand_valid = 1'b0;
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst = 1'b0;

        // Candidates from the Python SHAKE256 reference.
        send(16'hCFFF); // c[0]  = 4091
        send(16'h6DCF); // c[1]  = 3533
        send(16'hF75A); // REJECT
        send(16'h3944); // c[2]  = 2371
        send(16'h173D); // c[3]  = 5949
        send(16'h0E4C); // c[4]  = 3660
        send(16'hF6A7); // REJECT
        send(16'h053C); // c[5]  = 1340
        send(16'h8FA7); // c[6]  = 12197
        send(16'hE221); // c[7]  = 8733
        send(16'hDA3E); // c[8]  = 6714
        send(16'hC736); // c[9]  = 1842
        send(16'h145C); // c[10] = 5212
        send(16'h2129); // c[11] = 8489
        send(16'h8E70); // c[12] = 11886
        send(16'hED1D); // c[13] = 11545
        send(16'h6809); // c[14] = 2055
        send(16'h5027); // c[15] = 8230

        repeat (2) @(negedge clk);

        if (writes != 16)
            $fatal(1, "Expected 16 writes, observed %0d", writes);

        if (rejects != 2)
            $fatal(1, "Expected 2 rejected candidates, observed %0d",
                   rejects);

        if (candidates_sent != 18)
            $fatal(1, "Expected 18 candidates, observed %0d",
                   candidates_sent);

        $display("");
        $display("PASS tb_hash2point");
        $display("Coefficients checked: %0d", writes);
        $display("Candidates sent:      %0d", candidates_sent);
        $display("Rejected candidates:  %0d", rejects);
        $display("All 16 coefficients and addresses match Python.");

        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "TIMEOUT");
    end

endmodule