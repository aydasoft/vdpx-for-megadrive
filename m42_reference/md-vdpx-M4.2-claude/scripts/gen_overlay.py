#!/usr/bin/env python3
"""Gera rtl/board/vdpx_overlay.v: caixa de texto de diagnóstico sobre o vídeo
(linhas de texto 21..29 de 30, 40 colunas, fonte 5x7 ampliada 2x).

Os campos vêm da sonda CN2 e são congelados no início de cada vblank."""
import sys
from font5x7 import F, CHARS, glyph_rows

OUT = sys.argv[1] if len(sys.argv) > 1 else "../rtl/board/vdpx_overlay.v"
TOP_ROW = 21

# (texto, campos): {nome:tipo}  tipos: h8 h4 h1 d3 d2 f (S/N)
ROWS = [
    "MD-VDPX M4.2 SONDA CN2  AUTOTESTE:{st:f} MD:{md:f}",
    "ESCRITAS ACEITAS {n_acc:h8}  PERDIDAS {n_drop:h4}",
    "FIFO MAX {fifo_hw:d2}   ULTIMA A1200{last_off:h1}={last_d:h4}",
    "CICLO C/ FDWR {n_wr:h8} C/ CAS0 {n_wr_cas0:h8}",
    "CICLO S/ FDWR {n_rd:h8} C/ CAS0 {n_rd_cas0:h8}",
    "FDC BAIXO: ESC {fdcw_min:d3}-{fdcw_max:d3} SEM FDWR {fdcr_min:d3}-{fdcr_max:d3}",
    "FDC>FDWR {f2w_min:d3}-{f2w_max:d3}  LARGURA FDWR {ww_min:d3}-{ww_max:d3}",
    "FDC>CAS0 {f2c_min:d3}-{f2c_max:d3}  FRES:{fres_now:f} PULSOS {n_fres:h4}",
    "CAS0 FORA {n_cas_out:h8}  (UNIDADE 19.8 NS)",
]
WIDTHS = {"h8": 32, "h4": 16, "h1": 4, "d3": 8, "d2": 5, "f": 1}
NDIG = {"h8": 8, "h4": 4, "h1": 1, "d3": 3, "d2": 2, "f": 1}
G = {c: i for i, c in enumerate(CHARS)}

fields = {}           # nome -> tipo
cells = []            # por linha: lista de 40 (('c', glifo) | ('s', slot))
slots = []            # (campo, tipo, dígito)
for r in ROWS:
    out = []
    i = 0
    while i < len(r):
        if r[i] == "{":
            j = r.index("}", i)
            name, kind = r[i + 1:j].split(":")
            fields[name] = kind
            for k in range(NDIG[kind]):
                out.append(("s", len(slots)))
                slots.append((name, kind, k))
            i = j + 1
        else:
            out.append(("c", G[r[i]]))
            i += 1
    assert len(out) <= 40, (r, len(out))
    out += [("c", 0)] * (40 - len(out))
    cells.append(out)
assert len(slots) < 128

v = []
v.append("// GERADO por scripts/gen_overlay.py -- não editar à mão.")
v.append("// Overlay de diagnóstico (M4.2): texto da sonda CN2 sobre o vídeo da VDPX.")
v.append("// Domínio do sistema; segue o fluxo de vídeo da VDPX (um pixel por vid_ce).")
v.append("module vdpx_overlay (")
v.append("    input             clk, rst, enable,")
v.append("    input       [7:0] in_r, in_g, in_b,")
v.append("    input             in_hs_n, in_vs_n, in_de, in_ce,")
v.append("    output reg  [7:0] out_r, out_g, out_b,")
v.append("    output reg        out_hs_n, out_vs_n, out_de,")
v.append("    output reg        out_ce,")
ports = []
for name, kind in fields.items():
    w = 3 if name == "last_off" else (1 if kind == "f" else WIDTHS[kind] if kind[0] == "h" else 8)
    if kind == "d2":
        w = 5
    ports.append(f"    input [{w - 1}:0] f_{name}")
v.append(",\n".join(ports))
v.append(");")
v.append("""
    // ---- position of the incoming pixel (HSYNC falls at x=656, VSYNC at y=490)
    reg [9:0] hc, vc;
    reg hs_d = 1'b1, vs_d = 1'b1;
    wire hs_fall = hs_d & ~in_hs_n, vs_fall = vs_d & ~in_vs_n;
    wire [9:0] x = hs_fall ? 10'd656 : hc;
    wire [9:0] y = vs_fall ? 10'd490 : vc;
    always @(posedge clk) if (in_ce) begin
        hs_d <= in_hs_n; vs_d <= in_vs_n;
        if (x == 10'd799) begin hc <= 0; vc <= (y == 10'd524) ? 10'd0 : y + 10'd1; end
        else begin hc <= x + 10'd1; vc <= y; end
    end

    function [3:0] dec_h(input [7:0] n); dec_h = n / 8'd100; endfunction
    function [3:0] dec_t(input [7:0] n); dec_t = (n / 8'd10) % 8'd10; endfunction
    function [3:0] dec_o(input [7:0] n); dec_o = n % 8'd10; endfunction
""")
# snapshot registers
v.append("    // ---- snapshot at the start of vblank (no flicker)")
for name, kind in fields.items():
    if kind in ("d3", "d2"):
        v.append(f"    reg [11:0] s_{name};")
    elif name == "last_off":
        v.append(f"    reg [3:0] s_{name};")
    elif kind == "f":
        v.append(f"    reg s_{name};")
    else:
        v.append(f"    reg [{WIDTHS[kind] - 1}:0] s_{name};")
v.append("    always @(posedge clk) if (in_ce && x == 10'd0 && y == 10'd480) begin")
for name, kind in fields.items():
    if kind in ("d3", "d2"):
        src = f"f_{name}" if kind == "d3" else f"{{3'd0, f_{name}}}"
        v.append(f"        s_{name} <= {{dec_h({src}), dec_t({src}), dec_o({src})}};")
    elif name == "last_off":
        v.append(f"        s_{name} <= {{f_{name}, 1'b0}};")
    else:
        v.append(f"        s_{name} <= f_{name};")
v.append("    end")

# template function
v.append("""
    // ---- template: glyph (0..63) or slot (64 + n)
    function [7:0] tmpl(input [3:0] row, input [5:0] col);
        case ({row, col})""")
for ri, row in enumerate(cells):
    for ci, (t, val) in enumerate(row):
        code = val if t == "c" else 0x80 | val
        if code != 0:
            v.append(f"            {{4'd{ri}, 6'd{ci}}}: tmpl = 8'd{code};")
v.append("            default: tmpl = 8'd0;\n        endcase\n    endfunction")

# slot -> glyph
v.append("""
    function [5:0] hexg(input [3:0] n); hexg = {2'b00, n} + 6'd1; endfunction""")
v.append(f"    function [5:0] slotg(input [6:0] sl);\n        case (sl)")
for i, (name, kind, k) in enumerate(slots):
    if kind[0] == "h":
        nd = NDIG[kind]
        lsb = (nd - 1 - k) * 4
        expr = f"{{2'b00, s_{name}[{lsb + 3}:{lsb}]}} + 6'd1"
    elif kind in ("d3", "d2"):
        nd = NDIG[kind]
        lsb = (nd - 1 - k) * 4
        expr = f"{{2'b00, s_{name}[{lsb + 3}:{lsb}]}} + 6'd1"
    else:
        expr = f"(s_{name} ? 6'd{G['S']} : 6'd{G['N']})"
    v.append(f"            7'd{i}: slotg = {expr};")
v.append("            default: slotg = 6'd0;\n        endcase\n    endfunction")

# font
v.append("\n    function [7:0] font(input [5:0] g, input [2:0] r);\n        case ({g, r})")
for gi, c in enumerate(CHARS):
    for ri, bits in enumerate(glyph_rows(c)):
        if bits:
            v.append(f"            {{6'd{gi}, 3'd{ri}}}: font = 8'h{bits:02X};")
v.append("            default: font = 8'h00;\n        endcase\n    endfunction")

v.append(f"""
    // ---- 3-stage pipeline (one stage per pixel), video delayed to match
    localparam [4:0] TOP = 5'd{TOP_ROW};
    wire [4:0] trow = y[8:4];
    wire       in_box0 = enable && (y < 10'd480) && (trow >= TOP) && (x < 10'd640);
    reg  [7:0] code1; reg [2:0] gy1, gx1; reg box1, title1;
    reg  [5:0] gl2;   reg [2:0] gy2, gx2; reg box2, title2;
    reg  [26:0] d1, d2;
    wire [3:0] trel = trow - TOP;
    wire [7:0] frow = font(gl2, gy2);
    always @(posedge clk) begin
        out_ce <= in_ce;
        if (in_ce) begin
            // stage 1: template
            code1 <= tmpl(trel, x[9:4]);
            gy1 <= y[3:1]; gx1 <= x[3:1]; box1 <= in_box0; title1 <= (trel == 4'd0);
            d1 <= {{in_r, in_g, in_b, in_hs_n, in_vs_n, in_de}};
            // stage 2: slot -> glyph
            gl2 <= code1[7] ? slotg(code1[6:0]) : code1[5:0];
            gy2 <= gy1; gx2 <= gx1; box2 <= box1; title2 <= title1;
            d2 <= d1;
            // stage 3: font pixel and mix
            out_hs_n <= d2[2]; out_vs_n <= d2[1]; out_de <= d2[0];
            if (box2) begin
                if (frow[3'd7 - gx2]) begin
                    out_r <= 8'hFF; out_g <= title2 ? 8'hE0 : 8'hFF; out_b <= title2 ? 8'h40 : 8'hFF;
                end else begin
                    out_r <= 8'h08; out_g <= 8'h10; out_b <= 8'h38;
                end
            end else begin
                out_r <= d2[26:19]; out_g <= d2[18:11]; out_b <= d2[10:3];
            end
        end
    end
endmodule""")
open(OUT, "w").write("\n".join(v) + "\n")
print(OUT, len(slots), "dígitos,", len(fields), "campos")
# export for the testbench: font, glyph table and field positions (OCR of the HDMI image)
hdr = ["// GERADO por scripts/gen_overlay.py", "#pragma once", "#include <cstdint>",
       f"static const int OVL_TOP = {TOP_ROW};",
       f"static const char OVL_CHARS[] = \"{''.join(CHARS)}\";",
       "static const uint8_t OVL_FONT[][8] = {"]
for c in CHARS:
    hdr.append("    {" + ", ".join(f"0x{b:02X}" for b in glyph_rows(c)) + "},")
hdr.append("};")
hdr.append("struct OvlField { const char *name; const char *kind; int row, col, ndig; };")
hdr.append("static const OvlField OVL_FIELDS[] = {")
for ri, row in enumerate(cells):
    seen = set()
    for ci, (t, val) in enumerate(row):
        if t == "s":
            name, kind, k = slots[val]
            if k == 0:
                hdr.append(f'    {{"{name}", "{kind}", {ri}, {ci}, {NDIG[kind]}}},')
hdr.append("};")
open(OUT.replace(".v", "_tb.h").replace("rtl/board", "sim/m4"), "w").write("\n".join(hdr) + "\n")
