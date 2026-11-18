// TMDS channel encoder (DVI 1.0 8b/10b + HDMI TERC4 and guard bands).
// mode: 0 = control (c), 1 = video (d), 2 = video guard, 3 = data island (TERC4 of t),
//       4 = data island guard.
// Output q is registered; bit 0 is transmitted first.
module tmds_enc #(
    parameter CH = 0                  // channel number (selects guard band symbols)
) (
    input            clk,
    input      [2:0] mode,
    input      [7:0] d,
    input      [1:0] c,
    input      [3:0] t,
    output reg [9:0] q
);
    // ---- 8b/10b video
    function [3:0] ones8(input [7:0] v);
        ones8 = v[0] + v[1] + v[2] + v[3] + v[4] + v[5] + v[6] + v[7];
    endfunction
    wire [3:0] n1d = ones8(d);
    wire use_xnor  = (n1d > 4'd4) || (n1d == 4'd4 && d[0] == 1'b0);
    wire [8:0] qm;
    assign qm[0] = d[0];
    genvar gi;
    generate for (gi = 1; gi < 8; gi = gi + 1) begin : g_qm
        assign qm[gi] = use_xnor ? ~(qm[gi-1] ^ d[gi]) : (qm[gi-1] ^ d[gi]);
    end endgenerate
    assign qm[8] = ~use_xnor;
    wire [3:0] n1q = ones8(qm[7:0]);
    wire signed [5:0] diff = $signed({2'b00, n1q}) - $signed(6'd8 - {2'b00, n1q});  // n1 - n0
    reg  signed [5:0] cnt;

    // ---- TERC4
    function [9:0] terc4(input [3:0] v);
        case (v)
            4'h0: terc4 = 10'b1010011100;  4'h1: terc4 = 10'b1001100011;
            4'h2: terc4 = 10'b1011100100;  4'h3: terc4 = 10'b1011100010;
            4'h4: terc4 = 10'b0101110001;  4'h5: terc4 = 10'b0100011110;
            4'h6: terc4 = 10'b0110001110;  4'h7: terc4 = 10'b0100111100;
            4'h8: terc4 = 10'b1011001100;  4'h9: terc4 = 10'b0100111001;
            4'hA: terc4 = 10'b0110011100;  4'hB: terc4 = 10'b1011000110;
            4'hC: terc4 = 10'b1010001110;  4'hD: terc4 = 10'b1001110001;
            4'hE: terc4 = 10'b0101100011;  default: terc4 = 10'b1011000011;
        endcase
    endfunction

    always @(posedge clk) begin
        case (mode)
        3'd1: begin
            if (cnt == 0 || diff == 0) begin
                q   <= {~qm[8], qm[8], qm[8] ? qm[7:0] : ~qm[7:0]};
                cnt <= qm[8] ? cnt + diff : cnt - diff;
            end else if ((cnt > 0 && diff > 0) || (cnt < 0 && diff < 0)) begin
                q   <= {1'b1, qm[8], ~qm[7:0]};
                cnt <= cnt + $signed({4'd0, qm[8], 1'b0}) - diff;
            end else begin
                q   <= {1'b0, qm[8], qm[7:0]};
                cnt <= cnt - $signed({4'd0, ~qm[8], 1'b0}) + diff;
            end
        end
        3'd2: begin
            q <= (CH == 1) ? 10'b0100110011 : 10'b1011001100;
            cnt <= 0;
        end
        3'd3: begin
            q <= terc4(t);
            cnt <= 0;
        end
        3'd4: begin
            q <= (CH == 0) ? terc4(t) : 10'b0100110011;
            cnt <= 0;
        end
        default: begin
            case (c)
                2'b00: q <= 10'b1101010100;
                2'b01: q <= 10'b0010101011;
                2'b10: q <= 10'b0101010100;
                default: q <= 10'b1010101011;
            endcase
            cnt <= 0;
        end
        endcase
    end
endmodule
