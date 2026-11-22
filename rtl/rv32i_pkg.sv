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
