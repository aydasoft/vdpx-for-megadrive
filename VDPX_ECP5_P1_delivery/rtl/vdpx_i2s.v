// MD-VDPX I2S master (Philips format), 48 kHz, 64 BCLK per frame.
//   - TX: 16-bit stereo to a DAC / I2S amplifier (e.g. the Tang Nano 20K MAX98357A)
//   - RX: 24-bit stereo from an ADC (e.g. PCM1808) digitizing the Mega Drive's own
//         audio (expansion port SL2/SR2 on Model 2, headphone jack on Model 1)
//
// One frame = FR_DEN/FR_NUM clk = exactly 48 kHz on average. 128 BCLK half-periods are
// spread over the frames with a fractional accumulator (step 128*FR_NUM, modulus FR_DEN);
// a frame starts when the half-period index wraps from 127 to 0.
//   Tang/M4.2  clk = 50.4 MHz: FR_NUM = 1, FR_DEN = 1050 -> every frame 1050 clk (default,
//              cycle-identical to M4.2).
//   ECP5-P1    clk = 50.0 MHz: FR_NUM = 3, FR_DEN = 3125 -> frames of 1042/1042/1041 clk.
// On hardware an audio PLL clock can replace this; the frame timing stays.
//
// 'tick' pulses on the first cycle of every frame. tx_l/tx_r are latched at tick.
// rx_l/rx_r hold the last complete frame received, updated at tick.
module vdpx_i2s #(
    parameter FR_NUM = 1,
    parameter FR_DEN = 1050
) (
    input             clk,
    input             rst,
    output            tick,
    output reg        bclk,
    output reg        lrck,
    output reg        dout,
    input             din,
    input      [15:0] tx_l,
    input      [15:0] tx_r,
    output reg [15:0] rx_l,
    output reg [15:0] rx_r
);
    localparam [15:0] STEP = 16'd128 * FR_NUM;
    localparam [15:0] DEN  = FR_DEN;
    reg        tick_r;         // first cycle of a frame
    reg [15:0] acc;            // half-period accumulator
    reg  [6:0] half;           // half-period index 0..127
    reg [63:0] tx_sh;
    reg [23:0] rx_lsh, rx_rsh;

    assign tick = tick_r;

    // next half-period index at this cycle
    wire [15:0] acc_n  = acc + STEP;
    wire        adv    = (acc_n >= DEN);
    wire  [5:0] bitn   = half[6:1];       // current bit 0..63

    always @(posedge clk) begin
        if (rst) begin
            tick_r <= 1'b1; acc <= 0; half <= 0;
            bclk <= 0; lrck <= 0; dout <= 0;
            rx_l <= 0; rx_r <= 0; tx_sh <= 0; rx_lsh <= 0; rx_rsh <= 0;
        end else begin
            tick_r <= adv && (half == 7'd127);
            if (adv) begin
                acc <= acc_n - DEN;
                half <= half + 7'd1;            // 127 -> 0 starts the next frame
            end else begin
                acc <= acc_n;
            end

            // frame start: latch TX word, publish RX word
            if (tick) begin
                // I2S: MSB one bit after the LRCK edge -> bit 0 carries nothing useful
                tx_sh <= {1'b0, tx_l, 15'd0, 1'b0, tx_r, 15'd0};
                rx_l  <= rx_lsh[23:8];
                rx_r  <= rx_rsh[23:8];
            end

            // outputs follow the half-period index (registered)
            bclk <= half[0];
            lrck <= bitn[5];
            dout <= tx_sh[63 - bitn];

            // RX: sample on the BCLK rising edge (half becomes odd)
            if (adv && (half[0] == 1'b0)) begin
                if (bitn >= 6'd1 && bitn <= 6'd24)  rx_lsh <= {rx_lsh[22:0], din};
                if (bitn >= 6'd33 && bitn <= 6'd56) rx_rsh <= {rx_rsh[22:0], din};
            end
        end
    end
endmodule
