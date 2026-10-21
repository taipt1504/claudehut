# 06 — Quality plane: guides, sensors, review, deliberation

Component K7 và các pack chất lượng. Vấn đề neo: VER-1, VER-2, VER-3, VER-5, PLN-1, PLN-2, ACI-2, STA-1.

## 1. Mô hình guide × sensor

Theo [Böckeler](https://martinfowler.com/articles/harness-engineering.html). Mỗi control là một ô trong lưới dưới đây và được khai báo trong pack.

| | Computational (tất định, rẻ) | Inferential (model, đắt) |
|---|---|---|
| **Guide** (trước khi hành động) | template, codemod, scaffold, LSP | skill, rule theo `paths`, pattern catalogue, MADR cũ |
| **Sensor** (sau khi hành động) | test, lint, ArchUnit, `claudehut-verify`, checker theo version | design-reviewer, review lane, judge |

Quy tắc:
- Mỗi guide quan trọng có ít nhất một sensor kiểm nó, và ngược lại: sensor bắt lỗi lặp lại thì phải sinh hoặc cập nhật guide (vòng lái).
- Ưu tiên computational. Inferential chỉ dùng cho ngữ nghĩa mà rule không quyết định được.
- Output sensor viết cho model đọc: chỗ sai, vì sao, cách sửa, link runbook.

## 2. Hợp đồng sensor (`claudehut-pack.json`)

```json
{
  "id": "summer.dr-integration",
  "kind": "computational",
  "stage": ["post-edit", "set-review", "ci"],
  "cost": "low",
  "applies_to": "summer>=0.3.31 <0.4",
  "run": "python3 {pack_root}/checkers/check_dr.py {repo}",
  "message_format": "file:line severity rule — fix",
  "canary": {"fixture": "canary/dr-missing-gate", "expect": "ERROR"},
  "on_version_mismatch": "warn"
}
```

| Trường | Chống lại |
|---|---|
| `stage` | Gắn sensor vào vòng đời: `pre-edit` (guide), `post-edit` (hook advisory), `set-plan`/`set-review`/`end` (bất biến K2), `pre-commit`, `ci`, `scheduled` (drift), `runtime`. Đẩy chất lượng sang trái |
| `canary` | **VER-3:** kernel chạy canary khi cài, nâng cấp, theo lịch, và trong `claudehut status --selftest`. Canary không ra kết quả mong đợi thì sensor bị đánh dấu `dead` và báo đỏ |
| `applies_to`, `on_version_mismatch` | **VER-2:** checker theo version; lệch version thì hạ ERROR thành WARN và nhắc sinh lại |
| `run` qua kernel | **ACI-2:** kernel chạy lệnh raw, không qua wrapper của host; output được chuẩn hoá. `{pack_root}` là đường dẫn pack đã đăng ký với registry ([07 §1.1](07-packs-distribution.md)) |

## 3. Sensor có sẵn trong kernel: `claudehut-verify`

| Lệnh | Kiểm | Vấn đề |
|---|---|---|
| `claims <md> --tree <sha>` | mọi `path:line` trong spec/plan/review tồn tại ở tree; trích dẫn khớp ±3 dòng | VER-1 |
| `verdict <task>` | verdict gắn `spec_rev`, `plan_rev`, `head_tree`; artifact hoặc tree đổi thì verdict thành `stale` | VER-1 (N2) |
| `findings <task>` | không PASS khi còn finding `open`; self-review chỉ được `PASS-SELF` | VER-1 (W3, P7) |
| `budget <md>` | đếm từ theo ngôn ngữ, so với budget theo route và tier | PLN-3 |
| `env-placeholders` | (a) bắt typo: tên env khớp từ vựng tiền tố hoặc alias đã khai báo, khoảng cách sửa nhỏ thì báo (`SgstUMMER`). **Không** ép tên relaxed chính xác, vì alias cho field trong list là cố ý (F-0054). (b) Xác nhận thật bằng test binding | A2 |
| `vendor-leak` | tên vendor (danh sách từ hub hoặc pack) xuất hiện ở enum, cột, properties hoặc package trung lập | PLN-1 (V1, P3, P6) |
| `selftest` | chạy canary của mọi sensor đang kích hoạt | VER-3 |

Bất biến kernel dùng các lệnh này:
- `set-review pass` cần `claims`, `verdict` và `findings` đều sạch;
- `end done` cần review không `pending` hoặc `stale` (STA-1).

## 4. Review (pack `review`)

- **Hai tầng.** Tầng 1 kiểm tuân thủ spec (AC, test, contract). Tầng 2 kiểm thiết kế (rubric của pack deliberation) và chất lượng code. Chỉ finding thuộc rubric hoặc ảnh hưởng correctness mới chặn. Lý do: "Chasing every finding leads to over-engineering" (Claude Code best practices).
- **Lane chọn theo diff** (giữ cơ chế `review-pack` của 0.12). Mỗi lane có cost class và được đo cost/lane (VER-5).
- **Context mới, model khác** cho lane design và judge, để tránh self-preferential bias.
- **Review của plugin khác** (ví dụ superpowers `requesting-code-review`) có thể đăng ký làm lane opt-in (ADR-V10 của 0.12).

## 5. Xác nhận yêu cầu (PLN-2)

Pack `workflow-standard` khai báo bước **AC confirm** trước implement trên route `light` và `full`:
- tóm tắt yêu cầu thành 3–7 AC, kèm điều nằm ngoài phạm vi;
- phiên tương tác: hỏi user một lần;
- headless: ghi giả định và dừng ở gate.

Đây là phản hồi cho các lần rollback vì "đi sai hướng" trong transcript.

## 6. Pack `deliberation` (chất lượng quyết định thiết kế)

Là một capability (C21) trong số nhiều capability, không phải lõi. Chi tiết: [appendix/a2](appendix/a2-deliberation-pack.md); bằng chứng: [appendix/a1](appendix/a1-decision-quality-evidence.md).

| Thành phần | Loại |
|---|---|
| Tier T0–T3 và trigger nhận diện quyết định | invariant + guide |
| Variation probe (3 câu hỏi bằng tool `kb_*`) | guide inferential |
| Quy tắc Protected Variation hai chiều (a: ≥2 biến thể; b: có cam kết; c: pattern đã xác nhận) | guide + rubric |
| MADR + Confirmation (fitness function) | artifact + sensor computational (ArchUnit do pack lang sinh) |
| design-reviewer (opus, context mới, rubric R1–R6) | sensor inferential |
| Advisor ở hai điểm (khuyến nghị, không ép) | guide; đo ở eval |
| `design-tournament` cho T3 | workflow opt-in |

Phụ thuộc kernel: K6 (`kb_variation_points`, `kb_patterns`, `kb_decisions`), K2 (bất biến DEC), K11 (decision suite).
