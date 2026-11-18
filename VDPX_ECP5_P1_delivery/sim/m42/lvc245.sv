`timescale 1ns/1ps
// Functional 4-state model; 6ns illustrative delay, NOT analog sign-off.
module lvc245(input powered, input oe_n, input dir, inout [7:0] a,b);
assign #6 a = powered && !oe_n && !dir ? b : 8'bz;
assign #6 b = powered && !oe_n && dir ? a : 8'bz;
endmodule
