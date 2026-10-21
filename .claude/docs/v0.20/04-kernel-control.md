# 04 — Kernel và control plane

Phạm vi: K1–K5 và K8 (§3 của [03](03-reference-architecture.md)). Knowledge (K6) ở [05](05-knowledge-plane.md); sensor (K7) ở [06](06-quality-plane.md); pack registry (K10) ở [07](07-packs-distribution.md); telemetry và eval (K9, K11) ở [08](08-observability-eval.md).

## 1. K1 — Task và run-state store

**Mô hình.** Mỗi task có:
- `events.jsonl`, append-only: nguồn sự thật;
- `task.json`, projection tính lại được từ events;
- artifact: spec, plan, review, `progress.md`.

Theo 12-factor #5: execution state và business state chung một thread tuần tự hoá được.

| Quy tắc | Lý do |
|---|---|
| **Writer duy nhất là state CLI**, gọi tại transition tường minh | Hook không đủ tin cậy: 6.772 stop không có start, và SubagentStop không fire với background agent (OBS-1) |
| Hook chỉ **làm giàu** (`enrich` event có cờ `source: hook`), sau đó đối soát với event của CLI | Mất event hook không làm sai state |
| Event có kiểu: `task.started`, `route.set`, `tier.set`, `phase.entered`, `artifact.rev`, `decision.recorded`, `sensor.result`, `review.verdict`, `gate.blocked`, `gate.overridden`, `escalation.raised`, `handoff.written`, `task.ended` | Resume, audit, replay, metric (PLN-5: route cũng là event, kể cả `direct`) |
| Side effect (PR, push, campaign update) idempotent theo `task_id + step` | Retry không tạo trùng |
| Ghi bằng khoá file và rename nguyên tử; schema có version | STA-4, STA-3 |
| TTL: task `active` không có event trong N ngày → `stale`, đưa vào `claudehut status` | STA-2 |

**Resume và session theo task (CTX-1, MAO-4).**
- `claudehut-state resume <id>` dựng digest từ projection, phần cuối `progress.md` và các quyết định đang hiệu lực.
- Session mới tiếp tục được mà không cần mega-session.
- Phase dài chia thành checkpoint. Subagent trả kết quả từng phần vào file, nên một agent treo không làm mất cả phase.

## 2. K2 — Invariant và policy engine

Bất biến được kiểm **chỉ tại transition** của task (`set-*`, `end`). Nhờ vậy:
- việc ngoài workflow không bao giờ bị chặn;
- hook vẫn chỉ advisory (giữ ADR-R3/H2 của 0.12);
- không đụng giới hạn 8 lần chặn của Stop hook.

| Nguồn bất biến | Ví dụ |
|---|---|
| Kernel (luôn bật) | `end done ⇒ review ∉ {pending, stale}` khi route cần review; verdict gắn `head_tree` + `spec_rev`; event log hợp lệ |
| Pack workflow | `set-plan` cần AC đã xác nhận (PLN-2); tier ≥T2 cần DEC |
| Pack deliberation | DEC có Confirmation |
| Pack org/domain | money path ⇒ tier ≥T2; bump BOM ⇒ chạy sensor version |

Mỗi bất biến có:
- `severity`: `warn` hoặc `block`;
- thông điệp nói rõ sai gì và cách sửa (thông điệp sensor viết cho model đọc);
- `--override "<lý do>"`. Override được ghi thành event và đếm trong metric; tỉ lệ cao nghĩa là bất biến sai.

**Mức chặt của workflow cần user quyết** (Q6 ở [09](09-adr-roadmap.md)). Phương án mặc định đề xuất: bất biến kernel ở mức `block` có override, bất biến pack ở mức `warn`.

## 3. K3 — Workflow engine

- Phase, artifact và template **không nằm trong kernel**. Pack `workflow-standard` khai báo `discover → spec → plan → implement → review → learn`. Team khác có thể thay pack, ví dụ dùng superpowers hoặc spec-kit làm workflow (CMP-2).
- Hai trục:
  - **route** (`direct | light | full`) quyết định lượng tài liệu;
  - **tier** (T0–T3) quyết định mức cân nhắc ([a2 §1](appendix/a2-deliberation-pack.md)).
- Router vẫn là prompt rubric, nhưng mọi quyết định route/tier đều là event. Tín hiệu rủi ro do pack khai báo (money path, xuyên service, bump SDK) tự nâng route hoặc tier (PLN-5, STA-1).

## 4. K4 — Context assembler

| Phần | Quy tắc |
|---|---|
| Always-on (CLAUDE.md của plane, MEMORY.md, digest SessionStart) | Budget cứng: tổng ≤N token, đo bằng `claude plugin details` trong CI. Không chèn timestamp hay bộ đếm biến động vào prefix (Manus, cache) |
| Theo task | `kb_brief`, DEC liên quan, learning theo task (≤600 ký tự), phần cuối `progress.md` |
| Theo path | rule của pack nạp qua `paths:`; chỉ pack đã kích hoạt mới có rule (CTX-2) |
| Handoff | `progress.md` ghi cạnh event log, không thay log; recitation (todo) cho task dài |
| Budget artifact | đếm bằng máy; bất biến `warn→block` theo tier (PLN-3) |

## 5. K5 — Host adapter và profile

### 5.1 Capability probe (SessionStart, async, cache theo phiên)

Probe ghi `env-profile.json` gồm:
- phiên bản Claude Code;
- permission mode;
- sandbox có bật không;
- MCP có sẵn không;
- advisor, agent teams;
- shell (zsh/bash), `FORCE_COLOR`;
- **hook PreToolUse của plugin khác có rewrite input** (ví dụ rtk đổi `git` thành `rtk git`);
- danh sách plugin, skill và agent khác đang bật;
- stack detect (cho K10);
- **auth mode** (`plan`, `api`, provider cloud) và tính năng khả dụng theo mode, ví dụ advisor không có trên Bedrock ([09 §7](09-adr-roadmap.md)).

Kernel đọc profile để:
- **ENV-1/CMP-1:** khi phát hiện wrapper rewrite, cảnh báo user một lần kèm cách cấu hình loại trừ. Prompt của subagent worktree dùng đường dẫn tuyệt đối (`/usr/bin/git`) cho lệnh cần guard xác minh. Sensor của kernel chạy lệnh raw, không qua wrapper (ACI-2).
- **ACI-3:** chỉ phát agent hoặc tool khi capability có thật. Không có Bash thì không giao việc cần Bash.
- **CMP-2:** biết plugin khác để không giành phase của workflow plugin khác. Skill của plugin khác (ví dụ `ewallet-query-audit`) được liệt kê như guide khả dụng.

### 5.2 Thang autonomy (profile, user sở hữu)

| Mức | Cho phép | Ánh xạ host |
|---|---|---|
| L0 read-only | đọc, tìm | `plan` / deny Write, Edit |
| L1 local edit | sửa file trong repo | `acceptEdits` |
| L2 build & local git | build, test, commit local | allow `./gradlew *`, `git commit` |
| L3 remote | push, mở PR | allow theo remote đã tin cậy; merge vẫn cần người duyệt (auto-mode mặc định chặn) |

- `claudehut-init` sinh profile và chỉ ghi vào settings **khi user đồng ý** (HIL-3). Profile CI/routine dùng `dontAsk` cộng allowlist.
- **Không có "grant" do harness phát hành** (P11).
  - Việc vượt mức của delegate (subagent, workflow agent) phải **escalate lên main thread** bằng event `escalation.raised`; user duyệt trên chính session đó (HIL-1).
  - Push và mở PR chỉ thực hiện ở main.

## 6. K8 — Coordination và campaign (MAO-1, MAO-2)

Host không có primitive điều phối xuyên repo, chỉ có tin nhắn giữa session. Kernel bổ sung phần này.

| Khái niệm | Nội dung |
|---|---|
| **Campaign** | Một thay đổi trên nhiều repo, đặt ở hub: `campaigns/<id>/campaign.json` (mục tiêu, repo đích, template tham chiếu, owner, trạng thái tổng) |
| **Template tham chiếu** | Prompt hoặc spec chuẩn có version; task con trỏ tới `template@rev` cộng addendum riêng. Không copy (MAO-2, LIF-2) |
| **Task con** | Task bình thường ở repo đích, có `campaign_id`; mỗi event trạng thái của nó được ghi vào hub |
| **Ownership, khoá** | Mỗi repo trong campaign có owner session hoặc người; khoá mềm (lease có hạn) chống hai writer trên một repo/branch (P10) |
| **Hợp đồng bàn giao** | Theo hướng A2A: task có trạng thái, artifact, câu hỏi mở. Phụ thuộc giữa repo được ghi tường minh (SDK trước, consumer sau) |
| **Thông báo** | **Kiểu pull:** SessionStart của mỗi repo đọc task campaign đang chờ từ hub và đưa vào digest (một dòng tham chiếu cố định). CLI kernel không gửi được tin nhắn, vì `SendMessage` là tool của model. Agent có thể nhắn peer như kênh phụ, nhưng tin nhắn không mang quyền: peer vẫn cần user của nó duyệt |
| **Trạng thái** | `claudehut status --campaign <id>`: repo nào xong, dở, bị chặn, chờ duyệt |

## 7. Runtime: từ shell sang có kiểu (RC6)

- **Đề xuất:** kernel viết bằng Python 3 stdlib (đã dùng cho index), gói `claudehut_kernel`, không dependency ngoài. `bin/` chỉ giữ shim 3 dòng. Lý do: hiện có 11,7k dòng bash dưới zsh của user và một loạt lỗi tính khả chuyển (ENV-4, ACI-4, STA-4).
- **Migrate kiểu strangler**, không viết lại một lần:
  1. `claudehut-state` (K1, K2) và `claudehut-verify` (K7) trước, sau shim cùng CLI;
  2. sau đó hook dispatcher;
  3. `claudehut-init` và `claudehut-worktree` cuối cùng; worktree dần nhường cho host.
- Mỗi bước giữ nguyên hợp đồng CLI, nên suite cũ (1.654 assertion) vẫn dùng làm regression. Thêm fixture env-hostile: zsh, `FORCE_COLOR`, path có dấu cách, wrapper rtk (EVL-3).
- Ngôn ngữ kernel là câu hỏi mở cho user (Q8).
