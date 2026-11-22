// rv32i1.sv -- standalone RV32I multi-cycle CPU compilation unit.
// Top-level CPU: rv32i_core (same ports and behavior as rtl/rv32i_core.sv).
// The original package and five modules below are embedded without edits.
// Compile this file INSTEAD OF rtl/*.sv; combining both duplicates definitions.
//
// Standalone CPU smoke test (no other source or memory image required):
//   iverilog -g2012 -DRV32I1_SMOKE -s rv32i1_tb -o rv32i1.vvp rv32i1.sv
//   vvp rv32i1.vvp
//
// Full existing verification against this file (from repository root):
//   make test RTL=rv32i1.sv BUILD=build/rv32i1
// Synthesis: select rv32i_core as top; leave RV32I1_SMOKE undefined.
// ISA/EEI and interface details: docs/architecture.md, docs/integration.md.
`timescale 1ns/1ps

// ==================== BEGIN rtl/rv32i_pkg.sv ====================
`default_nettype none
package rv32i_pkg;
  typedef enum logic [3:0] {
    ALU_ADD, ALU_SUB, ALU_SLL, ALU_SLT, ALU_SLTU, ALU_XOR,
    ALU_SRL, ALU_SRA, ALU_OR, ALU_AND, ALU_PASS_B
  } alu_op_t;

  typedef enum logic [2:0] {
    BR_NONE, BR_EQ, BR_NE, BR_LT, BR_GE, BR_LTU, BR_GEU
  } branch_t;

  typedef enum logic [3:0] {
    IK_ALU, IK_LOAD, IK_STORE, IK_BRANCH, IK_LUI, IK_AUIPC,
    IK_JAL, IK_JALR, IK_FENCE, IK_ECALL, IK_EBREAK, IK_ILLEGAL
  } instr_kind_t;

  typedef struct packed {
    instr_kind_t kind;
    alu_op_t alu_op;
    branch_t branch;
    logic [31:0] imm;
    logic [4:0] rs1;
    logic [4:0] rs2;
    logic [4:0] rd;
    logic rd_we;
    logic alu_src_imm;
    logic [2:0] funct3;
  } decode_t;
endpackage
`default_nettype wire
// ===================== END rtl/rv32i_pkg.sv =====================

// ==================== BEGIN rtl/rv32i_decoder.sv ====================
`default_nettype none
module rv32i_decoder (
  input  logic [31:0] inst_i,
  output rv32i_pkg::decode_t dec_o
);
  import rv32i_pkg::*;

  logic [6:0] opcode;
  logic [6:0] funct7;
  logic [2:0] funct3;
  logic valid;

  assign opcode = inst_i[6:0];
  assign funct3 = inst_i[14:12];
  assign funct7 = inst_i[31:25];

  always_comb begin
    dec_o = '0;
    dec_o.kind = IK_ILLEGAL;
    dec_o.alu_op = ALU_ADD;
    dec_o.branch = BR_NONE;
    dec_o.rs1 = inst_i[19:15];
    dec_o.rs2 = inst_i[24:20];
    dec_o.rd = inst_i[11:7];
    dec_o.funct3 = funct3;
    valid = 1'b0;

    case (opcode)
      7'b0110011: begin // OP
        dec_o.kind = IK_ALU;
        dec_o.rd_we = 1'b1;
        case ({funct7, funct3})
          {7'b0000000,3'b000}: begin dec_o.alu_op = ALU_ADD;  valid = 1'b1; end
          {7'b0100000,3'b000}: begin dec_o.alu_op = ALU_SUB;  valid = 1'b1; end
          {7'b0000000,3'b001}: begin dec_o.alu_op = ALU_SLL;  valid = 1'b1; end
          {7'b0000000,3'b010}: begin dec_o.alu_op = ALU_SLT;  valid = 1'b1; end
          {7'b0000000,3'b011}: begin dec_o.alu_op = ALU_SLTU; valid = 1'b1; end
          {7'b0000000,3'b100}: begin dec_o.alu_op = ALU_XOR;  valid = 1'b1; end
          {7'b0000000,3'b101}: begin dec_o.alu_op = ALU_SRL;  valid = 1'b1; end
          {7'b0100000,3'b101}: begin dec_o.alu_op = ALU_SRA;  valid = 1'b1; end
          {7'b0000000,3'b110}: begin dec_o.alu_op = ALU_OR;   valid = 1'b1; end
          {7'b0000000,3'b111}: begin dec_o.alu_op = ALU_AND;  valid = 1'b1; end
          default: valid = 1'b0;
        endcase
      end
      7'b0010011: begin // OP-IMM
        dec_o.kind = IK_ALU;
        dec_o.rd_we = 1'b1;
        dec_o.alu_src_imm = 1'b1;
        dec_o.imm = {{20{inst_i[31]}}, inst_i[31:20]};
        valid = 1'b1;
        case (funct3)
          3'b000: dec_o.alu_op = ALU_ADD;
          3'b010: dec_o.alu_op = ALU_SLT;
          3'b011: dec_o.alu_op = ALU_SLTU;
          3'b100: dec_o.alu_op = ALU_XOR;
          3'b110: dec_o.alu_op = ALU_OR;
          3'b111: dec_o.alu_op = ALU_AND;
          3'b001: begin
            dec_o.alu_op = ALU_SLL;
            dec_o.imm = {27'b0, inst_i[24:20]};
            valid = (funct7 == 7'b0000000);
          end
          3'b101: begin
            dec_o.imm = {27'b0, inst_i[24:20]};
            if (funct7 == 7'b0000000) dec_o.alu_op = ALU_SRL;
            else if (funct7 == 7'b0100000) dec_o.alu_op = ALU_SRA;
            else valid = 1'b0;
          end
          default: valid = 1'b0;
        endcase
      end
      7'b0000011: begin // LOAD
        dec_o.kind = IK_LOAD;
        dec_o.rd_we = 1'b1;
        dec_o.alu_src_imm = 1'b1;
        dec_o.imm = {{20{inst_i[31]}}, inst_i[31:20]};
        case (funct3)
          3'b000,3'b001,3'b010,3'b100,3'b101: valid = 1'b1;
          default: valid = 1'b0;
        endcase
      end
      7'b0100011: begin // STORE
        dec_o.kind = IK_STORE;
        dec_o.alu_src_imm = 1'b1;
        dec_o.imm = {{20{inst_i[31]}}, inst_i[31:25], inst_i[11:7]};
        case (funct3)
          3'b000,3'b001,3'b010: valid = 1'b1;
          default: valid = 1'b0;
        endcase
      end
      7'b1100011: begin // BRANCH
        dec_o.kind = IK_BRANCH;
        dec_o.imm = {{19{inst_i[31]}}, inst_i[31], inst_i[7],
                     inst_i[30:25], inst_i[11:8], 1'b0};
        valid = 1'b1;
        case (funct3)
          3'b000: dec_o.branch = BR_EQ;
          3'b001: dec_o.branch = BR_NE;
          3'b100: dec_o.branch = BR_LT;
          3'b101: dec_o.branch = BR_GE;
          3'b110: dec_o.branch = BR_LTU;
          3'b111: dec_o.branch = BR_GEU;
          default: valid = 1'b0;
        endcase
      end
      7'b0110111: begin // LUI
        dec_o.kind = IK_LUI;
        dec_o.alu_op = ALU_PASS_B;
        dec_o.rd_we = 1'b1;
        dec_o.alu_src_imm = 1'b1;
        dec_o.imm = {inst_i[31:12], 12'b0};
        valid = 1'b1;
      end
      7'b0010111: begin // AUIPC
        dec_o.kind = IK_AUIPC;
        dec_o.rd_we = 1'b1;
        dec_o.alu_src_imm = 1'b1;
        dec_o.imm = {inst_i[31:12], 12'b0};
        valid = 1'b1;
      end
      7'b1101111: begin // JAL
        dec_o.kind = IK_JAL;
        dec_o.rd_we = 1'b1;
        dec_o.imm = {{11{inst_i[31]}}, inst_i[31], inst_i[19:12],
                     inst_i[20], inst_i[30:21], 1'b0};
        valid = 1'b1;
      end
      7'b1100111: begin // JALR
        dec_o.kind = IK_JALR;
        dec_o.rd_we = 1'b1;
        dec_o.imm = {{20{inst_i[31]}}, inst_i[31:20]};
        valid = (funct3 == 3'b000);
      end
      7'b0001111: begin // FENCE; FENCE.I is deliberately unsupported.
        dec_o.kind = IK_FENCE;
        valid = (funct3 == 3'b000);
      end
      7'b1110011: begin // No CSR or privileged encodings accepted.
        if (inst_i == 32'h0000_0073) begin
          dec_o.kind = IK_ECALL;
          valid = 1'b1;
        end else if (inst_i == 32'h0010_0073) begin
          dec_o.kind = IK_EBREAK;
          valid = 1'b1;
        end
      end
      default: valid = 1'b0;
    endcase

    if (!valid) begin
      dec_o.kind = IK_ILLEGAL;
      dec_o.rd_we = 1'b0;
      dec_o.branch = BR_NONE;
    end
  end
endmodule
`default_nettype wire
// ===================== END rtl/rv32i_decoder.sv =====================

// ==================== BEGIN rtl/rv32i_alu.sv ====================
`default_nettype none
module rv32i_alu (
  input  logic [31:0] a_i,
  input  logic [31:0] b_i,
  input  rv32i_pkg::alu_op_t op_i,
  output logic [31:0] result_o
);
  import rv32i_pkg::*;

  always_comb begin
    case (op_i)
      ALU_ADD:    result_o = a_i + b_i;
      ALU_SUB:    result_o = a_i - b_i;
      ALU_SLL:    result_o = a_i << b_i[4:0];
      ALU_SLT:    result_o = {31'b0, ($signed(a_i) < $signed(b_i))};
      ALU_SLTU:   result_o = {31'b0, (a_i < b_i)};
      ALU_XOR:    result_o = a_i ^ b_i;
      ALU_SRL:    result_o = a_i >> b_i[4:0];
      ALU_SRA:    result_o = $signed(a_i) >>> b_i[4:0];
      ALU_OR:     result_o = a_i | b_i;
      ALU_AND:    result_o = a_i & b_i;
      ALU_PASS_B: result_o = b_i;
      default:    result_o = 32'b0;
    endcase
  end
endmodule
`default_nettype wire
// ===================== END rtl/rv32i_alu.sv =====================

// ==================== BEGIN rtl/rv32i_regfile.sv ====================
`default_nettype none
module rv32i_regfile (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic [4:0] rs1_i,
  input  logic [4:0] rs2_i,
  output logic [31:0] rs1_data_o,
  output logic [31:0] rs2_data_o,
  input  logic rd_we_i,
  input  logic [4:0] rd_i,
  input  logic [31:0] rd_data_i
);
  logic [31:0] regs [0:31];
  integer i;

  assign rs1_data_o = (rs1_i == 5'd0) ? 32'b0 : regs[rs1_i];
  assign rs2_data_o = (rs2_i == 5'd0) ? 32'b0 : regs[rs2_i];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (i = 0; i < 32; i = i + 1)
        regs[i] <= 32'b0;
    end else if (rd_we_i && (rd_i != 5'd0)) begin
      regs[rd_i] <= rd_data_i;
    end
  end
endmodule
`default_nettype wire
// ===================== END rtl/rv32i_regfile.sv =====================

// ==================== BEGIN rtl/rv32i_lsu.sv ====================
`default_nettype none
module rv32i_lsu (
  input  logic [31:0] addr_i,
  input  logic [31:0] store_data_i,
  input  logic [31:0] read_data_i,
  input  logic [2:0] funct3_i,
  input  logic store_i,
  output logic misaligned_o,
  output logic [3:0] be_o,
  output logic [31:0] wdata_o,
  output logic [31:0] load_data_o
);
  logic [31:0] shifted_read;
  logic [4:0] lane_shift;

  always_comb begin
    lane_shift = {addr_i[1:0], 3'b000};
    shifted_read = read_data_i >> lane_shift;
    misaligned_o = 1'b0;
    be_o = 4'b0000;
    wdata_o = store_data_i << lane_shift;
    load_data_o = 32'b0;

    // Decode only the width bits for stores; the decoder rejects invalid
    // funct3 before this block can issue any transaction.
    if (store_i) begin
      case (funct3_i)
        3'b000: be_o = 4'b0001 << addr_i[1:0];
        3'b001: begin
          be_o = 4'b0011 << addr_i[1:0];
          misaligned_o = addr_i[0];
        end
        3'b010: begin
          be_o = 4'b1111;
          misaligned_o = |addr_i[1:0];
        end
        default: begin
          be_o = 4'b0000;
          misaligned_o = 1'b1;
        end
      endcase
    end else begin
      case (funct3_i)
        3'b000: begin
          be_o = 4'b0001 << addr_i[1:0];
          load_data_o = {{24{shifted_read[7]}}, shifted_read[7:0]};
        end
        3'b001: begin
          be_o = 4'b0011 << addr_i[1:0];
          misaligned_o = addr_i[0];
          load_data_o = {{16{shifted_read[15]}}, shifted_read[15:0]};
        end
        3'b010: begin
          be_o = 4'b1111;
          misaligned_o = |addr_i[1:0];
          load_data_o = read_data_i;
        end
        3'b100: begin
          be_o = 4'b0001 << addr_i[1:0];
          load_data_o = {24'b0, shifted_read[7:0]};
        end
        3'b101: begin
          be_o = 4'b0011 << addr_i[1:0];
          misaligned_o = addr_i[0];
          load_data_o = {16'b0, shifted_read[15:0]};
        end
        default: begin
          be_o = 4'b0000;
          misaligned_o = 1'b1;
        end
      endcase
    end
  end
endmodule
`default_nettype wire
// ===================== END rtl/rv32i_lsu.sv =====================

// ==================== BEGIN rtl/rv32i_core.sv ====================
`default_nettype none
module rv32i_core #(
    parameter logic [31:0] RESET_PC = 32'h0000_0000
) (
    input  logic clk_i,
    input  logic rst_ni,
    output logic imem_req,
    input  logic imem_ready,
    output logic [31:0] imem_addr,
    input  logic [31:0] imem_rdata,
    input  logic imem_error,
    output logic dmem_req,
    input  logic dmem_ready,
    output logic dmem_we,
    output logic [3:0] dmem_be,
    output logic [31:0] dmem_addr,
    output logic [31:0] dmem_wdata,
    input  logic [31:0] dmem_rdata,
    input  logic dmem_error,
    output logic halted,
    output logic fault_valid,
    output logic [3:0] fault_cause,
    output logic [31:0] fault_pc,
    output logic [31:0] fault_tval,
    output logic event_ecall,
    output logic event_ebreak,
    output logic retire_valid,
    output logic [31:0] retire_pc,
    output logic [31:0] retire_inst,
    output logic [4:0] retire_rd,
    output logic [31:0] retire_wdata,
    output logic retire_rd_we
);
    import rv32i_pkg::*;

    typedef enum logic [3:0] {
        FETCH_REQ, FETCH_WAIT, DECODE, EXECUTE,
        MEM_REQ, MEM_WAIT, WRITEBACK, HALTED
    } state_t;
    state_t state_q;
    decode_t dec;
    logic [31:0] pc_q, inst_q, rs1_q, rs2_q;
    logic [31:0] rs1_data, rs2_data, alu_b, alu_result;
    logic [31:0] next_pc_q, result_q;
    logic [31:0] mem_addr_q, mem_wdata_q;
    logic [3:0] mem_be_q;
    logic mem_we_q, rf_we;
    logic branch_taken;
    logic [31:0] control_target, effective_addr;
    logic lsu_misaligned;
    logic [3:0] lsu_be;
    logic [31:0] lsu_wdata, lsu_load;
    logic [31:0] lsu_addr;
    logic lsu_store;

    rv32i_decoder u_decoder (.inst_i(inst_q), .dec_o(dec));
    rv32i_regfile u_regfile (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .rs1_i(dec.rs1), .rs2_i(dec.rs2),
        .rs1_data_o(rs1_data), .rs2_data_o(rs2_data),
        .rd_we_i(rf_we), .rd_i(dec.rd), .rd_data_i(result_q)
    );
    assign alu_b = dec.alu_src_imm ? dec.imm : rs2_q;
    rv32i_alu u_alu (
        .a_i(rs1_q), .b_i(alu_b), .op_i(dec.alu_op), .result_o(alu_result)
    );
    assign effective_addr = rs1_q + dec.imm;
    assign lsu_addr = (state_q == EXECUTE) ? effective_addr : mem_addr_q;
    assign lsu_store = dec.kind == IK_STORE;
    // During EXECUTE check the new effective address; during memory states
    // use the latched address to select the returned word's byte lanes.
    rv32i_lsu u_lsu (
        .addr_i(lsu_addr),
        .store_data_i(rs2_q), .read_data_i(dmem_rdata),
        .funct3_i(dec.funct3), .store_i(lsu_store),
        .misaligned_o(lsu_misaligned), .be_o(lsu_be),
        .wdata_o(lsu_wdata), .load_data_o(lsu_load)
    );

    always_comb begin
        branch_taken = 1'b0;
        case (dec.branch)
            BR_EQ:  branch_taken = rs1_q == rs2_q;
            BR_NE:  branch_taken = rs1_q != rs2_q;
            BR_LT:  branch_taken = $signed(rs1_q) < $signed(rs2_q);
            BR_GE:  branch_taken = $signed(rs1_q) >= $signed(rs2_q);
            BR_LTU: branch_taken = rs1_q < rs2_q;
            BR_GEU: branch_taken = rs1_q >= rs2_q;
            default: branch_taken = 1'b0;
        endcase
        control_target = pc_q + dec.imm;
        if (dec.kind == IK_JALR)
            control_target = (rs1_q + dec.imm) & 32'hffff_fffe;
    end

    // ready is COMPLETION, not a separate request-acceptance indication.
    // REQ and WAIT both assert req: one continuous transaction until ready.
    assign imem_req = rst_ni && ((state_q == FETCH_REQ) ||
                      (state_q == FETCH_WAIT)) && (pc_q[1:0] == 2'b00);
    assign imem_addr = pc_q;
    assign dmem_req = rst_ni && ((state_q == MEM_REQ) || (state_q == MEM_WAIT));
    assign dmem_addr = mem_addr_q;
    assign dmem_we = mem_we_q;
    assign dmem_be = mem_be_q;
    assign dmem_wdata = mem_wdata_q;
    assign halted = state_q == HALTED;
    assign retire_valid = rst_ni && (state_q == WRITEBACK);
    assign retire_pc = pc_q;
    assign retire_inst = inst_q;
    assign retire_rd = dec.rd;
    assign retire_wdata = result_q;
    assign retire_rd_we = retire_valid && dec.rd_we && (dec.rd != 5'd0);
    assign rf_we = retire_rd_we;

    // The only fault path. No CSR/trap-vector/privilege behavior is implied.
    task automatic stop_with_fault(input logic [3:0] cause,
                                   input logic [31:0] value);
        begin
            state_q <= HALTED;
            fault_valid <= 1'b1;
            fault_cause <= cause;
            fault_pc <= pc_q;
            fault_tval <= value;
            event_ecall <= cause == 4'd11;
            event_ebreak <= cause == 4'd3;
        end
    endtask

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= FETCH_REQ;
            pc_q <= RESET_PC;
            inst_q <= 32'b0;
            rs1_q <= 32'b0;
            rs2_q <= 32'b0;
            next_pc_q <= RESET_PC;
            result_q <= 32'b0;
            mem_addr_q <= 32'b0;
            mem_wdata_q <= 32'b0;
            mem_be_q <= 4'b0;
            mem_we_q <= 1'b0;
            fault_valid <= 1'b0;
            fault_cause <= 4'b0;
            fault_pc <= 32'b0;
            fault_tval <= 32'b0;
            event_ecall <= 1'b0;
            event_ebreak <= 1'b0;
        end else begin
            case (state_q)
                FETCH_REQ, FETCH_WAIT: begin
                    if (pc_q[1:0] != 2'b00)
                        stop_with_fault(4'd0, pc_q);
                    else if (imem_ready) begin
                        if (imem_error)
                            stop_with_fault(4'd1, pc_q);
                        else begin
                            inst_q <= imem_rdata;
                            state_q <= DECODE;
                        end
                    end else state_q <= FETCH_WAIT;
                end
                DECODE: begin
                    if (dec.kind == IK_ILLEGAL)
                        stop_with_fault(4'd2, inst_q);
                    else begin
                        rs1_q <= rs1_data;
                        rs2_q <= rs2_data;
                        state_q <= EXECUTE;
                    end
                end
                EXECUTE: begin
                    next_pc_q <= pc_q + 32'd4;
                    state_q <= WRITEBACK;
                    case (dec.kind)
                        IK_ALU: result_q <= alu_result;
                        IK_LUI: result_q <= dec.imm;
                        IK_AUIPC: result_q <= pc_q + dec.imm;
                        IK_JAL, IK_JALR: begin
                            if (control_target[1:0] != 2'b00)
                                stop_with_fault(4'd0, control_target);
                            else begin
                                result_q <= pc_q + 32'd4;
                                next_pc_q <= control_target;
                            end
                        end
                        IK_BRANCH: begin
                            if (branch_taken) begin
                                if (control_target[1:0] != 2'b00)
                                    stop_with_fault(4'd0, control_target);
                                else next_pc_q <= control_target;
                            end
                        end
                        IK_LOAD, IK_STORE: begin
                            if (lsu_misaligned)
                                stop_with_fault((dec.kind == IK_STORE) ? 4'd6 : 4'd4,
                                                effective_addr);
                            else begin
                                mem_addr_q <= effective_addr;
                                mem_we_q <= dec.kind == IK_STORE;
                                mem_wdata_q <= lsu_wdata;
                                mem_be_q <= lsu_be;
                                state_q <= MEM_REQ;
                            end
                        end
                        IK_FENCE: begin end // Global serialization ensures ordering.
                        IK_ECALL: stop_with_fault(4'd11, 32'b0);
                        IK_EBREAK: stop_with_fault(4'd3, 32'b0);
                        default: stop_with_fault(4'd2, inst_q);
                    endcase
                end
                MEM_REQ, MEM_WAIT: begin
                    if (dmem_ready) begin
                        if (dmem_error)
                            stop_with_fault(mem_we_q ? 4'd7 : 4'd5, mem_addr_q);
                        else begin
                            if (!mem_we_q) result_q <= lsu_load;
                            state_q <= WRITEBACK;
                        end
                    end else state_q <= MEM_WAIT;
                end
                WRITEBACK: begin
                    // Exactly one edge per successfully completed instruction.
                    pc_q <= next_pc_q;
                    state_q <= FETCH_REQ;
                end
                HALTED: begin end
                default: stop_with_fault(4'd2, inst_q);
            endcase
        end
    end
endmodule
`default_nettype wire
// ===================== END rtl/rv32i_core.sv =====================

// Optional simulation harness. Excluded from normal RTL and synthesis.
`ifdef RV32I1_SMOKE
`ifndef SYNTHESIS
`default_nettype none
module rv32i1_tb;
    logic clk_i = 0;
    logic rst_ni = 0;
    always #5 clk_i = ~clk_i;
    wire imem_req, imem_ready, imem_error;
    wire [31:0] imem_addr, imem_rdata;
    wire dmem_req, dmem_ready, dmem_we, dmem_error;
    wire [3:0] dmem_be;
    wire [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    wire halted, fault_valid, event_ecall, event_ebreak;
    wire [3:0] fault_cause;
    wire [31:0] fault_pc, fault_tval;
    wire retire_valid, retire_rd_we;
    wire [31:0] retire_pc, retire_inst, retire_wdata;
    wire [4:0] retire_rd;
    logic [31:0] rom [0:127];
    logic [31:0] ram [0:127];
    logic [31:0] expected_regs [0:31];
    integer index, lane, retired = 0, data_completions = 0;

    rv32i_core dut (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .imem_req(imem_req), .imem_ready(imem_ready), .imem_addr(imem_addr),
        .imem_rdata(imem_rdata), .imem_error(imem_error),
        .dmem_req(dmem_req), .dmem_ready(dmem_ready), .dmem_we(dmem_we),
        .dmem_be(dmem_be), .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata),
        .dmem_rdata(dmem_rdata), .dmem_error(dmem_error),
        .halted(halted), .fault_valid(fault_valid), .fault_cause(fault_cause),
        .fault_pc(fault_pc), .fault_tval(fault_tval),
        .event_ecall(event_ecall), .event_ebreak(event_ebreak),
        .retire_valid(retire_valid), .retire_pc(retire_pc), .retire_inst(retire_inst),
        .retire_rd(retire_rd), .retire_wdata(retire_wdata), .retire_rd_we(retire_rd_we)
    );
    assign imem_ready = rst_ni && imem_req;
    assign imem_error = imem_addr >= 32'd512;
    assign imem_rdata = imem_addr < 32'd512 ? rom[imem_addr[8:2]] : 32'b0;
    assign dmem_ready = rst_ni && dmem_req;
    assign dmem_error = dmem_addr >= 32'd512;
    assign dmem_rdata = dmem_addr < 32'd512 ? ram[dmem_addr[8:2]] : 32'b0;
    always @(posedge clk_i) begin
        if (rst_ni) begin
            if (retire_valid) retired = retired + 1;
            if (dmem_req && dmem_ready) begin
                data_completions = data_completions + 1;
                if (dmem_we && !dmem_error)
                    for (lane = 0; lane < 4; lane = lane + 1)
                        if (dmem_be[lane])
                            ram[dmem_addr[8:2]][8*lane +: 8] <= dmem_wdata[8*lane +: 8];
            end
        end
    end
    initial begin
        for (index = 0; index < 128; index = index + 1) begin
            rom[index] = 32'hffff_ffff;
            ram[index] = 0;
        end
        for (index = 0; index < 32; index = index + 1) expected_regs[index] = 0;
        rom[ 0] = 32'h10000093; // PC   0: ADDI x1,x0,256
        rom[ 1] = 32'h80ff8137; // PC   4: LUI x2,0x80ff8
        rom[ 2] = 32'hf0110113; // PC   8: ADDI x2,x2,-255
        rom[ 3] = 32'h0020a023; // PC  12: SW x2,0(x1)
        rom[ 4] = 32'h00308183; // PC  16: LB x3,3(x1)
        rom[ 5] = 32'h0030c203; // PC  20: LBU x4,3(x1)
        rom[ 6] = 32'h00209283; // PC  24: LH x5,2(x1)
        rom[ 7] = 32'h0020d303; // PC  28: LHU x6,2(x1)
        rom[ 8] = 32'hfff00393; // PC  32: ADDI x7,x0,-1
        rom[ 9] = 32'h41f3d413; // PC  36: SRAI x8,x7,31
        rom[10] = 32'h01f3d493; // PC  40: SRLI x9,x7,31
        rom[11] = 32'h0093a533; // PC  44: SLT x10,x7,x9
        rom[12] = 32'h0093b5b3; // PC  48: SLTU x11,x7,x9
        rom[13] = 32'h00418633; // PC  52: ADD x12,x3,x4
        rom[14] = 32'h004080a3; // PC  56: SB x4,1(x1)
        rom[15] = 32'h00609123; // PC  60: SH x6,2(x1)
        rom[16] = 32'h0000a683; // PC  64: LW x13,0(x1)
        rom[17] = 32'h0ff0000f; // PC  68: FENCE iorw,iorw
        rom[18] = 32'h00060463; // PC  72: BEQ x12,x0,+8
        rom[19] = 32'hffffffff; // PC  76: must be skipped by branch
        rom[20] = 32'h0080076f; // PC  80: JAL x14,+8
        rom[21] = 32'hffffffff; // PC  84: must be skipped by JAL
        rom[22] = 32'h06500793; // PC  88: ADDI x15,x0,101
        rom[23] = 32'h00078867; // PC  92: JALR x16,0(x15): clear bit 0, target=100
        rom[24] = 32'hffffffff; // PC  96: must be skipped by JALR
        rom[25] = 32'h123458b7; // PC 100: LUI x17,0x12345
        rom[26] = 32'h00000917; // PC 104: AUIPC x18,0
        rom[27] = 32'h07b00013; // PC 108: ADDI x0,x0,123: suppress write
        rom[28] = 32'h00100073; // PC 112: EBREAK: diagnostic halt, no retirement
        expected_regs[ 1] = 32'h00000100;
        expected_regs[ 2] = 32'h80ff7f01;
        expected_regs[ 3] = 32'hffffff80;
        expected_regs[ 4] = 32'h00000080;
        expected_regs[ 5] = 32'hffff80ff;
        expected_regs[ 6] = 32'h000080ff;
        expected_regs[ 7] = 32'hffffffff;
        expected_regs[ 8] = 32'hffffffff;
        expected_regs[ 9] = 32'h00000001;
        expected_regs[10] = 32'h00000001;
        expected_regs[11] = 32'h00000000;
        expected_regs[12] = 32'h00000000;
        expected_regs[13] = 32'h80ff8001;
        expected_regs[14] = 32'h00000054;
        expected_regs[15] = 32'h00000065;
        expected_regs[16] = 32'h00000060;
        expected_regs[17] = 32'h12345000;
        expected_regs[18] = 32'h00000068;
        repeat (3) @(negedge clk_i);
        rst_ni = 1;
        wait (halted);
        @(negedge clk_i);
        if (!fault_valid || fault_cause !== 4'd3 || fault_pc !== 32'd112 ||
            fault_tval !== 0 || !event_ebreak || event_ecall)
            $fatal(1, "rv32i1 smoke: unexpected diagnostic halt");
        for (index = 0; index < 32; index = index + 1)
            if (dut.u_regfile.regs[index] !== expected_regs[index])
                $fatal(1, "rv32i1 smoke: x%0d=%h expected=%h", index,
                       dut.u_regfile.regs[index], expected_regs[index]);
        for (index = 0; index < 128; index = index + 1)
            if (ram[index] !== ((index == 64) ? 32'h80ff8001 : 32'b0))
                $fatal(1, "rv32i1 smoke: memory word %0d=%h", index, ram[index]);
        if (retired != 25 || data_completions != 8)
            $fatal(1, "rv32i1 smoke: unexpected retirement/transaction counts %0d/%0d",
                   retired, data_completions);
        repeat (3) begin
            @(negedge clk_i);
            if (!halted || imem_req || dmem_req || retire_valid)
                $fatal(1, "rv32i1 smoke: HALTED must remain quiescent");
        end
        $display("PASS rv32i1 standalone smoke: 32 registers, memory, flow, x0 and EBREAK");
        $finish;
    end
    initial begin
        #100000;
        $fatal(1, "rv32i1 smoke timeout");
    end
endmodule
`default_nettype wire
`endif // !SYNTHESIS
`endif // RV32I1_SMOKE
