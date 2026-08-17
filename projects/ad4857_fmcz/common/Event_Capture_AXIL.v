// ***************************************************************************
// ***************************************************************************
// Copyright (C) 2014-2025 Analog Devices, Inc. All rights reserved.
// ***************************************************************************
// ***************************************************************************

`timescale 1ns/100ps

module Event_Capture_AXIL #(
    parameter DW          = 16,
    parameter DEPTH       = 16384,
    parameter PRE_TRIGGER = 512
)(
    input                   s_axi_aclk,
    input                   s_axi_aresetn,
    input                   s_axi_awvalid,
    input  [15:0]           s_axi_awaddr,
    output                  s_axi_awready,
    input                   s_axi_wvalid,
    input  [31:0]           s_axi_wdata,
    input  [3:0]            s_axi_wstrb,
    output                  s_axi_wready,
    output                  s_axi_bvalid,
    output [1:0]            s_axi_bresp,
    input                   s_axi_bready,
    input                   s_axi_arvalid,
    input  [15:0]           s_axi_araddr,
    output                  s_axi_arready,
    output                  s_axi_rvalid,
    output [31:0]           s_axi_rdata,
    output [1:0]            s_axi_rresp,
    input                   s_axi_rready,

    // Configuration Registers
    output reg signed [31:0] reg_threshold,
    output reg        [31:0] reg_pdt,
    output reg        [31:0] reg_hdt,
    output reg        [31:0] reg_hlt,
    output reg        [31:0] reg_pretrig,

    // Feature Readback Registers (from FSM)
    input             [31:0] reg_peak_val,
    input             [31:0] reg_peak_time,
    input             [47:0] reg_energy_acc,
    input             [31:0] reg_hit_dur,
    input             [31:0] reg_hit_cnt,
    input             [31:0] reg_rise_time
);

    // Initial Defaults (1966 LSB = 150.0 mV)
    initial begin
        reg_threshold = 1966;
        reg_pdt       = 128;
        reg_hdt       = 256;
        reg_hlt       = 500;
        reg_pretrig   = PRE_TRIGGER;
    end

    //----------------------------------------------------------------------
    // AXI-Lite Write
    //----------------------------------------------------------------------
    assign s_axi_awready = !axi_bvalid;
    assign s_axi_wready  = !axi_bvalid;
    assign s_axi_bresp   = 2'b00; // OKAY

    reg axi_bvalid;
    assign s_axi_bvalid = axi_bvalid;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            axi_bvalid <= 1'b0;
        end else begin
            if (s_axi_awvalid && s_axi_wvalid && !axi_bvalid) begin
                case (s_axi_awaddr[7:0])
                    8'h00: reg_threshold <= s_axi_wdata;
                    8'h04: reg_pdt       <= s_axi_wdata;
                    8'h08: reg_hdt       <= s_axi_wdata;
                    8'h0C: reg_hlt       <= s_axi_wdata;
                    8'h24: reg_pretrig   <= (s_axi_wdata > (DEPTH - 1)) ? (DEPTH - 1) : s_axi_wdata;
                endcase
                axi_bvalid <= 1'b1;
            end else if (s_axi_bready && axi_bvalid) begin
                axi_bvalid <= 1'b0;
            end
        end
    end

    //----------------------------------------------------------------------
    // AXI-Lite Read
    // Address Map:
    //   0x00  reg_threshold   (R/W)
    //   0x04  reg_pdt         (R/W)
    //   0x08  reg_hdt         (R/W)
    //   0x0C  reg_hlt         (R/W)
    //   0x10  reg_peak_val    (R)  Absolute peak amplitude
    //   0x14  reg_peak_time   (R)  Sample index of peak from trigger
    //   0x18  reg_hit_dur     (R)  Hit duration in samples
    //   0x1C  reg_hit_cnt     (R)  Positive AE threshold crossing count
    //   0x20  reg_rise_time   (R)  Rise time: first pos. crossing -> peak (samples)
    //   0x24  reg_pretrig     (R/W) Pre-trigger sample count (0 .. DEPTH-1)
    //   0x28  reg_energy_acc[31:0]  (R) Energy Accumulation LSB
    //   0x2C  reg_energy_acc[47:32] (R) Energy Accumulation MSB
    //----------------------------------------------------------------------
    reg axi_arready;
    reg axi_rvalid;
    reg [31:0] axi_rdata;

    assign s_axi_arready = axi_arready;
    assign s_axi_rvalid  = axi_rvalid;
    assign s_axi_rdata   = axi_rdata;
    assign s_axi_rresp   = 2'b00; // OKAY

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            axi_arready <= 1'b0;
            axi_rvalid  <= 1'b0;
            axi_rdata   <= 0;
        end else begin
            if (s_axi_arvalid && !axi_arready && !axi_rvalid) begin
                axi_arready <= 1'b1;
            end else begin
                axi_arready <= 1'b0;
            end

            if (axi_arready && s_axi_arvalid) begin
                axi_rvalid <= 1'b1;
                case (s_axi_araddr[7:0])
                    8'h00: axi_rdata <= reg_threshold;
                    8'h04: axi_rdata <= reg_pdt;
                    8'h08: axi_rdata <= reg_hdt;
                    8'h0C: axi_rdata <= reg_hlt;
                    8'h10: axi_rdata <= reg_peak_val;
                    8'h14: axi_rdata <= reg_peak_time;
                    8'h18: axi_rdata <= reg_hit_dur;
                    8'h1C: axi_rdata <= reg_hit_cnt;
                    8'h20: axi_rdata <= reg_rise_time;
                    8'h24: axi_rdata <= reg_pretrig;
                    8'h28: axi_rdata <= reg_energy_acc[31:0];
                    8'h2C: axi_rdata <= {16'h0, reg_energy_acc[47:32]};
                    default: axi_rdata <= 32'hDEADBEEF;
                endcase
            end else if (s_axi_rready && axi_rvalid) begin
                axi_rvalid <= 1'b0;
            end
        end
    end
endmodule
