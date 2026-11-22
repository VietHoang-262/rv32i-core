# Kiểm chứng

## Các lớp kiểm tra

Đợt audit lần theo toàn bộ kết nối CPU và bổ sung kiểm tra theo nhóm lệnh, trạng thái và giao thức. Không phát hiện lỗi đấu nối cần sửa; RTL và hành vi kiến trúc giữ nguyên. [Biên bản kết nối](connectivity-audit.md) ghi các đường đã kiểm tra.

`tb/tb_units.sv` kiểm tra decoder, ALU, register file và LSU trực tiếp. Decoder được quét trên toàn bộ tổ hợp opcode/funct3/funct7 với các trường thanh ghi cố định khác 0; một lượt riêng quét 4096 giá trị immediate SYSTEM × 8 funct3 × 3 biến thể rd/rs1. Đây là kiểm tra không gian encoding được mô tả, không phải quét toàn bộ `2^32` từ lệnh.

Immediate I của ALU/load/JALR và các immediate S/B được kiểm tra với toàn bộ 4.096 payload tương ứng. J/U dùng walking-one, walking-zero và 512 mẫu phối hợp để bắt lỗi tráo hoặc đứt dây ở các trường bit rời nhau. Các trường rs1/rs2/rd được quét trên cả 32 chỉ số.

Các kiểm tra ALU gồm giá trị biên signed/unsigned, phép dịch với số dịch 0–63 để xác nhận chỉ dùng 5 bit thấp, và các mẫu giả ngẫu nhiên có seed xác định. LSU kiểm tra cả bốn byte lane, hai vị trí halfword, alignment và nhiều mẫu dữ liệu để phân biệt sign/zero extension. Register file được kiểm tra reset, đọc/ghi độc lập và chặn ghi x0.

`scripts/gen_tests.py` chứa bộ mã hóa lệnh nhỏ và mô hình tham chiếu Python, không yêu cầu cross compiler RISC-V. Mô hình giải mã từ instruction bits độc lập với các tín hiệu điều khiển RTL, tạo chương trình, trace retirement, danh sách data transaction, nội dung bộ nhớ cuối và chẩn đoán mong đợi. Nó là scoreboard của dự án, không phải một simulator RISC-V đã được chứng nhận độc lập.

## Ma trận kiểm tra theo nhóm lệnh

Mỗi chương trình nhóm được chạy qua top-level `rv32i_core`, cùng decoder, register file, ALU, LSU, FSM và hai bộ nhớ. Chúng dùng chung testbench để không bỏ qua ảnh hưởng của fetch, stall, writeback hoặc lỗi truy cập.

| Chương trình | Lệnh trong nhóm | Điểm kiểm tra chính | Golden cố định |
|---|---|---|---:|
| `group_r_type` | ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND | Tràn 32-bit, signed/unsigned, dịch chỉ dùng 5 bit, rd trùng nguồn | 15 |
| `group_i_arithmetic` | ADDI, SLTI, SLTIU, XORI, ORI, ANDI | Immediate âm/biên, SLTIU với immediate âm đã sign-extend, x0 | 11 |
| `group_shift_imm` | SLLI, SRLI, SRAI | shamt 0/1/15/31, phân biệt logical/arithmetic với dữ liệu âm | 12 |
| `group_loads` | LB, LH, LW, LBU, LHU | Mọi lane hợp lệ, sign/zero extension, offset âm, đích x0 | 15 |
| `group_stores` | SB, SH, SW | Byte-enable, dịch dữ liệu vào lane, byte cuối và load đọc lại | 16 |
| `group_branches` | BEQ, BNE, BLT, BGE, BLTU, BGEU | Taken/not-taken cho từng điều kiện, equality, signed boundary, vòng lặp lùi | 2 |
| `group_u_type` | LUI, AUIPC | Upper immediate có bit dấu, AUIPC dùng đúng PC hiện tại | 4 |
| `group_jumps` | JAL, JALR | Link PC+4, offset âm, mask bit0, rd trùng rs1, đích x0 | 5 |
| `group_fence_system` | FENCE, EBREAK | FENCE thông thường/trường reserved, tiếp tục sau FENCE, sự kiện dừng EBREAK | 1 |
| `group_system_ecall` | ECALL | Cause và sự kiện ECALL riêng, không retire | 0 |

81 golden cố định được viết bằng hằng kết quả thanh ghi hoặc byte bộ nhớ, độc lập với hàm thông dịch `execute()`. Generator đối chiếu chúng trước khi phát trace; testbench tiếp tục đối chiếu trace và bộ nhớ với RTL. Golden cho branch là marker kết quả đường chạy; chúng không thay thế việc kiểm tra từng branch bằng trace. ECALL/EBREAK được kiểm tra bằng trạng thái dừng, không bằng retirement.

Ngoài các nhóm riêng còn có ba stream ISA seed 1/23/2026 và các chương trình directed cho illegal encoding, FENCE.I/CSR không hỗ trợ, lỗi alignment, lỗi access, load lỗi vào x0, target fetch ngoài vùng, JAL âm và JALR rd trùng rs1.

Bộ hiện tại có 61 chương trình: 10 chương trình nhóm và 51 chương trình regression. Mỗi chương trình chạy ở sáu lịch phản hồi dưới đây; thêm 10 lượt reset tạo thành 376 lượt cho mỗi trình mô phỏng.

| Lịch | Instruction memory | Data memory | Nhiễu ngoài completion |
|---|---|---|---|
| `zero` | 0 chu kỳ chờ | 0 chu kỳ chờ | Không |
| `one` | 1 chu kỳ chờ | 1 chu kỳ chờ | Không |
| `variable_noise` | 0–6 chu kỳ | 0–6 chu kỳ | Có |
| `fast_i_slow_d` | 0 chu kỳ | 31 chu kỳ | Có |
| `slow_i_fast_d` | 31 chu kỳ | 0 chu kỳ | Có |
| `long_variable` | 8–38 chu kỳ | 8–38 chu kỳ | Có |

Mười lượt bổ sung gồm ba kiểu reset cho từng fetch/load/store: đang stall, đã stall dài và ready vừa xuất hiện trước cạnh completion; lượt cuối reset sau ECALL/HALTED. Reset trước cạnh completion hủy transaction, vì giao dịch chưa handshake.

## Kiểm tra kết nối, trạng thái và giao thức

`tb/rv32i_core_checks.svh` kiểm tra các chân module thực tế cùng với tín hiệu nguồn bên core: IR→decoder, địa chỉ đọc RF, dữ liệu/enable ghi RF, toán hạng và control ALU, địa chỉ/data/control LSU, PC→imem và payload latched→dmem. Monitor này được dùng cùng scoreboard ISA, không dùng để thay thế mô hình tham chiếu.

Mọi chu kỳ đều kiểm tra PC chỉ đổi sau commit, IR chỉ đổi sau fetch thành công, operand chỉ đổi sau decode hợp lệ, và toàn bộ 32 thanh ghi chỉ đổi theo retirement. Nó chặn ghi x0, ghi khi fault, retirement lặp và nhiều data completion cho một lệnh. Testbench còn đối chiếu toàn bộ register file với `registers.hex` và toàn bộ data memory với `final.hex` khi dừng.

Memory model kiểm tra request không mất và payload giữ ổn định đến cả cạnh completion; store chỉ thay đổi bộ nhớ một lần tại handshake thành công. Bộ đếm completion riêng được so với trace. Các lượt giao thức bổ sung dùng độ trễ instruction/data độc lập, stall dài, idle ready=1 và error/read-data không hợp lệ ngoài completion, cùng reset khi đang chờ hoặc ngay trước cạnh completion. Đây là các kịch bản mô phỏng hữu hạn; không phải chứng minh liveness cho mọi backpressure.

## Coverage và chứng cứ

`build/cases/coverage.json` ghi các đường thực thi của mô hình tham chiếu đã được sinh, với 97 ngưỡng bắt buộc: 40 mnemonic, 12 branch outcomes, 20 tổ hợp memory lane, 4 trường hợp dấu LB/LH, 12 shamt immediate và 9 cause lỗi/sự kiện. ECALL/EBREAK tính theo sự kiện dừng; các lệnh illegal không được tính vào mnemonic hợp lệ.

File coverage sinh từ mô hình chưa tự chứng minh RTL đã chạy. `build/icarus_regression_summary.json` và `build/verilator_regression_summary.json` chỉ cộng metadata sau khi lượt RTL tương ứng kết thúc PASS và kiểm tra lại các ngưỡng; cần đọc trạng thái cùng số lượt đã hoàn tất. `metadata.json` trong từng case ghi nhóm, số retirement/transaction, golden và các điểm coverage cho chương trình đó.

## Kiểm tra khả năng bắt lỗi kết nối

`scripts/mutation_checks.py` tạo sáu bản sao RTL lỗi trong `build/mutations/`: đổi chỗ cổng đọc RF, bỏ mux immediate ALU, lật bit dữ liệu ghi RF, bỏ dịch byte lane store, tăng PC khi fetch stall và bỏ mask bit0 JALR. Baseline nguyên gốc phải PASS; chỉ lỗi FATAL rõ ràng từ testbench sau khi biên dịch thành công mới được tính là bắt được mutation. Lỗi cài đặt, lỗi biên dịch và timeout không được tính.

Script kiểm tra SHA256 để xác nhận RTL nguồn không đổi. Đây là smoke test với sáu lỗi được chọn, không phải phần trăm mutation coverage tổng quát.

## Chạy kiểm tra

```sh
cd rv32i-core
make test          # unit + toàn bộ regression Icarus
make lint          # lint riêng RTL
make synth         # sv2v + Yosys smoke synthesis
make crosscheck    # cùng regression trên Verilator timing simulator
make mutation-test # tùy chọn: sáu lỗi wiring có chủ đích
```

Chạy riêng từng nhóm bằng `make test-r-type`, `make test-i-arithmetic`, `make test-shift-imm`, `make test-loads`, `make test-stores`, `make test-branches`, `make test-u-type`, `make test-jumps` hoặc `make test-fence-system`. Mỗi target chạy top-level core với sáu lịch phản hồi. Target fence/system gồm hai chương trình để quan sát riêng ECALL và EBREAK; các lỗi SYSTEM vẫn nằm trong regression đầy đủ.

Cần Python 3 và Icarus Verilog (`iverilog`, `vvp`) cho `make test`; Verilator cho `make lint`; sv2v và Yosys cho synthesis smoke. Các biến Makefile `PYTHON`, `IVERILOG`, `IVERILOG_FLAGS`, `VVP`, `VERILATOR`, `BUILD` cho phép chọn công cụ và thư mục build. Script tổng hợp nhận biến môi trường `SV2V`, `YOSYS`.

Trong workspace giao nộp, công cụ đã được giải nén tại `/workspace/.tools`; có thể chạy lại bằng:

```sh
make test \
  IVERILOG=/workspace/.tools/iverilog/usr/bin/iverilog \
  IVERILOG_FLAGS="-B /workspace/.tools/iverilog/usr/lib/x86_64-linux-gnu/ivl" \
  VVP=/workspace/.tools/iverilog/usr/bin/vvp
make lint VERILATOR=/workspace/.tools/verilator/usr/bin/verilator_bin
bash scripts/synth.sh
```

`-B` chỉ đường dẫn backend cho bản Icarus được giải nén tại chỗ. Với bản cài đặt chuẩn, chỉ cần `make test`. Script synthesis tự tìm bản sv2v/Yosys trong thư mục `.tools` cạnh dự án khi không có trong PATH.

`make lint` bật `-Wall` và tắt riêng `UNUSEDSIGNAL`: LSU cố ý chỉ dùng hai bit thấp của effective address và các bit dữ liệu cần cho load subword. Điều này không tắt kiểm tra latch, độ rộng hay các cảnh báo khác.

## Kết quả đã ghi nhận

| Kiểm tra | Công cụ | Kết quả |
|---|---|---|
| Unit decoder/ALU/RF/LSU | Icarus Verilog 11.0 | **PASS — 518.036 kiểm tra** |
| Toàn core, tất cả nhóm/giao thức | Icarus Verilog 11.0 | **PASS — 61 case, 376 lượt, 97 ngưỡng coverage, 81 golden** |
| Cùng regression trên trình mô phỏng thứ hai | Verilator 5.006 timing | **PASS — 61 case, 376 lượt, 97 ngưỡng coverage, 81 golden** |
| Lint top `rv32i_core` | Verilator 5.006 | **PASS** với `-Wall -Wno-UNUSEDSIGNAL` |
| Generic synthesis và kiểm tra không latch | sv2v 0.0.13 + Yosys 0.23 | **PASS — 9.914 generic cells** |
| Smoke test khả năng bắt lỗi wiring | Icarus Verilog 11.0 | **PASS — baseline đúng; bắt 6/6 lỗi được chọn; RTL nguồn không đổi** |

Synthesis kiểm tra hierarchy, `check -assert`, không có latch và không còn process/memory chưa hạ cấp. Cảnh báo duy nhất là chuyển register-file memory thành các register, phù hợp với reset bất đồng bộ. Kết quả chưa được mapping công nghệ và chưa có timing/PPA. Verilator timing crosscheck cần thêm trình biên dịch C++ và make; TIMESCALEMOD/WIDTH chỉ được tắt trong flow testbench, tách biệt với lint RTL.

Chứng cứ được lưu trong [reports](reports):

- [Unit log](reports/units_audit.log), [Icarus log](reports/grouped_test.log), [Icarus summary](reports/icarus_regression_summary.json).
- [Verilator log](reports/verilator_regression.log), [Verilator summary](reports/verilator_regression_summary.json).
- [Coverage của generator](reports/coverage.json), [mutation log](reports/mutation-smoke.log), [mutation summary](reports/mutation_summary.json).
- [Lint log](reports/lint.log), [synthesis log](reports/synthesis.log).

Các JSON summary ghi kết quả từng lượt và từng nhóm để kiểm tra lại số liệu. `build/` chứa bản sinh lại, trace và netlist `rv32i_core.v`/`rv32i_core_synth.v`; thư mục này không đưa vào Git. Các thông báo constant-select sensitivity của Icarus xuất hiện khi biên dịch không phải lỗi mô phỏng; mọi lượt đã nêu kết thúc PASS.

## Giới hạn

Test theo trace và seed cố định giúp tái lập lỗi nhưng không chứng minh mọi chuỗi chương trình. Thiết kế chưa được chứng nhận bằng RISC-V architectural tests chính thức, chưa có formal proof/RVFI và chưa được sign-off timing, area, power hay CDC trên công nghệ đích. Việc tổng hợp thành công chỉ chứng minh khả năng đi qua flow tổng hợp đã dùng; không thay thế các bước sign-off đó.

Khi mở rộng pipeline, cache, bus hoặc privileged architecture, cần bổ sung kiểm tra hazard/flush, exception chính xác, memory ordering và các giao thức mới tương ứng.
