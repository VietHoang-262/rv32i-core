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
