// ***************************************************************************
// ***************************************************************************
// Copyright (C) 2014-2025 Analog Devices, Inc. All rights reserved.
// ***************************************************************************
// ***************************************************************************

`timescale 1ns/100ps

module Event_Capture_Buffer #(
    parameter DW     = 16,
    parameter DEPTH  = 16384,
    parameter ADDR_W = 14
)(
    input                 clk,
    input                 wr_en,
    input  [ADDR_W-1:0]   wr_ptr,
    input  [DW-1:0]       wr_data,

    input  [ADDR_W-1:0]   rd_ptr,
    output [DW-1:0]       rd_data
);

    (* ram_style = "block" *) reg [DW-1:0] mem [0:DEPTH-1];
    reg [DW-1:0] rd_data_reg;

    always @(posedge clk) begin
        if (wr_en) begin
            mem[wr_ptr] <= wr_data;
        end
        rd_data_reg <= mem[rd_ptr];
    end

    assign rd_data = rd_data_reg;

endmodule
