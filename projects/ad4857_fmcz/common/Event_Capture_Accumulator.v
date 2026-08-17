// ***************************************************************************
// ***************************************************************************
// Copyright (C) 2014-2025 Analog Devices, Inc. All rights reserved.
// ***************************************************************************
// ***************************************************************************

`timescale 1ns/100ps

module Event_Capture_Accumulator #(
    parameter DW = 16
)(
    input                   clk,
    input                   rst,

    // Control Inputs from FSM
    input                   accum_init,
    input                   accum_en,

    // Data & Detector Inputs
    input  signed [DW-1:0]  s_axis_tdata,
    input                   pos_threshold_rising,
    input  signed [31:0]    reg_threshold,
    input         [31:0]    reg_pdt,

    // Feature Readback Outputs
    output reg [31:0]       peak_val,
    output reg [31:0]       peak_time,
    output reg [47:0]       energy_acc,
    output reg [31:0]       hit_cnt,
    output reg [31:0]       hit_dur,
    output     [31:0]       rise_time
);

    wire signed [DW-1:0] threshold = reg_threshold[DW-1:0];
    wire [DW-1:0]        abs_data  = s_axis_tdata[DW-1] ? -$signed(s_axis_tdata) : s_axis_tdata;

    reg [31:0] pdt_counter;
    reg [31:0] first_cross_index;
    reg        first_cross_seen;

    assign rise_time = (first_cross_seen && (peak_time >= first_cross_index)) ? (peak_time - first_cross_index) : 32'h0;

    always @(posedge clk) begin
        if (rst) begin
            peak_val          <= 32'h0;
            peak_time         <= 32'h0;
            energy_acc        <= 48'h0;
            hit_cnt           <= 32'h0;
            hit_dur           <= 32'h0;
            pdt_counter       <= 32'h0;
            first_cross_index <= 32'h0;
            first_cross_seen  <= 1'b0;
        end else if (accum_init) begin
            peak_val          <= {{(32-DW){1'b0}}, abs_data};
            peak_time         <= 32'h0;
            energy_acc        <= s_axis_tdata * s_axis_tdata;
            hit_cnt           <= pos_threshold_rising ? 32'd1 : 32'd0;
            hit_dur           <= 32'd1;
            pdt_counter       <= 32'd1;
            first_cross_index <= 32'h0;
            first_cross_seen  <= (s_axis_tdata >= threshold);
        end else if (accum_en) begin
            hit_dur     <= hit_dur + 1'b1;
            pdt_counter <= (pdt_counter == 32'hFFFFFFFF) ? pdt_counter
                                                          : pdt_counter + 1'b1;

            // --- Peak Detection (within PDT window) ---
            if (pdt_counter < reg_pdt) begin
                if (abs_data > peak_val[DW-1:0]) begin
                    peak_val  <= {{(32-DW){1'b0}}, abs_data};
                    peak_time <= hit_dur;
                end
            end

            // --- Energy Accumulation ---
            energy_acc <= energy_acc + (s_axis_tdata * s_axis_tdata);

            // --- AE Count & First Positive Crossing ---
            if (pos_threshold_rising) begin
                hit_cnt <= hit_cnt + 1'b1;
                if (!first_cross_seen) begin
                    first_cross_index <= hit_dur;
                    first_cross_seen  <= 1'b1;
                end
            end
        end
    end

endmodule
