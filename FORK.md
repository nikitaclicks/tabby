# Tabby Fork — OpenAI-Compatible Engine

This fork of [FuJacob/tabby](https://github.com/FuJacob/tabby) adds a third
suggestion engine alongside Apple Intelligence and local llama.cpp:
**OpenAI-Compatible HTTP API**.

You can now point Tabby at any server that speaks `/v1/chat/completions` —
a local MLX server, Ollama's OpenAI shim, LM Studio, OpenRouter, or anything
else with the same shape.

## What's different from upstream

- New engine kind `openAICompatible` in `SuggestionEngineKind`.
- `OpenAISuggestionEngine` POSTs to `{baseURL}/chat/completions` (non-streaming).
- `OpenAIPromptRenderer` produces a single chat `user` message with the prefix
  text anchored at the end before a `Continuation:` label. One message (not
  system+user) is portable across chat templates that drop the system role
  (Gemma in particular).
- `KeychainCredentialStore` — small `SecItem` wrapper. API keys live in Keychain,
  scoped per provider preset, never in `UserDefaults`.
- `ChromiumAccessibilityEnabler` — auto-sets `AXManualAccessibility` on Chrome /
  Arc / Brave / Edge / Vivaldi / Opera so their web `<input>` / `<textarea>`
  fields expose role + caret + selection to Tabby without the user toggling
  `chrome://accessibility/` or launching with `--force-renderer-accessibility`.
- Settings UI adds provider preset / base URL / model / API key fields when
  the OpenAI-compatible engine is selected.
- Debug logging of the request body + raw response when launched with
  `-tabby-debug` (see [Debugging](#debugging)).

Files added:
```
tabby/Services/Runtime/OpenAISuggestionEngine.swift
tabby/Support/OpenAIPromptRenderer.swift
tabby/Support/KeychainCredentialStore.swift
tabby/Services/Focus/ChromiumAccessibilityEnabler.swift
```

Files modified: engine enum, settings model, engine router, app composition,
settings view, onboarding view, suggestion request factory, focus tracker.

## Build

### One-time signing setup (strongly recommended)

macOS binds Accessibility / Input Monitoring / Screen Recording grants to the
**code signature**, not the bundle id. With ad-hoc signing (`CODE_SIGN_IDENTITY="-"`)
every rebuild changes the cdhash → macOS treats it as a new app → you re-grant
all three permissions. Doing this once eliminates that pain:

1. `open tabby.xcodeproj`
2. Select the **tabby** target → **Signing & Capabilities** tab
3. Check **Automatically manage signing**
4. **Team** → pick your Apple ID (shown as "Your Name (Personal Team)").
   If the menu is empty, click **Add Account…** and sign in with your Apple ID.
   A free Apple ID is enough; the paid Developer Program is not needed.
5. Bundle Identifier: if `com.jacobfu.tabby` is taken (it isn't, usually), use
   `com.<yourhandle>.tabby`.
6. Close Xcode. You won't need to touch this again.

The signature your Apple ID produces is stable across rebuilds, so TCC grants
stick.

### Build commands

Open in Xcode and hit ⌘R (easiest):
```bash
open tabby.xcodeproj
```

Or build from the CLI, dropping `.app` inside the repo:

```bash
# Recommended: with the Personal Team you set up above. No signing overrides.
xcodebuild -project tabby.xcodeproj -scheme tabby -destination 'platform=macOS' \
  -derivedDataPath ./build \
  CONFIGURATION_BUILD_DIR="$PWD/dist" \
  build
```

If you don't want to set up signing — quicker to start, but you'll re-grant
permissions on every rebuild:

```bash
xcodebuild -project tabby.xcodeproj -scheme tabby -destination 'platform=macOS' \
  -derivedDataPath ./build \
  CONFIGURATION_BUILD_DIR="$PWD/dist" \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES \
  build
```

The bundle lands at `./dist/tabby.app`. `build/` and `dist/` are gitignored.

## Run

Launch via `open` so macOS LaunchServices identifies the app as its bundle
(`com.jacobfu.tabby`). Granted permissions are bound to the launching identity
— if you `exec` the binary directly, macOS treats it as a *different* app with
its own (empty) permission set, and you end up granting permissions twice.

```bash
open -n /Users/nikita/dev/tabby/dist/tabby.app
```

### Run with debug logs

`-tabby-debug` makes the OpenAI engine print every request/response. Use `open`'s
`--stdout` / `--stderr` flags so output lands in a file you can tail, instead of
disappearing or forcing you to exec the binary directly.

```bash
# Kill any running instance, then launch with debug
pkill -9 -f /dist/tabby.app/Contents/MacOS/tabby 2>/dev/null
open -n --stdout /tmp/tabby.log --stderr /tmp/tabby.err \
  /Users/nikita/dev/tabby/dist/tabby.app --args -tabby-debug

# In another terminal:
tail -F /tmp/tabby.log /tmp/tabby.err
```

Note: `--stdout` and `--stderr` must come **before** the `.app` path; `--args`
consumes everything after it as arguments to the app.

Handy shell function:

```bash
tabby-run() {
  pkill -9 -f /dist/tabby.app/Contents/MacOS/tabby 2>/dev/null
  open -n --stdout /tmp/tabby.log --stderr /tmp/tabby.err \
    /Users/nikita/dev/tabby/dist/tabby.app --args -tabby-debug
  tail -F /tmp/tabby.log /tmp/tabby.err
}
```

## First-run permissions

Tabby needs Accessibility + Input Monitoring (Screen Recording is optional and
only used for visual context). The bundle id is `com.jacobfu.tabby` (or your
override from signing setup).

**Important**: macOS binds TCC grants to the binary that launches the app, so
**always launch with `open`** (not by exec'ing the binary directly) — otherwise
you'll end up with two separate sets of permissions, one for each identity.

1. Launch the app once with `open` so LaunchServices registers the bundle:
   ```bash
   open -n /Users/nikita/dev/tabby/dist/tabby.app
   ```
2. System Settings → Privacy & Security → **Accessibility** → click **+**
3. ⌘⇧G in the file picker → paste `/Users/nikita/dev/tabby/dist/tabby.app`
4. Toggle on.
5. Repeat for **Input Monitoring** (and **Screen & System Audio Recording** if
   you want visual context).
6. macOS may say "Quit & Reopen" — relaunch using the same `open` command.

### Why permissions sometimes need re-granting after a rebuild

macOS TCC binds permissions to the **code signature hash**, not the path or
bundle id. With ad-hoc signing (`CODE_SIGN_IDENTITY="-"`) every rebuild changes
that hash, so macOS sees a "new app" with no prior grants. The one-time signing
setup in [Build](#build) makes the signature stable across rebuilds and fixes
this for good. Until you do that setup, expect to re-grant every build.

If a stale grant blocks a new build from working:
```bash
tccutil reset Accessibility com.jacobfu.tabby
tccutil reset ListenEvent   com.jacobfu.tabby   # Input Monitoring
tccutil reset ScreenCapture com.jacobfu.tabby
```

## Configure the OpenAI-compatible engine

Menu bar → Settings → Autocomplete:

1. **Engine** → `OpenAI-Compatible API`
2. **Provider** → pick a preset:
   - `Local (mlx-lm / Ollama)` — prefills `http://127.0.0.1:8080/v1`
   - `OpenRouter` — prefills `https://openrouter.ai/api/v1`
   - `Custom` — you fill in the URL
3. **Base URL** — edit if your server runs elsewhere
4. **Model** — the exact id your server expects:
   - mlx-lm: e.g. `mlx-community/Llama-3.2-3B-Instruct-4bit`
   - Ollama: e.g. `gemma3:4b`, `llama3.2:3b`
   - OpenRouter: e.g. `openai/gpt-4o-mini`, `anthropic/claude-3.5-haiku`
5. **API Key** — required for OpenRouter; leave blank for local servers.
   Stored in Keychain under service `com.tabby.openai-engine`, scoped to the
   selected preset.

## Run a local server (one of these)

**mlx-lm** (Apple Silicon native):
```bash
pip install mlx-lm
mlx_lm.server --model mlx-community/Llama-3.2-3B-Instruct-4bit --port 8080
```

**Ollama** (already exposes an OpenAI shim):
```bash
ollama serve
ollama pull gemma3:4b
# Base URL: http://127.0.0.1:11434/v1
# Model:    gemma3:4b
```

**LM Studio**: Developer tab → Start Server. Base URL is typically
`http://localhost:1234/v1`.

## Smoke test the server (skip Tabby)

```bash
curl http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"mlx-community/Llama-3.2-3B-Instruct-4bit",
       "messages":[{"role":"user","content":"hi"}],
       "max_tokens":10}'
```

If that returns JSON with `choices[0].message.content`, Tabby will work too.

## Debugging

Launch with the debug flag (see [Run](#run)) and tail `/tmp/tabby.log` to see
every request and response:

```bash
open -n --stdout /tmp/tabby.log --stderr /tmp/tabby.err \
  /Users/nikita/dev/tabby/dist/tabby.app --args -tabby-debug
tail -F /tmp/tabby.log /tmp/tabby.err
```

Expected output around each suggestion:

```
[OpenAI engine] POST http://127.0.0.1:8080/v1/chat/completions model=… …
[OpenAI engine] request body:
{"model":"…","messages":[{"role":"user","content":"…Continuation:\n…"}],…}
[OpenAI engine] response status=200:
{"choices":[{"message":{"content":"…"}}…]}
```

This is also the fastest way to diagnose "irrelevant suggestions" — paste the
request body to see what context the model actually got, and the raw response
to see what shape the model returned (some models prepend explanations,
markdown, or quotes that `SuggestionTextNormalizer` then has to strip).

## Useful one-liners

```bash
# Rebuild (assumes Personal Team signing is set up — see Build)
xcodebuild -project tabby.xcodeproj -scheme tabby -destination 'platform=macOS' \
  -derivedDataPath ./build CONFIGURATION_BUILD_DIR="$PWD/dist" build

# Kill any running instance and relaunch with debug via open (preserves TCC grants)
pkill -9 -f /dist/tabby.app/Contents/MacOS/tabby 2>/dev/null
open -n --stdout /tmp/tabby.log --stderr /tmp/tabby.err \
  /Users/nikita/dev/tabby/dist/tabby.app --args -tabby-debug
tail -F /tmp/tabby.log /tmp/tabby.err

# Reset all Tabby permissions
for db in Accessibility ListenEvent ScreenCapture; do
  tccutil reset $db com.jacobfu.tabby
done
```

## Notes

- The fork keeps upstream's engines fully working. Switching back to Apple
  Intelligence or Open Source in Settings has no functional change.
- The OpenAI engine is non-streaming. Inline autocomplete is short and
  round-trip latency dominates, so first-token streaming isn't worth the
  pipeline plumbing.
- API key storage uses `kSecAttrAccessibleAfterFirstUnlock` — readable as
  soon as you've logged in, encrypted at rest before the first unlock.
- Chromium accessibility priming is automatic — no need to flip the global
  `chrome://accessibility/` toggle or launch Chrome with
  `--force-renderer-accessibility` (both are known to crash some tabs).
  Tabby flips the per-app `AXManualAccessibility` attribute the first time
  it sees a Chromium browser focused.
