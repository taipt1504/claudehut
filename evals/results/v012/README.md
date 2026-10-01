# Đánh giá v0.12 (M7)

Đo trên plugin 0.12.0, nhánh `feat/v0.12-m7` (xếp trên M0–M6), ngày 2026-10-01, máy Mac 10 CPU, load 2,9–4,2. Đây là bộ đo M0 ([baseline-v011](../baseline-v011/README.md)) chạy lại trên v0.12 theo [10 §5](../../../.claude/docs/v0.12/10-rollout-eval.md#5-kế-hoạch-eval). Mọi lệnh chỉ đọc ewallet-workspace. Số chi phí review của v0.11 lấy từ transcript cũ nên là số lịch sử; v0.12 chưa có đợt review thật, nên các metric cần phiên thật được ghi "sau phát hành".

## Kết quả

| Metric | v0.11 baseline | v0.12 | Mục tiêu | Đạt? |
|---|---|---|---|---|
| Router (22 case ewallet, sonnet, 1 lượt) | digest v0.11: 10/22 đúng; direct/light→full 6; vi phạm "skip workflow" 1 | 18/22 đúng; full→direct 0; direct/light→full 0; vi phạm 0 | full→direct = 0; ít direct/light→full hơn v0.11 trên cùng model | Có |
| Phân bố tuyến trong phiên thật | full 61/75 (81%) | chưa có phiên v0.12 | — | Sau phát hành |
| Deny ngoài workflow | ~8 deny fast lane; deny ghi scratchpad | 0 `decision`/`permissionDecision`/`updatedInput` trên mọi fixture và replay (`hook-tests.sh`) | 0 | Có |
| Lỗi hook | 356 "hook error" | 0; mọi output thoả `jq -s 'length<=1'` (`hook-tests.sh`) | 0 | Có |
| Stop hook | 292 block | không còn Stop hook; `hooks.json` 13 handler / 16 entry (`conformance.sh`) | 0 | Có |
| UserPromptSubmit | ~1,15 MB, 51% trên lượt máy sinh | lượt máy sinh 0 B ở cả 3 fixture; lượt người gõ 413–503 B, khối learnings ≤500 ký tự (K9) | rỗng với lượt máy sinh; ≤500 ký tự | Có |
| SessionStart | median 8.999 B | worst 3.702 B · va-ms 2.959 B · rỗng 2.642 B; digest 2.400 B; card 413 B | ≤4.000 / ≤2.500 / ≤500 B | Có |
| Độ trễ hook (benchmark) | bootstrap spawn `claude plugin list` 1–5 s; gate-done p50 156 ms | bootstrap p95 15,9 ms; inject-phase 12,0 ms (store 100 entry 31,3 ms); advise-write 6,7 ms; hint-explore ≤24,5 ms | p95 ≤50 ms không task; bootstrap ≤300 ms | Có (báo cáo, không gate) |
| MEMORY.md | party-ms 105.333 B | dry-run migrate trên bản thật: party-ms 1.380 B; lớn nhất 3.312 B (report-service-ms, giữ phần người viết); plane mới ≤2.048 B | ≤8.192 B; plane mới ≤2.048 B | Có |
| Learnings rỗng | 40 entry | dry-run: java-common 21 + payment-gateway 7 + va 12 = 40 chuyển sang `learnings.rejected.jsonl`; còn 0 | 0 | Có |
| Hits sau 30 ngày | payment-gateway-ms 317/400 entry hits≤1 | — | đo lại sau 30 ngày | Sau phát hành |
| Path index | reuse-index party-ms 24/43 | va-ms 149/149 qua `test -f` (`index-tests.sh`) | 100% | Có |
| Độ tươi index | graph lệch 374 commit | `indexed_commit=HEAD` sau pull nhờ git hook, nếu không thì ở lượt kế (`index-tests.sh`); dry-run: hook cài ở 9/13 service, 4 repo có `core.hooksPath` chỉ nhận hướng dẫn | ≤10 s hoặc lượt kế | Có |
| Khám phá lặp (07 AC-14) | explorer ~23 call/lần; 329 lần đọc chéo service ở va-ms | chưa có lần chạy v0.12 | giảm ≥40% / ≥50% trên 10 task | Sau phát hành |
| Độ dài tài liệu | p90 plan 4.611 / spec 2.747 / brainstorm 2.038 từ (C2) | corpus v0.11 theo đơn vị doclint: p90 plan 3.870 / spec 2.342 / brainstorm 1.864; artifact v0.12 chưa có | p90 plan ≤1.500, spec ≤1.200, brainstorm ≤600 trên 20 task đầu | Sau phát hành |
| Cấu trúc tài liệu | 41% dòng plan là code; 0/200 spec có Mermaid; AMENDMENT 7–11 file | replay 613 artifact / 207 task dir bắt đủ 3 mục tiêu (L4 va 0008, L2 va 0024, L6 party 0002); gate chạy ở `set-spec`/`set-plan` | 0 fence java/kotlin, 0 AMENDMENT trên artifact mới | Cơ chế có; đo trên task mới sau phát hành |
| Fan-out review | 28/52 đợt ≥4 agent | replay 22 task: 10/22 (45,5%) → 5/22 (22,7%), dispatch 81 → 67; khung 52 đợt: 21,2–32,7% | ≤25% mọi đợt ≥4 lane | Chưa chứng minh; đo lại trên đợt thật sau phát hành |
| Chi phí review | median đợt ≥4 auditor 22,58M input / 118k output / 12,7 phút | chưa có đợt v0.12 | S ≤3,5M, M ≤9M, L ≤15M; ≤8k output/auditor | Sau phát hành |
| Recall review | 72 MED+ trong diff | lane hoặc sàn 73,6%; 19/19 ca chỉ-escalate có fixture | 100% kể cả escalate | Có điều kiện: 100% là theo cách dựng, không phải phép đo |
| Danh tính agent | 61% dispatch có `name` | 100% dòng ledger có `resolved_type` (`hook-tests.sh`) | 100% | Có |
| MCP trong agent | 0 lời gọi MCP đúng tên | 0 `mcp__*` trong frontmatter (`conformance.sh`) | 0 | Có |
| Ngôn ngữ trong prompt dispatch (04 AC15) | — | dòng ngôn ngữ có trong digest, workflow, implement, review (pin conformance); chưa quan sát trong phiên thật | agent nhận đúng ngôn ngữ | Sau phát hành |

## Migration ewallet (chỉ dry-run)

`claudehut-migrate --dry-run` trên workspace thật (13 service có plane, 6 repo hub-scan) không ghi byte nào vào workspace. Checksum trước và sau giống nhau, kể cả `.git/index`, `.git/config` và `.git/hooks` của mọi repo. Bản kế hoạch: [migrate-dry-run.txt](migrate-dry-run.txt).

Diễn tập `--apply` trên bản sao clonefile cho kết quả sau:

- Hub có 19 service, 147 cạnh và 64 unresolved.
- Chạy apply lần hai không đổi file nào.
- `--restore` trả lại từng file đã backup của 13 service và root, đúng từng byte.
- Sau đó chạy `--refresh-rules` (bước `maintain.sh` làm ở lần nâng version kế tiếp) không thêm `.worktreeinclude` hay khối marketplace.

Dry-run còn tìm ra hai lỗi trong `merge-learnings.sh`, cả hai đã sửa và có test:

- Cả 7 entry của aml-service để nội dung learning trong `summary`, nên bị coi là rỗng.
- Các entry này dùng `ts` chỉ có ngày, bị đọc thành epoch, nên bước prune sẽ xoá chúng. Nay `--repair` còn gán cho entry viết tay những gì entry mới có: id, confidence 0,6, hits 1.

7 repo có plane bị gitignore, chứ không phải 4 như §4 ghi. Migrate chỉ in patch cho các repo này.

Ba lưu ý khi chạy thật:

- Git hook ghim đường dẫn của `claudehut-index` đã cài nó. Vì vậy nên chạy migrate từ bản plugin đã cài, không chạy từ thư mục dev.
- `learnings.jsonl.migrated` ở root là bản sau `--repair` (key đã chuẩn hoá). Bản gốc nằm trong backup.
- Root `CLAUDE.md` @import `HUB.md` của repo tri thức riêng. Theo yêu cầu M7, việc này khác 07 §4.3, nơi chỉ nói tới hub đặt ở root.

## File

- `payload.json`: `scripts/lint-prompt-length.sh --payload --json`
- `router-v012-sonnet.txt`: `evals/router-eval.sh --digest skills/claudehut-workflow/references/digest.md --model sonnet`. So sánh với [m2-router/v011-sonnet.txt](../m2-router/v011-sonnet.txt).
- `doclint-replay.txt`: `evals/doclint-replay.sh`, chạy trên corpus v0.11
- `review-replay.txt`: `evals/review-replay.sh` và `--frame ../baseline-v011/review-cost.json`
- `hook-bench.txt`: `evals/hook-bench.sh`
- `migrate-dry-run.txt`: `bin/claudehut-migrate --dry-run` trên workspace thật, đường dẫn đã che
