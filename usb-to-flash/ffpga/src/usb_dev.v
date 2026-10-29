// USB Full-Speed device SIE + endpoints.
//   EP0 : control (GET_DESCRIPTOR, SET_ADDRESS, SET_CONFIGURATION, ...), max packet 64
//   EP1 : vendor bulk OUT/IN, max packet 32: command on OUT, 2-byte response {opcode, status} on IN

module usb_dev (
    input  wire       clk,
    input  wire       rst,

    // PHY interface
    input  wire       rx_sop,
    input  wire       rx_bit_v,
    input  wire       rx_bit,
    input  wire       rx_eop,
    input  wire       rx_err,
    input  wire       bus_reset,
    output reg        tx_start,
    output wire [7:0] tx_data,
    output wire       tx_valid,
    input  wire       tx_next,

    // LED command outputs
    output reg        led_set,
    output reg        led_off,
    output reg [15:0] led_ms
);

    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------
    localparam [7:0] PID_ACK = 8'hD2, PID_NAK = 8'h5A, PID_STALL = 8'h1E,
                     PID_DATA0 = 8'hC3, PID_DATA1 = 8'h4B;

    localparam [2:0] P_IDLE = 3'd0, P_DATA_IN = 3'd1, P_STAT_IN = 3'd2,
                     P_STAT_OUT = 3'd3, P_STALL = 3'd4;

    localparam [1:0] E_NONE = 2'd0, E_SETUP = 2'd1, E_OUT0 = 2'd2, E_OUT1 = 2'd3;

    localparam [1:0] S_ROM = 2'd0, S_ZERO = 2'd1, S_CFG = 2'd2, S_RESP = 2'd3;

    // EP1 command protocol (host -> device, bulk OUT), response on bulk IN: {opcode, status}
    //   0x01 LED_SET  <ms_lo> <ms_hi>  : LED on for ms (1..65534); 0xFFFF = on forever; 0 = off
    //   0x02 LED_OFF                   : LED off
    // status: 0 = OK, 1 = bad length, 2 = unknown opcode
    localparam [7:0] OP_LED_SET = 8'h01, OP_LED_OFF = 8'h02;

    // ------------------------------------------------------------------
    // Descriptor ROM: device (0..17), configuration (18..49)
    // ------------------------------------------------------------------
    function [7:0] rom;
        input [5:0] a;
        begin
            case (a)
                // device descriptor
                6'd0:  rom = 8'h12; 6'd1:  rom = 8'h01; 6'd2:  rom = 8'h00; 6'd3:  rom = 8'h02;
                6'd4:  rom = 8'h00; 6'd5:  rom = 8'h00; 6'd6:  rom = 8'h00; 6'd7:  rom = 8'h40;
                6'd8:  rom = 8'h09; 6'd9:  rom = 8'h12;               // VID 0x1209
                6'd10: rom = 8'h01; 6'd11: rom = 8'h00;               // PID 0x0001 (test PID)
                6'd12: rom = 8'h00; 6'd13: rom = 8'h01;               // bcdDevice 1.00
                6'd14: rom = 8'h00; 6'd15: rom = 8'h00; 6'd16: rom = 8'h00; 6'd17: rom = 8'h01;
                // configuration descriptor
                6'd18: rom = 8'h09; 6'd19: rom = 8'h02; 6'd20: rom = 8'h20; 6'd21: rom = 8'h00;
                6'd22: rom = 8'h01; 6'd23: rom = 8'h01; 6'd24: rom = 8'h00; 6'd25: rom = 8'h80;
                6'd26: rom = 8'h32;
                // interface descriptor
                6'd27: rom = 8'h09; 6'd28: rom = 8'h04; 6'd29: rom = 8'h00; 6'd30: rom = 8'h00;
                6'd31: rom = 8'h02; 6'd32: rom = 8'hFF; 6'd33: rom = 8'h00; 6'd34: rom = 8'h00;
                6'd35: rom = 8'h00;
                // endpoint 1 OUT, bulk, 32 bytes
                6'd36: rom = 8'h07; 6'd37: rom = 8'h05; 6'd38: rom = 8'h01; 6'd39: rom = 8'h02;
                6'd40: rom = 8'h20; 6'd41: rom = 8'h00; 6'd42: rom = 8'h00;
                // endpoint 1 IN, bulk, 32 bytes
                6'd43: rom = 8'h07; 6'd44: rom = 8'h05; 6'd45: rom = 8'h81; 6'd46: rom = 8'h02;
                6'd47: rom = 8'h20; 6'd48: rom = 8'h00; 6'd49: rom = 8'h00;
                default: rom = 8'h00;
            endcase
        end
    endfunction

    function [15:0] crc16_b;
        input [15:0] c;
        input [7:0]  d;
        integer i;
        reg [15:0] r;
        reg        fb;
        begin
            r = c;
            for (i = 0; i < 8; i = i + 1) begin
                fb = r[15] ^ d[i];
                r  = {r[14:0], 1'b0};
                if (fb) r = r ^ 16'h8005;
            end
            crc16_b = r;
        end
    endfunction

    // ------------------------------------------------------------------
    // RX byte assembly + CRCs
    // ------------------------------------------------------------------
    reg [7:0]  rsh;
    reg [2:0]  rbc;
    reg [5:0]  ridx;          // completed bytes in current packet
    reg        byte_v;
    reg [7:0]  byte_d;
    reg [5:0]  byte_i;        // index of byte_d
    reg [15:0] crc16;
    reg [4:0]  crc5;

    always @(posedge clk) begin
        byte_v <= 1'b0;
        if (rx_sop) begin
            rbc   <= 3'd0;
            ridx  <= 6'd0;
            crc16 <= 16'hFFFF;
            crc5  <= 5'h1F;
        end else if (rx_bit_v) begin
            rsh <= {rx_bit, rsh[7:1]};
            rbc <= rbc + 3'd1;
            if (rbc == 3'd7) begin
                byte_v <= 1'b1;
                byte_d <= {rx_bit, rsh[7:1]};
                byte_i <= ridx;
                if (ridx != 6'd63) ridx <= ridx + 6'd1;
            end
            if (ridx != 6'd0) begin
                crc16 <= {crc16[14:0], 1'b0} ^ ((crc16[15] ^ rx_bit) ? 16'h8005 : 16'h0000);
                crc5  <= {crc5[3:0], 1'b0}   ^ ((crc5[4]   ^ rx_bit) ? 5'h05    : 5'h00);
            end
        end
    end

    // ------------------------------------------------------------------
    // Device state
    // ------------------------------------------------------------------
    reg [7:0] pid;
    reg [7:0] tb1, tb2;
    reg [7:0] s_type, s_req, s_vall, s_valh, s_lenl, s_lenh;

    reg [6:0] dev_addr, pend_addr;
    reg       cfg;
    reg [1:0] expect_;
    reg [2:0] ph;
    reg       wait_ack, ack_ep;

    reg [1:0] e0src;
    reg [5:0] e0base, e0len;

    // EP1: ep1_full = a 2-byte response {resp_op, resp_st} is waiting for the host
    reg       ep1_full, ep1_in_tog, ep1_out_tog;
    reg [7:0] c_op, c_l, c_h;          // command bytes of the packet being received
    reg [7:0] resp_op, resp_st;

    // TX packet description
    reg [7:0]  tx_pid;
    reg        tx_has;
    reg [1:0]  tx_src;
    reg [5:0]  tx_base;
    reg [6:0]  tx_len;
    reg [6:0]  tx_idx;
    reg [15:0] tx_crc;

    wire [6:0] tx_total = tx_has ? (tx_len + 7'd3) : 7'd1;
    assign tx_valid = (tx_idx < tx_total);

    wire [5:0] daddr = tx_base + tx_idx[5:0] - 6'd1;

    reg [7:0] dbyte;
    always @* begin
        case (tx_src)
            S_ROM:   dbyte = rom(daddr);
            S_CFG:   dbyte = {7'd0, cfg};
            S_RESP:  dbyte = (tx_idx == 7'd1) ? resp_op : resp_st;
            default: dbyte = 8'h00;
        endcase
    end

    reg [7:0] txd;
    always @* begin
        if (tx_idx == 7'd0)                 txd = tx_pid;
        else if (tx_idx <= tx_len)          txd = dbyte;
        else if (tx_idx == tx_len + 7'd1)   txd = ~{tx_crc[8], tx_crc[9],  tx_crc[10], tx_crc[11],
                                                    tx_crc[12], tx_crc[13], tx_crc[14], tx_crc[15]};
        else                                txd = ~{tx_crc[0], tx_crc[1], tx_crc[2], tx_crc[3],
                                                    tx_crc[4], tx_crc[5], tx_crc[6], tx_crc[7]};
    end
    assign tx_data = txd;

    // ------------------------------------------------------------------
    // Transaction handling
    // ------------------------------------------------------------------
    wire pid_ok     = (pid[7:4] == ~pid[3:0]);
    wire adr_ok     = (tb1[6:0] == dev_addr);
    wire [3:0] tep  = {tb2[2:0], tb1[7]};
    wire crc5_ok    = (crc5  == 5'b01100);
    wire crc16_ok   = (crc16 == 16'h800D);

    reg        go;
    reg [7:0]  rpid;
    reg        rhas;
    reg [1:0]  rsrc;
    reg [5:0]  rbase;
    reg [5:0]  rlen;
    reg [5:0]  dl;
    reg        sreq_in;

    // Pipeline stage A (on rx_eop): register all packet checks.
    // Stage B (eop_q): transaction decision. Stage C (go_q): load TX registers.
    reg        eop_q;
    reg        f_valid, f_tok, f_setup, f_data3, f_ack;
    reg        go_q, rhas_q;
    reg [7:0]  rpid_q;
    reg [1:0]  rsrc_q;
    reg [5:0]  rbase_q, rlen_q;

    always @(posedge clk) begin
        eop_q   <= rx_eop;
        f_valid <= !rx_err && pid_ok;
        f_tok   <= (ridx == 6'd3) && crc5_ok && adr_ok;
        f_setup <= crc16_ok && (ridx == 6'd11) && (pid[3:0] == 4'h3);
        f_data3 <= crc16_ok && (ridx >= 6'd3);
        f_ack   <= (ridx == 6'd1);
    end

    always @(posedge clk) begin
        tx_start <= 1'b0;
        go = 1'b0;
        led_set <= 1'b0;
        led_off <= 1'b0;

        // capture header bytes
        if (byte_v) begin
            case (byte_i)
                6'd0: pid <= byte_d;
                6'd1: begin tb1 <= byte_d; c_op <= byte_d; if (expect_ == E_SETUP) s_type <= byte_d; end
                6'd2: begin tb2 <= byte_d; c_l  <= byte_d; if (expect_ == E_SETUP) s_req  <= byte_d; end
                6'd3: begin c_h <= byte_d; if (expect_ == E_SETUP) s_vall <= byte_d; end
                6'd4: if (expect_ == E_SETUP) s_valh <= byte_d;
                6'd7: if (expect_ == E_SETUP) s_lenl <= byte_d;
                6'd8: if (expect_ == E_SETUP) s_lenh <= byte_d;
                default: ;
            endcase
        end

        if (rst || bus_reset) begin
            dev_addr    <= 7'd0;
            pend_addr   <= 7'd0;
            cfg         <= 1'b0;
            expect_     <= E_NONE;
            ph          <= P_IDLE;
            wait_ack    <= 1'b0;
            ep1_full    <= 1'b0;
            ep1_in_tog  <= 1'b0;
            ep1_out_tog <= 1'b0;
            tx_idx      <= 7'd1;
            tx_has      <= 1'b0;
            tx_len      <= 7'd0;
        end else begin
            if (eop_q && f_valid) begin
                case (pid[3:0])
                    // ---------------- tokens ----------------
                    4'h1, 4'h9, 4'hD: begin
                        if (f_tok) begin
                            wait_ack <= 1'b0;
                            expect_  <= E_NONE;
                            case (pid[3:0])
                                4'hD: if (tep == 4'd0) expect_ <= E_SETUP;
                                4'h1: begin
                                    if (tep == 4'd0)      expect_ <= E_OUT0;
                                    else if (tep == 4'd1) expect_ <= E_OUT1;
                                end
                                default: begin            // IN
                                    if (tep == 4'd0) begin
                                        case (ph)
                                            P_DATA_IN: begin
                                                go = 1'b1; rpid = PID_DATA1; rhas = 1'b1;
                                                rsrc = e0src; rbase = e0base; rlen = e0len;
                                                wait_ack <= 1'b1; ack_ep <= 1'b0;
                                            end
                                            P_STAT_IN: begin
                                                go = 1'b1; rpid = PID_DATA1; rhas = 1'b1;
                                                rsrc = S_ZERO; rbase = 6'd0; rlen = 6'd0;
                                                wait_ack <= 1'b1; ack_ep <= 1'b0;
                                            end
                                            P_STALL: begin
                                                go = 1'b1; rpid = PID_STALL; rhas = 1'b0;
                                                rsrc = S_ZERO; rbase = 6'd0; rlen = 6'd0;
                                            end
                                            default: begin
                                                go = 1'b1; rpid = PID_NAK; rhas = 1'b0;
                                                rsrc = S_ZERO; rbase = 6'd0; rlen = 6'd0;
                                            end
                                        endcase
                                    end else if (tep == 4'd1) begin
                                        if (ep1_full && cfg) begin
                                            go = 1'b1; rpid = ep1_in_tog ? PID_DATA1 : PID_DATA0;
                                            rhas = 1'b1; rsrc = S_RESP; rbase = 6'd0; rlen = 6'd2;
                                            wait_ack <= 1'b1; ack_ep <= 1'b1;
                                        end else begin
                                            go = 1'b1; rpid = PID_NAK; rhas = 1'b0;
                                            rsrc = S_ZERO; rbase = 6'd0; rlen = 6'd0;
                                        end
                                    end
                                end
                            endcase
                        end
                    end

                    // ---------------- data packets ----------------
                    4'h3, 4'hB: begin
                        expect_ <= E_NONE;
                        case (expect_)
                            E_SETUP: begin
                                if (f_setup) begin
                                    go = 1'b1; rpid = PID_ACK; rhas = 1'b0;
                                    rsrc = S_ZERO; rbase = 6'd0; rlen = 6'd0;
                                    sreq_in = s_type[7];
                                    ph     <= P_STALL;
                                    e0src  <= S_ZERO;
                                    e0base <= 6'd0;
                                    e0len  <= 6'd0;
                                    dl = 6'd0;
                                    case (s_req)
                                        8'h06: begin                       // GET_DESCRIPTOR
                                            if (sreq_in && s_valh == 8'd1) begin
                                                dl = 6'd18; e0src <= S_ROM; e0base <= 6'd0;
                                                ph <= P_DATA_IN;
                                            end else if (sreq_in && s_valh == 8'd2) begin
                                                dl = 6'd32; e0src <= S_ROM; e0base <= 6'd18;
                                                ph <= P_DATA_IN;
                                            end
                                        end
                                        8'h00: if (sreq_in) begin          // GET_STATUS
                                            dl = 6'd2; e0src <= S_ZERO; ph <= P_DATA_IN;
                                        end
                                        8'h08: if (sreq_in) begin          // GET_CONFIGURATION
                                            dl = 6'd1; e0src <= S_CFG; ph <= P_DATA_IN;
                                        end
                                        8'h0A: if (sreq_in) begin          // GET_INTERFACE
                                            dl = 6'd1; e0src <= S_ZERO; ph <= P_DATA_IN;
                                        end
                                        8'h05: if (!sreq_in) begin         // SET_ADDRESS
                                            pend_addr <= s_vall[6:0]; ph <= P_STAT_IN;
                                        end
                                        8'h09: if (!sreq_in) begin         // SET_CONFIGURATION
                                            cfg         <= s_vall[0];
                                            ep1_full    <= 1'b0;
                                            ep1_in_tog  <= 1'b0;
                                            ep1_out_tog <= 1'b0;
                                            ph          <= P_STAT_IN;
                                        end
                                        8'h01, 8'h03, 8'h0B: if (!sreq_in) begin // CLEAR/SET_FEATURE, SET_INTERFACE
                                            ph <= P_STAT_IN;
                                        end
                                        default: ;
                                    endcase
                                    if (dl != 6'd0) begin
                                        if (s_lenh != 8'd0 || s_lenl > {2'b00, dl}) e0len <= dl;
                                        else                                         e0len <= s_lenl[5:0];
                                        if (s_lenh == 8'd0 && s_lenl == 8'd0) ph <= P_STAT_IN;
                                    end
                                end
                            end

                            E_OUT0: begin
                                if (f_data3) begin
                                    go = 1'b1; rhas = 1'b0; rsrc = S_ZERO; rbase = 6'd0; rlen = 6'd0;
                                    if (ph == P_STALL) begin
                                        rpid = PID_STALL;
                                    end else begin
                                        rpid = PID_ACK;
                                        if (ph == P_DATA_IN || ph == P_STAT_OUT) ph <= P_IDLE;
                                    end
                                end
                            end

                            E_OUT1: begin
                                if (f_data3 && cfg) begin
                                    go = 1'b1; rhas = 1'b0; rsrc = S_ZERO; rbase = 6'd0; rlen = 6'd0;
                                    if (pid[3] != ep1_out_tog) begin
                                        rpid = PID_ACK;               // duplicate, drop
                                    end else begin
                                        rpid        = PID_ACK;
                                        ep1_out_tog <= ~ep1_out_tog;
                                        ep1_full    <= 1'b1;         // response ready (replaces any unread one)
                                        resp_op     <= c_op;
                                        resp_st     <= 8'd2;         // unknown opcode
                                        if (ridx == 6'd3) resp_st <= 8'd1;   // empty packet
                                        else begin
                                            case (c_op)
                                                OP_LED_SET: begin
                                                    if (ridx == 6'd6) begin
                                                        resp_st <= 8'd0;
                                                        led_set <= 1'b1;
                                                        led_ms  <= {c_h, c_l};
                                                    end else begin
                                                        resp_st <= 8'd1;
                                                    end
                                                end
                                                OP_LED_OFF: begin
                                                    if (ridx == 6'd4) begin
                                                        resp_st <= 8'd0;
                                                        led_off <= 1'b1;
                                                    end else begin
                                                        resp_st <= 8'd1;
                                                    end
                                                end
                                                default: ;
                                            endcase
                                        end
                                    end
                                end
                            end

                            default: ;
                        endcase
                    end

                    // ---------------- handshake ACK ----------------
                    4'h2: begin
                        if (wait_ack && f_ack) begin
                            wait_ack <= 1'b0;
                            if (!ack_ep) begin
                                if (ph == P_DATA_IN) begin
                                    ph <= P_STAT_OUT;
                                end else if (ph == P_STAT_IN) begin
                                    dev_addr <= pend_addr;
                                    ph       <= P_IDLE;
                                end
                            end else begin
                                ep1_full   <= 1'b0;
                                ep1_in_tog <= ~ep1_in_tog;
                            end
                        end
                    end

                    default: ;
                endcase
            end

            // ---------------- TX bookkeeping ----------------
            if (go_q) begin
                tx_pid  <= rpid_q;
                tx_has  <= rhas_q;
                tx_src  <= rsrc_q;
                tx_base <= rbase_q;
                tx_len  <= {1'b0, rlen_q};
                tx_idx  <= 7'd0;
                tx_crc  <= 16'hFFFF;
                tx_start <= 1'b1;
            end else if (tx_next) begin
                if (tx_idx >= 7'd1 && tx_idx <= tx_len) tx_crc <= crc16_b(tx_crc, txd);
                tx_idx <= tx_idx + 7'd1;
            end
        end

        go_q    <= go && !(rst || bus_reset);
        rpid_q  <= rpid;
        rhas_q  <= rhas;
        rsrc_q  <= rsrc;
        rbase_q <= rbase;
        rlen_q  <= rlen;
    end

endmodule
