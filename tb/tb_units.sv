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
    $display("PASS units: %0d checks", checks);
    $finish;
  end
endmodule
