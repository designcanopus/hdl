// ***************************************************************************
// FFT_Frame_Sync.v
// =================
//
// Generates tlast on the SAME AXI4-Stream transfer as sample N-1.
//
// For N = 4096:
//
//     sample 0     -> tlast = 0
//     sample 1     -> tlast = 0
//       ...
//     sample 4094  -> tlast = 0
//     sample 4095  -> tlast = 1
//
// IMPORTANT:
// tlast is combinational so it is aligned with valid_in/data.
// ***************************************************************************

`timescale 1ns/100ps

module FFT_Frame_Sync #(
    parameter FFT_N = 4096,
    parameter CNT_W = 12
)(
    input  clk,
    input  rst,

    input  valid_in,

    output tlast_out
);

    reg [CNT_W-1:0] cnt;

    /*
     * tlast describes the CURRENT AXI transfer.
     */
    assign tlast_out = valid_in && (cnt == FFT_N - 1);

    always @(posedge clk) begin
        if (rst) begin
            cnt <= {CNT_W{1'b0}};
        end else begin
            if (valid_in) begin
                if (cnt == FFT_N - 1) begin
                    cnt <= {CNT_W{1'b0}};
                end else begin
                    cnt <= cnt + 1'b1;
                end
            end
        end
    end

endmodule
