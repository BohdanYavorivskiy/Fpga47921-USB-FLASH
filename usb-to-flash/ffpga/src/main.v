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
    // SPI master (CS#, SCK, MISO, MOSI)
    // ----------------------------------------------
    output spi_cs,
    output spi_cs_oe,
    output spi_clk,
    output spi_clk_oe,
    input  spi_miso_i,
    output spi_mosi,
    output spi_mosi_oe,

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

    wire        led_force, usb_act, tick_ms;
    wire        led_usb, led_btn;
    wire        spi_start, spi_cs_en, spi_busy, spi_done, spi_sck, spi_mosi_w;
    wire [7:0]  spi_tx, spi_rx;
    wire [3:0]  spi_div;

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
        .led_force (led_force),
        .act       (usb_act),
        .spi_start (spi_start),
        .spi_tx    (spi_tx),
        .spi_cs_en (spi_cs_en),
        .spi_div   (spi_div),
        .spi_rx    (spi_rx),
        .spi_busy  (spi_busy),
        .spi_done  (spi_done)
    );

    spi_master u_spi (
        .clk     (i_clk),
        .rst     (rst),
        .start   (spi_start),
        .tx_data (spi_tx),
        .div     (spi_div),
        .miso    (spi_miso_i),
        .sck     (spi_sck),
        .mosi    (spi_mosi_w),
        .busy    (spi_busy),
        .done    (spi_done),
        .rx_data (spi_rx)
    );

    assign spi_cs      = ~spi_cs_en;
    assign spi_cs_oe   = 1'b1;
    assign spi_clk     = spi_sck;
    assign spi_clk_oe  = 1'b1;
    assign spi_mosi    = spi_mosi_w;
    assign spi_mosi_oe = 1'b1;

    led_ctrl u_led_ctrl (
        .clk (i_clk),
        .rst (rst),
        .force_on (led_force),
        .act      (usb_act),
        .led      (led_usb),
        .tick_ms  (tick_ms)
    );

    assign usb_dp   = dp_o;
    assign usb_dn    = dn_o;
    assign usb_dp_oe = oe;
    assign usb_dn_oe = oe;

    // soft-connect: pull D+ high through GPIO26 once the clock is running
    assign usb_pu    = 1'b1;
    assign usb_pu_oe = ~rst;

    // ----------------------------------------------
    // "Bitstream is loaded" indicator: five boot blinks, two per button press.
    // ----------------------------------------------
    btn_led #(.BOOT_BLINKS(4)) u_btn_led (
        .clk (i_clk),
        .rst (rst),
        .btn (btn),
        .tick (tick_ms),
        .led (led_btn)
    );
    assign led = led_btn | led_usb;
    assign led_oe = 1'b1;

endmodule
