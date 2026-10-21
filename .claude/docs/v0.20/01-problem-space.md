# 01 — Không gian vấn đề

Phạm vi: toàn bộ vấn đề của ClaudeHut 0.12.6 trên mọi capability của một harness, không chỉ chất lượng quyết định. Nguồn đầy đủ (tiếng Anh, có bằng chứng `path:line`, commit, transcript): [research/r4-problem-inventory.md](research/r4-problem-inventory.md), kèm [r4-src2-ewallet.md](research/r4-src2-ewallet.md) và [r4-src3-transcripts.md](research/r4-src3-transcripts.md). Chi tiết riêng cụm quyết định nằm ở [appendix/a1](appendix/a1-decision-quality-evidence.md).

Dữ liệu khảo sát:
- 282 thư mục task trên 16 repo ewallet;
- 47 session chính và khoảng 1.850 transcript subagent (2026-08-19 → 10-19);
- 59 finding audit v0.11 và 111 finding prompt audit;
- dữ liệu ledger, learnings, hub, settings của 20 scope.

## 1. Tổng quan

**66 vấn đề đang mở trên 16 vùng capability:** S1 9, S2 26, S3 28, S4 3.

Mức độ:
- **S1:** cho kết quả sai mà không báo (PASS giả, tri thức sai, money path không review); chặn một capability lõi với tần suất cao; hoặc chặn mục tiêu "harness tổng quát".
- **S2:** lặp lại, tốn rework, token hoặc công can thiệp.

Chất lượng quyết định (PLN-1) chỉ là **1 trong 9 S1**.

| Vùng | S1 | S2 | S3/S4 |
|---|---|---|---|
| Context & memory | – | CTX-1, CTX-2 | CTX-3 |
| Knowledge / retrieval | KNW-2 | KNW-1, KNW-3 | KNW-4..6 |
| Planning & decision | PLN-1 | PLN-2, PLN-3, PLN-5 | PLN-4 |
| Tool interface (ACI) | – | ACI-1, ACI-2 | ACI-3..5 |
| Execution environment | ENV-1 | ENV-2 | ENV-3..5 |
| Verification & gates | VER-1, VER-3 | VER-2, VER-5 | VER-4 |
| State / workflow | STA-1 | – | STA-2..4 |
| Multi-agent / fleet | MAO-1 | MAO-2, MAO-4 | MAO-3, MAO-5 |
| Human-in-loop / permission | – | HIL-1, HIL-2 | HIL-3 |
| Observability / cost | – | OBS-1, OBS-2 | OBS-3 |
| Eval & improvement | EVL-1 | EVL-2, EVL-4 | EVL-3 |
| Lifecycle / distribution | – | LIF-1, LIF-2 | LIF-3..6 |
| Composition | (CMP-1, tính chung với ENV-1) | CMP-2 | CMP-3 |
| Domain packs | DOM-1 | DOM-2 | DOM-3 |
| Security | – | SEC-1 | SEC-2..4 |
| DX | – | DX-1 | DX-2, DX-3 |

## 2. Chín vấn đề S1

| ID | Vấn đề | Bằng chứng chính |
|---|---|---|
| PLN-1 | Quyết định thiết kế hẹp, cứng | 25 case; mọi lần genericization đều do người ép; chỉ 1/222 spec có mục phương án |
| VER-1 | PASS dựa trên claim chưa kiểm | 7 case: dẫn file không có trong tree, review trước khi spec đổi, PASS khi finding còn mở |
| EVL-1 | Không có eval end-to-end hoạt động | 0 lần chạy baseline không plugin; 21/36 run bị cắt vì hết budget; `is_error` luôn true; lần chạy cuối 2026-06-28 |
| VER-3 | Control không bao giờ chạy mà không ai biết | SubagentStop verify chưa từng chạy; load-probe chưa từng ra verdict; Learn gate fail-open 356 lần; 682/682 bản ghi failure rỗng |
| STA-1 | Task `done` khi review chưa chạy | 5/39 task v0.12, trong đó có va 0038 (money path) và va 0039 (bump SDK xuyên service); `end --status done` không kiểm gì |
| ENV-1 | Subagent trong worktree tự từ chối lệnh của chính nó | 1.031 lần từ chối trong transcript và 88 trong `failures.jsonl`; 581 do hook rtk đổi `git` thành `rtk git` |
| MAO-1 | Việc xuyên repo điều phối bằng tin nhắn gõ tay giữa session | 49 tin nhắn tới 15 session; không xác nhận đã nhận, khoá tự chế, peer từ chối khi thiếu duyệt của user |
| KNW-2 | Fleet learning sai vẫn được inject, không retract được | F-0054, F-0080 vào 19 service; nhiễu tool được tự promote ở 5 repo; 70 learning nói về chính harness |
| DOM-1 | Lõi gắn cứng Java/Spring | Init trên repo bash/python của chính plugin sinh `PROJECT.md` Java cùng 36 rule Java |

## 3. Sáu nguyên nhân gốc xuyên suốt

| # | Nguyên nhân | Vấn đề liên quan |
|---|---|---|
| RC1 | **Cưỡng chế dao động giữa hai cực:** v0.11 dùng gate regex chặn cả việc hợp lệ; v0.12 bỏ hết gate. Không phiên bản nào kiểm **bất biến ngữ nghĩa** (verdict gắn tree, `done` cần review, budget) | STA-1, VER-1, PLN-3, STA-5 |
| RC2 | **Harness không tự quan sát được mình.** Control ship mà không có kiểm tra liveness; ledger mất sự kiện; metric hứa đo sau phát hành nhưng không đo; eval live chết. Lỗi chỉ lộ qua audit thủ công lớn | VER-3, OBS-1, OBS-2, EVL-1, EVL-4 |
| RC3 | **Giả định thế giới đóng:** chỉ có ClaudeHut, chỉ có Java/Spring, một repo mỗi session, một session mỗi task | ENV-1, CMP-2, DOM-1, MAO-1, MAO-2, LIF-1 |
| RC4 | **Phân phối bằng copy thay vì tham chiếu:** 21 bản cài, 51 skill, 16 checker, 14 prompt (14 nội dung khác nhau), 15 biến thể settings | LIF-1, LIF-2, MAO-2, VER-2 |
| RC5 | **Tri thức không có cơ chế bảo trì sự thật:** không xác minh, không retract, không owner, không tín hiệu hữu ích; validator không gắn version | KNW-1, KNW-2, VER-2, SEC-1 |
| RC6 | **Shell làm runtime:** khoảng 11,7k dòng bash/python chạy dưới zsh và env của user nên lỗi tính khả chuyển lặp lại | ENV-4, ACI-1, ACI-4, STA-4, LIF-5 |

## 4. Yêu cầu rút ra cho kiến trúc

1. Kiến trúc phải **tổng quát**: stack, số repo, plugin khác và surface (CLI, CI, lịch) đều là biến số, không phải giả định.
2. **Cưỡng chế bằng bất biến** tại chuyển trạng thái tường minh, không bằng regex trên file và không phó mặc.
3. **Mọi control có bằng chứng sống** (canary) và có metric. Harness đo được chính nó.
4. **Tri thức có vòng đời**: provenance, xác minh, owner, version, retract.
5. **Phân phối bằng gói có version**, không copy.
6. **Đi trên năng lực của host** (Claude Code) trước. Chỉ tự xây phần host không có ([03 §2](03-reference-architecture.md)).
7. **Mọi cơ chế truy về một vấn đề** trong bảng coverage ([03 §5](03-reference-architecture.md)). Component không có neo thì không xây.
