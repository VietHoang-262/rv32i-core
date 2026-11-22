# Hợp đồng bộ nhớ và tích hợp SoC

## Clock và reset

Lõi dùng `clk_i` và reset bất đồng bộ active-low `rst_ni`. Reset đưa PC về tham số `RESET_PC`, xóa trạng thái dừng/chẩn đoán và đưa register file về giá trị xác định. Việc xóa x1–x31 là lựa chọn của thiết kế này, không phải yêu cầu của ISA. Hệ thống thực cần đồng bộ quá trình nhả reset theo clock của lõi.

Reset phải bao phủ core và adapter/slave hoặc có cơ chế hủy giao dịch đồng nhất. Nếu reset xảy ra trong lúc một giao dịch đang chờ, core bỏ transaction nội bộ và bắt đầu lại từ RESET_PC khi nhả reset. Adapter không được trả một phản hồi cũ như thể đó là phản hồi của request mới. Store đã hoàn tất trước reset giữ nguyên side effect; reset core không có nghĩa rollback bộ nhớ.

`RESET_PC` cần chia hết cho 4 và trỏ đến vùng instruction hợp lệ. Nếu sai alignment, core dừng với cause 0 trước khi phát instruction request.

## Hai giao diện độc lập

| Tín hiệu | Chiều nhìn từ core | Ý nghĩa |
|---|---|---|
| `imem_req` | out | Yêu cầu đọc instruction |
| `imem_ready` | in | Giao dịch instruction đã hoàn tất |
| `imem_addr[31:0]` | out | Địa chỉ byte của instruction |
| `imem_rdata[31:0]` | in | Instruction 32-bit tại thời điểm hoàn tất |
| `imem_error` | in | Lỗi instruction access tại thời điểm hoàn tất |
| `dmem_req` | out | Yêu cầu data transaction |
| `dmem_ready` | in | Giao dịch data đã hoàn tất |
| `dmem_we` | out | 1=store, 0=load |
| `dmem_be[3:0]` | out | Byte lane được truy cập trong từ 32-bit |
| `dmem_addr[31:0]` | out | Effective byte address đầy đủ |
| `dmem_wdata[31:0]` | out | Dữ liệu ghi đã dịch vào lane đúng |
| `dmem_rdata[31:0]` | in | Từ 32-bit chứa các byte được đọc |
| `dmem_error` | in | Lỗi data access tại thời điểm hoàn tất |

Các tín hiệu lỗi là phần mở rộng cần thiết để nền tảng báo lỗi truy cập. Chúng chỉ có hiệu lực khi cùng cổng có `req && ready`. Với slave không sinh lỗi, nối error bằng 0; khi đó core không tự phát hiện truy cập ngoài vùng nếu slave không kiểm tra.

### Handshake

Một giao dịch hoàn tất tại cạnh lên có `req=1 && ready=1`. Core giữ request và payload ổn định trong toàn bộ thời gian `req=1 && ready=0`. Slave có thể hoàn tất ngay trong chu kỳ đầu hoặc chèn số chu kỳ chờ tùy ý. Error và read data chỉ được lấy mẫu tại cạnh hoàn tất.

```text
clock edge       A       B       C       D       E
req              1       1       1       0       0
ready            0       0       1       -       -
addr/payload     P       P       P       -       -
                         chờ    hoàn tất một lần
```

Core rút request ở chu kỳ sau handshake và không phát lại transaction đó. Slave không được coi mỗi chu kỳ req=1 trong khoảng chờ là một request mới. Với store, chỉ áp dụng byte-enable và thay đổi bộ nhớ **một lần** tại handshake thành công.

Chỉ có một giao dịch outstanding trên mỗi cổng. Kiến trúc hiện tại còn tuần tự hóa hai cổng: không có data transaction chạy song song với fetch tiếp theo. Không có hàng đợi store, prefetch hoặc đáp ứng out-of-order.

Nếu slave không bao giờ đưa ready lên 1, core sẽ chờ vô hạn. Phiên bản này không có timeout. Hệ thống có yêu cầu timeout nên đặt bộ giám sát trong adapter, kết thúc transaction bằng `ready=1,error=1` khi chính sách nền tảng yêu cầu.

### Lỗi truy cập và phạm vi địa chỉ

Core kiểm tra encoding và alignment; nền tảng kiểm tra vùng địa chỉ hợp lệ, quyền đọc/ghi/thực thi và lỗi thiết bị. Slave phải hoàn tất request bị từ chối với `ready=1,error=1`, không được để chờ vô hạn chỉ vì địa chỉ không hợp lệ.

Với store lỗi, nền tảng phải bảo đảm **không ghi bất kỳ byte nào**. Lõi có thể ngăn ghi thanh ghi kiến trúc nhưng không thể hoàn tác một side effect đã bị slave thực hiện trước khi báo lỗi. Đối với MMIO load có side effect, nền tảng cũng phải định nghĩa việc lỗi có thể xảy ra trước hay sau side effect và bảo đảm tính nhất quán của hợp đồng này.

Địa chỉ 32-bit không bị giới hạn bởi core; phép cộng effective address có wrap modulo `2^32`. Bản đồ RAM/ROM/MMIO là trách nhiệm SoC. Kiểm tra giới hạn vùng phải xét toàn bộ số byte của truy cập, không chỉ byte đầu tiên. Do chỉ hỗ trợ truy cập căn chỉnh, một halfword/word hợp lệ không đi qua ranh giới word 32-bit.

## Little-endian, byte lane và alignment

Địa chỉ trên `dmem_addr` luôn là effective byte address gốc. Core không làm tròn hoặc xóa bit địa chỉ thấp. Phía slave lấy từ chứa byte đó tại `word_base={dmem_addr[31:2],2'b00}` để trả `dmem_rdata`. Việc chọn từ trong slave không thay đổi địa chỉ kiến trúc hay che giấu lỗi alignment.

Với `word_base=A`, little-endian nghĩa là:

| Byte address | Lane | Bit trong rdata/wdata |
|---|---:|---|
| A + 0 | 0 | [7:0] |
| A + 1 | 1 | [15:8] |
| A + 2 | 2 | [23:16] |
| A + 3 | 3 | [31:24] |

`dmem_be` là mask lane. Với load, slave có thể trả nguyên word; LSU chỉ sử dụng các byte được chọn. Adapter MMIO nên giữ mask và kích thước truy cập chính xác nếu thiết bị phụ thuộc độ rộng đọc.

| Lệnh | `addr[1:0]` hợp lệ | BE | Xử lý dữ liệu |
|---|---|---|---|
| LB/LBU/SB | 00 | 0001 | Byte thấp của rs2 đặt vào [7:0] khi store |
| LB/LBU/SB | 01 | 0010 | Byte thấp của rs2 đặt vào [15:8] |
| LB/LBU/SB | 10 | 0100 | Byte thấp của rs2 đặt vào [23:16] |
| LB/LBU/SB | 11 | 1000 | Byte thấp của rs2 đặt vào [31:24] |
| LH/LHU/SH | 00 | 0011 | Halfword thấp ở [15:0] |
| LH/LHU/SH | 10 | 1100 | Halfword thấp ở [31:16] |
| LW/SW | 00 | 1111 | Toàn bộ 32-bit |

Byte-enable là thông tin xác định byte có hiệu lực; các byte wdata ngoài mask không mang ý nghĩa kiến trúc. Ví dụ store `SB rs2,[A+3]` với `rs2=32'h1234_5680` phải cập nhật byte A+3 thành `8'h80`, giữ nguyên A+0 đến A+2, với `BE=4'b1000`.

LB mở rộng dấu từ bit 7 của byte được chọn; LBU zero-extend. LH mở rộng dấu từ bit 15 của halfword được chọn; LHU zero-extend. LW giữ đủ 32-bit. Đối với byte `8'h80`, LB trả `32'hFFFF_FF80`, LBU trả `32'h0000_0080`.

Địa chỉ halfword có bit 0=1 gây lỗi, word có bất kỳ bit [1:0] khác 00 gây lỗi. Byte cho phép cả bốn lane. Khi alignment sai, core không phát data request; không tự chia nhỏ truy cập thành nhiều transaction.

## FENCE, bộ nhớ ngoài và adapter AXI

Các cổng req/ready này **không phải AXI4-Lite**. Muốn tích hợp AXI phải dùng adapter riêng có FSM, mapping lỗi, lưu payload và xử lý từng channel đúng giao thức AXI.

Một adapter đơn giản có thể giữ tối đa một transaction, nhưng với AXI write vẫn phải quản lý riêng AW, W và B; không giả định AWREADY và WREADY xuất hiện cùng chu kỳ. Adapter chỉ báo `dmem_ready=1` sau khi nhận phản hồi ghi B hoặc dữ liệu đọc R tương ứng, và chuyển SLVERR/DECERR thành error. Mapping địa chỉ/size/strobe phải bảo toàn effective byte address và mask lane.

Ngay cả khi đã có phản hồi AXI, người tích hợp vẫn phải xác nhận endpoint và bridge duy trì đúng thứ tự quan sát cần cho FENCE. Phiên bản core này không phát tín hiệu fence/drain ra adapter. Hệ thống có cache, posted writes hoặc nhiều miền cần đồng bộ phải bổ sung cơ chế đó trước khi tuyên bố hỗ trợ FENCE đầy đủ trong môi trường mới.

## Hướng phát triển

| Giai đoạn | Công việc cần bổ sung |
|---|---|
| Pipeline 5 stage | IF/ID/EX/MEM/WB registers, valid/ready giữa stage, forwarding, load-use stall, flush branch/jump, exception chính xác |
| SoC tối thiểu | ROM/RAM, address decoder, timer/UART, reset/clock và chính sách error rõ ràng |
| AXI | Adapter độc lập, assertions cho từng channel, backpressure và error propagation |
| Privileged/interrupt | CSR, privilege state, trap vector/return, interrupt priority và precise exception |
| DSP/AI accelerator | MMIO hoặc DMA rõ bản đồ địa chỉ; driver và ordering; không tự thêm custom instruction vào RV32I |
| Cache | Coherence/ordering policy, instruction visibility, hỗ trợ FENCE.I nếu mở rộng phạm vi |

Mỗi bước cần mở rộng mô hình tham chiếu, test và kiểm chứng giao thức tương ứng. Ranh giới module giúp tái sử dụng datapath, nhưng không làm các yêu cầu hazard, exception và memory ordering tự động được giải quyết.
