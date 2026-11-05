# Optional local model: design and verification plan

Status: proposal. 2026-11-05. Reviewed by the system designer/QA (Codex
gpt-6.1-sol) on the same day; its corrections are folded in below. The 1B
model and one runtime were downloaded and run on a macOS arm64 machine on
2026-11-05; those results are marked **measured**. Everything else is quoted
from a vendor page or measured with `df`/`HEAD`.

## 1. Goal and non-goals

Goal: an **opt-in** small local model inside Butler for cheap, private,
offline-capable *advisory* jobs (classification, summarisation, draft text),
with weights downloaded on demand so the install stays small, and a server
that runs on macOS, Linux and Windows. Embeddings are a separate capability
with its own verified model/API; a causal LM's hidden states are not evidence
of it.

Non-goals: replacing Claude/Codex/OpenCode members; shipping weights in the
installer; claiming quality or speed before we measure it.

Role is **not decided by the user yet**. The recommendation in this document is
"advisory only" (summaries, classification, drafts, no tools or writes). The
alternatives — a read-only tool-calling helper under the normal approval path,
or an embeddings-only service — stay open until the owner chooses. No
capability is granted just because the sidecar exists.

## 2. Verified facts (source, 2026-11-05)

Model — `openbmb/MiniCPM5-2B` and `openbmb/MiniCPM5-2B-GGUF`:

- Apache-2.0 (model card), 2,516,756,480 parameters, standard
  `LlamaForCausalLM`, 42 layers, GQA 16 Q / 2 KV, head dim 128, RoPE theta
  5e6, EOS ids 1 and 130073, 131,072 context.
- GGUF: Q4_K_M 1,561,318,368 B (SHA-256 `893ff0d7…16ea7`), Q8_0
  2,679,710,688 B (`e194ed32…bf1`), F16 5,039,006,688 B. `MiniCPM5-1B-GGUF`
  Q4_K_M is 688,065,920 B (`0d60a8ff…36d`). Hashes are Hugging Face's Xet
  etag/size from `HEAD`; they have **not** been checked against downloaded
  bytes yet.
- llama.cpp `master` carries a dedicated MiniCPM5 chat template and XML
  tool-call parser (`common/chat.cpp`, `common_chat_params_init_minicpm5`).
- Candle's quantized-Llama implementation declares `MAX_SEQ_LEN = 4096`, so an
  advertised 128k context proves nothing about a runtime's real limit.

Runtime A — `mistral.rs` v0.9.5 (2026-10-19), MIT, active:

- Loads GGUF `llama` architecture (MiniCPM5's arch) and can read the chat
  template from GGUF; OpenAI-compatible server; tool calling with grammar
  enforcement.
- Prebuilt binaries: macOS arm64 Metal (50.5 MB), Linux x86_64 CPU (36.3 MB),
  Linux aarch64 CPU (36.2 MB), Windows x86_64 CPU (34.2 MB). **No** Intel-mac
  binary and **no** Windows arm64; Windows CUDA is source-build only. These
  rows select an asset; they do **not** prove the binary runs or that an
  Apple-Silicon Metal build has a working CPU fallback.
- Not "pure Rust" in the strict sense: candle kernels plus CUDA/Metal
  backends, and `tokenizers` defaults pull native (Oniguruma/`esaxx_fast`)
  code. Audit the resolved feature graph, do not trust the crate language.

Runtime B — `candle` 0.11.1: MIT OR Apache-2.0, primitives only. We would own
model code, tokenizer glue, sampling, HTTP, batching and tool parsing. Not a
server.

Runtime C — `llama.cpp` b12121 (MIT): prebuilt for macOS arm64 **and** x64,
Linux x64/arm64, Windows x64/arm64, CUDA/ROCm/Vulkan variants; the MiniCPM5
tool parser already exists in `common/chat.cpp`. C++, not Rust.

Measured on macOS arm64 (2026-11-05), same file `MiniCPM5-1B-Q4_K_M.gguf`:

Candidate backend evidence (not a decision) on the same file:

| Runtime | Load | RSS | First completion | Result |
|---|---|---|---|---|
| mistral.rs 0.9.5 (Metal asset) | 15 s | 1636 MiB | HTTP 500 | `Shape mismatch, got buffer of size 32768 which is compatible with shape [1, 16, 16, 96]` — **not compatible as-is** |
| llama.cpp b12121 (`-c 4096 -ngl 99 --jinja`) | < 1 s to health | 913 MiB | 16 tokens in 0.36 s (~44 tok/s) | works; response carried `reasoning_content` |

Both downloaded archives matched their pinned SHA-256. llama.cpp's model id
is the file path passed to `-m`; the server answers on `/v1/models`. Neither
0.9.5 mistralrs `serve` nor this llama.cpp build exposes an API-key flag, so a
loopback-only port or a Butler-side authenticating proxy is required.

Repository constraints:

- `remuda-core` has an empty dependency list on purpose (pure policy, builds
  for wasm32); `remuda-native` owns host code. Release CI builds Linux x64,
  macOS arm64, Windows x64, Android arm64; Intel mac is not built.
- Remuda's own update path deliberately keeps an HTTP client out of the
  binary: `dist.rs` re-runs the published installer, and downloads are
  checked with `sha256sum`/`shasum` before install (`docs/install.sh`).
- Butler agents are external CLIs spawned into a PTY (`agents/*.lua`); a model
  is only a `--model` string today. There is no local-inference code.

## 3. Where the model server lives

| Option | Install size | CI cost | Platform risk | Verdict |
|---|---|---|---|---|
| A. Link `mistralrs` into `remuda-native` | unmeasured (the 33–51 MB figure is a compressed standalone asset, not a linked-delta) | heavy, per-accelerator matrix | breaks the small-binary property of the daemon | no |
| B. Separate Rust sidecar, downloaded like a tool | 33–51 MB once, shared by all Butlers | one small workflow, reuse release assets | per-OS asset matrix; gaps are explicit | **yes** |
| C. Implement inference on `candle` in-tree | small deps, large code | high | we own every bug | no |
| D. Require user-installed llama.cpp/Ollama | zero | zero | user friction; version drift | fallback only |

Recommendation: **B**, a sidecar process controlled by Butler, not a library
inside the daemon or `core`. It keeps `remuda-core` pure and the daemon small,
matches the existing installer/checksum precedent, and lets the runtime be
replaced without a Remuda release.

The backend choice is **not settled**. Measurement shows llama.cpp serving
1B and 2B with parsed tool calls, while mistral.rs serves 2B only with an
extra `tokenizer.json` and returns MiniCPM5's XML tool call as plain text
(`tool_calls: null`); 1B fails under mistral.rs. So llama.cpp is the leading
*candidate for a tool loop*, not a decision. The owner asked for a Rust serving
framework: Rust 2B is viable for plain text (advisory) with one more pinned
asset, and a tool loop would need a parser or a C++ worker. The architecture
review must record that tradeoff explicitly.

## 4. Lifecycle

- Default **off**. `local_model = true` (or `REMUDA_BUTLER_LOCAL_MODEL=1`)
  enables it; until then no download, no port, no process.
- First use: `remuda butler local-model status|enable|fetch|serve|stop|gc`.
  `fetch` prints bytes, checksum, license and free disk before it starts.
- Disk budget: the measured free space on the development Mac was 36 GiB
  (`df -h`, 2026-11-05) with 92% used; the default 512 MiB reserve keeps a
  download from consuming the last free space.
- Cache: `<cache home>/remuda/butler/models/` — `$XDG_CACHE_HOME` (fallback
  `~/.cache`), `~/Library/Caches`, `%LOCALAPPDATA%` — with an explicit
  override. Consent and config live in the config/data home, never in a cache
  the OS may delete. Runtime: `.../butler/runtime/<version>/`.
- Download to an exclusive `.part`, verify size + SHA-256, then atomic rename;
  never load an unverified file. Resume only against the same immutable
  ETag/Range, and always verify the whole file at the end.
- One server per user, bound to `127.0.0.1` on an ephemeral port with a random
  per-launch bearer token in a 0600 file; CORS, the web UI and non-inference
  endpoints are off. Loopback is not authentication.
- Multiple Butler members share the server through a bounded broker: one
  active request, per-member cancellation ids, 10 s queue timeout, 60 s
  generation timeout, 512 output tokens.
- Idle unload after 5 minutes; RSS ceiling and a default 4096-token context
  (KV cache ≈ 42 KiB/token for this config, ≈168 MiB at 4k versus ≈5.25 GiB
  at 128k before weights and activations). Process limits use cgroups/Job
  objects where available; macOS polling is a soft limit and we say so.
- Update/rollback: runtime version directory is content-addressed; old
  version stays until `gc`. Weights are pinned by hash, not by "latest".
- Offline: an offline mode that prohibits every network path (update checks
  included), not merely one that happens to need two local paths. Manual
  placement (`--model-file`, `--tokenizer-dir`) must pass the same hash check.

## 5. Security and permissions

- Downloads: HTTPS only, host allowlist (huggingface.co, its CDN, github.com),
  every redirect re-checked, no downgrade and no private-network target,
  streaming byte cap even without `Content-Length`, SHA-256 match, atomic
  promotion, reject symlinks/traversal, bounded cache and staging quota.
- Provenance: a manifest shipped with a signed Butler release (or a manifest
  signed by an app-held key). A hash served beside the artifact proves
  integrity, not authenticity; do not claim otherwise.
- Logs and Matrix mail show a redacted URL (query string carries signatures).
- Two processes, not one: a network-capable downloader and an offline
  inference worker. The worker gets a minimal environment, no
  `REMUDA_BUTLER_*` credentials, no workspace writes, a read-only model cache
  and a bounded scratch directory. `HF_HUB_OFFLINE` is configuration, not an
  OS firewall; doctor reports enforcement honestly.
- GGUF, tokenizer and Jinja template parsers are attack surfaces: no pickle,
  no custom model code, no shell installers, no runtime-selected scripts.
- Pins in PR1 are reviewed metadata (model LFS object id + immutable repo
  revision; release asset digest), not a signature. Trust is rooted in the
  authenticated Butler distribution that carries them: an upstream checksum is
  not automatically a trust root, and PR1 must not claim authenticated
  manifest delivery exists. PR2 adds a signed manifest (release key or an
  app-held key) and key rotation.
- The manifest lists `assets[]` (one or several files) with bytes, digest and
  license, so a tokenizer sidecar can be added without a schema change.
- The local model **never** gets tools, shell, file writes, Matrix sends or
  agent spawning. Its output is untrusted text: Butler may show, label or use
  it for a bounded classification, never auto-execute a "tool call" from it.
- It runs as the user but in its own process tree; no inherited Butler token
  and no `REMUDA_BUTLER_*` secret in its environment. "Cannot read mail or
  memory" is a sandbox goal, not something env stripping achieves: it needs
  OS-level allowlists and a test that shows the read fails.
- Prompt injection is a content risk, not a capability risk: the model cannot
  act. The real damage is a wrong or manipulated summary/classification that a
  downstream human or agent then trusts, and data leakage through what a
  member puts into the prompt. Both are shown with a local-model label and
  never become an authorization decision.
- Opt-in, per-machine; `status` and `doctor` state plainly whether it is on,
  what is cached, and whether hashes still match.

## 6. Platform matrix

| OS / arch | Runtime | Acceleration | State |
|---|---|---|---|
| macOS arm64 | mistral.rs 0.9.5 | Metal | asset published; not run here |
| Linux x86_64 | mistral.rs 0.9.5 | CPU | asset published; not run here |
| Linux aarch64 | mistral.rs 0.9.5 | CPU | asset published; not run here |
| Windows x86_64 | mistral.rs 0.9.5 | CPU | asset published; not run here |
| macOS x86_64 | llama.cpp `macos-x64` (prebuilt) | CPU | asset published; not run here |
| Windows arm64 | llama.cpp `win-cpu-arm64` (prebuilt) | CPU | asset published; not run here |
| Linux CUDA | mistral.rs 0.9.5 | CUDA | many assets, source-build for some drivers |
| any + llama.cpp | llama.cpp b12121 | Metal/CPU/CUDA/Vulkan | prebuilt for all four targets incl. mac x64 |

CI: a small workflow that downloads the pinned assets, verifies SHA-256,
starts the server with a tiny model and runs one chat completion per OS. macOS
arm64, Linux x64 and Windows x64 use prebuilt assets. Intel mac and Windows
arm64 require either a source build on a real runner (extra toolchain and
time) or the llama.cpp backend; both stay in scope because the owner requires
all three OSes, and the matrix must say which path CI actually exercised.
GitHub's hosted Intel-mac runner availability and aarch64 Windows Rust
toolchain support are unverified here.

## 7. Verification plan (phased; no large downloads)

P0 — done now: pure policy module `packages/butler/local_model.lua` plus 49
table cases (`tests/lua/butler_local_model_test.lua`). Covers pinned
sizes/hashes, runtime matrix, opt-in, cache paths, traversal refusal, hash
compare, download/repair/space decisions. Runs offline in under a second.

P1 — **done for one path**: the real 1B Q4 model (688 MB, hash matched) was
downloaded and run under mistral.rs (fails) and llama.cpp (works) on macOS
arm64. A random-weight GGUF fixture still belongs in CI: it proves only parse,
stream, EOS, cap and cancellation plumbing, and says **nothing** about
MiniCPM5 compatibility, tokenizer correctness, template output or quality.

P2 — optional, with explicit approval for a ≤300 MB official artifact (or the
688 MB 1B if the owner prefers): check tokenizer special tokens, template
dialect, EOS, and MiniCPM5's XML tool-call format. Same prompts on mistral.rs
and `llama.cpp`. Decision rule: if mistral.rs cannot parse MiniCPM5 tool
calls, report it and let an explicit user policy choose the fallback; never
route automatically, and do not write an untested parser.

P3 — cross-platform: Windows x64 CPU and Linux x64 CPU smoke in CI with the
synthetic fixture (no public model download without separate approval); verify
path handling (`%LOCALAPPDATA%`), process kill on Butler exit, and no orphan
server.

P4 — offline: remove network, place the files by hand, confirm `serve` works
and `fetch` fails with a clear message. Disk pressure: simulate free space
below `bytes + 512 MiB` and confirm refusal, not a partial file.

Fail criteria: any unverified file loaded; any server reachable off-loopback;
RSS above ceiling; orphan process after Butler stops; a tool call executed
without approval.

## 8. Slices for a PR

1. (this one) Pure catalog/policy module + tests + this document. No behavior
   change, no download, no process, no cache mutation. Lua expresses policy;
   hashing, atomicity, locks and process control stay in native code.
2. Downloader in Rust (native or a small crate) reusing the manifest, with
   `--dry-run`, progress, resume, checksum and disk preflight; unit tests with
   an injected HTTP/file seam.
3. Supervisor + `remuda butler local-model` verbs (opt-in gated), loopback
   token, idle unload, doctor line.
4. Backend seam and the llama.cpp adapter, only if P2 shows a fidelity gap.
5. Docs, license notice (Apache-2.0 weights, MIT runtime), uninstall/gc.

## 9. Open questions

- Does a 0.9.5 binary load `MiniCPM5-2B-Q4_K_M.gguf` with an empty HF cache and
  no network (GGUF metadata only)? The docs say `--tok-model-id` may be needed;
  the manifest's `assets[]` keeps room for one or several files either way.
- Does MiniCPM5's XML tool-call format parse in mistral.rs? Its tool parsers
  list llama/qwen/…, not MiniCPM5.
- Windows process containment (Job object) for the sidecar needs a real test,
  and macOS has no cgroup-equivalent hard RSS cap.
- Can mistral.rs build for `x86_64-apple-darwin` and `aarch64-pc-windows-msvc`
  at the pinned release, and does a hosted runner exist for each?
- Should the trusted manifest be signed by the Butler release key, and how is
  that key rotated? (Needed before PR2, not PR1.)
- Is a 2B model useful enough for Butler's cheap jobs, or is 1B the better
  default given the 512 MiB reserve rule?
