# ClaudeHut 0.20 Harness — Bộ tài liệu thiết kế (phase 1: nghiên cứu và kiến trúc)

Phiên bản: 0.20.0-design · Ngày: 2026-10-19 · Trạng thái: Đề xuất · Phạm vi: chỉ nghiên cứu và thiết kế, chưa có thay đổi code.

## Tóm tắt

ClaudeHut 0.12.6 đang có **66 vấn đề mở trên 16 vùng capability** (S1: 9, S2: 26). Chất lượng quyết định thiết kế chỉ là 1 trong 9 S1. Các S1 còn lại:
- PASS dựa trên claim chưa kiểm;
- eval end-to-end đã chết;
- control không chạy mà không ai biết;
- task `done` khi chưa review;
- 1.031 lần subagent tự từ chối lệnh trong worktree vì wrapper rtk;
- điều phối xuyên repo bằng tin nhắn gõ tay;
- learning sai lan ra cả fleet;
- lõi gắn cứng Java/Spring.

Sáu nguyên nhân gốc:
1. Cưỡng chế dao động giữa hai cực.
2. Harness không tự quan sát được mình.
3. Giả định thế giới đóng.
4. Phân phối bằng copy.
5. Tri thức không có cơ chế bảo trì sự thật.
6. Shell làm runtime.

Kiến trúc 0.20 là một **harness tổng quát xây trên Claude Code**:
- **Host-first:** dùng loop, sandbox, permission, marketplace, OTel, trigger của host.
- **Kernel nhỏ** gồm K1–K11:
  - event log theo task;
  - bất biến tại transition;
  - workflow engine;
  - context assembler;
  - host adapter;
  - knowledge service + MCP;
  - sensor runtime có canary;
  - campaign xuyên repo;
  - telemetry;
  - pack registry;
  - eval.
- **Mọi tri thức stack, tổ chức, domain nằm trong pack có version:** workflow, review, deliberation, lang-java-spring, lang-python-shell, org-summer, domain-ewallet, topology template.
- **Kiểm soát theo mô hình guide × sensor** (computational/inferential), có stage và canary.

Ma trận coverage gắn **35/35 vấn đề S1 và S2** với cơ chế và metric. Mọi component đều có neo. Kiến trúc được thử bằng hai walkthrough: fleet Spring ewallet và repo không Java (chính `claudehut`).

## Mục lục

| File | Nội dung |
|---|---|
| [01-problem-space.md](01-problem-space.md) | 66 vấn đề, ma trận vùng × mức, 9 S1, 6 nguyên nhân gốc, yêu cầu kiến trúc |
| [02-research.md](02-research.md) | Harness engineering, kiến trúc tham chiếu, năng lực host, observability, governance, fleet, cải tiến liên tục |
| [03-reference-architecture.md](03-reference-architecture.md) | **Tài liệu chính.** Nguyên tắc P1–P14, 22 capability theo owner, phân lớp, kernel và pack, **ma trận coverage**, hai walkthrough |
| [04-kernel-control.md](04-kernel-control.md) | Event log, bất biến, workflow engine, context, host adapter và autonomy, campaign, runtime Python |
| [05-knowledge-plane.md](05-knowledge-plane.md) | Schema, detector (pack), decision graph, MCP `claudehut-kb`, truth maintenance |
| [06-quality-plane.md](06-quality-plane.md) | Guide × sensor, hợp đồng sensor có canary, `claudehut-verify`, review, AC confirm, pack deliberation |
| [07-packs-distribution.md](07-packs-distribution.md) | Đặc tả pack, danh mục pack, marketplace stable/canary, profile, compose, migration |
| [08-observability-eval.md](08-observability-eval.md) | OTel, `claudehut status`, metric, 4 suite eval, vòng cải tiến |
| [09-adr-roadmap.md](09-adr-roadmap.md) | ADR K-01…K-16, ADR 0.12 bị thay, track Q (quick-win) và track 0.20, câu hỏi Q1–Q11 |
| [10-implementation-log.md](10-implementation-log.md) | Nhật ký build phase A: Track Q (0.12.7), review độc lập, phát hiện protected path (đề xuất K-18), harness eval M0 |
| [appendix/a1](appendix/a1-decision-quality-evidence.md), [a2](appendix/a2-deliberation-pack.md) | Chi tiết cụm chất lượng quyết định và pack deliberation |
| [research/](research/) | Báo cáo nguồn tiếng Anh r1–r5 |

Thứ tự đọc: 01 → 03 → 09 → 04…08 theo vùng phụ trách.

## Trạng thái quyết định (2026-10-21)

Đã chốt toàn bộ Q1–Q11 ([09 §3–§7](09-adr-roadmap.md)):
- **Q1:** chạy trong session, cộng runner headless chỉ đọc. Hỗ trợ cả **plan** lẫn **API key** (K-17).
- **Q2:** phase hiện tại chỉ làm plugin; phần ảnh hưởng service để sang phase B.
- **Q3:** dùng ArchUnit.
- **Q4:** bản mới là 0.20.0.
- **Q5:** advisor mặc định là Opus.
- **Q6:** bất biến kernel `block`, có override.
- **Q7:** eval chạy bằng quota plan.
- **Q8:** kernel viết bằng Python stdlib.
- **Q9:** hai marketplace.
- **Q10:** tech lead tạo campaign, owner service duyệt task con.
- **Q11:** làm track Q ngay.

## Bước kế tiếp

Phase A, chỉ trong plugin:
1. **Track Q trên 0.12.x:**
   - bất biến `done`;
   - `claudehut-verify claims`;
   - phát hiện rtk;
   - verb retract learning;
   - sửa eval (baseline, auth profile);
   - canary;
   - đếm budget artifact.
2. **Track 0.20:** M0 (4 suite eval, baseline 0.12.6) → M1 (kernel Python, event log, bất biến) → … → M6.

Phase B (rollout lên service) làm sau, theo [09 §2.3](09-adr-roadmap.md).
