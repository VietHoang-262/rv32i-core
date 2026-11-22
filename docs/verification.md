# Kiểm chứng

## Các lớp kiểm tra

`tb/tb_units.sv` kiểm tra decoder, ALU, register file và LSU trực tiếp. Decoder được quét trên toàn bộ tổ hợp opcode/funct3/funct7 với các trường thanh ghi cố định khác 0; một lượt riêng quét 4096 giá trị immediate SYSTEM × 8 funct3 × 3 biến thể rd/rs1. Đây là kiểm tra không gian encoding được mô tả, không phải quét toàn bộ `2^32` từ lệnh.

Các kiểm tra ALU gồm giá trị biên signed/unsigned, phép dịch với số dịch 0–63 để xác nhận chỉ dùng 5 bit thấp, và các mẫu giả ngẫu nhiên có seed xác định. LSU kiểm tra cả bốn byte lane, hai vị trí halfword, alignment và nhiều mẫu dữ liệu để phân biệt sign/zero extension. Register file được kiểm tra reset, đọc/ghi độc lập và chặn ghi x0.

`scripts/gen_tests.py` chứa bộ mã hóa lệnh nhỏ và mô hình tham chiếu Python, không yêu cầu cross compiler RISC-V. Mô hình giải mã từ instruction bits độc lập với các tín hiệu điều khiển RTL, tạo chương trình, trace retirement, danh sách data transaction, nội dung bộ nhớ cuối và chẩn đoán mong đợi. Nó là scoreboard của dự án, không phải một simulator RISC-V đã được chứng nhận độc lập.

Bộ regression có 51 chương trình: ba stream ISA với seed 1/23/2026 và các chương trình kiểm tra hành vi hoặc lỗi riêng. Mỗi chương trình được chạy với ba lịch phản hồi: hoàn tất ngay, chờ một chu kỳ và độ trễ thay đổi 0–6 chu kỳ. Bốn lượt bổ sung kiểm tra reset trong lúc chờ fetch/load/store và reset sau HALTED, tổng cộng 157 lượt toàn core.

Coverage có mọi nhóm lệnh hỗ trợ, branch taken/not-taken, immediate âm, JAL âm, JALR có rd trùng rs1, load đích x0 kể cả khi access fault, load/store và các lỗi illegal, FENCE.I/CSR không hỗ trợ, alignment, access, ECALL/EBREAK. Testbench toàn core so sánh retirement, transaction và bộ nhớ cuối với kết quả tham chiếu; kiểm tra payload ổn định khi stall, không mất request, không lặp completion, không đồng thời fetch/data và trạng thái halt yên lặng, sticky.

## Chạy kiểm tra

```sh
cd rv32i-core
make test       # unit test + regression toàn core
make lint       # Verilator, kiểm tra top rv32i_core
bash scripts/synth.sh  # sv2v + Yosys, smoke check tổng hợp
make generate && bash scripts/crosscheck.sh  # mô phỏng đối chiếu bằng Verilator
```

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

- Icarus Verilog 11.0: unit test **PASS, 233.420 kiểm tra**.
- Synthesis smoke với sv2v 0.0.13 và Yosys 0.23: **PASS** cho hierarchy, generic synthesis, `check -assert` và kiểm tra không có latch. Flow tạo 9.914 generic cells, không còn process hay memory chưa hạ cấp. Cảnh báo duy nhất là chuyển register-file memory thành các register, phù hợp với reset bất đồng bộ. Đây chưa phải netlist đã mapping công nghệ hoặc kết quả timing/PPA.
- Icarus Verilog 11.0: regression toàn core **PASS, 157 lượt chạy**. Mỗi stream ISA chính retire 647 lệnh và hoàn tất 188 data transaction; số chu kỳ lần lượt là 2.784 / 3.620 / 5.292 với các lịch latency 0 / 1 / thay đổi.
- Verilator 5.006: `make lint` **PASS** với cờ đã nêu; không còn cảnh báo chưa được xử lý.
- Verilator 5.006: mô phỏng timing độc lập **PASS, 157 lượt toàn core**, dùng cùng chương trình và scoreboard với Icarus. Script `scripts/crosscheck.sh` cần thêm trình biên dịch C++ và make; các cờ TIMESCALEMOD/WIDTH chỉ được tắt trong flow testbench này, tách biệt với lint RTL.
- Log tại thời điểm chạy: `build/test.log`, `build/lint.log`, `build/synthesis.log`. Netlist chuyển đổi và tổng hợp: `build/rv32i_core.v`, `build/rv32i_core_synth.v`. Các file build là sản phẩm sinh lại được.
- Log đối chiếu trình mô phỏng thứ hai: `build/verilator_regression.log`.

Bản sao log của lần kiểm chứng ban đầu được lưu trong [reports](reports). Thư mục `build/` chứa sản phẩm sinh lại được và không đưa vào Git.

## Giới hạn

Test theo trace và seed cố định giúp tái lập lỗi nhưng không chứng minh mọi chuỗi chương trình. Thiết kế chưa được chứng nhận bằng RISC-V architectural tests chính thức, chưa có formal proof/RVFI và chưa được sign-off timing, area, power hay CDC trên công nghệ đích. Việc tổng hợp thành công chỉ chứng minh khả năng đi qua flow tổng hợp đã dùng; không thay thế các bước sign-off đó.

Khi mở rộng pipeline, cache, bus hoặc privileged architecture, cần bổ sung kiểm tra hazard/flush, exception chính xác, memory ordering và các giao thức mới tương ứng.
