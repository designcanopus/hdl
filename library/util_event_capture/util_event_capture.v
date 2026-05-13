// ***************************************************************************
// ***************************************************************************
// Copyright (C) 2023-2026 Analog Devices, Inc. All rights reserved.
// ***************************************************************************
// ***************************************************************************

`timescale 1ns/100ps

module util_event_capture #(
  parameter NUM_OF_CHANNELS = 8,
  parameter DW            = 16,
  parameter DEPTH         = 16384,  // 2^14 — next power-of-2 above 10000
  parameter ADDR_W        = 14,     // log2(DEPTH)
  parameter PRE_TRIGGER   = 2500,   // samples before trigger
  parameter POST_TRIGGER  = 7500    // samples after  trigger
)(
  input                   clk,
  input                   rst,

  input                   valid_in,

  input  signed [DW-1:0]  data_in_0,
  input  signed [DW-1:0]  data_in_1,
  input  signed [DW-1:0]  data_in_2,
  input  signed [DW-1:0]  data_in_3,
  input  signed [DW-1:0]  data_in_4,
  input  signed [DW-1:0]  data_in_5,
  input  signed [DW-1:0]  data_in_6,
  input  signed [DW-1:0]  data_in_7,

  input  signed [DW-1:0]  threshold,

  output reg              trigger_out,

  output reg              data_out_valid,
  output reg [DW-1:0]     data_out_0,
  output reg [DW-1:0]     data_out_1,
  output reg [DW-1:0]     data_out_2,
  output reg [DW-1:0]     data_out_3,
  output reg [DW-1:0]     data_out_4,
  output reg [DW-1:0]     data_out_5,
  output reg [DW-1:0]     data_out_6,
  output reg [DW-1:0]     data_out_7,

  output reg              capture_done
);

  localparam TOTAL_WINDOW = PRE_TRIGGER + POST_TRIGGER;

  // =========================================================================
  // Threshold registration (Domain Crossing Protection)
  // =========================================================================
  reg signed [DW-1:0] threshold_r;
  always @(posedge clk) begin
    threshold_r <= threshold;
  end

  // =========================================================================
  // Memory (Separate arrays to bypass Vivado's 1M-bit synthesis limit)
  // =========================================================================
  (* ram_style = "block" *) reg [DW-1:0] mem_0 [0:DEPTH-1];
  (* ram_style = "block" *) reg [DW-1:0] mem_1 [0:DEPTH-1];
  (* ram_style = "block" *) reg [DW-1:0] mem_2 [0:DEPTH-1];
  (* ram_style = "block" *) reg [DW-1:0] mem_3 [0:DEPTH-1];
  (* ram_style = "block" *) reg [DW-1:0] mem_4 [0:DEPTH-1];
  (* ram_style = "block" *) reg [DW-1:0] mem_5 [0:DEPTH-1];
  (* ram_style = "block" *) reg [DW-1:0] mem_6 [0:DEPTH-1];
  (* ram_style = "block" *) reg [DW-1:0] mem_7 [0:DEPTH-1];

  reg [ADDR_W-1:0] wr_ptr;
  reg [ADDR_W-1:0] rd_ptr;

  // =========================================================================
  // Trigger Detection (Channel 0)
  // =========================================================================
  reg signed [DW-1:0] prev_sample;

  wire trigger_event_pos;
  wire trigger_event_neg;
  wire trigger_event_comb;

  assign trigger_event_pos =
          valid_in &&
          (prev_sample < threshold_r) &&
          (data_in_0 >= threshold_r);

  assign trigger_event_neg =
          valid_in &&
          (prev_sample > threshold_r) &&
          (data_in_0 <= threshold_r);

  assign trigger_event_comb =
          trigger_event_pos || trigger_event_neg;

  // Registering the trigger event to improve timing
  reg trigger_event;
  always @(posedge clk) begin
    if (rst) trigger_event <= 1'b0;
    else     trigger_event <= trigger_event_comb;
  end

  // =========================================================================
  // FSM States
  // =========================================================================
  localparam WAIT_TRIGGER = 2'd0;
  localparam CAPTURE      = 2'd1;
  localparam OUTPUT_PREP  = 2'd2;
  localparam OUTPUT       = 2'd3;

  reg [1:0] state;

  // =========================================================================
  // Counters
  // =========================================================================
  reg [ADDR_W:0] capture_count;
  reg [ADDR_W:0] output_count;

  // =========================================================================
  // BRAM Read Pipeline Registers
  // =========================================================================
  reg [DW-1:0] q_reg_0;
  reg [DW-1:0] q_reg_1;
  reg [DW-1:0] q_reg_2;
  reg [DW-1:0] q_reg_3;
  reg [DW-1:0] q_reg_4;
  reg [DW-1:0] q_reg_5;
  reg [DW-1:0] q_reg_6;
  reg [DW-1:0] q_reg_7;

  // =========================================================================
  // Continuous Circular Buffer Write
  // =========================================================================
  always @(posedge clk) begin
    if (rst) begin
      wr_ptr <= 0;
    end
    else if (valid_in) begin
      mem_0[wr_ptr] <= data_in_0;
      mem_1[wr_ptr] <= data_in_1;
      mem_2[wr_ptr] <= data_in_2;
      mem_3[wr_ptr] <= data_in_3;
      mem_4[wr_ptr] <= data_in_4;
      mem_5[wr_ptr] <= data_in_5;
      mem_6[wr_ptr] <= data_in_6;
      mem_7[wr_ptr] <= data_in_7;
      wr_ptr <= wr_ptr + 1'b1;
    end
  end

  // =========================================================================
  // Previous Sample Register
  // =========================================================================
  always @(posedge clk) begin
    if (rst)
      prev_sample <= 0;
    else if (valid_in)
      prev_sample <= data_in_0;
  end

  // =========================================================================
  // FSM + Streaming Logic
  // =========================================================================
  always @(posedge clk) begin

    if (rst) begin

      state           <= WAIT_TRIGGER;
      rd_ptr          <= 0;
      capture_count   <= 0;
      output_count    <= 0;
      q_reg_0         <= 0;
      q_reg_1         <= 0;
      q_reg_2         <= 0;
      q_reg_3         <= 0;
      q_reg_4         <= 0;
      q_reg_5         <= 0;
      q_reg_6         <= 0;
      q_reg_7         <= 0;
      data_out_0      <= 0;
      data_out_1      <= 0;
      data_out_2      <= 0;
      data_out_3      <= 0;
      data_out_4      <= 0;
      data_out_5      <= 0;
      data_out_6      <= 0;
      data_out_7      <= 0;
      data_out_valid  <= 1'b0;
      trigger_out     <= 1'b0;
      capture_done    <= 1'b0;

    end
    else begin

      // Only assert valid during the replay phase
      data_out_valid <= 1'b0;
      trigger_out    <= 1'b0;
      capture_done   <= 1'b0;

      case (state)

      // =============================================================
      // WAIT_TRIGGER
      // =============================================================
      WAIT_TRIGGER: begin
        if (trigger_event) begin

          trigger_out <= 1'b1;

          // Snapshot the pre-trigger start address.
          // Registered trigger adjustment:
          // trigger_event is delayed by 1 cycle, so wr_ptr has advanced by 1.
          // Correct start address is (wr_ptr - 1) - PRE_TRIGGER + 1 = wr_ptr - PRE_TRIGGER.
          rd_ptr <=
              (wr_ptr - PRE_TRIGGER[ADDR_W-1:0]) &
              (DEPTH - 1);

          capture_count <= 0;

          state <= CAPTURE;
        end
      end

      // =============================================================
      // CAPTURE
      // =============================================================
      CAPTURE: begin
        if (valid_in) begin

          capture_count <= capture_count + 1'b1;

          if (capture_count == (POST_TRIGGER - 1)) begin
            state <= OUTPUT_PREP;
          end
        end
      end

      // =============================================================
      // OUTPUT_PREP
      // =============================================================
      OUTPUT_PREP: begin
        if (valid_in) begin
          // Prime the pipeline
          q_reg_0 <= mem_0[rd_ptr];
          q_reg_1 <= mem_1[rd_ptr];
          q_reg_2 <= mem_2[rd_ptr];
          q_reg_3 <= mem_3[rd_ptr];
          q_reg_4 <= mem_4[rd_ptr];
          q_reg_5 <= mem_5[rd_ptr];
          q_reg_6 <= mem_6[rd_ptr];
          q_reg_7 <= mem_7[rd_ptr];

          rd_ptr <=
              (rd_ptr + 1'b1) &
              (DEPTH - 1);
          output_count <= 0;
          state <= OUTPUT;
        end
      end

      // =============================================================
      // OUTPUT
      // =============================================================
      OUTPUT: begin
        if (valid_in) begin
          // Assert valid only when driving real data
          data_out_valid <= 1'b1;

          // Present aligned BRAM data
          data_out_0 <= q_reg_0;
          data_out_1 <= q_reg_1;
          data_out_2 <= q_reg_2;
          data_out_3 <= q_reg_3;
          data_out_4 <= q_reg_4;
          data_out_5 <= q_reg_5;
          data_out_6 <= q_reg_6;
          data_out_7 <= q_reg_7;

          // Fetch next sample
          q_reg_0 <= mem_0[rd_ptr];
          q_reg_1 <= mem_1[rd_ptr];
          q_reg_2 <= mem_2[rd_ptr];
          q_reg_3 <= mem_3[rd_ptr];
          q_reg_4 <= mem_4[rd_ptr];
          q_reg_5 <= mem_5[rd_ptr];
          q_reg_6 <= mem_6[rd_ptr];
          q_reg_7 <= mem_7[rd_ptr];

          rd_ptr <=
              (rd_ptr + 1'b1) &
              (DEPTH - 1);

          output_count <= output_count + 1'b1;

          if (output_count == (TOTAL_WINDOW - 1)) begin
            capture_done <= 1'b1;
            state <= WAIT_TRIGGER;
          end
        end
      end

      default: begin
        state <= WAIT_TRIGGER;
      end

      endcase
    end
  end

endmodule
