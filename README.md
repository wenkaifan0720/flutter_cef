# flutter_cef

Embed a **live Chromium browser** (via the [Chromium Embedded Framework](https://bitbucket.org/chromiumembedded/cef/)) as a Flutter widget — rendered into a `Texture`, so it composites, transforms, clips, and zooms like any other widget, and **keeps rendering even when off-screen / not focused**. Pointer, scroll, and trackpad two-finger pans are forwarded by coordinate (pans are caught even when an ancestor opts into Flutter's trackpad gesture API, as canvas hosts do), and keyboard input reaches the page as real `keydown → keypress → keyup` events (Enter activates a focused button / submits a form, Space toggles a checkbox) — including platform IME composition for CJK / emoji and the ⌃⌘Space emoji picker. Text input is bound to the hosting `FlutterView` (as `EditableText` does), so it **works in multi-view / multi-window apps**; the page cursor drives a `MouseRegion`.

> Status: **experimental — macOS 12+ and Windows 10+** (CEF 144 runtime floor).
> Real Chromium (any site — JS/CSS/WebGL/video). **Multi-process by default**
> (GPU-accelerated OSR — `OnAcceleratedPaint` GPU compositing into a shared
> surface, HiDPI-crisp; renderer/utility crashes isolated, so heavy SPAs like
> Google sign-in render and survive). macOS composites into an `IOSurface`;
> Windows copies the shared D3D11 texture into a DXGI-shared bridge that Flutter's
> ANGLE compositor samples. **macOS is the reference platform**; the Windows port
> reaches feature parity for browsing, input/IME, persistent+shared profiles,
> cookies, the JS bridge, dialogs/find/zoom/downloads, and single-tile
> agent-control — with per-tile CDP isolation, the Chromium sandbox, and
> code-signing still pending (see [Roadmap](#roadmap)). No mobile (iOS bans
> third-party engines); desktop by nature.

```dart
import 'package:flutter_cef/flutter_cef.dart';

CefWebView(url: 'https://flutter.dev')

// Opt into a persistent, shared profile: the login (cookies + storage) survives
// relaunch and is shared by every view with the same profile name. Omit
// `profile:` (the default) for an ephemeral, throwaway session. See "Profiles".
CefWebView(url: 'https://app.example.com', profile: 'work')
```

Drive and observe it via a controller:

```dart
final c = CefWebController();
CefWebView(url: startUrl, controller: c);

// navigation + history + loading
c.navigate('https://example.com');
c.reload(); c.stop(); c.goBack(); c.goForward();
c.loadHtmlString('<h1>hi</h1>'); c.loadFile('/abs/page.html');
c.setZoomLevel(1.0);                 // 1.2^level (0 = 100%)
c.find('term'); c.stopFind();        // results on c.onFindResult

// JavaScript: run, return a value, and talk back from the page
c.executeJavaScript('document.body.style.zoom = 1.2');
final title = await c.runJavaScriptReturningResult('document.title'); // String/num/List/Map
c.addJavaScriptChannel('Native', onMessageReceived: (m) => print('JS says $m'));
// then in the page: window.Native.postMessage('hello')
c.removeJavaScriptChannel('Native'); // stop delivering (page-side shim stays; see Profiles)

// page state (ValueListenables) + lifecycle/dialog callbacks
c.isLoading;  c.url;  c.title;  c.canGoBack;  c.canGoForward;
c.onPageStarted = (u) {}; c.onPageFinished = (u) {}; c.onProgress = (p) {};
c.onUrlChange = (u) {}; c.onCreateWindow = (u) => c.navigate(u); // target=_blank
c.onLoadError = (e) => print('${e.errorCode} ${e.url}');
c.onConsoleMessage = (m) => print(m.message);
c.onJavaScriptConfirmDialog = (req) async => askUser(req.message); // alert/confirm/prompt

// process liveness + paint recovery
c.onProcessGone = (reason) {};   // host died: 'locked' (profile open elsewhere) / 'crashed'
c.onPaintStalled = () {};        // created but never painted — recreate the view to recover

// pause/resume frame production without tearing down (DOM + JS state kept)
c.setVisible(false); c.setVisible(true);

// cookies + scroll + storage
c.setCookie(url: 'https://example.com/', name: 'sid', value: 'abc');
final cookies = await c.getCookies(); // read/enumerate; pass url: to scope
c.deleteCookie(url: 'https://example.com/', name: 'sid'); c.clearCookies();
c.scrollTo(0, 200); c.scrollBy(0, -50); await c.getScrollPosition();
c.clearLocalStorage(); await c.getTitle(); await c.getUserAgent();
c.onDownload = (suggestedName) {}; // a download started (a native Save panel is shown)

// open the Chrome DevTools inspector for this view in its own window
c.openDevTools();

// Raw Chrome DevTools Protocol over a TCP port — opt in at construction with
// CefWebView(..., enableCdp: true), then connect a CDP client to 127.0.0.1:<port>:
final cdpPort = c.cdpPort.value; // ValueListenable<int>; 0 until created
// NOTE: enableCdp is an UNAUTHENTICATED localhost port and is rejected on a named
// `profile:`. To drive a logged-in tile from an agent, prefer agentControl +
// enableAgentControl() (CDP over a private pipe, token-gated) — see "Agent control".

// open the macOS emoji & symbols picker over the focused page (same as ⌃⌘Space)
c.showEmojiPicker();
```

See `example/` for a full browser chrome (URL bar, back/forward/reload, loading
bar, live title).

## How it works

```
Dart  CefWebView + CefWebController   (MethodChannel "flutter_cef")
  → host plugin (per OS):
      macOS   (FlutterCefPlugin / CefWebSession): allocates a global IOSurface +
              CVPixelBuffer, registers a FlutterTexture, spawns one cef_host.app
              per profile, relays input + cursor over a Unix socket
      Windows (FlutterCefPlugin, C++): registers a GpuSurfaceTexture (DXGI shared
              handle), spawns one cef_host.exe per profile, relays over a named
              pipe (overlapped I/O)
  → cef_host: CEF windowless (OSR), multi-process — the GPU/Viz process
      composites the page and hands OnAcceleratedPaint a shared-texture handle:
      macOS   copies it into the host-shared IOSurface;
      Windows opens the shared D3D11 texture and CopyResources it into a
              DXGI-shared "bridge" texture (NT→legacy handle) that ANGLE samples.
      → "present" → the texture re-samples. (OnPaint software blit is the fallback.)
```

Same pattern JCEF (JetBrains) and CefSharp use to render Chromium into a
non-native toolkit — adapted to Flutter's `Texture` (IOSurface on macOS, a
DXGI-shared D3D11 texture on Windows). One IPC opcode protocol
([`PROTOCOL.md`](packages/flutter_cef_windows/native/cef_host/PROTOCOL.md))
drives both; only the surface, transport, app-loop, sandbox, and framework-path
seams differ per OS (see [`PORTING.md`](PORTING.md)).

## Building

CEF (~200 MB) is **fetched**, not vendored, on both platforms.

**macOS** — build the renderer once (needs `cmake` + `ninja` —
`brew install cmake ninja`):

```sh
# The macOS implementation lives in packages/flutter_cef_macos.
cd packages/flutter_cef_macos
native/build_cef_host.sh            # fetches CEF + builds cef_host.app
export FLUTTER_CEF_HOST="$PWD/native/cef_host/build/cef_host.app/Contents/MacOS/cef_host"
cd ../../example && flutter run -d macos
```

**Windows** — nothing to run by hand: `flutter build windows` (or
`flutter run -d windows`) drives everything from the plugin's CMake. On the
first build it fetches the pinned CEF distribution
(`native/cef_host/fetch_cef.ps1`, SHA-verified, cached under `%LOCALAPPDATA%`)
and compiles `cef_host.exe`/`.dll` (`build_cef_host.bat` → the VS2022 toolchain,
located via `vswhere`; `cmake` + `ninja` ship with VS). Needs Windows 10+ with
Developer Mode on (Flutter uses symlinks for plugins).

```sh
cd example && flutter run -d windows
```

> A prebuilt, content-hash-keyed `cef_host` on GCS (so consumers fetch it
> instead of compiling, as macOS does) is scaffolded in
> `packages/flutter_cef_windows/tool/` but not yet live — it awaits Authenticode
> signing (see [Roadmap](#roadmap)); until then Windows builds from source.

### Bundling into a distributable app

For a shipped `.app` (no dev env var), `cef_host.app` must live in your bundle's
`Contents/Frameworks` and be signed by your build. The plugin resolves it there
automatically (`$FLUTTER_CEF_HOST` → pod resources → `Contents/Frameworks` →
`Contents/Helpers`). After `flutter build macos`, run:

```sh
packages/flutter_cef_macos/tool/bundle_cef_host.sh "build/macos/.../YourApp.app" "" "<signing-identity>"
```

or wire it as a Run Script build phase on your Runner target (snippet in
`packages/flutter_cef_macos/tool/bundle_cef_host.sh`) so it runs before Xcode's
code-sign phase. Your host
app **must not be App-Sandboxed** (CEF spawns the helper, shares a global
IOSurface, writes a cache); entitlements need
`com.apple.security.cs.disable-library-validation` + JIT — see
`example/macos/Runner/*.entitlements` for the reference set. Sign everything with
one identity (framework → cef_host → app, inside-out) and library validation can
stay on.

**Privacy usage descriptions (required in YOUR app's `Info.plist`).** `cef_host`
is spawned as a child of your app, so macOS TCC attributes the page's
privacy-sensitive hardware access to your app (the responsible process) and reads
the usage string from **your app's** `Info.plist` — not `cef_host`'s. Without it,
the process is **SIGABRT'd** the instant a page touches the hardware (e.g. Google
sign-in probing WebAuthn/FIDO security keys reaches Bluetooth). Declare at least:

```xml
<key>NSBluetoothAlwaysUsageDescription</key><string>A web page is requesting Bluetooth to use a security key or passkey.</string>
<key>NSCameraUsageDescription</key><string>A web page is requesting camera access.</string>
<key>NSMicrophoneUsageDescription</key><string>A web page is requesting microphone access.</string>
```

(`example/macos/Runner/Info.plist` carries these.) Hardened-runtime apps that want
the access to actually *function* (not just avoid the crash) also need the
matching `com.apple.security.device.{bluetooth,camera,microphone}` entitlements;
with them absent the access is denied gracefully, which is enough to keep
password sign-in working when WebAuthn isn't supported.

## Security

`flutter_cef` embeds a full Chromium that runs arbitrary web content with JIT.
Treat any page you load as untrusted code. The security posture is driven by one
build flag, `CEF_HOST_ADHOC` (default `ON`):

| | `CEF_HOST_ADHOC=ON` (default, dev/CI) | `CEF_HOST_ADHOC=OFF` (signed release) |
| --- | --- | --- |
| Chromium renderer/GPU sandbox | off (`no_sandbox=true`) | **on** — helper calls `CefScopedSandboxContext` |
| Mach-port peer validation | bypassed (env var + `--disable-features`) | **enforced** |
| Cookie-at-rest encryption | mock keychain / `password-store=basic` | **real Keychain / OSCrypt** |
| `get-task-allow` entitlement | present (local debugging) | **absent** (`entitlements.release.plist`) |

The `OFF` posture only *validates* under correct **inside-out Developer-ID
signing** of the `cef_host` tree (deepest helper → `libcef_sandbox.dylib` + CEF
framework → host, depth-first, Hardened Runtime + trusted timestamp). Build it
with `CEF_HOST_ADHOC=OFF CODESIGN_ID="<Developer ID>"
packages/flutter_cef_macos/native/build_cef_host.sh`,
or — when bundled into a host app — let the app's own signing re-sign the tree
with those entitlements. Ad-hoc/dev builds run unsandboxed by necessity (the
sandbox can't validate without proper signing), which is why `ON` is the default.

Other always-on protections:

- **Hardened-runtime relaxations.** The signed-release set
  (`entitlements.release.plist`) is intentionally minimal: only `allow-jit`
  (CEF's V8 JIT, via MAP_JIT) plus `device.bluetooth` (caBLE passkeys). The
  dev/ad-hoc set (`entitlements.plist`) additionally relaxes
  `disable-library-validation` and `allow-unsigned-executable-memory` for
  convenience, but neither is load-bearing under correct inside-out single-identity
  signing, so release drops both (see the hardening backlog and
  `entitlements.release.plist` for the rationale).
- **Navigation scheme allowlist** (`CefWebView(allowedSchemes:)`) — gate which
  schemes a page may navigate to (main-frame nav, programmatic `navigate()`,
  clicks, redirects); host content-injection (`loadHtmlString`/`loadFile`) is
  exempt. Off by default (allow-all). This is a **navigation policy knob, not a
  content-isolation boundary**: it gates *main-frame navigations only* — it does
  **not** restrict subframes, subresources, or `fetch`/XHR/`<img>`/`ws:` loads,
  so a page can still issue requests over any scheme. Use it to constrain where
  the top-level frame can go, not to sandbox what content can load.
- **JS channel names are validated** as JS identifiers before injection, and
  **`runJavaScriptReturningResult` expects a single expression** from trusted
  app code.
- **Per-user, per-process CEF cache** (under the 0700 temp dir, not a fixed
  world-readable `/tmp` path) and a **randomized control-socket name** — a named
  `profile:` instead uses a stable 0700 dir under Application Support (see
  [Profiles](#profiles)).

### Known limitations / hardening backlog

This is a competent CEF embedding with honestly-labeled deferrals, not a fully
hardened browser. Notable items still open — see
[`specs/persistent-profiles/SECURITY-REVIEW.md`](specs/persistent-profiles/SECURITY-REVIEW.md)
for the full punch list (file:line) and prioritization:

- **Per-product keychain item name** for OSCrypt (true at-rest isolation from
  other CEF apps) — needs a from-source CEF build to override the hardcoded
  `"Chromium Safe Storage"` name (see [Secrets at rest](#secrets-at-rest)).
- **Browser-process auto-respawn** — a `cef_host` crash surfaces and unbricks
  the profile, but does not yet automatically restart it.
- **Socket peer authentication** — the control socket is first-connector-wins
  with no `getpeereid()` check on the spawned process.

## Profiles

By default a `CefWebView` is **ephemeral**: cookies, `localStorage`, and the rest
of the page's storage live in a throwaway in-memory profile that is discarded
when the view is disposed (and the host process exits). Nothing persists across
relaunch. This is the historical behaviour and stays the default.

Pass `profile:` to opt into a **persistent, shared profile**:

```dart
CefWebView(url: 'https://app.example.com', profile: 'work')
// or, when scripting a view yourself:
final c = CefWebController(profile: 'work');
CefWebView(url: startUrl, controller: c);
```

- **Persistent.** A named profile is stored on disk — on macOS at
  `<Application Support>/<bundleId>/flutter_cef/profiles/<name>`, on Windows at
  `%LOCALAPPDATA%\flutter_cef\profiles\<name>`. The directory is created
  owner-only (`0700` on macOS; a current-user-SID-protected DACL on Windows) and
  the profile name is sanitized to `[A-Za-z0-9._-]`. CEF is started with
  `persist_session_cookies` on, so a login survives `cef_host` and host-app
  relaunch. On Windows the `profiles\` root is **not** namespaced by app, so every
  flutter_cef app for a user shares it — a `profile: 'work'` in two apps resolves
  to the same directory (co-locate only mutually-trusting apps on a shared name).
- **Shared.** Every view constructed with the same non-null `profile` is served
  by **one `cef_host` process with one cookie jar** — they share one login.
  Cookie writes are therefore process-wide: `clearCookies()` /
  `deleteCookie()` clear the cookie for *all* views in the profile, by design.
- **One trust domain per profile.** Because a named profile is one process with
  one cookie jar, sessions sharing a profile are **not isolated from each
  other**. The cookie jar is common (a page in one view can read another's
  cookies via `getCookies`), and registered JS channels
  (`addJavaScriptChannel`) are process-global, so a page in one view can observe
  a channel name another view registered. Per-message *routing* stays
  per-session — a channel message is delivered only to the view whose page sent
  it (`OnQuery` stamps the originating browser), so this is an information-
  sharing boundary, not a message-spoofing one — but the rule is the same:
  **co-locate only mutually-trusting content on one profile.** For
  mutually-distrusting content (e.g. arbitrary third-party pages from different
  authors), give each its own `profile`, or use the ephemeral default — each
  gets its own process, cookie jar, and channel namespace.

### Secrets at rest

Cookies (and Chromium's password / OSCrypt-encrypted data) are only encrypted
at rest under a **signed release build** (`CEF_HOST_ADHOC=OFF` — see
[Security](#security)), where `cef_host` uses the real macOS Keychain /
OSCrypt. The encryption key is stored in the default OSCrypt login-Keychain
item named **"Chromium Safe Storage"** (you'll see a **one-time Keychain
prompt** the first time a profile is created). This item is **shared** with
every CEF/Chromium-based app that resolves the same default name — it is *not*
ACL-scoped to one signing identity, so it does not isolate our key from other
CEF apps the user has approved. At-rest protection therefore comes from
**FileVault** (full-disk encryption) plus the **login keychain** being locked
when the user is logged out — not from a per-binary keychain ACL. True per-app
isolation needs a **per-product keychain item name**, but that name is a
hardcoded literal baked into the prebuilt CEF framework; overriding it requires
a from-source CEF build and is tracked as a follow-up (see the hardening
backlog).

The default ad-hoc / dev build (`CEF_HOST_ADHOC=ON`) has only a **mock keychain**
— it cannot encrypt cookies at rest. To avoid silently writing a "persistent"
login to a plaintext on-disk store, an ad-hoc host **downgrades a named profile
to ephemeral** (and logs a warning) rather than persisting it. Set
`FLUTTER_CEF_ALLOW_INSECURE_PROFILE=1` in the environment to override this and
persist under the mock keychain anyway (dev convenience only — do not ship it).
The downgrade leaks nothing: the refusal happens before any browser is created,
so nothing is ever written to the persistent directory.

**Windows is different — no downgrade, and no signing requirement.** On Windows,
OSCrypt encrypts the cookie store with **DPAPI**, which is **always available and
independent of code signing**. There is no mock-keychain state, so the
ad-hoc-downgrade rule above has no Windows analogue: a named `profile:` on Windows
simply persists, encrypted at rest, in every build. The trade-off is that DPAPI's
user-tier protection is **same-user-readable** — any process running as the same
Windows user can decrypt the store (`CryptUnprotectData`). This is **weaker than
the macOS Keychain**: at-rest protection covers other users and offline disk theft
(with BitLocker as the full-disk backstop), but **not** other same-user processes.
As on macOS, `localStorage` / IndexedDB are stored unencrypted regardless.

Two further caveats even under a signed build: `localStorage` and IndexedDB are
**not** encrypted by OSCrypt (they sit in the profile directory as plaintext —
FileVault is again the backstop), and **CDP (`enableCdp`) is incompatible with a
named profile**: CDP is an unauthenticated localhost port that could read the
shared cookie jar, so combining the two is rejected (the constructor asserts in
debug, and the native side refuses the create).

## Agent control

Let an external CDP client (e.g. [agent-browser](https://github.com/vercel-labs/agent-browser),
which is Playwright-based) drive a **live, logged-in** tile — without a duplicate
browser, without losing state, and **without an open debug port**.

```dart
// 1. Create the view in agent-control mode (CDP over a private inherited pipe,
//    not a TCP port — so it's permitted on a named profile, unlike enableCdp).
CefWebView(controller: c, profile: 'work', agentControl: true)

// 2. When you want an agent to drive THIS tile, broker a token-gated, per-tile
//    loopback CDP endpoint and hand it to the agent:
final grant = await c.enableAgentControl();        // -> {wsUrl, token, port}
// e.g.  agent-browser --cdp <grant.port> open https://example.com
await c.disableAgentControl();                     // revoke when done
```

`agentControl: true` launches `cef_host` so Chromium speaks CDP over an inherited
pipe (`--remote-debugging-pipe`, NUL-framed JSON on fds 3/4) instead of a TCP port —
there is **no listening debug port**. `enableAgentControl()` then starts a small
**loopback** HTTP+WebSocket relay that bridges a standard CDP client to that pipe and
returns the endpoint.

**Trust model.** The relay is the only way in, and it is deliberately narrow:

* **Per-tile opt-in.** Nothing is exposed until you call `enableAgentControl()`; the
  relay exists *only while the grant is active* and is torn down on
  `disableAgentControl()`, tile dispose, or host shutdown.
* **Loopback + ephemeral + single-client + mandatory token.** It binds `127.0.0.1`
  on an OS-assigned port and accepts one client at a time. The returned `token` is
  **required** — the ws upgrade is rejected (401) without a valid `Authorization:
  Bearer <token>` (a `?token=` query is an accepted fallback). A CDP client attaches
  it via `connectOverCDP({ headers })` (Playwright forwards request headers on the
  upgrade). Discovery (`/json/*`) stays token-free, so a local port-scanner learns
  the ws-url but cannot upgrade. (Strictly better than raw Chrome's fixed, always-
  open, multi-client `--remote-debugging-port`: even a same-UID process can't connect,
  because it never sees the token — the integrator must deliver it to its CDP client
  out-of-band, kept in memory, never on disk/argv/env.)
* **Per-tile isolation.** Tiles in a shared profile run in one `cef_host` process
  behind one browser-wide CDP pipe, so the relay enforces the boundary itself: a
  deny-by-default, fail-closed, **flatten-only** CDP Target-domain filter exposes the
  client **only its own tile's target** — sibling tiles are hidden (not in
  `Target.getTargets`) and unreachable (`attachToTarget`, `sendMessageToTarget`,
  `attachToBrowserTarget`, foreign sessions are all refused).

**Limits, by design.** Per-tile CDP isolation *within a shared browser context* is
inherently partial — browser-context-wide CDP can't be scoped to one tile. So
browser-context/process-global domains are **refused** entirely: `Storage.*`,
`Tracing.*`, `Memory.*`, `SystemInfo.*`, `Browser.*` (except `getVersion`), and the
cookie/cache methods (`Network.getAllCookies`/`clearBrowserCookies`/…). The agent can
drive its tile's page (navigate, click, type, read DOM, run JS) but **cannot read or
clear the shared cookie jar** or touch sibling tiles. It *can* act with the tile's own
authenticated session for the tile's own origin — that is inherent to driving a
logged-in page. Strictly airtight CDP isolation would require a per-tile browser
context, which would un-share the login the shared profile exists to provide.
**Multi-view:** N tiles sharing one `cef_host` (one named profile) can each be
agent-controlled concurrently — one token-gated relay per tile, each pinned to its
own CDP target, all multiplexed over the single browser-wide `--remote-debugging-pipe`
(per-tile sessionId scoping + a per-relay CDP-id rewrite so a sibling's traffic can
neither be seen nor driven). See the `CdpRelay` multiplex notes and
`CdpRelayFilterTests` for the isolation boundary.

## Troubleshooting

### Blank / black texture — the page never appears

`cef_host` couldn't be found, so no renderer subprocess spawned. Build it and make
it discoverable — in a dev checkout export `$FLUTTER_CEF_HOST` (see
[Building](#building)); in a shipped `.app`, `cef_host.app` must live in
`Contents/Frameworks` (run `tool/bundle_cef_host.sh`). Resolution order:
`$FLUTTER_CEF_HOST` → pod resources → `Contents/Frameworks` → `Contents/Helpers`.

### App crashes shortly after a page touches hardware (SIGABRT)

`cef_host` runs as a child of your app, so macOS attributes hardware access (e.g.
WebAuthn/passkeys reaching Bluetooth, camera, microphone) to your app and reads
the usage string from **your** app's `Info.plist`. If it's missing, the process is
SIGABRT'd the instant the hardware is touched. Declare
`NSBluetoothAlwaysUsageDescription` / `NSCameraUsageDescription` /
`NSMicrophoneUsageDescription` in your app's `Info.plist` (see
`example/macos/Runner/Info.plist`), plus the matching
`com.apple.security.device.*` entitlements if the access must actually function.

### A named `profile:` silently behaves as ephemeral (login doesn't persist)

**macOS only.** The default ad-hoc dev build (`CEF_HOST_ADHOC=ON`) has only a mock
keychain and can't encrypt cookies at rest, so it **downgrades a named profile to
ephemeral** rather than persisting a login to a plaintext store (it logs a
warning). For real persistence ship a signed release build (`CEF_HOST_ADHOC=OFF`,
real Keychain/OSCrypt). For dev only, set `FLUTTER_CEF_ALLOW_INSECURE_PROFILE=1` —
**never ship that override.** On **Windows** this never happens: OSCrypt uses
DPAPI, which is always available and signing-independent, so a named profile
persists in every build (see [Secrets at rest](#secrets-at-rest) for the
same-user-readable caveat).

### `onProcessGone` fires with reason `'locked'`

The persistent profile is already open in another process/instance — a named
profile is one `cef_host` with one cross-process cache lock. Close the other
holder and recreate the view to retry (vs. `'crashed'` for a generic death).

### Page loads but never paints (permanently blank, no crash)

The browser was created but never delivered a first frame even after a re-kick.
Wire `controller.onPaintStalled` and recreate the view to recover, rather than
leaving a blank tile.

### Agent-control CDP client gets `401` on the WebSocket upgrade

The relay **requires a token**. Present the token from `enableAgentControl()` as
`Authorization: Bearer <token>` (a `?token=` query is an accepted fallback) on the
upgrade; CDP discovery (`/json/*`) stays token-free. The token is minted per
grant, held only in memory, and embedded in `grant.wsUrl` — deliver it
out-of-band (never on disk/argv/env). See [Agent control](#agent-control).

## Roadmap

Known limitation: the IOSurface is single-buffered, so very fast-updating pages
can tear slightly under the compositor; double-buffering is planned. Working
today: **multi-process, GPU-accelerated** OSR render (on/off-screen,
HiDPI/Retina-crisp, GPU compositing via `OnAcceleratedPaint`, heavy SPAs render +
survive),
pointer/scroll/trackpad-pan/keyboard input, **IME text input** (CJK composition
+ emoji, the candidate window tracked under the caret, and the ⌃⌘Space emoji
picker — `showEmojiPicker()`) **in single- and multi-view (multi-window) hosts**
(the connection carries `TextInputConfiguration.viewId` and is re-shown on every
click, EditableText-style), `<select>` popups, page cursor;
navigation + history, page-lifecycle events (start/finish/progress/url-change),
new-window routing (`onCreateWindow`), loading/title/url/error/console state; JS
dialogs (alert/confirm/prompt), a JS bridge (`addJavaScriptChannel` +
`runJavaScriptReturningResult` over `CefMessageRouter`), `executeJavaScript`;
content zoom, find-in-page, `loadHtmlString`/`loadFile`, cookies
(set/clear plus read/enumerate via `getCookies` + `deleteCookie`), scroll,
title/user-agent getters, downloads, and a Chrome DevTools inspector window
(`openDevTools`).

Next:

- **True zero-copy GPU render.** Rendering is now GPU-accelerated:
  `OnAcceleratedPaint` (GPU compositing) is on by default, multi-process and
  crash-isolated. The `-67030` that used to gate the GPU→browser handoff (Chromium
  144 validating cef_host's ad-hoc signature) is cleared by disabling the
  `MachPortRendezvous*PeerRequirements` features — no Developer-ID signing needed.
  We still **copy** the GPU surface into the shared surface (cheap on
  unified-memory Macs, where compositing — not the copy — was the bottleneck).
  TRUE zero-copy — handing the GPU IOSurface to Flutter with no copy — needs
  cross-process Mach-port surface transfer (CEF's GPU surfaces aren't resolvable
  by global id from another process), and mostly helps discrete-GPU Macs and
  scenes with many simultaneously-animating webviews; deferred until measured.
- **Double-buffer the IOSurface** to remove the residual tearing on
  fast-updating pages (JCEF's named-mutex 2-slot buffer is a good reference).
- **The CEF feature tail** that CefSharp/JCEF expose: `loadRequest` with custom
  headers / POST body, `setUserAgent`, request / resource interception, custom
  scheme handlers, a typed DevTools/CDP client (the inspector window already
  ships via `openDevTools`; this is the programmatic CDP surface), and `CefPermissionHandler`
  (WebRTC camera/mic prompts).
- **Windows** (`flutter_cef_windows`) — **landed** and at feature parity for
  browsing, pointer/keyboard/IME input, persistent + shared profiles, cookies,
  the JS bridge, JS dialogs, find-in-page, content zoom, downloads, and
  single-tile agent-control. The Dart controller / widget surface is shared and
  one IPC opcode protocol drives both OSes
  ([`PROTOCOL.md`](packages/flutter_cef_windows/native/cef_host/PROTOCOL.md)).
  Still pending on Windows (hardening, not features):
  - **Per-tile CDP isolation** — agent-control is enforced single-tile
    (fail-closed: no grant on a multi-tile host); the deny-by-default per-tile
    Target-domain filter that macOS ships (so N tiles on one profile can each be
    agent-driven in isolation) is the next step.
  - **Chromium sandbox** — the host currently runs `no_sandbox`; the
    `bootstrapc.exe` + LPAC sandbox is designed (spike-proven) but not yet on.
  - **Code-signing + prebuilt distribution** — an Authenticode-signed,
    content-hash-keyed `cef_host` on GCS (fetched, not compiled, like macOS);
    tooling is scaffolded in `packages/flutter_cef_windows/tool/`, awaiting a
    signing certificate.
  - Double-buffering the shared texture (the ~1.8% tearing measured on
    fast-updating pages), and GPU device-lost / leak-soak hardening.
- **Linux** — not started; the same federated seam applies (a sibling
  `flutter_cef_linux` supplies shared-memory/DMA-buf surface + Unix-socket
  transport). See [`PORTING.md`](PORTING.md) for the contract and seam map.

## Credits

Built on [CEF](https://bitbucket.org/chromiumembedded/cef/). Patterns drawn from CEF's `cefclient` OSR sample, [JCEF](https://github.com/chromiumembedded/java-cef), and [CefSharp](https://github.com/cefsharp/CefSharp).
