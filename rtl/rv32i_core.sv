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
