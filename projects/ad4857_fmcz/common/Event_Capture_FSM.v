// ***************************************************************************
// ***************************************************************************
// Copyright (C) 2014-2025 Analog Devices, Inc. All rights reserved.
// ***************************************************************************
// ***************************************************************************

`timescale 1ns/100ps

module Event_Capture_FSM #(
    parameter DW          = 16,
    parameter DEPTH       = 16384,
    parameter ADDR_W      = 14,
    parameter PRE_TRIGGER = 512
)(
    input                   clk,
    input                   rst,

    // AXI4-Stream Slave Interface (Input from ADC)
    input                   s_axis_tvalid,
    input  signed [DW-1:0]  s_axis_tdata,

    // Signals from Detector
    input                   trigger_event,
    input                   pos_threshold_rising,
    input                   over_threshold,
    input                   sample_over_threshold,

    // Config inputs from AXI-Lite
    input  signed [31:0]    reg_threshold,
    input         [31:0]    reg_pdt,
    input         [31:0]    reg_hdt,
    input         [31:0]    reg_hlt,
    input         [31:0]    reg_pretrig,

    // Accumulator Control & Feature Inputs
    output                  accum_init,
    output                  accum_en,
    input         [31:0]    acc_peak_val,
    input         [31:0]    acc_peak_time,
    input         [47:0]    acc_energy_acc,
    input         [31:0]    acc_hit_cnt,
    input         [31:0]    acc_hit_dur,
    input         [31:0]    acc_rise_time,

    // Buffer Interface
    output                  wr_en,
    output reg [ADDR_W-1:0] wr_ptr,
    output reg [ADDR_W-1:0] rd_ptr,
    input      [DW-1:0]     buf_rd_data,

    // Control & Status Outputs
    output reg              trigger_out,
    output reg              capture_done,

    // AXI4-Stream Master Interface (Output to DMA)
    output reg [DW-1:0]     m_axis_tdata,
    output reg              m_axis_tvalid,
    input                   m_axis_tready,
    output reg              m_axis_tlast,

    // Feature Readback Outputs (to AXI-Lite)
    output reg [31:0]       reg_peak_val,
    output reg [31:0]       reg_peak_time,
    output reg [31:0]       reg_hit_dur,
    output reg [31:0]       reg_hit_cnt,
    output reg [31:0]       reg_rise_time,

    // FPGA FFT Peak Frequency Bin
    input      [31:0]       fft_peak_bin
);

    //----------------------------------------------------------------------
    // Header Staging Registers (16 x 32-bit = 64 bytes -> 32 x 16-bit words)
    //----------------------------------------------------------------------
    reg [31:0] header_regs [0:15];
    reg [31:0] event_id_counter = 0;

    // Lockout Counter
    reg [31:0] hlt_counter = 0;

    //----------------------------------------------------------------------
    // FSM States
    //----------------------------------------------------------------------
    localparam WAIT_TRIGGER = 2'd0;
    localparam CAPTURE      = 2'd1;
    localparam OUTPUT       = 2'd2;
    localparam LOCKOUT      = 2'd3;
    // Number of 16-bit AXI-Stream words in the output header (16×32-bit regs)
    localparam HEADER_WORDS = 32;

    reg [1:0]        state;
    reg [31:0]       hdt_timer;
    reg [31:0]       next_hdt_timer;
    reg [31:0]       total_samples;
    reg [31:0]       output_count;
    reg [ADDR_W-1:0] start_ptr;
    reg [ADDR_W-1:0] end_ptr;
    reg [DW-1:0]     mem_q;
    reg              buffer_full;

    // Accumulator Control Signals
    assign accum_init = (state == WAIT_TRIGGER) && trigger_event;
    assign accum_en   = (state == CAPTURE) && s_axis_tvalid;

    // Write enable for circular buffer
    assign wr_en = s_axis_tvalid && (state == WAIT_TRIGGER || state == CAPTURE || state == LOCKOUT);

    // Buffer Write Pointer Update
    always @(posedge clk) begin
        if (rst) begin
            wr_ptr <= 0;
        end else if (s_axis_tvalid) begin
            if (wr_en) begin
                wr_ptr <= wr_ptr + 1'b1;
            end
        end
    end

    

    //----------------------------------------------------------------------
    // Main FSM Logic
    //----------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state            <= WAIT_TRIGGER;
            rd_ptr           <= 0;
            hdt_timer        <= 0;
            hlt_counter      <= 0;
            total_samples    <= 0;
            output_count     <= 0;
            mem_q            <= 0;
            start_ptr        <= 0;
            end_ptr          <= 0;
            trigger_out      <= 1'b0;
            capture_done     <= 1'b0;
            m_axis_tdata     <= 0;
            m_axis_tvalid    <= 1'b0;
            m_axis_tlast     <= 1'b0;
            reg_peak_val     <= 0;
            reg_peak_time    <= 0;
            reg_hit_dur      <= 0;
            reg_hit_cnt      <= 0;
            reg_rise_time    <= 0;
            event_id_counter <= 0;
            buffer_full      <= 1'b0;
        end else begin
            trigger_out  <= 1'b0;
            capture_done <= 1'b0;

            case (state)

                // --------------------------------------------------------
                // WAIT_TRIGGER: idle, watching for threshold crossing
                // --------------------------------------------------------
                WAIT_TRIGGER: begin
                    m_axis_tvalid <= 1'b0;
                    m_axis_tlast  <= 1'b0;

                    if (trigger_event) begin
                        trigger_out <= 1'b1;
                        start_ptr   <= (wr_ptr - reg_pretrig) & (DEPTH - 1);
                        hdt_timer   <= 0;
                        hlt_counter <= 0;
                        state       <= CAPTURE;

                        // Phase 1 Header: identity fields
                        header_regs[0] <= 32'hAE5EE5AE; // Magic
                        header_regs[1] <= event_id_counter;
                        header_regs[2] <= {{(32-ADDR_W){1'b0}}, (wr_ptr - reg_pretrig) & (DEPTH-1)};
                        header_regs[3] <= reg_threshold; // Configured hardware threshold LSB
                        header_regs[4] <= {{(32-ADDR_W){1'b0}}, wr_ptr};
                        header_regs[5] <= 32'h0;    // reserved — patched post-DMA by event_dma_capture.c with g_ch_pdt (samples)
                        header_regs[6] <= 32'h0;    // reserved — patched post-DMA by event_dma_capture.c with g_ch_hdt (samples)
                        header_regs[7] <= 32'h0;    // reserved — patched post-DMA by event_dma_capture.c with g_ch_hlt (samples)
                    end
                end

                // --------------------------------------------------------
                // CAPTURE: watching HDT timer and sample limit
                // --------------------------------------------------------
                CAPTURE: begin
                    if (s_axis_tvalid) begin
                        // --- HDT Timer ---
                        next_hdt_timer = sample_over_threshold ? 32'h0
                                                               : hdt_timer + 1'b1;

                        if ((next_hdt_timer >= reg_hdt) || (acc_hit_dur >= (DEPTH - reg_pretrig))) begin
                            buffer_full <= (acc_hit_dur >= (DEPTH - reg_pretrig));
                            end_ptr       <= wr_ptr;
                            total_samples <= ((reg_pretrig + acc_hit_dur) > DEPTH) ? DEPTH : (reg_pretrig + acc_hit_dur);
                            rd_ptr        <= start_ptr;
                            output_count  <= 0;
                            state         <= OUTPUT;

                            // Latch final features for AXI-Lite readback
                            reg_peak_val  <= acc_peak_val;
                            reg_peak_time <= acc_peak_time;
                            reg_hit_dur   <= acc_hit_dur;
                            reg_hit_cnt   <= acc_hit_cnt;
                            reg_rise_time <= acc_rise_time;

                            // Phase 2 Header: status, length, and feature fields
                            header_regs[8]  <= fft_peak_bin;      // FPGA FFT Peak Frequency Bin (hdr32[8])
                            header_regs[9]  <= ((reg_pretrig + acc_hit_dur) > DEPTH) ? DEPTH : (reg_pretrig + acc_hit_dur);             // Waveform length
                            header_regs[10] <= 32'h00010000;      // Version 1.0
                            header_regs[11] <= acc_peak_val;
                            header_regs[12] <= acc_energy_acc[31:0];
                            header_regs[13] <= {acc_energy_acc[47:32], 16'h0} | acc_hit_cnt[15:0];
                            header_regs[14] <= acc_hit_dur;
                            header_regs[15] <= acc_rise_time;

                            m_axis_tdata  <= header_regs[0][15:0];   // word0 (Magic LSB)
                            mem_q         <= header_regs[0][31:16];  // word1 (Magic MSB)
                            m_axis_tvalid <= 1'b1;
                            m_axis_tlast  <= 1'b0;
                        end

                        hdt_timer <= next_hdt_timer;
                    end
                end

                // --------------------------------------------------------
                // OUTPUT: stream header (HEADER_WORDS words) then waveform
                // (total_samples words). BRAM has 1-cycle read latency so
                // rd_ptr is pre-advanced one beat before the first waveform
                // word is needed, ensuring buf_rd_data is valid in time.
                // --------------------------------------------------------
                OUTPUT: begin
                    if (m_axis_tvalid && m_axis_tready) begin
                        m_axis_tdata <= mem_q;
                        m_axis_tlast <= ((output_count + 1'b1) == (HEADER_WORDS + total_samples - 1));

                        if ((output_count + 2) <= (HEADER_WORDS + total_samples - 1)) begin
                            if ((output_count + 2) < HEADER_WORDS) begin
                                if ((output_count + 2) & 1'b1)
                                    mem_q <= header_regs[(output_count + 2) >> 1][31:16];
                                else
                                    mem_q <= header_regs[(output_count + 2) >> 1][15:0];
                                // Pre-prime BRAM one cycle early: advance rd_ptr when the
                                // NEXT word to stage is the first waveform sample.  This
                                // gives the synchronous BRAM one full clock to latch the
                                // correct address before buf_rd_data is consumed.
                                if ((output_count + 2) == (HEADER_WORDS - 1))
                                    rd_ptr <= (rd_ptr + 1'b1) & (DEPTH - 1);
                            end else begin
                                mem_q  <= buf_rd_data;
                                rd_ptr <= (rd_ptr + 1'b1) & (DEPTH - 1);
                            end
                        end

                        output_count <= output_count + 1'b1;

                        if (output_count == (HEADER_WORDS + total_samples - 1)) begin
                            m_axis_tvalid    <= 1'b0;
                            m_axis_tlast     <= 1'b0;
                            capture_done     <= 1'b1;
                            event_id_counter <= event_id_counter + 1'b1;
                            hlt_counter      <= 0;
                            hdt_timer        <= 0;
                            state            <= LOCKOUT;
                        end
                    end
                end

                // --------------------------------------------------------
                // LOCKOUT: HLT window — suppress new triggers for reg_hlt
                // samples.  Check (hlt_counter + 1 >= reg_hlt) BEFORE the
                // increment so the lockout is exactly reg_hlt samples long
                // (fix: previously the counter reached reg_hlt+1 samples).
                // --------------------------------------------------------
                LOCKOUT: begin
                    if (s_axis_tvalid) begin
                        if (hlt_counter + 1 < reg_hlt) begin
                            hlt_counter <= hlt_counter + 1'b1;
                            hdt_timer   <= 0;
                        end else if (buffer_full) begin
                            // Buffer was full — wait for signal to drop below threshold for 4x reg_hdt quiet samples before re-arming
                            if (sample_over_threshold) begin
                                hdt_timer <= 0;
                            end else if (hdt_timer + 1 >= (reg_hdt << 2)) begin
                                hdt_timer   <= 0;
                                hlt_counter <= 0;
                                buffer_full <= 1'b0;
                                state       <= WAIT_TRIGGER;
                            end else begin
                                hdt_timer <= hdt_timer + 1'b1;
                            end
                        end else begin
                            hlt_counter <= 0;
                            hdt_timer   <= 0;
                            state       <= WAIT_TRIGGER;
                        end
                    end
                end

                default: state <= WAIT_TRIGGER;

            endcase
        end
    end

endmodule
