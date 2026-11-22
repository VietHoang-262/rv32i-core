`timescale 1ns/1ps
// Simulation-only ordered memory. ready denotes COMPLETION, including zero delay.
// Addresses retain byte offset; rdata is the containing aligned 32-bit word.
module tb_latency_memory #(
    parameter integer WORDS = 1024,
    parameter bit READ_ONLY = 0
) (
    input logic clk_i, rst_ni,
    input logic req_i, we_i,
    input logic [3:0] be_i,
    input logic [31:0] addr_i, wdata_i,
    output logic ready_o,
    output logic [31:0] rdata_o,
    output logic error_o,
    input wire signed [31:0] latency_mode_i, seed_i,
    input logic noise_i,
    input logic [31:0] fault_addr_i
);
    logic [31:0] mem [0:WORDS-1];
    logic pending;
    logic [31:0] saved_addr, saved_wdata;
    logic saved_we;
    logic [3:0] saved_be;
    integer countdown, sequence_index;
    integer selected_delay;
    integer lane;
    integer stall_cycles, completions;
    logic completion, access_error;

    always_comb begin
        case (latency_mode_i)
            0: selected_delay = 0;
            1: selected_delay = 1;
            3: selected_delay = 31;
            4: selected_delay = 8 + (sequence_index * 11 + seed_i) % 31;
            default: selected_delay = (sequence_index * 5 + seed_i) % 7;
        endcase
        completion = rst_ni && req_i && ((pending && countdown == 0) || (!pending && selected_delay == 0));
        // Idle ready and invalid error/data before completion are legal: the
        // master may sample read data/error only when req && ready is true.
        ready_o = completion || (rst_ni && noise_i && !req_i);
        access_error = addr_i >= WORDS * 4 || addr_i == fault_addr_i;
        error_o = (noise_i && !completion) ? 1'b1 : access_error;
        rdata_o = noise_i && !completion ? (32'hbad0_cafe ^ sequence_index) : 32'b0;
        if ((!noise_i || completion) && addr_i < WORDS * 4)
            rdata_o = mem[addr_i >> 2];
    end
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            pending <= 0;
            countdown <= 0;
            sequence_index <= 0;
            saved_addr <= 0;
            saved_wdata <= 0;
            saved_be <= 0;
            saved_we <= 0;
            stall_cycles <= 0;
            completions <= 0;
        end else begin
            if (req_i && !ready_o) stall_cycles <= stall_cycles + 1;
            if (req_i) begin
                if (^{addr_i,we_i,be_i,wdata_i} === 1'bx)
                    $fatal(1,"unknown memory request payload");
                if (READ_ONLY) begin
                    if (we_i || be_i != 4'b1111 || addr_i[1:0] != 0)
                        $fatal(1,"invalid instruction request");
                end else begin
                    case (be_i)
                        4'b0001,4'b0010,4'b0100,4'b1000:
                            if (be_i != (4'b0001 << addr_i[1:0]))
                                $fatal(1,"byte lane disagrees with effective address");
                        4'b0011,4'b1100:
                            if (addr_i[0] || be_i != (4'b0011 << addr_i[1:0]))
                                $fatal(1,"halfword lane/alignment disagrees with address");
                        4'b1111:
                            if (addr_i[1:0] != 0) $fatal(1,"word request misaligned");
                        default: $fatal(1,"invalid memory byte-enable");
                    endcase
                end
            end
            if (pending) begin
                if (!req_i) $fatal(1, "request dropped before completion");
                if ({addr_i,we_i,be_i,wdata_i} !== {saved_addr,saved_we,saved_be,saved_wdata})
                    $fatal(1,"request payload changed while stalled");
            end
            if (req_i && ready_o) begin
                pending <= 0;
                sequence_index <= sequence_index + 1;
                completions <= completions + 1;
                if (we_i && !error_o) begin
                    if (READ_ONLY) $fatal(1,"instruction memory write");
                    for (lane=0;lane<4;lane=lane+1)
                        if (be_i[lane]) mem[addr_i >> 2][8*lane +: 8] <= wdata_i[8*lane +: 8];
                end
            end else if (req_i) begin
                if (!pending) begin
                    pending <= 1;
                    countdown <= selected_delay - 1;
                    saved_addr <= addr_i;
                    saved_we <= we_i;
                    saved_be <= be_i;
                    saved_wdata <= wdata_i;
                end else countdown <= countdown - 1;
            end
        end
    end
endmodule
