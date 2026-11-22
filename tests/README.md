# Bộ kiểm chứng

Chạy `make test` từ thư mục gốc dự án với Icarus Verilog và Python 3.
`make unit` chạy riêng các khối; `make core-test` chạy riêng core. Không cần
RISC-V assembler hoặc cross compiler.

## Kiểm tra unit

`tb/tb_units.sv` thực hiện 233.420 kiểm tra tự động:

- Quét opcode × funct3 × funct7 để kiểm tra tính hợp lệ của giải mã, và quét
  SYSTEM với immediate/rd/rs1 biến thiên để phân biệt chính xác ECALL/EBREAK.
- Kiểm tra các immediate, shamt, phép toán signed/unsigned và dịch số học.
- Kiểm tra LSU với mọi byte lane, kích thước hợp lệ, alignment và dấu dữ liệu.
- Kiểm tra reset, đọc/ghi độc lập của regfile và bất biến x0.

## Kiểm tra core bằng mô hình tham chiếu

`scripts/gen_tests.py` có bộ mã hóa lệnh và bộ thông dịch RV32I độc lập với
RTL. Script sinh 51 chương trình cùng kết quả mong đợi trong `build/cases/`.
Ba chương trình chính dùng seed 1, 23, 2026; mỗi chương trình retire 647 lệnh
và hoàn tất 188 giao dịch dữ liệu trước EBREAK. Phần directed bao phủ mọi
nhóm lệnh, signed/unsigned, branch lấy/không lấy, vòng lặp, JAL âm, JALR
xóa bit 0 và rd bằng rs1, load/store mọi lane hợp lệ, FENCE và ghi x0.
Các trường hợp riêng kiểm tra illegal encoding, SYSTEM không hỗ trợ,
misalignment, access fault, load vào x0 vẫn phát lỗi, và reset PC không thẳng hàng.

Mỗi thư mục chương trình có:

| Tệp | Nội dung |
| --- | --- |
| `program.hex` | 1.024 word instruction memory, mỗi dòng 32-bit |
| `data.hex` | Bộ nhớ dữ liệu khởi tạo, 1.024 word little-endian |
| `final.hex` | Toàn bộ bộ nhớ dữ liệu mong đợi khi dừng |
| `retire.hex` | `pc inst rd_we rd wdata`, mọi trường dạng hex |
| `transactions.hex` | `byte_addr we be wdata`, mọi trường dạng hex |
| `config.hex` | `cause fault_pc tval ecall ebreak nret ndata imem_fault_addr dmem_fault_addr reset_pc` |

`tb/tb_core.sv` đối chiếu mỗi retirement và mỗi data completion, số lần fetch,
trạng thái lỗi và toàn bộ bộ nhớ cuối. Dữ liệu ghi chỉ so sánh các byte lane
enable. Lệnh gặp lỗi không retire. `tb/tb_latency_memory.sv` kiểm tra request
và toàn bộ payload giữ ổn định trong stall, hoàn tất store đúng một lần tại
handshake và không ghi bộ nhớ khi phản hồi lỗi.

`scripts/run_tests.py` chạy mọi chương trình ở ba chế độ phản hồi: không chờ,
chờ một chu kỳ và độ trễ biến thiên 0–6 chu kỳ. Ngoài 153 lượt này, bốn lượt
kiểm tra reset khi fetch/load/store đang stall và reset phục hồi từ HALTED.
Tổng cộng **157 lượt core**. Mọi lượt phải PASS; lỗi đầu tiên làm tiến trình
trả mã khác 0.

Có thể chạy một trường hợp để debug sau `make generate` và biên dịch testbench:

```sh
vvp build/tb_core.vvp +case=build/cases/isa_seed_1 +latency=2
```

`reset_pc_align` dùng binary `build/tb_core_pc2.vvp` vì RESET_PC là parameter
elaboration. Các trường hợp reset đang stall dùng `+reset_mode=1` cho fetch,
`+reset_mode=2` cho dữ liệu; reset từ HALTED dùng `+restart_halted=1`.

## Giới hạn chứng cứ

Đây là kiểm tra directed và seeded differential với mô hình cục bộ; chưa phải
bộ kiểm tra tương thích RISC-V chính thức, formal proof hoặc sign-off silicon.
`make lint` kiểm tra RTL bằng Verilator. `make synth` chạy smoke synthesis
sv2v/Yosys trong `scripts/synth.sh`; kết quả generic không chứng minh timing
hoặc PPA trên một công nghệ cụ thể.
