#!/bin/bash
# MD-VDPX ECP5-P1: complete reproducible run (simulation, synthesis, P&R x3, bitstream,
# reports). Every step logs its command, exit code and output under logs/.
# Tools: verilator, iverilog, m68k-linux-gnu-gcc (or m68k-elf), python3 + pillow, and
# yosys / nextpnr-ecp5 / ecppack (native) or the YoWASP packages (set YOWASP=1 and put
# yowasp-* on PATH: pip install yowasp-yosys yowasp-nextpnr-ecp5).
set -u
cd "$(dirname "$0")/.."
L=logs; mkdir -p $L/regression $L/ecp5_sim $L/ecp5_build $L/ecp5_unit
SUMMARY=$L/RUN_SUMMARY.txt
: > $SUMMARY
step() {   # step <name> <logfile> <command...>
    local name=$1 log=$2; shift 2
    echo "=== $name" | tee -a $SUMMARY
    echo "\$ $*" > "$log"
    local t0=$(date +%s)
    "$@" >> "$log" 2>&1
    local rc=$?
    echo "exit $rc ($(( $(date +%s) - t0 )) s)" >> "$log"
    echo "    exit $rc  ($log)" | tee -a $SUMMARY
    return $rc
}
{
  echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "host: $(uname -srm)"
  verilator --version; iverilog -V 2>&1 | head -1
  (m68k-linux-gnu-gcc --version 2>/dev/null || m68k-elf-gcc --version) | head -1
  python3 --version
  if [ "${YOWASP:-0}" = 1 ]; then Y=yowasp-yosys; N=yowasp-nextpnr-ecp5; P=yowasp-ecppack; else Y=yosys; N=nextpnr-ecp5; P=ecppack; fi
  $Y -V; $N --version 2>&1 | head -1; $P --help 2>&1 | head -1
  pip list 2>/dev/null | grep -i yowasp
  [ -d ext/fx68k/.git ] && echo "fx68k: $(git -C ext/fx68k rev-parse HEAD)"
} > $L/versions.txt 2>&1

M="make YOWASP=${YOWASP:-0}"
step "M4.2 regression (Tang parameters, modified RTL)" $L/regression/all_tests_tangparams.log make all_tests
step "ECP5 lint (Verilator -Wall)"                    $L/ecp5_unit/ecp5_lint.log make ecp5_lint
step "ECP5 unit tests (SDRAM RMW, HDMI/TMDS serial)"  $L/ecp5_unit/ecp5_unit.log $M ecp5_unit
step "17 scenes at 50 MHz via RMW SDRAM"              $L/ecp5_sim/test50.log make test50
step "fx68k + write-only adapter at 50 MHz (M2WO50)"  $L/ecp5_sim/m2wo50.log make m2wo50
step "ECP5 board simulation (3 runs)"                 $L/ecp5_sim/ecp5_boardsim.log make ecp5_boardsim
step "ECP5 synthesis"                                 $L/ecp5_build/make_ecp5_synth.log $M ecp5_synth
rm -f build_ecp5/pnr_exit.txt
step "ECP5 place & route, seeds ${ECP5_SEEDS:-1 2 3}"  $L/ecp5_build/make_ecp5_pnr.log $M ecp5_pnr
step "ECP5 bitstream (ecppack)"                        $L/ecp5_build/make_ecp5_bitstream.log $M ecp5_bitstream
step "ECP5 report"                                     $L/ecp5_build/make_ecp5_report.log $M ecp5_report
step "ECP5 static audit (pins, banks, clocks, netlist)" $L/ecp5_build/ecp5_audit.log python3 scripts/ecp5_audit.py
cp build_ecp5/synth.log build_ecp5/synth_stat.txt build_ecp5/pnr_s*.log build_ecp5/report_s*.json build_ecp5/pnr_exit.txt $L/ecp5_build/ 2>/dev/null
gzip -f $L/ecp5_build/report_s*.json
echo "=== done" | tee -a $SUMMARY
