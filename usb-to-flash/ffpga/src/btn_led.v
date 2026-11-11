// LED (active high) blinks BOOT_BLINKS times after power-up / reset release,
// and twice per button press (active high). Confirms that the bitstream is loaded.
// Timing comes from the shared 1.365 ms tick (led_ctrl.tick_ms) instead of private
// free-running counters: debounce = 2^DEB_BITS - DEB_INIT ticks (8 -> 10.9 ms),
// LED phase = 2^PH_BITS - PH_INIT ticks (128 -> 175 ms).

module btn_led #(
    parameter DEB_BITS = 4,
    parameter DEB_INIT = 8,
    parameter PH_BITS  = 8,
    parameter PH_INIT  = 128,
    parameter BOOT_BLINKS = 4     // blinks after reset; 0 disables
) (
    input  wire clk,
    input  wire rst,
    input  wire btn,
    input  wire tick,
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
            dcnt   <= DEB_INIT;
            stable <= 1'b0;
        end else if (btn_s2 != stable) begin
            if (tick) begin
                dcnt <= dcnt + 1'b1;
                if (&dcnt) begin
                    stable <= btn_s2;
                    dcnt   <= DEB_INIT;
                    press  <= btn_s2;
                end
            end
        end else begin
            dcnt <= DEB_INIT;
        end
    end

    // blink: odd phases = on, even = off; last phase = 2*blinks
    reg [3:0]         phase;
    reg [3:0]         last;       // final phase of the running sequence
    reg               boot;       // pending power-up sequence
    reg [PH_BITS-1:0] pcnt;
    always @(posedge clk) begin
        if (rst) begin
            phase <= 4'd0;
            pcnt  <= PH_INIT;
            boot  <= (BOOT_BLINKS != 0);
        end else if (phase == 4'd0) begin
            pcnt <= PH_INIT;
            if (boot) begin
                boot  <= 1'b0;
                last  <= 2 * BOOT_BLINKS;
                phase <= 4'd1;
            end else if (press) begin
                last  <= 4'd4;
                phase <= 4'd1;
            end
        end else if (tick) begin
            pcnt <= pcnt + 1'b1;
            if (&pcnt) begin
                pcnt  <= PH_INIT;
                phase <= (phase == last) ? 4'd0 : phase + 4'd1;
            end
        end
    end

    assign led = phase[0];                 // odd phases = LED on

endmodule
