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

    always_comb begin
        case (latency_mode_i)
            0: selected_delay = 0;
            1: selected_delay = 1;
            default: selected_delay = (sequence_index * 5 + seed_i) % 7;
        endcase
        ready_o = rst_ni && req_i && ((pending && countdown == 0) || (!pending && selected_delay == 0));
        error_o = addr_i >= WORDS * 4 || addr_i == fault_addr_i;
        rdata_o = 0;
        if (addr_i < WORDS * 4) rdata_o = mem[addr_i >> 2];
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
        end else begin
            if (pending) begin
                if (!req_i) $fatal(1, "request dropped before completion");
                if ({addr_i,we_i,be_i,wdata_i} !== {saved_addr,saved_we,saved_be,saved_wdata})
                    $fatal(1,"request payload changed while stalled");
            end
            if (req_i && ready_o) begin
                pending <= 0;
                sequence_index <= sequence_index + 1;
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
