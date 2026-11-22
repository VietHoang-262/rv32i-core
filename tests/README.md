# Bộ kiểm chứng

Chạy `make test` với Icarus Verilog/Python 3; không cần cross compiler.
`make crosscheck` chạy cùng bộ core test bằng Verilator timing simulator.
`IVERILOG`, `IVERILOG_FLAGS`, `VVP`, `VERILATOR`, `PYTHON`, `BUILD` có thể override
trên dòng lệnh Make. `JOBS` điều chỉnh số job biên dịch C++ của crosscheck.

## Các nhóm lệnh độc lập

Mỗi chương trình `group_*` có thể chạy riêng qua target tương ứng. Chúng dùng
chung testbench full-core `tb/tb_core.sv`, nhưng có chương trình, trace, golden
và báo cáo riêng. Mỗi target chạy sáu lịch phản hồi bộ nhớ như regression đầy đủ.

| Target | Chương trình | Lệnh chính | Golden cố định |
| --- | --- | --- | ---: |
| `make test-r-type` | `group_r_type` | ADD SUB SLL SLT SLTU XOR SRL SRA OR AND | 15 |
| `make test-i-arithmetic` | `group_i_arithmetic` | ADDI SLTI SLTIU XORI ORI ANDI | 11 |
| `make test-shift-imm` | `group_shift_imm` | SLLI SRLI SRAI, shamt 0/1/15/31 | 12 |
| `make test-loads` | `group_loads` | LB LH LW LBU LHU, mọi lane hợp lệ | 15 |
| `make test-stores` | `group_stores` | SB SH SW, byte enable/little-endian | 16 |
| `make test-branches` | `group_branches` | BEQ BNE BLT BGE BLTU BGEU lấy/không lấy | 2 |
| `make test-u-type` | `group_u_type` | LUI AUIPC, U immediate âm và PC khác 0 | 4 |
| `make test-jumps` | `group_jumps` | JAL JALR, link/offset âm/rd trùng rs1/bit 0 | 5 |
| `make test-fence-system` | `group_fence_system`, `group_system_ecall` | FENCE ECALL EBREAK | 1 |

81 golden là các kết quả thanh ghi hoặc byte bộ nhớ viết bằng hằng số thủ công,
kiểm tra mô hình tham chiếu trước khi mô hình phát trace cho RTL. Chúng bổ sung
cho so sánh vi sai, không được đếm là số phép kiểm tra unit. Các góc khác gồm
tràn số modulo 32-bit, so sánh signed/unsigned trái ngược, immediate âm,
shift register có lượng dịch 32 hoặc -1, rd trùng rs1/rs2 và bảo toàn x0.

## Kiểm tra unit

`make unit` chạy `tb/tb_units.sv` với 518.036 kiểm tra tự động, gồm quét
opcode × funct3 × funct7, SYSTEM chính xác với immediate/rd/rs1 biến thiên,
kiểm tra giá trị immediate bằng walking-bit, ALU signed/unsigned/shift,
LSU lane/alignment/sign extension và regfile reset/x0.

## Regression core và protocol

`scripts/gen_tests.py` mã hóa chương trình và thực thi chúng bằng bộ thông dịch
RV32I độc lập với RTL. Tổng cộng 61 chương trình: giữ 51 chương trình regression
cũ và thêm 10 chương trình theo nhóm ở trên. Ba chương trình seed 1/23/2026
mỗi chương trình retire 647 lệnh với 188 giao dịch dữ liệu trước EBREAK.
Các case riêng kiểm tra illegal, SYSTEM không hỗ trợ, misalignment, lỗi truy cập,
load vào x0 vẫn gây lỗi, PC reset không thẳng hàng và reset giữa giao dịch.

`scripts/run_tests.py` chạy từng chương trình với sáu lịch:

1. Instruction/data không chờ.
2. Cùng chờ một chu kỳ.
3. Cùng biến thiên 0–6 chu kỳ, có tín hiệu phản hồi nhiễu ngoài completion.
4. Instruction không chờ, data chờ 31 chu kỳ, có nhiễu.
5. Instruction chờ 31 chu kỳ, data không chờ, có nhiễu.
6. Hai cổng cùng biến thiên 8–38 chu kỳ, có nhiễu.

366 lượt này cộng 10 lượt reset tạo thành **376 lượt core mỗi simulator**.
Reset được thử khi fetch/load/store đang stall, sau năm chu kỳ chờ dài, khi ready
đã lên nhưng chưa tới cạnh completion, và phục hồi từ HALTED. Mọi lượt có
wall-clock timeout mặc định 60 giây (`--timeout`), bên cạnh timeout trong SV.

Mỗi lượt đối chiếu từng retirement, từng data completion, số lần fetch, toàn bộ
1.024 word bộ nhớ và cả 32 thanh ghi cuối. Responder kiểm tra payload ổn định,
giữ request tới completion, đếm completion độc lập và không ghi khi lỗi/reset.
Checker `tb/rv32i_core_checks.svh` kiểm tra thêm FSM/PC/writeback/gating lỗi.

## Định dạng dữ liệu và báo cáo

Các tệp sinh trong `build/cases/<case>/`:

| Tệp | Nội dung |
| --- | --- |
| `program.hex` | 1.024 word instruction memory, mỗi dòng 32-bit |
| `data.hex` | 1.024 word bộ nhớ dữ liệu khởi tạo little-endian |
| `final.hex` | Toàn bộ bộ nhớ dữ liệu mong đợi khi dừng |
| `registers.hex` | Giá trị mong đợi x0–x31 khi dừng |
| `retire.hex` | `pc inst rd_we rd wdata`, các trường dạng hex |
| `transactions.hex` | `byte_addr we be wdata`, các trường dạng hex |
| `config.hex` | `cause fault_pc tval ecall ebreak nret ndata imem_fault_addr dmem_fault_addr reset_pc` |
| `metadata.json` | `name`, `group`, `coverage`, `golden_checks`, `retirements`, `transactions`, `halt_cause` |

`build/cases/coverage.json` chứa `status`, `source`, `counts`, `minimums`, `cases`.
97 gate bắt buộc gồm đủ 40 mnemonic, mỗi branch có lấy/không lấy, mỗi lane load/store
hợp lệ, dấu LB/LH, shamt 0/1/15/31 và mọi mã lỗi đã hỗ trợ. ECALL/EBREAK được đếm
là halt event; lệnh illegal không tăng bộ đếm mnemonic hợp lệ.

`build/icarus_regression_summary.json` và
`build/verilator_regression_summary.json` chứa `status`, `engine`, `case_count`,
`run_count`, `golden_checks`, `coverage`, `groups`, `runs`. Bộ đếm coverage trong
báo cáo chỉ lấy mỗi case đã PASS một lần; không nhân lên theo số lịch. Thiếu gate,
thiếu dòng PASS, lỗi simulator hoặc timeout đều làm runner trả mã lỗi. Đây là
coverage của đường thực thi tham chiếu đã được RTL đối chiếu thành công, không
phải statement/toggle coverage của simulator.

Ví dụ debug một case sau khi sinh/biên dịch:

```sh
vvp build/tb_core.vvp +case=build/cases/group_loads +imem_latency=0 +dmem_latency=3 +idle_noise=1
```

`reset_pc_align` dùng binary `build/tb_core_pc2.vvp` với RESET_PC=2 khi elaboration.
`+reset_mode=1` chọn reset fetch, `+reset_mode=2` chọn dữ liệu;
`+reset_wait=5` trì hoãn reset trong stall dài; `+reset_completion=1` reset trước
cạnh completion; `+restart_halted=1` reset từ HALTED.

## Các kiểm tra bổ sung và giới hạn

`make lint` kiểm tra RTL bằng Verilator; `make synth` chạy sv2v/Yosys generic
synthesis, không chứng minh timing/PPA trên công nghệ cụ thể.
`make mutation-test` chạy riêng các đột biến dây nối có chủ đích trên bản sao RTL
để xác nhận checker phát hiện lỗi; không sửa source RTL và không thuộc `make test`.

Đây là directed/seeded differential test với mô hình cục bộ, không phải bộ kiểm tra
RISC-V compliance chính thức, formal proof hoặc silicon sign-off.
