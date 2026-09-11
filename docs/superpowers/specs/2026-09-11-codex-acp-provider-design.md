# Codex ACP Provider Design

## Purpose

OpenClacky currently treats every configured model as a remote LLM API identified by a model name, base URL, and API key. Codex is different: it is a local agent runtime with its own authentication, conversation identity, approval flow, tools, and streamed events. The client must nevertheless present Codex in the same provider picker used for existing model cards, both during first-run setup and later in Settings.

This design adds a protocol-neutral agent-runtime extension point to core and ships Codex as a bundled extension implemented through Agent Client Protocol (ACP). Existing API-key providers and saved sessions remain compatible.

This is a bundled, default-enabled client extension rather than a separately installed marketplace extension. It is loaded early enough to contribute its provider descriptor before first-run onboarding, so `Codex (ChatGPT)` appears directly in the existing model configuration provider dropdown. Core owns only the generic provider/runtime contracts; the bundled extension owns every Codex-specific behavior.

## Decision Summary

The first implementation uses this chain:

```text
OpenClacky Web UI
  -> OpenClacky session/runtime SPI
  -> bundled Codex provider extension
  -> codex-acp 1.11.0 over stdio NDJSON
  -> Codex CLI `app-server` (verified with 0.153.4)
  -> ChatGPT account
```

The key decisions are:

- Use ACP instead of implementing the Codex App Server protocol directly. `codex-acp` already translates authentication, model configuration, session operations, approvals, tool events, and streamed output into a provider-neutral protocol.
- Add a thin core runtime SPI and provider contribution type. Do not implement the feature with `contributes.patches` monkey-patches.
- Put Codex-specific startup, authentication, home-directory preparation, event mapping, and diagnostics in a bundled default extension.
- Use an application-managed `CODEX_HOME` for sessions, state databases, caches, and logs. Reuse an existing file-backed Codex login only through a validated `auth.json` symlink; do not reuse the whole user Codex home.
- Start with codex-acp's safer `read-only` mode, then map each OpenClacky permission mode to an advertised adapter mode after session creation. Never select `agent-full-access` automatically.
- Pin `@agentclientprotocol/codex-acp` to `1.11.0`. Its declared Codex dependency baseline is `^0.153.4`, and the verified combination uses Codex 0.153.4. The prototype may launch an installed executable or pinned `npx`; production packaging must lock the full dependency tree.

`codex-acp` is itself an adapter that starts Codex App Server. ACP therefore does not bypass the official Codex runtime; it gives OpenClacky a stable, reusable client-side contract and avoids duplicating Codex-specific event translation in Ruby. OpenAI recommends App Server as the default for a Codex-only deep integration because it preserves every provider-specific feature. OpenClacky deliberately chooses ACP because its product boundary is a provider/agent picker that can later host other ACP agents. Codex-specific `_meta` fields remain available to the extension so the design does not force every agent into only the lowest common subset.

## User Experience

### First-run setup

The existing provider dropdown gains a `Codex (ChatGPT)` entry. Its descriptor marks it as an agent runtime and as not requiring a base URL or API key.

When selected:

- Base URL, API key, API format, and provider-key help are hidden.
- Model, Base URL, and API Key fields are hidden. The panel explains that Codex will report its actual model when the session starts.
- A connection panel shows one of `Connected`, `Not connected`, `Starting`, or an actionable dependency/version error.
- If a reusable Codex login is already available, the user can continue without signing in again.
- Otherwise, `Connect with ChatGPT` starts ACP's `chat-gpt` authentication method, opens the system browser, and the page polls status until the account is connected.
- `Continue` saves a credentialless runtime card and follows the existing onboarding completion flow without sending the OpenClacky-specific `/onboard` skill command to Codex.

The OpenClacky AI Keys device-login card remains unchanged. Codex appears anywhere the normal provider list is rendered; it is not a separate hidden onboarding product path.

### Settings

The Add Model dialog uses the same provider descriptor behavior. Selecting Codex hides API-key-only fields, shows connection status, and saves a runtime-backed model card after a runtime health check instead of calling the OpenAI-compatible model tester.

Codex model cards show the provider name, `Codex default` until a session reports its effective model, connection state, and a `Test` action that checks ACP process readiness plus authentication. Removing the card removes only OpenClacky's model configuration. It does not log out the shared Codex account or delete the source `~/.codex/auth.json`.

### Session behavior

Creating a session with a Codex card creates an ACP session in that workspace. Prompts, image attachments, cancellation, streamed assistant output, tool activity, usage, and permission requests are mapped into the existing OpenClacky session UI. The sidebar and session URL remain owned by OpenClacky.

Features that require internals unique to `Clacky::Agent` are capability-gated for ACP sessions. The first version does not expose Time Machine branching, OpenClacky sub-model overlays, OpenClacky idle compression, or OpenClacky goal loops on Codex sessions. Unsupported endpoints return a structured `422` response instead of failing with a missing Ruby method.

## Core Extension Boundary

### Provider contributions

`ext.yml` gains a `contributes.providers` array. A provider descriptor is presentation and configuration metadata; it does not contain credentials or execute code.

The bundled Codex descriptor has this conceptual shape:

```yaml
contributes:
  providers:
    - id: codex
      name: Codex (ChatGPT)
      name_key: provider.name.codex
      runtime_id: codex
      auth_mode: runtime
      credential_fields: []
      dynamic_models: session
      display_model: Codex default
      capabilities:
        vision: true
```

`Clacky::ProviderRegistry` merges the existing built-in `Providers::PRESETS` with enabled extension descriptors. Extension IDs cannot silently override a built-in provider or another winning descriptor; collisions are verifier errors. `GET /api/providers` projects the combined registry and preserves the current response fields for old UI clients.

### Runtime contributions

`ext.yml` also gains `contributes.agent_runtimes`:

```yaml
contributes:
  agent_runtimes:
    - id: codex
      adapter: runtime.rb
      class: Clacky::Extensions::Codex::Runtime
```

The loader resolves and validates the adapter path inside the extension directory. `Clacky::AgentRuntimeRegistry` lazily requires the adapter, resolves the declared class, and builds a runtime session only when a selected model card contains the matching `runtime_id`.

Runtime extensions are process-lifetime components in version 1. Enabling, disabling, or upgrading an `agent_runtimes` contribution requires an OpenClacky restart; Ruby classes are not hot-unloaded.

### Runtime session contract

Core provides a host-session facade that owns OpenClacky metadata, pending-input FIFO, normalized transcript, history replay, task counters, and persistence. A provider runtime remains deliberately small:

- `capabilities` describes protocol cancel, image input, and optional provider features;
- `run(input, generation:)` blocks until the provider's true turn-completion barrier;
- `cancel(reason:)` performs cooperative protocol cancellation;
- `dump_state` returns a secret-free provider resume reference;
- `close` releases provider-owned session resources.

The runtime factory receives a context containing session ID, UI sink, absolute working directory, permission mode, and optional persisted runtime state. `RuntimeInput` contains the existing content, files, reference context, display text, and timestamp fields; the provider converts it into its wire format.

The existing `Clacky::Agent` remains the default execution object and is not rewritten around ACP. For compatibility, the server continues to keep either `Clacky::Agent` or the host runtime-session facade in its existing agent slot. The facade supplies the common metadata/history/queue methods current registry code expects, while the provider SPI stays limited to turn execution. Agent-specific call sites check declared capabilities before invoking optional behavior.

## Model Configuration Contract

A saved Codex runtime card contains no secret, generated ID, fake endpoint, or hard-coded Codex model:

```yaml
runtime_models:
  - provider_id: codex
    type: default
    runtime_id: codex
    display_model: Codex default
    remark: ""
```

Runtime cards are persisted under a separate top-level `runtime_models` array in `config.yml`; API-backed cards remain under the existing `models` key. New OpenClacky versions combine both arrays in memory and generate their stable runtime IDs exactly as they do today. Older versions ignore the unknown `runtime_models` key instead of treating a credentialless card as an API model, which makes downgrade behavior safe.

`AgentConfig#models_configured?` accepts a card with a known runtime ID even when `api_key`, `base_url`, and `model` are empty. API-backed cards keep the existing validation rules. Create and update endpoints derive `runtime_id` from the selected provider descriptor; the browser cannot register an arbitrary Ruby runtime class.

Runtime-backed cards are never passed to `Clacky::Client`. Session construction selects the runtime factory before any API client is built.

## ACP Client and Lifecycle

### Transport

The generic Ruby ACP client uses JSON-RPC 2.0 objects separated by newlines on stdio. It never uses shell parsing. Process creation uses an argv array through `Open3.popen3`, a fixed working directory, and a controlled environment.

One managed ACP connection is shared by Codex runtime sessions in an OpenClacky server process. It owns:

- monotonically increasing request IDs;
- a mutex-protected pending-request table;
- a dedicated stdout reader thread;
- serialized stdin writes;
- bounded stderr capture with secret redaction;
- notification routing by ACP `sessionId`;
- inbound client-request dispatch, initially `session/request_permission` only;
- process-exit propagation to all waiting requests and live sessions;
- restart on the next operation after an unexpected exit, without replaying an in-flight turn.

OpenClacky advertises ACP protocol version 1 and only capabilities it implements. It advertises no filesystem or terminal client methods, so the agent executes through Codex App Server rather than asking OpenClacky to act as a terminal proxy.

### Startup and authentication

On first use the Codex extension:

1. prepares the managed home;
2. resolves a pinned-compatible launcher;
3. starts `codex-acp` with `CODEX_HOME` set to the managed home and `INITIAL_AGENT_MODE=read-only`;
4. sends `initialize` with OpenClacky client metadata;
5. checks `initialize.result.agentCapabilities._meta.authStatus`, caches the asynchronous `_auth/status_update` notification when supported, and otherwise uses the adapter's deprecated `authentication/status` extension method as a compatibility fallback;
6. exposes advertised `chat-gpt` authentication through its extension API.

The authentication HTTP API starts the long-running ACP `authenticate` request on a background thread and returns immediately. The status begins as `unknown` until a push notification or legacy fallback result arrives; `authMethods` alone never proves that the user is logged in. Browser polling reads OpenClacky's cached status and never returns an auth URL, token, refresh token, or raw adapter stderr.

### Session creation and restoration

A new runtime session sends:

```json
{
  "method": "session/new",
  "params": {
    "cwd": "/absolute/workspace",
    "mcpServers": []
  }
}
```

The returned ACP session ID is persisted under:

```yaml
runtime:
  id: codex
  version: 1
  state:
    session_id: external-acp-session-id
    model: effective-model-if-reported
    reasoning_effort: effective-effort-if-reported
```

No credentials, launch environment, or auth metadata are stored in OpenClacky session files. On restore, the extension starts or reuses its ACP connection and calls `session/resume` with the persisted ID, current absolute workspace, and an empty MCP list. Resume intentionally does not replay provider history because OpenClacky already restores its own normalized transcript. If the external session is missing or incompatible, the local transcript remains readable and the next prompt creates a replacement ACP session with an explicit warning; it does not pretend the old Codex context was restored.

### Turn configuration

After `session/new` or `session/resume`, the extension reads `configOptions`. A new session keeps each option's `currentValue`; a restored session reapplies saved effective values only when those values are still advertised. A successful `session/set_config_option` response or `config_option_update` replaces the complete cached option set, including mode, collaboration mode, model, reasoning effort, and fast mode. OpenClacky never hard-codes a catalog or assumes an unavailable value is accepted.

The extension maps OpenClacky permission modes only to modes advertised by codex-acp. `confirm_all` and `confirm_edits` prefer `read-only`, whose adapter label is "Ask for approval" and whose Codex sandbox is workspace-write without network. `auto_approve` prefers `agent`, whose adapter label is "Approve for me" and which can auto-review operations. Unsupported modes fall back to `read-only`. OpenClacky's `plan_only` has no exact Codex ACP equivalent in version 1 and is reported as unavailable. The extension never selects `agent-full-access` automatically. Any permission request the adapter does send remains mediated by ACP, and network or out-of-workspace access is not silently granted.

### Prompt, steering, and cancel

Text becomes an ACP text content block. Image attachments become ACP image blocks only when the initialized agent advertises image prompt support. Other files and OpenClacky reference context are sent as embedded text or resource links; binary files that cannot be represented are reported as unsupported before the prompt starts.

The initial prompt uses `session/prompt`. The original JSON-RPC response is the only turn-completion barrier; message chunks, final-looking text, and sending a cancellation do not mark the session idle. Each ACP session is single-flight, while independent sessions may run concurrently. Reader-thread events carry the host generation explicitly so late updates from a cancelled turn cannot mutate the replacement turn.

ACP v1 has no standard live-steering method. Version 1 therefore keeps OpenClacky's FIFO semantics: input received during a live Codex turn is queued and sent as a new `session/prompt` after the current prompt response. The adapter-specific `_session/steering` extension is deferred until the host can own its background-turn completion semantics safely.

`interrupt` sends the `session/cancel` notification and waits for the in-flight prompt to reach its protocol completion barrier before allowing a replacement prompt on the same ACP session. The existing Ruby interruption remains the final local escape hatch, but cannot violate ACP single-flight. Any pending permission request is answered with ACP's `cancelled` outcome.

## Event and History Mapping

ACP `session/update` notifications map as follows:

| ACP update | OpenClacky behavior |
| --- | --- |
| `agent_message_chunk` | Append to a message-ID buffer and emit a keyed assistant delta; finalize one persisted assistant message at turn completion. |
| `agent_thought_chunk` | Show bounded reasoning-summary progress; do not persist private chain-of-thought as an assistant message. |
| `tool_call` | Emit a tool item keyed by `toolCallId` and retain its title, kind, input, and locations. |
| `tool_call_update` | Update the matching keyed tool item; persist a compact tool result when complete or failed. |
| `plan` | Map entries to the existing task/todo presentation when possible; otherwise show a non-blocking progress summary. |
| `usage_update` and prompt usage | Update token/context metadata and aggregate runtime counters. |
| `config_option_update` | Refresh the runtime session's effective model and reasoning metadata. |
| `session_info_update` | Accept an ACP title only while the OpenClacky session still has an autogenerated name. |
| unknown update | Ignore safely and log only update type plus adapter version. |

Existing WebSocket event types remain valid. Keyed assistant and tool fields are additive, and the frontend retains positional fallback behavior for `Clacky::Agent` events and older session history.

The runtime maintains an OpenClacky `MessageHistory` mirror for sidebar naming, history replay, search, exports, and offline readability. Codex remains authoritative for model context; the mirror is display and persistence data, not replayed back into an already-restored ACP thread.

## Permission Mapping

For `session/request_permission`, the runtime formats the tool title, kind, locations, and safe summary for OpenClacky's confirmation UI. The default choice is rejection.

Version 1 maps the boolean confirmation to ACP options without inventing an option ID:

- `Yes` selects the first advertised allow option, preferring an allow-once kind.
- `No`, dismissal, timeout, disconnect, or interrupt selects the first advertised reject option, preferring reject-once.
- If the required side has no matching advertised option, the response is `cancelled`.

Permission requests are correlated by JSON-RPC request ID and `toolCallId`, so overlapping tools cannot consume one another's answers.

## Managed Codex Home and Login Reuse

ChatCut 0.3.13 does not directly set its internal agent to the user's entire `~/.codex`. It creates a managed home, copies and rewrites configuration, links `auth.json`, and links user plugin and skill directories while keeping sessions and state databases separate.

OpenClacky uses a narrower policy. Its managed home is:

```text
~/.clacky/ext-data/codex/codex-home
```

The directory is created with mode `0700`. Sessions, SQLite state, caches, logs, and installation metadata stay there.

The source home is the launch environment's existing `CODEX_HOME`, falling back to `~/.codex`. OpenClacky may create `managed/auth.json` as a symlink to `source/auth.json` only when all of these checks pass:

- platform supports safe file symlinks;
- the source path is a regular file and not itself a symlink;
- the file is owned by the current user when ownership is available;
- group and other permission bits are zero;
- the resolved source is inside the selected source Codex home;
- the managed destination does not contain an unrelated regular file.

If the checks fail or the symlink cannot be created, OpenClacky does not copy credentials. ACP uses its own browser login in the managed home. Windows defaults to independent login rather than copying a refresh token.

OpenClacky does not inherit or link the source `config.toml`, `plugins`, `skills`, `rules`, hooks, MCP definitions, custom providers, OTEL exporters, OAuth files, history, or databases. This prevents unexpected code execution, recursive OpenClacky integrations, telemetry leakage, and session collisions.

Removing a model card or stopping OpenClacky only unlinks or closes OpenClacky-owned resources. It never follows the auth symlink for recursive cleanup and never modifies the source Codex home. Because a shared auth file can still be refreshed by either Codex process, the UI labels it as a reused Codex login rather than an isolated credential.

## Launcher and Version Policy

The extension resolves launchers in this order:

1. an explicit executable path configured for development or enterprise packaging;
2. a packaged managed Node runtime and exact `codex-acp` entry point when present;
3. an installed `codex-acp` executable whose reported version is exactly `1.11.0`, paired with an explicitly verified Codex path when distributed by OpenClacky;
4. pinned `npx -y @agentclientprotocol/codex-acp@1.11.0` for the prototype when `npx` is available.

It does not run an unversioned `npx ...@latest`. The Ruby launcher always passes an argv array rather than evaluating a command string through a shell. `CODEX_PATH` may be passed only as an explicit verified path override. The adapter declares `@openai/codex ^0.153.4`; the verified baseline is 0.153.4, but exact adapter pinning alone does not prevent npm from resolving a newer compatible transitive Codex version.

The npm fallback requires Node.js 20 or newer, needs network access on first resolution, and relies on the local npm cache afterward. The upstream v1.11.0 release does not currently publish standalone platform binaries, so any packaged executable or managed Node tree is an OpenClacky distribution artifact and must carry an immutable lock/integrity record. A standalone adapter executable also requires a paired Codex executable through `CODEX_PATH`; it does not embed Codex. Missing Node/npx or an incompatible installed adapter produces an actionable status response. A production release may replace the npm fallback without changing the provider, runtime, or ACP contracts.

## Security and Failure Behavior

- The ACP child does not inherit OpenClacky's configured model API keys. `OPENAI_API_KEY` and `CODEX_API_KEY` are explicitly removed unless a future user-selected API-key auth method supplies them.
- stdout is protocol-only. stderr is bounded, redacted, and never returned verbatim to the browser.
- Auth files, account tokens, browser-login internals, and environment values are absent from model cards, session files, logs, errors, and WebSocket events.
- Short control requests use method-specific timeouts. Long-running authentication and prompt requests use liveness monitoring plus cooperative cancel rather than one global request deadline. Malformed lines, unknown IDs, oversized messages, and process exits fail waiting operations without hanging the server.
- A runtime health test verifies process startup, ACP initialize compatibility, and authentication state. Model availability is validated only when a real session returns `configOptions`; the health test does not create a session or run a billable prompt.
- An authentication failure leaves existing API-key providers and sessions usable.
- An ACP crash marks only affected Codex sessions as errored. It does not terminate the OpenClacky server.
- Permission prompts default to reject and are cancelled during disconnect, interrupt, or shutdown.
- Shutdown sends protocol cancellation/close where possible, closes stdio, and then terminates the OpenClacky-owned process group (or Windows Job Object) so the adapter cannot leave its Codex child behind.

## Compatibility

- Existing provider presets, API responses, model cards, and sessions have no `runtime_id` and continue through `Clacky::Client` and `Clacky::Agent` unchanged.
- Runtime-backed cards live under `runtime_models`; an older OpenClacky ignores that unknown top-level key instead of constructing `Clacky::Client` with empty API credentials.
- New provider-response fields are optional. Older frontends continue rendering provider name, model, and URL fields.
- Extension manifests without `providers` or `agent_runtimes` load unchanged.
- A client version that does not understand a saved runtime model reports it as unavailable instead of treating it as a custom empty API provider.
- Ruby implementation code remains compatible with Ruby 2.6 through Ruby 4.0 and uses no new runtime gem dependency.
- The first version targets the Web UI. Terminal CLI/TUI model setup does not offer runtime providers until it has an equivalent browser-auth status experience; opening an already-saved Codex Web session remains safe, but unsupported terminal entry points report the capability limitation.

## Scope and Non-goals

Version 1 includes:

- provider and runtime extension contributions;
- a generic stdio ACP client sufficient for Codex;
- the bundled Codex extension;
- safe managed-home preparation and existing-login reuse;
- ChatGPT browser authentication and status polling;
- session-scoped model/reasoning discovery and effective-value persistence;
- new/resume/prompt/cancel session lifecycle;
- text and image input;
- streamed assistant, tool, plan, usage, and permission mapping;
- local transcript persistence and restore;
- onboarding and Settings integration;
- unit, contract, server, frontend-architecture, and fake-ACP integration specs.

Version 1 does not include:

- copying ChatCut's Codex policy wrappers or unsafe permission defaults;
- direct implementation of the Codex App Server wire protocol;
- full reuse of the user's Codex home, plugins, skills, MCP servers, hooks, rules, or session database;
- API-key or custom-gateway Codex auth in the UI;
- pre-session model selection or a hard-coded Codex model catalog;
- adapter-specific live steering;
- automatic logout of a shared Codex credential;
- bundling or publishing production platform binaries;
- ACP filesystem, terminal, elicitation, native subagent-session, background-task, or goal extensions;
- Time Machine, OpenClacky idle compression, OpenClacky sub-model overlays, or channel/cron execution for Codex sessions.

## Acceptance Scenarios

1. On a fresh OpenClacky install, the provider picker includes Codex beside existing providers; selecting it removes the base URL and API-key requirements.
2. With a valid and securely permissioned file-backed `~/.codex/auth.json`, Codex status becomes connected through a managed-home symlink without reading or copying token contents.
3. With no reusable login, `Connect with ChatGPT` opens browser authentication through ACP, status polling completes, and a credentialless card is saved under `runtime_models`.
4. A source Codex home containing MCP commands, plugins, hooks, custom providers, or telemetry configuration does not make those settings visible in OpenClacky's managed home.
5. Creating a Codex session accepts the adapter's `currentValue` model and reasoning effort, sends a prompt, streams one assistant message, displays keyed tool progress, and persists the effective values plus ACP session ID without credentials.
6. A permission request defaults to rejection, maps Yes/No to an option actually advertised by the agent, and is cancelled safely on interrupt.
7. Interrupt sends ACP `session/cancel`, returns the OpenClacky session to idle, preserves completed output, and does not leave a blocked permission waiter.
8. Restarting OpenClacky resumes the saved ACP session ID without replaying duplicate provider history and retains the local transcript. A missing external ACP session produces a warning and a fresh external session on the next prompt.
9. Existing API-key model create, edit, test, default selection, session restore, steering, and deletion specs continue to pass unchanged.
10. Missing or incompatible codex-acp/Node dependencies produce an actionable provider status while the rest of OpenClacky remains operational.
11. Logs, API responses, session JSON, and WebSocket payloads contain no auth token, refresh token, API key, or raw auth file content.
12. The complete RSpec suite passes on the feature branch, and all new Ruby files parse under Ruby 2.6-compatible syntax.

## Assumptions

- ACP protocol version 1 remains supported by `@agentclientprotocol/codex-acp` 1.11.0.
- `codex-acp` 1.11.0 continues to use stdio newline-delimited JSON and includes a compatible `@openai/codex` 0.153.4 dependency.
- ACP session configuration continues to advertise model and reasoning choices rather than requiring OpenClacky to hard-code the complete Codex model catalog.
- Browser authentication is available on the local machine running OpenClacky. Headless and remote login flows can be added through ACP device-code elicitation later.
- Production distribution will decide whether to bundle standalone adapter binaries or require a managed Node runtime before this branch is released.
