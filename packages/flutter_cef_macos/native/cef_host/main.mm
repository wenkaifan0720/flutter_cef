// cef_host — a standalone CEF off-screen-rendering subprocess.
//
// The Flutter host (the flutter_cef macOS plugin) spawns one cef_host per
// PROFILE (persistent or ephemeral) and drives N browsers in it over a
// Unix-socket IPC. For each browser the host allocates an IOSurface-backed
// CVPixelBuffer, registers a FlutterTexture on it, and sends kOpCreateBrowser
// (carrying url/width/height/dpr/iosurface-id). cef_host runs CEF windowless
// (OSR), paints each page into its shared IOSurface, and notifies the host so
// it calls textureFrameAvailable. Because the page renders to an offscreen
// buffer (no NSWindow), it keeps rendering live even when the view is off-screen
// — the whole point of the CEF path. No browser is created at startup; the host
// waits for kOpReady, then issues kOpCreateBrowser per view.
//
// Multi-process is the default (CMake option CEF_MULTI_PROCESS, ON by default,
// defines CEF_HOST_MULTIPROCESS): the CEF helper subprocesses
// (GPU/Renderer/Plugin/Alerts) spawn from Contents/Frameworks, the GPU/Viz
// process composites the page, and OnAcceleratedPaint delivers it as a
// shared-texture IOSurface — crash-isolated, so heavy SPAs survive. Chromium
// 144's Mach-port peer validation (process_requirement.cc -67030) is cleared
// WITHOUT Developer-ID signing: the MACH_PORT_RENDEZVOUS_PEER_VALDATION=0 env
// var (inherited by children) plus
// --disable-features=MachPortRendezvousValidatePeerRequirements,
// MachPortRendezvousEnforcePeerRequirements in the browser process. Build with
// -DCEF_MULTI_PROCESS=OFF for the simpler single-process fallback (software
// OnPaint, no helpers, no peer validation at all).
//
// Those Mach-port shortcuts plus a mock keychain are gated behind the
// CEF_HOST_ADHOC compile flag (ON by default). A signed release builds with
// -DCEF_HOST_ADHOC=OFF, which enforces peer validation and uses the real
// Keychain (OSCrypt) — and so requires correct inside-out Developer-ID signing.
//
// Args (all per-PROCESS / per-profile): --ipc=<path> --cdp-port=<port>
//       --allowed-schemes=<csv> --profile-dir=<abs path>
// --profile-dir maps to settings.root_cache_path (empty/omitted -> a per-pid
// ephemeral temp dir; Swift always supplies it, so the fallback is defensive).
// The per-view args (url/width/height/dpr/iosurface-id) moved into the
// kOpCreateBrowser payload. --cdp-port is rejected upstream when a named profile
// is in use, so persistent profiles never expose the unauthenticated debug port.
//
// IPC wire format: 4-byte big-endian length prefix (bodyLen), then a 4-byte
// big-endian browserId, then [opcode][payload]. bodyLen = 4 + 1 + payloadLen.
// browserId is the Swift-assigned wire id (>=1); browserId 0 = process/profile
// level (kOpReady, process-level kOpLog, inbound kOpShutdown). The full opcode
// table lives in the `kOp*` constants below — each carries its payload layout;
// cef_host -> host are 0x01-0x1a, host -> cef_host 0x10-0x35.

#import <Cocoa/Cocoa.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <vector>

#include <libgen.h>
#include <mach-o/dyld.h>
#include <sys/event.h>
#include <sys/file.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include "include/base/cef_bind.h"
#include "include/base/cef_callback.h"
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_command_line.h"
#include "include/cef_cookie.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_download_handler.h"
#include "include/cef_find_handler.h"
#include "include/cef_jsdialog_handler.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_permission_handler.h"
#include "include/cef_render_handler.h"
#include "include/cef_request_context.h"
#include "include/cef_request_handler.h"
#include "include/cef_task.h"
#include "include/wrapper/cef_closure_task.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"
#include "include/wrapper/cef_message_router.h"

namespace {

// ---- Wire protocol version ----
// Announced in kOpReady's payload (byte 1; byte 0 stays the ready-flags byte) so the
// Swift plugin can REFUSE a host speaking a different protocol instead of silently
// mis-parsing frames (frozen/blank tiles with no breadcrumb). The content-hash
// distribution keeps host + plugin matched on the normal path; this catches the skew
// vectors that bypass it (FLUTTER_CEF_HOST env override, a stale from-source build, a
// stale embedded copy). BUMP THIS on any semantic change to the kOp wire protocol
// below, together with CefProfileHost.protocolVersion (Swift side) — the two must
// stay equal. Hosts predating the handshake send a 1-byte payload and read as v0.
constexpr uint8_t kCefHostProtocolVersion = 7;

// ---- Opcodes ----
constexpr uint8_t kOpPresent = 0x01;
constexpr uint8_t kOpReady = 0x02;
constexpr uint8_t kOpCursor = 0x03;
constexpr uint8_t kOpLog = 0x04;
constexpr uint8_t kOpLoadState = 0x05;  // {loading,back,forward : u8}
constexpr uint8_t kOpTitle = 0x06;      // {utf8}
constexpr uint8_t kOpUrl = 0x07;        // {utf8} main-frame address
constexpr uint8_t kOpLoadErr = 0x08;    // {code:u32}{utf8 "url\ntext"}
constexpr uint8_t kOpConsole = 0x09;    // {level:u32}{utf8 "source:line\tmsg"}
constexpr uint8_t kOpPageStart = 0x0a;  // {utf8 url} main frame load started
constexpr uint8_t kOpPageFinish = 0x0b; // {utf8 url} main frame load finished
constexpr uint8_t kOpProgress = 0x0c;   // {u32 percent 0-100}
constexpr uint8_t kOpNewWindow = 0x0d;  // {utf8 url} popup / target=_blank
constexpr uint8_t kOpFindResult = 0x0e; // {u32 count}{u32 activeOrdinal}{u8 final}
constexpr uint8_t kOpJsDialog = 0x0f;   // {u32 id}{u32 type}{u32 msgLen}{msg}{default}
constexpr uint8_t kOpEvalResult = 0x16; // {utf8 "id:json"} runJavaScriptReturningResult
constexpr uint8_t kOpChannelMsg = 0x17; // {utf8 "name:message"} JS channel -> host
constexpr uint8_t kOpDownload = 0x18;   // {utf8 suggestedName} a download started
constexpr uint8_t kOpImeBounds = 0x19;  // {u32 x}{u32 y}{u32 w}{u32 h} caret rect (DIP)
constexpr uint8_t kOpCookies = 0x1a;    // {u32 id}{utf8 json-array} visitAllCookies result
constexpr uint8_t kOpTargetId = 0x1b;   // {utf8 targetId} -> plugin: this browser's CDP targetId (CEF-2b)
constexpr uint8_t kOpCreated = 0x1c;    // {} H3: OnAfterCreated — browser is up; host's pacer sends the next create
constexpr uint8_t kOpCreateFailed = 0x1d; // {} H7: async CreateBrowser dispatch failed; host drops the session
constexpr uint8_t kOpMediaRequest = 0x1e; // {u32 id}{u32 requested}{utf8 origin} page called getUserMedia and there is NO stored decision -> host prompts
constexpr uint8_t kOpMediaState = 0x1f;   // {u8 videoActive}{u8 audioActive}{u8 setting 0=ask 1=allow} page media status -> URL-bar "in use" / "allowed" indicator
constexpr uint8_t kOpContextMenu = 0x40;  // {u32 id}{utf8 json} right-click in the page: Chromium's OWN menu model + params, for the host to draw in Flutter (OSR has no window to put a native menu in)
constexpr uint8_t kOpPointer = 0x10;
constexpr uint8_t kOpResize = 0x11;          // {u32 w}{u32 h}{f64 dpr} — producer-allocates: no sid
constexpr uint8_t kOpKey = 0x12;
constexpr uint8_t kOpCreateBrowser = 0x13;  // {u32 w}{u32 h}{f64 dpr}{utf8 url}; producer-allocates (no sid); frame browserId = NEW id
constexpr uint8_t kOpShutdown = 0x14;       // {} tear down the whole PROCESS (all browsers); frame browserId 0
constexpr uint8_t kOpDisposeBrowser = 0x15;  // {} close ONE browser (target = frame browserId); process survives
constexpr uint8_t kOpNavigate = 0x20;
constexpr uint8_t kOpReload = 0x21;
constexpr uint8_t kOpStop = 0x22;
constexpr uint8_t kOpBack = 0x23;
constexpr uint8_t kOpForward = 0x24;
constexpr uint8_t kOpExecuteJs = 0x25;  // {utf8 code}
constexpr uint8_t kOpSetZoom = 0x26;    // {f64 level} (factor = 1.2^level)
constexpr uint8_t kOpFind = 0x27;       // {u8 fwd}{u8 matchCase}{u8 findNext}{utf8}
constexpr uint8_t kOpStopFind = 0x28;   // {u8 clearSelection}
constexpr uint8_t kOpJsDialogResp = 0x29;  // {u32 id}{u8 ok}{utf8 text}
constexpr uint8_t kOpEvalReturning = 0x2a;  // {u32 id}{utf8 code}
constexpr uint8_t kOpAddChannel = 0x2b;     // {utf8 name} register a JS channel
constexpr uint8_t kOpSetCookie = 0x2c;      // {utf8 url\0name\0value\0domain\0path[\0secure(0|1)\0httpOnly(0|1)\0sameSite(unspecified|none|lax|strict)]}
constexpr uint8_t kOpClearCookies = 0x2d;   // {} delete all cookies
constexpr uint8_t kOpVisitCookies = 0x2e;   // {u32 id}{utf8 url} enumerate (url empty = all)
constexpr uint8_t kOpDeleteCookie = 0x2f;   // {utf8 url\0name} delete one
constexpr uint8_t kOpImeSetComp = 0x30;     // {utf8 text} IME composition update
constexpr uint8_t kOpImeCommit = 0x31;      // {utf8 text} commit composed text
constexpr uint8_t kOpImeCancel = 0x32;      // {} cancel composition
constexpr uint8_t kOpShowDevTools = 0x33;   // {} or {u32 x}{u32 y} open DevTools in a window; with a point, opened INSPECTING the element there (the right-click "Inspect" path)
constexpr uint8_t kOpLoadTrusted = 0x34;    // {utf8 url} host content-load, exempt from allowlist
constexpr uint8_t kOpSetVisible = 0x35;     // {u8 visible} -> CefBrowserHost::WasHidden(!visible)
constexpr uint8_t kOpResolveTargetId = 0x36;  // {} resolve this browser's CDP targetId (CEF-2b) -> kOpTargetId
constexpr uint8_t kOpInvalidate = 0x37;       // {} C1: force a repaint (Invalidate PET_VIEW) to re-kick a stalled first frame
constexpr uint8_t kOpMediaResponse = 0x3c;    // {u32 id}{u8 allow}{u8 remember} answer a kOpMediaRequest prompt; remembered per-origin ONLY when `remember` (a human chose) — never for a defensive auto-deny
constexpr uint8_t kOpSetMediaSetting = 0x3d;  // {u8 value} rewrite the CURRENT origin's camera+mic content setting (0=ask/default 1=allow 2=block) — the URL-bar "site settings" path; no reload, it applies next time the page asks
constexpr uint8_t kOpEditCommand = 0x38;      // {u8 cmd} run a focused-frame edit command (0=copy 1=cut 2=paste 3=selectAll 4=undo 5=redo)
constexpr uint8_t kOpOpenAuthWindow = 0x39;   // {utf8 url} open a windowed Chrome-runtime browser for a WebAuthn/Touch ID ceremony the OSR tile can't host (shares the tile's cookie jar)
constexpr uint8_t kOpSetAudioMuted = 0x3a;    // {u8 muted} -> CefBrowserHost::SetAudioMuted; a hidden AND muted page regains intensive wake-up throttling (audible pages are exempt)
constexpr uint8_t kOpSetPumpInterval = 0x3b;  // {u16 BE ms} visible begin-frame cadence for this slot, clamped to [8, 250]; hidden slots stay on the 100ms no-op poll
constexpr uint8_t kOpContextMenuCommand = 0x3e;  // {u32 id}{u32 commandId} run the chosen command from a kOpContextMenu (commandId 0 = dismissed); Chromium executes it, so copy/paste/back/spellcheck behave exactly as in Chrome

// ---- Shared runtime state ----
// Atomic: the reader thread reads it (ReadAll), SendFrame on any thread reads it,
// and main() stores the connected fd then -1 on teardown. A plain int would tear
// the SendFrame `< 0` check against the teardown `= -1` store (UB, and benign
// only because a closed-fd write is a safe no-op); the atomic makes it defined.
std::atomic<int> g_ipc_fd{-1};

// ── Renderer crash-loop detector ─────────────────────────────────────────────
// A renderer that dies is normally recoverable: OnRenderProcessTerminated
// reloads and the fresh child takes over. But if the child can no longer be
// SPAWNED at all, that reload re-crashes instantly and loops forever, and the
// host never notices: the browser process is healthy, so the IPC pipe stays up,
// no processGone is ever emitted, and the embedder sees a tile stuck on its last
// frame with no signal and no way back. The observed trigger is the app bundle
// being replaced under a running host (a rebuild/relaunch): every child then
// SIGTRAPs at startup resolving the CEF framework it was launched from.
//
// So make the unrecoverable case LOOK like the recoverable one. Past a burst
// threshold, exit deliberately: the pipe EOFs, the plugin reports processGone,
// and the embedder's existing recreate funnel spawns a fresh host — which
// re-resolves the binary from disk and therefore picks up the NEW bundle. A
// silent wedge becomes the recovery path that already works.
std::mutex g_renderer_crash_mutex;
int g_renderer_crash_count = 0;
std::chrono::steady_clock::time_point g_renderer_crash_window_start;
// Tuned to be unreachable by ordinary flakiness: an isolated renderer crash (or
// a few across unrelated tabs) reloads normally and never trips this.
constexpr int kRendererCrashBurstLimit = 4;
constexpr std::chrono::seconds kRendererCrashWindow{10};

void DoShutdown();  // defined below; the crash-loop exit reuses it

/// Record a renderer death and report whether they are arriving as a burst —
/// i.e. the reload is re-crashing rather than recovering. UI-thread only (the
/// single caller is OnRenderProcessTerminated), but locked anyway since the
/// counter is process-global across every slot: a stale-bundle host fails for
/// ALL its browsers at once, which is exactly the signal we want to add up.
bool NoteRendererCrashAndCheckLoop() {
  const auto now = std::chrono::steady_clock::now();
  std::lock_guard<std::mutex> lock(g_renderer_crash_mutex);
  if (g_renderer_crash_count == 0 ||
      now - g_renderer_crash_window_start > kRendererCrashWindow) {
    // First death, or the previous burst aged out: start a fresh window so
    // unrelated one-off crashes over a long session never accumulate.
    g_renderer_crash_window_start = now;
    g_renderer_crash_count = 1;
    return false;
  }
  return ++g_renderer_crash_count >= kRendererCrashBurstLimit;
}
std::mutex g_ipc_write_mutex;

// Per-browser state. One cef_host process now multiplexes N browsers (one per
// CefWebView sharing this profile), so the state that used to be process-global
// (surface/geometry/dpr, the browser, pending JS dialogs, the trusted-load
// allowlist exemptions, popup compositing buffers) moves into a per-browser
// Slot. HostClient / HostRenderHandler each hold a shared_ptr to their slot, and
// per-op UI tasks bind a shared_ptr copy so the slot outlives the
// dispose/in-flight race. Slots are created in DoCreateBrowser and torn down in
// OnBeforeClose (both on the CEF UI thread).
struct Slot {
  uint32_t browser_id = 0;  // Swift-assigned wire id (>=1); NOT GetIdentifier().
  CefRefPtr<CefBrowser> browser;
  // H3 async-create dispose-loss guard: a dispose arriving while the async
  // CreateBrowser is still in flight (browser == null) can't CloseBrowser yet, so it
  // records intent here and OnAfterCreated honors it the instant the browser binds —
  // otherwise that browser is a live orphan (renderer + IOSurface) nothing reclaims
  // until whole-host shutdown. UI-thread-confined (DoDisposeBrowser + OnAfterCreated
  // both run on the CEF UI thread), so no lock.
  bool close_requested = false;

  // Pending getUserMedia permission callbacks, keyed by request id — the browser
  // permission model: a page asks, the host shows a prompt, the answer comes back
  // over the IPC (kOpMediaResponse -> DoMediaResponse -> Continue). Held exactly
  // like `dialogs` below: UI-thread-only (OnRequestMediaAccessPermission and the
  // response both run on the CEF UI thread), per-slot so one browser's request id
  // can never Continue() another's. A held callback that is never answered is
  // dropped (Cancel) in OnBeforeClose / on navigation, matching a page whose
  // permission prompt is dismissed by leaving it.
  // The requested mask is held with the callback because CefMediaAccessCallback
  // requires that, for a getUserMedia request, the allowed permissions MATCH the
  // requested ones — so a grant is all-or-nothing and the host enforces that
  // itself rather than trusting whatever mask the response carries.
  struct PendingMedia {
    CefRefPtr<CefMediaAccessCallback> callback;
    uint32_t wanted = 0;
    // The ORIGIN that asked — the decision is remembered against this, not the
    // address bar, so a cross-origin iframe's grant can't be recorded for (or
    // silently inherited from) the top-level page.
    std::string origin;
  };
  std::map<uint32_t, PendingMedia> media_requests;

  // Right-click menus awaiting a choice from the Flutter side. Same shape as
  // media_requests and for the same reason: OSR has no window, so the menu is
  // drawn by the host and the callback has to survive until the user picks.
  // CEF requires the callback be answered (Continue or Cancel) exactly once, so
  // a dropped entry would leave the page's menu logic hanging.
  std::map<uint32_t, CefRefPtr<CefRunContextMenuCallback>> context_menus;
  uint32_t next_context_menu_id = 1;
  uint32_t media_req_next = 1;
  // Last capture state reported by OnMediaAccessChange, so the complete media
  // status can be re-sent (on load, or on demand) without waiting for a change.
  bool media_video_active = false;
  bool media_audio_active = false;

  // Guards surface / width / height / dpr / popup_* for THIS browser. Per-slot
  // (not a single global) so paints on independent browsers don't contend.
  std::mutex surface_mutex;
  IOSurfaceRef surface = nullptr;  // host-OWNED IOSurface we paint into (producer-allocates;
                                   // minted lazily in EnsureSurfaceForPaint on the first paint)
  // Set under surface_mutex in OnBeforeClose BEFORE nulling `surface`, so a paint racing teardown
  // (EnsureSurfaceForPaint) doesn't re-mint a surface for a closing browser (which would leak —
  // OnBeforeClose already released the last one). Producer-allocates lifetime guard.
  bool closing = false;
  // Cached Metal wrap of `surface` for the GPU-blit DEST. Wrapping it fresh every
  // frame is pure churn (the surface is stable except on resize), so cache it and
  // recreate only when the wrapped IOSurface id changes. Released wherever `surface`
  // is. Guarded by surface_mutex. MRC: holds the +1 from newTextureWithDescriptor.
  id<MTLTexture> dst_mtl = nil;
  uint32_t dst_mtl_sid = 0;
  int width = 800;   // logical (DIP) — GetViewRect; CEF scales by dpr.
  int height = 600;
  double dpr = 1.0;  // device pixel ratio; the IOSurface is logical*dpr px.

  // Popup widgets (<select> dropdowns, autofill) paint into a separate PET_POPUP
  // buffer that we composite over the view at the popup rect. Guarded by
  // surface_mutex. Per-slot so two browsers' open dropdowns don't clobber.
  bool popup_visible = false;
  CefRect popup_rect;
  std::vector<uint8_t> popup_buf;
  int popup_w = 0;
  int popup_h = 0;

  // Exact URLs armed for a host-trusted content load (kOpLoadTrusted). The
  // exemption is bound to the specific URL, NOT to a moment in time: LoadURL does
  // not deliver OnBeforeBrowse synchronously (it enqueues the nav; the callback
  // arrives as a later UI task), so a global one-shot flag could be consumed by a
  // page-initiated navigation queued in the gap — an allowlist bypass. Matching
  // on the exact URL (and main frame) in OnBeforeBrowse means a page nav to a
  // different URL can never steal another load's exemption. A multiset tolerates
  // identical concurrent trusted loads. UI-thread only, so no lock. Per-slot so a
  // trusted load on one browser can't exempt a navigation on another.
  // (A page racing the host to the EXACT same data:/file: URL could consume one
  // armed entry, but that is benign — it loads the same content the host chose —
  // so it is not defended beyond exact-URL matching.)
  std::multiset<std::string> trusted_pending;

  // Pending JS dialog callbacks, keyed by id. UI-thread-only (OnJSDialog and the
  // host's response both run on the CEF UI thread), so no lock is needed.
  // Per-slot so dialog ids on one browser can't Continue() another's callback.
  std::map<uint32_t, CefRefPtr<CefJSDialogCallback>> dialogs;
  uint32_t dialog_next = 1;

  // CEF-2b: registration for the DevTools message observer used to resolve this
  // browser's CDP targetId (Target.getTargetInfo). Kept alive for the slot's life;
  // UI-thread only. Lazily set on the first kOpResolveTargetId.
  CefRefPtr<CefRegistration> devtools_reg;
  // CEF-2b: the DevTools message id of the LAST Target.getTargetInfo probe on this
  // browser. A FRESH, monotonically-increasing id per probe (seeded to
  // kTargetInfoMsgId) — Chromium's DevTools session requires increasing command ids,
  // so reusing a fixed id silently drops the 2nd+ probe, which hung a re-enable of
  // agent-control (disable then enable again). UI-thread only, like dialog_next.
  int target_info_msg = 0;

  // External begin-frame pump (see PumpBeginFrame). With external_begin_frame_enabled, CEF's
  // internal frame timer is OFF — frames are produced ONLY when we drive them — so a per-slot
  // pump calls SendExternalBeginFrame on a cadence. `visible` gates it (UI-thread only, set by
  // DoSetVisible); `begin_frame_pump_started` guards a double-start. UI-thread only.
  bool visible = true;
  bool begin_frame_pump_started = false;
  // Visible begin-frame cadence (ms) for this slot — the OSR frame clock.
  // 16 ≈ 60fps (default); the host clamps kOpSetPumpInterval to [8, 250] so a
  // consumer can drop an unengaged tile to ~30fps without touching hidden
  // gating. UI-thread only, like `visible`.
  int pump_interval_ms = 16;
  // F-1/F-2: a dpr/screen-info change that lands while the slot is HIDDEN is deferred —
  // the begin-frame pump is gated off while hidden, so notifying + painting now would
  // composite into a surface nothing displays and mislead the Swift resize watchdog into
  // promoting a never-painted buffer. DoResize sets this while hidden; DoSetVisible's
  // hidden->visible edge re-asserts screen info before forcing a full repaint. UI-thread only.
  bool needs_screen_info_on_show = false;
  // Per-slot pump-tick + accelerated-paint counters, logged from PumpBeginFrame when
  // FLUTTER_CEF_DEBUG is set — diagnostics for paint-stall investigation at scale.
  uint64_t diag_pump_ticks = 0;
  uint64_t diag_paint_count = 0;
  // about:blank-first (FLUTTER_CEF_BLANK_FIRST): the real URL to navigate to AFTER the
  // browser establishes on about:blank. Establishing on blank makes the first-frame GPU
  // handshake near-instant (so the create-pacer releases its slot fast), decoupling
  // establishment from the real page's load time. Navigated + cleared on first paint.
  // UI-thread only.
  std::string pending_nav_url;
};

// Routing map from a wire browser id to its Slot. MUTATED ONLY ON THE CEF UI
// THREAD (insert in DoCreateBrowser, erase in OnBeforeClose). The IPC reader
// thread takes g_slots_mutex, copies the shared_ptr, releases the lock, then
// operates — so a slot stays alive for the duration of an in-flight op even if
// it's disposed. Paint/display handlers don't consult this map: each HostClient
// / HostRenderHandler holds its slot_ shared_ptr directly (no hot-path lookup).
std::mutex g_slots_mutex;
std::map<uint32_t /*wire id*/, std::shared_ptr<Slot>>
    g_slots_by_wire_id;  // inbound IPC routing -> slot

// Look up a slot by its Swift-assigned wire id (used by the IPC reader to route
// an inbound per-browser op). Null for wire id 0 or an unknown/disposed id.
std::shared_ptr<Slot> LookupWireId(uint32_t wire_id) {
  if (wire_id == 0) return nullptr;
  std::lock_guard<std::mutex> lock(g_slots_mutex);
  auto it = g_slots_by_wire_id.find(wire_id);
  return it == g_slots_by_wire_id.end() ? nullptr : it->second;
}

void SendLog(uint32_t browser_id, const std::string& msg);  // DIAG fwd decl (defined below)
// External begin-frame pump. window_info.external_begin_frame_enabled (set in DoCreateBrowser)
// turns OFF CEF's internal frame timer, so the GPU/Viz compositor produces a frame ONLY when we
// call SendExternalBeginFrame — which, unlike Invalidate(), deterministically drives one frame
// the scheduler cannot coalesce away. We are now the frame clock. This re-posts itself per live
// slot on the CEF UI thread; it dies when the slot is disposed (LookupWireId -> null) and idles
// to a slow poll while the tile is hidden (no begin-frame -> the off-screen browser costs ~zero,
// and WasHidden(true) already stopped its rendering). Started in HostClient::OnAfterCreated.
// Runs on TID_UI, so slot->visible / slot->browser need no lock (only UI-thread code touches them).
void PumpBeginFrame(uint32_t wire_id) {
  std::shared_ptr<Slot> slot = LookupWireId(wire_id);
  if (!slot || !slot->browser) return;  // disposed mid-flight — let the pump die
  if (slot->visible) slot->browser->GetHost()->SendExternalBeginFrame();
  slot->diag_pump_ticks++;  // DIAG
  if (std::getenv("FLUTTER_CEF_DEBUG") && slot->diag_pump_ticks % 120 == 0)
    SendLog(wire_id, "diag wire=" + std::to_string(wire_id) +
                         " pumpTicks=" + std::to_string(slot->diag_pump_ticks) +
                         " paints=" + std::to_string(slot->diag_paint_count) +
                         " visible=" + std::to_string(slot->visible ? 1 : 0));
  CefPostDelayedTask(TID_UI, base::BindOnce(&PumpBeginFrame, wire_id),
                     slot->visible ? slot->pump_interval_ms : 100);
}

// Process-wide Metal context for the GPU-blit present path (CompositeMetalLocked). One device +
// queue for the whole cef_host process; created lazily on first accelerated paint. MRC build, so
// these are owned singletons we intentionally never release. EnsureMetal() returns false (once,
// then cached) if Metal is unavailable — callers fall back to the CPU composite.
static id<MTLDevice> g_mtl_device = nil;
static id<MTLCommandQueue> g_mtl_queue = nil;
static bool EnsureMetal() {
  static bool tried = false;
  if (g_mtl_device) return true;
  if (tried) return false;
  tried = true;
  g_mtl_device = MTLCreateSystemDefaultDevice();
  if (!g_mtl_device) return false;
  g_mtl_queue = [g_mtl_device newCommandQueue];
  return g_mtl_queue != nil;
}

// Host-set navigation scheme allowlist (lowercased; `--allowed-schemes=a,b`).
// Empty = allow all. `about` is always allowed (the blank placeholder).
// Enforced in HostClient::OnBeforeBrowse so it covers the initial load,
// programmatic navigation (navigate), in-page clicks, and redirects. The host's
// explicit content-injection APIs (loadHtmlString -> data:, loadFile -> file:)
// are NOT subject to it — they arrive as kOpLoadTrusted and arm an exact-URL
// exemption in the browser's Slot::trusted_pending so their load isn't refused.
std::set<std::string> g_allowed_schemes;

// Agent-control opt-in: when true (set from main() via --cdp-pipe BEFORE
// CefInitialize, read back in OnBeforeCommandLineProcessing), cef_host exposes
// CDP over inherited fds (3=read / 4=write, Chromium's DevToolsPipeHandler)
// instead of a TCP port. The argv-scrub below hands CEF only argv[0], so the
// "remote-debugging-pipe" Chromium switch can ONLY be injected through the
// OnBeforeCommandLineProcessing hook — hence this file-scope flag. Off by
// default; when off, behavior is byte-identical to the pre-pipe path.
bool g_cdp_pipe = false;

// Registered JS channel names (UI-thread-only). On each frame load we inject a
// window.<name>.postMessage shim that routes to the host over window.cefQuery
// (the CefMessageRouter channel — renderer half lives in process_helper.mm).
std::set<std::string> g_channels;

// A JS channel name is interpolated into the injected shim's source, so it MUST
// be a plain JS identifier — otherwise a crafted name could break out of the
// string literal and run arbitrary script on every page load. Reject anything
// else (DoAddChannel drops invalid names).
bool IsValidChannelName(const std::string& n) {
  if (n.empty() || n.size() > 64) return false;
  auto isFirst = [](unsigned char c) {
    return std::isalpha(c) || c == '_' || c == '$';
  };
  auto isRest = [](unsigned char c) {
    return std::isalnum(c) || c == '_' || c == '$';
  };
  if (!isFirst(static_cast<unsigned char>(n[0]))) return false;
  for (size_t i = 1; i < n.size(); ++i) {
    if (!isRest(static_cast<unsigned char>(n[i]))) return false;
  }
  return true;
}

void InjectChannelShim(CefRefPtr<CefFrame> frame, const std::string& name) {
  if (!frame) return;
  std::string js = "window['" + name +
                   "']={postMessage:function(m){window.cefQuery({request:'ch:" +
                   name + ":'+String(m),persistent:false,"
                   "onSuccess:function(){},onFailure:function(){}});}};";
  frame->ExecuteJavaScript(js, "", 0);
}

// ---- IPC helpers ----
bool WriteAll(int fd, const void* buf, size_t len) {
  const uint8_t* p = static_cast<const uint8_t*>(buf);
  size_t off = 0;
  while (off < len) {
    ssize_t n = write(fd, p + off, len - off);
    if (n <= 0) {
      if (n < 0 && (errno == EINTR)) continue;
      return false;
    }
    off += static_cast<size_t>(n);
  }
  return true;
}

bool ReadAll(int fd, void* buf, size_t len) {
  uint8_t* p = static_cast<uint8_t*>(buf);
  size_t off = 0;
  while (off < len) {
    ssize_t n = read(fd, p + off, len - off);
    if (n == 0) return false;  // peer closed
    if (n < 0) {
      if (errno == EINTR) continue;
      return false;
    }
    off += static_cast<size_t>(n);
  }
  return true;
}

// Frame layout: [u32 bodyLen BE][u32 browserId BE][u8 opcode][payload]. browserId
// is the Swift-assigned wire id of the originating browser; 0 for process-level
// frames (kOpReady, process-level kOpLog). bodyLen = 4 (browserId) + 1 (op) +
// payloadLen, counting every byte after the length prefix.
void SendFrame(uint32_t browser_id, uint8_t opcode, const void* payload,
               uint32_t payload_len) {
  if (g_ipc_fd < 0) return;  // racy early-out; the authoritative check is under the lock
  std::lock_guard<std::mutex> lock(g_ipc_write_mutex);
  // C3: SNAPSHOT the fd under the write lock and write to the snapshot, never re-loading
  // g_ipc_fd at write time. Teardown sets g_ipc_fd=-1 (exchange) and close()s the old fd
  // under this same lock, so once we hold it the fd is either still valid (write) or
  // already -1 (skip) — a paint thread can no longer pass the early-out and then write
  // into a closed/recycled fd.
  int fd = g_ipc_fd.load();
  if (fd < 0) return;
  uint32_t body_len = 4 + 1 + payload_len;
  // Assemble the whole frame and write it in one WriteAll so a partial write
  // never leaves the peer with a length prefix it can't satisfy (stream desync).
  std::vector<uint8_t> frame(4 + body_len);
  frame[0] = static_cast<uint8_t>((body_len >> 24) & 0xff);
  frame[1] = static_cast<uint8_t>((body_len >> 16) & 0xff);
  frame[2] = static_cast<uint8_t>((body_len >> 8) & 0xff);
  frame[3] = static_cast<uint8_t>(body_len & 0xff);
  frame[4] = static_cast<uint8_t>((browser_id >> 24) & 0xff);
  frame[5] = static_cast<uint8_t>((browser_id >> 16) & 0xff);
  frame[6] = static_cast<uint8_t>((browser_id >> 8) & 0xff);
  frame[7] = static_cast<uint8_t>(browser_id & 0xff);
  frame[8] = opcode;
  if (payload_len) memcpy(frame.data() + 9, payload, payload_len);
  WriteAll(fd, frame.data(), frame.size());
}

void SendLog(uint32_t browser_id, const std::string& msg) {
  SendFrame(browser_id, kOpLog, msg.data(), static_cast<uint32_t>(msg.size()));
}

void SendUtf8(uint32_t browser_id, uint8_t op, const std::string& s) {
  SendFrame(browser_id, op, s.data(), static_cast<uint32_t>(s.size()));
}

void SendLoadState(uint32_t browser_id, bool loading, bool back, bool forward) {
  uint8_t p[3];
  p[0] = loading ? 1 : 0;
  p[1] = back ? 1 : 0;
  p[2] = forward ? 1 : 0;
  SendFrame(browser_id, kOpLoadState, p, 3);
}

// op payload: [u32 BE code][utf8 body]. Used for load-error and console.
void SendCodePlusUtf8(uint32_t browser_id, uint8_t op, uint32_t code,
                      const std::string& body) {
  std::vector<uint8_t> p(4 + body.size());
  p[0] = (code >> 24) & 0xff;
  p[1] = (code >> 16) & 0xff;
  p[2] = (code >> 8) & 0xff;
  p[3] = code & 0xff;
  memcpy(p.data() + 4, body.data(), body.size());
  SendFrame(browser_id, op, p.data(), static_cast<uint32_t>(p.size()));
}

uint32_t ReadU32BE(const uint8_t* p) {
  return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) |
         uint32_t(p[3]);
}

void WriteU32BE(uint8_t* p, uint32_t v) {
  p[0] = static_cast<uint8_t>((v >> 24) & 0xff);
  p[1] = static_cast<uint8_t>((v >> 16) & 0xff);
  p[2] = static_cast<uint8_t>((v >> 8) & 0xff);
  p[3] = static_cast<uint8_t>(v & 0xff);
}

uint64_t ReadU64BE(const uint8_t* p) {
  uint64_t v = 0;
  for (int i = 0; i < 8; ++i) v = (v << 8) | p[i];
  return v;
}

double ReadF64BE(const uint8_t* p) {
  uint64_t bits = ReadU64BE(p);
  double d;
  memcpy(&d, &bits, sizeof(d));
  return d;
}

// ---- CEF NSApplication (CefAppProtocol) ----
}  // namespace

// NSWindowDelegate for the native OAuth popup window (see PopupClient below).
// ObjC declarations must be at global scope — not inside the anonymous
// namespace that wraps PopupClient — so it lives here alongside the app class.
@interface FCPopupWindowDelegate : NSObject <NSWindowDelegate> {
 @public
  // Raw CefBrowser*, only safe to deref while `alive` is YES — i.e. between
  // OnAfterCreated and DoClose. Once a close is underway (JS window.close() or a
  // user click) CEF may synthesize a close-button press and fire this delegate
  // AFTER it has begun destroying the browser, leaving `browser` dangling; the
  // `alive` gate keeps us from touching it then (EXC_BAD_ACCESS otherwise).
  CefBrowser* browser;
  BOOL alive;
}
@end

@implementation FCPopupWindowDelegate
- (BOOL)windowShouldClose:(NSWindow*)sender {
  if (alive && browser) {
    browser->GetHost()->CloseBrowser(false);  // -> DoClose -> OnBeforeClose closes the window
    return NO;  // don't close yet; CEF drives teardown, then we close the window
  }
  return YES;  // a close is already underway (browser gone/going) — let it close
}
@end

@interface CefHostApplication : NSApplication <CefAppProtocol> {
  BOOL handlingSendEvent_;
}
@end
@implementation CefHostApplication
- (BOOL)isHandlingSendEvent {
  return handlingSendEvent_;
}
- (void)setHandlingSendEvent:(BOOL)h {
  handlingSendEvent_ = h;
}
- (void)sendEvent:(NSEvent*)event {
  CefScopedSendingEvent sendingEventScoper;
  [super sendEvent:event];
}
@end

namespace {

// Copy a tight BGRA source rect into the surface at (dx,dy), clipped to the
// surface bounds. CEF may deliver a frame at the pre-resize size while a resize
// is in flight, so over-large sources are clipped rather than rejected.
void BlitBGRA(uint8_t* dst, size_t dst_stride, int surf_w, int surf_h,
              const uint8_t* src, int src_w, int src_h, int dx, int dy) {
  for (int row = 0; row < src_h; ++row) {
    const int y = dy + row;
    if (y < 0 || y >= surf_h) continue;
    const int x0 = dx < 0 ? 0 : dx;
    const int sx0 = x0 - dx;
    int w = src_w - sx0;
    if (x0 + w > surf_w) w = surf_w - x0;
    if (w <= 0) continue;
    memcpy(
        dst + static_cast<size_t>(y) * dst_stride + static_cast<size_t>(x0) * 4,
        src + (static_cast<size_t>(row) * src_w + sx0) * 4,
        static_cast<size_t>(w) * 4);
  }
}

// ---- Render handler: OSR -> shared IOSurface ----
// One handler per browser; it holds a shared_ptr to that browser's Slot and
// derefs it instead of the old process-global surface/geometry. The CefBrowser*
// the callbacks are handed is ignored (this handler already owns exactly one
// slot — no map lookup on the hot paint path). All surface/popup access is under
// slot_->surface_mutex; OnPaint/OnAcceleratedPaint re-check slot_->surface after
// taking the lock, since OnBeforeClose nulls + CFReleases it under the same lock
// (a GPU-thread paint racing UI-thread teardown then sees null and no-ops).
class HostRenderHandler : public CefRenderHandler {
 public:
  explicit HostRenderHandler(std::shared_ptr<Slot> slot)
      : slot_(std::move(slot)) {}

  void GetViewRect(CefRefPtr<CefBrowser>, CefRect& rect) override {
    std::lock_guard<std::mutex> lock(slot_->surface_mutex);
    rect = CefRect(0, 0, slot_->width, slot_->height);
  }

  // The REAL display the app sits on (DIP). Reporting screen == the tile's own
  // viewport (the old behavior) is a textbook headless/OSR fingerprint — bot
  // detectors flag `window.screen.width == innerWidth`, `screen.colorDepth == 0`.
  // This is not spoofing: it's the actual monitor the browser is on. GetViewRect
  // (the render size) stays tile-sized, exactly like a real browser window is
  // smaller than its screen. Falls back to a plausible frame with no display
  // (headless CI). Returns rect(top-left DIP) + work-area (menu-bar/Dock excluded).
  static void RealScreenDip(CefRect& full, CefRect& work) {
    NSScreen* s = NSScreen.mainScreen;
    if (!s) {  // headless: a common 14" default so the value is never the tell
      full = CefRect(0, 0, 1512, 982);
      work = CefRect(0, 38, 1512, 982 - 38);
      return;
    }
    NSRect f = s.frame;          // points == DIP on macOS; primary screen at (0,0)
    NSRect v = s.visibleFrame;   // minus menu bar (top) + Dock; Cocoa bottom-left
    const int H = static_cast<int>(f.size.height);
    full = CefRect(0, 0, static_cast<int>(f.size.width), H);
    // Flip Cocoa bottom-left visibleFrame to CEF top-left work area.
    work = CefRect(static_cast<int>(v.origin.x),
                   H - static_cast<int>(v.origin.y + v.size.height),
                   static_cast<int>(v.size.width),
                   static_cast<int>(v.size.height));
  }

  // Report the device scale so CEF renders the OSR buffer at logical*dpr
  // (Retina-native) instead of 1x upscaled — fixes the blur on HiDPI displays —
  // AND the real screen bounds + color depth (see RealScreenDip).
  bool GetScreenInfo(CefRefPtr<CefBrowser>, CefScreenInfo& info) override {
    std::lock_guard<std::mutex> lock(slot_->surface_mutex);
    info.device_scale_factor = static_cast<float>(slot_->dpr);
    info.depth = 24;             // screen.colorDepth — 0 was a headless tell
    info.depth_per_component = 8;
    info.is_monochrome = 0;
    CefRect full, work;
    RealScreenDip(full, work);
    info.rect = full;
    info.available_rect = work;
    return true;
  }

  // The browser's root-window rect on screen (DIP). Without this CEF falls back
  // to GetViewRect → window.outerWidth/Height == innerWidth/Height and
  // screenX/screenY == 0, another OSR tell. Report a plausible window frame at a
  // non-zero offset, taller than the view by typical browser chrome, so
  // outerHeight > innerHeight like a real window. Popups/IME are composited into
  // our own surface from view-relative coords, so this offset doesn't move them.
  bool GetRootScreenRect(CefRefPtr<CefBrowser>, CefRect& rect) override {
    std::lock_guard<std::mutex> lock(slot_->surface_mutex);
    constexpr int kChromeH = 87;  // tab strip + toolbar, ~ real Chrome on macOS
    rect = CefRect(100, 80, slot_->width, slot_->height + kChromeH);
    return true;
  }

  // Present the just-painted slot surface, TAGGING the frame with its IOSurface id
  // (BE u32). The host (Swift) uses this to promote a resized "pending" surface to the
  // Flutter texture only once a paint into THAT surface has actually landed — until
  // then it keeps serving the old surface, so a resize never flashes the fresh,
  // zero-filled IOSurface. Caller holds slot_->surface_mutex.
  // The present carries the SID of the surface presented AND the PHYSICAL pixel dims of the
  // frame that was actually composited into it (srcW/srcH). On a device-scale (zoom) resize
  // the host swaps to the new-size surface synchronously while the renderer re-rasters
  // async, so the first frame after a resize is the renderer's OLD-scale frame landing in
  // the NEW surface. With only a sid the consumer can't tell that provisional wrong-scale
  // frame from a correct one and promotes it → content renders too big/small. Carrying the
  // composited dims lets the consumer promote ONLY a frame whose dims match the new surface
  // (round(logical*dpr)), so it keeps serving the last correct-scale buffer until the real
  // re-rastered frame lands. UI thread; caller holds slot_->surface_mutex.
  void SendPresentLocked(int srcW, int srcH) {
    uint32_t sid = slot_->surface ? IOSurfaceGetID(slot_->surface) : 0;
    auto be32 = [](uint8_t* o, uint32_t v) {
      o[0] = (v >> 24) & 0xff; o[1] = (v >> 16) & 0xff;
      o[2] = (v >> 8) & 0xff;  o[3] = v & 0xff;
    };
    uint8_t p[12];
    be32(p, sid);
    be32(p + 4, static_cast<uint32_t>(srcW < 0 ? 0 : srcW));
    be32(p + 8, static_cast<uint32_t>(srcH < 0 ? 0 : srcH));
    SendFrame(slot_->browser_id, kOpPresent, p, 12);
  }

  void OnPaint(CefRefPtr<CefBrowser>, PaintElementType type, const RectList&,
               const void* buffer, int width, int height) override {
    std::lock_guard<std::mutex> lock(slot_->surface_mutex);
    // PRODUCER-ALLOCATES (software path): mint/resize the surface to the painted VIEW dims
    // before the guard, mirroring OnAcceleratedPaint — else the surface is never created and
    // nothing paints. A POPUP paint composites onto the existing view surface (don't resize).
    if (type == PET_VIEW) EnsureSurfaceForPaint(width, height);
    if (!slot_->surface) return;
    if (IOSurfaceLock(slot_->surface, 0, nullptr) != kIOReturnSuccess) return;
    uint8_t* dst = static_cast<uint8_t*>(IOSurfaceGetBaseAddress(slot_->surface));
    const size_t dst_stride = IOSurfaceGetBytesPerRow(slot_->surface);
    const int surf_w = static_cast<int>(IOSurfaceGetWidth(slot_->surface));
    const int surf_h = static_cast<int>(IOSurfaceGetHeight(slot_->surface));
    const uint8_t* src = static_cast<const uint8_t*>(buffer);
    // OnPopupSize reports the popup rect in LOGICAL (DIP) coords, but we blit
    // into the physical (device-scaled) IOSurface — so the paint offset must be
    // scaled by the device pixel ratio. Without this the dropdown paints at the
    // wrong position on HiDPI and mouse clicks miss it (CEF hit-tests the popup
    // against the logical rect, which no longer matches where it was drawn).
    const int popup_px = static_cast<int>(slot_->popup_rect.x * slot_->dpr);
    const int popup_py = static_cast<int>(slot_->popup_rect.y * slot_->dpr);
    if (type == PET_VIEW) {
      BlitBGRA(dst, dst_stride, surf_w, surf_h, src, width, height, 0, 0);
      // Keep an open popup (<select> dropdown) painted on top of the view.
      if (slot_->popup_visible && !slot_->popup_buf.empty()) {
        BlitBGRA(dst, dst_stride, surf_w, surf_h, slot_->popup_buf.data(),
                 slot_->popup_w, slot_->popup_h, popup_px, popup_py);
      }
    } else if (type == PET_POPUP) {
      slot_->popup_w = width;
      slot_->popup_h = height;
      slot_->popup_buf.assign(src, src + static_cast<size_t>(width) * height * 4);
      BlitBGRA(dst, dst_stride, surf_w, surf_h, src, width, height, popup_px,
               popup_py);
    }
    IOSurfaceUnlock(slot_->surface, 0, nullptr);
    // PET_VIEW reports the painted view-frame dims (the size-gate signal); a PET_POPUP
    // repaint didn't rescale the view, so report the surface dims (always correct-scale).
    SendPresentLocked(type == PET_VIEW ? width : surf_w,
                      type == PET_VIEW ? height : surf_h);
  }

  void OnPopupShow(CefRefPtr<CefBrowser> browser, bool show) override {
    {
      std::lock_guard<std::mutex> lock(slot_->surface_mutex);
      slot_->popup_visible = show;
      if (!show) {
        slot_->popup_buf.clear();
        slot_->popup_rect = CefRect();
      }
    }
    // Repaint the view so the render path switches: on show, the next view paint
    // takes the software-composite branch (to draw the popup on top); on hide, it
    // returns to zero-copy and the dropdown's pixels are gone.
    if (browser) browser->GetHost()->Invalidate(PET_VIEW);
  }

  void OnPopupSize(CefRefPtr<CefBrowser>, const CefRect& rect) override {
    std::lock_guard<std::mutex> lock(slot_->surface_mutex);
    slot_->popup_rect = rect;
  }

  // Copy a popup's GPU surface into the CPU popup buffer so the software
  // composite can draw it over the view. Caller holds slot_->surface_mutex.
  void CopyAccelToPopupBuf(IOSurfaceRef src) {
    if (IOSurfaceLock(src, kIOSurfaceLockReadOnly, nullptr) != kIOReturnSuccess) {
      return;
    }
    const int pw = static_cast<int>(IOSurfaceGetWidth(src));
    const int ph = static_cast<int>(IOSurfaceGetHeight(src));
    const size_t ss = IOSurfaceGetBytesPerRow(src);
    const auto* s = static_cast<const uint8_t*>(IOSurfaceGetBaseAddress(src));
    slot_->popup_w = pw;
    slot_->popup_h = ph;
    slot_->popup_buf.resize(static_cast<size_t>(pw) * ph * 4);
    for (int y = 0; y < ph; ++y) {
      memcpy(slot_->popup_buf.data() + static_cast<size_t>(y) * pw * 4,
             s + static_cast<size_t>(y) * ss, static_cast<size_t>(pw) * 4);
    }
    IOSurfaceUnlock(src, kIOSurfaceLockReadOnly, nullptr);
  }

  // PRODUCER-ALLOCATES: ensure slot_->surface is EXACTLY sw x sh — the dims CEF actually
  // painted (view_src). cef_host owns this surface (it mints it, the consumer adopts it by id
  // from the present). Because the blit dst is then the same size as the src, the copy is 1:1
  // and can NEVER crop (src>dst) or leave stale margins (src<dst) — the entire wrong-size class
  // is structurally gone. Reallocates on first paint or any size/dpr change (CEF re-rasters at
  // the new logical×dpr → a new view_src size → here). Caller holds slot_->surface_mutex.
  // Releases cef_host's ref on the OLD surface immediately; the consumer's CVPixelBuffer keeps
  // the old one alive (independent refcount) until it adopts the new id, so no UAF.
  void EnsureSurfaceForPaint(int sw, int sh) {
    if (sw < 1 || sh < 1) return;  // popup-only repaint (view_src null) keeps the current surface
    if (slot_->closing) return;    // a paint racing teardown must not re-mint a surface (leak)
    IOSurfaceRef cur = slot_->surface;
    if (cur && static_cast<int>(IOSurfaceGetWidth(cur)) == sw &&
        static_cast<int>(IOSurfaceGetHeight(cur)) == sh) {
      return;  // already the right size — the common steady-state path, zero allocation
    }
    const size_t bpr = ((static_cast<size_t>(sw) * 4) + 63) & ~static_cast<size_t>(63);
    NSDictionary* props = @{
      (id)kIOSurfaceWidth : @(sw),
      (id)kIOSurfaceHeight : @(sh),
      (id)kIOSurfaceBytesPerElement : @(4),
      (id)kIOSurfaceBytesPerRow : @(static_cast<long>(bpr)),
      (id)kIOSurfaceAllocSize : @(static_cast<long>(bpr * sh)),
      (id)kIOSurfacePixelFormat : @(0x42475241),  // 'BGRA' = kCVPixelFormatType_32BGRA
      @"IOSurfaceIsGlobal" : @YES,                // resolvable cross-process by id (consumer Lookups it)
    };
    IOSurfaceRef fresh = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    if (!fresh) {
      SendLog(slot_->browser_id, "EnsureSurfaceForPaint: IOSurfaceCreate failed");
      return;  // keep the old surface; next paint retries
    }
    slot_->surface = fresh;  // cef_host's +1 (mint, not Lookup)
    [slot_->dst_mtl release];
    slot_->dst_mtl = nil;
    slot_->dst_mtl_sid = 0;  // the cached Metal wrap pointed at `cur`; rebuilt this same paint
    if (cur) CFRelease(cur);  // drop cef_host's +1 on the old; consumer's CVPixelBuffer still holds it
  }

  // Software-composite the view (optional GPU surface, stride-aware) and the open
  // popup into the host-allocated slot_->surface and present it. Used only while
  // a <select> dropdown is open, since a popup can't ride the zero-copy texture.
  // Caller holds slot_->surface_mutex.
  void CompositeSoftwareLocked(IOSurfaceRef view_src) {
    // Producer-allocates: size the host surface to the painted view BEFORE compositing, so the
    // memcpy below is 1:1 (no crop/partial). Popup-only repaint (view_src null) keeps the surface.
    if (view_src) {
      EnsureSurfaceForPaint(static_cast<int>(IOSurfaceGetWidth(view_src)),
                            static_cast<int>(IOSurfaceGetHeight(view_src)));
    }
    if (!slot_->surface) return;
    if (IOSurfaceLock(slot_->surface, 0, nullptr) != kIOReturnSuccess) return;
    auto* dst = static_cast<uint8_t*>(IOSurfaceGetBaseAddress(slot_->surface));
    const size_t ds = IOSurfaceGetBytesPerRow(slot_->surface);
    const int dw = static_cast<int>(IOSurfaceGetWidth(slot_->surface));
    const int dh = static_cast<int>(IOSurfaceGetHeight(slot_->surface));
    // The composited frame's physical dims (for the size-gated present). A popup-only
    // repaint (view_src == null) re-presents the existing view surface as-is → report the
    // surface dims so it counts as correct-scale.
    int srcW = dw, srcH = dh;
    if (view_src &&
        IOSurfaceLock(view_src, kIOSurfaceLockReadOnly, nullptr) ==
            kIOReturnSuccess) {
      srcW = static_cast<int>(IOSurfaceGetWidth(view_src));
      srcH = static_cast<int>(IOSurfaceGetHeight(view_src));
      const auto* s = static_cast<const uint8_t*>(IOSurfaceGetBaseAddress(view_src));
      const size_t ss = IOSurfaceGetBytesPerRow(view_src);
      const int rows = std::min<int>(dh, IOSurfaceGetHeight(view_src));
      const size_t rb = std::min<size_t>(
          static_cast<size_t>(dw) * 4,
          static_cast<size_t>(IOSurfaceGetWidth(view_src)) * 4);
      for (int y = 0; y < rows; ++y) {
        memcpy(dst + static_cast<size_t>(y) * ds, s + static_cast<size_t>(y) * ss, rb);
      }
      IOSurfaceUnlock(view_src, kIOSurfaceLockReadOnly, nullptr);
    }
    if (slot_->popup_visible && !slot_->popup_buf.empty()) {
      const int px = static_cast<int>(slot_->popup_rect.x * slot_->dpr);
      const int py = static_cast<int>(slot_->popup_rect.y * slot_->dpr);
      BlitBGRA(dst, ds, dw, dh, slot_->popup_buf.data(), slot_->popup_w,
               slot_->popup_h, px, py);
    }
    IOSurfaceUnlock(slot_->surface, 0, nullptr);
    SendPresentLocked(srcW, srcH);
  }

  // GPU-blit composite: copy CEF's accelerated view surface into the host-owned slot_->surface
  // with a Metal blit instead of the CPU IOSurfaceLock+memcpy in CompositeSoftwareLocked. CEF's
  // contract reclaims view_src back to its pool when this callback returns, so the blit's GPU READ
  // of view_src MUST complete before we return — hence waitUntilCompleted (the existing CPU path's
  // IOSurfaceLock+memcpy is likewise synchronous). The win is keeping frame data on the GPU
  // end-to-end: on discrete-GPU / Windows / Linux this avoids the GPU->CPU readback the memcpy
  // forces; on unified-memory Apple Silicon it's ~neutral. Caller holds slot_->surface_mutex.
  // Falls back to the CPU composite if Metal is unavailable or the IOSurface->texture wrap fails.
  // Popups never take this path — an open <select> dropdown is CPU-composited over the view.
  //
  // PORTING: this is the macOS half of the cross-platform "copy CEF's accelerated surface into a
  // client-owned texture via a GPU blit, INSIDE the callback" pattern that CEF's pool contract
  // mandates on every platform. A port swaps only this one method: Windows takes the D3D11 shared
  // HANDLE from CefAcceleratedPaintInfo -> ID3D11DeviceContext::CopyResource; Linux takes the
  // dmabuf fd -> import as a GL/VK image -> blit. The OnAcceleratedPaint call site, the
  // reclaim-at-return contract, and the present protocol are identical across platforms.
  void CompositeMetalLocked(IOSurfaceRef view_src) {
    // Producer-allocates: size the host surface to the painted view first → the blit is 1:1.
    if (view_src) {
      EnsureSurfaceForPaint(static_cast<int>(IOSurfaceGetWidth(view_src)),
                            static_cast<int>(IOSurfaceGetHeight(view_src)));
    }
    if (!slot_->surface) return;
    bool blitted = false;
    // Composited frame's physical dims — now ALWAYS == slot_->surface dims (producer-allocated),
    // so the present's srcW/srcH the consumer adopts always match the surface it Lookups.
    const int srcW = view_src ? static_cast<int>(IOSurfaceGetWidth(view_src)) : 0;
    const int srcH = view_src ? static_cast<int>(IOSurfaceGetHeight(view_src)) : 0;
    // DIAG (screen-independent verification — the box may be display-asleep, so a screenshot
    // can't tell content from blank): sample the renderer's composited frame on a throttle and
    // classify a 9-point grid. content>0 means real pixels landed; white==9 means only the
    // opaque background (page didn't paint content); clear==9 means a zero-filled / never-
    // committed frame (the shared-GPU multiplex failure). Under FLUTTER_CEF_DEBUG only.
    static const int kDiagEvery = []() {
      const char* e = std::getenv("FLUTTER_CEF_DIAGPX_EVERY");
      int n = e ? atoi(e) : 60;
      return n > 0 ? n : 60;  // sample 1-in-N accelerated paints (default 60 ≈ 1/s; set 6 ≈ 10/s)
    }();
    if (view_src && (slot_->diag_paint_count % kDiagEvery) == 2 &&
        std::getenv("FLUTTER_CEF_DEBUG") &&
        IOSurfaceLock(view_src, kIOSurfaceLockReadOnly, nullptr) == kIOReturnSuccess) {
      const auto* base = static_cast<const uint8_t*>(IOSurfaceGetBaseAddress(view_src));
      const size_t bpr = IOSurfaceGetBytesPerRow(view_src);
      int content = 0, white = 0, clear = 0;
      uint32_t center = 0;
      const int xs[3] = {srcW / 4, srcW / 2, (3 * srcW) / 4};
      const int ys[3] = {srcH / 4, srcH / 2, (3 * srcH) / 4};
      for (int yi = 0; yi < 3; ++yi)
        for (int xi = 0; xi < 3; ++xi) {
          const uint8_t* p = base + static_cast<size_t>(ys[yi]) * bpr +
                             static_cast<size_t>(xs[xi]) * 4;  // BGRA8
          const uint8_t b = p[0], g = p[1], r = p[2], a = p[3];
          if (xi == 1 && yi == 1)
            center = (uint32_t)b | ((uint32_t)g << 8) | ((uint32_t)r << 16) | ((uint32_t)a << 24);
          if (a == 0) clear++;
          else if (r > 240 && g > 240 && b > 240) white++;
          else if (r < 12 && g < 12 && b < 12) clear++;  // black == empty too
          else content++;
        }
      IOSurfaceUnlock(view_src, kIOSurfaceLockReadOnly, nullptr);
      // want = the requested OSR surface dims (logical × dpr). Comparing painted (srcWxsrcH)
      // against want is the WRONG-SIZE oracle: painted << want past a grace = the small-surface-
      // scaled-up "4x" bug. content==0 with want>0 = BLANK. Both are screen-independent.
      const int wantW = static_cast<int>(slot_->width * slot_->dpr + 0.5);
      const int wantH = static_cast<int>(slot_->height * slot_->dpr + 0.5);
      char buf[200];
      snprintf(buf, sizeof(buf),
               "diagpx wire=%u painted=%dx%d want=%dx%d content=%d white=%d clear=%d "
               "center=0x%08x",
               slot_->browser_id, srcW, srcH, wantW, wantH, content, white, clear, center);
      SendLog(slot_->browser_id, buf);
    }
    if (view_src && EnsureMetal()) {
      @autoreleasepool {
        const int sw = static_cast<int>(IOSurfaceGetWidth(view_src));
        const int sh = static_cast<int>(IOSurfaceGetHeight(view_src));
        const int dw = static_cast<int>(IOSurfaceGetWidth(slot_->surface));
        const int dh = static_cast<int>(IOSurfaceGetHeight(slot_->surface));
        MTLTextureDescriptor* sd = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                         width:sw
                                        height:sh
                                     mipmapped:NO];
        sd.storageMode = MTLStorageModeShared;
        // src wraps CEF's pooled view_src — it rotates, so wrap per-call.
        id<MTLTexture> src = [g_mtl_device newTextureWithDescriptor:sd
                                                          iosurface:view_src
                                                              plane:0];
        // dst wraps slot_->surface (stable except on resize) — cache it and only
        // recreate when the wrapped surface id changes, halving per-frame texture
        // churn on the GPU thread.
        const uint32_t dsid = IOSurfaceGetID(slot_->surface);
        if (slot_->dst_mtl == nil || slot_->dst_mtl_sid != dsid) {
          [slot_->dst_mtl release];
          MTLTextureDescriptor* dd = [MTLTextureDescriptor
              texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                           width:dw
                                          height:dh
                                       mipmapped:NO];
          dd.storageMode = MTLStorageModeShared;
          slot_->dst_mtl = [g_mtl_device newTextureWithDescriptor:dd
                                                        iosurface:slot_->surface
                                                            plane:0];
          slot_->dst_mtl_sid = dsid;
        }
        id<MTLTexture> dst = slot_->dst_mtl;  // cached (released on resize/close)
        if (src && dst) {
          const int cw = std::min(sw, dw), ch = std::min(sh, dh);
          // DIAG: a src≠dst blit crops (src>dst → top-left only) or partial-fills (src<dst →
          // stale margins). On a static page this single mismatched frame sticks. Log it.
          if ((sw != dw || sh != dh) && std::getenv("FLUTTER_CEF_DEBUG")) {
            char b[160];
            snprintf(b, sizeof(b), "blitmismatch src=%dx%d dst=%dx%d copy=%dx%d", sw, sh, dw, dh, cw, ch);
            SendLog(slot_->browser_id, b);
          }
          id<MTLCommandBuffer> cb = [g_mtl_queue commandBuffer];
          id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
          [blit copyFromTexture:src
                    sourceSlice:0
                    sourceLevel:0
                   sourceOrigin:MTLOriginMake(0, 0, 0)
                     sourceSize:MTLSizeMake(cw, ch, 1)
                      toTexture:dst
               destinationSlice:0
               destinationLevel:0
              destinationOrigin:MTLOriginMake(0, 0, 0)];
          [blit endEncoding];
          [cb commit];
          [cb waitUntilCompleted];
          blitted = true;
        }
        [src release];
        // dst is cached on the Slot (released on resize/close), not per-frame.
      }
    }
    if (blitted) {
      static bool logged = false;
      if (!logged) {
        logged = true;
        SendLog(slot_->browser_id, "present: GPU Metal blit path active");
      }
      SendPresentLocked(srcW, srcH);
    } else {
      static bool loggedFb = false;
      if (!loggedFb) {
        loggedFb = true;
        SendLog(slot_->browser_id,
                "present: CPU composite fallback (Metal unavailable or IOSurface wrap failed)");
      }
      CompositeSoftwareLocked(view_src);
    }
  }

  // GPU-accelerated OSR. With shared_texture_enabled, CEF's GPU/Viz process
  // COMPOSITES the page on the GPU and hands us the result as a shared IOSurface
  // (a rotating pool, valid only for this call). We copy it into the host-shared
  // surface and present that. The win is that compositing moves OFF the CPU —
  // software OSR's bottleneck for video / animation — while the copy itself is
  // cheap on unified-memory Macs. (True zero-copy, handing the GPU surface to
  // Flutter directly, would need cross-process Mach-port surface transfer since
  // these surfaces aren't resolvable by global id from another process; a future
  // optimization, mostly for discrete-GPU Macs where the copy is a real readback.)
  void OnAcceleratedPaint(CefRefPtr<CefBrowser>, PaintElementType type,
                          const RectList&,
                          const CefAcceleratedPaintInfo& info) override {
    slot_->diag_paint_count++;  // DIAG
    // about:blank-first: the browser has established (first paint on about:blank) — now
    // navigate to the real URL. The establishment slot has already been released by this
    // paint, so the real page loads WITHOUT holding a serial slot (concurrent with the
    // other tiles' loads). Fires once (pending_nav_url cleared). UI thread.
    if (!slot_->pending_nav_url.empty() && slot_->browser) {
      std::string nav = slot_->pending_nav_url;
      slot_->pending_nav_url.clear();
      if (auto frame = slot_->browser->GetMainFrame()) frame->LoadURL(nav);
    }
    IOSurfaceRef src =
        reinterpret_cast<IOSurfaceRef>(info.shared_texture_io_surface);
    if (!src) {
      SendLog(slot_->browser_id, "OnAcceleratedPaint: null io_surface");
      return;
    }
    std::lock_guard<std::mutex> lock(slot_->surface_mutex);
    // PRODUCER-ALLOCATES: the surface is minted lazily by the FIRST view paint (and re-minted on
    // any size change) inside the composite path — so we must NOT early-return on a null surface
    // before reaching it (that would deadlock: no surface → no paint → no surface). For a VIEW
    // paint, ensure the surface to the painted dims here; EnsureSurfaceForPaint no-ops if the
    // browser is closing. For a POPUP paint (no view dims) the view surface must already exist.
    if (type != PET_POPUP) {
      EnsureSurfaceForPaint(static_cast<int>(IOSurfaceGetWidth(src)),
                            static_cast<int>(IOSurfaceGetHeight(src)));
    }
    if (!slot_->surface) return;  // closing, or alloc failed — drop this frame
    if (type == PET_POPUP) {
      CopyAccelToPopupBuf(src);
      CompositeSoftwareLocked(nullptr);  // popup over latest view in slot->surface
      return;
    }
    // View frame. While a <select> dropdown is open we must CPU-composite so the popup is drawn
    // over the view; otherwise take the GPU-blit path (no CPU readback).
    if (slot_->popup_visible) {
      CompositeSoftwareLocked(src);  // GPU-composited view + the open popup
    } else {
      CompositeMetalLocked(src);  // GPU blit, no CPU readback
    }
  }

  // Report the composition caret rect (DIP, view coords) so the host can place
  // the OS IME candidate window under the text being composed.
  void OnImeCompositionRangeChanged(CefRefPtr<CefBrowser>, const CefRange&,
                                    const RectList& bounds) override {
    CefRect r = bounds.empty() ? CefRect(0, 0, 0, 0) : bounds.front();
    uint8_t p[16];
    WriteU32BE(p + 0, static_cast<uint32_t>(std::max(0, r.x)));
    WriteU32BE(p + 4, static_cast<uint32_t>(std::max(0, r.y)));
    WriteU32BE(p + 8, static_cast<uint32_t>(std::max(0, r.width)));
    WriteU32BE(p + 12, static_cast<uint32_t>(std::max(0, r.height)));
    SendFrame(slot_->browser_id, kOpImeBounds, p, 16);
  }

 private:
  std::shared_ptr<Slot> slot_;

  IMPLEMENT_REFCOUNTING(HostRenderHandler);
};

// Deny-default permission gate. With NO permission handler, CEF/Chromium has no
// per-site gate, so untrusted web content (including a third-party iframe on a
// trusted page) could reach camera/mic (getUserMedia), geolocation,
// notifications, etc. We deny every permission prompt and every media-access
// request up front. This is deliberately deny-ONLY: there is no host round-trip
// and no allow path. It does NOT touch WebAuthn / caBLE — passkeys are not a
// CefPermissionHandler permission type (they go through the authenticator /
// Bluetooth stack, gated by the OS + the bluetooth entitlement), so denying
// media/geo here leaves the passkey-over-Bluetooth flow untouched.
// Send the page's COMPLETE media status: what is capturing right now, plus the
// site's remembered decision. The stored setting has to be reported explicitly
// because Chromium enforces a remembered BLOCK itself, without ever calling the
// permission handler — so the UI could otherwise never learn that a site is
// blocked (there is no request to observe). UI-thread only (GetContentSetting).
void SendMediaState(const std::shared_ptr<Slot>& slot) {
  CEF_REQUIRE_UI_THREAD();
  uint8_t setting = 0;  // 0 = ask (no stored decision)
  if (slot->browser) {
    CefRefPtr<CefRequestContext> ctx =
        slot->browser->GetHost()->GetRequestContext();
    CefRefPtr<CefFrame> frame = slot->browser->GetMainFrame();
    const std::string url = frame ? frame->GetURL().ToString() : std::string();
    if (ctx &&
        (url.rfind("https://", 0) == 0 || url.rfind("http://", 0) == 0)) {
      const cef_content_setting_values_t cam = ctx->GetContentSetting(
          url, CefString(), CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA);
      const cef_content_setting_values_t mic = ctx->GetContentSetting(
          url, CefString(), CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC);
      // Heal a stored BLOCK from an older build, at LOAD time. It cannot wait
      // for the next getUserMedia: the page reads this through
      // navigator.permissions.query() BEFORE deciding whether to ask at all, so
      // a site that sees "denied" never calls getUserMedia and the request-time
      // heal would never run — the page stays permanently dead. Clearing it
      // here puts the site back to "ask"; a refusal now lives on the Campus
      // side, invisible to the page.
      if (cam == CEF_CONTENT_SETTING_VALUE_BLOCK ||
          mic == CEF_CONTENT_SETTING_VALUE_BLOCK) {
        ctx->SetContentSetting(url, CefString(),
                               CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA,
                               CEF_CONTENT_SETTING_VALUE_DEFAULT);
        ctx->SetContentSetting(url, CefString(),
                               CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC,
                               CEF_CONTENT_SETTING_VALUE_DEFAULT);
        setting = 0;
      } else if (cam == CEF_CONTENT_SETTING_VALUE_ALLOW ||
                 mic == CEF_CONTENT_SETTING_VALUE_ALLOW) {
        setting = 1;
      }
    }
  }
  const uint8_t p[3] = {static_cast<uint8_t>(slot->media_video_active ? 1 : 0),
                        static_cast<uint8_t>(slot->media_audio_active ? 1 : 0),
                        setting};
  SendFrame(slot->browser_id, kOpMediaState, p, 3);
}

class HostPermissionHandler : public CefPermissionHandler {
 public:
  explicit HostPermissionHandler(std::shared_ptr<Slot> slot)
      : slot_(std::move(slot)) {}

  // getUserMedia (camera/mic): the standard BROWSER model — ask once per origin,
  // then remember. Never auto-grant: with no stored decision we hold the callback
  // and ask the host to show a prompt over the tile (kOpMediaRequest), and the
  // answer is written back as a per-origin content setting so the page is never
  // asked twice. Only DEVICE capture is ever on the table; DESKTOP capture
  // (screen-share) is dropped here and stays a separate capability.
  bool OnRequestMediaAccessPermission(
      CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>,
      const CefString& requesting_origin, uint32_t requested_permissions,
      CefRefPtr<CefMediaAccessCallback> callback) override {
    CEF_REQUIRE_UI_THREAD();
    const uint32_t device_only =
        static_cast<uint32_t>(CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE) |
        static_cast<uint32_t>(CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE);
    const uint32_t wanted = requested_permissions & device_only;
    // Nothing grantable (e.g. a pure getDisplayMedia/desktop request) -> deny.
    if (!slot_ || wanted == 0) {
      callback->Continue(CEF_MEDIA_PERMISSION_NONE);
      return true;
    }
    const std::string origin = requesting_origin.ToString();
    // A remembered decision answers immediately — no prompt. Chromium normally
    // short-circuits a stored setting before ever reaching this handler; we read
    // it ourselves so the behavior is identical whether or not it does, and so a
    // partially-stored decision (camera allowed, mic unset) still re-prompts.
    CefRefPtr<CefRequestContext> ctx =
        browser ? browser->GetHost()->GetRequestContext() : nullptr;
    if (ctx && !origin.empty()) {
      uint32_t remembered = 0;
      bool stored_block = false;
      const auto read = [&](uint32_t bit, cef_content_setting_types_t type) {
        if (!(wanted & bit)) return;
        const cef_content_setting_values_t v =
            ctx->GetContentSetting(origin, CefString(), type);
        if (v == CEF_CONTENT_SETTING_VALUE_ALLOW) {
          remembered |= bit;
        } else if (v == CEF_CONTENT_SETTING_VALUE_BLOCK) {
          stored_block = true;
        }
      };
      read(CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE,
           CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA);
      read(CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE,
           CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC);
      // A stored BLOCK is never written any more, but an older profile may
      // still carry one — heal it. It has to go: the PAGE can read it through
      // navigator.permissions.query(), and sites branch on that. Meet asks
      // first and, seeing "denied", never calls getUserMedia at all — so its
      // own "use camera" button goes dead with no request for the host to
      // observe, prompt on, or offer a way back from. "Blocked" is remembered
      // on the Campus side instead, where it can't lie to the page.
      if (stored_block) {
        ctx->SetContentSetting(origin, CefString(),
                               CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA,
                               CEF_CONTENT_SETTING_VALUE_DEFAULT);
        ctx->SetContentSetting(origin, CefString(),
                               CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC,
                               CEF_CONTENT_SETTING_VALUE_DEFAULT);
      }
      // All-or-nothing: Continue must MATCH the request for getUserMedia, so a
      // grant only short-circuits when EVERY requested device is remembered.
      if (!stored_block && remembered == wanted) {
        callback->Continue(remembered);
        return true;
      }
    }
    // Undecided -> hold the callback (exactly like a JS dialog) and prompt.
    const uint32_t id = slot_->media_req_next++;
    slot_->media_requests[id] = Slot::PendingMedia{callback, wanted, origin};
    std::vector<uint8_t> p(8 + origin.size());
    for (int i = 0; i < 4; ++i) {
      p[i] = (id >> (24 - 8 * i)) & 0xff;
      p[4 + i] = (wanted >> (24 - 8 * i)) & 0xff;
    }
    memcpy(p.data() + 8, origin.data(), origin.size());
    SendFrame(slot_->browser_id, kOpMediaRequest, p.data(),
              static_cast<uint32_t>(p.size()));
    return true;  // answered asynchronously via DoMediaResponse
  }
  // Geolocation, notifications, clipboard, etc. all arrive as a permission
  // prompt: deny without ever showing UI.
  bool OnShowPermissionPrompt(
      CefRefPtr<CefBrowser>, uint64_t, const CefString&, uint32_t,
      CefRefPtr<CefPermissionPromptCallback> callback) override {
    callback->Continue(CEF_PERMISSION_RESULT_DENY);
    return true;
  }

  IMPLEMENT_REFCOUNTING(HostPermissionHandler);

 private:
  std::shared_ptr<Slot> slot_;
};

// ───── Native windowed popup for OAuth (window.open with features) ──────────
//
// The main tile is OSR (windowless) and cancels ordinary popups, loading their
// URL in-place. That works for target=_blank links but BREAKS popup-based sign-in
// (Google / Firebase signInWithPopup): those open a real popup, authenticate,
// then postMessage the credential back to window.opener and close. An in-place
// navigation has no opener and destroys the page waiting for the message, so the
// flow hangs (e.g. stuck at accounts.google.com/gsi/transform).
//
// For a SIZED popup (WOD_NEW_POPUP) we instead let CEF create a REAL popup
// browser hosted in a native NSWindow (SetAsChild). window.opener / postMessage /
// window.close all work natively — exactly like a normal browser's sign-in popup.
// The popup is windowed (no OSR render handler), fixed-size, and owns its window's
// lifecycle. It uses the parent's request context (shared cookie jar), so an
// already-signed-in Google session is recognized.
// FCPopupWindowDelegate (the NSWindowDelegate) is declared at global scope
// between the two anonymous namespaces (ObjC decls can't live in a C++
// namespace) — see near CefHostApplication above.
static void OpenNativeAuthPopup(const CefString& url, const CefPopupFeatures& f,
                                CefWindowInfo& window_info,
                                CefRefPtr<CefClient>& client);

class PopupClient : public CefClient,
                    public CefLifeSpanHandler,
                    public CefDisplayHandler {
 public:
  PopupClient(NSWindow* window, FCPopupWindowDelegate* delegate)
      : window_([window retain]), delegate_([delegate retain]) {}

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }

  // Nested windows opened from within the auth popup (consent screens, IdP hops)
  // are part of the same flow — give sized popups their own native window too so
  // opener/postMessage keeps working all the way down. Other dispositions fall
  // through to CEF's default (rare in a sign-in flow).
  bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int,
                     const CefString& target_url, const CefString&,
                     WindowOpenDisposition disposition, bool,
                     const CefPopupFeatures& features, CefWindowInfo& window_info,
                     CefRefPtr<CefClient>& client, CefBrowserSettings&,
                     CefRefPtr<CefDictionaryValue>&, bool*) override {
    if (disposition == CEF_WOD_NEW_POPUP)
      OpenNativeAuthPopup(target_url, features, window_info, client);
    return false;
  }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    if (delegate_) {
      delegate_->browser = browser.get();
      delegate_->alive = YES;
    }
  }

  bool DoClose(CefRefPtr<CefBrowser>) override {
    // Close underway (JS window.close() or a user click). Flip the gate BEFORE
    // CEF destroys the browser so any close-button press CEF synthesizes can't
    // deref a dangling browser in windowShouldClose:.
    if (delegate_) delegate_->alive = NO;
    return false;  // allow the default close; OnBeforeClose then tears down the window
  }

  void OnBeforeClose(CefRefPtr<CefBrowser>) override {
    // Runs inside CEF's teardown of the child NSView. Closing/releasing the
    // window synchronously here re-enters -[NSWindow __close] and can fire the
    // delegate against a half-destroyed browser (EXC_BAD_ACCESS). So: sever the
    // browser pointer NOW (any stray windowShouldClose: then sees nil and no-ops),
    // detach the delegate, and defer the window close + releases to the next
    // main-loop turn, out of the teardown stack.
    NSWindow* win = window_;
    FCPopupWindowDelegate* del = delegate_;
    window_ = nil;
    delegate_ = nil;
    if (del) del->browser = nullptr;
    if (win) [win setDelegate:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
      if (win) {
        [win orderOut:nil];
        [win close];
        [win release];
      }
      if (del) [del release];
    });
  }

  void OnTitleChange(CefRefPtr<CefBrowser>, const CefString& title) override {
    if (window_)
      [window_ setTitle:[NSString stringWithUTF8String:title.ToString().c_str()]];
  }

 private:
  NSWindow* window_;                 // MRC: retained in ctor, released in OnBeforeClose
  FCPopupWindowDelegate* delegate_;  // MRC: retained in ctor, released in OnBeforeClose
  IMPLEMENT_REFCOUNTING(PopupClient);
};

// SPIKE (passkeys): a bare client for a windowed, CHROME-runtime browser. The
// Chrome runtime manages its own native window, toolbar, and — crucially — the
// full WebAuthn stack (Touch ID sheet, account picker, hybrid QR), none of which
// exist in the Alloy/OSR runtime the tiles are forced into. So this needs no
// handlers; it exists to prove a Campus-spawned window can complete a passkey
// ceremony the OSR tile cannot.
class AuthWindowClient : public CefClient {
  IMPLEMENT_REFCOUNTING(AuthWindowClient);
};

// SPIKE: open a real windowed Chrome-runtime browser at |url|, sharing THIS
// process's cookie jar (global request context == the tile's named profile, since
// profiles are per-cef_host-process via root_cache_path). Windowed + Chrome style
// = the WebAuthn UI can actually draw. Env-triggered one-shot from OnAfterCreated.
void OpenChromeAuthWindow(const std::string& url) {
  CefWindowInfo wi;                             // default → windowed, CEF owns the NSWindow
  wi.runtime_style = CEF_RUNTIME_STYLE_CHROME;  // full Chrome UI + WebAuthn stack
  wi.bounds = CefRect(120, 100, 520, 760);      // a plausible sign-in window
  CefBrowserSettings settings;
  CefBrowserHost::CreateBrowser(wi, new AuthWindowClient(), url, settings,
                                nullptr, nullptr);  // nullptr ctx = shared cookies
}

static void OpenNativeAuthPopup(const CefString& url, const CefPopupFeatures& f,
                                CefWindowInfo& window_info,
                                CefRefPtr<CefClient>& client) {
  // Runs on the CEF UI thread, which on macOS (CefRunMessageLoop) is the main
  // thread — safe to build AppKit objects here.
  int w = (f.widthSet && f.width > 0) ? f.width : 480;
  int h = (f.heightSet && f.height > 0) ? f.height : 640;
  if (w < 320) w = 320;
  if (w > 1200) w = 1200;
  if (h < 400) h = 400;
  if (h > 1000) h = 1000;
  NSRect frame = NSMakeRect(0, 0, w, h);
  NSWindow* win = [[NSWindow alloc]
      initWithContentRect:frame
                styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                  backing:NSBackingStoreBuffered
                    defer:NO];
  [win setReleasedWhenClosed:NO];  // MRC: PopupClient releases it explicitly
  [win setTitle:@"Sign in"];
  [win center];
  FCPopupWindowDelegate* del = [[[FCPopupWindowDelegate alloc] init] autorelease];
  [win setDelegate:del];
  // Host the popup browser windowed inside our content view: CEF renders + routes
  // native input for it, and keeps the window.opener relationship intact.
  window_info.SetAsChild((CefWindowHandle)[win contentView], CefRect(0, 0, w, h));
  client = new PopupClient(win, del);  // retains win + del
  [win makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
  [win release];  // drop our alloc +1; PopupClient's retain keeps it alive
}

std::string JsonEscape(const std::string& s);  // defined below

// Flatten Chromium's CefMenuModel into JSON for the Flutter side to draw.
// Recurses one level for submenus (the spellcheck / "Spelling and Grammar"
// blocks are submenus). Separators are emitted so the drawn menu keeps
// Chromium's grouping instead of one undifferentiated list.
std::string SerializeMenuModel(CefRefPtr<CefMenuModel> model) {
  std::string out = "[";
  const size_t n = model->GetCount();
  for (size_t i = 0; i < n; ++i) {
    if (i) out += ",";
    const cef_menu_item_type_t type = model->GetTypeAt(i);
    const int command = model->GetCommandIdAt(i);
    out += "{";
    if (type == MENUITEMTYPE_SEPARATOR) {
      out += "\"type\":\"separator\"";
    } else {
      const char* t = type == MENUITEMTYPE_CHECK      ? "check"
                      : type == MENUITEMTYPE_RADIO    ? "radio"
                      : type == MENUITEMTYPE_SUBMENU  ? "submenu"
                                                      : "command";
      out += "\"type\":\"" + std::string(t) + "\",";
      out += "\"label\":\"" + JsonEscape(model->GetLabelAt(i).ToString()) + "\",";
      out += "\"commandId\":" + std::to_string(command) + ",";
      // Chromium owns enabled/checked — reporting them keeps the drawn menu
      // honest (e.g. Paste greyed out with an empty clipboard) without Campus
      // re-deriving state it cannot see.
      out += "\"enabled\":" +
             std::string(model->IsEnabledAt(i) ? "true" : "false") + ",";
      out += "\"checked\":" +
             std::string(model->IsCheckedAt(i) ? "true" : "false");
      if (type == MENUITEMTYPE_SUBMENU) {
        if (CefRefPtr<CefMenuModel> sub = model->GetSubMenuAt(i)) {
          out += ",\"items\":" + SerializeMenuModel(sub);
        }
      }
    }
    out += "}";
  }
  out += "]";
  return out;
}

class HostClient : public CefClient,
                   public CefLoadHandler,
                   public CefDisplayHandler,
                   public CefLifeSpanHandler,
                   public CefFindHandler,
                   public CefJSDialogHandler,
                   public CefDownloadHandler,
                   public CefRequestHandler,
                   public CefContextMenuHandler,
                   public CefMessageRouterBrowserSide::Handler {
 public:
  explicit HostClient(std::shared_ptr<Slot> slot) : slot_(std::move(slot)) {
    CefMessageRouterConfig config;  // default: window.cefQuery / cefQueryCancel
    router_ = CefMessageRouterBrowserSide::Create(config);
    router_->AddHandler(this, false);
    rh_ = new HostRenderHandler(slot_);
    ph_ = new HostPermissionHandler(slot_);  // deny-default; owner opts in per tile
  }
  CefRefPtr<CefMessageRouterBrowserSide> router_;
  CefRefPtr<CefRenderHandler> rh_;
  CefRefPtr<CefPermissionHandler> ph_;
  CefRefPtr<CefRenderHandler> GetRenderHandler() override { return rh_; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return ph_; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override {
    return this;
  }

  // ── CefContextMenuHandler ──────────────────────────────────────────────
  //
  // Chromium already builds a complete, correctly-stateful context menu for
  // every right-click (back/forward/reload, cut/copy/paste with the right items
  // greyed out, view-source, copy-link-address, the whole spellcheck block with
  // live dictionary suggestions). Without a handler CEF constructs it and throws
  // it away, which is why right-click did nothing in a web tile.
  //
  // We can't let CEF display it: the default display path is a native menu
  // parented to a window, and OSR has none. So RunContextMenu takes over
  // display — serialise the model Chromium built, hand it to Flutter to draw in
  // the Campus design system, and send the chosen command id back so CHROMIUM
  // executes it. That keeps every command's behaviour and enabled/checked state
  // authoritative instead of reimplementing it.
  bool RunContextMenu(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>,
                      CefRefPtr<CefContextMenuParams> params,
                      CefRefPtr<CefMenuModel> model,
                      CefRefPtr<CefRunContextMenuCallback> callback) override {
    CEF_REQUIRE_UI_THREAD();
    if (!slot_ || !params || !model || !callback) return false;
    // An empty model means Chromium had nothing to offer; let the default
    // (no-op) path handle it rather than showing an empty menu.
    if (model->GetCount() == 0) return false;

    uint32_t id;
    {
      std::lock_guard<std::mutex> lock(slot_->surface_mutex);
      id = slot_->next_context_menu_id++;
      slot_->context_menus[id] = callback;
    }

    std::string json = "{";
    json += "\"x\":" + std::to_string(params->GetXCoord()) + ",";
    json += "\"y\":" + std::to_string(params->GetYCoord()) + ",";
    json += "\"editable\":" + std::string(params->IsEditable() ? "true" : "false") + ",";
    json += "\"linkUrl\":\"" + JsonEscape(params->GetLinkUrl().ToString()) + "\",";
    json += "\"sourceUrl\":\"" + JsonEscape(params->GetSourceUrl().ToString()) + "\",";
    json += "\"selectionText\":\"" + JsonEscape(params->GetSelectionText().ToString()) + "\",";
    json += "\"misspelledWord\":\"" + JsonEscape(params->GetMisspelledWord().ToString()) + "\",";
    json += "\"items\":" + SerializeMenuModel(model);
    json += "}";

    std::vector<uint8_t> p(4 + json.size());
    for (int i = 0; i < 4; ++i) p[i] = (id >> (8 * (3 - i))) & 0xff;
    std::memcpy(p.data() + 4, json.data(), json.size());
    SendFrame(slot_->browser_id, kOpContextMenu, p.data(),
              static_cast<uint32_t>(p.size()));
    return true;  // we display it
  }

  // The menu is gone for a reason other than a pick (page navigated, browser
  // destroyed). Drop our pending entry — CEF has already invalidated the
  // callback, so answering it later would be a use-after-free.
  void OnContextMenuDismissed(CefRefPtr<CefBrowser>,
                              CefRefPtr<CefFrame>) override {
    if (!slot_) return;
    std::lock_guard<std::mutex> lock(slot_->surface_mutex);
    slot_->context_menus.clear();
  }

  // CefDownloadHandler: allow downloads (CEF blocks them without a handler) and
  // notify the host. Continue with an empty path + show_dialog so the user picks
  // where to save via the native panel.
  bool OnBeforeDownload(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem>,
                        const CefString& suggested_name,
                        CefRefPtr<CefBeforeDownloadCallback> callback) override {
    SendUtf8(slot_->browser_id, kOpDownload, suggested_name.ToString());
    callback->Continue(CefString(), true);
    return true;
  }

  // CefFindHandler: report find-in-page results to the host.
  void OnFindResult(CefRefPtr<CefBrowser>, int /*identifier*/, int count,
                    const CefRect& /*selectionRect*/, int activeMatchOrdinal,
                    bool finalUpdate) override {
    uint32_t c = static_cast<uint32_t>(count);
    uint32_t a = static_cast<uint32_t>(activeMatchOrdinal);
    uint8_t p[9] = {static_cast<uint8_t>((c >> 24) & 0xff),
                    static_cast<uint8_t>((c >> 16) & 0xff),
                    static_cast<uint8_t>((c >> 8) & 0xff),
                    static_cast<uint8_t>(c & 0xff),
                    static_cast<uint8_t>((a >> 24) & 0xff),
                    static_cast<uint8_t>((a >> 16) & 0xff),
                    static_cast<uint8_t>((a >> 8) & 0xff),
                    static_cast<uint8_t>(a & 0xff),
                    static_cast<uint8_t>(finalUpdate ? 1 : 0)};
    SendFrame(slot_->browser_id, kOpFindResult, p, 9);
  }

  // CefJSDialogHandler: forward alert/confirm/prompt to the host, which shows a
  // native dialog and answers back over the IPC (DoJsDialogResp -> Continue).
  bool OnJSDialog(CefRefPtr<CefBrowser>, const CefString&,
                  JSDialogType dialog_type, const CefString& message_text,
                  const CefString& default_prompt_text,
                  CefRefPtr<CefJSDialogCallback> callback,
                  bool& /*suppress_message*/) override {
    uint32_t id = slot_->dialog_next++;
    slot_->dialogs[id] = callback;
    uint32_t type = dialog_type == JSDIALOGTYPE_ALERT
                        ? 0
                        : (dialog_type == JSDIALOGTYPE_CONFIRM ? 1 : 2);
    std::string msg = message_text.ToString();
    std::string def = default_prompt_text.ToString();
    std::vector<uint8_t> p(12 + msg.size() + def.size());
    uint32_t ml = static_cast<uint32_t>(msg.size());
    for (int i = 0; i < 4; ++i) {
      p[i] = (id >> (24 - 8 * i)) & 0xff;
      p[4 + i] = (type >> (24 - 8 * i)) & 0xff;
      p[8 + i] = (ml >> (24 - 8 * i)) & 0xff;
    }
    memcpy(p.data() + 12, msg.data(), msg.size());
    memcpy(p.data() + 12 + msg.size(), def.data(), def.size());
    SendFrame(slot_->browser_id, kOpJsDialog, p.data(),
              static_cast<uint32_t>(p.size()));
    return true;  // we answer asynchronously via Continue()
  }
  bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser>, const CefString&, bool,
                            CefRefPtr<CefJSDialogCallback> callback) override {
    // Always allow navigation away (don't block on "leave this page?").
    callback->Continue(true, CefString());
    return true;
  }
  // CEF calls this when a pending dialog is dismissed by navigation / reload /
  // renderer death. Drop any held callbacks so they don't leak (the host may
  // never send a response for a dialog the page already abandoned).
  void OnResetDialogState(CefRefPtr<CefBrowser>) override {
    slot_->dialogs.clear();
  }

  // CefDisplayHandler: camera/mic capture started or stopped on this page. This
  // is the ONLY honest source for the URL bar's "in use" indicator — it reflects
  // what Chromium is actually capturing, not what was merely permitted.
  void OnMediaAccessChange(CefRefPtr<CefBrowser>, bool has_video_access,
                           bool has_audio_access) override {
    slot_->media_video_active = has_video_access;
    slot_->media_audio_active = has_audio_access;
    SendMediaState(slot_);
  }

  // Recover from a renderer crash (multi-process only): reload rather than show
  // a dead page. In single-process a renderer CHECK kills the whole process, so
  // this never fires — which is why heavy pages need multi-process.
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                 TerminationStatus status, int /*error_code*/,
                                 const CefString& /*error_string*/) override {
    SendLog(slot_->browser_id, "renderer terminated (status " +
                                   std::to_string(status) + ") — reloading");
    if (router_) router_->OnRenderProcessTerminated(browser);
    if (NoteRendererCrashAndCheckLoop()) {
      // Reloading again would just re-crash: the children can't start. Exit so
      // the embedder's processGone → recreate path takes over (see the detector).
      SendLog(0,
              "renderer crash LOOP (" + std::to_string(kRendererCrashBurstLimit) +
                  " in " + std::to_string(kRendererCrashWindow.count()) +
                  "s) — children cannot start; exiting so the host is respawned");
      DoShutdown();
      return;
    }
    if (browser) browser->ReloadIgnoreCache();
  }

  // CefLoadHandler: spinner + back/forward enablement.
  void OnLoadingStateChange(CefRefPtr<CefBrowser>, bool isLoading,
                            bool canGoBack, bool canGoForward) override {
    SendLoadState(slot_->browser_id, isLoading, canGoBack, canGoForward);
  }
  void OnLoadStart(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                   TransitionType) override {
    if (!frame) return;
    if (frame->IsMain()) {
      SendUtf8(slot_->browser_id, kOpPageStart, frame->GetURL().ToString());
      // A navigation abandons any camera/mic prompt the previous page raised —
      // Cancel the held callbacks so they don't leak (the page that asked is
      // gone and will never be answered). The host dismisses its prompt UI off
      // the url change, mirroring how OnResetDialogState drops JS dialogs.
      for (auto& kv : slot_->media_requests) {
        if (kv.second.callback) kv.second.callback->Cancel();
      }
      slot_->media_requests.clear();
      // Leaving the page stops its capture; don't strand a stale "in use" dot if
      // the teardown's OnMediaAccessChange(false,false) doesn't arrive.
      slot_->media_video_active = false;
      slot_->media_audio_active = false;
      // SECURITY: install the JS-channel shims ONLY into the MAIN frame. The shims expose the
      // privileged campusHost bridge (window.<name> -> window.cefQuery 'ch:'); injecting them
      // into cross-origin SUBFRAMES would hand an untrusted embedded iframe that bridge. (The
      // previous code injected into every frame.) OnQuery also refuses subframe 'ch:'/'eval:'.
      for (const auto& name : g_channels) InjectChannelShim(frame, name);
    }
  }
  void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                 int /*httpStatusCode*/) override {
    if (frame && frame->IsMain()) {
      SendUtf8(slot_->browser_id, kOpPageFinish, frame->GetURL().ToString());
      // Report the new page's remembered camera/mic decision so the URL bar can
      // show a "blocked" indicator for a site Chromium will silently refuse.
      SendMediaState(slot_);
      // C1 + RENDER FLOOR: force a repaint when the main frame finishes. Invalidate(PET_VIEW)
      // ALONE is coalesce-able — the scheduler can drop it, which on a shared GPU/Viz process
      // under a multi-browser establishment burst is exactly when the real-content first frame
      // gets lost, leaving a permanently blank tile though the page loaded. Mirror the proven
      // DoSetVisible visibility-edge kick: re-assert size + damage + a NON-coalesce-able
      // SendExternalBeginFrame, which deterministically drives one renderer frame the scheduler
      // cannot swallow. (slot_->visible gate: a hidden tile must stay paused — F-2.)
      if (browser && browser->GetHost() && slot_->visible) {
        auto h = browser->GetHost();
        h->WasResized();
        h->Invalidate(PET_VIEW);
        h->SendExternalBeginFrame();
      }
    }
  }
  void OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, ErrorCode code,
                   const CefString& text, const CefString& url) override {
    if (code == ERR_ABORTED) return;
    SendCodePlusUtf8(slot_->browser_id, kOpLoadErr, static_cast<uint32_t>(code),
                     url.ToString() + "\n" + text.ToString());
  }

  // CefDisplayHandler: title / address / console -> host.
  void OnTitleChange(CefRefPtr<CefBrowser>, const CefString& title) override {
    SendUtf8(slot_->browser_id, kOpTitle, title.ToString());
  }
  void OnAddressChange(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                       const CefString& url) override {
    if (frame && frame->IsMain())
      SendUtf8(slot_->browser_id, kOpUrl, url.ToString());
  }
  bool OnConsoleMessage(CefRefPtr<CefBrowser>, cef_log_severity_t level,
                        const CefString& message, const CefString& source,
                        int line) override {
    SendCodePlusUtf8(slot_->browser_id, kOpConsole,
                     static_cast<uint32_t>(level),
                     source.ToString() + ":" + std::to_string(line) + "\t" +
                         message.ToString());
    return false;  // also keep CEF's default console logging
  }
  void OnLoadingProgressChange(CefRefPtr<CefBrowser>, double progress) override {
    uint32_t pct = static_cast<uint32_t>(progress * 100.0 + 0.5);
    uint8_t p[4] = {static_cast<uint8_t>((pct >> 24) & 0xff),
                    static_cast<uint8_t>((pct >> 16) & 0xff),
                    static_cast<uint8_t>((pct >> 8) & 0xff),
                    static_cast<uint8_t>(pct & 0xff)};
    SendFrame(slot_->browser_id, kOpProgress, p, 4);
  }

  // H3: async create completes here on the CEF UI thread. Bind the browser to its slot
  // (DoCreateBrowser no longer does — it dropped the blocking CreateBrowserSync) and ack
  // the host so its create-pacer sends the NEXT create: creates serialize by COMPLETION
  // (each browser's render + GPU/Viz accelerated-surface handshake done before the next
  // contends the shared GPU process), not a wall-clock guess.
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    slot_->browser = browser;
    SendFrame(slot_->browser_id, kOpCreated, nullptr, 0);
    // H3: a dispose arrived during the async-create window and recorded intent — honor
    // it now (OnBeforeClose then does the normal map-erase + surface release + retain-
    // cycle break) so we don't leak a live orphan browser the Swift side already forgot.
    if (slot_->close_requested) {
      browser->GetHost()->CloseBrowser(true);
      return;
    }
    // F-3: reconcile a visibility intent that arrived before the browser bound. A
    // setVisible(false) on a still-creating slot ran DoSetVisible with browser==null
    // (WasHidden skipped), so slot_->visible is already false but CEF never heard it —
    // the slot would establish VISIBLE and pump at 60fps off-screen until the next flip.
    // Honor the recorded intent now (mirrors the close_requested deferred-intent pattern).
    if (!slot_->visible) browser->GetHost()->WasHidden(true);
    // Start the external begin-frame pump now that the browser is bound. We turned the internal
    // frame timer OFF (external_begin_frame_enabled), so without this nothing ever paints.
    if (!slot_->begin_frame_pump_started) {
      slot_->begin_frame_pump_started = true;
      PumpBeginFrame(slot_->browser_id);
    }
    // SPIKE (passkeys): one-shot — open a windowed Chrome-runtime auth window on
    // the first tile, so we can test whether a passkey ceremony completes there
    // (it hangs in the OSR/Alloy tile). Off unless FLUTTER_CEF_SPIKE_AUTH_URL set.
    static std::atomic<bool> s_auth_opened{false};
    if (const char* au = std::getenv("FLUTTER_CEF_SPIKE_AUTH_URL")) {
      bool expected = false;
      if (s_auth_opened.compare_exchange_strong(expected, true)) {
        OpenChromeAuthWindow(au);
      }
    }
  }

  // CefLifeSpanHandler: route popups (window.open / target=_blank) to the host
  // instead of opening a native window. Returning true cancels the native popup;
  // the host decides what to do (commonly load the URL in the same view). This
  // mirrors webview_flutter, which surfaces new-window requests through its
  // navigation delegate rather than a separate window.
  bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int,
                     const CefString& target_url, const CefString&,
                     WindowOpenDisposition disposition, bool,
                     const CefPopupFeatures& features, CefWindowInfo& window_info,
                     CefRefPtr<CefClient>& client, CefBrowserSettings&,
                     CefRefPtr<CefDictionaryValue>&, bool*) override {
    // A SIZED popup (window.open with width/height) is the shape OAuth /
    // "Sign in with Google" uses: it needs a real popup with window.opener so it
    // can postMessage the credential back to us. Give it a native window — the
    // in-tab diversion below can never complete that handshake (it would strand
    // the flow at e.g. accounts.google.com/gsi/transform with no opener).
    if (disposition == CEF_WOD_NEW_POPUP) {
      OpenNativeAuthPopup(target_url, features, window_info, client);
      return false;  // allow CEF to create the popup browser in our native window
    }
    // target=_blank / plain new tab: keep loading it in this single-view tile.
    if (!target_url.empty())
      SendUtf8(slot_->browser_id, kOpNewWindow, target_url.ToString());
    return true;
  }

  // The page's cursor (I-beam over text, hand over links, etc.). Forward the
  // type to the host so it can drive the Flutter MouseRegion cursor.
  bool OnCursorChange(CefRefPtr<CefBrowser>, CefCursorHandle,
                      cef_cursor_type_t type, const CefCursorInfo&) override {
    uint8_t p[4];
    uint32_t t = static_cast<uint32_t>(type);
    p[0] = (t >> 24) & 0xff;
    p[1] = (t >> 16) & 0xff;
    p[2] = (t >> 8) & 0xff;
    p[3] = t & 0xff;
    SendFrame(slot_->browser_id, kOpCursor, p, 4);
    return true;
  }

  // CefMessageRouter wiring: the renderer half (process_helper.mm) injects
  // window.cefQuery; queries land here. We forward the request string to the
  // host: "eval:<id>:<json>" for a runJavaScriptReturningResult result,
  // "ch:<name>:<message>" for a JS-channel post.
  bool OnQuery(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, int64_t,
               const CefString& request, bool,
               CefRefPtr<Callback> callback) override {
    std::string r = request.ToString();
    // SECURITY: 'eval:' (host-eval result channel) and 'ch:' (campusHost bridge) are
    // PRIVILEGED — they reach the trusted host eval/result path and the agent_ui reducer. The
    // shim is injected per-frame, so a cross-origin / untrusted IFRAME could forge them. Honor
    // them ONLY from the MAIN frame (the host-trusted document); refuse subframe queries.
    const bool main_frame = !frame || frame->IsMain();
    if (r.rfind("eval:", 0) == 0) {
      if (!main_frame) { callback->Failure(403, "subframe"); return true; }
      SendUtf8(slot_->browser_id, kOpEvalResult, r.substr(5));
      callback->Success(CefString());
      return true;
    }
    if (r.rfind("ch:", 0) == 0) {
      if (!main_frame) { callback->Failure(403, "subframe"); return true; }
      SendUtf8(slot_->browser_id, kOpChannelMsg, r.substr(3));
      callback->Success(CefString());
      return true;
    }
    return false;
  }
  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                CefProcessId source_process,
                                CefRefPtr<CefProcessMessage> message) override {
    return router_->OnProcessMessageReceived(browser, frame, source_process,
                                             message);
  }
  // Centralized per-browser teardown (CEF UI thread). CloseBrowser(true) — sent
  // by DoDisposeBrowser or DoShutdown — lands here. Drop the routing-map entries
  // (so no inbound op or paint can find this slot again), release the host
  // IOSurface under the slot's lock (nulling it FIRST so a GPU-thread paint
  // racing this teardown sees null and no-ops, then CFRelease the old surface),
  // and break the HostClient -> Slot -> CefBrowser -> HostClient retain cycle by
  // nulling slot_->browser. The last shared_ptr<Slot> drops once any in-flight
  // paint refs (which copied the shared_ptr) drain.
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    if (router_) router_->OnBeforeClose(browser);
    // Answer nothing and release everything: a tile closed with a camera/mic
    // prompt still up must not leave a held callback behind.
    for (auto& kv : slot_->media_requests) {
      if (kv.second.callback) kv.second.callback->Cancel();
    }
    slot_->media_requests.clear();
    {
      std::lock_guard<std::mutex> lock(g_slots_mutex);
      g_slots_by_wire_id.erase(slot_->browser_id);
    }
    {
      std::lock_guard<std::mutex> lock(slot_->surface_mutex);
      slot_->closing = true;  // BEFORE nulling: a paint racing this must not re-mint a surface
      IOSurfaceRef old = slot_->surface;
      slot_->surface = nullptr;
      if (old) CFRelease(old);  // drop cef_host's last +1; consumer's CVPixelBuffer keeps it alive
      [slot_->dst_mtl release];
      slot_->dst_mtl = nil;
      slot_->dst_mtl_sid = 0;
    }
    slot_->browser = nullptr;
  }
  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request, bool, bool) override {
    if (!g_allowed_schemes.empty()) {
      const std::string url = request->GetURL().ToString();
      // Only gate MAIN-frame navigations. A subframe can't change the view's
      // top-level origin (it's already same-policy-constrained by Chromium), and
      // gating subframes would cancel legitimate cross-scheme embeds — blob: /
      // data: iframes, PDF/video viewers, ad frames — breaking real pages.
      const bool main_frame = !frame || frame->IsMain();
      // A host content-injection load (loadHtmlString -> data:, loadFile ->
      // file:) armed an exact-URL exemption in DoNavigateTrusted. Honor it only
      // for the matching main-frame request, and consume that one entry, so a
      // page navigation to a different URL can't steal it. A redirect of a
      // trusted load carries a different URL and so remains gated.
      bool host_trusted = false;
      if (main_frame) {
        auto it = slot_->trusted_pending.find(url);
        if (it != slot_->trusted_pending.end()) {
          slot_->trusted_pending.erase(it);
          host_trusted = true;
        }
      }
      if (main_frame && !host_trusted) {
        const size_t colon = url.find(':');
        std::string scheme =
            colon == std::string::npos ? std::string() : url.substr(0, colon);
        std::transform(scheme.begin(), scheme.end(), scheme.begin(),
                       [](unsigned char c) { return std::tolower(c); });
        // `view-source:` is judged by what it wraps: viewing the source of a
        // page you were already allowed to LOAD grants no new reach (it renders
        // bytes as text and runs nothing), whereas refusing it silently breaks
        // Chromium's own View Page Source menu command. `view-source:file:///…`
        // stays refused, because `file` is not in the allowlist.
        //
        // Nesting is not recursive in Chromium (`view-source:view-source:` is
        // rejected upstream), so one unwrap is the whole story.
        if (scheme == "view-source") {
          const std::string inner = url.substr(colon + 1);
          const size_t inner_colon = inner.find(':');
          std::string inner_scheme = inner_colon == std::string::npos
                                         ? std::string()
                                         : inner.substr(0, inner_colon);
          std::transform(inner_scheme.begin(), inner_scheme.end(),
                         inner_scheme.begin(),
                         [](unsigned char c) { return std::tolower(c); });
          if (g_allowed_schemes.count(inner_scheme) == 0) {
            return true;  // cancel — the wrapped scheme is not permitted
          }
        } else if (scheme != "about" &&
                   g_allowed_schemes.count(scheme) == 0) {
          // `about:` (blank placeholder) is always allowed; anything else must
          // be in the host allowlist or the navigation is refused.
          return true;  // cancel
        }
      }
    }
    if (router_) router_->OnBeforeBrowse(browser, frame);
    return false;  // allow
  }

 private:
  std::shared_ptr<Slot> slot_;

  IMPLEMENT_REFCOUNTING(HostClient);
};

class HostApp : public CefApp, public CefBrowserProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }
  void OnBeforeCommandLineProcessing(
      const CefString&, CefRefPtr<CefCommandLine> command_line) override {
    // Chromium parses --disable-features ONCE: a second occurrence of the
    // switch REPLACES the first rather than unioning with it, so appending our
    // own would silently re-enable whatever an earlier block turned off (most
    // dangerously the ad-hoc MachPortRendezvous bypass below, whose loss
    // -67030s the multi-process GPU→browser handoff and blanks every tile).
    // Every disable therefore accumulates here and is emitted as ONE
    // comma-joined value at the bottom of this hook. Do not call
    // AppendSwitchWithValue("disable-features", …) anywhere else.
    std::vector<std::string> disabled_features;
    // Effective memory-lever configuration, captured for the one-line startup
    // log at the bottom (see there for why it is unconditional).
    bool no_spare_renderer = false;

    // OSR establishment-latency: OSR views have no real OS window, so Chromium's scheduler
    // treats every renderer as backgrounded/occluded and LOWERS its process priority during
    // the critical first load — delaying the first frame of a tile that's actually visible
    // in our canvas. Keeping the renderer at full priority ~halved time-to-first-paint for a
    // 20-real-site board (measured), with no race/security change. Default ON; opt out with
    // FLUTTER_CEF_KEEP_BG_THROTTLE for debugging. NOTE: we deliberately do NOT add
    // --disable-background-timer-throttling — that would keep HIDDEN (off-screen, WasHidden)
    // tiles' JS timers running hot, fighting the off-screen-is-cheap property; the priority
    // flags below are what speed establishment without that cost.
    if (!std::getenv("FLUTTER_CEF_KEEP_BG_THROTTLE")) {
      command_line->AppendSwitch("disable-renderer-backgrounding");
      command_line->AppendSwitch("disable-backgrounding-occluded-windows");
    }

    // ---- Memory levers (both opt-in; unset == today's behaviour) -----------
    // Measured shape of this process tree on macOS (phys_footprint, not summed
    // RSS — the 307 MB Chromium framework is mapped into every process, so
    // summed RSS overstates by ~3.4x): 158 MB fixed + 33-42 MB per live
    // webview, r²=0.9997, with processes = N+5 and renderers = N+1 for N views.
    // The renderers are the whole per-view slope: at N=16 that is 17 x ~28 MB
    // = ~476 MB of a 689 MB total. Each lever below trades a specific,
    // user-visible property for part of that slope, so each is env-gated and
    // OFF by default — they can be A/B'd on one binary without a rebuild.

    // NOT A LEVER: --renderer-process-limit. Recorded because it is the obvious
    // next idea and it does NOT work here, so the next person should not spend
    // the day we spent. The intent would be that above the cap Chromium reuses
    // renderers instead of spawning, trading isolation for memory. MEASURED on
    // this build (CEF 144 / chromium-144.0.7559.254): Chromium treats it as a
    // SOFT limit and still gives every CEF windowless browser a DEDICATED
    // renderer. At N=8 browsers the renderer count was 8 for caps of 1, 2, 4
    // and 8 alike — never the cap; at N=16 under a cap of 8 there were 16.
    // The value does reach Chromium — cap=99 kept the spare (9 renderers),
    // cap<=8 dropped it (8) — so its ONLY enforced effect is declining to warm
    // the spare, which is a strictly weaker version of the lever below. It
    // recovers none of the per-view slope, so there is nothing here to ship.

    // THE LEVER — drop Chromium's SPARE renderer. The browser process keeps one
    // extra pre-warmed renderer per profile so the next navigation can skip
    // process startup; it is why renderers measure N+1 at EVERY N, including
    // N=1, and it costs ~23-24 MB permanently and PER PROFILE (so it compounds
    // with profile count, and we spawn one cef_host per profile). THE COST IS
    // FIRST-PAINT LATENCY on the NEXT tile created: that navigation now pays a
    // cold renderer launch instead of adopting a warm one. Nothing already
    // rendering is affected.
    //
    // Feature name verified against THIS build's vendored Chromium
    // (CEF 144.0.27 / chromium-144.0.7559.254, see native/build_cef_host.sh):
    // "SpareRendererForSitePerProcess" appears verbatim in the shipped
    // "Chromium Embedded Framework" binary, next to the source path
    // content/browser/renderer_host/spare_render_process_host_manager_impl.cc
    // that gates on it — i.e. it is this framework's own feature string, not a
    // name carried over from an older branch.
    // DEFAULT ON. Measured on the always-live bench (phys_footprint, shared
    // profile, N in {1,2,4,8,16}): renderer count drops from N+1 to exactly N at
    // every N, and the fitted fixed term falls 149.5 -> 126.2 MB — ~23 MB back
    // per CEF PROFILE, so it compounds with however many profiles a host app
    // declares. The cost is one cold renderer launch for the NEXT browser
    // created: first paint 38 -> 69 ms (~+31 ms). Nothing already rendering is
    // touched, and no browser shares a process with another, so there is no
    // neighbour-jank trade here.
    //
    // Opt BACK IN with FLUTTER_CEF_SPARE_RENDERER=1 when first-paint latency of
    // a newly created browser matters more than ~23 MB.
    const char* spare_env = std::getenv("FLUTTER_CEF_SPARE_RENDERER");
    const bool keep_spare =
        spare_env != nullptr && spare_env[0] != '\0' &&
        std::strcmp(spare_env, "0") != 0;
    if (!keep_spare) {
      no_spare_renderer = true;
      disabled_features.push_back("SpareRendererForSitePerProcess");
    }
    // ------------------------------------------------------------------------

#ifdef CEF_HOST_ADHOC
    // Dev / ad-hoc-only (CEF_HOST_ADHOC is ON by default; a signed release sets
    // -DCEF_HOST_ADHOC=OFF). Mock keychain + basic password store so a launch
    // doesn't raise the macOS Keychain access prompt every time. A signed
    // release omits these and uses the real Keychain via OSCrypt.
    command_line->AppendSwitch("use-mock-keychain");
    command_line->AppendSwitchWithValue("password-store", "basic");
#endif
#ifndef CEF_HOST_MULTIPROCESS
    // Single-process (-DCEF_MULTI_PROCESS=OFF; NOT the default): renderer + GPU
    // + utility all share this process, so there are no Mach-port peers to
    // validate (Chromium 144's -67030). The catch: heavy pages whose work lands
    // on the in-process utility thread (e.g. Google sign-in probing WebAuthn/HID
    // security keys) can CHECK-crash the whole process. It's best for
    // simpler/first-party content; the default multi-process build isolates
    // those crashes.
    command_line->AppendSwitch("single-process");
#endif
#ifdef CEF_HOST_ADHOC
    // Dev / ad-hoc-only: disable Chromium 144's Mach-port peer-requirement
    // validation, which otherwise -67030s the multi-process GPU→browser handoff
    // (OnAcceleratedPaint) under an ad-hoc signature. (Harmless in
    // single-process, where there are no peers to validate.) Together with the
    // shared-texture GPU OSR path this lets the accelerated path run
    // multi-process (crash-isolated) WITHOUT Developer-ID signing. A signed
    // release omits this and enforces validation, which then requires correct
    // inside-out Developer-ID signing of the cef_host tree. Accumulated (not
    // appended) so a later --disable-features can't clobber it — see the
    // disabled_features declaration at the top of this hook.
    disabled_features.push_back("MachPortRendezvousValidatePeerRequirements");
    disabled_features.push_back("MachPortRendezvousEnforcePeerRequirements");
#endif
    // Verbose Chromium logging to /tmp only when explicitly debugging; off by
    // default so a shipped build doesn't write logs behind the user's back.
    if (std::getenv("FLUTTER_CEF_DEBUG")) {
      command_line->AppendSwitch("enable-logging");
      command_line->AppendSwitchWithValue("log-file", "/tmp/cef_host_chromium.log");
      command_line->AppendSwitchWithValue("v", "1");
    }
    // CDP WebSocket origin allow-list: Chromium M113+ rejects DevTools WS
    // connections whose Origin isn't allow-listed (anti-CSRF on the local debug
    // port). We do NOT widen it with "*": the wildcard would disable that only
    // origin/CSRF guard on the unauthenticated localhost debugger. CDP stays
    // 127.0.0.1-bound and ephemeral-only (rejected on a persistent profile), and
    // clients that need WS access pass their own --remote-allow-origins out of
    // band; the default (no Origin / same-origin) still connects.

    // Agent-control / pipe mode (opt-in via --cdp-pipe, gated by g_cdp_pipe).
    // This hook only runs for the browser process (process_type empty), so no
    // explicit process_type check is needed. Inject "remote-debugging-pipe" so
    // Chromium's DevToolsPipeHandler speaks CDP over inherited fds (3=read /
    // 4=write) instead of a TCP port — there is no listening socket, so the
    // ONLY CDP client is the process that launched cef_host with those fds (the
    // Swift plugin). Default (ASCIIZ) framing: each CDP message is UTF-8 JSON
    // followed by a single 0x00 NUL byte, both directions (Puppeteer
    // PipeTransport). Deliberately NOT "remote-debugging-pipe=cbor". This MUST
    // go through this hook: the argv-scrub in main() hands CEF only argv[0], so
    // the switch can't ride in via clean_argv.
    if (g_cdp_pipe) {
      command_line->AppendSwitch("remote-debugging-pipe");
      // Chromium turns on the "AutomationControlled" blink feature whenever
      // remote debugging is active, which exposes `navigator.webdriver === true`.
      // Sites that gate on it (Google's OAuth — "this browser or app may not be
      // secure") then refuse human sign-in. We drive the page over CDP, never
      // WebDriver, so suppressing that one signal costs us nothing and lets a
      // user log in to a tile that's simultaneously agent-controllable. Does NOT
      // affect the DevTools pipe / CDP itself — only the JS-visible flag.
      command_line->AppendSwitchWithValue("disable-blink-features",
                                          "AutomationControlled");
    }

    // The ONE --disable-features emission (see the top of this hook: a second
    // occurrence would replace, not extend, this one).
    std::string disabled_features_value;
    for (const std::string& feature : disabled_features) {
      if (!disabled_features_value.empty()) disabled_features_value += ',';
      disabled_features_value += feature;
    }
    if (!disabled_features_value.empty()) {
      command_line->AppendSwitchWithValue("disable-features",
                                          disabled_features_value);
    }

    // Unconditional, one line, once per browser process (CEF calls this hook
    // only for process_type == "", see the CDP note above). Deliberately NOT
    // behind FLUTTER_CEF_DEBUG: an A/B memory sweep needs positive in-band
    // proof of which configuration the process ACTUALLY started with —
    // including the control arm, where "no levers" is itself the claim being
    // measured. Silently measuring the wrong build is the recurring failure
    // mode, and one stderr write per process launch is the cheapest cure.
    // Unlike --enable-logging this writes no file and leaks nothing about the
    // user's browsing — it names only our own switch configuration.
    fprintf(stderr,
            "[cef_host] mem-levers spare-renderer=%s disable-features=%s\n",
            no_spare_renderer ? "disabled" : "kept",
            disabled_features_value.empty() ? "(none)"
                                            : disabled_features_value.c_str());
  }
  // No browser is created here. We only announce readiness; the host then drives
  // browser creation on demand via kOpCreateBrowser (one per CefWebView sharing
  // this profile). Nothing loads — and nothing is written to the profile cache —
  // until the first kOpCreateBrowser, which is the safety window the host uses to
  // refuse a persistent profile under a mock-keychain (ad-hoc) build (F.5). The
  // payload is [readyFlags (bit0 = ad-hoc build), protocolVersion] — the version
  // byte lets the host refuse a protocol-skewed binary at the handshake instead of
  // silently mis-parsing every later frame.
  void OnContextInitialized() override {
    CEF_REQUIRE_UI_THREAD();
    if (std::getenv("FLUTTER_CEF_DEBUG"))
      fprintf(stderr, "[cef_host] OnContextInitialized\n");
    uint8_t ready_flags = 0;
#ifdef CEF_HOST_ADHOC
    ready_flags |= 0x01;  // bit0 = ad-hoc / mock-keychain build
#endif
    const uint8_t ready_payload[2] = {ready_flags, kCefHostProtocolVersion};
    SendFrame(/*browser_id=*/0, kOpReady, ready_payload, sizeof(ready_payload));
  }
  IMPLEMENT_REFCOUNTING(HostApp);
};

// ---- CEF-thread task helpers (IPC reader runs off the UI thread) ----

// Create a windowless browser for a CefWebView (kOpCreateBrowser). Runs on the
// CEF UI thread. wire_id is the Swift-assigned browser id this slot is keyed by;
// sid is the host's IOSurface for this view (0 / lookup-failure -> no surface
// until the first resize). Builds the Slot, registers it in both routing maps,
// and creates the CEF browser bound to a HostClient that holds the slot.
void DoCreateBrowser(uint32_t wire_id, int w, int h, double dpr,
                     std::string url) {
  CEF_REQUIRE_UI_THREAD();
  // WIRE-ID REUSE GUARD: the Swift side allocates ids monotonically, so a collision should be
  // impossible — but if one ever happened, registering the new slot would let the OLD browser's
  // OnBeforeClose later erase the NEW slot (g_slots_by_wire_id.erase(id)), leaving an unroutable
  // browser + a leaked IOSurface/dst_mtl. Fail loudly + tell the host (kOpCreateFailed advances
  // its pacer / drops the session) instead of silently corrupting cross-tile routing.
  {
    std::lock_guard<std::mutex> lock(g_slots_mutex);
    if (g_slots_by_wire_id.count(wire_id)) {
      SendLog(wire_id, "createBrowser: wire id already in use — refusing (id-reuse bug)");
      SendFrame(wire_id, kOpCreateFailed, nullptr, 0);
      return;
    }
  }
  auto slot = std::make_shared<Slot>();
  slot->browser_id = wire_id;
  slot->width = w < 1 ? 1 : w;
  slot->height = h < 1 ? 1 : h;
  slot->dpr = dpr;
  // PRODUCER-ALLOCATES: no surface is created here. slot->surface stays nullptr until the first
  // OnAcceleratedPaint, where EnsureSurfaceForPaint mints it sized to the actual painted view.
  // The consumer adopts that surface's id from the first present.
  {
    std::lock_guard<std::mutex> lock(g_slots_mutex);
    g_slots_by_wire_id[wire_id] = slot;
  }
  CefWindowInfo window_info;
  window_info.SetAsWindowless(0);
#ifdef CEF_HOST_MULTIPROCESS
  // Multi-process GPU OSR: the GPU/Viz process composites on the GPU and hands
  // the frame to OnAcceleratedPaint as a shared IOSurface, which we copy into
  // the host surface. This used to be gated by -67030 (process_requirement.cc
  // peer validation of this process's ad-hoc signature), but disabling the
  // MachPortRendezvous*PeerRequirements features above clears it — so the
  // GPU-accelerated path runs multi-process (crash-isolated) without
  // Developer-ID signing. (The software OnPaint path remains the fallback if a
  // build leaves shared_texture_enabled off.) All browsers in this process share
  // one GPU/Viz process; set per-create, it resolves to that same process (the
  // second+ browser attaching cleanly is the one multiplex behavior to confirm
  // at runtime under a signed build — see CONTRACT H.6).
  window_info.shared_texture_enabled = true;
#endif
  // Own the frame clock. Without this CEF's internal scheduler decides when to paint and can
  // skip the frame after a resize (a resize is viewport-only damage on an idle page), leaving
  // the tile stuck at the old size until real input forces a tick. With external begin-frame WE
  // drive every frame via SendExternalBeginFrame (the per-slot PumpBeginFrame), so a resize —
  // and all rendering — always produces a frame. NOTE: this turns the internal timer OFF, so the
  // pump MUST run for anything to render at all (started in OnAfterCreated).
  window_info.external_begin_frame_enabled = true;
  CefBrowserSettings settings;
  settings.windowless_frame_rate = 60;
  // RENDER FLOOR: paint an OPAQUE background. With the default (alpha 0) a windowless
  // browser paints transparent, so a DROPPED renderer frame — the shared-GPU multiplex
  // failure where the 2nd+ browser's CompositorFrame never lands — is INVISIBLE (the canvas
  // shows through) and indistinguishable from "loading". Opaque means a missing frame reads
  // as a blank white tile (correct-looking for a not-yet-painted page) instead of a ghost,
  // and makes the failure diagnosable. Pages with their own bg paint over this normally.
  settings.background_color = CefColorSetARGB(255, 255, 255, 255);
  // about:blank-first: for a real http(s) URL, establish on about:blank (near-instant
  // first frame → the pacer's establishment slot frees fast) and defer the real
  // navigation to first paint. Skip for data:/file:/about: (already instant) and when the
  // env flag is off.
  std::string create_url = url;
  if (std::getenv("FLUTTER_CEF_BLANK_FIRST") &&
      (url.rfind("http://", 0) == 0 || url.rfind("https://", 0) == 0)) {
    slot->pending_nav_url = url;
    create_url = "about:blank";
  }
  // create-with-html/file: a data:/file: create URL is host-trusted content
  // injection (the same schemes loadHtmlString/loadFile use via kOpLoadTrusted),
  // and can NEVER arise from an untrusted page navigation — the scheme allowlist
  // refuses data:/file: in OnBeforeBrowse. So arm the trusted-load exemption for
  // the INITIAL load here, exactly as DoNavigateTrusted does, letting a consumer
  // create the browser directly on its authored document in ONE step (no
  // about:blank + later loadHtmlString, which raced blank). Identical trust model
  // to a post-create loadTrusted; only the timing (at create) differs.
  if (!g_allowed_schemes.empty() &&
      (create_url.rfind("data:", 0) == 0 ||
       create_url.rfind("file:", 0) == 0)) {
    slot->trusted_pending.insert(create_url);
  }
  CefRefPtr<HostClient> client = new HostClient(slot);
  // H3: ASYNC create. CreateBrowserSync BLOCKS this (the single CEF UI) thread until
  // the renderer + GPU/Viz accelerated-surface handshake completes — so a burst of
  // creates serialized here, contended the one shared GPU process (later browsers got
  // no surface, never painted), and one hung create wedged input/resize/dispose for
  // every sibling. CreateBrowser returns immediately; the browser is bound to its slot
  // in HostClient::OnAfterCreated, which acks kOpCreated so the host's pacer sends the
  // NEXT create — serialized by COMPLETION, not a wall-clock guess.
  bool dispatched = CefBrowserHost::CreateBrowser(
      window_info, client, create_url, settings, nullptr, nullptr);
  if (!dispatched) {
    // H7: the create couldn't even be dispatched — OnAfterCreated/OnBeforeClose will
    // never fire, so reclaim the slot + the looked-up IOSurface (+1 ref) here (else
    // they leak and the wire id is stranded) and tell the host so it drops the session
    // (processGone) and its create-pacer advances instead of stalling on the ack.
    SendLog(wire_id, "createBrowser: CreateBrowser dispatch failed");
    SendFrame(wire_id, kOpCreateFailed, nullptr, 0);
    {
      std::lock_guard<std::mutex> lock(g_slots_mutex);
      g_slots_by_wire_id.erase(wire_id);
    }
    std::lock_guard<std::mutex> slock(slot->surface_mutex);
    if (slot->surface) {
      CFRelease(slot->surface);
      slot->surface = nullptr;
    }
    [slot->dst_mtl release];
    slot->dst_mtl = nil;
    slot->dst_mtl_sid = 0;
  }
  if (std::getenv("FLUTTER_CEF_DEBUG"))
    fprintf(stderr, "[cef_host] createBrowser wire=%u dispatched=%d\n", wire_id,
            dispatched);
}

// Close one browser (kOpDisposeBrowser). Runs on the CEF UI thread. The actual
// map-erase + surface release happen in OnBeforeClose once CEF finishes closing.
void DoDisposeBrowser(uint32_t wire_id) {
  CEF_REQUIRE_UI_THREAD();
  std::shared_ptr<Slot> slot = LookupWireId(wire_id);
  if (!slot) return;
  if (slot->browser) {
    slot->browser->GetHost()->CloseBrowser(true);
  } else {
    // H3: the async CreateBrowser hasn't bound the browser yet — record the close so
    // OnAfterCreated closes it the instant it lands. Without this the create completes
    // into a live orphan browser the Swift side has already forgotten (browsers[id]
    // cleared), leaking a renderer + IOSurface until whole-host shutdown.
    slot->close_requested = true;
  }
}

void DoResize(const std::shared_ptr<Slot>& slot, int w, int h, double dpr) {
  if (w < 1 || w > 16384 || h < 1 || h > 16384) {
    SendLog(slot->browser_id, "resize: out-of-range dims " + std::to_string(w) +
                                  "x" + std::to_string(h));
    return;
  }
  // PRODUCER-ALLOCATES: resize no longer touches the surface — it only updates the logical
  // geometry + dpr and kicks CEF to re-raster. CEF then paints a new-size view_src, and
  // EnsureSurfaceForPaint (in the composite path) reallocates slot->surface to match + the next
  // present hands the consumer the new id. So there is no IOSurfaceLookup/CFRelease-swap here
  // (that was the consumer-allocates handoff that could crop when src≠dst). dpr<=0 = unchanged.
  bool dpr_changed = false;
  {
    std::lock_guard<std::mutex> lock(slot->surface_mutex);
    slot->width = w;
    slot->height = h;
    if (dpr > 0.0 && dpr != slot->dpr) {
      slot->dpr = dpr;
      dpr_changed = true;
    }
    // dst_mtl is rebuilt by EnsureSurfaceForPaint on the realloc; nil it here too so a same-size
    // relayout that doesn't realloc still drops a wrap that could be mid-rebuild (belt + suspenders).
    [slot->dst_mtl release];
    slot->dst_mtl = nil;
    slot->dst_mtl_sid = 0;
  }
  if (slot->browser) {
    if (slot->visible) {
      // A device-scale change needs the renderer told (screen info), not just a relayout.
      if (dpr_changed) slot->browser->GetHost()->NotifyScreenInfoChanged();
      slot->browser->GetHost()->WasResized();
      // Drive a frame right now at the new size. With external begin-frame this is a guaranteed
      // tick (not a coalesce-able Invalidate request), so the re-laid-out content composites into
      // the new surface immediately; PumpBeginFrame's ongoing ticks cover the heavy-page settle.
      slot->browser->GetHost()->SendExternalBeginFrame();
    } else {
      // F-2: HIDDEN — the begin-frame pump is gated off (PumpBeginFrame skips while
      // !visible), so WasResized()+SendExternalBeginFrame() here would never paint the
      // freshly-swapped (blank) surface, yet the Swift resizeWatchdog would force-promote
      // it to the live texture → permanent blank on a static page. The surface + dims are
      // already swapped above (geometry is current); defer the screen-info re-assert + the
      // repaint to DoSetVisible's hidden->visible edge (F-1). WasResized while hidden is
      // pointless (no frame can result), so it is dropped, not deferred.
      if (dpr_changed) slot->needs_screen_info_on_show = true;
    }
  }
}

void DoNavigate(const std::shared_ptr<Slot>& slot, const std::string& url) {
  if (!slot->browser) {
    // The slot exists but the browser is not yet BOUND (OnAfterCreated pending) — e.g. a
    // loadHtmlString that arrived right behind a queued createBrowser in a shared-host burst
    // (6 agent_ui tiles created at once). Defer instead of dropping: the first-paint handler
    // applies pending_nav_url once the browser binds, and a trusted load keeps its armed
    // exemption in trusted_pending. Dropping here is exactly why such a burst stayed blank.
    slot->pending_nav_url = url;
    return;
  }
  CefRefPtr<CefFrame> f = slot->browser->GetMainFrame();
  if (f) f->LoadURL(url);
}

// A host content-injection load (loadHtmlString -> data:, loadFile -> file:).
// Runs on the CEF UI thread. Arm an exact-URL exemption so this specific load's
// OnBeforeBrowse (a later UI task) skips the scheme allowlist, while a page nav
// to any other URL stays gated. Only arm when an allowlist is actually set —
// g_allowed_schemes is immutable after startup, so when the feature is off this
// is a plain navigate and we don't accumulate unconsumed entries. Trusted
// because the host explicitly chose this content, not the page.
void DoNavigateTrusted(const std::shared_ptr<Slot>& slot,
                       const std::string& url) {
  if (!g_allowed_schemes.empty()) slot->trusted_pending.insert(url);
  DoNavigate(slot, url);
}

// Navigate / loadTrusted resolved by wire id ON the UI thread, not the reader thread. On a
// shared host the createBrowser for this id is queued ahead of us on TID_UI (FIFO ordering),
// so LookupWireId is null on the reader thread but registered by the time this task runs —
// dropping the op on the reader thread (the old `if (!slot) break`) is why a burst of tiles
// that loadHtmlString right after create stayed blank. Mirrors the kOpAddChannel fix. With
// trusted=true the allowlist exemption is armed and a not-yet-bound browser is tolerated via
// pending_nav_url (DoNavigate above).
void DoNavigateByWireId(uint32_t wire_id, std::string url, bool trusted) {
  auto slot = LookupWireId(wire_id);
  if (!slot) return;  // genuinely disposed before the nav landed
  if (trusted)
    DoNavigateTrusted(slot, url);
  else
    DoNavigate(slot, url);
}

void DoReload(const std::shared_ptr<Slot>& slot) {
  if (slot->browser) slot->browser->Reload();
}
void DoStopLoad(const std::shared_ptr<Slot>& slot) {
  if (slot->browser) slot->browser->StopLoad();
}
void DoGoBack(const std::shared_ptr<Slot>& slot) {
  if (slot->browser) slot->browser->GoBack();
}
void DoGoForward(const std::shared_ptr<Slot>& slot) {
  if (slot->browser) slot->browser->GoForward();
}
void DoExecuteJs(const std::shared_ptr<Slot>& slot, const std::string& code) {
  if (!slot->browser) return;
  CefRefPtr<CefFrame> f = slot->browser->GetMainFrame();
  if (f) f->ExecuteJavaScript(code, "", 0);
}
void DoSetZoom(const std::shared_ptr<Slot>& slot, double level) {
  if (slot->browser) slot->browser->GetHost()->SetZoomLevel(level);
}
// Run a browser edit command on the FOCUSED frame. OSR has no AppKit responder
// chain, so a raw ⌘C/⌘V key event never becomes an editor action — the host
// invokes these explicitly (CefWebView wires the shortcuts). CefFrame's methods
// are no-ops when nothing is focused/selected. UI-thread only.
void DoEditCommand(const std::shared_ptr<Slot>& slot, int command) {
  CEF_REQUIRE_UI_THREAD();
  if (!slot->browser) return;
  CefRefPtr<CefFrame> frame = slot->browser->GetFocusedFrame();
  if (!frame) return;
  switch (command) {
    case 0: frame->Copy(); break;
    case 1: frame->Cut(); break;
    case 2: frame->Paste(); break;
    case 3: frame->SelectAll(); break;
    case 4: frame->Undo(); break;
    case 5: frame->Redo(); break;
    default: break;
  }
}
// Off-screen render gating. WasHidden(true) makes CEF stop producing frames
// (no OnPaint, the compositor idles) until WasHidden(false); the browser stays
// alive, so this is a cheap pause/resume — not a teardown. The host pauses a
// tile that scrolls fully out of the canvas viewport and resumes it on return.
void DoSetVisible(const std::shared_ptr<Slot>& slot, bool visible) {
  const bool was_visible = slot->visible;
  slot->visible = visible;  // PumpBeginFrame reads this to idle the begin-frame pump while hidden
  if (!slot->browser) return;
  slot->browser->GetHost()->WasHidden(!visible);
  // F-1 (keystone): on the hidden->visible edge, FORCE a fresh full-viewport repaint at the
  // current geometry. WasHidden(false) alone does NOT repaint, and three things can have left
  // the live texture blank/stale while hidden: (a) a resize landed while the pump was gated off
  // (F-2 deferred its paint here); (b) a dpr/screen-info change was deferred; (c) Chromium's
  // FrameEvictionManager reclaimed the off-screen compositor frame entirely (happens past ~5
  // browsers / under memory pressure) so there is nothing to show even though geometry is
  // unchanged. Re-assert screen info (if a dpr change was deferred) + size, then drive a
  // guaranteed frame — mirrors DoResize/DoInvalidate. Unconditional on the edge because the
  // eviction case carries no resize to key off.
  if (visible && !was_visible) {
    if (slot->needs_screen_info_on_show) {
      slot->browser->GetHost()->NotifyScreenInfoChanged();
      slot->needs_screen_info_on_show = false;
    }
    slot->browser->GetHost()->WasResized();
    slot->browser->GetHost()->Invalidate(PET_VIEW);
    slot->browser->GetHost()->SendExternalBeginFrame();
  }
}
void DoSetAudioMuted(const std::shared_ptr<Slot>& slot, bool muted) {
  if (slot->browser) slot->browser->GetHost()->SetAudioMuted(muted);
}
// Write a camera+mic content setting for `origin` on this browser's context.
// This is what makes a decision STICK the way a browser's does — and what
// un-poisons an origin Chromium has already stored a BLOCK for (with a stored
// BLOCK it short-circuits getUserMedia and never consults the permission
// handler, so a site the user once denied would otherwise be permanently dead
// with no way back). UI-thread only.
void SetMediaContentSetting(const std::shared_ptr<Slot>& slot,
                            const std::string& origin,
                            cef_content_setting_values_t value) {
  CEF_REQUIRE_UI_THREAD();
  if (!slot->browser) return;
  // Content settings are origin-keyed; only http(s) carries one worth writing
  // (about:blank et al have no meaningful origin to remember).
  if (origin.rfind("https://", 0) != 0 && origin.rfind("http://", 0) != 0) return;
  CefRefPtr<CefRequestContext> ctx =
      slot->browser->GetHost()->GetRequestContext();
  if (!ctx) return;
  ctx->SetContentSetting(origin, CefString(),
                         CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA, value);
  ctx->SetContentSetting(origin, CefString(),
                         CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC, value);
}

// Answer a pending prompt (kOpMediaRequest -> the host showed UI -> the user
// chose). Grants all-or-nothing because Continue must MATCH the getUserMedia
// request.
//
// `remember` MUST be set only when a human actually chose. The host also denies
// defensively — no permission UI wired up, the prompt handler threw, the tile
// was torn down or its page replaced mid-prompt — and persisting those as a
// site-wide BLOCK would permanently, silently kill camera/mic for the site with
// no request left to re-prompt on. Deny transiently instead: the page simply
// asks again next time.
// Answer a Flutter-drawn context menu. commandId 0 means dismissed: CEF requires
// the callback be answered exactly once either way, so a dismissal must Cancel
// rather than simply drop the entry — otherwise the page's menu logic hangs and
// the next right-click is ignored.
void DoContextMenuCommand(const std::shared_ptr<Slot>& slot, uint32_t id,
                          uint32_t command) {
  CEF_REQUIRE_UI_THREAD();
  CefRefPtr<CefRunContextMenuCallback> cb;
  {
    std::lock_guard<std::mutex> lock(slot->surface_mutex);
    auto it = slot->context_menus.find(id);
    if (it == slot->context_menus.end()) return;  // already answered/dismissed
    cb = it->second;
    slot->context_menus.erase(it);
  }
  if (!cb) return;
  if (command == 0) {
    cb->Cancel();
  } else {
    cb->Continue(static_cast<int>(command), EVENTFLAG_NONE);
  }
}

void DoMediaResponse(const std::shared_ptr<Slot>& slot, uint32_t id, bool allow,
                     bool remember) {
  CEF_REQUIRE_UI_THREAD();
  auto it = slot->media_requests.find(id);
  if (it == slot->media_requests.end()) return;  // already answered/abandoned
  const uint32_t wanted = it->second.wanted;
  const std::string origin = it->second.origin;
  CefRefPtr<CefMediaAccessCallback> cb = it->second.callback;
  slot->media_requests.erase(it);
  // Remember BEFORE continuing: the page may re-ask the instant it is answered,
  // and the stored setting is what keeps that from re-prompting.
  //
  // Only an ALLOW is ever written here. A stored BLOCK is visible to the page
  // via navigator.permissions.query(), and sites check it before asking — so
  // writing one makes their own "use camera" button do nothing and leaves no
  // request to prompt on. A refusal is remembered on the Campus side instead.
  if (remember) {
    SetMediaContentSetting(slot, origin,
                           allow ? CEF_CONTENT_SETTING_VALUE_ALLOW
                                 : CEF_CONTENT_SETTING_VALUE_DEFAULT);
  }
  if (cb) cb->Continue(allow ? wanted : CEF_MEDIA_PERMISSION_NONE);
  SendMediaState(slot);  // refresh the indicator for the new decision
}

// The URL-bar "site settings" path: rewrite THIS page's camera+mic decision
// (0 = ask again / forget, 1 = allow, 2 = block).
//
// Deliberately does NOT reload. A browser never yanks the page out from under
// you to change a site permission — the new decision simply applies the next
// time the page asks. Reloading here also had a surprising side effect: the page
// re-runs its startup getUserMedia, so the permission prompt appeared by itself
// right after the reload instead of when the user pressed the site's own
// "use camera" button. An already-running stream keeps running (it belongs to
// the page), which is also what a browser does.
void DoSetMediaSetting(const std::shared_ptr<Slot>& slot, uint8_t value) {
  CEF_REQUIRE_UI_THREAD();
  if (!slot->browser) return;
  CefRefPtr<CefFrame> frame = slot->browser->GetMainFrame();
  const std::string url = frame ? frame->GetURL().ToString() : std::string();
  // 1 = allow; anything else clears the stored decision. "Block" deliberately
  // does NOT write CEF_CONTENT_SETTING_VALUE_BLOCK — see DoMediaResponse: a
  // stored block is readable by the page and stops it from ever asking.
  const cef_content_setting_values_t setting =
      value == 1 ? CEF_CONTENT_SETTING_VALUE_ALLOW
                 : CEF_CONTENT_SETTING_VALUE_DEFAULT;
  SetMediaContentSetting(slot, url, setting);
  SendMediaState(slot);  // the indicator reflects the new decision immediately
}

void DoSetPumpInterval(const std::shared_ptr<Slot>& slot, int ms) {
  // Clamp: <8ms buys nothing over 60fps begin-frames + risks pump starvation;
  // >250ms visible would read as a frozen tile.
  slot->pump_interval_ms = ms < 8 ? 8 : (ms > 250 ? 250 : ms);
}
void DoFind(const std::shared_ptr<Slot>& slot, const std::string& text,
            bool forward, bool match_case, bool find_next) {
  if (slot->browser)
    slot->browser->GetHost()->Find(text, forward, match_case, find_next);
}
void DoStopFind(const std::shared_ptr<Slot>& slot, bool clear_selection) {
  if (slot->browser) slot->browser->GetHost()->StopFinding(clear_selection);
}
void DoJsDialogResp(const std::shared_ptr<Slot>& slot, uint32_t id, bool ok,
                    const std::string& text) {
  auto it = slot->dialogs.find(id);
  if (it == slot->dialogs.end()) return;
  it->second->Continue(ok, text);
  slot->dialogs.erase(it);
}
void DoEvalReturning(const std::shared_ptr<Slot>& slot, uint32_t id,
                     const std::string& code) {
  if (!slot->browser) return;
  CefRefPtr<CefFrame> frame = slot->browser->GetMainFrame();
  if (!frame) return;
  // Evaluate the user expression and post its JSON result back via window.cefQuery
  // (OnQuery -> kOpEvalResult). `code` is the trusted host's JS (same trust level
  // as executeJavaScript) and must be a single expression. We splice it rather
  // than eval() it so it still works under a strict page CSP (eval would be
  // blocked); the Dart side fails any pending result on navigation so a malformed
  // expression that wedges this callback can't leak a completer forever.
  std::string js =
      "window.cefQuery({request:'eval:" + std::to_string(id) +
      ":'+(function(){try{return JSON.stringify({ok:true,v:(" + code +
      "\n)});}catch(e){return JSON.stringify({ok:false,v:String(e)});}})(),"
      "persistent:false,onSuccess:function(){},onFailure:function(){}});";
  frame->ExecuteJavaScript(js, "", 0);
}
void DoAddChannel(const std::shared_ptr<Slot>& slot, const std::string& name) {
  if (!IsValidChannelName(name)) {
    if (slot)
      SendLog(slot->browser_id, "addJavaScriptChannel: rejected invalid name '" +
                                    name + "' (must be a JS identifier)");
    return;
  }
  // Register process-globally: OnLoadStart injects every g_channels entry into
  // each freshly-loaded frame, so the shim lands on the next load. This also
  // keeps the op null-safe — if `slot` is somehow absent the registration still
  // takes (defense; the Swift session now buffers addChannel until attach(), so
  // in practice the op carries a valid browserId and `slot` is set).
  g_channels.insert(name);
  // Inject into the registering session's CURRENT frame too, covering the case
  // where the channel is registered after its page has already loaded.
  if (slot && slot->browser) InjectChannelShim(slot->browser->GetMainFrame(), name);
}
// Cookie ops act on the GLOBAL cookie manager (= the shared profile jar), so a
// login in one browser is visible to every browser sharing this profile. They
// take `slot` only to stamp the reply browserId / route a log. Note clear/delete
// affect the WHOLE shared jar by design (the contract's kOpClearCookies semantics).
// Map the wire sameSite token to Chromium's enum (and back for getCookies).
cef_cookie_same_site_t ParseSameSite(const std::string& s) {
  if (s == "none") return CEF_COOKIE_SAME_SITE_NO_RESTRICTION;
  if (s == "lax") return CEF_COOKIE_SAME_SITE_LAX_MODE;
  if (s == "strict") return CEF_COOKIE_SAME_SITE_STRICT_MODE;
  return CEF_COOKIE_SAME_SITE_UNSPECIFIED;
}
const char* SameSiteToString(cef_cookie_same_site_t v) {
  switch (v) {
    case CEF_COOKIE_SAME_SITE_NO_RESTRICTION: return "none";
    case CEF_COOKIE_SAME_SITE_LAX_MODE: return "lax";
    case CEF_COOKIE_SAME_SITE_STRICT_MODE: return "strict";
    default: return "unspecified";
  }
}

void DoSetCookie(const std::shared_ptr<Slot>& slot, const std::string& url,
                 const std::string& name, const std::string& value,
                 const std::string& domain, const std::string& path,
                 bool secure, bool http_only, const std::string& same_site) {
  CefRefPtr<CefCookieManager> mgr = CefCookieManager::GetGlobalManager(nullptr);
  if (!mgr) return;
  CefCookie cookie;
  CefString(&cookie.name).FromString(name);
  CefString(&cookie.value).FromString(value);
  if (!domain.empty()) CefString(&cookie.domain).FromString(domain);
  CefString(&cookie.path).FromString(path.empty() ? "/" : path);
  cookie.has_expires = false;
  // SameSite=None without Secure is rejected by Chromium (the cookie is
  // dropped at SetCookie time), so force Secure on for that combination.
  cookie.secure = (secure || same_site == "none") ? 1 : 0;
  cookie.httponly = http_only ? 1 : 0;
  cookie.same_site = ParseSameSite(same_site);
  if (!mgr->SetCookie(url, cookie, nullptr)) {
    SendLog(slot->browser_id,
            "setCookie rejected for " + url + " (name '" + name + "')");
  }
}
void DoClearCookies(const std::shared_ptr<Slot>& slot) {
  (void)slot;  // shared jar; slot unused beyond routing the op here
  CefRefPtr<CefCookieManager> mgr = CefCookieManager::GetGlobalManager(nullptr);
  if (mgr) mgr->DeleteCookies(CefString(), CefString(), nullptr);
}

// JSON-escape a UTF-8 string for embedding in the cookie array.
std::string JsonEscape(const std::string& s) {
  std::string out;
  out.reserve(s.size() + 2);
  for (unsigned char ch : s) {
    switch (ch) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (ch < 0x20) {
          char buf[8];
          snprintf(buf, sizeof(buf), "\\u%04x", ch);
          out += buf;
        } else {
          out += static_cast<char>(ch);
        }
    }
  }
  return out;
}

std::string CookieToJson(const CefCookie& c) {
  std::string out = "{";
  out += "\"name\":\"" + JsonEscape(CefString(&c.name).ToString()) + "\",";
  out += "\"value\":\"" + JsonEscape(CefString(&c.value).ToString()) + "\",";
  out += "\"domain\":\"" + JsonEscape(CefString(&c.domain).ToString()) + "\",";
  out += "\"path\":\"" + JsonEscape(CefString(&c.path).ToString()) + "\",";
  out += "\"secure\":" + std::string(c.secure ? "true" : "false") + ",";
  out += "\"httpOnly\":" + std::string(c.httponly ? "true" : "false") + ",";
  out += "\"sameSite\":\"" + std::string(SameSiteToString(c.same_site)) + "\"";
  return out + "}";
}

// Accumulates a Visit pass and flushes the JSON array on destruction, so the
// 0-cookie case (Visit never called) still replies (godot-cef does the same).
class HostCookieVisitor : public CefCookieVisitor {
 public:
  HostCookieVisitor(uint32_t browser_id, uint32_t id)
      : browser_id_(browser_id), id_(id) {}
  bool Visit(const CefCookie& cookie, int, int, bool&) override {
    if (!json_.empty()) json_ += ",";
    json_ += CookieToJson(cookie);
    return true;
  }
  ~HostCookieVisitor() override {
    // Stamp the reply with the browser that asked, so the host routes the
    // kOpCookies result back to the right CefWebSession.
    SendCodePlusUtf8(browser_id_, kOpCookies, id_, "[" + json_ + "]");
  }

 private:
  uint32_t browser_id_;
  uint32_t id_;
  std::string json_;
  IMPLEMENT_REFCOUNTING(HostCookieVisitor);
};

void DoVisitCookies(const std::shared_ptr<Slot>& slot, uint32_t id,
                    const std::string& url) {
  CefRefPtr<CefCookieManager> mgr = CefCookieManager::GetGlobalManager(nullptr);
  // The visitor replies on destruction; a null manager just yields [].
  CefRefPtr<HostCookieVisitor> visitor =
      new HostCookieVisitor(slot->browser_id, id);
  if (!mgr) return;
  if (url.empty()) {
    mgr->VisitAllCookies(visitor);
  } else {
    mgr->VisitUrlCookies(url, true, visitor);
  }
}

void DoDeleteCookie(const std::shared_ptr<Slot>& slot, const std::string& url,
                    const std::string& name) {
  (void)slot;  // shared jar; slot unused beyond routing the op here
  CefRefPtr<CefCookieManager> mgr = CefCookieManager::GetGlobalManager(nullptr);
  if (mgr) mgr->DeleteCookies(url, name, nullptr);
}

void DoShowDevTools(const std::shared_ptr<Slot>& slot, int inspect_x,
                    int inspect_y) {
  if (!slot->browser) return;
  // Windowed DevTools (default CefWindowInfo is windowed) — the OSR host can
  // still host a real window. null client lets CEF manage it.
  //
  // A non-negative point opens DevTools already inspecting the element there,
  // which is what "Inspect" from a right-click means. DevTools is a real window
  // (unlike the page itself), so nothing here depends on OSR having one.
  CefWindowInfo window_info;
  CefBrowserSettings settings;
  const CefPoint at = (inspect_x >= 0 && inspect_y >= 0)
                          ? CefPoint(inspect_x, inspect_y)
                          : CefPoint();
  slot->browser->GetHost()->ShowDevTools(window_info, nullptr, settings, at);
}

// CEF-2b: resolve a browser's CDP targetId so the Swift relay can scope an agent's
// CDP session to exactly this tile. Extract the first quoted string value for `key`
// from a flat CDP result JSON (targetIds are GUIDs with no embedded quotes/escapes).
std::string ExtractJsonStringField(const std::string& json,
                                   const std::string& key) {
  std::string needle = "\"" + key + "\"";
  size_t k = json.find(needle);
  if (k == std::string::npos) return "";
  size_t colon = json.find(':', k + needle.size());
  if (colon == std::string::npos) return "";
  size_t q1 = json.find('"', colon + 1);
  if (q1 == std::string::npos) return "";
  size_t q2 = json.find('"', q1 + 1);
  if (q2 == std::string::npos) return "";
  return json.substr(q1 + 1, q2 - q1 - 1);
}

constexpr int kTargetInfoMsgId = 0x7e57;  // fixed id for our Target.getTargetInfo probe

// Receives the Target.getTargetInfo result for one browser and reports its targetId
// back to the plugin (kOpTargetId). UI-thread callbacks. One per browser.
class TargetIdObserver : public CefDevToolsMessageObserver {
 public:
  explicit TargetIdObserver(uint32_t wire_id) : wire_id_(wire_id) {}
  void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser, int message_id,
                              bool success, const void* result,
                              size_t result_size) override {
    // Match this browser's CURRENT probe id (ids now increment per resolve, so a
    // fixed constant would miss every probe after the first). UI-thread, like the
    // resolve that set it.
    auto slot = LookupWireId(wire_id_);
    if (!slot || message_id != slot->target_info_msg || !success || !result ||
        result_size == 0)
      return;
    std::string json(static_cast<const char*>(result), result_size);
    // Anchor to the targetInfo object first, so a differently-named *targetId* field
    // (e.g. openerId/browserContextId) earlier in the JSON can't be mistaken for it.
    size_t ti = json.find("\"targetInfo\"");
    std::string scope = (ti != std::string::npos) ? json.substr(ti) : json;
    std::string tid = ExtractJsonStringField(scope, "targetId");
    if (!tid.empty()) SendUtf8(wire_id_, kOpTargetId, tid);
  }

 private:
  uint32_t wire_id_;
  IMPLEMENT_REFCOUNTING(TargetIdObserver);
};

void DoResolveTargetId(const std::shared_ptr<Slot>& slot) {
  if (!slot->browser) return;
  CefRefPtr<CefBrowserHost> host = slot->browser->GetHost();
  if (!host) return;
  if (!slot->devtools_reg) {
    slot->devtools_reg =
        host->AddDevToolsMessageObserver(new TargetIdObserver(slot->browser_id));
  }
  // Fresh, increasing id per probe (see Slot::target_info_msg) so a re-resolve on the
  // SAME browser isn't dropped by the DevTools session's monotonic-id requirement.
  slot->target_info_msg = slot->target_info_msg < kTargetInfoMsgId
                              ? kTargetInfoMsgId
                              : slot->target_info_msg + 1;
  // Target.getTargetInfo with no params: executed on a specific browser's DevTools
  // agent (a page target), it returns THAT page's own targetInfo — so this resolves
  // exactly this browser's targetId, with no cross-tile ambiguity.
  host->ExecuteDevToolsMethod(slot->target_info_msg, "Target.getTargetInfo", nullptr);
}

void DoImeSetComposition(const std::shared_ptr<Slot>& slot,
                         const std::string& text) {
  if (!slot->browser) return;
  CefString t(text);
  uint32_t len = static_cast<uint32_t>(t.length());
  // Mark the whole composition with a single underline so the in-progress text
  // is visibly distinguished (transparent color -> Blink picks an adaptive
  // default that reads on both light and dark pages). The caret sits at the end.
  std::vector<CefCompositionUnderline> underlines;
  if (len > 0) {
    CefCompositionUnderline u;
    u.range = CefRange(0, len);
    u.color = 0;             // transparent: let Blink choose a contrasting color
    u.background_color = 0;  // transparent background
    u.thick = 0;             // thin underline
    u.style = CEF_CUS_SOLID;
    underlines.push_back(u);
  }
  slot->browser->GetHost()->ImeSetComposition(t, underlines,
                                              CefRange::InvalidRange(),
                                              CefRange(len, len));
}
void DoImeCommitText(const std::shared_ptr<Slot>& slot,
                     const std::string& text) {
  if (slot->browser)
    slot->browser->GetHost()->ImeCommitText(text, CefRange::InvalidRange(), 0);
}
void DoImeCancel(const std::shared_ptr<Slot>& slot) {
  if (slot->browser) slot->browser->GetHost()->ImeCancelComposition();
}

// type: 0=move 1=down 2=up 3=wheel; button: 0=left 1=middle 2=right.
void DoPointer(const std::shared_ptr<Slot>& slot, int type, int button,
               int click_count, uint32_t modifiers, double x, double y,
               double dx, double dy) {
  if (!slot->browser) return;
  CefMouseEvent ev;
  ev.x = static_cast<int>(x);
  ev.y = static_cast<int>(y);
  ev.modifiers = modifiers;
  CefRefPtr<CefBrowserHost> host = slot->browser->GetHost();
  switch (type) {
    case 0:
      host->SendMouseMoveEvent(ev, false);
      break;
    case 1:
      // Give the browser keyboard focus on press so text fields take input and
      // show a caret (CEF won't route key events to an unfocused OSR browser).
      host->SetFocus(true);
      host->SendMouseClickEvent(
          ev, static_cast<cef_mouse_button_type_t>(button), false, click_count);
      break;
    case 2:
      host->SendMouseClickEvent(
          ev, static_cast<cef_mouse_button_type_t>(button), true, click_count);
      break;
    case 4:
      // Cursor left the view: a move with mouseLeave=true clears hover state.
      host->SendMouseMoveEvent(ev, true);
      break;
    case 3:
      host->SendMouseWheelEvent(ev, static_cast<int>(dx), static_cast<int>(dy));
      break;
    default:
      break;
  }
}

// type: 0=rawkeydown 2=keyup 3=char (cef_key_event_type_t).
void DoKey(const std::shared_ptr<Slot>& slot, int type, uint32_t modifiers,
           int32_t windows_key_code, int32_t native_key_code,
           uint32_t character) {
  if (!slot->browser) return;
  CefKeyEvent ev;
  ev.type = static_cast<cef_key_event_type_t>(type);
  ev.modifiers = modifiers;
  ev.windows_key_code = windows_key_code;
  ev.native_key_code = native_key_code;
  // ALWAYS set the character fields, not just for CHAR. On macOS OSR, an editing
  // or navigation key (Backspace, arrows, …) with a zero character is applied
  // TWICE inside Blink — populating it with the real NSEvent codepoint
  // de-duplicates it (CEF forum t=11650). 0 for printable keys is fine: their
  // text rides the IME ImeCommitText path, and a raw keydown inserts nothing.
  ev.character = static_cast<char16_t>(character);
  ev.unmodified_character = static_cast<char16_t>(character);
  slot->browser->GetHost()->SendKeyEvent(ev);
}

// C1: force a repaint. The host's first-present watchdog sends kOpInvalidate when a
// browser hasn't delivered its first frame within the deadline — re-requesting the
// frame self-heals a dropped/raced first paint instead of a permanently blank texture.
void DoInvalidate(const std::shared_ptr<Slot>& slot) {
  CEF_REQUIRE_UI_THREAD();
  if (slot && slot->browser && slot->browser->GetHost()) {
    slot->browser->GetHost()->Invalidate(PET_VIEW);
    // With external begin-frame the internal timer is off, so Invalidate alone may never paint —
    // drive a guaranteed frame so a watchdog re-kick actually delivers.
    slot->browser->GetHost()->SendExternalBeginFrame();
  }
}

// Tear down the WHOLE process: close every browser, then quit the message loop.
// Each browser's per-slot cleanup (maps, surface, retain-cycle break) runs in
// OnBeforeClose as CEF processes the CloseBrowser(true). Sent when the host
// disposes the last browser, on socket loss, or on parent death.
void DoShutdown() {
  std::vector<std::shared_ptr<Slot>> slots;
  {
    std::lock_guard<std::mutex> lock(g_slots_mutex);
    slots.reserve(g_slots_by_wire_id.size());
    for (auto& kv : g_slots_by_wire_id) slots.push_back(kv.second);
  }
  for (auto& slot : slots) {
    if (slot->browser) slot->browser->GetHost()->CloseBrowser(true);
  }
  CefQuitMessageLoop();
}

// Reader thread: decode frames, marshal onto the CEF UI thread.
void IpcReadLoop() {
  for (;;) {
    uint8_t hdr[4];
    if (!ReadAll(g_ipc_fd, hdr, 4)) break;
    uint32_t body_len = ReadU32BE(hdr);
    // Minimum valid body is 5 bytes (4 browserId + 1 op + 0 payload).
    // H9: a malformed/oversized length is a wire desync and tears down EVERY browser in
    // this process — log it first so it isn't a silent, breadcrumb-less all-tiles exit
    // (the IPC peer is trusted, so this only fires on a genuine framing bug).
    if (body_len < 5 || body_len > (64u << 20)) {
      fprintf(stderr, "[cef_host] rejecting malformed IPC frame, body_len=%u — exiting\n",
              body_len);
      break;
    }
    std::vector<uint8_t> body(body_len);
    if (!ReadAll(g_ipc_fd, body.data(), body_len)) break;
    uint32_t wire_id = ReadU32BE(body.data());
    uint8_t opcode = body[4];
    const uint8_t* p = body.data() + 5;
    uint32_t plen = body_len - 5;
    // Resolve the target browser once. null for wire id 0 (process-level) or an
    // unknown/disposed id. Per-browser ops bind this shared_ptr into their UI
    // task, so the slot stays alive even if a dispose lands while the task is
    // queued (closes the dispose/in-flight race). Control ops handle slot==null.
    std::shared_ptr<Slot> slot = LookupWireId(wire_id);
    switch (opcode) {
      case kOpCreateBrowser: {
        // Producer-allocates: no sid on the wire. {u32 w}{u32 h}{f64 dpr}{utf8 url}.
        if (plen < 16) break;
        int w = static_cast<int>(ReadU32BE(p));
        int h = static_cast<int>(ReadU32BE(p + 4));
        double dpr = ReadF64BE(p + 8);
        if (dpr <= 0.0 || dpr > 8.0) dpr = 1.0;  // guard a bad/forged dpr
        std::string url(reinterpret_cast<const char*>(p + 16), plen - 16);
        if (url.empty()) url = "about:blank";
        CefPostTask(TID_UI,
                    base::BindOnce(&DoCreateBrowser, wire_id, w, h, dpr, url));
        break;
      }
      case kOpDisposeBrowser:
        if (slot)
          CefPostTask(TID_UI, base::BindOnce(&DoDisposeBrowser, wire_id));
        break;
      case kOpShutdown:
        CefPostTask(TID_UI, base::BindOnce(&DoShutdown));
        return;
      case kOpResize: {
        // Producer-allocates: no sid. {u32 w}{u32 h}{f64 dpr}. dpr 0/absent = unchanged.
        if (!slot) break;
        if (plen < 8) break;
        int w = static_cast<int>(ReadU32BE(p));
        int h = static_cast<int>(ReadU32BE(p + 4));
        double dpr = (plen >= 16) ? ReadF64BE(p + 8) : 0.0;
        if (dpr < 0.0 || dpr > 8.0) dpr = 0.0;  // guard a bad/forged dpr
        CefPostTask(TID_UI, base::BindOnce(&DoResize, slot, w, h, dpr));
        break;
      }
      case kOpNavigate: {
        // Resolve by wire id on TID_UI (see DoNavigateByWireId): do NOT require the slot
        // here, or a nav landing behind a still-queued create on a shared host is dropped.
        std::string url(reinterpret_cast<const char*>(p), plen);
        CefPostTask(TID_UI,
                    base::BindOnce(&DoNavigateByWireId, wire_id, url, false));
        break;
      }
      case kOpLoadTrusted: {
        // Same: a loadHtmlString right behind a queued create (a 6-tile agent_ui burst)
        // must not be dropped — that was the blank-tile bug. Resolved on TID_UI, FIFO-after
        // the create, and tolerant of a not-yet-bound browser via pending_nav_url.
        std::string url(reinterpret_cast<const char*>(p), plen);
        CefPostTask(TID_UI,
                    base::BindOnce(&DoNavigateByWireId, wire_id, url, true));
        break;
      }
      case kOpOpenAuthWindow: {
        // Open a windowed Chrome-runtime browser at |url| for a WebAuthn / Touch
        // ID ceremony. The OSR/Alloy tile CANNOT host WebAuthn (no window for the
        // Touch ID sheet); the Chrome runtime can. nullptr request context = this
        // process's global cookie jar == the tile's named profile (profiles are
        // per-cef_host-process via root_cache_path), so a sign-in propagates back
        // to the tile. Process-level: no slot required.
        std::string url(reinterpret_cast<const char*>(p), plen);
        CefPostTask(TID_UI, base::BindOnce(&OpenChromeAuthWindow, url));
        break;
      }
      case kOpReload:
        if (!slot) break;
        CefPostTask(TID_UI, base::BindOnce(&DoReload, slot));
        break;
      case kOpStop:
        if (!slot) break;
        CefPostTask(TID_UI, base::BindOnce(&DoStopLoad, slot));
        break;
      case kOpBack:
        if (!slot) break;
        CefPostTask(TID_UI, base::BindOnce(&DoGoBack, slot));
        break;
      case kOpForward:
        if (!slot) break;
        CefPostTask(TID_UI, base::BindOnce(&DoGoForward, slot));
        break;
      case kOpExecuteJs: {
        if (!slot) break;
        std::string code(reinterpret_cast<const char*>(p), plen);
        CefPostTask(TID_UI, base::BindOnce(&DoExecuteJs, slot, code));
        break;
      }
      case kOpSetZoom: {
        if (!slot) break;
        if (plen < 8) break;
        CefPostTask(TID_UI, base::BindOnce(&DoSetZoom, slot, ReadF64BE(p)));
        break;
      }
      case kOpEditCommand: {
        if (!slot) break;
        if (plen < 1) break;
        CefPostTask(TID_UI, base::BindOnce(&DoEditCommand, slot, int{p[0]}));
        break;
      }
      case kOpSetVisible: {
        if (!slot) break;
        bool vis = plen >= 1 ? p[0] != 0 : true;
        CefPostTask(TID_UI, base::BindOnce(&DoSetVisible, slot, vis));
        break;
      }
      case kOpMediaResponse: {
        // {u32 id}{u8 allow}{u8 remember} — an answer to a camera/mic prompt.
        if (!slot) break;
        if (plen < 5) break;
        uint32_t id = ReadU32BE(p);
        bool allow = p[4] != 0;
        // Absent byte = don't remember: only an explicit human choice persists.
        bool remember = plen >= 6 && p[5] != 0;
        CefPostTask(TID_UI,
                    base::BindOnce(&DoMediaResponse, slot, id, allow, remember));
        break;
      }
      case kOpContextMenuCommand: {
        // {u32 id}{u32 commandId} — the user picked an item in the Flutter-drawn
        // context menu (commandId 0 = dismissed without choosing). Chromium runs
        // the command, so behaviour matches Chrome exactly.
        if (!slot) break;
        if (plen < 8) break;
        uint32_t id = ReadU32BE(p);
        uint32_t command = ReadU32BE(p + 4);
        CefPostTask(TID_UI,
                    base::BindOnce(&DoContextMenuCommand, slot, id, command));
        break;
      }
      case kOpSetMediaSetting: {
        // {u8 value} — change this site's remembered camera/mic decision.
        if (!slot) break;
        if (plen < 1) break;
        CefPostTask(TID_UI, base::BindOnce(&DoSetMediaSetting, slot, p[0]));
        break;
      }
      case kOpSetAudioMuted: {
        if (!slot) break;
        bool muted = plen >= 1 ? p[0] != 0 : true;
        CefPostTask(TID_UI, base::BindOnce(&DoSetAudioMuted, slot, muted));
        break;
      }
      case kOpSetPumpInterval: {
        if (!slot) break;
        if (plen < 2) break;
        int ms = (int{p[0]} << 8) | int{p[1]};
        CefPostTask(TID_UI, base::BindOnce(&DoSetPumpInterval, slot, ms));
        break;
      }
      case kOpFind: {
        if (!slot) break;
        if (plen < 3) break;
        bool fwd = p[0] != 0, mc = p[1] != 0, fn = p[2] != 0;
        std::string text(reinterpret_cast<const char*>(p + 3), plen - 3);
        CefPostTask(TID_UI, base::BindOnce(&DoFind, slot, text, fwd, mc, fn));
        break;
      }
      case kOpStopFind: {
        if (!slot) break;
        bool clear = plen >= 1 ? p[0] != 0 : true;
        CefPostTask(TID_UI, base::BindOnce(&DoStopFind, slot, clear));
        break;
      }
      case kOpJsDialogResp: {
        if (!slot) break;
        if (plen < 5) break;
        uint32_t id = ReadU32BE(p);
        bool ok = p[4] != 0;
        std::string text(reinterpret_cast<const char*>(p + 5), plen - 5);
        CefPostTask(TID_UI, base::BindOnce(&DoJsDialogResp, slot, id, ok, text));
        break;
      }
      case kOpEvalReturning: {
        if (!slot) break;
        if (plen < 4) break;
        uint32_t id = ReadU32BE(p);
        std::string code(reinterpret_cast<const char*>(p + 4), plen - 4);
        CefPostTask(TID_UI, base::BindOnce(&DoEvalReturning, slot, id, code));
        break;
      }
      case kOpAddChannel: {
        // Do NOT require `slot`: on a shared host a session's createBrowser may
        // still be queued (pendingCreates) when this op arrives, and dropping it
        // here is exactly why a peer/secondary session's window.<name> shim was
        // never injected (campus.emit silently dead). DoAddChannel registers the
        // name in the process-global g_channels — OnLoadStart injects it into the
        // frame once the browser loads — and injects into the current frame only
        // if the browser already exists.
        std::string name(reinterpret_cast<const char*>(p), plen);
        CefPostTask(TID_UI, base::BindOnce(&DoAddChannel, slot, name));
        break;
      }
      case kOpSetCookie: {
        if (!slot) break;
        std::string s(reinterpret_cast<const char*>(p), plen);
        std::vector<std::string> f;
        size_t start = 0;
        for (size_t i = 0; i <= s.size(); ++i) {
          if (i == s.size() || s[i] == '\0') {
            f.push_back(s.substr(start, i - start));
            start = i + 1;
          }
        }
        while (f.size() < 8) f.push_back("");
        CefPostTask(TID_UI,
                    base::BindOnce(&DoSetCookie, slot, f[0], f[1], f[2], f[3],
                                   f[4], f[5] == "1", f[6] == "1", f[7]));
        break;
      }
      case kOpClearCookies:
        if (!slot) break;
        CefPostTask(TID_UI, base::BindOnce(&DoClearCookies, slot));
        break;
      case kOpVisitCookies: {
        if (!slot) break;
        if (plen < 4) break;
        uint32_t id = ReadU32BE(p);
        std::string url(reinterpret_cast<const char*>(p + 4), plen - 4);
        CefPostTask(TID_UI, base::BindOnce(&DoVisitCookies, slot, id, url));
        break;
      }
      case kOpDeleteCookie: {
        if (!slot) break;
        std::string s(reinterpret_cast<const char*>(p), plen);
        const size_t nul = s.find('\0');
        std::string url = nul == std::string::npos ? s : s.substr(0, nul);
        std::string name = nul == std::string::npos ? "" : s.substr(nul + 1);
        CefPostTask(TID_UI, base::BindOnce(&DoDeleteCookie, slot, url, name));
        break;
      }
      case kOpImeSetComp: {
        if (!slot) break;
        std::string text(reinterpret_cast<const char*>(p), plen);
        CefPostTask(TID_UI, base::BindOnce(&DoImeSetComposition, slot, text));
        break;
      }
      case kOpImeCommit: {
        if (!slot) break;
        std::string text(reinterpret_cast<const char*>(p), plen);
        CefPostTask(TID_UI, base::BindOnce(&DoImeCommitText, slot, text));
        break;
      }
      case kOpShowDevTools: {
        if (!slot) break;
        // Back-compat: an empty payload still means "just open DevTools".
        int ix = -1, iy = -1;
        if (plen >= 8) {
          ix = static_cast<int>(ReadU32BE(p));
          iy = static_cast<int>(ReadU32BE(p + 4));
        }
        CefPostTask(TID_UI, base::BindOnce(&DoShowDevTools, slot, ix, iy));
        break;
      }
      case kOpResolveTargetId:
        if (!slot) break;
        CefPostTask(TID_UI, base::BindOnce(&DoResolveTargetId, slot));
        break;
      case kOpInvalidate:
        if (!slot) break;
        CefPostTask(TID_UI, base::BindOnce(&DoInvalidate, slot));
        break;
      case kOpImeCancel:
        if (!slot) break;
        CefPostTask(TID_UI, base::BindOnce(&DoImeCancel, slot));
        break;
      case kOpPointer: {
        if (!slot) break;
        if (plen < 40) break;
        int type = p[0], button = p[1], clicks = p[2];
        uint32_t mods = ReadU32BE(p + 4);
        double x = ReadF64BE(p + 8), y = ReadF64BE(p + 16);
        double dx = ReadF64BE(p + 24), dy = ReadF64BE(p + 32);
        CefPostTask(TID_UI, base::BindOnce(&DoPointer, slot, type, button,
                                           clicks, mods, x, y, dx, dy));
        break;
      }
      case kOpKey: {
        if (!slot) break;
        if (plen < 20) break;
        int type = p[0];
        uint32_t mods = ReadU32BE(p + 4);
        int32_t wkc = static_cast<int32_t>(ReadU32BE(p + 8));
        int32_t nkc = static_cast<int32_t>(ReadU32BE(p + 12));
        uint32_t ch = ReadU32BE(p + 16);
        CefPostTask(TID_UI, base::BindOnce(&DoKey, slot, type, mods, wkc, nkc,
                                           ch));
        break;
      }
      default: {
        // An opcode this build doesn't know = protocol skew (a newer plugin driving an
        // older host — the kOpReady version handshake should have refused it, but an
        // in-between version or a bypassed handshake still lands here). Log ONCE per
        // opcode (this reader is a single thread, so plain statics are safe) instead of
        // silently dropping — a silent drop is a frozen tile with no breadcrumb.
        static bool logged_unknown[256] = {false};
        if (!logged_unknown[opcode]) {
          logged_unknown[opcode] = true;
          SendLog(/*browser_id=*/0,
                  "unknown opcode " + std::to_string(opcode) +
                      " (protocol skew? plugin newer than host) — dropping this "
                      "and further frames of this opcode");
        }
        break;
      }
    }
  }
  // Parent died / socket closed: quit.
  CefPostTask(TID_UI, base::BindOnce(&DoShutdown));
}

// Belt-and-suspenders: if the host process dies without closing the socket
// cleanly, kqueue NOTE_EXIT still tears us down so no cef_host orphans.
void WatchParentDeath(pid_t parent) {
  int kq = kqueue();
  if (kq < 0) return;
  struct kevent change;
  EV_SET(&change, parent, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0,
         nullptr);
  if (kevent(kq, &change, 1, nullptr, 0, nullptr) < 0) {
    close(kq);  // parent already gone (ESRCH) — socket EOF will catch it
    return;
  }
  struct kevent out;
  const int n = kevent(kq, nullptr, 0, &out, 1, nullptr);  // blocks until exit
  close(kq);
  if (n > 0) CefPostTask(TID_UI, base::BindOnce(&DoShutdown));
}

// ---- Arg parsing ----
std::string ArgValue(int argc, char** argv, const char* key) {
  std::string prefix = std::string("--") + key + "=";
  for (int i = 1; i < argc; ++i) {
    if (strncmp(argv[i], prefix.c_str(), prefix.size()) == 0) {
      return std::string(argv[i] + prefix.size());
    }
  }
  return std::string();
}

// Presence-only flag (no value), e.g. bare "--cdp-pipe". ArgValue only matches
// "--key=value", so a value-less flag needs this. Accepts both "--key" and
// "--key=..." forms so the caller can pass either.
bool HasFlag(int argc, char** argv, const char* key) {
  const std::string bare = std::string("--") + key;
  const std::string prefix = bare + "=";
  for (int i = 1; i < argc; ++i) {
    if (argv[i] == bare ||
        strncmp(argv[i], prefix.c_str(), prefix.size()) == 0) {
      return true;
    }
  }
  return false;
}

std::string ExecutableDir() {
  char buf[4096];
  uint32_t sz = sizeof(buf);
  if (_NSGetExecutablePath(buf, &sz) != 0) return std::string();
  char real[4096];
  const char* resolved = realpath(buf, real) ? real : buf;
  return std::string(dirname(const_cast<char*>(resolved)));
}

int ConnectUnixSocket(const std::string& path) {
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return -1;
  sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, path.c_str(), sizeof(addr.sun_path) - 1);
  if (connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
    close(fd);
    return -1;
  }
  return fd;
}

}  // namespace

int main(int argc, char* argv[]) {
  // Raise the open-file limit early. A busy shared host runs many OSR browsers, each holding
  // sockets/pipes plus IOSurfaces, against macOS's low default soft limit (256) — and an
  // fd-heavy campus reaches the documented non-fatal WebRTC select() fd>=1024 fault. Lift the
  // soft limit toward the hard limit so fd headroom isn't the reachable ceiling.
  {
    struct rlimit rl;
    if (getrlimit(RLIMIT_NOFILE, &rl) == 0) {
      const rlim_t kCap = 10240;  // macOS caps RLIMIT_NOFILE at OPEN_MAX (10240)
      rlim_t target =
          (rl.rlim_max == RLIM_INFINITY || rl.rlim_max > kCap) ? kCap : rl.rlim_max;
      if (rl.rlim_cur < target) {
        rl.rlim_cur = target;
        setrlimit(RLIMIT_NOFILE, &rl);
      }
    }
  }
#if defined(CEF_HOST_MULTIPROCESS) && defined(CEF_HOST_ADHOC)
  // Disable Chromium 144's Mach-port peer-requirement validation for the whole
  // process tree. The child processes read this policy from an env var (NOT the
  // FeatureList, which isn't up yet when the rendezvous runs), and the browser
  // injects it; pre-setting it here makes children inherit kNoValidation (0).
  // (Note Chromium's misspelling "VALDATION".) On macOS 26 a failed validation
  // TERMINATES children, so without this no paint callback ever fires. This is a
  // dev/CI unblock (ad-hoc only — compiled out of a signed -DCEF_HOST_ADHOC=OFF
  // release); the production fix is correct inside-out Developer-ID signing.
  setenv("MACH_PORT_RENDEZVOUS_PEER_VALDATION", "0", 1);
#endif
  CefScopedLibraryLoader library_loader;
  if (!library_loader.LoadInMain()) {
    fprintf(stderr, "[cef_host] failed to load CEF framework\n");
    return 1;
  }

  // All args are now per-PROCESS / per-profile; the per-view geometry/url moved
  // into the kOpCreateBrowser payload.
  std::string ipc_path = ArgValue(argc, argv, "ipc");
  std::string allowed = ArgValue(argc, argv, "allowed-schemes");
  std::string cdp = ArgValue(argc, argv, "cdp-port");
  // Agent-control / pipe mode opt-in (presence = true, no value). When set, CDP
  // goes over inherited fds 3/4 instead of the TCP --cdp-port; stashed in the
  // file-scope g_cdp_pipe so OnBeforeCommandLineProcessing can inject the
  // Chromium switch (set BEFORE CefInitialize, below). Mutually independent of
  // --cdp-port; the pipe path never touches the TCP `cdp` string above, so the
  // persistent-profile guard below (which strips only the TCP port) doesn't
  // fire for it — a pipe on a named profile is naturally allowed.
  const bool want_pipe = HasFlag(argc, argv, "cdp-pipe");
  std::string profile_dir = ArgValue(argc, argv, "profile-dir");
  // Swift always passes --profile-dir (even for an ephemeral host, whose dir is a
  // throwaway temp dir), so profile_dir alone can't tell "persistent" from
  // "ephemeral". --ephemeral marks the throwaway case so the CDP / mock-keychain
  // guards below fire only for a real (named, persistent) profile.
  const bool is_ephemeral = !ArgValue(argc, argv, "ephemeral").empty();
  for (size_t start = 0; start < allowed.size();) {
    const size_t comma = allowed.find(',', start);
    const size_t len =
        comma == std::string::npos ? std::string::npos : comma - start;
    std::string s = allowed.substr(start, len);
    std::transform(s.begin(), s.end(), s.begin(),
                   [](unsigned char c) { return std::tolower(c); });
    if (!s.empty()) g_allowed_schemes.insert(s);
    if (comma == std::string::npos) break;
    start = comma + 1;
  }

  if (!ipc_path.empty()) {
    g_ipc_fd = ConnectUnixSocket(ipc_path);
    if (g_ipc_fd < 0) {
      fprintf(stderr, "[cef_host] failed to connect IPC socket %s\n",
              ipc_path.c_str());
    }
  }

  // Defense-in-depth (Swift is the real gate): CDP is an unauthenticated
  // localhost port that could read the shared cookie jar, so a *persistent*
  // profile must never expose it. CDP IS allowed on an ephemeral host, so gate
  // on !is_ephemeral — not on profile_dir alone, which is always set. Swift
  // already rejects CDP+named before spawn; this is belt-and-suspenders.
  // NOTE: this gates the TCP --cdp-port (`cdp`) ONLY. The agent-control pipe
  // path (--cdp-pipe / g_cdp_pipe) never sets `cdp`, so this guard does not fire
  // for it — a pipe on a named profile is allowed by construction (no listening
  // socket means the cookie-exfil rationale above doesn't apply).
  if (!cdp.empty() && !profile_dir.empty() && !is_ephemeral) {
    SendLog(0,
            "ignoring --cdp-port: refusing CDP on a persistent --profile-dir");
    cdp.clear();
  }
#ifdef CEF_HOST_ADHOC
  // Ad-hoc / mock-keychain build: secrets at rest aren't really encrypted, so a
  // persistent (named) profile here is insecure. Swift downgrades named profiles
  // to ephemeral on an ad-hoc host (F.5); this is an advisory log only, and only
  // for a real persistent profile (an ephemeral throwaway dir is never at risk).
  if (!profile_dir.empty() && !is_ephemeral &&
      !std::getenv("FLUTTER_CEF_ALLOW_INSECURE_PROFILE")) {
    SendLog(0, "warning: persistent profile under mock keychain (ad-hoc build)");
  }
#endif

  // Cross-process single-writer lock on a PERSISTENT profile dir (C2). Swift's
  // in-memory dedup only covers one plugin instance; two app instances (or two
  // FlutterEngines in one process) would resolve the same root_cache_path and
  // spawn two cef_host on it. Chromium's own profile singleton then fails the
  // SECOND CefInitialize (-> EOF, silent dead profile) with possible cache
  // corruption if the lock races. Take an advisory exclusive flock on
  // <profile_dir>/.flutter_cef.lock FIRST; on contention (or any failure
  // opening/locking it) report a distinct, machine-parseable signal and exit
  // with code 2 so Swift surfaces a real "profile already in use" error instead
  // of the generic crash/EOF path. Only for a real persistent profile — an
  // ephemeral throwaway dir is per-pid, so it can never contend. The fd is held
  // open (never closed) for the process lifetime: the lock releases when the
  // process exits (closing it early, or letting an RAII guard close it, would
  // drop the lock while the profile is still live). Intentionally leaked.
  if (!profile_dir.empty() && !is_ephemeral) {
    const std::string lock_path = profile_dir + "/.flutter_cef.lock";
    int lock_fd = open(lock_path.c_str(), O_CREAT | O_RDWR, 0600);
    if (lock_fd < 0) {
      SendLog(0, "profile-locked");
      fprintf(stderr, "[cef_host] cannot open profile lock %s: %s\n",
              lock_path.c_str(), strerror(errno));
      return 2;
    }
    if (flock(lock_fd, LOCK_EX | LOCK_NB) != 0) {
      SendLog(0, "profile-locked");
      fprintf(stderr,
              "[cef_host] profile already in use by another process (%s): %s\n",
              lock_path.c_str(), strerror(errno));
      close(lock_fd);
      return 2;
    }
    // Held for the process lifetime — never closed (the OS drops the lock on
    // exit). Suppress the unused-variable warning without releasing the lock.
    (void)lock_fd;
  }

  // Stash the agent-control / pipe opt-in for OnBeforeCommandLineProcessing,
  // which runs during CefInitialize below. That hook is the ONLY place the
  // "remote-debugging-pipe" Chromium switch can be injected (the argv-scrub just
  // below hands CEF argv[0] only, so it can't ride in via clean_argv). When
  // false, nothing is injected and behavior is byte-identical to the pre-pipe
  // path. Note: --cdp-pipe is independent of the TCP --cdp-port and is NOT
  // subject to the persistent-profile guard above (which strips only the TCP
  // `cdp` string); a pipe has no listening socket, so a pipe on a named profile
  // is allowed by construction.
  g_cdp_pipe = want_pipe;

  // Hand Chromium ONLY the program name. Our custom switches (--ipc,
  // --cdp-port, --allowed-schemes, --profile-dir, --cdp-pipe) are parsed by us
  // above; if they reach Chromium's CommandLine, cef_initialize CHECK-crashes
  // on them.
  char* clean_argv[] = {argv[0]};
  CefMainArgs main_args(1, clean_argv);
  @autoreleasepool {
    [CefHostApplication sharedApplication];
    CefSettings settings;
#ifdef CEF_HOST_ADHOC
    // Dev / ad-hoc: the Chromium renderer/GPU sandbox is OFF. It only *validates*
    // under proper Developer-ID signing, so an ad-hoc build must run unsandboxed.
    settings.no_sandbox = true;
#else
    // Signed release (-DCEF_HOST_ADHOC=OFF): enable the Chromium renderer/GPU
    // sandbox. The browser process itself is never sandboxed on macOS — only the
    // helper subprocesses, which call CefScopedSandboxContext (process_helper.mm)
    // before loading the framework. Requires correct inside-out Developer-ID
    // signing of the cef_host tree (the libcef_sandbox.dylib + helpers + host).
    settings.no_sandbox = false;
#endif
    settings.windowless_rendering_enabled = true;
    settings.log_severity = LOGSEVERITY_INFO;
    // Chrome DevTools Protocol (CDP): the host picks a free port and passes it
    // via --cdp-port; CEF stands up the DevTools HTTP/WebSocket server on
    // 127.0.0.1:<port> (M113+ forces localhost-only). UNAUTHENTICATED — any local
    // client that reaches the port fully drives the page — so this is opt-in,
    // never set by default. CEF treats 0 as "disabled" (no auto-assign), so the
    // host must choose a real port (1024-65535).
    if (!cdp.empty()) {
      int port = atoi(cdp.c_str());
      if (port >= 1024 && port <= 65535) {
        settings.remote_debugging_port = port;
      }
    }
    // Per-profile cache. The host supplies --profile-dir: a stable 0700 dir
    // under Application Support for a named (persistent, shared-login) profile,
    // or a unique throwaway temp dir for an ephemeral session. One root_cache_path
    // is shared by every browser in this process, which is what makes login
    // shared. The per-pid temp fallback is defensive — Swift always passes
    // --profile-dir, so it normally never fires. persist_session_cookies keeps
    // session cookies across relaunch (harmless for ephemeral; required for
    // "stay signed in").
    std::string cef_cache =
        !profile_dir.empty()
            ? profile_dir
            : std::string([NSTemporaryDirectory() UTF8String]) +
                  "flutter_cef_cache_" +
                  std::to_string([[NSProcessInfo processInfo] processIdentifier]);
    CefString(&settings.root_cache_path) = cef_cache;
    settings.persist_session_cookies = true;
    // A plain (non-.app) executable can't auto-locate the framework Resources
    // (icudtl.dat, *.pak, locale .lproj), so point CEF at them explicitly via a
    // normalized (no "..") framework dir.
    std::string exe_dir = ExecutableDir();
    std::string fw_raw =
        exe_dir + "/../Frameworks/Chromium Embedded Framework.framework";
    char fw_real[4096];
    std::string fw =
        realpath(fw_raw.c_str(), fw_real) ? std::string(fw_real) : fw_raw;
    CefString(&settings.framework_dir_path) = fw;
    CefString(&settings.resources_dir_path) = fw + "/Resources";
    CefString(&settings.locales_dir_path) = fw + "/Resources";
#ifdef CEF_HOST_MULTIPROCESS
    // Multi-process: point CEF at the base helper subprocess + the cef_host
    // bundle. CEF derives the (GPU)/(Renderer)/(Plugin)/(Alerts) variants from
    // the base helper name.
    auto normalize = [](const std::string& p) {
      char buf[4096];
      return realpath(p.c_str(), buf) ? std::string(buf) : p;
    };
    CefString(&settings.browser_subprocess_path) = normalize(
        exe_dir + "/../Frameworks/cef_host Helper.app/Contents/MacOS/cef_host Helper");
    CefString(&settings.main_bundle_path) = normalize(exe_dir + "/../..");
#endif
    CefRefPtr<HostApp> app(new HostApp);
    if (!CefInitialize(main_args, settings, app, nullptr)) {
      fprintf(stderr, "[cef_host] CefInitialize failed\n");
      return 1;
    }
    if (std::getenv("FLUTTER_CEF_DEBUG"))
      fprintf(stderr, "[cef_host] CefInitialize OK (fd=%d)\n", g_ipc_fd.load());
    std::thread reader;
    if (g_ipc_fd >= 0) reader = std::thread(&IpcReadLoop);
    std::thread(&WatchParentDeath, getppid()).detach();
    CefRunMessageLoop();
    if (reader.joinable()) {
      shutdown(g_ipc_fd, SHUT_RDWR);  // unblock the reader's blocking read
      reader.join();
    }
    // Reader is joined (no more reads); close the socket under the write mutex
    // (no concurrent SendFrame) and clear the fd so any late write is a no-op.
    {
      std::lock_guard<std::mutex> lock(g_ipc_write_mutex);
      // C3: store -1 FIRST (atomic exchange), THEN close — so a SendFrame that snapshots
      // the fd under this lock never holds a value that's already closed/recycled. The
      // GPU/compositor threads that call SendFrame aren't joined until CefShutdown below,
      // so this ordering (not close-then-clear) is what makes a late paint write a safe
      // no-op instead of a write into an unrelated recycled fd.
      int fd = g_ipc_fd.exchange(-1);
      if (fd >= 0) close(fd);
    }
    CefShutdown();
  }
  return 0;
}
