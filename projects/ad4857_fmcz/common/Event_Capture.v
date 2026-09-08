// ***************************************************************************
// ***************************************************************************
// Copyright (C) 2014-2025 Analog Devices, Inc. All rights reserved.
// ***************************************************************************
// ***************************************************************************

`timescale 1ns/100ps

module Event_Capture #(
    parameter DW            = 16,
    parameter DEPTH         = 16384,  // 16384 samples (MUST be power of 2)
    parameter ADDR_W        = 14,     // log2(16384) = 14
    parameter PRE_TRIGGER   = 512
)(
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET s_axi_aresetn" *)
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

    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axis:m_axis, ASSOCIATED_RESET rst" *)
    input                   clk,
    input                   rst,      // Active-high from BD 'adc_reset'

    // AXI4-Stream Slave Interface (Input from ADC)
    input                   s_axis_tvalid,
    input  signed [DW-1:0]  s_axis_tdata,
    output                  s_axis_tready,

    output                  trigger_out,
    output                  capture_done,

    // AXI-4-Stream Master Interface (Output to DMA)
    output [DW-1:0]         m_axis_tdata,
    output                  m_axis_tvalid,
    input                   m_axis_tready,
    output                  m_axis_tlast,

    // FPGA FFT Peak Frequency Bin
    input  [31:0]           fft_peak_bin
);

    // ADC input stream is always ready
    assign s_axis_tready = 1'b1;

    //----------------------------------------------------------------------
    // Internal Wires & Connections
    //----------------------------------------------------------------------
    // Raw outputs from AXIL sub-module (s_axi_aclk domain)
    wire signed [31:0] reg_threshold_raw;
    wire        [31:0] reg_pdt_raw;
    wire        [31:0] reg_hdt_raw;
    wire        [31:0] reg_hlt_raw;
    wire        [31:0] reg_pretrig_raw;

    // 2-FF CDC synchronised config registers (clk domain).
    // Config regs change infrequently; double-FF sync prevents metastability.
    (* ASYNC_REG = "TRUE" *) reg signed [31:0] reg_threshold_s1;
    (* ASYNC_REG = "TRUE" *) reg        [31:0] reg_pdt_s1;
    (* ASYNC_REG = "TRUE" *) reg        [31:0] reg_hdt_s1;
    (* ASYNC_REG = "TRUE" *) reg        [31:0] reg_hlt_s1;
    (* ASYNC_REG = "TRUE" *) reg        [31:0] reg_pretrig_s1;
    reg signed [31:0] reg_threshold;   // fully synchronised, used by all submodules
    reg        [31:0] reg_pdt;
    reg        [31:0] reg_hdt;
    reg        [31:0] reg_hlt;
    reg        [31:0] reg_pretrig;

    // Wires from Accumulator (Live)
    wire        [31:0] reg_peak_val;
    wire        [31:0] reg_peak_time;
    wire        [47:0] reg_energy_acc;
    wire        [31:0] reg_hit_dur;
    wire        [31:0] reg_hit_cnt;
    wire        [31:0] reg_rise_time;

    // Wires from FSM (Latched for AXI-Lite readback)
    wire        [31:0] latched_peak_val;
    wire        [31:0] latched_peak_time;
    wire        [31:0] latched_hit_dur;
    wire        [31:0] latched_hit_cnt;
    wire        [31:0] latched_rise_time;

    wire               over_threshold;
    wire               sample_over_threshold;
    wire               trigger_event;
    wire               pos_threshold_rising;

    wire               wr_en;
    wire  [ADDR_W-1:0] wr_ptr;
    wire  [ADDR_W-1:0] rd_ptr;
    wire  [DW-1:0]     buf_rd_data;

    wire               accum_init;       // FSM -> Accumulator control
    wire               accum_en;         // FSM -> Accumulator control

    //----------------------------------------------------------------------
    // 2-FF CDC Synchronisers: AXIL (s_axi_aclk) → capture (clk)
    // Reset values match the AXIL initial block defaults.
    //----------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            // Match AXIL initial default: 1966 LSB = 150.0 mV
            reg_threshold_s1 <= 32'sd1966;     reg_threshold <= 32'sd1966;
            reg_pdt_s1       <= 32'd128;        reg_pdt       <= 32'd128;
            reg_hdt_s1       <= 32'd256;        reg_hdt       <= 32'd256;
            reg_hlt_s1       <= 32'd500;        reg_hlt       <= 32'd500;
            reg_pretrig_s1   <= PRE_TRIGGER;    reg_pretrig   <= PRE_TRIGGER;
        end else begin
            reg_threshold_s1 <= reg_threshold_raw;  reg_threshold <= reg_threshold_s1;
            reg_pdt_s1       <= reg_pdt_raw;         reg_pdt       <= reg_pdt_s1;
            reg_hdt_s1       <= reg_hdt_raw;         reg_hdt       <= reg_hdt_s1;
            reg_hlt_s1       <= reg_hlt_raw;         reg_hlt       <= reg_hlt_s1;
            reg_pretrig_s1   <= reg_pretrig_raw;     reg_pretrig   <= reg_pretrig_s1;
        end
    end

    //----------------------------------------------------------------------
    // AXI-Lite Register Sub-module
    //----------------------------------------------------------------------
    Event_Capture_AXIL #(
        .DW          ( DW          ),
        .DEPTH       ( DEPTH       ),
        .PRE_TRIGGER ( PRE_TRIGGER )
    ) i_axil (
        .s_axi_aclk    ( s_axi_aclk        ),
        .s_axi_aresetn ( s_axi_aresetn     ),
        .s_axi_awvalid ( s_axi_awvalid     ),
        .s_axi_awaddr  ( s_axi_awaddr      ),
        .s_axi_awready ( s_axi_awready     ),
        .s_axi_wvalid  ( s_axi_wvalid      ),
        .s_axi_wdata   ( s_axi_wdata       ),
        .s_axi_wstrb   ( s_axi_wstrb       ),
        .s_axi_wready  ( s_axi_wready      ),
        .s_axi_bvalid  ( s_axi_bvalid      ),
        .s_axi_bresp   ( s_axi_bresp       ),
        .s_axi_bready  ( s_axi_bready      ),
        .s_axi_arvalid ( s_axi_arvalid     ),
        .s_axi_araddr  ( s_axi_araddr      ),
        .s_axi_arready ( s_axi_arready     ),
        .s_axi_rvalid  ( s_axi_rvalid      ),
        .s_axi_rdata   ( s_axi_rdata       ),
        .s_axi_rresp   ( s_axi_rresp       ),
        .s_axi_rready  ( s_axi_rready      ),

        .reg_threshold ( reg_threshold_raw ),
        .reg_pdt       ( reg_pdt_raw       ),
        .reg_hdt       ( reg_hdt_raw       ),
        .reg_hlt       ( reg_hlt_raw       ),
        .reg_pretrig   ( reg_pretrig_raw   ),

        .reg_peak_val  ( latched_peak_val  ),
        .reg_peak_time ( latched_peak_time ),
        .reg_energy_acc( reg_energy_acc    ),
        .reg_hit_dur   ( latched_hit_dur   ),
        .reg_hit_cnt   ( latched_hit_cnt   ),
        .reg_rise_time ( latched_rise_time )
    );

    //----------------------------------------------------------------------
    // Threshold Detector Sub-module
    //----------------------------------------------------------------------
    Event_Capture_Detector #(
        .DW ( DW )
    ) i_detector (
        .clk                  ( clk                   ),
        .rst                  ( rst                   ),
        .s_axis_tvalid        ( s_axis_tvalid         ),
        .s_axis_tdata         ( s_axis_tdata          ),
        .reg_threshold        ( reg_threshold         ),

        .over_threshold       ( over_threshold        ),
        .sample_over_threshold( sample_over_threshold ),
        .trigger_event        ( trigger_event         ),
        .pos_threshold_rising ( pos_threshold_rising  )
    );

    //----------------------------------------------------------------------
    // Circular Buffer Memory Sub-module
    //----------------------------------------------------------------------
    Event_Capture_Buffer #(
        .DW     ( DW     ),
        .DEPTH  ( DEPTH  ),
        .ADDR_W ( ADDR_W )
    ) i_buffer (
        .clk     ( clk          ),
        .wr_en   ( wr_en        ),
        .wr_ptr  ( wr_ptr       ),
        .wr_data ( s_axis_tdata ),
        .rd_ptr  ( rd_ptr       ),
        .rd_data ( buf_rd_data  )
    );

    //----------------------------------------------------------------------
    // Feature Accumulator Sub-module
    //----------------------------------------------------------------------
    Event_Capture_Accumulator #(
        .DW ( DW )
    ) i_accumulator (
        .clk                  ( clk                  ),
        .rst                  ( rst                  ),

        .accum_init           ( accum_init           ),
        .accum_en             ( accum_en             ),

        .s_axis_tdata         ( s_axis_tdata         ),
        .pos_threshold_rising ( pos_threshold_rising ),
        .reg_threshold        ( reg_threshold        ),
        .reg_pdt              ( reg_pdt              ),

        .peak_val             ( reg_peak_val         ),
        .peak_time            ( reg_peak_time        ),
        .energy_acc           ( reg_energy_acc       ),
        .hit_cnt              ( reg_hit_cnt          ),
        .hit_dur              ( reg_hit_dur          ),
        .rise_time            ( reg_rise_time        )
    );

    //----------------------------------------------------------------------
    // Main Capture FSM & DMA Output Sub-module
    //----------------------------------------------------------------------
    Event_Capture_FSM #(
        .DW          ( DW          ),
        .DEPTH       ( DEPTH       ),
        .ADDR_W      ( ADDR_W      ),
        .PRE_TRIGGER ( PRE_TRIGGER )
    ) i_fsm (
        .clk                  ( clk                   ),
        .rst                  ( rst                   ),
        .s_axis_tvalid        ( s_axis_tvalid         ),
        .s_axis_tdata         ( s_axis_tdata          ),

        .trigger_event        ( trigger_event         ),
        .pos_threshold_rising ( pos_threshold_rising  ),
        .over_threshold       ( over_threshold        ),
        .sample_over_threshold( sample_over_threshold ),

        .reg_threshold        ( reg_threshold         ),
        .reg_pdt              ( reg_pdt               ),
        .reg_hdt              ( reg_hdt               ),
        .reg_hlt              ( reg_hlt               ),
        .reg_pretrig          ( reg_pretrig           ),

        .wr_en                ( wr_en                 ),
        .wr_ptr               ( wr_ptr                ),
        .rd_ptr               ( rd_ptr                ),
        .buf_rd_data          ( buf_rd_data           ),

        .accum_init           ( accum_init            ),
        .accum_en             ( accum_en              ),

        .acc_peak_val         ( reg_peak_val          ),
        .acc_peak_time        ( reg_peak_time         ),
        .acc_energy_acc       ( reg_energy_acc        ),
        .acc_hit_cnt          ( reg_hit_cnt           ),
        .acc_hit_dur          ( reg_hit_dur           ),
        .acc_rise_time        ( reg_rise_time         ),
 
        .trigger_out          ( trigger_out           ),
        .capture_done         ( capture_done          ),

        .m_axis_tdata         ( m_axis_tdata          ),
        .m_axis_tvalid        ( m_axis_tvalid         ),
        .m_axis_tready        ( m_axis_tready         ),
        .m_axis_tlast         ( m_axis_tlast          ),

        .reg_peak_val         ( latched_peak_val      ),
        .reg_peak_time        ( latched_peak_time     ),
        .reg_hit_dur          ( latched_hit_dur       ),
        .reg_hit_cnt          ( latched_hit_cnt       ),
        .reg_rise_time        ( latched_rise_time     ),

        .fft_peak_bin         ( fft_peak_bin          )
    );

endmodule