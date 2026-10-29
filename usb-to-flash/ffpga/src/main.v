// USB Full-Speed device on GPIO24 (D-) / GPIO25 (D+), soft-connect pull-up via GPIO26 (1k to D+)

(* top *) module main (
    (* clkbuf_inhibit *) input i_clk,      // PLL0 FOUT0 = 48 MHz via global clock network

    // ----------------------------------------------
    // Oscillator (50 MHz HF mode, PLL reference)
    // ----------------------------------------------
    output osc_en,
    output osc_mode,

    // ----------------------------------------------
    // PLL0
    // ----------------------------------------------

    // Port List
    output pll0_en,
    output [5:0] pll0_refdiv,
    output [11:0] pll0_fbdiv,
    output [2:0] pll0_postdiv0_out0,
    output [2:0] pll0_postdiv1_out0,
    output [1:0] pll0_ref_clk_sel,
    output pll0_bypass,
    input  pll0_lock,

    // ----------------------------------------------
    // USB
    // ----------------------------------------------
    input  usb_dp_i,        // GPIO25_IN
    input  usb_dn_i,        // GPIO24_IN
    output usb_dp,          // GPIO25_OUT
    output usb_dp_oe,       // GPIO25_OE
    output usb_dn,          // GPIO24_OUT
    output usb_dn_oe,       // GPIO24_OE
    output usb_pu,          // GPIO26_OUT (pull-up on D+ through 1k)
    output usb_pu_oe,       // GPIO26_OE

    // ----------------------------------------------
    // Button (GPIO36, active high) and LED (GPIO4, active high)
    // ----------------------------------------------
    input  btn,             // GPIO36_IN
    output led,             // GPIO4_OUT
    output led_oe           // GPIO4_OE
);

    // Assigned signals
    assign osc_en  = 1'b1;
    assign osc_mode = 1'b1;                    // HF = 50 MHz

    assign pll0_en = 1'b1;
    assign pll0_refdiv = 6'b00_0101;		// Equivalent value in decimal form 6'd5
    assign pll0_fbdiv = 12'b0000_0100_1000;	// Equivalent value in decimal form 12'd72
    assign pll0_postdiv0_out0 = 3'b101;	// Equivalent value in decimal form 3'd5
    assign pll0_postdiv1_out0 = 3'b011;	// Equivalent value in decimal form 3'd3
    assign pll0_bypass = 1'b0;
    assign pll0_ref_clk_sel = 2'b00;		// OSC

    // 50 MHz / 5 = 10 MHz; x72 = 720 MHz VCO; / (5*3) = 48 MHz

    // ----------------------------------------------
    // Reset from PLL lock
    // ----------------------------------------------
    reg [1:0] lock_sr = 2'b00;
    always @(posedge i_clk) lock_sr <= {lock_sr[0], pll0_lock};
    wire rst = ~lock_sr[1];

    // ----------------------------------------------
    // USB
    // ----------------------------------------------
    wire       rx_sop, rx_bit_v, rx_bit, rx_eop, rx_err, bus_reset;
    wire       tx_start, tx_valid, tx_next, tx_busy;
    wire [7:0] tx_data;
    wire       dp_o, dn_o, oe;

    usb_phy u_phy (
        .clk       (i_clk),
        .rst       (rst),
        .dp_i      (usb_dp_i),
        .dn_i      (usb_dn_i),
        .dp_o      (dp_o),
        .dn_o      (dn_o),
        .oe        (oe),
        .rx_sop    (rx_sop),
        .rx_bit_v  (rx_bit_v),
        .rx_bit    (rx_bit),
        .rx_eop    (rx_eop),
        .rx_err    (rx_err),
        .bus_reset (bus_reset),
        .tx_start  (tx_start),
        .tx_data   (tx_data),
        .tx_valid  (tx_valid),
        .tx_next   (tx_next),
        .tx_busy   (tx_busy)
    );

    wire        led_set, led_off;
    wire [15:0] led_ms;
    wire        led_usb, led_btn;

    usb_dev u_dev (
        .clk       (i_clk),
        .rst       (rst),
        .rx_sop    (rx_sop),
        .rx_bit_v  (rx_bit_v),
        .rx_bit    (rx_bit),
        .rx_eop    (rx_eop),
        .rx_err    (rx_err),
        .bus_reset (bus_reset),
        .tx_start  (tx_start),
        .tx_data   (tx_data),
        .tx_valid  (tx_valid),
        .tx_next   (tx_next),
        .led_set   (led_set),
        .led_off   (led_off),
        .led_ms    (led_ms)
    );

    led_ctrl u_led_ctrl (
        .clk (i_clk),
        .rst (rst),
        .set (led_set),
        .off (led_off),
        .ms  (led_ms),
        .led (led_usb)
    );

    assign usb_dp   = dp_o;
    assign usb_dn    = dn_o;
    assign usb_dp_oe = oe;
    assign usb_dn_oe = oe;

    // soft-connect: pull D+ high through GPIO26 once the clock is running
    assign usb_pu    = 1'b1;
    assign usb_pu_oe = ~rst;

    // ----------------------------------------------
    // "Bitstream is loaded" indicator: LED blinks twice on button press
    // ----------------------------------------------
    btn_led u_btn_led (
        .clk (i_clk),
        .rst (rst),
        .btn (btn),
        .led (led_btn)
    );
    assign led = led_btn | led_usb;
    assign led_oe = 1'b1;

endmodule
