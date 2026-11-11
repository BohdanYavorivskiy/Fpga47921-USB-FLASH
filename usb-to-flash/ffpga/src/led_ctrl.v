// LED controller + shared 1.365 ms time base.
//   LED = force_on (set by USB command) | USB activity (stretched pulse).
//   act: one clk pulse per USB transaction addressed to the device;
//        the LED stays on for ACT_TICKS ticks (~1.4 ms each) after the last one.
// The time base is a 16-bit LFSR (period 65535 clk = 1.365 ms at 48 MHz),
// which needs no carry chain, unlike a binary counter.

module led_ctrl #(
    parameter ACT_TICKS = 15      // ~20 ms
) (
    input  wire clk,
    input  wire rst,
    input  wire force_on,
    input  wire act,
    output wire led,
    output reg  tick_ms
);

    reg [15:0] lfsr;
    reg [3:0]  act_cnt;

    always @(posedge clk) begin
        if (rst) lfsr <= 16'hACE1;
        else     lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
        tick_ms <= (lfsr == 16'hACE1);
    end

    always @(posedge clk) begin
        if (rst)                          act_cnt <= 4'd0;
        else if (act)                     act_cnt <= ACT_TICKS;
        else if (tick_ms && act_cnt != 0) act_cnt <= act_cnt - 4'd1;
    end

    assign led = force_on || (act_cnt != 4'd0);

endmodule
