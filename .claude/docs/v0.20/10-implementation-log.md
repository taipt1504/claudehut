# 10 — Nhật ký triển khai phase A

Ghi lại phần đã build so với thiết kế, kèm chỗ lệch và lý do. Cập nhật theo từng milestone.

## Track Q → 0.12.7 (2026-10-21)

| Mục | Thiết kế | Đã build | Lệch / ghi chú |
|---|---|---|---|
| Q-a | Bất biến `end done` | `claudehut-state end` gọi `claudehut-kernel gate end`: done cần review `pass`/`capped`; sau pass, binding phải còn khớp (`tree-changed`, `spec-changed`, `plan-changed`) | Binding là **fingerprint nội dung** (diff từ task base tới worktree + file untracked), không phải SHA của HEAD. Lý do: commit đúng phần đã review không được làm verdict thành stale |
| Q-b | `claudehut-verify claims/verdict/findings` gắn vào `set-review pass` | Có, Python stdlib (`scripts/kernel/`) | Claim được resolve theo thứ tự: repo root, project dir, suffix hoặc basename duy nhất, rồi `.claude/` (rule và skill thường bị gitignore). File đã có ở base được coi là bị task xoá, không tính lỗi |
| Gate mode | `warn` → `block` có override | `CLAUDEHUT_GATE_MODE` > `topology.json .gates.mode` > `warn`. Mọi kết quả là event trong `tasks/<id>/events.jsonl` | Mặc định `warn` trong phase A, vì pilot `block` thuộc phase B |
| Q-c | Phát hiện wrapper rewrite | `claudehut-kernel probe` chạy thử hook PreToolUse/Bash của user bằng payload giả và phát hiện rewrite. Có cache 1 ngày; tắt bằng `CLAUDEHUT_PROBE_HOOKS=0` | Kiểm thực nghiệm thay vì so tên `rtk`, nên áp dụng được cho mọi wrapper. Đã xác minh đường dẫn tuyệt đối `/usr/bin/git` không bị rtk rewrite |
| Q-d | Retract/verify learning; promotion gate | `learn retract/verify`; injector, scoring và MEMORY bỏ qua entry `retracted`; bản copy lên fleet cần `verified_by` | Learning fleet chưa xác minh vẫn giữ `scope: fleet` ở local và được đếm là `fleet_held_unverified` |
| Q-e | Sửa eval | `run.sh`: lỗi jq `.is_error // true`, `--mode both`, `--auth`, `aborted`, budget theo task; `summarize.sh` | Nguyên nhân `is_error` luôn true là bẫy toán tử `//` của jq (nó thay cả giá trị `false`) |
| Q-f | Canary | `claudehut-kernel selftest`: hợp đồng của mọi hook trong hooks.json + 4 canary hành vi | — |
| Q-g | Budget artifact | `budget.exceeded` event + thông báo % vượt; không bao giờ từ chối | — |

Test: hai suite mới `verify-tests` (46) và `eval-harness-tests` chạy trong `hook-tests.sh`. Tổng suite tất định trên baseline 0.12.6 là 1.654 assertion, xanh hết.

## M0 — harness eval (bắt đầu)

- `evals/plugin-eval.sh` bọc `claude plugin eval`:
  - Copy plugin ra `$TMPDIR` (ngoài `$HOME`), vì Bash trong run eval bị sandbox và **không đọc được `$HOME`**. Nếu không copy, agent không gọi được `bin/claudehut-state` của plugin.
  - Chỉ mang theo `evals/suites`, không mang oracle cũ.
  - Luôn bật `--scaffold`, `--trust-plugin`, `--no-publish`; ghi `run-meta.json` (auth_mode, version).
- Suite (`evals/suites/`): `process/` (2 case), `decision/` (3 case: zns-follows-provider-pattern, vendor-neutral-columns, single-client-no-abstraction), `outcome/` (1 case).
- **Lệch so với 08 §4.2:** suite env-hostile **không** chạy qua `claude plugin eval`, vì run eval cố ý chặn phần lớn env (FORCE_COLOR, zsh, hook của user). Phần này đã được phủ bởi `verify-tests` (path có dấu cách, hook rewrite, thiếu python3) và `selftest` chạy trên runtime thật.
- Smoke run (plan quota, 1 run, không baseline):
  - `end-refused-without-review`: 1.00, $0.16. Bản đầu dùng grader `--override` trên trace và bị false-fail, vì chính thông điệp của gate có chứa chữ đó; đã đổi sang `tool_used` với `max: 0`.
  - `zns-follows-provider-pattern`: 0.67, $0.33. Grader "đã Read SmsProvider" chấm đường đi chứ không chấm kết quả nên đã bỏ.

## Review độc lập Track Q (2026-10-21)

Một reviewer subagent với context mới chỉ đọc diff và tìm ra 12 lỗi; tất cả đã được sửa, mỗi lỗi có test hồi quy (verify-tests R1–R7, H2):

| # | Lỗi | Sửa |
|---|---|---|
| 1 | `"${BARE[@]}"` rỗng làm bash 3.2 dừng dưới `set -u`, khiến mọi row plan-auth thành fail giả | `${BARE[@]+"${BARE[@]}"}` |
| 2 | Fingerprint đổi khi file mới được stage, vì untracked và tracked bị băm khác nhau | Dùng tree sha từ index tạm (`git add -A` rồi `write-tree`); index của user không bị đụng tới |
| 3 | Probe chạy trên SessionStart sync có thể vượt timeout 5 s | Probe chuyển sang `maintain.sh` (async), deadline 2 s, ghi cache theo từng hook, kill cả process group. Bootstrap chỉ đọc `--cached` |
| 4 | Kernel crash (exit 1) bị hiểu là "block"; lỗi argparse (exit 2) cho transition đi qua mà không ghi gì | Chỉ refuse khi rc 1 **và** `decision=block`. Exception bị ánh xạ thành exit 3. Gate bị bỏ qua sinh event `gate.skipped`. Override truyền dưới dạng `--override=<r>` |
| 5 | Learn sửa `.claude/rules` làm verdict thành stale | Loại `.claude/` khỏi fingerprint |
| 6 | Trên Linux, lock của `learn` khác lock của merge (flock) | Lấy cả flock `<store>.lock.flock` lẫn mkdir lock; row không phải object được giữ nguyên; giữ mode của file |
| 7 | `merge-learnings` bỏ qua `retracted` (vẫn promote, vẫn sync lên hub) | Mọi điều kiện lọc `superseded` giờ lọc cả `retracted` |
| 8 | Claim bị báo sai khi nằm trong khối code (stack trace), là file đề xuất tạo, hoặc là path `~/` | Bỏ qua khối code, câu đề xuất, `~`/`$` |
| 9 | `lstrip("./")` cắt mất `.github` | Chỉ bỏ đúng tiền tố `./` |
| 10 | Bảng domain có giá trị `PENDING`/`OPEN` bị hiểu là finding đang mở | Chỉ đọc cột có header Status/State/Trạng thái |
| 11 | Plan-auth nạp cả plugin user đã cài vào cả hai nhánh eval | Workspace eval tắt mọi plugin mà user đang bật; crash được chấm điểm thay vì bị coi là `aborted` |
| 12 | Probe chạy cả hook user đã tắt; cache dùng chung cho hook có đường dẫn tương đối | Tôn trọng `disableAllHooks`/`allowManagedHooksOnly`; key cache gồm cả project khi hook dùng đường dẫn tương đối |

Còn để lại, có ghi nhận:
- `start` đóng task cũ của cùng session qua `supersede_active` mà không đi qua end gate. Xử lý ở M1, khi chuyển state sang Python.
- `fleet_held_unverified` đếm mọi entry chưa xác minh trong mỗi lần chạy, nên con số bị thổi phồng; chỉ là thông tin.

## Phát hiện kiến trúc quan trọng: `.claude/` là protected path

Smoke eval cho thấy Edit vào `.claude/claudehut/tasks/*/review.md` bị **từ chối** ở chế độ `dontAsk`. Theo tài liệu Claude Code ([permission-modes, Protected paths](https://code.claude.com/docs/en/permission-modes)), `.claude` là protected directory:

| Mode | Hệ quả |
|---|---|
| `default`, `acceptEdits` | prompt |
| `auto` | đi qua classifier |
| `dontAsk` (CI, routine, eval, runner headless) | **từ chối** |
| `bypassPermissions` | cho phép |

Rule `permissions.allow` trong settings **không** mở được giới hạn này.

Hệ quả:
- Mọi artifact ClaudeHut (spec, plan, review, learnings) ghi bằng Write/Edit dưới `.claude/claudehut/` đều gây prompt hoặc tốn classifier trong session thường.
- Mọi artifact đó bị chặn hẳn trong runner headless (Q1-B) và trong eval.
- Đây là gốc của khoảng 150 Write denial ghi nhận từ v0.11 (STA-5), và của việc `evals/run.sh` cũ phải dùng `--dangerously-skip-permissions`.

Đề xuất **ADR K-18 (chờ user)**: chuyển phần artifact ghi thường xuyên (tasks, learnings, index, events) ra khỏi `.claude/`, ví dụ sang `<repo>/.claudehut/`. Chỉ giữ dưới `.claude/` những gì Claude Code phải tự đọc (rules, skills, CLAUDE import). Việc migrate 20 scope thuộc phase B, dùng `claudehut-migrate`.
