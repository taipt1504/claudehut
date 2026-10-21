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
- Góp phần vào ma sát: trong session tương tác, mỗi lần ghi artifact sẽ hiện prompt hoặc đi qua classifier; còn ở `dontAsk` thì bị từ chối hẳn. Đây cũng là lý do `evals/run.sh` cũ phải dùng `--dangerously-skip-permissions`. Mối liên hệ với khoảng 150 Write denial thời v0.11 (STA-5) **chưa được xác minh**: r4 quy các denial đó chủ yếu cho gate riêng của ClaudeHut (scratchpad, `.understand-anything`).

Đề xuất **ADR K-18 (chờ user)**: chuyển phần artifact ghi thường xuyên (tasks, learnings, index, events) ra khỏi `.claude/`, ví dụ sang `<repo>/.claudehut/`. Chỉ giữ dưới `.claude/` những gì Claude Code phải tự đọc (rules, skills, CLAUDE import). Việc migrate 20 scope thuộc phase B, dùng `claudehut-migrate`.

## Eval: fail-open và grader

- Thêm grader `gate-never-skipped` (regex trên trace: `gate (review-pass|end) skipped`, `not_contains`) cho cả hai case process. Nếu kernel lỗi trong sandbox (python3 là shim xcrun và in lỗi cache), gate sẽ bị bỏ qua và lọt PASS giả; grader này bắt trường hợp đó.
- Một lần chạy trước từng có `"review":"pass"` mà không giải thích được. Không tái hiện được trong 3 lần chạy sau; cả hai lần có trace đều cho thấy gate BLOCK đúng. Giữ ở trạng thái **chưa xác minh**; grader mới sẽ bắt nếu lặp lại.
- Run eval không có JDK dùng được: `/usr/bin/java` là stub, còn JDK của SDKMAN nằm dưới `$HOME` mà sandbox không đọc được. Case outcome vẫn qua khi agent tìm được javac.

## M0 — baseline đầy đủ (2026-10-21)

Chạy bằng plan quota: 0.12.7 `--ablation with-without` × 3 run, rồi 0.12.6 (tag `baseline-0.12.6`) × 3 run. Tổng $12.10 (giá list; plan không tính tiền theo token).

Provenance (`run-meta.json`): arm "0.12.7" là `a65180b` + **cây đang dirty** (sửa suite và một phần K-18 chưa commit, phần K-18 lúc đó chỉ là resolver, fallback legacy). Arm 0.12.6 là `9860eb7`, sạch. Vì vậy cột 0.12.7 phải đọc là "0.12.7 + WIP", không phải bản release sạch.

| Case | 0.12.7 with | 0.12.7 without | 0.12.6 with | Ghi chú |
|---|---|---|---|---|
| bank-export-follows-param | 0.50 | 0.50 | 0.50 | Không arm nào nhận ra variation point (`bank-is-a-variation-point` fail ở mọi run) |
| single-client-no-abstraction | 1.00 | 1.00 | 1.00 | Guard "không over-engineer": không phân biệt |
| vendor-neutral-columns | 0.83 | 0.83 | 1.00 | 1/6 run có cột tên vendor; chênh với 0.12.6 nằm trong nhiễu (3 run) |
| zns-follows-provider-pattern | 0.00 | 0.00 | 0.00 | Bản hardened bắt được lỗi: không arm nào đi theo pattern provider |
| fix-rounding-bug | 1.00 | 1.00 | 1.00 | Outcome guard |
| end-refused-without-review | 0.93 | 0.60 | 0.60 | Δ +0.33: end gate của Track Q có tác dụng; 0.12.6 không có gate (`gate-fired` fail) |
| review-pass-fixes-bad-citation | 1.00 | 1.00 | 0.83 | Không phân biệt with/without; grader cần siết (xem dưới) |

Kết luận:
- **Process**: Track Q đo được. `end-refused-without-review` tăng từ 0.60 lên 0.93, cả so với without lẫn 0.12.6.
- **Decision**: chưa arm nào giúp được. zns 0.00 và bank-export 0.50 ở mọi arm. Đây là mục tiêu của deliberation pack (M4); suite hiện đã đủ nhạy để đo nó.
- **Lỗi của suite**: `review-pass-fixes-bad-citation` đạt 1.00 ngay cả khi không có plugin, nên grader đang chấm "báo cáo trung thực" chứ chưa chấm "gate bắt được citation sai". Cần một grader chỉ pass khi có plugin, trước khi dùng case này làm bằng chứng.
- Hai guard (`single-client`, `fix-rounding`) giữ 1.00 ở mọi arm, đúng vai trò: một pack sau này làm tụt guard là regression.

## M1a — K-18: plane ra khỏi `.claude/` → 0.12.8 (2026-10-21)

| Thiết kế | Đã build | Lệch / ghi chú |
|---|---|---|
| Plane ghi được nằm ở `<repo>/.claudehut/` | Resolver duy nhất (bash `scripts/lib/plane-path.sh`, Python `claudehut_kernel/plane.py`); mọi hook, `claudehut-state`, doclint, index/hub/memory đi qua nó | Chỉ đổi cách tìm path; gate, hook và schema giữ nguyên hành vi |
| Legacy vẫn chạy | `.claudehut/` thắng; chỉ có `.claude/claudehut/` thì dùng legacy; không có gì thì dùng mới | Có cả hai: dùng mới, không merge. Migrate từ chối repo có cả hai |
| `claudehut-init` | Repo mới → `.claudehut/` + `.gitignore` `*` (plane mặc định local), import `@.claudehut/…` | `.gitignore` của project vẫn không bao giờ bị sửa |
| `claudehut-migrate` | Thêm script riêng `bin/claudehut-migrate-plane` (dry-run/apply), không gộp vào `claudehut-migrate` | `claudehut-migrate` cũ là migration workspace v0.11→v0.12, cần `--workspace/--hub`; move layout là việc theo từng repo nên tách ra cho đơn giản. Chưa chạy trên scope nào (phase B) |
| Skill/agent | Skill dùng `<plane>/…`; SessionStart in `Plane: .claudehut/` cạnh dòng State CLI. Agent ghi rõ cả hai layout, vì subagent không thấy context SessionStart | — |

Test: thêm `regress/plane-layout-tests.sh` (18). Fixture init/hub tạo plane mới thì giờ kỳ vọng `.claudehut/`. Các suite dựng fixture legacy giữ nguyên và vẫn xanh, đó chính là test cho legacy.

Theo review của advisor, đã sửa thêm:
- `claudehut-migrate` (migration workspace) cũng đi qua resolver. Hub mới được tạo ở `<hub>/.claudehut/hub`, không còn tạo song song bản legacy; có test riêng cho việc này. `MEMBERS` của backup/restore và prefix của dry-run giờ có `.claudehut`.
- Index/hub bỏ qua `.claudehut/` khi walk file (non-git) và khi lọc danh sách file.
- Federation learnings bỏ qua plane legacy của một sibling nếu sibling đó đã có `.claudehut/`.
- `.worktreeinclude`: không thêm plane. Bản legacy cũng không copy plane vào worktree; subagent nhận đường dẫn task trong dispatch prompt. Giữ nguyên để tương đương legacy.

Còn lại của M1: chuyển state sang Python với event log làm nguồn sự thật, và sửa lỗ hổng `start`/`supersede_active` bỏ qua end gate. Chưa có eval case process chạy trên layout mới (tốn quota; để chung với lần chạy eval M1 tiếp theo).

### Eval K-18 trên layout mới (2026-10-21, plan quota)

Case `process/review-pass-new-plane`, 3 run × with/without, cộng 1 run giữ trace:
- **Edit vào `.claudehut/tasks/*/review.md` dưới `dontAsk` thành công 7/7 run** (grader file `citation-fixed-in-file`). Trên `.claude/claudehut/`, cùng thao tác này bị từ chối, nên đây là bằng chứng K-18 giải quyết đúng vấn đề.
- Pass không được ghi, và như vậy là **đúng**: `set-review pass` từ chối vì review.md không có bằng chứng test mới (fixture không có build). Grader `review-recorded-pass` đã bỏ, vì một agent trung thực không thể đạt nó trong fixture này.
- Bản đầu của fixture có ghi `./gradlew test — 1 passed` trong khi repo không có build. Agent từ chối pass và chỉ ra claim đó là giả. Cũng vì vậy mà `review-pass-fixes-bad-citation` đạt 1.00 ở cả arm without (M0): grader `honest-report` thưởng cho việc từ chối, mà việc đó không cần plugin. Case đó cần thiết kế lại trước khi dùng làm bằng chứng.
- Case này không phân biệt with/without (0.75/0.75), vì arm without cũng sửa được file. Nó là bằng chứng cho đường ghi, không phải cho giá trị của plugin.
- Môi trường eval: `git` trong sandbox là shim xcrun và lỗi khi tạo cache, nên các lệnh git của kernel có thể fail khi chạy eval. Cần một case riêng hoặc chỉnh môi trường trước khi chấm review binding qua eval.

## M1b-a — state writer sang Python, không đổi hành vi (2026-10-21)

Theo advisor, M1b tách thành ba commit, mỗi commit đều xanh: (a) port không đổi hành vi, (b) event log làm nguồn sự thật, (c) sửa lỗ hổng supersede.

| Thiết kế (04 §7) | Đã build | Ghi chú |
|---|---|---|
| Strangler: `claudehut-state` trước, giữ nguyên hợp đồng CLI | `bin/claudehut-state` là shim, gọi `scripts/kernel/state_cli.py` → `claudehut_kernel/state.py`. Bản bash 0.12 nằm ở `scripts/legacy/claudehut-state.sh` | Fallback sang bash khi `CLAUDEHUT_STATE_IMPL=bash`, khi không có python3 hoặc python < 3.8 (`state_cli.py` tự exec bash, nên chỉ tốn một fork), và với `cost-report` (chỉ đọc). Một transition không bao giờ bị chạy lại bằng writer kia |
| Gate chạy trong process | `gates.run()` dùng chung cho CLI `claudehut-kernel gate` và state.py | Gate raise exception thì ghi `gate.skipped` và transition vẫn đi tiếp, giống R7 của bash |
| Lock tương thích | flock trên `.state.lock.flock` cộng mkdir lock `.state.lock` (stale sau 30 s, chờ tối đa 10 s rồi fail-open) | Repo có cài lẫn nhiều bản plugin vẫn serialize được |

Kiểm chứng:
- Toàn bộ suite chạy với cả hai writer (`CLAUDEHUT_STATE_IMPL=py` và `bash`) đều xanh.
- `state-diff-tests` chạy 4 kịch bản, tổng 68 lệnh, qua cả hai writer và so transcript: exit code, stdout, stderr, task.json, pointer, events. Mutation test (đổi một message) bị bắt.
- `state-lock-tests` ghim các interleaving của lock trong process. Lý do: stub `mkdir` trên PATH của hook-tests không chạm được tới syscall `os.mkdir`, nên với writer Python thì check R3-C1 của hook-tests chuyển sang kỳ vọng `00000`.
- Test đọc source (conformance R1, WS-8b, DT-11) giờ trỏ vào `state.py`. Doc của hợp đồng CLI nằm ở header của shim, nơi state-tests grep.

## M1b-b — event log làm nguồn sự thật (2026-10-21)

| Thiết kế (04 §1) | Đã build | Ghi chú |
|---|---|---|
| `events.jsonl` append-only là nguồn sự thật; `task.json` là projection | `claudehut_kernel/tasklog.py`: `commit()` append một state event (`rev`, `session`, `data.snapshot` hoặc `data.patch`/`unset`) rồi mới ghi projection, có `event_rev` | Hook vẫn đọc `task.json`, nên projection được ghi đồng bộ ở mỗi transition |
| Event có kiểu | `task.started`, `phase.entered`, `route.set`, `artifact.rev` (`data.kind`), `review.verdict`, `task.ended`, `task.superseded`, `task.resumed` | **Thêm ngoài danh sách 04 §1:** `plan_review.verdict`, `profile.set`, `enforcement.set`, `outstanding.set`, `task.imported` |
| Writer duy nhất, hook chỉ enrich | Chỉ state event (có `rev` + patch/snapshot) mới đổi projection. Event `gate.*`, `budget.exceeded` và các dòng `review.verdict`/`task.ended` mà gate CLI 0.12.7 đã ghi đều chỉ mang thông tin | Replay log cũ không bị lệch. Trên đường Python, gate chạy với `record=False`, nên mỗi transition ra đúng một event |
| Ghi nguyên tử, schema có version | Transition bị refuse thì không ghi gì. Log đi trước `task.json` (crash sau khi append) → writer kế tiếp re-project trước khi làm. `task.json` bị writer khác sửa (bash fallback, sửa tay) → ghi `task.imported` | Giới hạn đã biết: nếu crash *và* bash fallback cùng sửa một task trước lần ghi Python kế tiếp, phần bash sửa sẽ bị projection ghi đè. Hiếm; bash chỉ là fallback một release |

Kiểm chứng:
- `claudehut-kernel replay --task DIR [--check]`.
- Với `CLAUDEHUT_STATE_SELFCHECK=1`, mỗi lần ghi sẽ replay rồi so lại. Toàn bộ suite chạy ở chế độ này với writer Python và đều xanh. Thêm canary replay trong selftest.
- `tasklog-tests` (10) phủ: một event cho mỗi transition, refuse thì không có event, import task 0.12, import khi có writer khác, phục hồi sau crash, và log 0.12.7 cũ.
- `state-diff` giờ bỏ qua state event khi so (bash không có), nhưng bắt buộc mọi task phải replay đúng.
- Fault canary chỉ dùng cho test: `CLAUDEHUT_KERNEL_FAULT=gate` (R7-py).

## M1b-c — supersede đi qua end invariant (2026-10-21)

Lỗ hổng tồn từ review Track Q: `supersede_active` (do `start` và `resume` gọi) đóng task đã "finished" thành `done` mà không qua end gate. Một review pass rồi bị sửa tiếp (binding stale) vẫn thành `done`.

Đã sửa (chỉ ở writer Python; writer bash 0.12 giữ nguyên làm fallback):
- Task finished → chạy end gate in-process, `status=done`, `record=False`.
- Mode `warn`: vẫn `done`, ghi `gate.warned`.
- Mode `block`: task thành `superseded` (vẫn resume được để sửa), ghi `gate.blocked`, có notice nêu invariant.
- Gate crash: giữ hành vi 0.12 (`done`).
- `start`/`resume` không bao giờ bị từ chối vì task cũ.
- Task chưa finished: `superseded`, không chạy gate.
- Test SU1–SU8 trong verify-tests: block/stale, warn, review còn hiện hành, task chưa finished, đường resume.

Auth profile (K-17): eval-harness A1–A4 ghim nhánh auth của `plugin-eval.sh`. Một lần chạy `api` thật không làm được, vì quyết định Q7 là eval chạy bằng quota của plan, không dùng API key. Tiêu chí "suite chạy được cả plan lẫn api" vì vậy mới **được xác minh bằng unit test, chưa bằng một lần chạy thật**.

## M1 — tiêu chí exit (2026-10-21)

| Tiêu chí (09 §2.2) | Kết quả |
|---|---|
| Suite process pass^3 | **Đạt.** `--tag process --runs 3`, plan quota, trên writer Python tại `19d166d` (không có thay đổi tracked; `source_dirty:true` chỉ do các file untracked có từ trước, như `CLAUDE.md` và `.understand-anything/`): `end-refused-without-review`, `review-pass-fixes-bad-citation` và `review-pass-new-plane` đều 3/3, tổng 9/9 run, $2.22. Grader `gate-never-skipped` pass ở mọi run, tức gate in-process có chạy thật trong sandbox. Caveat: `review-pass-fixes-bad-citation` không phân biệt with/without (M0), nên kết quả của nó chỉ cho thấy không có regression, không chứng minh giá trị |
| Regression 0.12 xanh | **Đạt.** 1781 assertion với writer Python, mỗi lần ghi đều kèm selfcheck. Suite cũng chạy lại với writer bash và xanh |
| Suite chạy được cả `plan` lẫn `api` | **Mới một phần.** Đường `plan` đã chạy thật. Đường `api` chỉ được unit test (eval-harness R1–R3, A1–A4), vì Q7 là không dùng API key |

Chuyển sang sau:
- TTL `stale` (04 §1) và digest khi resume chuyển sang M5 (`claudehut status`). Lý do: thêm field vào output `status` sẽ phá hợp đồng chung với writer bash fallback.
- Strangler bước 2 (hook dispatcher sang Python) chưa làm.
- Gỡ writer bash: sau một release.
