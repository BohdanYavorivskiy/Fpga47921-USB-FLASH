// USB Full-Speed (12 Mbit/s) bit-level PHY: clk = 48 MHz (4 clocks per bit).
// RX: 2FF sync, edge-resync DPLL, NRZI decode, bit unstuffing, SYNC/EOP detect.
// TX: SYNC, NRZI, bit stuffing, EOP. Bytes are pulled from the SIE (tx_valid/tx_data/tx_next).

module usb_phy (
    input  wire       clk,
    input  wire       rst,
    input  wire       dp_i,
    input  wire       dn_i,
    output reg        dp_o,
    output reg        dn_o,
    output reg        oe,

    output reg        rx_sop,     // pulse: SYNC done, PID bits follow
    output reg        rx_bit_v,   // pulse: rx_bit is a decoded data bit
    output reg        rx_bit,
    output reg        rx_eop,     // pulse: end of packet (SE0)
    output reg        rx_err,     // level: bit-stuff violation in current packet
    output reg        bus_reset,  // pulse: SE0 for > ~2.6 us

    input  wire       tx_start,   // pulse: start a packet
    input  wire [7:0] tx_data,
    input  wire       tx_valid,   // 1: tx_data is the next byte, 0: end of packet
    output reg        tx_next,    // pulse: tx_data consumed
    output wire       tx_busy
);

    localparam [1:0] J = 2'b10, K = 2'b01, SE0 = 2'b00;

    // ---------------- input synchronizer ----------------
    reg dp_s1, dp_s2, dn_s1, dn_s2, dp_d, dn_d;
    always @(posedge clk) begin
        dp_s1 <= dp_i;  dp_s2 <= dp_s1;
        dn_s1 <= dn_i;  dn_s2 <= dn_s1;
        dp_d  <= dp_s2; dn_d  <= dn_s2;
    end
    wire [1:0] ls     = {dp_s2, dn_s2};
    wire       edge_w = ({dp_d, dn_d} != ls);

    // ---------------- RX ----------------
    localparam [1:0] RX_IDLE = 2'd0, RX_SYNC = 2'd1, RX_DATA = 2'd2, RX_EOPW = 2'd3;

    reg [1:0] rx_state;
    reg [1:0] rx_cnt;
    reg [1:0] last;
    reg [2:0] zeros;
    reg [2:0] ones;

    wire tick    = (rx_cnt == 2'd1) && !edge_w;
    wire cur_bit = (ls == last);

    always @(posedge clk) begin
        rx_sop   <= 1'b0;
        rx_bit_v <= 1'b0;
        rx_eop   <= 1'b0;

        if (edge_w) rx_cnt <= 2'd0;
        else        rx_cnt <= rx_cnt + 2'd1;

        if (rst || tx_busy) begin
            rx_state <= RX_IDLE;
            last     <= J;
            rx_err   <= 1'b0;
        end else if (tick) begin
            case (rx_state)
                RX_IDLE: begin
                    if (ls == K && last == J) begin
                        rx_state <= RX_SYNC;
                        zeros    <= 3'd1;
                    end
                    if (ls == J || ls == K) last <= ls;
                end

                RX_SYNC: begin
                    if (ls == SE0 || ls == 2'b11) begin
                        rx_state <= RX_IDLE;
                    end else begin
                        last <= ls;
                        if (cur_bit) begin
                            if (zeros >= 3'd3) begin
                                rx_state <= RX_DATA;
                                rx_sop   <= 1'b1;
                                rx_err   <= 1'b0;
                                ones     <= 3'd1;
                            end else begin
                                rx_state <= RX_IDLE;
                            end
                        end else if (zeros != 3'd7) begin
                            zeros <= zeros + 3'd1;
                        end
                    end
                end

                RX_DATA: begin
                    if (ls == SE0) begin
                        rx_eop   <= 1'b1;
                        rx_state <= RX_EOPW;
                    end else begin
                        last <= ls;
                        if (ones == 3'd6) begin
                            if (cur_bit) rx_err <= 1'b1;
                            ones <= 3'd0;
                        end else begin
                            rx_bit   <= cur_bit;
                            rx_bit_v <= 1'b1;
                            ones     <= cur_bit ? ones + 3'd1 : 3'd0;
                        end
                    end
                end

                default: begin // RX_EOPW
                    if (ls == J) begin
                        rx_state <= RX_IDLE;
                        last     <= J;
                    end
                end
            endcase
        end
    end

    // ---------------- bus reset detect ----------------
    reg [6:0] se0_cnt;
    always @(posedge clk) begin
        bus_reset <= 1'b0;
        if (rst) begin
            se0_cnt <= 7'd0;
        end else if (ls == SE0 && !tx_busy) begin
            if (se0_cnt != 7'd127) se0_cnt <= se0_cnt + 7'd1;
            if (se0_cnt == 7'd126) bus_reset <= 1'b1;
        end else begin
            se0_cnt <= 7'd0;
        end
    end

    // ---------------- TX ----------------
    localparam [2:0] T_IDLE = 3'd0, T_WAIT = 3'd1, T_BITS = 3'd2,
                     T_SE0A = 3'd3, T_SE0B = 3'd4, T_JEND = 3'd5;

    reg [2:0] tstate;
    reg [1:0] tx_div;
    reg [1:0] wcnt;
    reg [7:0] shreg;
    reg [3:0] bits_left;
    reg [2:0] tones;

    assign tx_busy = (tstate != T_IDLE);
    wire txtick = (tx_div == 2'd3);

    always @(posedge clk) begin
        tx_next <= 1'b0;
        if (rst) begin
            tstate <= T_IDLE;
            oe     <= 1'b0;
            dp_o   <= 1'b1;
            dn_o   <= 1'b0;
            tx_div <= 2'd0;
        end else if (tstate == T_IDLE) begin
            tx_div <= 2'd0;
            if (tx_start) begin
                tstate <= T_WAIT;
                wcnt   <= 2'd2;
            end
        end else begin
            tx_div <= tx_div + 2'd1;
            if (txtick) begin
                case (tstate)
                    T_WAIT: begin
                        if (wcnt == 2'd0) begin
                            oe        <= 1'b1;
                            dp_o      <= 1'b1;
                            dn_o      <= 1'b0;
                            shreg     <= 8'h80;      // SYNC (LSB first: 0000_0001)
                            bits_left <= 4'd8;
                            tones     <= 3'd0;
                            tstate    <= T_BITS;
                        end else begin
                            wcnt <= wcnt - 2'd1;
                        end
                    end

                    T_BITS: begin
                        if (tones == 3'd6) begin             // stuff a zero
                            dp_o  <= ~dp_o;
                            dn_o  <= ~dn_o;
                            tones <= 3'd0;
                        end else if (bits_left == 4'd0) begin // need next byte
                            if (tx_valid) begin
                                shreg     <= {1'b0, tx_data[7:1]};
                                bits_left <= 4'd7;
                                tx_next   <= 1'b1;
                                if (!tx_data[0]) begin
                                    dp_o  <= ~dp_o;
                                    dn_o  <= ~dn_o;
                                    tones <= 3'd0;
                                end else begin
                                    tones <= tones + 3'd1;
                                end
                            end else begin
                                dp_o   <= 1'b0;              // SE0
                                dn_o   <= 1'b0;
                                tstate <= T_SE0A;
                            end
                        end else begin
                            shreg     <= {1'b0, shreg[7:1]};
                            bits_left <= bits_left - 4'd1;
                            if (!shreg[0]) begin
                                dp_o  <= ~dp_o;
                                dn_o  <= ~dn_o;
                                tones <= 3'd0;
                            end else begin
                                tones <= tones + 3'd1;
                            end
                        end
                    end

                    T_SE0A: tstate <= T_SE0B;

                    T_SE0B: begin
                        dp_o   <= 1'b1;                      // J
                        dn_o   <= 1'b0;
                        tstate <= T_JEND;
                    end

                    default: begin                           // T_JEND
                        oe     <= 1'b0;
                        tstate <= T_IDLE;
                    end
                endcase
            end
        end
    end

endmodule
