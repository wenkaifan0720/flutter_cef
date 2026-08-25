## Unreleased

* **Windows support** (`flutter_cef_windows`, experimental) — the port reaches
  feature parity with macOS for browsing, pointer/keyboard/IME input, persistent
  + shared profiles, cookies, the JS bridge (`addJavaScriptChannel` /
  `runJavaScriptReturningResult`, per-session routed), JS dialogs, find-in-page,
  content zoom, downloads, and single-tile agent-control (CDP over an inherited
  pipe, token-gated loopback relay). The app-facing Dart API is unchanged and one
  IPC opcode protocol drives both OSes. Windows specifics:
  * **Rendering**: CEF `OnAcceleratedPaint`'s shared D3D11 texture is copied into
    a DXGI-shared "bridge" texture that Flutter's ANGLE compositor samples (a
    `GpuSurfaceTexture`); software `OnPaint` is the fallback.
  * **Profiles at rest**: encrypted with **DPAPI** (OSCrypt) — always available
    and signing-independent, so a named `profile:` persists in every build with
    **no** macOS-style ad-hoc→ephemeral downgrade. DPAPI is same-user-readable
    (weaker than the macOS Keychain); the profile dir also gets a current-user
    SID DACL.
  * **Transport/host**: one `cef_host.exe` per profile over a named pipe
    (overlapped I/O); the CEF runtime is fetched + SHA-verified on first build
    and `cef_host` is compiled from source (`build_cef_host.bat`, VS2022 via
    `vswhere`).
  * **Not yet on Windows** (hardening): per-tile CDP isolation (agent-control is
    fail-closed single-tile), the Chromium sandbox (`no_sandbox` today), and a
    signed prebuilt `cef_host` on GCS (tooling scaffolded, awaits an Authenticode
    cert). Requires Windows 10+ with Developer Mode.
  * macOS behaviour is **byte-for-byte unchanged**.

## 0.2.0

* **Persistent, shared profiles**: `CefWebView(profile: 'name')` /
  `CefWebController(profile: 'name')` opt a view into a persistent, shared
  browser profile — cookies and storage live in a stable `0700` directory under
  Application Support (`<bundleId>/flutter_cef/profiles/<name>`,
  `persist_session_cookies` on), so a login survives `cef_host` / host-app
  relaunch. Every view with the same non-null `profile` is served by **one
  `cef_host` process and one cookie jar**, so they share one login (and
  `clearCookies` / `deleteCookie` clear it for all of them). Omitting `profile:`
  (the default) is **byte-for-byte today's behaviour** — an ephemeral, throwaway
  in-memory session. See the new "Profiles" section in the README.
* **Secrets-at-rest safety rail**: cookies only encrypt at rest under a signed
  release build (`CEF_HOST_ADHOC=OFF`, real Keychain / OSCrypt). An ad-hoc / dev
  build cannot, so a named profile is **automatically downgraded to ephemeral**
  (with a logged warning) rather than persisting a login to a plaintext store;
  set `FLUTTER_CEF_ALLOW_INSECURE_PROFILE=1` to override. The refusal happens
  before any browser is created, so it leaks no credentials.
* **CDP × profile rejection**: `enableCdp` cannot be combined with a named
  `profile` — CDP is an unauthenticated localhost port that could read the shared
  cookie jar — so the combination is rejected (a debug assert in
  `CefWebView` / `CefWebController`, and a native refusal of the create).
* **Internal: per-browser IPC dimension**. The host↔`cef_host` wire protocol
  gained a `browserId` frame field plus `opCreateBrowser` / `opDisposeBrowser`
  control ops, so one `cef_host` process can host several browsers (the shared
  profile). This is entirely below the method channel — the Dart API and the
  `create`/event arg maps are unchanged apart from the new optional `profile`
  key.
* **Agent control (drive a tile over CDP, no open port)**:
  `CefWebView(agentControl: true)` launches `cef_host` so it speaks CDP over an
  inherited pipe (Chromium `--remote-debugging-pipe`) instead of a TCP port — so
  there is **no listening debug port**, and (unlike `enableCdp`) it is permitted on
  a named `profile`. `CefWebController.enableAgentControl()` then brokers a
  token-gated **loopback** HTTP+WebSocket CDP endpoint (`{wsUrl, token, port}`) an
  external CDP client (e.g. `agent-browser`/Playwright via `--cdp <port>`) connects
  to; `disableAgentControl()` tears it down. Security model: per-tile opt-in; the
  relay exists **only while a grant is active**, binds **loopback only** on an
  **ephemeral port**, accepts a **single client**, and **requires** the token: the ws
  upgrade is rejected without a valid `Authorization: Bearer <token>` (Playwright
  forwards it via `connectOverCDP({ headers })`; a `?token=` query is a fallback),
  while discovery (`/json/*`) stays token-free so a port-scanner can't upgrade.
  Crucially the relay **confines the agent to
  that one tile**: a deny-by-default / fail-closed / flatten-only CDP Target-domain
  filter exposes only the tile's own target (sibling tiles in the same shared-profile
  process are hidden and unreachable), and browser-context-wide CDP (`Storage.*`,
  `Tracing.*`, `Browser.*` mutators, cookie methods) is refused — so an agent can
  drive the page but cannot read or clear the shared cookie jar. **Multi-view:**
  N tiles sharing one `cef_host` (one named profile) can each be agent-controlled
  concurrently — one token-gated relay per tile, each pinned to its own CDP target,
  all multiplexed over the single browser-wide `--remote-debugging-pipe`: inbound
  traffic is scoped by `sessionId`, and browser-level commands (which carry no
  `sessionId`) are disambiguated by a per-relay CDP-id rewrite, so a sibling tile's
  page can be neither observed nor driven through another tile's grant (distinct
  ephemeral port + token each). On host quit every `cef_host` is SIGTERM-reaped so
  none is left orphaned holding a profile's Chromium `SingletonLock`.

## 0.1.3

* **Federated package structure** (no API change): `flutter_cef` is now a
  federated plugin — the app-facing package plus
  `flutter_cef_platform_interface` (the shared Dart types + method-channel
  contract) and the endorsed `flutter_cef_macos` (Swift plugin + `cef_host`).
  Consumers keep depending on `flutter_cef` and importing
  `package:flutter_cef/flutter_cef.dart` exactly as before. A Windows or Linux
  implementation can now be added as a sibling `flutter_cef_<os>` package — see
  [`PORTING.md`](PORTING.md) for the contract and the platform-seam map.

## 0.1.2

* **Navigation scheme allowlist**: `CefWebView(allowedSchemes: {...})` restricts
  which URL schemes the page may navigate to — the initial load, programmatic
  `navigate()`, in-page link clicks, and redirects are all gated in the
  renderer's `OnBeforeBrowse`. `about:` is always permitted. Pass e.g.
  `{'http', 'https'}` to keep an untrusted page off `file:` / `data:` /
  `chrome:` schemes — important when a host can drive navigation
  programmatically. Default (`null`) preserves the previous allow-all behavior,
  so this is a non-breaking, opt-in addition. The host's explicit
  content-injection APIs — `loadHtmlString` (a `data:` URL) and `loadFile` (a
  `file:` URL) — are exempt from the allowlist, since the host (not the page)
  chose that content; only navigation (the page's, and `navigate()`) is gated.
* **Production hardening (build-time, `-DCEF_HOST_ADHOC=OFF`)**: a signed release
  build now enables the **Chromium renderer/GPU sandbox** (the helper calls
  `CefScopedSandboxContext` before loading the framework; `settings.no_sandbox`
  is false), drops the ad-hoc-only Mach-port peer-validation bypass + mock
  keychain (so cookies encrypt at rest via the real Keychain/OSCrypt), and signs
  with a stripped entitlements file that omits `get-task-allow`. All of this is
  off by default (`CEF_HOST_ADHOC=ON`) so dev/CI builds are byte-identical and
  run unsandboxed under ad-hoc signing; the release posture only *validates*
  under correct inside-out Developer-ID signing of the `cef_host` tree.

## 0.1.1

* **Multi-view host support**: the IME connection now carries
  `TextInputConfiguration.viewId` (as `EditableText` does). In a host that
  enables Flutter's multi-view mode the implicit view 0 does not exist, so a
  config without `viewId` bound the IME to a nil view and `show()` silently
  failed — pages received keydown/keyup but never characters. Typing, CJK
  composition, and the emoji picker now work in multi-view (multi-window) apps.
* Re-issue `TextInput.show()` on every click into an already-focused view
  (mirrors `EditableText.requestKeyboard`), so hosts that move macOS first
  responder around between clicks can't strand the IME view; also re-seeds the
  emoji/accent-picker caret anchor at the latest click.
* Trackpad scrolling inside hosts that opt into Flutter's trackpad gesture API
  (e.g. canvas apps): two-finger pans arrive as `PointerPanZoom*` events rather
  than `PointerScrollEvent`s — they are now forwarded to the page as scrolls,
  with a gain factor to approximate native browser scroll distance.

## 0.1.0

* Multi-process CEF by default — crash-isolated, so heavy SPAs (e.g. Google
  sign-in) render and survive. **GPU-accelerated OSR**: CEF's GPU process
  composites the page and hands it to `OnAcceleratedPaint` as a shared IOSurface,
  which moves compositing off the CPU (the bottleneck for video / animation).
  This runs multi-process without Developer-ID signing by disabling the
  MachPort peer-requirement validation that otherwise `-67030`s the GPU→browser
  handoff. The composited surface is still copied into the shared surface (cheap
  on unified-memory Macs); true zero-copy is on the roadmap.
* Fixed a multi-process blank-render bug (resize-race: geometry is re-synced
  when the renderer connects) and hardened the IPC (pre-connect frame queue).
* Page-lifecycle callbacks: `onPageStarted`, `onPageFinished`, `onProgress`,
  `onUrlChange`; new-window routing via `onCreateWindow`.
* JavaScript bridge over `CefMessageRouter`: `runJavaScriptReturningResult`
  (JSON round-trip — primitives, lists, maps) and `addJavaScriptChannel`
  (`window.<name>.postMessage` → Dart).
* JS dialogs: `onJavaScriptAlertDialog` / `onJavaScriptConfirmDialog` /
  `onJavaScriptTextInputDialog`.
* Content zoom (`setZoomLevel`), find-in-page (`find` / `stopFind` /
  `onFindResult`), `loadHtmlString` / `loadFile`.
* Cookies (`setCookie` / `clearCookies`, plus `getCookies` to read/enumerate —
  optionally scoped to a URL — and `deleteCookie`), scrolling (`scrollTo` /
  `scrollBy` / `getScrollPosition`), `getTitle` / `getUserAgent`,
  `clearLocalStorage`.
* Downloads (`onDownload` + the native Save panel).
* `openDevTools` — opens the Chrome DevTools inspector for the view in its own
  window (Elements / Console / Network / Sources, inspecting the live page).
* Automatic IME / text input: while focused, `CefWebView` holds a platform
  `TextInputConnection`, so dead keys, CJK composition, and emoji all reach the
  page. Committed text is sent as full UTF-8 (fixes the prior surrogate-pair
  truncation that mangled emoji / astral characters), composition is relayed and
  visibly underlined, and the OS candidate window is positioned under the caret
  (`OnImeCompositionRangeChanged` readback). The low-level
  `imeSetComposition` / `imeCommitText` / `imeCancelComposition` controller verbs
  remain for direct use.
* The macOS emoji & symbols picker (⌃⌘Space) now opens cold over the page —
  previously it only worked after the shortcut had been used in another (native)
  text field first. Two fixes: the key router no longer swallows ⌃⌘Space (it
  carries no `character`, so it was being treated as a consumed non-text key
  instead of falling through to the platform input context), and a caret rect is
  now always pushed while focused (seeded at the last click), so the picker —
  and the candidate / accent popups — anchor at the text instead of the screen
  corner. New `showEmojiPicker()` opens the same picker programmatically.
* Keyboard activation: typed characters now reach the page as real
  `keydown → keypress → keyup` events (a CHAR key event) like a browser, instead
  of an IME commit that fired no key events. So a focused control activates from
  the keyboard: **Enter** clicks a button / submits a form, **Space** toggles a
  checkbox / radio or clicks a button, and the page's own keypress handlers fire.
  (Composition results and multi-unit inserts — emoji, paste — still commit via
  the IME, which is correct: they have no keypress.) Space also now carries its
  `character` on keydown/keyup so Blink resolves the activation key.
* Input fidelity: editing / navigation keys (Backspace, arrows, …) no longer
  double-apply (one Backspace deleted two characters; one arrow moved two
  options in a `<select>`) — the host now sets the macOS `character` /
  `unmodified_character` on every key, which de-duplicates the edit command on
  CEF's OSR path (known CEF behavior). `<select>` dropdowns now position and
  click correctly on Retina — the popup composite offset is scaled by the device
  pixel ratio. Key routing also stops Flutter's own shortcuts from eating arrow
  keys while the view is focused.
* Verbose CEF logging is now gated behind the `FLUTTER_CEF_DEBUG` env var.
* Hardening (security/concurrency audit): validate JS channel names before
  injection; fail pending `runJavaScriptReturningResult` completers on
  navigation/dispose; deterministic session teardown that joins the reader
  thread (no use-after-free on dispose); per-user/per-process CEF cache +
  randomized IPC socket (off the world-readable `/tmp`); null main-frame and
  resize-dimension guards in the host.

## 0.0.1

* Initial macOS preview: `CefWebView` widget + `CefWebController`.
* Live Chromium (CEF) rendered off-screen into a Flutter `Texture` via a
  per-view `cef_host` subprocess and a shared IOSurface.
* Pointer, scroll, and keyboard input forwarding; page cursor drives a
  `MouseRegion`. Native `<select>` dropdowns composite over the view.
* Navigation + history: `navigate` / `reload` / `stop` / `goBack` /
  `goForward`, gated by `canGoBack` / `canGoForward`.
* Page state to Dart: `isLoading`, `title`, `url` (`ValueListenable`s) plus
  `onLoadError` and `onConsoleMessage` callbacks.
* `executeJavaScript(code)` (fire-and-forget).
* `native/build_cef_host.sh` fetches CEF and builds `cef_host.app`.
