# Lõi RV32I multi-cycle bằng SystemVerilog

Dự án cung cấp lõi RV32I 32-bit không pipeline, điều khiển bằng FSM, với giao tiếp instruction/data riêng và cơ chế dừng có chẩn đoán khi gặp lỗi. RTL được chia thành decoder, ALU, register file, LSU và core để phục vụ kiểm chứng từng khối và phát triển SoC.

Đặc tả tham chiếu: **The RISC-V Instruction Set Manual, Volume I: Unprivileged ISA, phiên bản 20191213; RV32I Base Integer Instruction Set v2.1**. Đây là lõi thực thi RV32I với môi trường thực thi được giới hạn rõ bên dưới; chưa có privileged architecture, CSR hay trap handler.

## Nội dung

| Đường dẫn | Vai trò |
|---|---|
| `rtl/rv32i_pkg.sv` | Kiểu dữ liệu và tín hiệu điều khiển chung |
| `rtl/rv32i_decoder.sv` | Giải mã và tạo immediate, phát hiện encoding không hợp lệ |
| `rtl/rv32i_alu.sv` | Số học, logic, dịch và so sánh |
| `rtl/rv32i_regfile.sv` | 32 × 32-bit, hai cổng đọc, một cổng ghi; x0 cố định bằng 0 |
| `rtl/rv32i_lsu.sv` | Alignment, byte lane và sign/zero extension |
| `rtl/rv32i_core.sv` | Datapath đa chu kỳ, FSM, handshake, retirement và chẩn đoán |
| `tb/`, `tests/`, `scripts/` | Môi trường kiểm thử và công cụ chạy |
| [docs/architecture.md](docs/architecture.md) | ISA, datapath, FSM và hành vi dừng |
| [docs/integration.md](docs/integration.md) | Hợp đồng bộ nhớ, reset và tích hợp SoC |
| [docs/verification.md](docs/verification.md) | Ma trận nhóm lệnh, cách chạy và chứng cứ kiểm thử |
| [docs/connectivity-audit.md](docs/connectivity-audit.md) | Kiểm tra kết nối giữa các khối và đường điều khiển |

## Phạm vi thực thi

- XLEN = 32; 32 thanh ghi; little-endian; `IALIGN=32`.
- Hỗ trợ toàn bộ các phép RV32I đã yêu cầu: số học/logic R/I, load/store byte/halfword/word, branch, LUI, AUIPC, JAL và JALR.
- `FENCE` được giải mã và hoàn tất theo thứ tự như NOP khi nền tảng tuân thủ hợp đồng bộ nhớ của dự án.
- `ECALL` và `EBREAK` dừng lõi, đặt các tín hiệu sự kiện riêng và lưu thông tin chẩn đoán.
- `FENCE.I`, CSR, các lệnh SYSTEM còn lại và các extension M/C/A/F/D/custom đều không được hỗ trợ; encoding tương ứng gây illegal instruction.
- Mọi lỗi alignment, illegal instruction hoặc lỗi truy cập do nền tảng phản hồi đều dẫn tới trạng thái `HALTED`, không tiếp tục âm thầm.

Không có cache, speculative execution, interrupt, debug module, MMU/PMP, pipeline, AXI, DSP hoặc AI accelerator trong phiên bản này. Các hướng phát triển được trình bày trong tài liệu tích hợp và không phải tính năng đã triển khai.

## Sử dụng

Top-level là `rv32i_core`, tham số `RESET_PC` mặc định bằng `32'h0000_0000`. Biên dịch package trước các module sử dụng nó. Các file RTL không phụ thuộc testbench và không dùng cấu trúc mô phỏng để triển khai hành vi CPU.

Với Python 3, Icarus Verilog, Verilator, sv2v và Yosys có trong PATH:

```sh
git clone https://github.com/VietHoang-262/rv32i-core.git
cd rv32i-core
make test
make lint
make synth
make crosscheck
```

Kiểm chứng đã ghi nhận **518.036 unit checks**, **376 lượt toàn core trên Icarus và 376 lượt trên Verilator**, 40 mnemonic/97 ngưỡng coverage và 81 golden cố định; lint và synthesis smoke đều PASS. Các nhóm lệnh có target riêng như `make test-r-type`, `make test-loads`, `make test-branches`; [ma trận đầy đủ](docs/verification.md) liệt kê từng nhóm và tình huống kiểm tra. Công cụ, lệnh chạy và giới hạn kiểm chứng được ghi lại trong [docs/verification.md](docs/verification.md). Trước khi tích hợp, đọc kỹ [hợp đồng bộ nhớ](docs/integration.md): `ready` biểu thị **hoàn tất giao dịch**, không chỉ nhận yêu cầu. Hai cổng này là giao thức nội bộ riêng của dự án, không phải AXI4-Lite.

Audit kết nối không phát hiện lỗi cần sửa và không thay đổi RTL hoặc hành vi CPU. Log và JSON của đợt audit cùng regression theo nhóm được lưu trong [docs/reports](docs/reports).
