// ***************************************************************************
// ***************************************************************************
// Copyright (C) 2014-2025 Analog Devices, Inc. All rights reserved.
// ***************************************************************************
// ***************************************************************************

`timescale 1ns/100ps

module Event_Capture_Detector #(
    parameter DW = 16
)(
    input                  clk,
    input                  rst,

    input                  s_axis_tvalid,
    input  signed [DW-1:0] s_axis_tdata,
    input  signed [31:0]   reg_threshold,

    output                 over_threshold,
    output                 sample_over_threshold,
    output                 trigger_event,
    output                 pos_threshold_rising
);

    wire signed [DW-1:0] threshold = reg_threshold[DW-1:0];

    reg over_threshold_q;
    reg over_pos_threshold_q;

    assign sample_over_threshold = (s_axis_tdata >= threshold) || (s_axis_tdata <= -threshold);

    // Threshold Detection — Pipelined for Timing (200 MHz)
    always @(posedge clk) begin
        if (rst) begin
            over_threshold_q     <= 1'b0;
            over_pos_threshold_q <= 1'b0;
        end else if (s_axis_tvalid) begin
            over_threshold_q     <= (s_axis_tdata >= threshold) || (s_axis_tdata <= -threshold);
            over_pos_threshold_q <= (s_axis_tdata >= threshold);
        end
    end

    // Absolute rising edge — used to start a hit in WAIT_TRIGGER
    assign trigger_event = s_axis_tvalid && !over_threshold_q &&
                           ((s_axis_tdata >= threshold) || (s_axis_tdata <= -threshold));

    // Positive-only rising edge — used for AE count and rise time
    assign pos_threshold_rising = s_axis_tvalid && !over_pos_threshold_q &&
                                  (s_axis_tdata >= threshold);

    assign over_threshold = over_threshold_q;

endmodule