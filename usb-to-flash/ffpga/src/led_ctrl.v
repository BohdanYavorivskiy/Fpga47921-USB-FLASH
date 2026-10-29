// LED on-time controller driven by USB commands.
//   set : load on-time in ms (16'hFFFF = on always_on, 0 = off)
//   off : turn LED off
// TICK_DIV = clk cycles per millisecond (48 MHz -> 48000).

module led_ctrl #(
    parameter TICK_DIV = 48000
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        set,
    input  wire        off,
    input  wire [15:0] ms,
    output wire        led
);

    reg [15:0] tcnt;
    reg [15:0] rem;
    reg        always_on;

    wire tick = (tcnt == TICK_DIV - 1);

    always @(posedge clk) begin
        if (rst || off) begin
            always_on <= 1'b0;
            rem     <= 16'd0;
            tcnt    <= 16'd0;
        end else if (set) begin
            tcnt <= 16'd0;
            if (ms == 16'hFFFF) begin
                always_on <= 1'b1;
                rem     <= 16'd0;
            end else begin
                always_on <= 1'b0;
                rem     <= ms;
            end
        end else begin
            tcnt <= tick ? 16'd0 : tcnt + 16'd1;
            if (tick && rem != 16'd0) rem <= rem - 16'd1;
        end
    end

    assign led = always_on || (rem != 16'd0);

endmodule
