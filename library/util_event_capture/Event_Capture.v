module Event_Capture #(
    // -----------------------------------------------------------------
    // DEPTH must be a power of 2 and MUST be >= PRE_TRIGGER + POST_TRIGGER.
    // We need 10000 samples total (PRE=2500 + POST=7500).
    // Next power of 2 above 10000 is 16384.
    // ADDR_W = log2(16384) = 14
    // -----------------------------------------------------------------
    parameter DW            = 16,
    parameter DEPTH         = 16384,  // 2^14 — next power-of-2 above 10000
    parameter ADDR_W        = 14,     // log2(DEPTH)
    parameter PRE_TRIGGER   = 2500,   // samples before trigger
    parameter POST_TRIGGER  = 7500    // samples after  trigger
                                      // TOTAL = 10000
)(
    input                   clk,
    input                   rst,

    input                   valid_in,
    input  signed [DW-1:0]  data_in,
    input  signed [DW-1:0]  threshold,

    output reg              trigger_out,
    output reg signed [DW-1:0] data_out,
    output reg              data_out_valid,
    output reg              capture_done
);

    localparam TOTAL_WINDOW = PRE_TRIGGER + POST_TRIGGER; // 10000

    // ============================================================
    // Circular Buffer Memory  (16384 x 16-bit words)
    // On Zynq/UltraScale this will infer RAMB36 BRAMs automatically.
    // 16384 * 16-bit = 32 KB  →  ~9 RAMB36 tiles
    // ============================================================
    reg signed [DW-1:0] mem [0:DEPTH-1];

    reg [ADDR_W-1:0] wr_ptr;
    reg [ADDR_W-1:0] rd_ptr;

    // ============================================================
    // Trigger Detection  (both slope directions)
    // ============================================================
    reg signed [DW-1:0] prev_sample;

    wire trigger_event_pos;
    wire trigger_event_neg;
    wire trigger_event;

    assign trigger_event_pos =
            valid_in &&
            (prev_sample <  threshold) &&
            (data_in     >= threshold);

    assign trigger_event_neg =
            valid_in &&
            (prev_sample >  threshold) &&
            (data_in     <= threshold);

    assign trigger_event = trigger_event_pos || trigger_event_neg;

    // ============================================================
    // FSM States
    // ============================================================
    localparam WAIT_TRIGGER = 2'd0;
    localparam CAPTURE      = 2'd1;
    localparam OUTPUT_PREP  = 2'd2;
    localparam OUTPUT       = 2'd3;

    reg [1:0] state;

    // ============================================================
    // Counters — width must hold POST_TRIGGER (7500) and TOTAL (10000)
    // 14 bits covers up to 16383  ✓
    // ============================================================
    reg [ADDR_W:0] capture_count;  // 15-bit, max 16384
    reg [ADDR_W:0] output_count;   // 15-bit, max 16384

    // ============================================================
    // BRAM Read Pipeline Register
    // ============================================================
    reg signed [DW-1:0] mem_q;

    // ============================================================
    // Continuous Circular Buffer Write
    // (runs in ALL states so the pre-trigger history is always fresh)
    // ============================================================
    always @(posedge clk) begin
        if (rst) begin
            wr_ptr <= 0;
        end
        else if (valid_in) begin
            mem[wr_ptr] <= data_in;
            wr_ptr      <= wr_ptr + 1'b1;
        end
    end

    // ============================================================
    // Previous Sample Register  (for edge-crossing detection)
    // ============================================================
    always @(posedge clk) begin
        if (rst)
            prev_sample <= 0;
        else if (valid_in)
            prev_sample <= data_in;
    end

    // ============================================================
    // Main FSM
    // ============================================================
    always @(posedge clk) begin

        if (rst) begin

            state           <= WAIT_TRIGGER;
            rd_ptr          <= 0;
            capture_count   <= 0;
            output_count    <= 0;
            mem_q           <= 0;
            data_out        <= 0;
            data_out_valid  <= 1'b0;
            trigger_out     <= 1'b0;
            capture_done    <= 1'b0;

        end
        else begin

            // --------------------------------------------------------
            // Pulse-only defaults (deassert every cycle unless set)
            // --------------------------------------------------------
            trigger_out  <= 1'b0;
            capture_done <= 1'b0;

            case (state)

            // ========================================================
            // WAIT_TRIGGER
            // Idle — stream zeros, keep DMA alive via valid_in
            // ========================================================
            WAIT_TRIGGER: begin

                data_out       <= 0;
                data_out_valid <= valid_in;   // mirror source — DMA stays alive

                if (trigger_event) begin

                    trigger_out <= 1'b1;

                    // FIX 2: compute rd_ptr at trigger moment.
                    // wr_ptr is the address where data_in is being written
                    // THIS cycle (parallel always block), so wr_ptr+1 will
                    // be the next free slot.  We go back PRE_TRIGGER samples
                    // from the sample being written now (wr_ptr).
                    rd_ptr        <= (wr_ptr - PRE_TRIGGER + 1'b1) & (DEPTH - 1);

                    capture_count <= 0;
                    state         <= CAPTURE;
                end
            end

            // ========================================================
            // CAPTURE
            // Wait for POST_TRIGGER more valid samples to be written
            // into the circular buffer so the full window is on-chip.
            //
            // FIX 1: count ONLY valid_in pulses — if the ADC ever
            // stalls or inserts idle cycles, we must not exit early.
            // ========================================================
            CAPTURE: begin

                data_out       <= 0;
                data_out_valid <= valid_in;   // mirror source during wait

                if (valid_in) begin

                    capture_count <= capture_count + 1'b1;

                    if (capture_count == (POST_TRIGGER - 1))
                        state <= OUTPUT_PREP;
                end
            end

            // ========================================================
            // OUTPUT_PREP
            // Issue the first BRAM read (synchronous RAM: 1-cycle latency).
            // rd_ptr already points to sample #0 of the pre-trigger window.
            //
            // FIX 2: we do NOT move rd_ptr here before the first read,
            // so sample #0 is correctly latched into mem_q and output
            // first in the OUTPUT state.  The original code advanced
            // rd_ptr before latching, causing sample #0 to be skipped.
            // ========================================================
            OUTPUT_PREP: begin

                mem_q          <= mem[rd_ptr];               // latch sample #0
                rd_ptr         <= (rd_ptr + 1'b1) & (DEPTH - 1); // next = sample #1

                output_count   <= 0;

                // FIX 3: assert valid immediately — no gap between
                // the CAPTURE zeros and the replayed waveform
                data_out_valid <= 1'b1;
                data_out       <= 0;

                state <= OUTPUT;
            end

            // ========================================================
            // OUTPUT
            // Replay all 10000 captured samples from the BRAM.
            //
            // FIX 3: data_out_valid is held HIGH unconditionally for
            // the entire replay window, regardless of valid_in.
            // Original code used a global "data_out_valid <= valid_in"
            // default which caused the DMA to see holes whenever
            // valid_in was low during replay.
            // ========================================================
            OUTPUT: begin

                data_out_valid <= 1'b1;          // FIX 3 — always valid during replay

                data_out       <= mem_q;          // present previous read result
                mem_q          <= mem[rd_ptr];    // pipeline: fetch next sample
                rd_ptr         <= (rd_ptr + 1'b1) & (DEPTH - 1);

                output_count   <= output_count + 1'b1;

                // Done after TOTAL_WINDOW = 10000 samples
                if (output_count == (TOTAL_WINDOW - 1)) begin
                    capture_done <= 1'b1;
                    state        <= WAIT_TRIGGER;
                end
            end

            // ========================================================
            // Default (should never be reached)
            // ========================================================
            default: begin
                state          <= WAIT_TRIGGER;
                data_out_valid <= 1'b0;
            end

            endcase
        end
    end

endmodule
