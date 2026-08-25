# flutter_cef Windows wire + channel contract (slice)

TRANSCRIBED from the macOS reference implementation — do not invent. Sources
(line numbers as of branch `feat/windows-port-p0`):

- `packages/flutter_cef_macos/native/cef_host/main.mm` — opcode table
  (`kOp*`, main.mm:111-164), framing (main.mm:40-45, 416-446), read-loop
  payload decoding (main.mm:2338-2603).
- `packages/flutter_cef_macos/macos/Classes/FlutterCefPlugin.swift` — channel
  verb dispatch (`handle`, FlutterCefPlugin.swift:111-242) and native->Dart
  events (`emit` sites, FlutterCefPlugin.swift:359-430, 490, 521, 531, 541,
  554-558).
- `packages/flutter_cef_macos/macos/Classes/CefWebSession.swift:28-73` and
  `CefProfileHost.swift:21-42` — the Swift copies of the opcode table (must
  match main.mm; they do).
- `lib/src/cef_web_controller.dart` — the exact channel-arg maps Dart sends
  (cited per verb below).

The Windows host + plugin speak EXACTLY this protocol with **one payload
difference**: `kOpPresent` (see below). Opcode numbers, framing, byte order,
and every other payload are copied verbatim. Protocol version byte = **3**
(main.mm:108, CefProfileHost.swift:42).

---

## 1. IPC framing (byte stream over the named pipe)

Identical to macOS (main.mm:40-45, SendFrame main.mm:416-446, reader
main.mm:2338-2357):

```
[u32 bodyLen BE][u32 browserId BE][u8 opcode][payload...]
```

- `bodyLen` = 4 (browserId) + 1 (opcode) + payloadLen — counts every byte
  after the length prefix.
- Guard on read: `5 <= bodyLen <= 64 MiB`, else the stream is desynced —
  log + tear down the whole process (main.mm:2343-2351).
- `browserId` is the PLUGIN-assigned wire id (>= 1). `browserId 0` =
  process/profile level (`kOpReady`, process-level `kOpLog`, inbound
  `kOpShutdown`) (main.mm:41-43).
- ALL multi-byte integers are BIG-ENDIAN, including `f64` (IEEE-754 double,
  BE byte order — `ReadF64BE`/`WriteF64BE`, see main.mm ReadU32BE:476).
- Writes are assembled into one contiguous frame and written atomically
  under a write mutex, so a partial write never desyncs the peer
  (main.mm:431-445).
- Transport on Windows: named pipe `\\.\pipe\flutter_cef_<pid>_<counter>`,
  `PIPE_TYPE_BYTE | PIPE_READMODE_BYTE`, single instance; plugin is the
  server (`CreateNamedPipeW`), cef_host connects with `CreateFileW`
  (+ `SECURITY_SQOS_PRESENT | SECURITY_ANONYMOUS`). Same framing on top.
- **OVERLAPPED I/O is REQUIRED on any pipe end that reads and writes from
  different threads** (empirical, cef_host + pipe_probe 2026-07-20): Windows
  serializes I/O on a synchronous pipe file object, so a dedicated reader
  thread's pending blocking `ReadFile` makes every `WriteFile` on the same
  handle queue behind it. In cef_host that froze the CEF UI thread inside
  `SendFrame(kOpCreated)`, stalled `CefRunMessageLoop`, and every Chromium
  child process died with "Terminating current process after 15 seconds with
  no connection" (no renderer/GPU/network, browsers never created). Fix:
  open/create the handle with `FILE_FLAG_OVERLAPPED` and run all reads AND
  writes as event-based overlapped ops (`cef_host_win.cc` `OverlappedIo`).
  The plugin's server end (`CreateNamedPipeW` + reader thread + writes from
  the platform thread) has the identical shape and MUST also pass
  `FILE_FLAG_OVERLAPPED`. A Unix socket fd is full-duplex, so the macOS
  reference never encounters this.
- Unknown opcode at either end: log ONCE per opcode value and drop the
  frame — never kill the stream (main.mm:2583-2598).

## 2. Opcode table (numbers verbatim from main.mm:111-164)

Direction `H<-C` = cef_host -> plugin (event), `H->C` = plugin -> cef_host
(command). Payload layouts are exactly the macOS ones except where marked
**WINDOWS**.

### cef_host -> plugin (0x01-0x1d)

| Op | Name | Payload | Source |
|---|---|---|---|
| 0x01 | kOpPresent | **WINDOWS**: `{u64 bridgeHandle BE}{u32 srcW BE}{u32 srcH BE}` = 16 bytes. bridgeHandle = the DXGI **legacy** shared handle (`IDXGIResource::GetSharedHandle`) of the host-minted `MISC_SHARED` bridge texture; srcW/srcH = the PHYSICAL px dims of the frame actually composited (the size-gate signal). macOS reference is 12 bytes `{u32 iosurfaceId}{u32 srcW}{u32 srcH}` — same semantics, different token width. | main.mm:654-665 (semantics + size gate), SPIKES.md S1/S4, LAW 10 |
| 0x02 | kOpReady | `{u8 readyFlags}{u8 protocolVersion}` on browserId 0. readyFlags bit0 = ad-hoc/mock-keychain build (macOS-only concern; Windows sends 0). protocolVersion = 3. Sent from `OnContextInitialized`, BEFORE any browser exists. | main.mm:1664-1682 |
| 0x03 | kOpCursor | `{u32 cef_cursor_type_t}` | main.mm:1456-1466 |
| 0x04 | kOpLog | `{utf8 message}` (browserId 0 = process-level) | main.mm:448-450 |
| 0x05 | kOpLoadState | `{u8 loading}{u8 canGoBack}{u8 canGoForward}` | main.mm:115, 456-462 |
| 0x06 | kOpTitle | `{utf8 title}` | main.mm:116 |
| 0x07 | kOpUrl | `{utf8 main-frame url}` | main.mm:117 |
| 0x08 | kOpLoadErr | `{u32 code}{utf8 "url\ntext"}` | main.mm:118, 464-474 |
| 0x09 | kOpConsole | `{u32 level}{utf8 "source:line\tmsg"}` | main.mm:119 |
| 0x0a | kOpPageStart | `{utf8 url}` main frame load started | main.mm:120 |
| 0x0b | kOpPageFinish | `{utf8 url}` main frame load finished | main.mm:121 |
| 0x0c | kOpProgress | `{u32 percent 0-100}` | main.mm:122, 1396 |
| 0x0d | kOpNewWindow | `{utf8 url}` popup / target=_blank | main.mm:123 |
| 0x0e | kOpFindResult | `{u32 count}{u32 activeOrdinal}{u8 final}` = 9 bytes | main.mm:124, 1274 |
| 0x0f | kOpJsDialog | `{u32 id}{u32 type}{u32 msgLen}{msg utf8}{defaultText utf8}` | main.mm:125, 1300 |
| 0x16 | kOpEvalResult | `{utf8 "id:json"}` (runJavaScriptReturningResult) | main.mm:126 |
| 0x17 | kOpChannelMsg | `{utf8 "name:message"}` JS channel -> host | main.mm:127 |
| 0x18 | kOpDownload | `{utf8 suggestedName}` a download started | main.mm:128 |
| 0x19 | kOpImeBounds | `{u32 x}{u32 y}{u32 w}{u32 h}` caret rect (DIP) | main.mm:129, 1050 |
| 0x1a | kOpCookies | `{u32 id}{utf8 json-array}` visitAllCookies result | main.mm:130 |
| 0x1b | kOpTargetId | `{utf8 targetId}` this browser's CDP targetId (reply to 0x36) | main.mm:131 |
| 0x1c | kOpCreated | `{}` OnAfterCreated — browser is up (create pacer advance) | main.mm:132, 1406 |
| 0x1d | kOpCreateFailed | `{}` async CreateBrowser dispatch failed — drop the session | main.mm:133, 1705 |

### plugin -> cef_host (0x10-0x38)

Payload minimums are enforced host-side exactly as the macOS read loop does
(cited); short frames are dropped per-op, not fatal.

| Op | Name | Payload | Source |
|---|---|---|---|
| 0x10 | kOpPointer | `{u8 type}{u8 button}{u8 clickCount}{u8 pad}{u32 modifiers}{f64 x}{f64 y}{f64 dx}{f64 dy}` = 40 bytes. type: 0=move 1=down 2=up 3=wheel 4=leave; button: 0=left 1=middle 2=right. x/y logical (DIP). | main.mm:2560-2570 |
| 0x11 | kOpResize | `{u32 w}{u32 h}[{f64 dpr}]` — plen>=8; dpr present iff plen>=16, `0`/absent = unchanged; guard `0 < dpr <= 8` else treat as 0. Producer-allocates: no surface id. EVERY WasResized discards CEF's frame pool (LAW 4). | main.mm:135, 2384-2394 |
| 0x12 | kOpKey | `{u8 type}{u8 pad×3}{u32 modifiers}{u32 windowsKeyCode}{u32 nativeKeyCode}{u32 character}` = 20 bytes. type: 0=rawkeydown 2=keyup 3=char. wkc/nkc are i32 stored as u32 BE. | main.mm:136, 2571-2582 |
| 0x13 | kOpCreateBrowser | `{u32 w}{u32 h}{f64 dpr}{utf8 url}` (plen>=16); frame browserId = the NEW wire id; producer-allocates (no surface id); empty url -> about:blank; guard `0 < dpr <= 8` else 1.0. | main.mm:137, 2364-2376 |
| 0x14 | kOpShutdown | `{}` tear down the whole PROCESS (all browsers); browserId 0. | main.mm:138, 2381-2383 |
| 0x15 | kOpDisposeBrowser | `{}` close ONE browser (target = frame browserId); process survives. | main.mm:139, 2377-2380 |
| 0x20 | kOpNavigate | `{utf8 url}` — do NOT require a bound slot; resolve by wire id on the UI thread (a nav right behind a queued create must not drop). | main.mm:140, 2395-2402 |
| 0x21 | kOpReload | `{}` | main.mm:141 |
| 0x22 | kOpStop | `{}` | main.mm:142 |
| 0x23 | kOpBack | `{}` | main.mm:143 |
| 0x24 | kOpForward | `{}` | main.mm:144 |
| 0x25 | kOpExecuteJs | `{utf8 code}` | main.mm:145 |
| 0x26 | kOpSetZoom | `{f64 level}` (factor = 1.2^level) | main.mm:146, 2434-2439 |
| 0x27 | kOpFind | `{u8 fwd}{u8 matchCase}{u8 findNext}{utf8 text}` (plen>=3) | main.mm:147, 2452-2459 |
| 0x28 | kOpStopFind | `{u8 clearSelection}` (absent = 1) | main.mm:148, 2460-2465 |
| 0x29 | kOpJsDialogResp | `{u32 id}{u8 ok}{utf8 text}` (plen>=5) | main.mm:149, 2466-2474 |
| 0x2a | kOpEvalReturning | `{u32 id}{utf8 code}` (plen>=4) | main.mm:150, 2475-2482 |
| 0x2b | kOpAddChannel | `{utf8 name}` — do NOT require a bound slot (registers process-global; injected on load). | main.mm:151, 2483-2494 |
| 0x2c | kOpSetCookie | `{utf8 url\0name\0value\0domain\0path[\0secure(0|1)\0httpOnly(0|1)\0sameSite(unspecified|none|lax|strict)]}` (NUL-separated, pad missing fields to 8; hosts older than the attribute fields read only the first five) | main.mm:152, 2495-2510 |
| 0x2d | kOpClearCookies | `{}` delete all cookies | main.mm:153 |
| 0x2e | kOpVisitCookies | `{u32 id}{utf8 url}` enumerate (url empty = all) | main.mm:154, 2515-2522 |
| 0x2f | kOpDeleteCookie | `{utf8 url\0name}` delete one | main.mm:155, 2523-2531 |
| 0x30 | kOpImeSetComp | `{utf8 text}` IME composition update | main.mm:156 |
| 0x31 | kOpImeCommit | `{utf8 text}` commit composed text | main.mm:157 |
| 0x32 | kOpImeCancel | `{}` cancel composition | main.mm:158 |
| 0x33 | kOpShowDevTools | `{}` open DevTools in a window | main.mm:159 |
| 0x34 | kOpLoadTrusted | `{utf8 url}` host content-load, exempt from allowlist; do NOT require a bound slot (same as 0x20). | main.mm:160, 2403-2411 |
| 0x35 | kOpSetVisible | `{u8 visible}` (absent = 1) -> `WasHidden(!visible)` | main.mm:161, 2446-2451 |
| 0x36 | kOpResolveTargetId | `{}` resolve this browser's CDP targetId -> kOpTargetId | main.mm:162 |
| 0x37 | kOpInvalidate | `{}` force a repaint (`Invalidate(PET_VIEW)`) to re-kick a stalled first frame | main.mm:163 |
| 0x38 | kOpEditCommand | `{u8 cmd}` focused-frame edit command: 0=copy 1=cut 2=paste 3=selectAll 4=undo 5=redo | main.mm:164, 2440-2445 |

Reserved (do NOT reuse): `0x1e` was earmarked `kOpPresentV2` by PLAN §4.3
stage-1; the slice instead reuses `kOpPresent 0x01` with the Windows payload
(LAW 10) because the Windows plugin is the only peer of the Windows host.

## 3. Method-channel verbs (Dart -> plugin), channel `flutter_cef`

Verb names + arg keys verbatim from FlutterCefPlugin.swift:113-241 and
cef_web_controller.dart (invokeMethod sites). Every arg map carries
`sessionId` (String). SLICE = functional since the P1–P4 vertical slice;
P6 = functional since the profiles/cookies slice; P7 = functional since the
JS-bridge/dialogs/find/zoom/downloads slice (see §7); IMPL\* = native
implementation present but not yet verified on Windows OSR; STUB = still a
reply success/null + `OutputDebugString` warning, never an error.

| Verb | Args (beyond sessionId) | Returns | Maps to | Slice? | Source |
|---|---|---|---|---|---|
| create | url:String, width:int, height:int, dpr:double, allowedSchemes:String? (csv, omit-when-empty), enableCdp:bool? (omit-when-false), agentControl:bool? (omit-when-false), profile:String? (omit-when-empty) | `{textureId:int, width:int, height:int, cdpPort:int}` | spawn host (if needed) + kOpCreateBrowser 0x13 | SLICE | Swift:255-446, controller:506-523 |
| navigate | url:String | null | 0x20 | SLICE | Swift:617-622, controller:566 |
| loadTrusted | url:String | null | 0x34 | SLICE (stub-ok) | Swift:626-631, controller:634 |
| resize | width:int, height:int, dpr:double | `{textureId:int}` (or null if unknown session) | 0x11 | SLICE | Swift:633-641, controller:874 |
| getFrameSurface | — | `{surfaceId:int, width:int, height:int}` (physical px) or null | plugin-local | STUB | Swift:649-658 |
| dispose | — | null | 0x15 (last browser: 0x14 + host teardown) | SLICE | Swift:660-663, controller:530/948 |
| pointer | type:int, button:int, clickCount:int, modifiers:int, x:double, y:double, dx:double, dy:double | null | 0x10 | SLICE | Swift:730-740, controller:895 |
| key | type:int, modifiers:int, windowsKeyCode:int, nativeKeyCode:int, character:int | null | 0x12 | SLICE | Swift:742-752, controller:919 |
| reload | — | null | 0x21 | SLICE | Swift:122 |
| stop | — | null | 0x22 | SLICE | Swift:123 |
| goBack | — | null | 0x23 | SLICE | Swift:124 |
| goForward | — | null | 0x24 | SLICE | Swift:125 |
| executeJavaScript | code:String | null | 0x25 | SLICE | Swift:126-130 |
| setZoomLevel | level:double | null | 0x26 | P7 | Swift:131-133 |
| editCommand | command:int | null | 0x38 | SLICE | Swift:134-136 |
| setVisible | visible:bool | null | 0x35 | SLICE | Swift:137-139 |
| find | text:String, forward:bool, matchCase:bool, findNext:bool | null | 0x27 | P7 | Swift:140-148 |
| stopFind | clearSelection:bool | null | 0x28 | P7 | Swift:149-151 |
| respondJsDialog | id:int, ok:bool, text:String | null | 0x29 | P7 | Swift:152-158 |
| evalReturning | id:int, code:String | null | 0x2a | P7 | Swift:159-165 |
| addJavaScriptChannel | name:String | null | 0x2b | P7 | Swift:166-170 |
| setCookie | url, name, value, domain, path, sameSite : String; secure, httpOnly : bool | null | 0x2c | P6 | Swift:171-179 |
| clearCookies | — | null | 0x2d | P6 | Swift:180-182 |
| visitCookies | id:int, url:String | null | 0x2e | P6 | Swift:183-188 |
| deleteCookie | url:String, name:String | null | 0x2f | P6 | Swift:189-194 |
| showDevTools | — | null | 0x33 | IMPL\* | Swift:195-197 |
| enableAgentControl | — | `{wsUrl:String, token:String, port:int}` or FlutterError (`no_agent_control` when the session wasn't created with `agentControl:true`) | CDP relay (§8) | P9 | Swift:198-217, controller:595-605 |
| disableAgentControl | — | null | CDP relay (§8) | P9 | Swift:218-225, controller:609-610 |
| showEmojiPicker | — | null | macOS-only (Character Palette) | STUB | Swift:226-230 |
| imeSetComposition | text:String | null | 0x30 | IMPL\* | Swift:231-233 |
| imeCommitText | text:String | null | 0x31 | IMPL\* | Swift:234-236 |
| imeCancelComposition | — | null | 0x32 | IMPL\* | Swift:237-239 |

macOS replies `FlutterMethodNotImplemented` for unknown verbs
(Swift:240); the WINDOWS SLICE deviates deliberately: unknown/unimplemented
verbs reply success(null) + `OutputDebugString` so the example app never sees
a MissingPluginException-style error (slice contract).

## 4. Events (plugin -> Dart), channel `flutter_cef`

Method names + payload keys verbatim from the Swift `emit` sites. Every
payload carries `sessionId:String`. `invokeMethod` MUST run on the platform
thread (marshal from the reader thread).

| Method | Payload (beyond sessionId) | From opcode | Source |
|---|---|---|---|
| cursor | cursor:int (cef_cursor_type_t) | 0x03 | Swift:359-361 |
| loadingState | isLoading:bool, canGoBack:bool, canGoForward:bool | 0x05 | Swift:362-367 |
| title | title:String | 0x06 | Swift:368-370 |
| url | url:String | 0x07 | Swift:371-373 |
| loadError | code:int, url:String, text:String (split payload at first '\n') | 0x08 | Swift:374-378 |
| consoleMessage | level:int, message:String | 0x09 | Swift:379-383 |
| pageStarted | url:String | 0x0a | Swift:384-386 |
| pageFinished | url:String | 0x0b | Swift:387-389 |
| progress | progress:int | 0x0c | Swift:390-392 |
| newWindow | url:String | 0x0d | Swift:393-395 |
| findResult | count:int, activeMatchOrdinal:int, isFinal:bool | 0x0e | Swift:396-401 |
| jsDialog | id:int, type:int, message:String, defaultText:String | 0x0f | Swift:402-407 |
| evalResult | payload:String ("id:json") | 0x16 | Swift:408-410 |
| channelMessage | payload:String ("name:message") | 0x17 | Swift:411-413 |
| download | suggestedName:String | 0x18 | Swift:414-416 |
| imeCompositionBounds | x:int, y:int, w:int, h:int | 0x19 | Swift:417-421 |
| cookies | id:int, json:String | 0x1a | Swift:422-424 |
| onSurface | surfaceId:int, width:int, height:int (physical px) — Windows: surfaceId = the bridge-handle token as int64 | 0x01 (on surface (re)alloc) | Swift:425-433 |
| processGone | reason:String — "crashed" \| "locked" (host exit code 2) \| "createFailed" (0x1d) \| "respawnFailed" \| "protocolMismatch(host=vN)" | host death / 0x1d / handshake | Swift:490, 521, 531, 541, 601 |
| paintStalled | — | watchdog (no 0x01 after create + 0x37 re-kick) | Swift:554-558 |

## 5. Handshake + lifecycle rules (carry-over)

- Plugin sends NOTHING until it receives `kOpReady`; it then checks
  `protocolVersion == 3` and refuses (teardown + `processGone
  protocolMismatch`) on skew (main.mm:100-108, Swift:528-533).
- Host exit code 2 after a `kOpLog "profile-locked"` = profile already open
  elsewhere -> `processGone reason:"locked"` (main.mm:2786-2806, Swift:521).
- Present size-gate (LAW 4): the plugin promotes a presented bridge
  handle to the Flutter texture ONLY when `{srcW,srcH}` matches the expected
  `round(logical*dpr)` for the current size (±1 px); until then it keeps
  serving the previous texture (main.mm:640-665 rationale).
- Bridge-handle identity (LAW 3): the host-minted legacy handle is the
  identity Flutter sees; never key anything on CEF's per-callback
  `shared_texture_handle` values (SPIKES.md S4).
- The plugin holds an opened `ID3D11Texture2D` ComPtr on the current bridge
  handle for as long as it feeds it to Flutter (LAW 6 / S1 belt-1).
- cef_host args: `--ipc=<pipe name>` `--profile-dir=<abs path>` `--ephemeral`
  `--allowed-schemes=<csv>` (§6) and — for agent control (§8) — `--cdp-io-pipes=
  <read>,<write>` (cf. macOS args main.mm:32-38; `--cdp-port` TCP CDP is still
  post-slice — the Dart-side `enableCdp`+named-profile assert already blocks the
  unsafe combination, so `cdpPort` stays 0 on Windows).

## 6. Profile model (P6 foundation + P11 profile slice)

The plugin owns ONE `cef_host` process per **profile key** and multiplexes N
browsers over it (one wire browserId each) — the macOS
`CefProfileHost`/`FlutterCefPlugin` model transcribed to Windows. Key =
the sanitized `profile` name for a named profile, or `"~ephemeral~"+sessionId`
for the default (throwaway) case, so every ephemeral session gets its own host
and every view with the same non-null `profile` shares one host → one cookie
jar → one login (macOS: FlutterCefPlugin.swift:326-327, CefProfileHost.swift:1-12).

### 6.1 Profile-dir resolution (plugin side)

The `create` verb's `profile` arg (String, omit-when-empty — §3) selects the
mode. The plugin resolves an on-disk cache dir and always passes it as
`--profile-dir=<abs path>` (macOS `resolveProfileDir`,
FlutterCefPlugin.swift:697-728):

- **Ephemeral** (`profile` absent/empty): a unique throwaway dir
  `%TEMP%\flutter_cef_ephem_<uuid>`, created + removed on host shutdown, and the
  host is launched WITH `--ephemeral` (macOS uses `flutter_cef_ephem_<uuid>` +
  `--ephemeral=1`, FlutterCefPlugin.swift:704-708 / CefProfileHost.swift:286-288).
- **Named / persistent** (`profile` non-empty): a stable dir
  `%LOCALAPPDATA%\flutter_cef\profiles\<sanitized-name>`, launched WITHOUT
  `--ephemeral`. Sanitize the name to `[A-Za-z0-9._-]` (every other char → `_`),
  and neutralize an all-dots leaf (`.`/`..`/`...`) to `_` so it can't escape the
  `profiles\` container (macOS FlutterCefPlugin.swift:710-717 — mirror this
  exactly, including the all-dots guard).

  NOTE — Windows path root differs from macOS DELIBERATELY: macOS uses
  `<Application Support>/<bundleId>/flutter_cef/profiles/<name>`; Windows uses
  `%LOCALAPPDATA%\flutter_cef\profiles\<name>` (no per-app bundleId segment).
  **Multi-app shared-profiles-root caveat**: every flutter_cef app for a given
  Windows user therefore shares this one `profiles\` root, so a `profile: 'work'`
  in app A and app B resolve to the SAME dir (analogous to the macOS
  shared-"Chromium Safe Storage"-keychain caveat). Co-locate only
  mutually-trusting apps on a shared profile name.

- **DACL**: create the named-profile dir (and its `profiles\` ancestor) with a
  current-user-SID-protected DACL — the same pattern `ipc_pipe.cpp` uses for the
  pipe (audit fix #3). This is the Windows analogue of macOS's `0700`
  owner-only chmod (FlutterCefPlugin.swift:706/722/726). Re-apply on an existing
  leaf from a prior run (macOS re-chmods at :726).

### 6.2 Host side (`--profile-dir` → `root_cache_path`)

`cef_host` maps `--profile-dir` to `CefSettings.root_cache_path` and sets
`settings.persist_session_cookies = true` (macOS main.mm:2854-2869). One
`root_cache_path` is shared by every browser in the process — that is what makes
the login shared. `persist_session_cookies` keeps session cookies across relaunch
(harmless for ephemeral, required for "stay signed in" on a named profile). The
`--ephemeral` flag (main.mm:2726, `is_ephemeral`) marks the throwaway case so the
host's guards (CDP-on-named-profile refusal, and on macOS the mock-keychain
downgrade) fire only for a REAL persistent profile — `--profile-dir` is set for
both.

### 6.3 At-rest encryption — Windows DPAPI (NO macOS-style downgrade)

**KEY Windows security fact (SPIKES.md S2):** OSCrypt on Windows encrypts the
cookie store with **DPAPI**, which is **always available and
signing-independent**. So the macOS rule "ad-hoc build → mock keychain → downgrade
a named profile to ephemeral (unless `FLUTTER_CEF_ALLOW_INSECURE_PROFILE=1`)"
has **NO Windows analogue** — there is no mock-keystore state and no downgrade.
A named profile on Windows simply persists, encrypted at rest, regardless of code
signing. Concretely: `kOpReady`'s `readyFlags` bit0 (ad-hoc/mock-keychain build)
is **macOS-only; the Windows host always sends 0** (§2, main.mm:1664-1682), and
there is no `onInsecureProfileRefused` / re-home-to-ephemeral path on Windows.

**Caveat (state it, do not hide it):** DPAPI's user-tier protection is
**same-user-readable** — any process running as the same Windows user can call
`CryptUnprotectData` and decrypt the store. This is **weaker than the macOS
Keychain**, which can prompt / ACL-scope access. So on Windows the at-rest
guarantee is "protected against other users / offline disk theft, NOT against
other same-user processes." `localStorage`/IndexedDB are plaintext on both
platforms (FileVault/BitLocker is the backstop).

### 6.4 Cookies API (the four verbs + the result event)

Cookies act on the profile's ONE process-wide `CefCookieManager` (the shared
jar §6.1), so a write/clear is visible to every browser in the host. The four
command opcodes and the one result event are fully specified in §2 (byte layouts,
with main.mm cites) and reached from Dart via the verbs in §3/§4 — summarized here:

| Dart (controller) | Verb (§3) | Opcode (§2) | main.mm |
|---|---|---|---|
| `setCookie(url,name,value,domain,path,secure,httpOnly,sameSite)` | `setCookie` | 0x2c `{utf8 url\0name\0value\0domain\0path\0secure\0httpOnly\0sameSite}` (pad to 8) | 2495-2510 |
| `clearCookies()` | `clearCookies` | 0x2d `{}` | 2511-2514 |
| `getCookies({url})` → `List<CefCookie>` | `visitCookies` | 0x2e `{u32 id}{utf8 url}` (empty = all) → **0x1a** `{u32 id}{utf8 json-array}` event | 2515-2522 |
| `deleteCookie(url,name)` | `deleteCookie` | 0x2f `{utf8 url\0name}` | 2523-2531 |

`getCookies` is the only round-trip: the plugin assigns `id`, sends `visitCookies`,
and resolves the Dart `Future` when the `cookies` event (from opcode 0x1a — §4)
arrives carrying the same `id` and a JSON array (`CefCookie.fromJson` per element,
cef_web_controller.dart:741-767). The JSON array shape MUST match macOS
byte-for-byte (main.mm's `DoVisitCookies` serializer) so a page cannot detect a
Windows-vs-macOS divergence.

## 7. JS bridge, JS dialogs, find, zoom, downloads (P7 verb parity)

All opcode numbers and byte layouts are in §2; this section documents the
**string packings** and the **per-session message-router routing** that the P7
verbs depend on, transcribed from main.mm with line cites. The Dart side
(cef_web_controller.dart, cross-platform, unchanged for Windows) parses exactly
these shapes; the Windows host MUST reproduce them byte-for-byte so a page cannot
detect a Windows-vs-macOS divergence.

### 7.1 The message router (CefMessageRouter) — renderer + browser halves

The JS bridge (channels + `runJavaScriptReturningResult`) rides one
`CefMessageRouter` created with the **DEFAULT** `CefMessageRouterConfig`
(`window.cefQuery` / `window.cefQueryCancel`). Browser-side and renderer-side
MUST use the SAME config or queries never route.

- **macOS reference:** browser-side router lives in the `Handler` (main.mm —
  `router_->OnProcessMessageReceived`, main.mm:1495-1501; `OnQuery`,
  main.mm:1472-1494). The renderer half is a SEPARATE process
  (`process_helper.mm`): `CefMessageRouterRendererSide` with the default config,
  wired in `OnContextCreated` / `OnContextReleased` / `OnProcessMessageReceived`.
- **Windows:** there is no separate helper exe — the SAME `cef_host.exe` is
  re-executed as the render subprocess via `CefExecuteProcess`, so the
  renderer-side router lives in cef_host's `CefApp::GetRenderProcessHandler`
  (cef_host_win.cc), branched by process type. Both halves still use the DEFAULT
  config (contract, not Dart-visible).

### 7.2 JS channels — `addJavaScriptChannel` / `removeJavaScriptChannel`

Page → host. The shim is injected NATIVELY (there is no Dart-injected shim):

- `addJavaScriptChannel(name)` → verb `addJavaScriptChannel` → **0x2b
  kOpAddChannel** `{utf8 name}` (§2). The host validates `name` is a JS
  identifier (`IsValidChannelName`, main.mm:362-375; ≤64 chars,
  `[A-Za-z_$][A-Za-z0-9_$]*`) and registers it process-globally in `g_channels`
  (`DoAddChannel`, main.mm:2019-2035). Invalid names are dropped + logged, never
  fatal. Dart pre-validates with the same regex (cef_web_controller.dart:165,
  669-671) and re-registers every channel on `create()`
  (cef_web_controller.dart:541-544) so add-before-mount works.
- **Shim injection** (`InjectChannelShim`, main.mm:377-384) — injected into the
  **MAIN frame ONLY** on every `OnLoadStart` (main.mm:1337-1343) and into the
  current frame at registration time (main.mm:2034). The injected source is
  exactly:
  ```js
  window['<name>']={postMessage:function(m){window.cefQuery({request:'ch:<name>:'+String(m),
    persistent:false,onSuccess:function(){},onFailure:function(){}});}};
  ```
- **Page → host delivery.** `window.<name>.postMessage(m)` calls
  `window.cefQuery` with `request = "ch:<name>:<m>"`. `OnQuery`
  (main.mm:1487-1492) refuses subframe queries (privileged bridge; 403), strips
  the `"ch:"` prefix (3 bytes), and sends **0x17 kOpChannelMsg** `{utf8
  "name:message"}` (main.mm:1489). The plugin emits `channelMessage
  {payload:"name:message"}` (§4); Dart splits at the FIRST `:` and dispatches to
  the registered handler (`_handleChannelMessage`, cef_web_controller.dart:336-340)
  — colons in the message body are preserved.
- **Per-session routing (mandatory — channel_probe_shared).** `OnQuery` stamps
  `slot_->browser_id` (the originating browser) on kOpChannelMsg
  (main.mm:1489), and the plugin fans the event to only that session's Dart
  channel handler. A message from tile A's page reaches A's handler, never B's,
  even on a shared host. This is an information-sharing boundary (the channel
  NAME is process-global), not a message-spoofing one.
- `removeJavaScriptChannel(name)` is **Dart-local** (cef_web_controller.dart:683-685):
  it stops delivery to the handler but does NOT tear down the page-side shim
  (which is process-global on a shared profile), so the page may still post — those
  messages are dropped. No opcode.

### 7.3 `runJavaScriptReturningResult` — the eval round-trip

- `runJavaScriptReturningResult(code)` assigns an `id` and sends verb
  `evalReturning` → **0x2a kOpEvalReturning** `{u32 id}{utf8 code}` (§2,
  cef_web_controller.dart:655-662). The host (`DoEvalReturning`,
  main.mm:2001-2018) SPLICES `code` into a `window.cefQuery` call (not `eval()`,
  so it survives a strict page CSP) that JSON-stringifies
  `{ok:true,v:(<code>)}` on success or `{ok:false,v:String(e)}` on throw, with
  `request = "eval:<id>:<json>"`.
- `OnQuery` (main.mm:1481-1486) refuses subframe queries (403), strips the
  `"eval:"` prefix (5 bytes), and sends **0x16 kOpEvalResult** `{utf8
  "id:json"}` (main.mm:1483). The plugin emits `evalResult
  {payload:"id:json"}` (§4); Dart splits at the FIRST `:`, matches the pending
  completer by `id`, and JSON-decodes the tail: `ok:true` completes with `v`,
  `ok:false` completes with an `Exception('<v>')` (`_handleEvalResult`,
  cef_web_controller.dart:297-313).
- In-flight evals are failed (never leaked) on `pageStarted`
  (cef_web_controller.dart:224-228), `processGone`, and `dispose`
  (cef_web_controller.dart:317-324).
- `executeJavaScript(code)` is the fire-and-forget sibling → **0x25
  kOpExecuteJs** `{utf8 code}` (§2), no result event.

### 7.4 JS dialogs — alert / confirm / prompt

- Host → page request: `CefJSDialogHandler::OnJSDialog` (main.mm:1279-1303)
  assigns a per-slot `id`, stashes the `CefJSDialogCallback`, and sends **0x0f
  kOpJsDialog** `{u32 id}{u32 type}{u32 msgLen}{msg utf8}{defaultText utf8}`
  (main.mm:1291-1301). `type`: 0=alert, 1=confirm, 2=prompt (main.mm:1286-1288).
  The plugin emits `jsDialog {id,type,message,defaultText}` (§4).
- Dart (`_handleJsDialog`, cef_web_controller.dart:345-382) routes by `type` to
  `onJavaScriptAlertDialog` / `onJavaScriptConfirmDialog` /
  `onJavaScriptTextInputDialog`, then replies verb `respondJsDialog
  {id, ok, text}` → **0x29 kOpJsDialogResp** `{u32 id}{u8 ok}{utf8 text}` (§2).
  Unset handlers fall closed to sensible defaults (alert dismissed, confirm→OK,
  prompt→defaultText). A throwing handler fails closed (`ok=false`) but is
  reported via `FlutterError.reportError` (not silently swallowed).
- Host applies the answer: `DoJsDialogResp` (main.mm:1994-2000) looks up the
  stashed callback by `id` and calls `Continue(ok, text)`, which returns the
  page's `alert`/`confirm`/`prompt`. `OnBeforeUnloadDialog` always allows
  navigation (main.mm:1304-1309).

### 7.5 Find-in-page

- `find(text, forward, matchCase, findNext)` → verb `find` → **0x27 kOpFind**
  `{u8 fwd}{u8 matchCase}{u8 findNext}{utf8 text}` (§2,
  cef_web_controller.dart:858-868; host read main.mm:2452-2459 → `DoFind`).
- `stopFind(clearSelection)` → verb `stopFind` → **0x28 kOpStopFind** `{u8
  clearSelection}` (absent = 1) (§2, cef_web_controller.dart:871-872; host
  main.mm:2460-2465 → `DoStopFind`, main.mm:1991-1993).
- Result event: `CefFindHandler::OnFindResult` (main.mm:1260-1275) sends **0x0e
  kOpFindResult** `{u32 count}{u32 activeOrdinal}{u8 final}` = 9 bytes
  (main.mm:1265-1274). The plugin emits `findResult
  {count, activeMatchOrdinal, isFinal}` (§4); Dart delivers a `CefFindResult`
  to `onFindResult` (cef_web_controller.dart:239-245). ⌘F/Ctrl+F is surfaced to
  the host via `CefWebView.onFind` (cef_web_view.dart:571-579) — the widget has
  no find bar of its own.

### 7.6 Content zoom

- `setZoomLevel(level)` → verb `setZoomLevel` → **0x26 kOpSetZoom** `{f64
  level}` (§2, cef_web_controller.dart:822-823; host read main.mm:2434-2438 →
  `DoSetZoom`). `level` is a Chromium zoom LEVEL; the factor is `1.2^level`
  (0 = 100%). The view wires Ctrl/⌘ +/-/0 to step it (cef_web_view.dart:559-570).
  No result event.

### 7.7 Downloads

- `CefDownloadHandler::OnBeforeDownload` (main.mm:1251-1257) allows the download
  (CEF blocks downloads without a handler), continues with an empty path +
  `show_dialog=true` (native Save panel), and sends **0x18 kOpDownload** `{utf8
  suggestedName}` (main.mm:1254). The plugin emits `download {suggestedName}`
  (§4); Dart invokes `onDownload(suggestedName)`
  (cef_web_controller.dart:255-257). Informational only (no reply verb).

## 8. Agent control — CDP-over-pipe + the token-gated loopback relay (P9)

An external CDP client (Playwright via `connectOverCDP`, agent-browser) drives a
live, logged-in tile **without** an open debug port: Chromium speaks CDP over an
inherited pipe (`--remote-debugging-pipe` + `--remote-debugging-io-pipes`,
NUL-framed JSON), and a small token-gated LOOPBACK HTTP+WebSocket relay bridges a
standard CDP client to that pipe. Transcribed from the macOS reference
`CdpRelay.swift` (the canonical relay) + `CefProfileHost.swift`
(launchViaPosixSpawn / readCdpLoop / enableAgentControl); the Windows spawn is
the S3 recipe (`flutter_cef_spikes/s3`). **SINGLE-TILE scope:** one relay per
host (raw browser-level passthrough — the pipe carries exactly one page target);
the per-tile Target-domain filter + N-relay CDP-id multiplex (CEF-2b,
`CdpRelay.swift:560-884`) is a documented follow-up (the `scope_target_id` seam
in `windows/cdp_relay.h`).

### 8.1 Launch — the CDP pipe (S3 recipe)

The `create` arg `agentControl:true` (§3) switches the host launch mechanism.
`HostProcess::Spawn(agent_control=true)` (windows/host_process.cpp):

- `CreatePipe` × 2 (anonymous). `cmd_pipe`: parent writes CDP → child reads.
  `out_pipe`: child writes CDP → parent reads.
- `SetHandleInformation(HANDLE_FLAG_INHERIT)` on **only the two child-side ends**;
  a `STARTUPINFOEX` `PROC_THREAD_ATTRIBUTE_HANDLE_LIST` naming exactly those two
  (so nothing else leaks). This **composes** with the existing spawn, which
  inherits nothing: the IPC pipe is connected by NAME (`CreateFileW`) and the Job
  Object is assigned post-spawn — neither is an inherited handle. `bInheritHandles
  = TRUE` + `EXTENDED_STARTUPINFO_PRESENT` are added only on this path; the
  non-agent spawn stays byte-identical (S2/S3 confirm bootstrap preserves the
  handle list).
- The child gets `--cdp-io-pipes=<childRead>,<childWrite>` (decimal HANDLE
  values). cef_host's `OnBeforeCommandLineProcessing` (browser process only)
  translates it into Chromium's `--remote-debugging-pipe` +
  `--remote-debugging-io-pipes=<childRead>,<childWrite>`. Mirrors macOS main.mm's
  `--cdp-pipe` → `remote-debugging-pipe` injection (fds 3/4 there; explicit HANDLE
  values here).
- The plugin keeps the two PARENT-side ends (`CdpTransport::read`/`write`) and
  runs an always-on `CdpReadLoop` that splits the NUL-framed CDP stream and fans
  each message to the current relay (mirrors `CefProfileHost.readCdpLoop` +
  `deliverCdpToRelays`). `cdpPort` stays 0 — there is no listening socket.

### 8.2 The relay (`windows/cdp_relay.{h,cpp}`, winsock + bcrypt)

A loopback HTTP+WS server (`socket`/`bind` `127.0.0.1:0` → OS-assigned ephemeral
port, accept thread, detached per-connection handlers), a direct winsock port of
`CdpRelay.swift`:

- **Discovery (token-free):** `GET /json/version` · `/json` · `/json/list`
  advertise `webSocketDebuggerUrl = ws://127.0.0.1:<port>/devtools/browser` (the
  token is NOT in the discovery response).
- **Upgrade (token-REQUIRED):** RFC-6455 handshake; `Sec-WebSocket-Accept =
  base64(SHA-1(key + GUID))` via BCrypt. The upgrade is rejected **401** without a
  valid `Authorization: Bearer <token>` header (a `?token=` query is an accepted
  fallback); constant-time compared. A second concurrent client is **503**'d
  (single active client).
- **Bridge:** masked client text frames → `send_to_pipe` (NUL-framed CDP command
  onto `cmd_pipe`); pipe messages → `DeliverToClient` (unmasked text frame to the
  client). Frame/message cap 64 MiB; ping→pong; close handled.
- **Token:** 24 CSPRNG bytes (`BCryptGenRandom`) hex-encoded (48 chars).

Security posture (matches macOS): loopback only, ephemeral unadvertised port,
mandatory token, single client, and the relay exists **only while the grant is
active** (created by `enableAgentControl`, torn down by `disableAgentControl` /
dispose / host-death). Strictly better than raw Chrome's fixed, always-open,
multi-client `--remote-debugging-port`.

### 8.3 Verbs

- `enableAgentControl` → starts (idempotently) the relay for the session's host
  and returns `{wsUrl, token, port}` — the macOS return shape **exactly**:
  `wsUrl = ws://127.0.0.1:<port>/devtools/browser?token=<token>`
  (`CefProfileHost.endpoint`). Errors `no_agent_control` if the session was not
  created with `agentControl:true`.
- `disableAgentControl` → stops the relay (closes the listener + any client,
  invalidates the token); the tile keeps running. Idempotent. Also torn down on
  `dispose` / host death (the reaper stops the relay, joins the CDP reader, and
  closes the pipe ends).

### 8.4 Deferred (N-tile Target multiplex)

Not implemented in the slice (single-tile is passthrough): `Target.getTargetInfo`
targetId resolution (`kOpResolveTargetId 0x36` → `kOpTargetId 0x1b`, still a
logged drop host-side), the deny-by-default / fail-closed / flatten-only
Target-domain filter, and the per-relay CDP-id rewrite/demux that lets N relays
share one browser-wide pipe. See `CdpRelay.swift:560-884` +
`CefProfileHost.swift:1460-1596` and the filter test vectors
`packages/flutter_cef_macos/macos/Classes/test/CdpRelayFilterTests.swift`.
