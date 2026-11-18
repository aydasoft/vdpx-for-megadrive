// MD-VDPX - restrições de timing (Gowin EDA)
create_clock -name clk27   -period 37.037 [get_ports {clk27}]
create_clock -name clk_sys -period 19.841 [get_nets {clk_sys}]
create_clock -name clk_pix -period 39.683 [get_nets {clk_pix}]
create_clock -name clk126  -period 7.937  [get_nets {clk126}]
// sistema e pixel vêm de PLLs diferentes: só se falam pela FIFO assíncrona
set_clock_groups -asynchronous -group [get_clocks {clk_sys}] -group [get_clocks {clk_pix clk126}]
