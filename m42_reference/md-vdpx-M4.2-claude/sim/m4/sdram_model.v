// Behavioral model of the GW2AR-18 embedded SDRAM (2M x 32, 4 banks, CL2)
// with protocol and timing checks. Clocked by the SDRAM clock pin, which is
// the inverted system clock: commands are sampled on the system clock's
// falling edge. Memory size can be reduced for simulation (AW_SIM).
module sdram_model #(
    parameter T_RCD  = 2,      // ACT -> READ/WRITE, cycles
    parameter T_RC   = 4,      // ACT -> ACT (same bank)
    parameter T_RFC  = 4,
    parameter T_RP   = 2,
    parameter REF_MAX = 800,   // max cycles between AUTO REFRESH after init
    parameter INIT_MIN = 100   // min cycles with CKE high before the first command
) (
    input             sd_clk,
    input             cke,
    input             cs_n, ras_n, cas_n, we_n,
    input       [1:0] ba,
    input      [10:0] a,
    input       [3:0] dqm,
    input      [31:0] dq_in,          // from controller
    output reg [31:0] dq_out,         // to controller
    output reg [31:0] errors
);
    reg [31:0] mem [0:(1<<21)-1];     // 2M x 32 = 8 MB
    integer i;
    initial begin
        for (i = 0; i < (1<<21); i = i + 1) mem[i] = 32'h0;
        errors = 0; dq_out = 0;
    end

    reg  [3:0] bank_open;
    reg [10:0] bank_row [0:3];
    reg [31:0] t_act [0:3];
    reg [31:0] t_now, t_ref, t_cke;
    reg [31:0] t_pre_done [0:3];
    reg        mode_set, init_ok;
    reg  [2:0] cl;
    reg [31:0] rd_data_q [0:3];
    reg  [3:0] rd_valid;
    integer b;

    initial begin
        bank_open = 0; t_now = 0; t_ref = 0; t_cke = 0; mode_set = 0; init_ok = 0; cl = 0; rd_valid = 0;
        for (b = 0; b < 4; b = b + 1) begin t_act[b] = 0; t_pre_done[b] = 0; end
    end

    task err(input [8*48-1:0] msg);
        begin
            if (errors < 20) $display("SDRAM ERRO @%0d: %0s", t_now, msg);
            errors = errors + 1;
        end
    endtask

    wire [3:0] c = {cs_n, ras_n, cas_n, we_n};
    always @(posedge sd_clk) begin
        t_now <= t_now + 1;
        // read data (CAS latency 2): valid between edge N+1 (+tAC) and edge N+2 (+tOH)
        // after the READ at edge N; outside that window the bus holds garbage.
        rd_valid <= {rd_valid[2:0], 1'b0};
        if (rd_valid[0]) dq_out <= rd_data_q[0];
        else dq_out <= 32'hDEADBEEF;
        if (!cke) t_cke <= t_now + 1;
        if (cke && !cs_n) begin
            case (c)
            4'b0011: begin // ACTIVE
                if (!mode_set) err("ACTIVE antes do MODE REGISTER");
                if (bank_open[ba]) err("ACTIVE em banco aberto");
                if (t_now - t_act[ba] < T_RC && t_act[ba] != 0) err("tRC violado");
                if (t_now < t_pre_done[ba]) err("tRP violado");
                bank_open[ba] <= 1'b1; bank_row[ba] <= a; t_act[ba] <= t_now;
            end
            4'b0101, 4'b0100: begin // READ / WRITE
                if (!bank_open[ba]) err("READ/WRITE em banco fechado");
                if (t_now - t_act[ba] < T_RCD) err("tRCD violado");
                if (a[10]) begin
                    bank_open[ba] <= 1'b0;
                    t_pre_done[ba] <= t_now + T_RP + ((c == 4'b0100) ? 2 : 1);
                end
                if (c == 4'b0100) begin
                    // write with byte masks
                    if (!dqm[0]) mem[{bank_row[ba], ba, a[7:0]}][7:0]   <= dq_in[7:0];
                    if (!dqm[1]) mem[{bank_row[ba], ba, a[7:0]}][15:8]  <= dq_in[15:8];
                    if (!dqm[2]) mem[{bank_row[ba], ba, a[7:0]}][23:16] <= dq_in[23:16];
                    if (!dqm[3]) mem[{bank_row[ba], ba, a[7:0]}][31:24] <= dq_in[31:24];
                end else begin
                    if (cl != 3'd2) err("CAS latency diferente de 2");
                    rd_data_q[0] <= mem[{bank_row[ba], ba, a[7:0]}];
                    rd_valid[0] <= 1'b1;
                end
            end
            4'b0010: begin // PRECHARGE
                if (a[10]) begin
                    bank_open <= 0;
                    for (b = 0; b < 4; b = b + 1) t_pre_done[b] <= t_now + T_RP;
                end else begin
                    bank_open[ba] <= 1'b0; t_pre_done[ba] <= t_now + T_RP;
                end
            end
            4'b0001: begin // AUTO REFRESH
                if (bank_open != 0) err("REFRESH com banco aberto");
                if (init_ok && t_now - t_ref > REF_MAX) err("intervalo de refresh longo demais");
                t_ref <= t_now;
                for (b = 0; b < 4; b = b + 1) t_pre_done[b] <= t_now + T_RFC;
            end
            4'b0000: begin // LOAD MODE REGISTER
                if (bank_open != 0) err("MODE REGISTER com banco aberto");
                if (t_now - t_cke < INIT_MIN) err("inicialização curta demais");
                if (a[2:0] != 3'b000) err("burst length diferente de 1");
                cl <= a[6:4];
                mode_set <= 1'b1; init_ok <= 1'b1;
            end
            default: ;
            endcase
        end
        if (init_ok && t_now - t_ref > REF_MAX + 5) begin
            err("refresh atrasado");
            t_ref <= t_now;
        end
    end
endmodule
