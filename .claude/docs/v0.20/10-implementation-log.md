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

Sau review của advisor:
- **Shim fallback.** Nếu `python3` có trên PATH nhưng không chạy được (stub CLT của macOS, venv hỏng, shim trong sandbox), bản cũ làm mọi verb fail với exit 1, và exit 1 bị hiểu là "refused". Shim giờ dùng `CLAUDEHUT_PYTHON` (cùng interpreter với kernel), kiểm tra trước rằng interpreter chạy được và là ≥3.8, nếu không thì chuyển sang bash. Test G18b chạy trên đường mặc định và fail với shim cũ.
- **Version dev `0.20.0-dev.1`.** `run-meta.json` của các eval sau sẽ phân biệt được với 0.12.8 (bản chỉ có K-18).
- **Câu hỏi cho user (Q6):** gate mode mặc định vẫn là `warn` (quyết định từ Track Q), trong khi Q6 chốt bất biến kernel là `block` có override. Mọi case process đều tự set `block`, nên mặc định đang ship chưa từng được đo.

## M2a — pack logic trong một plugin (2026-10-21)

**Nghiên cứu host** (claude-code-guide, docs code.claude.com, 2026-10-21):
- `dependencies` trong `plugin.json` có hỗ trợ semver. Bundle là plugin chỉ có `dependencies` (pattern có trong docs).
- Hai marketplace có thể trỏ hai ref của cùng một repo (stable/canary).
- `bin/` của plugin nằm trên PATH của **Bash tool**.
- `${CLAUDE_PLUGIN_DATA}` giữ nguyên qua các lần update.
- Plugin không được tham chiếu file của plugin khác: path không được thoát khỏi plugin root.
- `claude plugin details` báo "Projected token cost" (always-on).
- `claude plugin eval` chỉ nhận một target.
- Hook của mọi plugin chạy song song; tất cả `additionalContext` đều được ghép, thứ tự không xác định.

**Thực nghiệm:** `bin/` của plugin A **không** có trên PATH của hook của plugin B. Cũng không có thư mục plugin nào trên PATH của hook. Kiểm bằng `claude -p` với `--plugin-dir` ×2, 2.1.306. Vì vậy thiết kế 07 §1.1 (`claudehut-kernel register` gọi qua PATH) không chạy được. Đã sửa design: pack tự ghi registry vào `<plane>/state/packs/`.

| Thiết kế | Đã build | Lệch |
|---|---|---|
| Pack = plugin riêng + `claudehut-pack.json` | **M2a:** 6 manifest trong `packs/`, vẫn ship trong một plugin. Mọi file ship thuộc đúng một pack (test K2) | Tách vật lý là M2b. Làm theo kiểu strangler: hơn 1.700 assertion đang tham chiếu path trong repo |
| K10 `detect` | `claudehut_kernel/packs.py`: `always`, path literal (một lần stat), glob ở root hoặc sâu một cấp, chuỗi con trong build file. Không walk đệ quy | Pack `deliberation` và `domain-ewallet` chưa có manifest, vì chưa có nội dung (M4, phase B) |
| Pack không khớp thì không nạp rule (DOM-1) | init gate theo pack. Repo không Java: 0 rule Java, template plane generic, rule riêng của pack | Tree Java của một repo đã thôi là Java chỉ bị báo stale; chỉ xoá khi có `--retire-inactive` |
| Pack `lang-python-shell` (mới) | 3 rule rút từ bài học của chính repo này: bash 3.2 với mảng rỗng, bẫy `//` của jq, BSD/GNU, `__pycache__`, exit code | — |

**Exit criterion M2 (1/2):** init trên bản copy của repo này (bash + Python) cho ra 0 rule Java (test K5). Tiêu chí (2/2), bundle cài sạch từ marketplace canary, thuộc M2b.

## M2b — phân phối tách (2026-10-21)

**Spike** (CLAUDE_CONFIG_DIR tạm, `~/.claude/plugins` không bị đụng; chỉ chạy model call qua `--plugin-dir`):
- Bundle chỉ khai báo `dependencies`, cài từ directory marketplace: cài **và bật** cả hai dependency. Đúng với cả tên trần lẫn range `~0.20.0-0` (prerelease cần `-0`), không cần git tag.
- `bin/` của plugin khác **có** trên PATH của Bash tool, và `$0` trỏ đúng path của plugin. Pattern locator cho caller là Bash tool vì vậy dùng được.
- `bin/` **không** có trên PATH của hook (đã ghi ở M2a).
- `claude plugin validate --strict` fail vì cảnh báo của directory (README, LICENSE, icon, author). Bản non-strict pass.
- `claude plugin details` báo token cost always-on: plugin `claudehut` khoảng 1.255 tok.
- Marketplace dạng `file://` git không được nhận, nên symlink qua cache copy chưa kiểm được. Chọn vendor file thay cho symlink.

**Kiểm kê tham chiếu chéo giữa các pack** (quét path tĩnh, chưa tính path động như `$TPL/rules` hay `lib/hook-common.sh`):

| Hướng | Số tham chiếu trong code |
|---|---|
| workflow → kernel | 11 |
| kernel → workflow | 7 |
| kernel → java | 4 (hook) |
| kernel ↔ org-summer | 3 + 1 |
| review → kernel/workflow | 4 |

Phần lớn là skill gọi `scripts/` của kernel qua `${CLAUDE_PLUGIN_ROOT}`. Path đó không còn đúng khi skill nằm ở plugin khác.

**Quyết định (decision gate của advisor):** chỉ tách `org-summer`. Lý do phân phối: nội dung nội bộ không được lên marketplace public (Q9). Coupling của nó chỉ có hai điểm, và đã cắt được:
- bước Summer của `maintain.sh` chuyển thành `skills/summer-kb-setup/scripts/kb-maintain.sh`, tự chứa;
- `extract.py` được vendor vào plugin org-summer.

Kernel, workflow, review, java và python-shell vẫn là **một plugin `claudehut` với pack logic**, cho tới khi các tham chiếu trên được cắt. Đó là việc của từng pack sau này, không phải một lần refactor lớn.

| Thiết kế (07 §2-§3) | Đã build |
|---|---|
| Kernel, pack, bundle; hai marketplace | `claudehut-kernel dist --out DIR [--channel stable\|canary]`. Kết quả gồm marketplace public `claudehut[-canary]` (plugin `claudehut`) và marketplace nội bộ `claudehut-internal[-canary]` (`claudehut-org-summer`, cùng bundle `claudehut-backend-jvm` có dependency chéo marketplace). Chỉ ship file tracked. `dist/` đã gitignore |
| Kênh stable/canary | Hậu tố tên marketplace theo channel. Ref thật (branch/tag) cần push, nên chưa làm (ngoài phạm vi phase A) |
| Source vẫn cài được, làm đường rollback (07 §6) | Plugin gốc `claudehut` ở root repo không đổi |

**Exit criterion M2 (2/2):** bundle cài sạch từ các marketplace canary **dạng directory**, cả hai dependency đều được bật, `validate` pass, và registry của user không bị đụng (`dist-tests` D6). Plugin trong dist cũng **chạy được** từ chính root của nó (D4): selftest xanh; init tìm thấy template bên trong plugin (Gradle → có rule Java, Python → không có); `kb-maintain.sh` của org-summer tự cài được KB.

**Marketplace git-hosted chưa kiểm:** CLI từ chối URL `file://`, còn `extraKnownMarketplaces` trong config tạm thì không được nạp. Vì vậy dependency trong dist để tên trần, không dùng range: trên marketplace git, range cần tag, thiếu tag thì plugin bị tắt. Canary bỏ version, để mỗi commit có một version theo SHA. Ghi ở 07 §3.

**Onboarding (spike, config tạm):**
- Chỉ có marketplace nội bộ: bundle vẫn cài nhưng báo `claudehut` sẽ không load; thêm marketplace public sau đó thì dependency được cài bù.
- Plugin gốc cũ và `claudehut@claudehut-canary` bật được cùng lúc dù trùng tên manifest, nên phase B phải gỡ bản cũ trước.
- Registry pack ở plane (07 §1.1): mới thiết kế, chưa build (M5).

**Phát hiện:** 14 file của plugin public vẫn nhắc tên tổ chức nội bộ (`f8a`). Việc scrub chờ user quyết; `dist-tests` in ra số đếm.

Theo mặc định, vì user hoãn quyết định: gate mode giữ `warn`; `claudehut-migrate-plane` giữ là script riêng.

## M3a — detector variation point (2026-10-21)

**Spike MCP** (trước khi thiết kế server):
- Một stdio server khai trong `.mcp.json` của plugin nhận được `CLAUDE_PLUGIN_ROOT`, `CLAUDE_PLUGIN_DATA`, `CLAUDE_PROJECT_DIR`; cwd là project.
- Server ghi được vào `.claudehut/`: nó là một process, không phải file tool, nên không dính protected path.
- Tên tool là `mcp__plugin_<plugin>_<server>__<tool>`.
- Trong `claude plugin eval`, server thật chỉ start khi có `--mocks off`. `--allow-tools 'mcp__*'` bị từ chối, phải liệt kê tên tool cụ thể. Tool gọi được trong sandbox của eval.
- **Vệ sinh spike:** chạy `--plugin-dir` thật sẽ tạo `~/.claude/plugins/data/<name>-inline`. Hai spike của em tạo 2 thư mục rỗng (`probe-b-inline`, `probe-kb-inline`); đã xoá. Thư mục `probeplug-inline` có từ 29/09, không phải của em, nên để nguyên. Từ giờ chạy thử live qua `plugin-eval` (HOME tạm).

| Thiết kế (05 §2) | Đã build | Ghi chú |
|---|---|---|
| Detector thuộc pack | `scripts/index/variation.py` thuộc `lang-java-spring` (kernel giờ liệt kê từng file của `scripts/index/` mà nó sở hữu). Index chỉ chạy detector khi K10 bật pack Java; không bật thì ghi `applicable:false` kèm lý do | Kernel không có khái niệm Spring |
| D1–D4 | multi-impl, registry, factory, conditional | — |
| D5–D7 | **chưa build** | D7 (inject vendor trực tiếp) để M3 sau |
| D8 (mới, không có trong 05) | `contract-param`: tham số endpoint mang tên variant (bank, provider, vendor, partner, channel…) | Thêm cho case `bank-export-follows-param` (rule b: variation do contract quyết định) |
| Pattern miner | `port-selector`: port có ≥2 variant **và** một selector. Trạng thái `candidate` | Chưa có cơ chế confirm của owner |
| `extension-point` (mới) | Base type generic (`RequestHandler<T,R>`, `AbstractService<E,ID,R>`) có ≥2 bean con. Chỉ báo cáo, không phải VP | Rút ra từ mẫu đọc trên service thật |

**Đo lường:**
- **Fixture đã freeze trước khi viết code** (`1d59276`): precision 1.0, recall 1.0, không trúng negative nào, pattern khớp chính xác.
- Scaffold eval zns và bank-export (viết cho mục đích khác): đều tìm thấy.
- **Pass xoá rule** đã bắt được hai lỗi trong cách đo:
  - Ở bản đầu, 10/12 lần xoá làm module lỗi cú pháp, nên lần V3 pass trước đó là vô nghĩa. Đã viết lại rule thành bảng, mỗi entry một dòng xoá độc lập được.
  - Sau đó còn 4 rule xoá đi mà điểm không đổi. 2 rule là thật sự thừa trên fixture: registry chỉ dùng Map và selector chỉ là factory, vì mọi port trong fixture đều có thêm List. Đã thêm vào `additions/`, file tách riêng có ghi rõ, không sửa ground truth đã freeze. Rule "concrete" chuyển thành guard không tag. Kết quả: 15/15 rule đều có trọng số.
- **Mẫu đọc trên service thật** (chỉ đọc, chỉ đếm, không commit code):
  - notification-ms: 5 multi-impl, 3 registry, 2 factory, 1 extension-point; 3 instance pattern (Email/Push provider, SmsProvider).
  - payment-gateway-ms: 4 multi-impl, 4 registry, 1 factory, 1 contract-param (`partnerCode`), 6 extension-point.
  - va-ms: 2 multi-impl, 5 registry.
  - Trước khi có rule extension-point, các base handler generic (69 và 25 subclass) bị tính là VP. Sau rule thì tên của các VP còn lại đều trông như concern variant; **chưa đối chiếu từng file**.

## M3b/M3c — MCP `claudehut-kb` và guide tại thời điểm quyết định (2026-10-21)

| Thiết kế (05 §4, §6) | Đã build | Lệch |
|---|---|---|
| MCP stdio, stdlib, chỉ đọc | `bin/claudehut-kb` → `scripts/kb/claudehut_kb.py`; tool `kb_variation_points`, `kb_patterns`, `kb_brief` | `kb_impact`, `kb_decisions`, `kb_domain`, `kb_record_decision` chưa làm (chờ harvest decision) |
| Ba trạng thái `ok` / `none_found` / `unknown` | Có, kèm lý do và cách sửa; có `stale` và commit đã index; provenance file:line; dữ liệu đã sanitize | **Lệch:** server không bao giờ reindex một index *đã có* (chỉ báo stale). Nhưng một plane *chưa từng* index thì được build một lần ngay lần gọi đầu, có giới hạn. Nếu không, mọi repo mới clone sẽ chỉ trả `unknown` |
| Digest một câu cố định | Có, digest vẫn trong budget 2.500 B | — |
| Budget always-on (K-15) | Instructions + schema khoảng 2.066 ký tự (~520 tok), có test ≤2.600 | `claude plugin details` không tính MCP |
| Guide tại thời điểm quyết định (mới) | UserPromptSubmit cho prompt kiểu "thêm provider/vendor/bank…"; PreToolUse cho một class production *mới* có tên giống variant hoặc gọi hệ thống ngoài (`advise-variant.sh`, pack Java). Mỗi loại một dòng, tối đa một lần mỗi session | Tạm thay cho phần deliberation pack ở M4 |

**Eval** (decision suite, plan quota, `--mocks off`, kb tool được cấp theo tên):

| Lần chạy | zns | bank-export | single-client (guard) | vendor-neutral |
|---|---|---|---|---|
| M0, 0.12.7 with | 0.00 | 0.50 | 1.00 | 0.83 |
| M3b, chỉ có tool | 0.00 | 0.67 | 1.00 | 1.00 |
| M3c, tool + hint (run by0wegcat, before advise-variant) | 0.00 | 1.00 | 1.00 | 0.83 |
| **0129197, toàn bộ M3** (tool + hint + advisory, plan, `--mocks off`) | **0.00** | **1.00** (3/3) | **1.00** (3/3) | 0.83 |

- **Kết quả đo trên commit cuối `0129197`** (`evals/results/plugin-eval/2026-10-21T15-45-57Z`, `signals.json`, đọc bằng `evals/plugin-eval-signals.py` từ session log; `source_dirty:true` chỉ do file untracked có từ trước):
  - kb tool được gọi ở 3/21 run (14%): 2 run bank-export, 1 run vendor-neutral.
  - Hint UserPromptSubmit được inject ở 9/9 run của zns, bank-export và vendor-neutral, và 0/3 ở guard single-client (đúng như mong đợi).
  - Advisory lúc Write được inject ở 3/3 run zns.
  - Suite process vẫn pass^3 (9/9) khi đã bật MCP server và hook mới.
  - bank-export 3/3 trong khi hint đã được inject ở cả 3 run. Kết quả nhất quán với việc hint có giúp, nhưng chưa có arm đối chứng nên chưa chứng minh được nguyên nhân.
- Số lần gọi kb tool ở các run trước: 2/12 ở M3b (cả hai trả `unknown` vì eval không có index); 0/12 ở M3c (by0wegcat).
- Tiêu chí M3 "tool được gọi ở ≥90% case T1+" **không đạt**. Tier T1+ cũng chưa tồn tại trước M4.
- Ở run `0129197`, cả 3 session log của zns đều cho thấy hai guide **đến được model**: hint UserPromptSubmit nêu `SmsProvider` và advisory lúc Write nêu `SmsProviderFactory`. Agent tự đọc file của SmsProvider/Factory, nhưng vẫn làm theo prompt ("like PushService", "minimal change") và chỉ viết `ZnsService` một lần.
- Vì vậy thiếu dữ kiện không phải lý do. Agent thấy đủ thông tin mà vẫn chọn sai. Đây là đúng việc của deliberation pack (M4): tier, rule PV, design-reviewer.
- bank-export lên 3/3, nhưng với 3 run thì chưa tách được khỏi nhiễu.
- **Sửa một kết luận sai của chính em:** em từng ghi "UserPromptSubmit không fire dưới `-p`". Thực ra nó có fire. `trace.jsonl` của eval chỉ ghi event hook SessionStart; context của hook nằm trong session log `config/projects/*.jsonl`.
- Hook latency: `hook-bench` báo cáo, không gate.

### Sửa lỗi sau review của advisor (`0129197`)

- **Lỗi chặn:** `do_update` trả "up to date" trước khi kịp chạy detector. Vì vậy mọi plane index trước `cf3a1f1`, tức mọi service thật, sẽ không bao giờ có `variation.json`, và kb tool, hint, advisory đều im lặng. Fixture của em đều là repo mới nên không bắt được.
  - Đã sửa: bump `TOOL_VERSION`, coi "variation.json missing" là một lý do để rebuild, `hc_index_first_build` kiểm tra `variation.json`.
  - Có test hồi quy (variation-tests V4, kb-tests B7).
- Claim build hết hạn sau 10 phút, và sweep đã nhận ra file claim này.
- **Thời gian (đo trên bản copy trong scratchpad, không index vào repo thật):**
  - Build full lần đầu, 300 file Java: 0,75 s, nằm trong timeout 5 s của hook.
  - Build full payment-gateway-ms (1.221 file): 3,7 s, nên chạy detached.
  - Update incremental của cùng service: 3,0 s khi detector parse lại toàn bộ. Sau khi thêm cache parse theo từng file (key là sha nội dung): 1,0 s.
- Dọn dẹp: đã xoá 46 thư mục `--keep-temp` (`/private/tmp/e-*`) của các run eval của em, kể cả phần `sealed/` (sau khi chmod).

## M3d + M4 — owner confirm pattern, deliberation pack (2026-10-22)

**M3d:**
- `claudehut-index patterns confirm|reject|deprecate <id> --by <owner> [--note]` ghi vào `<plane>/patterns.json` (ai, khi nào, vì sao, commit đã index).
- Trong `kb_patterns`, hint và advisory: instance đã confirm đứng trước, instance đã reject không bao giờ hiện lại.

**M4a** (`9a2833b`):
- Pack `deliberation` gồm:
  - skill `claudehut:deliberate`: tier, probe bằng kb, rule PV hai chiều (a)/(b)/(c), các option, `decision.md` theo dạng MADR;
  - agent `claudehut-design-reviewer` (R1–R6);
  - `set-tier` ở cả hai writer;
  - `minimalism.md` mang rule hai chiều.
- **Đo** (`2026-10-21T16-44-04Z`, with/without): bank-export +0.50 (1.00 so với 0.50), các case khác Δ 0.
- Trong 24 run: **0 lần gọi Skill**, 0 lần gọi kb. Vì vậy con số này đo hint của M3c, chưa đo pack.

**Chẩn đoán (theo advisor):**
- Trigger-eval chỉ dựa vào description: recall 12/24, và poach case single-client 3/3.
- Case chẩn đoán `diagnostic/zns-forced-deliberate` (zns kèm câu "Use claudehut:deliberate first", tag riêng, không tính điểm): **3/3**, có gọi kb ở 3/3.
- Kết luận: **loop chạy đúng khi được kích hoạt; chỗ hỏng là trigger.**

**M4b** (`1ace782`):
- Theo đúng a2 §2 (trigger tất định chạy trước): khi prompt có dạng "thêm một variant" và kb tìm thấy một họ variant, hint giờ nêu rõ "Deliberation trigger (T2)" và yêu cầu gọi `claudehut:deliberate`. Advisory lúc Write cũng vậy.
- Description của skill được viết sắc hơn (trigger recall lên 14/24).
- Thêm guard **should-not mới** `decision/internal-client-beside-family`: vẫn là một client nội bộ duy nhất, nhưng cạnh một họ SMS đang hoạt động, để hint chắc chắn fire. Thêm theo point 5 của advisor, vì guard single-client cũ không thể fail trước câu chữ mới.

**Exit M4, đo trên `1ace782`** (`2026-10-21T17-15-57Z`, `--ablation with-without`, 3 run mỗi arm, plan quota, $5,38):

| Case | Loại | with | without | Δ |
|---|---|---|---|---|
| zns-follows-provider-pattern | should-abstract | 0.67 | 0.00 | +0.67 |
| bank-export-follows-param | should-abstract | 1.00 | 0.50 | +0.50 |
| vendor-neutral-columns | should-abstract (vendor leak) | 1.00 | 0.83 | +0.17 |
| single-client-no-abstraction | should-not | 1.00 | 1.00 | 0 |
| internal-client-beside-family | should-not (hint có fire) | 1.00 | 1.00 | 0 |

- **should-abstract 8/9 (89% ≥ 80%), should-not 6/6 (100% ≥ 90%): tiêu chí exit M4 đạt ở n=3.** Với n=3, mỗi run làm điểm một case lệch 0,33 nên khoảng tin cậy còn rộng. Cần lặp lại trên n lớn hơn trước khi tin hẳn.
- Signals:
  - Skill `deliberate` được gọi 1/15 run;
  - kb tool 0/15;
  - hint ở 12/15 (không có ở single-client, đúng như mong đợi);
  - advisory 2/15.
- Vậy cải thiện đến từ **nội dung hint**: nó nêu họ variant, rule (c) và trigger T2. Skill hay kb tool gần như không được gọi. Bản thân loop deliberate mới chỉ được chứng minh ở case chẩn đoán.
- Chưa làm:
  - invariant `tier ≥ T2 ⇒ decision.md trước set-plan`;
  - route rubric đẩy "tích hợp mới" lên tối thiểu light;
  - sensor vendor-leak (a2 §2);
  - tournament T3.

### Kiểm tra sau review của advisor (M4)

| Kiểm tra | Kết quả |
|---|---|
| Suite process trên commit hiện tại (`4aadee0`) | 8/9. `review-pass-new-plane`: 1/3 run thử `--override` với lý do tự bịa ở check bằng chứng test. Override không áp dụng cho check đó nên vẫn bị refuse, và báo cáo cuối vẫn trung thực. Chạy lại case này: lại 1/3. Đã sửa ở `fix(state)`: thông điệp refuse giờ nói rõ `--override` không áp dụng cho check này. Chạy lại sau khi sửa: **3/3**. Vì n=3 nên chưa coi là đã sửa xong hẳn |
| Chẩn đoán đối xứng `diagnostic/guard-forced-deliberate` (guard + ép chạy skill) | **3/3**. Skill chạy 3/3, gọi kb 2/3, và đều không trừu tượng hoá client nội bộ. Loop không đẩy sai theo chiều nguy hiểm |
| Case held-out `decision/payout-channel-follows-strategy` (freeze ở `4aadee0`, trước mọi lần chạy) | with 1.00, without 1.00, Δ 0. Case **không phân biệt** được: không có plugin thì agent cũng tự theo strategy, có lẽ vì router nằm ngay cạnh. Không thấy hại, nhưng cũng không chứng minh được gain tổng quát. **Con số 8/9 ở trên đo trên chính các case mà trigger đã được chỉnh theo** |
| `~/.claude/plugins/data` | Không có thư mục mới. `claudehut-inline` (27/05), `devco-agent-skills-inline` (24/04) và `probeplug-inline` (29/09) đều có từ trước. Model arm của trigger-eval gọi `claude -p` với config thường và không nạp plugin này |
| Độ chính xác của keyword gate (miễn phí) | Trên `deliberate.json`: fire 7/8 positive, 0/8 negative. Nhưng trên guard thật ("add … through the party client") gate có fire, và câu hint "this request adds a variant" khi đó là sai. Cả hai guard vẫn 1.00 nên chưa sửa câu chữ |

Vấn đề chính sách còn mở: skill bảo agent theo pattern ngay cả khi user nói rõ "like X". Ở headless, đó là hành vi a2 đã duyệt. Trong session tương tác, hỏi một AskUserQuestion có lẽ hợp lý hơn. Chờ user quyết.

## M4c–M4e — invariant tier/decision, route rubric, sensor vendor-leak (2026-10-22)

**M4c: invariant pack `plan.tier-needs-decision`.**
- Pack `deliberation` khai báo trong manifest: `{"id": "plan.tier-needs-decision", "at": "set-plan", "mode": "warn"}`. Kernel kiểm ở `set-plan` qua `gates.run("plan")`, ở cả hai writer. Bash chỉ gọi kernel khi tier là T2/T3, nên plan khác không tốn thêm một lần start python.
- Điều kiện: pack đang active, tier T2/T3, `<task>/decision.md` không tồn tại. Chỉ kiểm file có tồn tại; "DEC có Confirmation" là invariant khác, chưa làm.
- **Mode riêng cho invariant pack (Q6):** `topology.json .gates.pack_mode` > `mode` trong manifest > `warn`. `CLAUDEHUT_GATE_MODE` và `.gates.mode` (công tắc của kernel) không nâng nó lên block (GP1, GP12).
- Dòng warn giờ ghi "recorded; the transition proceeds, no --override needed" và nêu tên skill, vì agent từng bịa `--override` khi dòng gate trông giống refuse.
- Test GP1–GP12 trong `verify-tests` chạy dưới cả hai writer. Mutation 5: 4 bị giết. Mutant sống sót (bỏ lọc `at`) tương đương với manifest hiện tại, vì chỉ có một invariant.
- Selftest có canary `gate plan warns a T2 plan without decision.md`.

**M4d: route rubric.** Hàng `light` trong `claudehut-workflow/SKILL.md` thêm "a new vendor integration". Digest không đổi (chỉ còn 9 B), SKILL.md 6684/6700 B.

**M4e: sensor `claudehut-verify vendor-leak`** (advisory, exit 1 khi có finding như các lệnh verify khác).
- **Nguồn vendor**, không hard-code (plugin public không ship tên vendor):
  - danh sách của owner `<plane>/vendors.txt`, hoặc `vendors.txt` trong pack đang active;
  - suy từ `variation.json`: variant của họ port trông giống external (Provider, Client, Sender, Gateway, Adapter, Exporter, Connector, Notifier, Integration) trừ tên port, ví dụ `CmcSmsProvider − SmsProvider → cmc`. Có stop-list (`noop`, `static`, `default`, các danh từ concern…). Strategy/Handler không được suy.
- **Chỗ quét:**
  - enum constant, `@Column`/`@JoinColumn`/`@Table` name;
  - field của class entity hoặc `@ConfigurationProperties`;
  - prefix `@ConfigurationProperties`;
  - segment package nằm trong domain/model/entity/core;
  - SQL `ADD COLUMN`, `CREATE TABLE` (tên bảng và cột).
- **Không quét:**
  - thư mục variant của họ đã suy (adapter);
  - test;
  - YAML, vì `providers.<vendor>.*` là vendor ở dạng data, đúng chỗ.
- **Đo:**
  - Fixture `evals/fixtures/vendor-leak` (8 positive, 7 file negative) freeze ở `d593625`, trước code: **precision 1.0, recall 1.0 ngay lần chạy đầu**. Fixture và code cùng một người viết, nên chưa phải bằng chứng độc lập.
  - Fixture `variation` (viết cho detector, không cho sensor này): suy đúng 7 vendor, 0 finding.
- Mutation 9/9 bị giết. 3 mutant đầu sống sót (lọc package trung lập, giới hạn field theo class data, finding bảng) nên thêm V10–V12; ba test này ghi rõ là viết sau code.
- Có canary selftest. Skill `deliberate` và rubric R3 của design-reviewer gọi sensor sau khi viết code.
- Chưa nối vào gate hay hook. Chưa chạy trên service thật, vì service thật cần `variation.json` mà phase A không index vào repo thật.

**Sửa roadmap:** tournament T3 thuộc **M6** (09 §2.2), không phải M4. Ghi nhầm ở mục M4 phía trên.
