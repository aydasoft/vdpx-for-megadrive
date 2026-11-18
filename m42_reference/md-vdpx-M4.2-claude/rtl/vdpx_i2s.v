// MD-VDPX I2S master (Philips format), 48 kHz, 64 BCLK per frame.
//   - TX: 16-bit stereo to a DAC / I2S amplifier (e.g. the Tang Nano 20K MAX98357A)
//   - RX: 24-bit stereo from an ADC (e.g. PCM1808) digitizing the Mega Drive's own
//         audio (expansion port SL2/SR2 on Model 2, headphone jack on Model 1)
//
// clk = 50.4 MHz. One frame = 1050 clk = exactly 48 kHz. 128 BCLK half-periods are
// spread over the frame with a fractional accumulator (16 or 17 clk per bit).
// On hardware (M4) an audio PLL clock can replace this; the frame timing stays.
//
// 'tick' pulses on the first cycle of every frame. tx_l/tx_r are latched at tick.
// rx_l/rx_r hold the last complete frame received, updated at tick.
module vdpx_i2s (
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
    reg [10:0] cyc;            // 0..1049
    reg [10:0] acc;            // half-period accumulator
    reg  [6:0] half;           // half-period index 0..127
    reg [63:0] tx_sh;
    reg [23:0] rx_lsh, rx_rsh;

    assign tick = (cyc == 11'd0);

    // next half-period index at this cycle
    wire [11:0] acc_n  = {1'b0, acc} + 12'd128;
    wire        adv    = (acc_n >= 12'd1050);
    wire  [5:0] bitn   = half[6:1];       // current bit 0..63

    always @(posedge clk) begin
        if (rst) begin
            cyc <= 0; acc <= 0; half <= 0;
            bclk <= 0; lrck <= 0; dout <= 0;
            rx_l <= 0; rx_r <= 0; tx_sh <= 0; rx_lsh <= 0; rx_rsh <= 0;
        end else begin
            cyc <= (cyc == 11'd1049) ? 11'd0 : cyc + 11'd1;
            if (cyc == 11'd1049) begin
                acc <= 0; half <= 0;
            end else if (adv) begin
                acc <= acc_n[10:0] - 11'd1050;
                half <= half + 7'd1;
            end else begin
                acc <= acc_n[10:0];
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
            if (adv && (half[0] == 1'b0) && cyc != 11'd1049) begin
                if (bitn >= 6'd1 && bitn <= 6'd24)  rx_lsh <= {rx_lsh[22:0], din};
                if (bitn >= 6'd33 && bitn <= 6'd56) rx_rsh <= {rx_rsh[22:0], din};
            end
        end
    end
endmodule
