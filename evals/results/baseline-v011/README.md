# Baseline v0.11 (M0)

Đo trên plugin 0.11.0, HEAD `0128b37`, ngày 2026-09-29. Nguồn: 23 transcript main thread của ewallet-workspace (`~/.claude/projects/-Users-taiphan-Documents-Projects-ewallet-workspace-*/*.jsonl`) và subagent transcript cạnh chúng. M0 không đổi hành vi plugin.

| Metric | Đo được | Giá trị audit | Khớp? |
|---|---|---|---|
| SessionStart additionalContext, median (transcript, raw) | 8.999 B (n=67) | 8.999 B (F-7) | Có |
| SessionStart median, resolved (thay preview bằng file đã lưu) | 9.005 B (n=64/67) | — | Tham khảo |
| SessionStart mean (transcript, raw) | 7.804 B | 7.833 B (A10) | Gần khớp, xem ghi chú 1 |
| digest.md | 4.331 B | 4.331 B (F-7) | Có |
| SessionStart chạy thật tại HEAD, fixture va-ms (93 learnings + Summer KB) | 8.813 B | — | Tham khảo, xem ghi chú 2 |
| SessionStart chạy thật tại HEAD, plane rỗng | 4.668 B | — | Tham khảo |
| UserPromptSubmit tại HEAD, va-ms: prompt đầu / lặp / lượt máy sinh | 2.114 / 1.895 / 1.908 B | — | Tham khảo (F-6: lượt máy sinh vẫn bị inject) |
| Số đợt review | 52 | 52 (E1) | Có |
| Đợt có ≥4 auditor | 28 | 28 (E1) | Có |
| Đợt có đủ 7 loại auditor | 7 | 7 (E1) | Có |
| Tổng dispatch auditor typed | 208 | 208 (E) | Có |
| `git diff` do auditor tự chạy | 119 (trong 62 transcript auditor) | 119 (E4) | Có |
| Output token/auditor, median | 22.150 | 19–31k (E7, trung bình theo loại) | Trong khoảng |
| Chi phí đợt ≥4 auditor, median: input / output / wall | 22,58M / 118k / 12,7 phút (8 đợt có đủ transcript) | 22,1M / 118k / 12,7 phút (E1, 08-review) | Gần khớp, xem ghi chú 3 |
| Chi phí mọi đợt, median: input / output / wall | 8,51M / 55,2k / 11,3 phút (18 đợt có đủ transcript) | — | Tham khảo |
| `set-complexity`: full / small / trivial | 61 / 12 / 2 (75) | 61 / 12 / 2 (A3) | Có |
| Router case | 22: direct 7, light 6, full 7, ask 2; `--validate` ok | ~20 (M0) | Có |

## Ghi chú

1. Mean 7.804 B so với 7.833 B: chưa xác định được nguyên nhân. Transcript thứ 23 (neo-flagd, ngày 09-29) không có bản ghi SessionStart nào, nên không gây ra chênh lệch. Bỏ lần lượt từng transcript cho mean trong khoảng 7.285–7.975 B, không lần nào ra 7.833 B. Median vẫn là 8.999 B.
2. Fixture tại HEAD chỉ chép `learnings.jsonl` và `.summer-kb-meta.json` của va-ms vào thư mục tạm. `claude` được stub trên PATH, nên cờ understand-anything luôn là "absent". Số liệu transcript đến từ nhiều phiên bản plugin cũ hơn, một số phiên còn inject toàn bộ SKILL.md. Vì vậy 8.813 B chỉ dùng tham khảo; tiêu chí F-7 so với median transcript.
3. Chỉ 62/208 dispatch auditor có subagent transcript liên kết được qua `toolUseId` trong `*.meta.json`. Các phiên cũ không lưu transcript này. Con số của E1 là median trên đợt ≥4 auditor; tính đúng tập đó (8 đợt có đủ transcript cho mọi auditor) được 22,58M input, 118k output, 12,7 phút, khớp output và wall, input lệch ~2%. Median 8,51M là trên cả 18 đợt đủ transcript, gồm đợt 1–3 auditor, nên không so với E1. Mẫu nhỏ (8/28 đợt ≥4).
4. Cách gom đợt: trong cùng một transcript, dispatch cách dispatch trước ≤300 s thì thuộc cùng đợt. Kết quả ổn định từ 120 s đến 600 s (52/28/7). Nếu gom theo message id thì được 77/24/4. Chi tiết ở header `evals/review-cost.sh` và mục `sensitivity` trong `review-cost.json`.
5. Router case lấy từ đoạn trích tối đa 500 ký tự của prompt thật; case nào bị cắt có `truncated: true`. Đã bỏ prompt chứa credential, đã che mã FT và đường dẫn tuyệt đối. Việc trích toàn văn prompt bị auto-mode classifier từ chối, nên không có bản đầy đủ.

## File

- `payload.json`: `lint-prompt-length.sh --payload --json` và `--payload-transcripts --json`
- `review-cost.json`: `evals/review-cost.sh --json`, gồm cả số liệu từng đợt
- `router-cases-validate.txt`: `evals/router-eval.sh --validate` và `--self-test`

Chạy lại: `scripts/lint-prompt-length.sh --payload`, `scripts/lint-prompt-length.sh --payload-transcripts`, `evals/review-cost.sh`, `evals/router-eval.sh --validate`.
