module spi_master #(
    parameter integer CLK_HZ = 48_000_000
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       cs_n_req,
    input  wire [7:0] clk_divider,
    input  wire       start,
    input  wire [7:0] tx_data,
    input  wire       miso,
    output reg        cs_n,
    output reg        sck,
    output reg        mosi,
    output wire       busy,
    output reg        done,
    output reg  [7:0] rx_data
);

    localparam [1:0] IDLE = 2'd0, TRANSFER = 2'd1;
    localparam [63:0] SETUP_CYCLES_CALC =
        ((64'd1 * CLK_HZ * 7) + 64'd999_999_999) / 64'd1_000_000_000;
    localparam [63:0] HOLD_CYCLES_CALC =
        ((64'd1 * CLK_HZ * 5) + 64'd999_999_999) / 64'd1_000_000_000;
    localparam [63:0] HIGH_CYCLES_CALC =
        ((64'd1 * CLK_HZ * 30) + 64'd999_999_999) / 64'd1_000_000_000;
    localparam integer CS_SETUP_CYCLES =
        SETUP_CYCLES_CALC < 1 ? 1 : SETUP_CYCLES_CALC;
    localparam integer CS_HOLD_CYCLES =
        HOLD_CYCLES_CALC < 1 ? 1 : HOLD_CYCLES_CALC;
    localparam integer CS_HIGH_CYCLES =
        HIGH_CYCLES_CALC < 1 ? 1 : HIGH_CYCLES_CALC;

    reg [1:0] state;
    reg [7:0] active_divider;
    reg [7:0] half_count;
    reg [7:0] tx_shift;
    reg [3:0] bit_count;
    reg [31:0] cs_setup_count;
    reg [31:0] cs_hold_count;
    reg [31:0] cs_high_count;
    reg sample_toggle;
    reg sample_seen;
    reg transfer_begin;
    reg pending_start;
    reg [7:0] pending_tx;
    reg [7:0] rx_shift;

    assign busy = (state == TRANSFER);

    always @(negedge clk or posedge rst) begin
        if (rst) begin
            state          <= IDLE;
            cs_n           <= 1'b1;
            sck            <= 1'b0;
            mosi           <= 1'b0;
            done           <= 1'b0;
            active_divider <= 8'd1;
            half_count     <= 8'd0;
            tx_shift       <= 8'd0;
            cs_setup_count <= 32'd0;
            cs_hold_count  <= 32'd0;
            cs_high_count  <= 32'd0;
            sample_toggle  <= 1'b0;
            transfer_begin <= 1'b0;
            pending_start <= 1'b0;
            pending_tx    <= 8'd0;
            rx_data        <= 8'd0;
        end else begin
            done           <= 1'b0;
            transfer_begin <= 1'b0;

            if (state == IDLE) begin
                sck <= 1'b0;

                if (start && !cs_n_req) begin
                    pending_start <= 1'b1;
                    pending_tx    <= tx_data;
                end else if (cs_n_req) begin
                    pending_start <= 1'b0;
                end

                if (cs_hold_count != 32'd0)
                    cs_hold_count <= cs_hold_count - 32'd1;

                if (cs_n) begin
                    if (cs_high_count < CS_HIGH_CYCLES)
                        cs_high_count <= cs_high_count + 32'd1;
                    if (!cs_n_req && cs_high_count >= CS_HIGH_CYCLES) begin
                        cs_n           <= 1'b0;
                        cs_setup_count <= 32'd0;
                    end
                end else begin
                    if (cs_setup_count < CS_SETUP_CYCLES)
                        cs_setup_count <= cs_setup_count + 32'd1;
                    if (cs_n_req && cs_hold_count == 32'd0) begin
                        cs_n          <= 1'b1;
                        cs_high_count <= 32'd0;
                    end
                end

                if ((pending_start || start) && !cs_n && !cs_n_req &&
                    cs_setup_count >= CS_SETUP_CYCLES) begin
                    state          <= TRANSFER;
                    active_divider <= (clk_divider == 8'd0) ? 8'd1 : clk_divider;
                    half_count     <= 8'd0;
                    tx_shift       <= start ? tx_data : pending_tx;
                    mosi           <= start ? tx_data[7] : pending_tx[7];
                    sck            <= 1'b0;
                    cs_hold_count  <= 32'd0;
                    pending_start  <= 1'b0;
                    transfer_begin <= 1'b1;
                end
            end else begin
                if (half_count >= active_divider - 8'd1) begin
                    half_count <= 8'd0;
                    if (!sck) begin
                        sck           <= 1'b1;
                        sample_toggle <= ~sample_toggle;
                    end else begin
                        sck <= 1'b0;
                        if (bit_count == 4'd8) begin
                            state         <= IDLE;
                            done          <= 1'b1;
                            rx_data       <= rx_shift;
                            mosi          <= 1'b0;
                            cs_hold_count <= CS_HOLD_CYCLES;
                        end else begin
                            tx_shift <= {tx_shift[6:0], 1'b0};
                            mosi     <= tx_shift[6];
                        end
                    end
                end else begin
                    half_count <= half_count + 8'd1;
                end
            end
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sample_seen <= 1'b0;
            bit_count   <= 4'd0;
            rx_shift    <= 8'd0;
        end else if (transfer_begin) begin
            sample_seen <= sample_toggle;
            bit_count   <= 4'd0;
            rx_shift    <= 8'd0;
        end else if (sample_toggle != sample_seen) begin
            sample_seen <= sample_toggle;
            bit_count   <= bit_count + 4'd1;
            rx_shift    <= {rx_shift[6:0], miso};
        end
    end

endmodule
