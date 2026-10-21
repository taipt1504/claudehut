# 09 — ADR, lộ trình, câu hỏi mở

## 1. ADR (trạng thái `proposed`)

| ID | Quyết định | Phương án bị bác | Neo |
|---|---|---|---|
| K-01 | Vẫn là **Claude Code plugin**, theo host-first: dùng loop, sandbox, permission, marketplace, OTel, trigger của host. ClaudeHut cung cấp kernel, pack và profile | App riêng hoặc fork CLI; tự dựng telemetry, sandbox | P1 |
| K-02 | **Kernel nhỏ cộng pack có version**; Spring, Summer, ewallet đều là pack | Lõi mang tri thức stack (DOM-1) | DOM-1, DOM-2 |
| K-03 | **Run state = event log append-only theo task**, writer duy nhất là state CLI; hook chỉ làm giàu và được đối soát | State dựa trên hook (OBS-1) | STA-*, OBS-1, MAO-4 |
| K-04 | **MCP `claudehut-kb`** cùng CLI; thay ADR-V5 của 0.12 | Chỉ CLI + grep | KNW-3, ACI-1 |
| K-05 | **Bất biến tại transition**, có override ghi lý do; hook vẫn advisory. **Accepted (Q6)** | Stop hook chặn; không gate | STA-1, VER-1, PLN-3 |
| K-06 | **Hợp đồng sensor** có stage, kind, cost, `applies_to`, **canary bắt buộc** | Control không có bằng chứng sống | VER-2, VER-3 |
| K-07 | **Truth maintenance** cho mọi fact: provenance, `verified_by`, scope, `applies_to`, retract | Learning theo confidence/hits | KNW-1, KNW-2, SEC-1 |
| K-08 | **Host adapter + profile** autonomy L0–L3 do user sở hữu. **Không có grant của harness**; delegate escalate lên main | Grant file cho agent hay peer vượt auto-mode (permission laundering) | ENV-1, HIL-1, HIL-3 |
| K-09 | **Campaign** cho thay đổi xuyên repo: template tham chiếu, task con, owner, lease, trạng thái tổng | Tin nhắn gõ tay, prompt copy | MAO-1, MAO-2 |
| K-10 | **Phân phối (accepted Q9):** kernel, pack, bundle; hai marketplace tổ chức `claudehut` (chung) và `f8a-internal` (Summer, ewallet), mỗi cái có kênh stable/canary; cài ở user/managed scope; không copy asset vào repo | 21 bản cài project-scope, copy skill | LIF-1, LIF-2 |
| K-11 | **Kernel viết bằng Python stdlib**, migrate strangler: state, verify trước. **Accepted (Q8)** | Viết lại một lần; giữ bash | RC6 |
| K-12 | **Single-writer theo repo/branch**; scout chỉ đọc; writer song song chung log quyết định; dùng `isolation: worktree` của host, bỏ dần `claudehut-worktree` | Worktree manager riêng (ENV-2) | ENV-2, MAO-3 |
| K-13 | **Eval-first, baseline bắt buộc**; metric release là test định kỳ; thay đổi qua canary. **Eval chạy bằng quota của plan (Q7)**, không dùng API key | Đo sau phát hành | EVL-*, OBS-2 |
| K-14 | **Deliberation là pack** (tier, PV rule, MADR, design-reviewer); không phải lõi | Đưa logic quyết định vào kernel | PLN-1, P2 |
| K-15 | **Context:** always-on có budget kiểm trong CI; không nội dung biến động trong prefix; handoff cạnh log; session theo task | Mega-session | CTX-*, PLN-3 |
| K-16 | **AC confirm** trước implement (pack workflow); headless không tự duyệt T2+ | Self-approve | PLN-2, HIL-2 |
| K-17 | **Auth profile** (`plan`/`api`/`auto`) cho runner, eval, judge; không phụ thuộc cách xác thực (§7) | Chỉ hỗ trợ API key (`--bare`) hoặc chỉ hỗ trợ plan | Q1, Q7, EVL-1 |

**ADR của 0.12:**

| ADR 0.12 | Trạng thái | Thay bằng |
|---|---|---|
| V5 (không MCP) | superseded | K-04 |
| D2 (quyết định trong spec) | superseded | K-14, MADR |
| R2 (task.json schema 2) | superseded | K-03 |
| H10 (`bin/` ở gốc plugin) | amended | K-10, K-11 (shim) |
| R1 (router ba tuyến) | amended | route × tier |
| H2 (advisory only) | amended | K-05 |
| IDX-6 (learnings có schema) | amended | K-07 |
| V3, V4 (roster, model theo lane) | amended | pack `review` |
| R3, H4, H7, IDX-1, IDX-3, V1, V2 | giữ nguyên | — |

## 2. Lộ trình

**Phạm vi (Q2, 2026-10-21):** phase hiện tại chỉ enhance, upgrade và refactor **plugin**. Mọi thay đổi ảnh hưởng tới service đang dùng plugin (dữ liệu hub, learning của fleet, cài đặt và cấu hình ở repo service, xoá copy skill, duyệt catalogue) để sang **phase B, rollout**, làm sau.

Eval và pilot ở phase A dùng:
- fixture trong `evals/`;
- chính repo `claudehut`;
- **bản clone chỉ đọc** của vài service (không ghi gì vào repo thật).

### 2.1 Phase A, track Q: quick-wins trong plugin 0.12.x

Q6 đã chốt, nên Q-a và Q-b là `block` có `--override`. Khi bật, chạy `warn` 1 tuần trước rồi mới chuyển `block`.

| # | Việc (chỉ code plugin) | Vấn đề | Exit (đo trên fixture) |
|---|---|---|---|
| Q-a | Bất biến `end done ⇒ review không pending/stale` trong `claudehut-state` | STA-1 | case process pass^3 |
| Q-b | `claudehut-verify claims/verdict/findings` gắn vào `set-review pass` | VER-1 | case claim-integrity phát hiện 100% |
| Q-c | Probe phát hiện hook rewrite (rtk), cảnh báo kèm hướng dẫn; prompt implementer dùng đường dẫn tuyệt đối; guide "một lệnh mỗi lần Bash, sửa file bằng Edit" (giả thuyết, cần đo) | ENV-1, ACI-2 | fixture rtk: 0 refusal do rewrite |
| Q-d | Verb `retract`/`supersede` cho learning; chặn promote fleet khi thiếu `verified_by`. **Việc retract F-0054/F-0080 trên hub thật để ở phase B** | KNW-2 | regression learning |
| Q-e | Sửa eval: baseline không plugin, budget, `is_error`, auth profile (§3, Q1), chạy định kỳ bằng plan | EVL-1, OBS-2 | có Δ cho suite hiện có |
| Q-f | Canary cho các hook và sensor hiện có | VER-3 | selftest xanh |
| Q-g | Đếm budget artifact bằng máy, `warn` | PLN-3 | báo cáo p90 trên fixture |

### 2.2 Phase A, track 0.20: kiến trúc mới trong plugin

| M | Nội dung | Exit criteria (không đụng service) |
|---|---|---|
| M0 | Suite outcome, decision, process, env-hostile; baseline 0.12.6 | Báo cáo baseline; judge đồng thuận ≥80% |
| M1 | Kernel K1, K2, K7 bằng Python (strangler); event log; bất biến; auth profile | Suite process pass^3; regression 0.12 xanh; suite chạy được cả `plan` lẫn `api` |
| M2 | Tách pack: `workflow-standard`, `review`, `lang-java-spring`, `lang-python-shell`, `org-summer`, `domain-ewallet`; bundle; hai marketplace stable/canary; pack registry | Init trên repo `claudehut` (không Java) không sinh rule Java; bundle cài sạch từ marketplace canary |
| M3 | K6 schema 3, MCP `claudehut-kb`, truth maintenance, cơ chế duyệt catalogue (`candidate→confirmed`), harvest decision (đọc clone) | Detector precision ≥0,9, recall ≥0,8 trên fixture; tool được gọi ở ≥90% case T1+ |
| M4 | Pack `deliberation`, design-reviewer, hướng dẫn advisor | Decision suite: should-abstract ≥80%, should-not ≥90% |
| M5 | K8 campaign (đối tượng, trạng thái, pull ở SessionStart), K5 profile autonomy, `claudehut status`, telemetry bridge, `claudehut-run` (runner offline) | Campaign mô phỏng trên ≥3 fixture repo; runner chạy job eval/mining ở cả `plan` và `api` |
| M6 | Vòng cải tiến (mining), tournament T3, SCIP tuỳ chọn | Một thay đổi pack đi hết vòng PR → eval → canary trong repo plugin |

### 2.3 Phase B: rollout lên service (làm sau, cần quyết định riêng)

- Duyệt gói [appendix/a3](appendix/a3-approval-candidates.md): pattern, domain fact, vendor, fleet learning. Gói này được giữ làm **dữ liệu seed và fixture** cho M3–M4 của phase A.
- Retract F-0054 và F-0080 trên hub thật; dọn learning nhiễu.
- `claudehut-migrate` lên 20 scope: cài ở user/managed scope, bundle, gỡ copy skill/checker/prompt, `task.json` → event log.
- Campaign thật đầu tiên. Pilot trên payment-gateway-ms, va-ms, notification-ms.
- Các câu hỏi domain trong a3 §5 (consumer/client chuẩn, topology DB ở DR, vendor class…).

## 3. Quyết định đã chốt (2026-10-21)

| # | Quyết định |
|---|---|
| Q3 | Dùng ArchUnit làm sensor computational ở service JVM (pack `lang-java-spring`) |
| Q4 | Bản harness mới là **0.20.0**; bộ tài liệu chuyển sang `docs/v0.20/` |
| Q5 | Advisor mặc định là **Opus**. `claudehut-init` đề xuất `advisorModel: opus` và chỉ ghi khi user đồng ý (plugin không tự set được) |
| Q6 | Bất biến kernel ở mức `block`, có `--override "<lý do>"`. Bất biến pack mặc định `warn`. Hook vẫn advisory |
| Q7 | **Eval chạy bằng quota của plan**, không API key (chi tiết bên dưới) |
| Q8 | Kernel bằng Python 3 stdlib, migrate strangler |
| Q9 | Hai marketplace tổ chức: `claudehut` (kernel + pack chung) và `f8a-internal` (`org-summer`, `domain-ewallet`); mỗi marketplace có stable/canary |
| Q11 | Làm track Q ngay trên 0.12.x |

**Hệ quả của Q7**, theo tài liệu `claude plugin eval`: eval "call the model with your credentials, so they count against your plan's usage limits".
- `claude plugin eval` và `claude -p` **không có `--bare`** dùng chính login subscription. Chế độ `--bare` "doesn't use your subscription login", nên **không dùng `--bare`** cho eval.
- Suite cần model (outcome, decision, judge) chạy **trên máy dev** hoặc máy chạy riêng có đăng nhập plan. CI chỉ chạy suite tất định (regression shell/python, canary, ArchUnit), vì CI không có subscription login.
- Rủi ro: run gặp usage limit thì nhận HTTP lỗi, run đó bị chấm 0 và lệnh exit khác 0. Biện pháp:
  - chia suite nhỏ, chạy ngoài giờ;
  - dùng `--ablation none` khi chỉ lặp grader;
  - chỉ chạy judge grader ở lần chạy chính thức;
  - `--max-cost-usd` chỉ là trần ước lượng, không phải hạn mức plan;
  - loại run `partial` khỏi xu hướng.
- Routine cloud cũng chạy bằng tài khoản. Có chạy được `claude plugin eval` trong routine hay không thì **chưa xác minh**, để ở M0.

## 4. Quyết định bổ sung (2026-10-21)

| # | Quyết định |
|---|---|
| Q1 | **Phương án B:** chạy trong session, cộng runner headless `claudehut-run` cho việc offline (eval, mining, drift, báo cáo), chỉ đọc, output là báo cáo hoặc PR nháp. **Kiến trúc hỗ trợ cả hai cách xác thực:** plan (subscription) và API key, xem §7 |
| Q2 | Phase hiện tại chỉ làm plugin. Việc duyệt a3 và mọi thay đổi trên service để sang phase B (§2.3) |
| Q10 | Tech lead hoặc người khởi xướng tạo campaign và giữ template; owner từng service duyệt task con trong repo của mình |

## 5. Q1: "chỉ trong session" và "runner headless"

| | A. Chỉ trong session | B. Session + headless cho việc offline (khuyến nghị) | C. Headless tự làm task |
|---|---|---|---|
| Ai khởi động Claude | Bạn mở `claude` trong repo | Như A, cộng một lệnh `claudehut-run <job>` (hoặc cron hay routine) gọi `claude -p` mà không cần người | Như B, và runner tự mở task code |
| Kernel hoạt động khi | Có session đang mở: hook, CLI, MCP chạy theo thao tác của bạn | Thêm các job chạy theo lịch | Bất kỳ lúc nào |
| Việc làm được | Toàn bộ workflow có người tương tác | + eval suite, mining transcript (tìm lỗi lặp, đề xuất PR vào pack), drift scan (vendor leak, lệch pattern, KB cũ), báo cáo `claudehut status --fleet`. **Chỉ đọc, output là báo cáo hoặc PR nháp** | + implement task campaign ở 14 repo trong đêm, mở PR |
| Quyền | Theo session | profile `dontAsk` + allowlist chỉ đọc; không push | cần L2–L3 không người duyệt, nhiều rủi ro nhất |
| Quota | dùng plan khi bạn làm việc | job tốn thêm quota plan, nên lên lịch ngoài giờ | tốn nhiều nhất |
| Hỏi người khi cần | AskUserQuestion | không hỏi được: ghi câu hỏi vào báo cáo | không hỏi được: dễ đoán sai (lý do các case "headless tự duyệt" ở [01](01-problem-space.md)) |

Khuyến nghị **B**:
- Vòng cải tiến, eval định kỳ và drift sensor cần chạy khi không ai mở session.
- Việc sửa code vẫn có người trong vòng lặp.
- C chỉ nên xét sau khi eval chứng minh tỉ lệ đúng đủ cao.

## 6. Q10: campaign là gì

**Campaign = một thay đổi giống nhau trên nhiều repo, được quản lý như một đối tượng**, thay vì như hiện nay:
- chép prompt ra 14 repo (14 bản khác nhau);
- tự nhắn tin giữa các session;
- tự hỏi "repo nào xong chưa".

Ví dụ campaign `dr-featureflag` (DR + feature flag cho 14 service):

| Thành phần | Nội dung |
|---|---|
| Mục tiêu và template | `ewallet-knowledge/prompts/implement-dr-featureflag.md@rev7`, chỉ một bản; repo trỏ tới bản này, không copy |
| Addendum riêng | ví dụ `notification-ms`: vẫn gửi SMS/ZNS ở DR |
| Danh sách repo + thứ tự | `java-common-ms` (SDK) trước, các service sau |
| Owner từng repo | người hoặc session phụ trách repo đó |
| Trạng thái từng repo | lấy tự động từ event của task con: chưa bắt đầu, đang làm, chờ duyệt, xong, bị chặn |
| Câu hỏi mở | ví dụ "Kafka ở DR là cluster riêng?", gom một chỗ |

Cách chạy:
1. Owner tạo campaign trong hub.
2. Khi bạn mở session ở một repo trong danh sách, SessionStart báo "có task campaign cho repo này" và tạo task con gắn `campaign_id`.
3. Mọi task dùng template mới nhất. Sửa template một lần thì các repo đều thấy, kèm cảnh báo cho task đang làm dở.
4. `claudehut status --campaign dr-featureflag` cho biết "9/14 xong, wallet-ms chờ duyệt…".
5. Campaign **không mang quyền**. Mỗi repo vẫn cần người duyệt trong session của repo đó; campaign chỉ là nơi giao việc và theo dõi.

Câu hỏi Q10 là **ai được tạo và sửa campaign**, và **ai duyệt task con**. Khuyến nghị:
- tech lead hoặc người khởi xướng thay đổi tạo campaign và giữ template;
- owner của từng service duyệt task con ở repo của mình.

## 7. Auth profile: plan và API key (ADR K-17)

**Quyết định.** Mọi thành phần gọi model (session, runner, eval, judge) đều độc lập với cách xác thực. Kernel không giả định cách nào; `claudehut-run` và K11 nhận `auth` là `plan`, `api` hoặc `auto`.

| Mặt | `plan` (subscription) | `api` (API key hoặc provider cloud) |
|---|---|---|
| Lệnh chạy | `claude -p` **không** `--bare` (bare "doesn't use your subscription login") | `claude --bare -p` + `ANTHROPIC_API_KEY` hoặc `apiKeyHelper`; Bedrock/Agent Platform/Foundry dùng biến của provider |
| Plugin được nạp | theo cài đặt của user, cộng `--plugin-dir` nếu cần | chỉ `--plugin-dir`/`--plugin-url` |
| Cấu hình host khác (hook của user như rtk, plugin khác) | **có** chạy, nên host adapter (K5) probe và ghi `env-profile` vào kết quả để so sánh được | không chạy; tái lập tốt hơn |
| Hạn mức | usage limit của plan; run chạm limit bị chấm 0 → loại khỏi xu hướng | USD; `--max-budget-usd`, `--max-cost-usd` |
| Báo cáo chi phí | token + ước lượng list-price (`total_cost_usd` là ước lượng client) | như trái, gần hoá đơn hơn |
| Advisor | có (subscription và API-billed đều dùng được) | có trên Anthropic API; **không** có trên Bedrock/Agent Platform/Foundry |
| Nơi chạy | máy dev hoặc máy riêng đã đăng nhập; routine cloud (chạy được eval hay không: chưa xác minh) | máy dev, CI (secret hoặc OIDC), `claude-code-action` |
| Telemetry | OTel của Claude Code như nhau | như nhau |

`auto`: có `ANTHROPIC_API_KEY`, `apiKeyHelper` hoặc biến provider thì dùng `api`; ngược lại dùng `plan`.

Ràng buộc thiết kế suy ra:
- Tính năng nào thiếu ở một mode (advisor trên Bedrock, routine với API key) phải có đường thay thế hoặc được báo rõ là `unavailable`, không fail im lặng.
- Eval report luôn ghi `auth_mode`, `claude_version`, `env-profile`. Kết quả hai mode không trộn vào cùng một xu hướng.
