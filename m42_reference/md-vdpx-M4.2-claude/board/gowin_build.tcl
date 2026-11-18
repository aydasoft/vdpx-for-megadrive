# MD-VDPX - síntese/P&R com o Gowin EDA (Linux ou Windows):
#   cd board && gw_sh gowin_build.tcl
# O bitstream sai em board/impl/pnr/md_vdpx.fs
set_device GW2AR-LV18QN88C8/I7 -name GW2AR-18C
foreach f {
    ../rtl/vdpx_top.v ../rtl/vdpx_timing.v ../rtl/vdpx_render.v ../rtl/vdpx_sdpram.v
    ../rtl/vdpx_apu.v ../rtl/vdpx_i2s.v ../rtl/md_bus_adapter.v
    ../rtl/hdmi/tmds_enc.v ../rtl/hdmi/hdmi_tx.v
    ../rtl/board/async_fifo.v ../rtl/board/sdram_ctrl.v ../rtl/board/vdpx_selftest.v
    ../rtl/board/vdpx_board.v ../rtl/board/cn2_probe.v ../rtl/board/vdpx_overlay.v
    ../rtl/board/tang_top.v
} { add_file $f }
add_file tang_nano_20k.cst
add_file tang_nano_20k.sdc
set_option -top_module tang_top
set_option -verilog_std v2001
set_option -output_base_name md_vdpx
set_option -use_mspi_as_gpio 1
set_option -use_sspi_as_gpio 1
set_option -use_ready_as_gpio 1
set_option -use_done_as_gpio 1
set_option -rw_check_on_ram 1
# o ROM do autoteste ($readmemh "selftest.hex") é procurado no diretório do projeto
file copy -force ../rtl/board/selftest.hex selftest.hex
run all
