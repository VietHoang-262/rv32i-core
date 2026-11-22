`timescale 1ns/1ps
module tb_core #(
    parameter logic [31:0] RESET_PC = 0
);
    logic clk_i=0;
    always #5 clk_i=~clk_i;
    logic rst_ni=0;
    wire imem_req, imem_ready, imem_error;
    wire [31:0] imem_addr, imem_rdata;
    wire dmem_req,dmem_ready,dmem_error,dmem_we;
    wire [3:0] dmem_be;
    wire [31:0] dmem_addr,dmem_wdata,dmem_rdata;
    wire halted,fault_valid,event_ecall,event_ebreak;
    wire [3:0] fault_cause;
    wire [31:0] fault_pc,fault_tval;
    wire retire_valid,retire_rd_we;
    wire [31:0] retire_pc,retire_inst,retire_wdata;
    wire [4:0] retire_rd;
    integer latency_mode=2,seed=3,reset_mode=0,restart_halted=0;
    integer imem_latency_mode=2,dmem_latency_mode=2,idle_noise=0;
    integer reset_wait=0,reset_completion=0;
    logic [31:0] imem_fault,dmem_fault;
    // Keep every core connection explicit so interface additions cannot be
    // silently omitted or depend on a testbench signal's spelling.
    rv32i_core #(.RESET_PC(RESET_PC)) dut (
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
    `include "tb/rv32i_core_checks.svh"
    tb_latency_memory #(.READ_ONLY(1)) imem (
        .clk_i,.rst_ni,.req_i(imem_req),.we_i(1'b0),.be_i(4'b1111),
        .addr_i(imem_addr),.wdata_i(32'b0),.ready_o(imem_ready),.rdata_o(imem_rdata),.error_o(imem_error),
        .latency_mode_i(imem_latency_mode),.seed_i(seed),.noise_i(idle_noise!=0),.fault_addr_i(imem_fault)
    );
    tb_latency_memory dmem (
        .clk_i,.rst_ni,.req_i(dmem_req),.we_i(dmem_we),.be_i(dmem_be),
        .addr_i(dmem_addr),.wdata_i(dmem_wdata),.ready_o(dmem_ready),.rdata_o(dmem_rdata),.error_o(dmem_error),
        .latency_mode_i(dmem_latency_mode),.seed_i(seed),.noise_i(idle_noise!=0),.fault_addr_i(dmem_fault)
    );
    string case_dir;
    integer cfg_fd,retire_fd,txn_fd,scan_result;
    integer exp_cause,exp_ecall,exp_ebreak,exp_retire_count,exp_txn_count;
    logic [31:0] exp_fault_pc,exp_fault_tval,exp_reset_pc;
    logic [31:0] final_mem [0:1023];
    logic [31:0] final_regs [0:31];
    integer retire_count=0,txn_count=0,fetch_count=0,cycles=0;
    logic [31:0] ref_pc,ref_inst,ref_wdata,ref_addr;
    integer ref_we,ref_rd,ref_be;
    logic [31:0] byte_mask;
    integer n;
    initial begin
        if (!$value$plusargs("case=%s",case_dir)) $fatal(1,"missing +case=<directory>");
        scan_result=$value$plusargs("latency=%d",latency_mode);
        imem_latency_mode=latency_mode;
        dmem_latency_mode=latency_mode;
        scan_result=$value$plusargs("imem_latency=%d",imem_latency_mode);
        scan_result=$value$plusargs("dmem_latency=%d",dmem_latency_mode);
        scan_result=$value$plusargs("idle_noise=%d",idle_noise);
        scan_result=$value$plusargs("reset_wait=%d",reset_wait);
        scan_result=$value$plusargs("reset_completion=%d",reset_completion);
        scan_result=$value$plusargs("seed=%d",seed);
        scan_result=$value$plusargs("reset_mode=%d",reset_mode);
        scan_result=$value$plusargs("restart_halted=%d",restart_halted);
        cfg_fd=$fopen({case_dir,"/config.hex"},"r");
        if (!cfg_fd) $fatal(1,"cannot open config");
        scan_result=$fscanf(cfg_fd,"%h %h %h %h %h %h %h %h %h %h",exp_cause,exp_fault_pc,exp_fault_tval,exp_ecall,exp_ebreak,exp_retire_count,exp_txn_count,imem_fault,dmem_fault,exp_reset_pc);
        if (scan_result!=10) $fatal(1,"bad configuration");
        $fclose(cfg_fd);
        if (exp_reset_pc !== RESET_PC) $fatal(1,"wrong RESET_PC parameter");
        retire_fd=$fopen({case_dir,"/retire.hex"},"r");
        txn_fd=$fopen({case_dir,"/transactions.hex"},"r");
        if (!retire_fd || !txn_fd) $fatal(1,"missing expected traces");
        $readmemh({case_dir,"/program.hex"},imem.mem);
        $readmemh({case_dir,"/data.hex"},dmem.mem);
        $readmemh({case_dir,"/final.hex"},final_mem);
        $readmemh({case_dir,"/registers.hex"},final_regs);
        repeat(3) @(negedge clk_i);
        rst_ni=1;
        if (reset_mode!=0) begin
            if (reset_mode==1) wait(imem_req && !imem_ready);
            else wait(dmem_req && !dmem_ready);
            // Assert reset between clock edges. In completion mode, cancel
            // after ready has risen but before the would-be handshake edge.
            if (reset_completion!=0) begin
                if (reset_mode==1) wait(imem_req && imem_ready);
                else wait(dmem_req && dmem_ready);
            end else repeat(reset_wait) @(negedge clk_i);
            @(negedge clk_i);
            if (reset_completion!=0 && ((reset_mode==1 && !imem_req) ||
                                       (reset_mode!=1 && !dmem_req)))
                $fatal(1,"completion reset missed transaction");
            rst_ni=0;
            repeat(2) @(negedge clk_i);
            rst_ni=1;
        end
        wait(halted);
        if (restart_halted!=0) begin
            @(negedge clk_i); rst_ni=0;
            repeat(2) @(negedge clk_i); rst_ni=1;
            wait(halted);
        end
        @(negedge clk_i);
        if (!fault_valid || fault_cause!==exp_cause[3:0] || fault_pc!==exp_fault_pc || fault_tval!==exp_fault_tval || event_ecall!==exp_ecall[0] || event_ebreak!==exp_ebreak[0])
            $fatal(1,"halt mismatch cause=%h pc=%h tval=%h ecall=%b break=%b expected %h %h %h %b %b",fault_cause,fault_pc,fault_tval,event_ecall,event_ebreak,exp_cause,exp_fault_pc,exp_fault_tval,exp_ecall[0],exp_ebreak[0]);
        if (retire_count!=exp_retire_count || txn_count!=exp_txn_count)
            $fatal(1,"count mismatch retire %0d/%0d data %0d/%0d",retire_count,exp_retire_count,txn_count,exp_txn_count);
        if (imem.completions != fetch_count || dmem.completions != txn_count)
            $fatal(1,"memory responder completion count disagrees with scoreboard");
        if (fetch_count!=exp_retire_count+(RESET_PC[1:0]==0 ? 1:0))
            $fatal(1,"duplicate/lost fetch: got %0d expected %0d",fetch_count,exp_retire_count+(RESET_PC[1:0]==0 ? 1:0));
        for (n=0;n<1024;n=n+1)
            if (dmem.mem[n]!==final_mem[n]) $fatal(1,"final data mismatch word %0d got %h expected %h",n,dmem.mem[n],final_mem[n]);
        for (n=0;n<32;n=n+1)
            if (dut.u_regfile.regs[n]!==final_regs[n])
                $fatal(1,"final register mismatch x%0d got %h expected %h",n,dut.u_regfile.regs[n],final_regs[n]);
        repeat(5) begin
            @(negedge clk_i);
            if (!halted || imem_req || dmem_req || retire_valid || !fault_valid || fault_cause!==exp_cause[3:0] || fault_pc!==exp_fault_pc || fault_tval!==exp_fault_tval || event_ecall!==exp_ecall[0] || event_ebreak!==exp_ebreak[0])
                $fatal(1,"halt was not sticky/quiescent");
        end
        $display("PASS core %s latency=%0d imem=%0d dmem=%0d noise=%0d retire=%0d data=%0d cycles=%0d stalls=%0d/%0d",case_dir,latency_mode,imem_latency_mode,dmem_latency_mode,idle_noise,retire_count,txn_count,cycles,imem.stall_cycles,dmem.stall_cycles);
        $finish;
    end
    always @(posedge clk_i) begin
        if (!rst_ni) begin
            retire_count=0; txn_count=0; fetch_count=0; cycles=0;
            if (retire_fd) scan_result=$fseek(retire_fd,0,0);
            if (txn_fd) scan_result=$fseek(txn_fd,0,0);
        end else begin
            cycles=cycles+1;
            if (cycles>200000) $fatal(1,"simulation timeout");
            if (imem_req && dmem_req) $fatal(1,"core violated global serialization");
            if (imem_req && imem_addr[1:0]!=0) $fatal(1,"misaligned fetch issued");
            if (imem_req && imem_ready) fetch_count=fetch_count+1;
            if (retire_valid) begin
                if (retire_count>=exp_retire_count) $fatal(1,"unexpected/duplicate retirement");
                scan_result=$fscanf(retire_fd,"%h %h %h %h %h",ref_pc,ref_inst,ref_we,ref_rd,ref_wdata);
                if (scan_result!=5) $fatal(1,"bad retirement reference");
                if (retire_pc!==ref_pc || retire_inst!==ref_inst || retire_rd_we!==ref_we[0] || (ref_we && (retire_rd!==ref_rd[4:0] || retire_wdata!==ref_wdata)))
                    $fatal(1,"retire %0d got pc=%h ins=%h we=%b rd=%0d data=%h expected pc=%h ins=%h we=%b rd=%0d data=%h",retire_count,retire_pc,retire_inst,retire_rd_we,retire_rd,retire_wdata,ref_pc,ref_inst,ref_we[0],ref_rd,ref_wdata);
                retire_count=retire_count+1;
            end
            if (dmem_req && dmem_ready) begin
                if (txn_count>=exp_txn_count) $fatal(1,"unexpected/duplicate data completion");
                scan_result=$fscanf(txn_fd,"%h %h %h %h",ref_addr,ref_we,ref_be,ref_wdata);
                if (scan_result!=4) $fatal(1,"bad data reference");
                byte_mask={{8{ref_be[3]}},{8{ref_be[2]}},{8{ref_be[1]}},{8{ref_be[0]}}};
                if (dmem_addr!==ref_addr || dmem_we!==ref_we[0] || dmem_be!==ref_be[3:0] || (ref_we && ((dmem_wdata&byte_mask)!==(ref_wdata&byte_mask))))
                    $fatal(1,"data txn %0d addr=%h we=%b be=%h data=%h expected %h %b %h %h",txn_count,dmem_addr,dmem_we,dmem_be,dmem_wdata,ref_addr,ref_we[0],ref_be[3:0],ref_wdata);
                txn_count=txn_count+1;
            end
        end
    end
    initial begin
        #3000000;
        $fatal(1,"absolute timeout (reset test failed to progress)");
    end
endmodule
