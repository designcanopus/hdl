// ***************************************************************************
// FFT_Peak_Detector.v
// ====================
// Finds the maximum magnitude-squared FFT bin over the positive-frequency
// spectrum.
//
// For FFT_N = 4096:
//     bins searched = 1 ... 2048
//
// bin 0 (DC) is ignored.
// ***************************************************************************

`timescale 1ns/100ps

module FFT_Peak_Detector #(
    parameter FFT_N = 8192,
    parameter BIN_W = 13,
    parameter MAG_W = 48
)(
    input                   clk,
    input                   rst,

    input  [MAG_W-1:0]      s_axis_mag_sq,
    input                   s_axis_tvalid,
    input                   s_axis_tlast,
    output                  s_axis_tready,

    output reg [BIN_W-1:0]  peak_bin,
    output reg              peak_valid
);

    /* Always ready: no backpressure */
    assign s_axis_tready = 1'b1;

    /* Running maximum */
    reg [MAG_W-1:0] max_mag;
    reg [BIN_W-1:0] max_bin;

    /* Current FFT bin */
    reg [BIN_W-1:0] bin_cnt;

    always @(posedge clk) begin

        if (rst) begin

            max_mag    <= {MAG_W{1'b0}};
            max_bin    <= {BIN_W{1'b0}};
            bin_cnt    <= {BIN_W{1'b0}};

            peak_bin   <= {BIN_W{1'b0}};
            peak_valid <= 1'b0;

        end else begin

            /* Default */
            peak_valid <= 1'b0;

            if (s_axis_tvalid) begin

                /*
                 * ---------------------------------------------------------
                 * DC bin
                 * ---------------------------------------------------------
                 *
                 * Ignore bin 0.
                 */
                if (bin_cnt == 0) begin

                    max_mag <= {MAG_W{1'b0}};
                    max_bin <= {BIN_W{1'b0}};

                end

                /*
                 * ---------------------------------------------------------
                 * Positive-frequency bins
                 * ---------------------------------------------------------
                 *
                 * Search bins 1 ... N/2.
                 */
                else if (bin_cnt <= (FFT_N >> 1)) begin

                    if (s_axis_mag_sq > max_mag) begin

                        max_mag <= s_axis_mag_sq;
                        max_bin <= bin_cnt;

                    end

                end

                /*
                 * ---------------------------------------------------------
                 * End of FFT frame
                 * ---------------------------------------------------------
                 */
                if (s_axis_tlast) begin

                    /*
                     * Determine the winner INCLUDING the current sample.
                     *
                     * If current sample is larger than the previous
                     * running maximum, current bin wins.
                     *
                     * Otherwise previous max wins.
                     */
                    if ((bin_cnt >= 1) &&
                        (bin_cnt <= (FFT_N >> 1)) &&
                        (s_axis_mag_sq > max_mag)) begin

                        peak_bin <= bin_cnt;

                    end else begin

                        peak_bin <= max_bin;

                    end

                    peak_valid <= 1'b1;

                    /*
                     * Reset for next FFT frame.
                     */
                    bin_cnt <= {BIN_W{1'b0}};
                    max_mag <= {MAG_W{1'b0}};
                    max_bin <= {BIN_W{1'b0}};

                end else begin

                    bin_cnt <= bin_cnt + 1'b1;

                end

            end

        end

    end

endmodule
