// Simulation-only white-box connectivity and architectural side-effect monitor.
// Include inside tb_core after the DUT. The trace scoreboard remains independent
// of this monitor: it checks ISA results, while this checks every register and
// the boundaries where an instruction is allowed to change architectural state.
logic [31:0] check_regs [0:31];
logic [31:0] check_pc, check_inst, check_rs1, check_rs2;
integer check_index;
integer connection_checks = 0;
integer instruction_data_completions = 0;
logic instruction_open = 0;

task automatic connection_check(input logic condition, input string message);
    begin
        connection_checks = connection_checks + 1;
        if (condition !== 1'b1)
            $fatal(1, "connection/state: %s pc=%h instruction=%h state=%h",
                   message, dut.pc_q, dut.inst_q, dut.state_q);
    end
endtask

always @(posedge clk_i) begin
    if (!rst_ni) begin
        check_pc = RESET_PC;
        check_inst = 0;
        check_rs1 = 0;
        check_rs2 = 0;
        instruction_open = 0;
        instruction_data_completions = 0;
        for (check_index = 0; check_index < 32; check_index = check_index + 1)
            check_regs[check_index] = 0;
    end else begin
        // Observe the state from the previous edge before the DUT's NBA writes.
        connection_check(dut.pc_q === check_pc, "PC changed outside commit");
        connection_check(dut.inst_q === check_inst, "IR changed without successful fetch");
        connection_check(dut.rs1_q === check_rs1 && dut.rs2_q === check_rs2,
                         "operand registers changed outside legal decode");
        for (check_index = 0; check_index < 32; check_index = check_index + 1)
            connection_check(dut.u_regfile.regs[check_index] === check_regs[check_index],
                             $sformatf("architectural x%0d differs from retirement", check_index));

        connection_check(dut.state_q <= 4'd7, "unknown/invalid FSM state");
        connection_check(fault_valid === halted, "fault status asserted outside HALTED");
        connection_check(event_ecall === (halted && fault_cause == 4'd11), "ECALL event");
        connection_check(event_ebreak === (halted && fault_cause == 4'd3), "EBREAK event");
        connection_check(dut.rf_we === retire_rd_we, "register write gate vs retirement");
        connection_check(!dut.rf_we || (retire_valid && dut.dec.rd != 0 && !fault_valid),
                         "uncommitted/faulting/x0 register write");

        // Check the actual submodule pins as well as their source-side values.
        connection_check(dut.u_decoder.inst_i === dut.inst_q, "IR -> decoder");
        connection_check(dut.u_regfile.rs1_i === dut.dec.rs1 &&
                         dut.u_regfile.rs2_i === dut.dec.rs2, "decoder -> RF read addresses");
        connection_check(dut.u_regfile.rd_i === dut.dec.rd &&
                         dut.u_regfile.rd_we_i === dut.rf_we &&
                         dut.u_regfile.rd_data_i === dut.result_q, "writeback -> RF");
        connection_check(dut.u_alu.a_i === dut.rs1_q &&
                         dut.u_alu.b_i === (dut.dec.alu_src_imm ? dut.dec.imm : dut.rs2_q) &&
                         dut.u_alu.op_i === dut.dec.alu_op, "operands/control -> ALU");
        connection_check(dut.u_lsu.addr_i === ((dut.state_q == 4'd3) ?
                         (dut.rs1_q + dut.dec.imm) : dut.mem_addr_q), "effective/latched address -> LSU");
        connection_check(dut.u_lsu.store_data_i === dut.rs2_q &&
                         dut.u_lsu.read_data_i === dmem_rdata &&
                         dut.u_lsu.funct3_i === dut.dec.funct3 &&
                         dut.u_lsu.store_i === (dut.inst_q[6:0] == 7'h23 &&
                                               dut.dec.kind != rv32i_pkg::IK_ILLEGAL), "data/control -> LSU");
        connection_check(imem_addr === dut.pc_q, "PC -> instruction address");
        connection_check(dmem_addr === dut.mem_addr_q && dmem_be === dut.mem_be_q &&
                         dmem_we === dut.mem_we_q && dmem_wdata === dut.mem_wdata_q,
                         "latched transaction -> data port");
        connection_check(imem_req === (((dut.state_q == 4'd0) || (dut.state_q == 4'd1)) &&
                                      dut.pc_q[1:0] == 0), "instruction request state gate");
        connection_check(dmem_req === ((dut.state_q == 4'd4) || (dut.state_q == 4'd5)),
                         "data request state gate");
        connection_check(retire_valid === (dut.state_q == 4'd6), "retirement state gate");

        if (imem_req && imem_ready && !imem_error) begin
            connection_check(!instruction_open, "second instruction fetched before completion");
            connection_check((^imem_rdata) !== 1'bx, "unknown instruction at completion");
            instruction_open = 1;
            instruction_data_completions = 0;
            check_inst = imem_rdata;
        end
        if (dut.state_q == 4'd2 && dut.dec.kind != rv32i_pkg::IK_ILLEGAL) begin
            check_rs1 = dut.rs1_data;
            check_rs2 = dut.rs2_data;
        end
        if (dmem_req && dmem_ready) begin
            connection_check(instruction_open, "data completion without an instruction");
            connection_check(instruction_data_completions == 0, "multiple data completions for one instruction");
            connection_check(dut.inst_q[6:0] == 7'h03 || dut.inst_q[6:0] == 7'h23,
                             "non-memory instruction issued a data request");
            instruction_data_completions = instruction_data_completions + 1;
        end
        if (retire_valid) begin
            connection_check(instruction_open, "duplicate/unfetched retirement");
            connection_check((^retire_pc) !== 1'bx && (^retire_inst) !== 1'bx,
                             "unknown retirement identity");
            if (dut.inst_q[6:0] == 7'h03 || dut.inst_q[6:0] == 7'h23)
                connection_check(instruction_data_completions == 1, "memory instruction retired without completion");
            else
                connection_check(instruction_data_completions == 0, "unexpected data side effect");
            if (retire_rd_we) begin
                connection_check((^retire_wdata) !== 1'bx && retire_rd != 0, "invalid retirement write");
                check_regs[retire_rd] = retire_wdata;
            end
            check_pc = dut.next_pc_q;
            instruction_open = 0;
        end
        if (halted) begin
            connection_check(!imem_req && !dmem_req && !dut.rf_we && !retire_valid,
                             "HALTED side effect");
            instruction_open = 0;
        end
    end
end

always @(negedge clk_i) begin
    // Reset is driven on a falling edge; observe after asynchronous NBA updates.
    #1;
    if (!rst_ni) begin
        connection_check(!imem_req && !dmem_req && !retire_valid && !dut.rf_we,
                         "requests/writeback active during reset");
        connection_check(!fault_valid && !event_ecall && !event_ebreak && !halted,
                         "reset did not clear fault state");
    end
end
