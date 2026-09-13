# AI Settings responsiveness fix

## Diagnosis

Reported flow: Settings → AI provider → provider/model selection freezes.

Code inspection found a concrete main-thread blocking path:

- `SettingsView.body` reads `hasAI` / `configuredProviders`.
- `AIProvidersView.row` reads `hasKey` repeatedly for each provider.
- Previously, every such read called `SecItemCopyMatching` synchronously, including repeated reads of missing keys.
- Opening the provider sheet performed another synchronous credential read. Saving or testing also synchronously deleted and added a Keychain item.

Security framework operations involve system services and can stall. Repeating them during SwiftUI rendering can make navigation appear frozen. This is a **likely cause identified from code**, not a device-profiled diagnosis: this workspace has no Xcode, iOS simulator or connected iPhone.

Additional issues found: a hard 40-model display cap, duplicate IDs accepted from model APIs, requests surviving dismissal, tests implicitly saving drafts, ignored Keychain failures, and keyless custom endpoints rejected by the chat client despite being offered by Settings.

## Changes

- Secure reads/writes use a dedicated serial background queue. The existing Keychain service/account names are unchanged; no key migration is required.
- Settings render against an in-memory credential cache, including missing keys. Concurrent initial loads share one task. Failed loads are visible and retryable.
- Key replacements use `SecItemUpdate`, not delete-then-add. Cache changes occur only after successful persistence. Save failures keep the sheet and draft open.
- Model selection is a separate searchable `List`, with a free-only filter, current selection and result count. All models returned by discovery can be searched; there is no first-40 limit. Arbitrary model IDs remain editable.
- Catalogue parsing removes empty/duplicate IDs, filters Gemini non-generation models and checks both input and output prices before calling an OpenRouter model free. Availability/pricing still depends on the account; bundled suggestions are not verified availability guarantees.
- Discovery and connection tests have 20-second request timeouts and explicit cancellation. Editing inputs or closing the sheet cancels work; request identities reject stale results. Failed discovery retains the previous catalogue.
- Connection tests use the draft without persisting it. Only Save / Set as primary saves the draft. Remove key remains an explicit immediate action.
- Keyless custom HTTP(S) endpoints work. Invalid/relative/credential-bearing base URLs fail before a request starts. Gemini credentials are sent in a header instead of a URL query.
- Router cancellation no longer starts the next fallback provider.
- Planning no longer reads or sends raw sample rows. The privacy notice now explicitly discloses that narration sends report/result excerpts (which can include cell values), potentially to fallback providers.

## Regression coverage

`Tests/` contains 18 unit tests covering cache-only rendering, shared loading, retry, save failure, removal, catalogue formats, duplicates, 1,000-model search, pricing, URL validation, request authentication, timeout configuration, keyless local servers, HTTP errors, cancellation and schema-only planning.

`UITests/AISettingsUITests.swift` exercises Settings → AI → Groq/Gemini → model search → selection → Cancel, without API keys or external network access.

`project.yml` defines both test targets. The `ci/build-ipa.yml` template runs simulator tests before packaging the device IPA and uploads the `.xcresult` bundle, including on failures. The active workflow is unchanged: this GitHub connection lacks permission to edit workflow files. Install the template with an appropriately authorized connection to enable automated tests. Network unit tests use an ephemeral `URLSession` with `URLProtocol` fixtures, not live credentials.

### Validation in this workspace

- `git diff --check`: passed.
- Project and workflow YAML parsing: passed.
- Tree-sitter syntax inspection: changed/new AI implementation and test files parse; the parser has existing limitations in `AskView.swift` / `SettingsView.swift` also present in the baseline. This is **not** Swift compiler/type-check validation.
- The unsigned iPhoneOS Release build and IPA packaging were subsequently verified through GitHub Actions during the 1.1.0 update.
- XCTest, simulator UI tests and device hang profiling: **not run**. The tests are added and the `ci/` template is ready, but they are not claimed as passing.

### Run on macOS

```bash
brew install xcodegen
xcodegen generate
xcrun simctl list devices available
# Substitute an available iPhone simulator's UDID:
xcodebuild -project SheetX.xcodeproj -scheme SheetX \
  -destination 'platform=iOS Simulator,id=<UDID>' \
  -parallel-testing-enabled NO -derivedDataPath build-tests \
  CODE_SIGNING_ALLOWED=NO test
```

### Required physical-device acceptance (iPhone 11 Pro Max / iOS 16.4)

1. Upgrade an existing installation **without deleting the app or keys**. Open Settings, each provider and model selection repeatedly. Confirm existing primary/model/key status remains correct.
2. Open model selection without network or credentials. Search/select suggestions, return, cancel and reopen; cancelled draft changes must not persist.
3. Fetch a large catalogue, search for a model beyond position 40, select it and Save. Reopen and check the exact ID. Type and save an ID absent from the list.
4. During fetching/testing, edit the key/model/URL, cancel, dismiss and reopen. Old responses must not overwrite new state. A spinner must not trap navigation.
5. Exercise invalid URL, invalid key, 429, offline, empty catalogue and slow-server cases. Retain the prior model list and show an actionable error.
6. Test a keyless LAN server with a valid OpenAI-compatible URL. Test must not change persisted settings; Save must.
7. Verify Keychain read/write failure handling on the actual TrollStore installation. Failed saves must not claim success, discard the old key or dismiss the draft. No credentials should appear in logs or URLs.
8. Repeat in Arabic/RTL, English, dark mode, landscape and large text. Profile with Instruments Hangs / Time Profiler: no `SecItem…` calls should appear on the main thread in the Settings flow.

A system Keychain call cannot itself be force-cancelled safely. Moving it off-main keeps navigation responsive; dismissal is intentionally disabled during a committed credential write so its outcome is not hidden.
