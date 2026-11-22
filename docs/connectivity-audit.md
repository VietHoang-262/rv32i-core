# Rà soát kết nối datapath và điều khiển

## Kết luận và phạm vi

Đã lần theo các kết nối của toàn bộ core từ instruction memory tới decoder, register file, operand registers, ALU/branch/LSU, writeback, PC và các đường lỗi/reset. Không phát hiện lỗi đấu nối trong bản RTL được rà soát. Hai lượt đọc RTL độc lập cho cùng kết luận; không cần sửa RTL trong đợt audit này.

Audit gồm đọc nguồn, kiểm tra trực tiếp các module và đối chiếu hành vi toàn core. Đây không phải chứng minh formal cho mọi giá trị hoặc mọi chuỗi chương trình. Core vẫn thực hiện RV32I multi-cycle với diagnostic halt; không có CSR, trap handler hay AXI trong phạm vi này.

Nguồn chính: [core](../rtl/rv32i_core.sv), [decoder](../rtl/rv32i_decoder.sv), [register file](../rtl/rv32i_regfile.sv), [ALU](../rtl/rv32i_alu.sv), [LSU](../rtl/rv32i_lsu.sv). Số dòng dưới đây ứng với bản nguồn tại thời điểm audit.

## Bảng kết nối

| Đường nối | Nguồn → đích và thời điểm | Điều kiện đúng đã kiểm tra | Bằng chứng |
|---|---|---|---|
| Fetch address | `pc_q[31:0]` → `imem_addr[31:0]` | Không mất bit địa chỉ; request chỉ bật ở FETCH_REQ/FETCH_WAIT và khi PC chia hết cho 4 | core:98–100, 150–160; trace PC và lỗi reset-PC/fetch |
| Fetch data | `imem_rdata[31:0]` → `inst_q[31:0]` | Chỉ chốt khi fetch hoàn tất và không có `imem_error`; giữ nguyên instruction qua execute/memory/writeback | core:153–158; scoreboard instruction từng retirement |
| Decoder input | `inst_q` → `u_decoder.inst_i` → `dec` | Không giải mã trực tiếp bus đang thay đổi; controls ổn định khi dmem stall | core:56; quét legality và control map trong unit test |
| Source indices | `inst[19:15]`, `inst[24:20]` → `dec.rs1/rs2` → hai read port RF | Không hoán đổi rs1/rs2; cả 5 bit chỉ số được giữ; hai cổng đọc độc lập | decoder:22–23, core:59–60; unit sweep mọi bit rs1/rs2 và mọi RF entry |
| Operand snapshots | `rs1_data/rs2_data` → `rs1_q/rs2_q` | Chốt tại DECODE trước EXECUTE; không lấy giá trị link vừa ghi làm nguồn JALR khi `rd=rs1` | core:162–168; `jalr_same_rd_rs1`, trace các phép toán phụ thuộc |
| Immediate | Instruction fields → `dec.imm[31:0]` | I/S/B/J sign extension đúng; U giữ bits 31:12 và thêm 12 zero; shift chỉ dùng bits 24:20 | decoder:50–65, 77, 86, 94–95, 112, 119, 125–126, 132; unit immediate sweeps |
| ALU operand A | `rs1_q[31:0]` → `u_alu.a_i` | Dùng operand đã chốt; LUI/AUIPC có lựa chọn kết quả riêng đúng ngữ nghĩa | core:65, 175–177; ALU unit và trace R/I/U |
| ALU operand B/control | `dec.alu_src_imm ? dec.imm : rs2_q` → `u_alu.b_i`, `dec.alu_op` → `op_i` | R dùng rs2; I dùng imm; exact OP/OP-IMM mapping; shifts chỉ dùng low 5 bits | core:63–65; decoder control-map sweep, ALU shift 0–63 |
| ALU result | `alu_result[31:0]` → `result_q` | Chốt ở EXECUTE cho IK_ALU; không ghi RF ngay trong EXECUTE | core:175, 112–113; unit ALU và retirement data |
| Branch operands/control | `rs1_q/rs2_q`, `dec.branch` → `branch_taken` | EQ/NE, signed LT/GE và unsigned LTU/GEU đúng; branch không ghi RF | core:80–90; decoder branch map, taken/not-taken traces |
| Control target | `pc_q + dec.imm`; JALR dùng `(rs1_q + dec.imm) & 0xffff_fffe` | Giữ phép cộng modulo 32 bit; chỉ xóa bit 0 JALR rồi kiểm tra IALIGN=32; branch không taken không lỗi target alignment | core:91–94, 178–191; JAL âm, JALR rd=rs1, target bit 1, branch alignment |
| Link/U result | `pc_q+4`, `dec.imm`, `pc_q+dec.imm` → `result_q` | JAL/JALR ghi link của PC hiện tại; LUI/AUIPC không bị ảnh hưởng các register fields nằm trong immediate | core:176–183; trace các nhóm U/jump |
| Effective address | `rs1_q + dec.imm` → `effective_addr` → `lsu_addr` tại EXECUTE | Không xóa low bits trước alignment check; không phát request nếu alignment sai | core:67–68, 193–202; LSU mọi offset, load/store alignment faults |
| Store source/lane | `rs2_q` → LSU → `lsu_wdata/lsu_be` | Shift theo `addr[1:0]*8`; byte lane 0/1/2/3, halfword lane 0/2, word 0; low bits địa chỉ bus vẫn giữ nguyên | core:74–77; LSU lane/data checks và transaction scoreboard |
| Latched bus payload | `effective_addr`, `dec.kind`, `lsu_wdata/be` → `mem_addr_q/we_q/wdata_q/be_q` → dmem outputs | Chốt một lần trước MEM_REQ; giữ toàn bộ payload trong MEM_REQ/MEM_WAIT; không tính lại từ bus response | core:102–105, 198–202; memory model kiểm tra payload khi stall |
| Read response | `dmem_rdata` → LSU cùng `mem_addr_q` → `lsu_load` → `result_q` | Chọn lane bằng địa chỉ transaction đã chốt; LB/LH sign extend, LBU/LHU zero extend, LW đủ 32 bits; chỉ chốt khi hoàn tất không lỗi | core:68–77, 211–219; LSU unit, load traces và final RF effects |
| RF writeback | `result_q`, `dec.rd`, `retire_rd_we` → RF data/index/enable | Chỉ một edge WRITEBACK; `rd_we` phải được decoder cho phép; x0 bị chặn ở cả core và RF | core:61, 107–113; regfile:16–24; retirement scoreboard, x0 load/access-fault tests |
| PC commit | `next_pc_q` → `pc_q` | Ngoài reset, chỉ cập nhật tại WRITEBACK; default PC+4, branch taken/jump chọn target; load/store đợi completion | core:172, 183, 190, 223; retirement PC sequence, latency 0/1/0–6 |
| Fault/event output | illegal/alignment/access/ECALL/EBREAK → `stop_with_fault` → HALTED và diagnostic outputs | Địa chỉ lỗi hoặc illegal instruction đến đúng `fault_tval`; PC lỗi là PC hiện tại; không có WRITEBACK cho lệnh lỗi; event ECALL/EBREAK tách biệt và sticky | core:116–126, 150–168, 178–208, 211–219; fault config/trace, halt-quiescence checks |
| Reset | `rst_ni` → core state/registers, RF và request/retire gating | Reset bất đồng bộ đưa state về FETCH_REQ, PC về RESET_PC, xóa diagnostics/RF; req và retire bị chặn ngay khi reset | core:98–107, 129–147; RF reset unit, reset khi chờ fetch/load/store và restart HALTED |

LUI/AUIPC/jump không cần dùng kết quả ALU chung: các mux kết quả thể hiện bằng `case (dec.kind)` tại EXECUTE. Store/branch/FENCE có thể giữ giá trị `result_q` cũ, nhưng `dec.rd_we=0`, nên dữ liệu đó không được ghi vào RF. Trace chỉ coi `retire_wdata` có nghĩa khi `retire_rd_we=1`.

## FSM và các điểm loại trừ side effect

FETCH_REQ/FETCH_WAIT cùng giữ `imem_req=1`; MEM_REQ/MEM_WAIT cùng giữ `dmem_req=1`. State rời nhóm request ngay sau cạnh clock có completion; do đó request là một khoảng liên tục tới completion, không phải hai giao dịch. State instruction và data tách biệt nên chỉ có một giao dịch trên toàn core tại một thời điểm.

Illegal instruction dừng tại DECODE. Load/store misalignment dừng tại EXECUTE trước khi vào MEM_REQ. Target alignment của jump và branch taken được kiểm tra trước khi WRITEBACK. Access error dừng tại cạnh completion; load lỗi không chốt dữ liệu và store lỗi không đi vào WRITEBACK. ECALL/EBREAK cũng dừng ở EXECUTE. Trong EXECUTE có default assignment sang WRITEBACK, nhưng `stop_with_fault` được gọi sau assignment đó và ghi HALTED trong cùng procedural block; HALTED là assignment cuối có hiệu lực, không xuất hiện một chu kỳ WRITEBACK trung gian.

FENCE hợp lệ đi qua EXECUTE/WRITEBACK mà không phát data request. Điều này đáp ứng phạm vi ordering đã quy định vì core không có cache, prefetch, write buffer hoặc transaction outstanding qua biên instruction. FENCE.I và CSR vẫn illegal.

## Khoảng trống kiểm thử đã bổ sung

Unit test ban đầu quét legality rộng nhưng chỉ có vài mẫu cho immediate và chưa đối chiếu đầy đủ control kind/enable. Đã bổ sung vào [tb_units.sv](../tb/tb_units.sv):

- Đối chiếu register fields, funct3, instruction kind, `rd_we`, operand-immediate select và branch select trong sweep opcode/funct3/funct7; kiểm tra mọi ALU operation hợp lệ và chặn quyền ghi/branch trên decode illegal.
- Kiểm tra cả 5 bit của rs1, rs2, rd với mọi chỉ số 0–31.
- Exhaustive 4096 payload I-immediate cho ADDI/load/JALR và 4096 payload cho từng S/B-immediate. B kiểm tra mọi offset chẵn trong khoảng −4096…4094, kể cả target lệch 2 byte ở cấp decoder.
- Walking-one, walking-zero trên mọi bit immediate J/U; thêm 512 pattern trộn bit có seed cố định. Đây không phải exhaustive toàn bộ không gian J/U.
- Kiểm tra RF giữ dữ liệu khi write enable bằng 0; reset bất đồng bộ sau khi đã ghi dữ liệu; held reset chặn write đang bật; mọi entry về 0 sau restart.

Kết quả chạy Icarus Verilog 11.0 sau các bổ sung: **PASS, 518.036 kiểm tra**. Log: `build/units_audit.log`; compile log: `build/units_audit_compile.log`. Các thông báo Icarus về constant-select sensitivity của `always_comb` là giới hạn lập sensitivity list của công cụ; lần chạy kết thúc PASS. Không thay đổi RTL để xử lý các thông báo này.

Lệnh tái lập trong workspace hiện tại:

```sh
/workspace/.tools/iverilog/usr/bin/iverilog \
  -B /workspace/.tools/iverilog/usr/lib/x86_64-linux-gnu/ivl \
  -g2012 -s tb_units -o build/tb_units_audit.vvp \
  -f rtl/rtl.f tb/tb_units.sv
/workspace/.tools/iverilog/usr/bin/vvp build/tb_units_audit.vvp
```

`make unit` dùng cùng testbench với công cụ cài đặt chuẩn. Các chương trình toàn core, kiểm tra giao thức và kết quả tổng hợp được mô tả ở [verification.md](verification.md); cần chạy lại regression khi thay đổi kết nối hoặc control logic.

## Ràng buộc tích hợp còn hiệu lực

Core không tự xác định memory map, permissions hoặc thiết bị đích: platform phát `imem_error`/`dmem_error` cùng completion cho truy cập không hợp lệ. Slave/adapter phải không gây store side effect khi trả error. Reset chung phải hủy transaction đang chờ ở cả core lẫn memory/adapter; transaction đã hoàn tất trước reset vẫn là một side effect đã xảy ra. Đây là các điều kiện của giao thức tích hợp, không phải một lỗi dây nối hoặc chức năng privileged bị thiếu trong phạm vi ISA đã công bố.
