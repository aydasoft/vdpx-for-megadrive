`timescale 1ns/1ps
module tb_lvc245;
tri [7:0] md,fpga;
reg pwr=1,oe=1,dir=1,cpu_en=0,fpga_en=0;
reg [7:0] cpu_data=8'ha5,fpga_data=8'h5a;
assign md=cpu_en?cpu_data:8'bz;
assign fpga=fpga_en?fpga_data:8'bz;
lvc245 u(pwr,oe,dir,md,fpga);
integer conflicts=0;
// Explicit driver-intent detector also sees contention independent of X resolution.
wire conflict=pwr && !oe && !dir && cpu_en && fpga_en && (cpu_data!=fpga_data);
initial begin
 #30; if(md!==8'bz || fpga!==8'bz) $fatal(1,"OE tristate");
 cpu_en=1;oe=0; #30; if(fpga!==cpu_data) $fatal(1,"A to B");
 // Fixed write direction: even an erroneous FPGA driver cannot drive MD through 245.
 fpga_en=1; #30; if(md!==cpu_data || fpga!==8'bx) $fatal(1,"isolation/X detection");
 fpga_en=0; oe=1; #30; cpu_en=0;dir=0;fpga_en=1; #30;oe=0;
 #30; if(md!==fpga_data) $fatal(1,"hypothetical B to A");
 cpu_en=1; #30;
 if(!conflict || md!==8'bx) $fatal(1,"missed opposing drivers"); conflicts=conflicts+1;
 oe=1; #30; if(md!==cpu_data) $fatal(1,"release");
 pwr=0;oe=0; #30; if(md!==cpu_data) $fatal(1,"power-off isolation");
 $display("PASS LVC245: directions=2 OE=1 powered_off=1 intentional_contentions_detected=%0d; physical_reads=DISABLED",conflicts);
 $finish;
end
endmodule
