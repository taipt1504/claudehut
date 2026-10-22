# 07 — Packs, phân phối, vòng đời

Component K10 và mô hình phân phối. Vấn đề neo: DOM-1, DOM-2, LIF-1..5, MAO-2, CMP-2, CMP-3, HIL-3.

## 1. Pack là gì

Pack là **một Claude Code plugin** (dùng nguyên cơ chế host) phụ thuộc `claudehut-kernel` theo semver. Pack có thêm `claudehut-pack.json` để khai báo extension cho kernel.

```json
{
  "pack": "lang-java-spring",
  "version": "0.20.0",
  "kernel": "~0.20",
  "detect": {"any": ["build.gradle", "pom.xml"], "deps": ["org.springframework.boot"]},
  "guides": [{"skill": "spring-conventions", "trigger": "paths", "paths": ["src/main/java/**"], "budget_tokens": 1200}],
  "sensors": ["archunit.layering", "archunit.vendor-fence"],
  "knowledge": {"extractors": ["java-components", "spring-beans", "variation-detectors"]},
  "invariants": [],
  "evals": ["evals/java-spring/*.json"]
}
```

| Khả năng | Cơ chế host dùng |
|---|---|
| Skill, agent, hook, MCP, LSP của pack | thành phần plugin chuẩn |
| Phụ thuộc kernel và pack khác | `dependencies` có semver; ràng buộc phải giao nhau, xung đột thì cài thất bại |
| Kích hoạt theo stack | `detect` do K10 đánh giá; pack không khớp thì không nạp guide hay rule (CTX-2, DOM-1) |
| Ngân sách always-on | K10 cộng budget của pack đang kích hoạt; CI chặn release nếu vượt (đo bằng `claude plugin details`) |

### 1.1 Khám phá pack (registry)

Kernel **không** đọc file nội bộ của host (`installed_plugins.json`, cấu trúc cache) vì chúng có thể đổi bất kỳ lúc nào. Thay vào đó:
- ~~Mỗi pack ship một hook `SessionStart` gọi `claudehut-kernel register` qua PATH.~~ **Đã kiểm thực nghiệm (Claude Code 2.1.306, 2026-10-21): `bin/` của plugin KHÔNG có trên PATH của hook.** Docs chỉ hứa điều này cho Bash tool. Hook của plugin B gọi `probe-a-tool` (nằm trong `bin/` của plugin A) thì nhận `NOT FOUND`, và trong PATH của hook không có thư mục plugin nào. Plugin cũng không được đọc file của plugin khác: path không được thoát khỏi plugin root.
- **Thiết kế thay thế:** mỗi pack ship một hook `SessionStart` nhỏ, tự chứa, không gọi kernel. Hook này ghi `{pack, version, root: ${CLAUDE_PLUGIN_ROOT}, manifest_hash}` vào `<plane>/state/packs/<pack>.json` của project; plane `.claudehut/` ghi được, theo K-18. Kernel đọc registry từ plane. Sensor dùng `{pack_root}` lấy từ đây. **Trạng thái: đã build ở M5a.** Hook là `scripts/register-packs.sh` (vendored vào plugin `claudehut-org-summer`). Kernel (`packs.load_all`) đọc registry để lấy pack ngoại, `vendors.txt` và invariant. Trạng thái mỗi pack là `registered`, `unregistered`, `foreign` hoặc `stale` (root mất hoặc manifest đổi), hiện trong `claudehut-kernel packs` và `claudehut status`. Test D7 kiểm trên bản dist: kernel public thấy `org-summer` là `foreign`.
- Pack không đăng ký, ví dụ hook bị tắt, sẽ hiện trong `claudehut status` là `unregistered`, không bị bỏ qua âm thầm (VER-3).

## 2. Danh mục pack đề xuất

| Pack | Loại | Nội dung | Thay cho (0.12) |
|---|---|---|---|
| `claudehut-kernel` | lõi | K1–K11, `claudehut-state`, `claudehut-verify`, MCP `claudehut-kb`, hook advisory | toàn bộ `bin/`, `scripts/` lõi |
| `workflow-standard` | workflow | phase, template spec/plan/review, AC confirm, router rubric | `skills/*` phase |
| `review` | quality | lane, review-pack, reviewer roster | `agents/*reviewer*` |
| `deliberation` | quality | tier, probe, PV rule, MADR, design-reviewer, tournament | mới |
| `lang-java-spring` | stack | extractor, detector D1–D7, ArchUnit sensor, rule Spring | 58 rule template, extractor Spring trong lõi |
| `lang-python-shell` | stack | extractor, `shellcheck`, `pytest` | mới (DOM-1) |
| `topology-jvm-service`, `topology-kafka-consumer` | template | bộ guide và sensor theo topology (harness template) | mới |
| `org-summer` | tổ chức | Summer KB, skill `using-*-summer`, checker theo version | Summer KB trong lõi; 51 bản copy skill, 16 bản copy checker |
| `domain-ewallet` | domain | domain facts, template campaign (DR, feature flag), aliases hub | prompt copy ở 14 repo |
| Bundle `backend-jvm` | bundle | chỉ `dependencies`: kernel, workflow, review, deliberation, lang-java-spring, topology-jvm-service | — |

**Trạng thái M2 (2026-10-21):** cả 6 pack đều đã có manifest, và K10 đã gate `claudehut-init` theo pack. Về mặt vật lý, mới chỉ `org-summer` được tách thành plugin riêng `claudehut-org-summer` trong marketplace nội bộ, cùng bundle `claudehut-backend-jvm`. Các pack còn lại vẫn nằm chung plugin `claudehut`, vì còn tham chiếu file của nhau: một plugin không đọc được file ngoài root của nó, và `bin/` của plugin khác không có trên PATH của hook. Mỗi pack sẽ tách ra khi các tham chiếu của nó đã được cắt ([10](10-implementation-log.md) M2b).

Skill hoặc checker của tổ chức (ví dụ `using-dr-summer`) **không còn copy vào repo**. Repo bật pack `org-summer` và skill được gọi theo namespace `org-summer:using-dr-summer` (LIF-2).

## 3. Phân phối và release

| Vấn đề | Cơ chế |
|---|---|
| Marketplace (Q9) | `claudehut` cho kernel và pack chung; `f8a-internal` cho `org-summer`, `domain-ewallet` |
| Kênh phát hành | Mỗi marketplace có hai bản `-stable` và `-canary` trỏ hai ref (host không có khái niệm channel). Pilot repo dùng canary |
| Phạm vi cài | Cài ở **user** hoặc **managed** scope. Repo chỉ khai báo bundle trong `.claude/settings.json` (`enabledPlugins`). Không còn 21 bản cài project-scope (LIF-1) |
| Cập nhật | `autoUpdate` cho marketplace. `claudehut status` cảnh báo session đang chạy bản cũ hơn bản đã cài |
| Tag và version | `claude plugin tag`; version chỉ đặt ở `plugin.json`. **M2b:** `stable` đóng dấu version (user bị ghim tới lần bump kế tiếp) và từ chối build khi cây dirty. `canary` bỏ version, nên marketplace git sẽ đánh version theo SHA của từng commit. Dependency để tên trần, vì range chỉ resolve được qua git tag `<plugin>--v<ver>`; plugin relative-path không có tag khớp thì cài xong vẫn bị tắt. Range sẽ quay lại khi có bước tag |
| Onboarding | Thêm **cả hai** marketplace, public trước. Nếu chỉ có marketplace nội bộ, bundle vẫn cài nhưng báo `claudehut` sẽ không load; thêm marketplace public sau đó thì dependency còn thiếu được cài bù. Plugin gốc cũ `claudehut@claudehut-marketplace` trùng tên manifest với `claudehut` mới, và cả hai đều bật được. Host chỉ chạy hook của một bản, nên migrate ở phase B phải gỡ bản cũ trước |
| Đổi tên | map `renames` append-only |
| Tổ chức | mẫu managed settings: `extraKnownMarketplaces`, `enabledPlugins`; khoá chặt (`strictKnownMarketplaces`…) chỉ khi governance yêu cầu |

## 4. Cấu hình project và profile

- `claudehut-init` làm ba việc:
  - phát hiện stack;
  - đề xuất bundle;
  - sinh profile (autonomy, sandbox, advisor). Advisor mặc định là `opus` (Q5).
- Mọi thay đổi vào `settings.json` đều **merge có cấu trúc**: giữ nguyên format và field lạ, có diff, user đồng ý mới ghi (LIF-3). Bản ghi cũ được lưu để rollback.
- File sinh ra giữ ngoài tree được track khi có thể (`.claude/claudehut/` có `.gitignore` riêng). File cần chia sẻ thì commit có chủ đích (ENV-3).
- AGENTS.md: nếu repo dùng AGENTS.md, init tạo CLAUDE.md một dòng `@AGENTS.md` thay vì nhân đôi nội dung.

## 5. Cùng tồn tại với plugin khác (CMP)

| Tình huống | Chính sách |
|---|---|
| Plugin workflow khác (superpowers, spec-kit) đang bật | K5 phát hiện. Hỏi user chọn workflow chủ; pack `workflow-standard` tự lùi về vai knowledge, quality |
| Plugin cung cấp skill hữu ích (ví dụ `ewallet-query-audit`, understand-anything) | K10 liệt kê làm guide khả dụng; pack có thể tham chiếu theo tên |
| Hook của user/plugin khác rewrite input (rtk), inject style (caveman) | K5 phát hiện và thích nghi ([04 §5.1](04-kernel-control.md)); không chặn plugin khác |
| Xung đột tên hoặc event | Tool có namespace riêng; ClaudeHut không đăng ký hook chặn |

## 6. Migration 0.12.6 → 0.20

Chạy theo kiểu strangler, có dry-run và apply, giống M7 của 0.12:

1. **0.12.x quick-wins** ([09 §3](09-adr-roadmap.md)), trên cấu trúc hiện tại.
2. Tách lõi thành `claudehut-kernel`. Plugin `claudehut` cũ thành bundle tương thích, phụ thuộc kernel + workflow-standard + review + lang-java-spring.
3. Tách `org-summer` và `domain-ewallet`. `claudehut-migrate` gỡ các bản copy skill, checker, prompt ở repo, sau khi so sánh nội dung với bản canonical (copy lệch thì báo, không xoá).
4. Chuyển cài đặt sang user/managed scope. Gỡ 21 bản cài project-scope.
5. Task cũ: `task.json` schema 2 được chuyển thành `events.jsonl` (sự kiện tổng hợp) cộng projection. Task đã `done` không bị kiểm lại bằng bất biến.
6. Rollback: bundle cũ vẫn có ở marketplace stable cho tới khi pilot đạt exit criteria.
