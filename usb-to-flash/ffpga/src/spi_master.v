// Minimal SPI master, mode 0 (CPOL=0, CPHA=0), 8-bit frames, MSB first.
// Single clock edge, no async reset. CS# is not handled here: the host
// controls it explicitly, so USB latency provides all CS setup/hold time.
//   SCK = clk / (2 * div), div = 1..15
//   MOSI changes on falling SCK, MISO is sampled on rising SCK.

module spi_master (
    input  wire       clk,
    input  wire       rst,
    input  wire       start,      // pulse: shift out tx_data (ignored while busy)
    input  wire [7:0] tx_data,
    input  wire [3:0] div,
    input  wire       miso,
    output reg        sck,
    output reg        mosi,
    output reg        busy,
    output reg        done,       // pulse: rx_data valid
    output wire [7:0] rx_data
);

    reg [7:0] sh;                 // TX bits leave from the top, RX bits enter at the bottom
    reg [3:0] cnt;                // half-period counter
    reg [2:0] bitn;               // rising edges seen
    reg       miso_s;

    assign rx_data = sh;

    wire half = (cnt == div - 4'd1);

    always @(posedge clk) begin
        miso_s <= miso;
        done   <= 1'b0;
        if (rst) begin
            busy <= 1'b0;
            sck  <= 1'b0;
            mosi <= 1'b0;
        end else if (!busy) begin
            if (start) begin
                busy <= 1'b1;
                sh   <= tx_data;
                mosi <= tx_data[7];
                cnt  <= 4'd0;
                bitn <= 3'd0;
            end
        end else if (half) begin
            cnt <= 4'd0;
            sck <= ~sck;
            if (!sck) begin                       // rising edge: sample
                sh   <= {sh[6:0], miso_s};
                bitn <= bitn + 3'd1;
            end else if (bitn == 3'd0) begin      // falling edge after 8th bit
                busy <= 1'b0;
                done <= 1'b1;
                mosi <= 1'b0;
            end else begin                        // falling edge: next bit
                mosi <= sh[7];
            end
        end else begin
            cnt <= cnt + 4'd1;
        end
    end

endmodule
