// ***************************************************************************
// ***************************************************************************
// Copyright (C) 2025 Analog Devices, Inc. All rights reserved.
// ***************************************************************************
// ***************************************************************************
//
// FFT_Peak_Finder.v
// ==================
// Top-level wrapper for FFT peak-detection pipeline.
// ***************************************************************************

`timescale 1ns/100ps

module FFT_Peak_Finder #(
    parameter FFT_N = 4096,
    parameter BIN_W = 12     // log2(FFT_N)
)(
    input           clk,
    input           rst,

    // AXI4-Stream Slave (from Xilinx xfft IP m_axis_data_*)
    // xfft 16-bit scaled output: Re[15:0] @ bits[15:0], Im[15:0] @ bits[31:16] → 32-bit total
    input  [31:0]   s_axis_tdata,
    input           s_axis_tvalid,
    input           s_axis_tlast,
    output          s_axis_tready,

    // AXI4-Stream Master
    output [15:0]   m_axis_tdata,
    output          m_axis_tvalid,
    output          m_axis_tlast,
    input           m_axis_tready,

    // Latched Peak Bin Output (held stable for Event_Capture_FSM header_regs[8])
    output reg [31:0] peak_bin_reg
);

    wire [47:0] mag_sq;
    wire        mag_tvalid;
    wire        mag_tlast;

    FFT_Magnitude_Squared i_mag_sq (
        .clk        ( clk           ),
        .rst        ( rst           ),
        .tdata      ( s_axis_tdata  ),
        .tvalid_in  ( s_axis_tvalid ),
        .tlast_in   ( s_axis_tlast  ),
        .mag_sq     ( mag_sq        ),
        .tvalid_out ( mag_tvalid    ),
        .tlast_out  ( mag_tlast     )
    );

    wire [BIN_W-1:0] peak_bin;
    wire             peak_valid;

    FFT_Peak_Detector #(
        .FFT_N ( FFT_N ),
        .BIN_W ( BIN_W ),
        .MAG_W ( 48    )
    ) i_peak_det (
        .clk           ( clk            ),
        .rst           ( rst            ),
        .s_axis_mag_sq ( mag_sq         ),
        .s_axis_tvalid ( mag_tvalid     ),
        .s_axis_tlast  ( mag_tlast      ),
        .s_axis_tready ( s_axis_tready  ),
        .peak_bin      ( peak_bin       ),
        .peak_valid    ( peak_valid     )
    );

    reg [15:0]  r_tdata;
    reg         r_tvalid;

    assign m_axis_tdata  = r_tdata;
    assign m_axis_tvalid = r_tvalid;
    assign m_axis_tlast  = r_tvalid;

    always @(posedge clk) begin
        if (rst) begin
            r_tdata      <= 16'd0;
            r_tvalid     <= 1'b0;
            peak_bin_reg <= 32'd0;
        end else begin
            if (peak_valid) begin
                peak_bin_reg <= {{(32-BIN_W){1'b0}}, peak_bin};
            end

            if (peak_valid && !r_tvalid) begin
                r_tdata  <= {{(16-BIN_W){1'b0}}, peak_bin};
                r_tvalid <= 1'b1;
            end else if (peak_valid && r_tvalid && m_axis_tready) begin
                r_tdata  <= {{(16-BIN_W){1'b0}}, peak_bin};
                r_tvalid <= 1'b1;
            end else if (r_tvalid && m_axis_tready) begin
                r_tvalid <= 1'b0;
            end
        end
    end

endmodule
