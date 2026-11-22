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
