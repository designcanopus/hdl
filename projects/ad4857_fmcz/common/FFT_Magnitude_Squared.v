// ***************************************************************************
// ***************************************************************************
// Copyright (C) 2025 Analog Devices, Inc. All rights reserved.
// ***************************************************************************
// ***************************************************************************
//
// FFT_Magnitude_Squared.v
// ========================
// Registered pipeline module.
// Extracts the real and imaginary parts from the Xilinx xfft IP output,
// computes magnitude-squared (mag_sq = Re*Re + Im*Im), and registers all
// outputs to eliminate setup timing violations.
// ***************************************************************************

`timescale 1ns/100ps

module FFT_Magnitude_Squared #(
    parameter DATA_W = 16
)(
    input                  clk,
    input                  rst,
    input  [2*DATA_W-1:0]  tdata,
    input                  tvalid_in,
    input                  tlast_in,

    output reg [47:0]      mag_sq,
    output reg             tvalid_out,
    output reg             tlast_out
);

    wire signed [DATA_W-1:0]   re = tdata[DATA_W-1 : 0];
    wire signed [DATA_W-1:0]   im = tdata[2*DATA_W-1 : DATA_W];

    wire [DATA_W-1:0] re_abs = re[DATA_W-1] ? (~re + 1'b1) : re;
    wire [DATA_W-1:0] im_abs = im[DATA_W-1] ? (~im + 1'b1) : im;

    wire [2*DATA_W-1:0] re_sq = re_abs * re_abs;   // unsigned, always positive
    wire [2*DATA_W-1:0] im_sq = im_abs * im_abs;   // unsigned, always positive

    wire [2*DATA_W:0] sum_sq = {1'b0, re_sq} + {1'b0, im_sq};

    always @(posedge clk) begin
        if (rst) begin
            mag_sq     <= 48'd0;
            tvalid_out <= 1'b0;
            tlast_out  <= 1'b0;
        end else begin
            mag_sq     <= {{(47 - 2*DATA_W){1'b0}}, sum_sq};
            tvalid_out <= tvalid_in;
            tlast_out  <= tlast_in;
        end
    end

endmodule
