// Button (active high) -> LED (active high) blinks twice per press.
// Used to confirm that the bitstream is loaded into the chip.
// 48 MHz: DEB_BITS=19 -> ~10.9 ms debounce, PH_BITS=23 -> ~175 ms per LED phase.

module btn_led #(
    parameter DEB_BITS = 19,
    parameter PH_BITS  = 23
) (
    input  wire clk,
    input  wire rst,
    input  wire btn,
    output wire led
);

    reg btn_s1, btn_s2;
    always @(posedge clk) begin
        btn_s1 <= btn;
        btn_s2 <= btn_s1;
    end

    // debounce
    reg [DEB_BITS-1:0] dcnt;
    reg                stable;
    reg                press;
    always @(posedge clk) begin
        press <= 1'b0;
        if (rst) begin
            dcnt   <= {DEB_BITS{1'b0}};
            stable <= 1'b0;
        end else if (btn_s2 != stable) begin
            dcnt <= dcnt + 1'b1;
            if (&dcnt) begin
                stable <= btn_s2;
                dcnt   <= {DEB_BITS{1'b0}};
                press  <= btn_s2;
            end
        end else begin
            dcnt <= {DEB_BITS{1'b0}};
        end
    end

    // blink: phases 1..4 = on, off, on, off
    reg [2:0]         phase;
    reg [PH_BITS-1:0] pcnt;
    always @(posedge clk) begin
        if (rst) begin
            phase <= 3'd0;
            pcnt  <= {PH_BITS{1'b0}};
        end else if (phase == 3'd0) begin
            pcnt <= {PH_BITS{1'b0}};
            if (press) phase <= 3'd1;
        end else begin
            pcnt <= pcnt + 1'b1;
            if (&pcnt) phase <= (phase == 3'd4) ? 3'd0 : phase + 3'd1;
        end
    end

    assign led = (phase == 3'd1) || (phase == 3'd3);

endmodule
