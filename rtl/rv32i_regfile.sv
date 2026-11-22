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
