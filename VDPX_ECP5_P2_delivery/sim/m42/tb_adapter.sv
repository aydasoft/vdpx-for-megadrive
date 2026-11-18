`timescale 1ns/1ps
module tb_adapter;
reg clk=0; always #9.920635 clk=~clk;
reg rst=1, fdc=1, fdwr=1, cas0=1;
reg [2:0] a=0; reg [15:0] din=0;
wire cs,we,oe,commit,overflow,activity; wire [2:0] ca; wire [15:0] cd; wire [4:0] level;
reg ack=0, run=0; integer delay_count=0, latency=1;
md_fdc_adapter dut(.clk(clk),.rst(rst),.fdc_n(fdc),.fdwr_n(fdwr),.cas0_n(cas0),.a(a),.d_in(din),
.d_out(),.d_oe(oe),.core_cs(cs),.core_we(we),.core_addr(ca),.core_wdata(cd),.core_ack(ack),
.peek_addr(),.peek_data(16'h1234),.peek_valid(1'b1),.rd_commit(commit),.rd_commit_addr(),
.late_read(),.activity(activity),.overflow(overflow),.fifo_level(level));
integer exp[0:20000]; integer head=0,tail=0, delivered=0, rejected=0, wraps=0, reads=0;
reg [18:0] held; reg holding=0;
always @(negedge clk) begin
 ack=0;
 if (rst || !cs) delay_count=0;
 else if(run) begin
  delay_count=delay_count+1;
  if(delay_count>=latency) ack=1;
 end
end
always @(posedge clk) if (!rst) begin
 if(oe !== 0 || commit !== 0) $fatal(1,"read output active");
 if(level>16) $fatal(1,"capacity exceeded");
 if(cs && ack) begin
  if(head==tail) $fatal(1,"underflow/duplicate");
  if({ca,cd} !== exp[head][18:0]) $fatal(1,"order/data mismatch %d expected %h got %h",head,exp[head],{ca,cd});
  head=head+1; delivered=delivered+1;
 end
 if(holding && cs && {ca,cd} !== held) $fatal(1,"request changed while stalled");
 holding=cs && !ack; held={ca,cd};
end
 task reset;
 begin
 rst=1; holding=0; head=0; tail=0; run=0;
 repeat(5) @(negedge clk); rst=0;
 repeat(6) @(negedge clk);
 if(level!==0 || cs!==0 || overflow!==0) $fatal(1,"reset failed");
 end endtask
 task write_word(input integer value,input real phase,input real width,input real skew,input integer accept);
 begin
 @(negedge clk); #(phase); a=value%8; din=~value; fdc=0;
 #(skew); fdwr=0;
 #(value%26); din=value;
 if(accept) begin exp[tail]=((value%8)<<16)|(value&65535); tail=tail+1; end
 else rejected=rejected+1;
 #(width-(value%26)); fdwr=1;
 #17; fdc=1;
 #125;
 end endtask
 task drain;
 integer timeout;
 begin
 run=1; timeout=0;
 while ((head!=tail || cs || level!=0) && timeout<10000) begin @(negedge clk); timeout=timeout+1; end
 if(timeout==10000) $fatal(1,"drain timeout");
 repeat(8) @(negedge clk);
 end endtask
 integer i,j;
 initial begin
 $dumpfile("build_m42/adapter.vcd"); $dumpvars(0,tb_adapter);
 reset;
 // Every phase across a 19.84ns period, width jitter 120..140ns, skew 0..35ns.
 run=1;
 for(i=0;i<21;i=i+1) for(j=0;j<21;j=j+1) begin
  latency=1+(i+j)%7;
  write_word(i*21+j,i,120+j,(i*7+j)%36,1);
 end
 for(i=0;i<16;i=i+1) begin
  write_word(1<<i,i,130,10,1);
  write_word((~(1<<i))&65535,i,130,10,1);
 end
 drain; wraps=delivered/32;
 // Full including outstanding request; reject newest, preserve first sixteen.
 reset;
 for(i=0;i<16;i=i+1) write_word(1000+i,i%20,130,i%15,1);
 if(level!=16) $fatal(1,"capacity not 16");
 for(i=0;i<20;i=i+1) write_word(2000+i,0,130,12,0);
 if(!overflow) $fatal(1,"overflow not sticky");
 // Full + simultaneous ACK/capture: reuse freed slot without losing order.
 a=3;din=3331;fdc=0;fdwr=0;
 exp[tail]=(3<<16)|3331;tail=tail+1;
 wait(dut.capture); force ack=1;
 @(posedge clk); #1; release ack;
 #130; fdwr=1;fdc=1;#160;
 if(level!=16) $fatal(1,"full simultaneous push/pop occupancy");
 // A read following queued writes never drives or commits; CAS0 arbitrary.
 for(i=0;i<8;i=i+1) begin a=i; fdc=0; cas0=0; #130; cas0=1; fdc=1; #130; reads=reads+1; end
 latency=9; drain;
 if(!overflow) $fatal(1,"overflow lost before reset");
 // Reset while active flushes queue and requires idle before a new write.
 reset;
 write_word(42,0,130,10,1);
 fdc=0;fdwr=0;
 reset;
 #300; if(level!=0) $fatal(1,"accepted held-low reset transaction");
 fdc=1;fdwr=1; #160; run=1;
 write_word(99,3,130,20,1); drain;
 // Spurious ACK on empty cannot advance pointers.
 run=0; force ack=1; repeat(8) @(negedge clk); release ack;
 if(level!=0 || cs) $fatal(1,"empty ack underflow");
 $display("PASS M42 adapter: delivered=%0d rejected=%0d phase_width_bins=441 pointer_wraps>=%0d read_after_write=%0d reset_active=1 empty_ack=1 simultaneous_full_pop_push=1 walking_data_patterns=32",delivered,rejected,wraps,reads);
 $finish;
 end
 initial begin #2000000; $fatal(1,"watchdog"); end
endmodule
