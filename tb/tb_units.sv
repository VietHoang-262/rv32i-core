`timescale 1ns/1ps
module tb_units;
  import rv32i_pkg::*;
  logic [31:0] inst;
  decode_t dec;
  logic [31:0] a, b, result;
  alu_op_t alu_op;
  logic [31:0] addr, store_data, read_data, wdata, load_data;
  logic [2:0] funct3;
  logic store, misaligned;
  logic [3:0] be;
  logic clk = 0;
  logic rst_n = 0;
  logic [4:0] rs1, rs2, rd;
  logic [31:0] rs1_data, rs2_data, rd_data;
  logic rd_we;
  integer checks = 0;
  integer op, f3, f7, lane, mode, i, j, k, width;
  logic expected_legal, expected_misaligned;
  logic [31:0] shifted, expected_data, expected_mask;
  logic [3:0] expected_be;
  logic [31:0] samples [0:7];
  logic [31:0] rng;
  logic [31:0] raw_imm;
  instr_kind_t expected_kind;
  alu_op_t expected_op;
  branch_t expected_branch;
  logic expected_rd_we, expected_alu_src_imm;

  rv32i_decoder decoder(.inst_i(inst), .dec_o(dec));
  rv32i_alu alu(.a_i(a), .b_i(b), .op_i(alu_op), .result_o(result));
  rv32i_lsu lsu(.addr_i(addr), .store_data_i(store_data),
    .read_data_i(read_data), .funct3_i(funct3), .store_i(store),
    .misaligned_o(misaligned), .be_o(be), .wdata_o(wdata), .load_data_o(load_data));
  rv32i_regfile rf(.clk_i(clk), .rst_ni(rst_n), .rs1_i(rs1), .rs2_i(rs2),
    .rs1_data_o(rs1_data), .rs2_data_o(rs2_data), .rd_we_i(rd_we), .rd_i(rd),
    .rd_data_i(rd_data));
  always #5 clk = ~clk;

  task automatic check(input logic condition, input string message);
    begin
      checks = checks + 1;
      if (condition !== 1'b1) begin
        $error("%s inst=%08x a=%08x b=%08x funct3=%d addr=%08x", message,inst,a,b,funct3,addr);
        $fatal(1, "Unit test failed");
      end
    end
  endtask

  task automatic test_alu(input alu_op_t operation, input logic [31:0] lhs,
                          input logic [31:0] rhs, input logic [31:0] expected);
    begin
      alu_op = operation; a = lhs; b = rhs; #1;
      check(result === expected, "ALU result");
    end
  endtask

  initial begin
    inst=0; a=0; b=0; alu_op=ALU_ADD;
    addr=0; store_data=0; read_data=0; funct3=0; store=0;
    rs1=0; rs2=0; rd=0; rd_data=0; rd_we=0;
    // Exercise a real asynchronous reset edge before observing register data.
    #1; rst_n=1; #1; rst_n=0; #1;
    for (i=0;i<32;i=i+1) begin
      rs1=i[4:0]; rs2=(31-i); #1;
      check(rs1_data===32'b0 && rs2_data===32'b0, "Regfile reset");
    end
    @(negedge clk); rst_n=1;
    for (i=0;i<32;i=i+1) begin
      @(negedge clk); rd=i[4:0]; rd_we=1; rd_data=32'hcaf00000+i;
      @(posedge clk); #1;
      rs1=i[4:0]; rs2=0; #1;
      check(rs1_data === ((i==0)?32'b0:32'hcaf00000+i), "Regfile write/read");
      check(rs2_data===32'b0, "x0 immutable");
    end
    @(negedge clk); rd_we=0;
    for (i=0;i<32;i=i+1) begin
      rs1=i[4:0]; #1;
      check(rs1_data === ((i==0)?32'b0:32'hcaf00000+i), "Regfile independent registers");
    end

    // Sweep every opcode/funct3/funct7 combination. Source/destination fields
    // deliberately nonzero so malformed SYSTEM encodings cannot alias ECALL.
    for (op=0;op<128;op=op+1) begin
      for (f3=0;f3<8;f3=f3+1) begin
        for (f7=0;f7<128;f7=f7+1) begin
          inst=(f7<<25)|(3<<20)|(1<<15)|(f3<<12)|(2<<7)|op;
          expected_legal=0;
          case (op)
            'h37, 'h17, 'h6f: expected_legal=1;
            'h67: expected_legal=(f3==0);
            'h63: expected_legal=(f3==0 || f3==1 || f3>=4);
            'h03: expected_legal=(f3==0 || f3==1 || f3==2 || f3==4 || f3==5);
            'h23: expected_legal=(f3<=2);
            'h13: begin
              if (f3==1) expected_legal=(f7==0);
              else if (f3==5) expected_legal=(f7==0 || f7==32);
              else expected_legal=1;
            end
            'h33: expected_legal=(f7==0 || (f7==32 && (f3==0 || f3==5)));
            'h0f: expected_legal=(f3==0);
            default: expected_legal=0;
          endcase
          #1;
          check((dec.kind!=IK_ILLEGAL)===expected_legal, "Decoder legality sweep");
          check(dec.rs1===5'd1 && dec.rs2===5'd3 && dec.rd===5'd2 &&
                dec.funct3===f3[2:0], "Decoder register/funct3 field wiring");
          if (!expected_legal) begin
            check(dec.rd_we===1'b0 && dec.branch===BR_NONE,
                  "Illegal decode cannot authorize a write or branch");
          end else begin
            expected_kind=IK_ILLEGAL;
            expected_rd_we=0;
            expected_alu_src_imm=0;
            expected_branch=BR_NONE;
            case (op)
              'h33: begin expected_kind=IK_ALU; expected_rd_we=1; end
              'h13: begin expected_kind=IK_ALU; expected_rd_we=1; expected_alu_src_imm=1; end
              'h03: begin expected_kind=IK_LOAD; expected_rd_we=1; expected_alu_src_imm=1; end
              'h23: begin expected_kind=IK_STORE; expected_alu_src_imm=1; end
              'h63: begin
                expected_kind=IK_BRANCH;
                case(f3)
                  0: expected_branch=BR_EQ;
                  1: expected_branch=BR_NE;
                  4: expected_branch=BR_LT;
                  5: expected_branch=BR_GE;
                  6: expected_branch=BR_LTU;
                  7: expected_branch=BR_GEU;
                  default: expected_branch=BR_NONE;
                endcase
              end
              'h37: begin expected_kind=IK_LUI; expected_rd_we=1; expected_alu_src_imm=1; end
              'h17: begin expected_kind=IK_AUIPC; expected_rd_we=1; expected_alu_src_imm=1; end
              'h6f: begin expected_kind=IK_JAL; expected_rd_we=1; end
              'h67: begin expected_kind=IK_JALR; expected_rd_we=1; end
              'h0f: expected_kind=IK_FENCE;
              default: expected_kind=IK_ILLEGAL;
            endcase
            check(dec.kind===expected_kind && dec.rd_we===expected_rd_we &&
                  dec.alu_src_imm===expected_alu_src_imm && dec.branch===expected_branch,
                  "Decoder instruction-kind and datapath control wiring");
            if (op=='h33 || op=='h13) begin
              case (f3)
                0: if (op=='h33 && f7==32) expected_op=ALU_SUB; else expected_op=ALU_ADD;
                1: expected_op=ALU_SLL;
                2: expected_op=ALU_SLT;
                3: expected_op=ALU_SLTU;
                4: expected_op=ALU_XOR;
                5: if (f7==32) expected_op=ALU_SRA; else expected_op=ALU_SRL;
                6: expected_op=ALU_OR;
                7: expected_op=ALU_AND;
                default: expected_op=ALU_ADD;
              endcase
              check(dec.alu_op===expected_op, "Decoder complete ALU operation map");
            end
          end
          if (expected_legal && op=='h13 && f3==5)
            check(dec.alu_op===((f7==32)?ALU_SRA:ALU_SRL), "SRLI/SRAI exact funct7");
          if (expected_legal && op=='h33 && f3==5)
            check(dec.alu_op===((f7==32)?ALU_SRA:ALU_SRL), "SRL/SRA exact funct7");
        end
      end
    end
    // SYSTEM must match both complete instruction words; all CSR functions and
    // reserved immediate values are illegal. Also vary rd and rs1 independently.
    for (i=0;i<4096;i=i+1) begin
      for (f3=0;f3<8;f3=f3+1) begin
        for (j=0;j<3;j=j+1) begin
          inst=(i<<20)|(f3<<12)|32'h73;
          if (j==1) inst=inst|(1<<7);
          if (j==2) inst=inst|(1<<15);
          expected_legal=(j==0 && f3==0 && (i==0 || i==1));
          #1;
          check((dec.kind!=IK_ILLEGAL)===expected_legal, "SYSTEM exact encoding");
          if (expected_legal)
            check(dec.kind===((i==0)?IK_ECALL:IK_EBREAK), "SYSTEM event classification");
        end
      end
    end
    // Immediate reconstruction, including the sign and split B/J fields.
    inst=32'hfff10093; #1; check(dec.imm===32'hffffffff, "I immediate -1");
    inst=32'h80010093; #1; check(dec.imm===32'hfffff800, "I immediate min");
    inst=32'hfe20afa3; #1; check(dec.imm===32'hffffffff, "S immediate -1");
    inst=32'hfe208ee3; #1; check(dec.imm===32'hfffffffc, "B immediate -4");
    inst=32'hffdff0ef; #1; check(dec.imm===32'hfffffffc, "J immediate -4");
    inst=32'h89abc0b7; #1; check(dec.imm===32'h89abc000, "U immediate");
    for (i=0;i<32;i=i+1) begin
      inst=(i<<20)|(1<<15)|(1<<12)|(2<<7)|32'h13; #1;
      check(dec.imm[4:0]===i[4:0] && dec.alu_op===ALU_SLL, "SLLI shamt bits 24:20");
    end

    // Exercise every bit of all register indices, rather than relying only on
    // the fixed register fields in the legality sweep.
    for (i=0;i<32;i=i+1) begin
      inst=(((i+7)&31)<<20)|(i<<15)|((31-i)<<7)|32'h33; #1;
      check(dec.rs1===i[4:0] && dec.rs2===((i+7)&31) && dec.rd===(31-i),
            "All five bits of rs1/rs2/rd are independently wired");
    end

    // Numeric immediate values provide the reference. The encodings use all
    // 4096 possible payloads so sign extension and every split S/B wire are
    // checked, including min/max offsets and positive/negative transitions.
    for (i=0;i<4096;i=i+1) begin
      expected_data=(i<2048)?i:(i-4096);
      inst=(i<<20)|32'h00010093; #1;
      check(dec.kind===IK_ALU && dec.imm===expected_data, "All ADDI I-immediates");
      inst=(i<<20)|32'h00014083; #1;
      check(dec.kind===IK_LOAD && dec.imm===expected_data, "All load I-immediates");
      inst=(i<<20)|32'h000100e7; #1;
      check(dec.kind===IK_JALR && dec.imm===expected_data, "All JALR I-immediates");
      inst=((i/32)<<25)|((i%32)<<7)|32'h00312023; #1;
      check(dec.kind===IK_STORE && dec.imm===expected_data, "All split S-immediates");
      expected_data=(i<2048)?(2*i):(2*i-8192);
      inst=((i/2048)<<31)|(((i/1024)%2)<<7)|(((i/16)%64)<<25)|
           ((i%16)<<8)|32'h00310063; #1;
      check(dec.kind===IK_BRANCH && dec.imm===expected_data, "All split B-immediates");
    end

    // Walking-one and walking-zero payloads check every J/U immediate wire
    // and complement; mixed patterns test simultaneous bit combinations.
    for (mode=0;mode<2;mode=mode+1) begin
      for (i=0;i<20;i=i+1) begin
        raw_imm=32'b1<<i;
        if (mode!=0) raw_imm=raw_imm^32'h000fffff;
        expected_data=(raw_imm<524288)?(2*raw_imm):(2*raw_imm-2097152);
        inst=(((raw_imm>>19)&1)<<31)|((raw_imm&1023)<<21)|
             (((raw_imm>>10)&1)<<20)|(((raw_imm>>11)&255)<<12)|32'h000000ef; #1;
        check(dec.kind===IK_JAL && dec.imm===expected_data, "Every split J-immediate wire");
        expected_data=raw_imm<<12;
        inst=(raw_imm<<12)|32'h000000b7; #1;
        check(dec.kind===IK_LUI && dec.imm===expected_data, "Every LUI U-immediate wire");
        inst=(raw_imm<<12)|32'h00000097; #1;
        check(dec.kind===IK_AUIPC && dec.imm===expected_data, "Every AUIPC U-immediate wire");
      end
    end
    rng=32'h9a37c015;
    for (i=0;i<512;i=i+1) begin
      rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
      raw_imm=rng&32'h000fffff;
      expected_data=(raw_imm<524288)?(2*raw_imm):(2*raw_imm-2097152);
      inst=(((raw_imm>>19)&1)<<31)|((raw_imm&1023)<<21)|
           (((raw_imm>>10)&1)<<20)|(((raw_imm>>11)&255)<<12)|32'h000000ef; #1;
      check(dec.imm===expected_data, "Mixed J-immediate bit combinations");
      expected_data=raw_imm<<12;
      inst=(raw_imm<<12)|32'h000000b7; #1;
      check(dec.imm===expected_data, "Mixed U-immediate bit combinations");
    end

    samples[0]=0; samples[1]=1; samples[2]=32'hffffffff; samples[3]=32'h80000000;
    samples[4]=32'h7fffffff; samples[5]=32'h55555555; samples[6]=32'haaaaaaaa;
    samples[7]=32'h12345678;
    for(i=0;i<8;i=i+1) begin
      for(j=0;j<8;j=j+1) begin
        test_alu(ALU_ADD,samples[i],samples[j],samples[i]+samples[j]);
        test_alu(ALU_SUB,samples[i],samples[j],samples[i]-samples[j]);
        test_alu(ALU_SLT,samples[i],samples[j],{31'b0,($signed(samples[i])<$signed(samples[j]))});
        test_alu(ALU_SLTU,samples[i],samples[j],{31'b0,(samples[i]<samples[j])});
        test_alu(ALU_XOR,samples[i],samples[j],samples[i]^samples[j]);
        test_alu(ALU_OR,samples[i],samples[j],samples[i]|samples[j]);
        test_alu(ALU_AND,samples[i],samples[j],samples[i]&samples[j]);
        test_alu(ALU_PASS_B,samples[i],samples[j],samples[j]);
      end
      for(j=0;j<64;j=j+1) begin
        test_alu(ALU_SLL,samples[i],j,samples[i]<<(j&31));
        test_alu(ALU_SRL,samples[i],j,samples[i]>>(j&31));
        test_alu(ALU_SRA,samples[i],j,$signed(samples[i])>>>(j&31));
      end
    end
    rng=32'h01c0ffee;
    for(i=0;i<512;i=i+1) begin
      rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]}; a=rng;
      rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]}; b=rng;
      test_alu(ALU_SLT,a,b,{31'b0,($signed(a)<$signed(b))});
      test_alu(ALU_SLTU,a,b,{31'b0,(a<b)});
      test_alu(ALU_SRA,a,b,$signed(a)>>>b[4:0]);
    end

    // All lane offsets, legal sizes and signedness. Byte high-bit patterns cover
    // positive, negative and zero; halfwords exercise both high and low halves.
    for(mode=0;mode<2;mode=mode+1) begin
      store=mode[0];
      for(f3=0;f3<8;f3=f3+1) begin
        if ((mode==1 && f3<=2) || (mode==0 && (f3<=2 || f3==4 || f3==5))) begin
          funct3=f3[2:0];
          width=(f3==0 || f3==4)?1:((f3==1 || f3==5)?2:4);
          for(lane=0;lane<4;lane=lane+1) begin
            for(k=0;k<4;k=k+1) begin
              addr=32'h12345670+lane;
              case(k)
                0: begin read_data=32'h80ff7f01; store_data=32'ha1b2c3d4; end
                1: begin read_data=32'h00000000; store_data=32'hffffffff; end
                2: begin read_data=32'hffffffff; store_data=32'h00000000; end
                default: begin read_data=32'h7fff8000; store_data=32'h01234567; end
              endcase
              expected_misaligned=((width==2 && (lane&1)!=0) || (width==4 && lane!=0));
              expected_be=(width==1)?(4'b0001<<lane):((width==2)?(4'b0011<<lane):4'b1111);
              shifted=read_data>>(8*lane);
              case(f3)
                0: expected_data={{24{shifted[7]}},shifted[7:0]};
                1: expected_data={{16{shifted[15]}},shifted[15:0]};
                2: expected_data=read_data;
                4: expected_data={24'b0,shifted[7:0]};
                default: expected_data={16'b0,shifted[15:0]};
              endcase
              expected_mask={{8{expected_be[3]}},{8{expected_be[2]}},{8{expected_be[1]}},{8{expected_be[0]}}};
              #1;
              check(misaligned===expected_misaligned, "LSU alignment for every lane");
              if(!expected_misaligned) begin
                check(be===expected_be, "LSU byte-enable for every lane");
                if(store)
                  check((wdata&expected_mask)===((store_data<<(8*lane))&expected_mask), "Store data placement");
                else
                  check(load_data===expected_data, "Load sign/zero extension");
              end
            end
          end
        end
      end
    end

    // Write-enable suppression and a second asynchronous reset after the
    // registers contain data. A held reset must also suppress an active write.
    @(negedge clk); rd=5; rd_data=32'hbad0cafe; rd_we=0;
    @(posedge clk); #1; rs1=5; #1;
    check(rs1_data===32'hcaf00005, "RF disabled write preserves register");
    @(negedge clk); rd_we=1; rst_n=0; #1;
    check(rs1_data===32'b0, "RF asynchronous reset clears without clock edge");
    @(posedge clk); #1;
    check(rs1_data===32'b0, "RF held reset suppresses active write");
    @(negedge clk); rd_we=0; rst_n=1;
    for(i=0;i<32;i=i+1) begin
      rs1=i[4:0]; rs2=31-i; #1;
      check(rs1_data===32'b0 && rs2_data===32'b0, "All RF entries cleared on restart");
    end
    $display("PASS units: %0d checks", checks);
    $finish;
  end
endmodule
