# 02 — Nghiên cứu (có nguồn)

Mọi nguồn đã được fetch ngày 2026-10-19. Báo cáo đầy đủ (tiếng Anh): [r3](research/r3-research.md) gồm nền tảng Claude Code, Anthropic, prior art, ADR, knowledge graph, eval; [r5](research/r5-harness-architecture.md) gồm harness engineering, kiến trúc tham chiếu, observability, governance, fleet, cải tiến liên tục, pack. Trích dẫn giữ tiếng Anh.

## 1. Harness engineering như một ngành

- **Định nghĩa.** Harness là mọi thứ quanh model, gồm "Agent = Model + Harness". Với người *dùng* coding agent, harness là lớp ngoài mà team dựng cho project của mình, trên harness có sẵn của agent. ([Böckeler, martinfowler.com](https://martinfowler.com/articles/harness-engineering.html))
- **Hai trục kiểm soát:**
  - **Guides (feedforward)** tác động trước khi agent hành động; **sensors (feedback)** quan sát sau khi agent hành động.
  - Mỗi loại có thể **computational** (test, lint, ArchUnit: rẻ, tất định) hoặc **inferential** (AI review, judge: đắt, không tất định).
  - "Feedback-only gives an agent that repeats mistakes. Feedforward-only gives rules that are never checked." (Böckeler)
- **Đẩy chất lượng sang trái.** Check nhanh chạy trước khi tích hợp; check chậm chạy sau. Ngoài vòng đời thay đổi có **drift sensor theo lịch** và sensor runtime.
- **Ba mục tiêu cần harness:** maintainability (dễ nhất), architecture fitness, behaviour (khó nhất). "Correctness is outside any sensor's remit if the human didn't clearly specify what they wanted."
- **Harness template theo topology dịch vụ** (ví dụ "CRUD business service on the JVM"): đây là động tác giảm độ đa dạng (Ashby). Fleet microservice là đúng trường hợp này.
- **Vòng lái.** Việc của con người là cải tiến harness mỗi khi một lỗi lặp lại: "an ongoing engineering practice, not a one-time configuration".
- **Context engineering.** Câu hỏi "ai quyết định nạp context" (LLM qua skill, người qua slash command, phần mềm qua hook) quan trọng ngang nội dung; copy config của team khác sinh chỉ dẫn mâu thuẫn. ([Böckeler CE](https://martinfowler.com/articles/exploring-gen-ai/context-engineering-coding-agents.html))
- Harness thuần (cùng model, chỉ đổi harness) đưa LangChain từ "Top 30 to Top 5" trên Terminal Bench 2.0. ([LangChain](https://www.langchain.com/blog/the-anatomy-of-an-agent-harness), số liệu chi tiết theo r5)

## 2. Kiến trúc tham chiếu và nguyên tắc

| Nguồn | Điểm đáng lấy |
|---|---|
| [12-Factor Agents](https://github.com/humanlayer/12-factor-agents) | #5 hợp nhất execution state với business state trong một thread tuần tự hoá được, nên resume, fork, audit có sẵn; #7 liên hệ người qua tool call; #8 tự sở hữu control flow; #11 kích hoạt từ mọi nơi |
| [Cognition — Don't build multi-agents](https://cognition.com/blog/dont-build-multi-agents) | "Share context, and share full agent traces"; "Actions carry implicit decisions". Agent viết code song song sẽ trôi khỏi nhau nếu không chung log quyết định |
| [Manus — context engineering](https://manus.im/blog/Context-Engineering-for-AI-Agents-Lessons-from-Building-Manus) | Cache hit rate là "the single most important metric"; prefix ổn định, append-only; ẩn tool bằng mask thay vì gỡ; filesystem làm bộ nhớ; viết lại `todo.md` liên tục; giữ lỗi trong context |
| [OpenAI — practical guide](https://cdn.openai.com/business-guides-and-resources/a-practical-guide-to-building-agents.pdf) | "maximize a single agent's capabilities first"; guardrail nhiều lớp; xếp hạng rủi ro tool (read/write, reversibility, quyền, tài chính); người can thiệp khi vượt ngưỡng lỗi hoặc gặp hành động rủi ro cao |
| Durable execution ([LangGraph interrupts](https://docs.langchain.com/oss/python/langgraph/interrupts), [Temporal](https://temporal.io/blog/durable-execution-meets-ai-why-temporal-is-the-perfect-foundation-for-ai), [OpenHands SDK](https://arxiv.org/html/2511.03690v1)) | Event log append-only; resume bằng replay; condensation ghi cạnh log chứ không thay; side effect idempotent; mỗi tool call có rating rủi ro và chính sách xác nhận |
| [A2A](https://a2a-protocol.org/latest/topics/key-concepts/) | Agent card, task có vòng đời, artifact: hợp đồng bàn giao giữa agent hoặc team |
| [Building effective agents](https://www.anthropic.com/engineering/building-effective-agents), [context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents), [writing tools](https://www.anthropic.com/engineering/writing-tools-for-agents), [long-running harnesses](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) | Đơn giản trước; evaluator-optimizer khi có tiêu chí rõ; ít tool nhưng theo tác vụ; feature list, progress file, một feature mỗi lần |

## 3. Năng lực của host (Claude Code): xây trên, không xây lại

| Năng lực host | Ghi chú cho harness | Nguồn |
|---|---|---|
| Agent loop, subagents (`model`, `effort`, `skills`, `memory`, `isolation: worktree`), workflows, agent teams | Plugin không thay loop. Agent teams còn experimental | [sub-agents](https://code.claude.com/docs/en/sub-agents.md), [workflows](https://code.claude.com/docs/en/workflows.md) |
| Hooks, gồm 30+ event và handler `command/prompt/agent/mcp_tool` | `additionalContext` ≤10.000 ký tự; Stop chặn tối đa 8 lần liên tiếp | [hooks](https://code.claude.com/docs/en/hooks.md) |
| Permission modes, auto-mode classifier, deny rules | "Deny rules block in every mode"; auto mode tạm dừng sau 3 lần chặn liên tiếp hoặc 20 lần tổng | [permission-modes](https://code.claude.com/docs/en/permission-modes) |
| Sandbox OS (Seatbelt, bubblewrap) | Mặc định vẫn **đọc được `~/.ssh`, `~/.aws/credentials`**. Hook, MCP, LSP, công cụ file chạy **ngoài** sandbox | [sandboxing](https://code.claude.com/docs/en/sandboxing) |
| Marketplace, semver `dependencies`, bundle plugin, managed settings | "Claude Code has no release-channel concept", nên dùng hai marketplace (stable, canary) | [plugin-marketplaces](https://code.claude.com/docs/en/plugin-marketplaces), [org](https://code.claude.com/docs/en/plugins/org) |
| Plugin ship được skills, agents, hooks, MCP, LSP, output styles, monitors, `bin/`, workflows | `settings.json` của plugin chỉ nhận `agent` và `subagentStatusLine`; plugin agent bỏ qua `hooks`, `mcpServers`, `permissionMode` | [components](https://code.claude.com/docs/en/plugins/components.md) |
| OTel metrics, events, traces (beta) | Content redact mặc định; repo không bật được telemetry; `OTEL_*` không truyền xuống hook | [monitoring-usage](https://code.claude.com/docs/en/monitoring-usage) |
| Surfaces: CLI, IDE, `claude-code-action`, routines, Agent SDK, headless `--bare` | Routines chạy **không có permission prompt**, mang danh tính user, mặc định có đủ connector | [routines](https://code.claude.com/docs/en/routines), [github-actions](https://code.claude.com/docs/en/github-actions) |
| Advisor, `/goal`, LSP (`jdtls-lsp`), checkpoints, worktrees | Advisor experimental, chỉ trên Anthropic API | [advisor](https://code.claude.com/docs/en/advisor) |
| `claude plugin eval`, `claude plugin details`, `/skill-doctor`, `/insights` | Eval có baseline không plugin (Δ); đo token always-on; phát hiện skill không bao giờ được dùng | [plugin-evals](https://code.claude.com/docs/en/plugin-evals.md), [measure](https://code.claude.com/docs/en/plugins/measure.md) |
| AGENTS.md | Chỉ được đọc khi không có CLAUDE.md. Pattern an toàn: CLAUDE.md một dòng `@AGENTS.md` | r5 §6 |
| [Agent Skills](https://agentskills.io/specification) | Chuẩn mở. OTel GenAI đã có span load skill, đọc resource của skill | r5 §3.1, §6 |

## 4. Observability và governance

- OTel GenAI semantic conventions (trạng thái Development) có `invoke_workflow`, `plan`, `execute_tool`, load-skill span. Harness nên phát sự kiện theo các tên này. ([semconv-genai](https://github.com/open-telemetry/semantic-conventions-genai))
- Không dựng pipeline telemetry riêng. Dùng OTel của Claude Code qua managed settings, thêm thuộc tính `team.id`/`service`.
- Phòng thủ nhiều lớp: deny rules, classifier, sandbox (cả filesystem lẫn network), gateway. Không lớp nào đủ một mình.
- CI và routine dùng `dontAsk` cùng allowlist, không dùng `bypassPermissions`.

## 5. Vận hành fleet và cải tiến liên tục

- **Phân phối:** một kernel plugin, các pack plugin phụ thuộc kernel theo semver, bundle plugin theo vai trò hoặc topology, hai marketplace stable/canary, repo pin bundle trong `.claude/settings.json`. ([dependencies](https://code.claude.com/docs/en/plugins/dependencies))
- **Thang autonomy** read-only → low → medium → high, fail-fast, không để thay đổi dở dang (Factory Droid Exec). Dùng làm từ vựng quyền cho user.
- **Vòng cải tiến:** capture → mine transcript → đề xuất PR vào pack → eval so baseline → canary → stable → gỡ phần không dùng. Không bao giờ tự sửa rule hoặc skill một cách âm thầm. (r5 §5)

## 6. Quyết định thiết kế: generic hay cứng

Phần nghiên cứu cho capability "deliberation": quy tắc Protected Variation hai chiều, MADR, rule of three, YAGNI theo Fowler, Larman. Xem [appendix/a2 §3](appendix/a2-deliberation-pack.md) và r3 §C8.

## 7. Chưa xác nhận

- Bài "Harness engineering" của OpenAI (HTTP 403, chỉ biết qua trích dẫn gián tiếp).
- Số liệu Terminal Bench chi tiết.
- Google ADK, OPA/Cedar cho agent.
- Chế độ durable của LangGraph.
- EARS của Kiro.
- Devin, Factory ngoài Droid Exec.
