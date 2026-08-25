// cef_host (Windows) — a standalone CEF off-screen-rendering subprocess.
//
// The Flutter plugin (packages/flutter_cef_windows/windows/) spawns one
// cef_host per profile and drives N browsers in it over a named-pipe IPC.
// The wire contract is PROTOCOL.md + cef_host_protocol.h in this directory —
// transcribed verbatim from the macOS reference
// packages/flutter_cef_macos/native/cef_host/main.mm, with ONE payload
// difference (LAW 10): kOpPresent carries {u64 bridgeHandle BE}{u32 srcW BE}
// {u32 srcH BE} where bridgeHandle is the DXGI LEGACY shared handle of the
// host-minted D3D11_RESOURCE_MISC_SHARED bridge texture.
//
// Ship shape (LAW 8, SPIKES.md S2): this builds as cef_host.dll exporting
// RunConsoleMain, loaded by CEF's prebuilt bootstrapc.exe shipped RENAMED to
// cef_host.exe beside it. sandbox_info is forwarded to BOTH CefExecuteProcess
// and CefInitialize. The slice runs settings.no_sandbox = 1 (sandbox is P11).
//
// THE LAWS this file keeps (specs/windows-port/SPIKES.md):
//  1. external_begin_frame_enabled = FALSE; windowless_frame_rate = 60.
//     (S4: with the external pump only the FIRST browser in the process ever
//     paints. The macOS PumpBeginFrame pacer is NOT ported; everywhere main.mm
//     calls SendExternalBeginFrame we use Invalidate(PET_VIEW) — with the
//     internal frame timer ON that is sufficient to drive a repaint.)
//  2. OnAcceleratedPaint's NT handle is valid ONLY inside the callback:
//     OpenSharedResource1 + CopyResource to the legacy bridge INSIDE the
//     callback, synchronously. The NT handle is never stored.
//  3. Identity is never keyed on shared_texture_handle VALUES (they alias
//     across sizes and browsers). The bridge texture handle WE mint is the
//     identity Flutter sees.
//  4. Every WasResized discards CEF's pool; late frames at the OLD size still
//     arrive — every kOpPresent carries the TRUTHFUL composited dims
//     (srcW/srcH) so the plugin's size-gate (the macOS SendPresentLocked
//     consumer contract, PROTOCOL.md §5) can refuse stale-size frames.
//  5. Bridge textures are D3D11_RESOURCE_MISC_SHARED (LEGACY handle via
//     IDXGIResource::GetSharedHandle, not NT) — what ANGLE/Flutter accepts.
//  6. (Plugin-side; supported here by keeping the retired bridge alive until
//     the present announcing its replacement has been written to the pipe.)
//
// Args (per-PROCESS / per-profile, mirroring main.mm:32-38):
//   --ipc=<pipe name>          the plugin's already-created named pipe
//   --profile-dir=<abs path>   -> settings.root_cache_path
//   --ephemeral                marks the profile dir throwaway
//   --allowed-schemes=<csv>    optional navigation scheme allowlist
//                              (empty/omitted = allow all; main.mm:2727-2737)

#include <windows.h>

#include <d3d11.h>
#include <d3d11_1.h>
#include <shlobj.h>  // SHGetKnownFolderPath / FOLDERID_Downloads (downloads)
#include <wrl/client.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <vector>

#include "include/base/cef_bind.h"
#include "include/base/cef_callback.h"
#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_command_line.h"
#include "include/cef_cookie.h"
#include "include/cef_download_handler.h"
#include "include/cef_find_handler.h"
#include "include/cef_jsdialog_handler.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_permission_handler.h"
#include "include/cef_render_handler.h"
#include "include/cef_render_process_handler.h"
#include "include/cef_request_handler.h"
#include "include/cef_sandbox_win.h"
#include "include/cef_task.h"
#include "include/cef_v8.h"
#include "include/wrapper/cef_closure_task.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_message_router.h"

#include "cef_host_protocol.h"

// SHGetKnownFolderPath (downloads dir) + CoTaskMemFree live in shell32/ole32.
// These pragmas keep the TU self-linking without touching CMake.
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "ole32.lib")

namespace {

using namespace flutter_cef;  // opcodes + BE codecs (cef_host_protocol.h)
using Microsoft::WRL::ComPtr;

// ---- Shared runtime state ----
// The IPC pipe handle. Atomic for the same reason main.mm:166-172 makes the
// fd atomic: the reader thread, SendFrame (any CEF thread), and teardown all
// touch it.
std::atomic<HANDLE> g_ipc_pipe{INVALID_HANDLE_VALUE};
std::mutex g_ipc_write_mutex;

// One hidden window per host process, passed to SetAsWindowless(parent) so
// dialogs/menus/IMM degrade gracefully (PLAN §4.3; S5 works either way but
// an HWND is the better default).
HWND g_hidden_hwnd = nullptr;

// Host-set navigation scheme allowlist (lowercased; --allowed-schemes=a,b).
// Empty = allow all. `about` is always allowed. Enforced in
// HostClient::OnBeforeBrowse exactly like main.mm:335-342/1528-1565.
std::set<std::string> g_allowed_schemes;

// Agent-control CDP-over-pipe (P9). "<read>,<write>" decimal inherited-HANDLE
// values from the plugin's --cdp-io-pipes= switch (the S3 recipe): the browser
// READS CDP commands from <read> and WRITES responses/events to <write>. Set in
// RunConsoleMain (browser process only) BEFORE CefInitialize; OnBeforeCommand-
// LineProcessing then injects Chromium's --remote-debugging-pipe +
// --remote-debugging-io-pipes. Empty = agent control off (byte-identical to the
// pre-P9 launch). Mirrors macOS main.mm's --cdp-pipe translation.
std::string g_cdp_io_pipes;

// Registered JS channel names (UI-thread-only; mirrors main.mm:352-356). On
// each MAIN-frame load OnLoadStart injects a window.<name>.postMessage shim
// that routes to the browser process over window.cefQuery (the
// CefMessageRouter channel; the renderer half lives in HostApp below).
std::set<std::string> g_channels;

// A channel name is spliced into the injected shim's source, so it MUST be a
// plain JS identifier — else a crafted name could break out of the string
// literal and run arbitrary script on every page load (main.mm:362-375,
// verbatim). DoAddChannel drops invalid names.
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

// Inject the per-channel page-side shim (window.<name>.postMessage ->
// window.cefQuery 'ch:<name>:<msg>'). BYTE-for-byte identical to main.mm:
// 377-384 so a page cannot detect a Windows-vs-macOS divergence.
void InjectChannelShim(CefRefPtr<CefFrame> frame, const std::string& name) {
  if (!frame) return;
  std::string js = "window['" + name +
                   "']={postMessage:function(m){window.cefQuery({request:'ch:" +
                   name + ":'+String(m),persistent:false,"
                   "onSuccess:function(){},onFailure:function(){}});}};";
  frame->ExecuteJavaScript(js, "", 0);
}

// The user's Downloads folder (Windows analogue of macOS's native save panel).
// Empty on failure — OnBeforeDownload then falls back to a Save-As dialog.
std::wstring GetDownloadsDir() {
  PWSTR path = nullptr;
  if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_Downloads, 0, nullptr, &path)) &&
      path) {
    std::wstring dir(path);
    CoTaskMemFree(path);
    return dir;
  }
  if (path) CoTaskMemFree(path);
  // Fallback: %USERPROFILE%\Downloads.
  wchar_t up[MAX_PATH] = {};
  const DWORD n = GetEnvironmentVariableW(L"USERPROFILE", up, MAX_PATH);
  if (n > 0 && n < MAX_PATH) return std::wstring(up) + L"\\Downloads";
  return std::wstring();
}

void LogErr(const char* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vfprintf(stderr, fmt, ap);
  fprintf(stderr, "\n");
  fflush(stderr);
  va_end(ap);
}

// ---- Pipe I/O (framing per PROTOCOL.md §1 / main.mm:416-446) ----
//
// OVERLAPPED, EMPIRICALLY REQUIRED (found via pipe_probe, 2026-07-20): on a
// SYNCHRONOUS pipe handle Windows serializes all I/O on the file object, so
// the reader thread's pending blocking ReadFile makes any WriteFile from a
// CEF thread queue behind it — the UI thread froze inside
// SendFrame(kOpCreated), CefRunMessageLoop stalled, and every child process
// then died with "Terminating current process after 15 seconds with no
// connection" (no renderer/GPU/network — browsers never came up). A Unix
// socket fd is full-duplex so macOS never sees this. The pipe is therefore
// opened with FILE_FLAG_OVERLAPPED and every read/write runs event-based
// overlapped I/O; concurrent read+write on the one handle is then legal.
// (The plugin side of the pipe needs the same treatment — ipc_pipe.cpp.)

bool OverlappedIo(HANDLE pipe, void* buf, size_t len, bool write) {
  uint8_t* p = static_cast<uint8_t*>(buf);
  HANDLE ev = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!ev) return false;
  bool ok = true;
  size_t off = 0;
  while (off < len) {
    OVERLAPPED ov = {};
    ov.hEvent = ev;
    DWORD n = 0;
    BOOL res = write ? WriteFile(pipe, p + off,
                                 static_cast<DWORD>(len - off), nullptr, &ov)
                     : ReadFile(pipe, p + off, static_cast<DWORD>(len - off),
                                nullptr, &ov);
    if (!res && GetLastError() != ERROR_IO_PENDING) {
      ok = false;  // broken pipe / cancelled / error
      break;
    }
    if (!GetOverlappedResult(pipe, &ov, &n, TRUE)) {
      ok = false;
      break;
    }
    if (n == 0) {
      ok = false;  // peer closed
      break;
    }
    off += n;
  }
  CloseHandle(ev);
  return ok;
}

bool ReadAllPipe(HANDLE pipe, void* buf, size_t len) {
  return OverlappedIo(pipe, buf, len, /*write=*/false);
}

bool WriteAllPipe(HANDLE pipe, const void* buf, size_t len) {
  return OverlappedIo(pipe, const_cast<void*>(buf), len, /*write=*/true);
}

// Frame layout: [u32 bodyLen BE][u32 browserId BE][u8 opcode][payload].
// bodyLen = 4 + 1 + payloadLen. Assembled whole + written under the write
// mutex so a partial write never desyncs the peer (mirrors main.mm SendFrame).
// C3 ordering: the handle is snapshotted UNDER the write lock; teardown
// exchanges INVALID_HANDLE_VALUE + closes under this same lock, so a late
// paint-thread send can never write into a recycled handle.
void SendFrame(uint32_t browser_id, uint8_t opcode, const void* payload,
               uint32_t payload_len) {
  if (g_ipc_pipe.load() == INVALID_HANDLE_VALUE) return;  // racy early-out
  std::lock_guard<std::mutex> lock(g_ipc_write_mutex);
  HANDLE pipe = g_ipc_pipe.load();
  if (pipe == INVALID_HANDLE_VALUE) return;
  uint32_t body_len = 4 + 1 + payload_len;
  std::vector<uint8_t> frame(4 + body_len);
  WriteU32BE(frame.data(), body_len);
  WriteU32BE(frame.data() + 4, browser_id);
  frame[8] = opcode;
  if (payload_len) memcpy(frame.data() + 9, payload, payload_len);
  WriteAllPipe(pipe, frame.data(), frame.size());
}

void SendLog(uint32_t browser_id, const std::string& msg) {
  SendFrame(browser_id, kOpLog, msg.data(),
            static_cast<uint32_t>(msg.size()));
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

// op payload: [u32 BE code][utf8 body]. Used for load-error, console, cookies.
void SendCodePlusUtf8(uint32_t browser_id, uint8_t op, uint32_t code,
                      const std::string& body) {
  std::vector<uint8_t> p(4 + body.size());
  WriteU32BE(p.data(), code);
  memcpy(p.data() + 4, body.data(), body.size());
  SendFrame(browser_id, op, p.data(), static_cast<uint32_t>(p.size()));
}

// ---- argv helpers ----

std::string GetSwitch(int argc, char* argv[], const char* prefix) {
  size_t n = strlen(prefix);
  for (int i = 0; i < argc; ++i) {
    if (strncmp(argv[i], prefix, n) == 0) return std::string(argv[i] + n);
  }
  return std::string();
}

bool HasFlag(int argc, char* argv[], const char* flag) {
  for (int i = 0; i < argc; ++i) {
    if (strcmp(argv[i], flag) == 0) return true;
  }
  return false;
}

std::wstring Widen(const std::string& s) {
  if (s.empty()) return std::wstring();
  int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
  std::wstring w(n > 0 ? n - 1 : 0, L'\0');
  if (n > 1)
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, &w[0], n);
  return w;
}

// ---- Process-wide D3D11 device for the bridge-blit present path ----
// One device + immediate context for the whole cef_host process, created
// lazily on the first accelerated paint (mirrors main.mm's g_mtl_device
// singleton, main.mm:320-333). The immediate context is NOT thread-safe;
// OnAcceleratedPaint arrives on the CEF UI thread only, but g_d3d_mutex
// serializes it anyway (belt + suspenders, and future-proof).
ComPtr<ID3D11Device> g_d3d_device;
ComPtr<ID3D11Device1> g_d3d_device1;
ComPtr<ID3D11DeviceContext> g_d3d_ctx;
std::mutex g_d3d_mutex;
// EnsureD3D's "already tried and failed" latch. A file-global (not a function
// static) so device-loss recovery can clear it; touched only on the CEF UI
// thread (the sole OnAcceleratedPaint thread).
bool g_d3d_tried = false;
// Bumped on every device (re)create / loss so a Slot can tell its bridge was
// minted on a now-dead device and re-mint (see EnsureBridgeForPaintLocked).
// Atomic because Slots read it while only the UI thread writes it.
std::atomic<uint64_t> g_d3d_epoch{0};

// Returns false (once, then cached until a device-loss reset) if D3D11 is
// unavailable — the pixel path then degrades to the logged software OnPaint
// fallback.
bool EnsureD3D() {
  if (g_d3d_device1) return true;
  if (g_d3d_tried) return false;
  g_d3d_tried = true;
  UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
  D3D_FEATURE_LEVEL fl;
  HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                                 flags, nullptr, 0, D3D11_SDK_VERSION,
                                 &g_d3d_device, &fl, &g_d3d_ctx);
  if (FAILED(hr)) {
    LogErr("[cef_host] D3D11CreateDevice failed 0x%08lx", hr);
    return false;
  }
  hr = g_d3d_device.As(&g_d3d_device1);
  if (FAILED(hr)) {
    LogErr("[cef_host] ID3D11Device1 unavailable 0x%08lx", hr);
    g_d3d_device.Reset();
    g_d3d_ctx.Reset();
    return false;
  }
  g_d3d_epoch.fetch_add(1);  // a fresh device — all bridges must re-mint on it
  return true;
}

// True if the cached device has been removed/reset (any GetDeviceRemovedReason
// failure). Caller holds g_d3d_mutex.
bool D3DDeviceLostLocked() {
  return g_d3d_device && FAILED(g_d3d_device->GetDeviceRemovedReason());
}

// Drop the cached device/context so the NEXT EnsureD3D re-creates from scratch,
// and bump the epoch so every Slot re-mints its bridge on the new device (their
// old bridge textures died with the removed device). Caller holds g_d3d_mutex.
void ResetD3DDeviceLocked() {
  g_d3d_device1.Reset();
  g_d3d_device.Reset();
  g_d3d_ctx.Reset();
  g_d3d_tried = false;
  g_d3d_epoch.fetch_add(1);
}

// Per-browser state: one cef_host process multiplexes N browsers, one Slot
// per plugin-assigned wire id (mirrors main.mm's Slot, main.mm:182-274, with
// the IOSurface/Metal fields swapped for the D3D11 bridge and the macOS-only
// begin-frame-pump fields dropped per LAW 1).
struct Slot {
  uint32_t browser_id = 0;  // plugin-assigned wire id (>=1); NOT GetIdentifier().
  CefRefPtr<CefBrowser> browser;
  // H3 async-create dispose-loss guard (main.mm:186-191): a dispose arriving
  // while CreateBrowser is in flight records intent here; OnAfterCreated
  // honors it the instant the browser binds. UI-thread-confined.
  bool close_requested = false;

  // Guards bridge / width / height / dpr for THIS browser. Per-slot so paints
  // on independent browsers don't contend (main.mm surface_mutex).
  std::mutex surface_mutex;
  // The host-minted legacy MISC_SHARED bridge texture (LAWs 3/5) — the
  // identity Flutter sees. Re-minted whenever CEF paints at a new size
  // (producer-allocates: the bridge always matches the painted frame, so the
  // CopyResource below is always 1:1 — the wrong-size class is structurally
  // gone, same rationale as main.mm EnsureSurfaceForPaint:749-785).
  ComPtr<ID3D11Texture2D> bridge;
  uint64_t bridge_handle = 0;  // IDXGIResource::GetSharedHandle of `bridge`
  int bridge_w = 0;
  int bridge_h = 0;
  // g_d3d_epoch the current `bridge` was minted at. A mismatch means the device
  // it lives on was lost/reset, so the bridge must be re-minted (#9).
  uint64_t bridge_epoch = 0;
  // Belt-1 friendliness: the OLD bridge is kept alive here across a re-mint
  // until the kOpPresent announcing its replacement has been written to the
  // pipe (the plugin also holds its own opened D3D reference — LAW 6 — this
  // is the producer-side half of that belt).
  ComPtr<ID3D11Texture2D> retired_bridge;
  // Set under surface_mutex in OnBeforeClose BEFORE releasing `bridge`, so a
  // paint racing teardown doesn't re-mint a bridge for a closing browser.
  bool closing = false;

  int width = 800;   // logical (DIP) — GetViewRect; CEF scales by dpr.
  int height = 600;
  double dpr = 1.0;

  // Exact URLs armed for a host-trusted content load (kOpLoadTrusted /
  // data:-file: create). Exact-URL matched + consumed in OnBeforeBrowse —
  // see main.mm:222-233 for why it is URL-bound, not a one-shot flag.
  // UI-thread only.
  std::multiset<std::string> trusted_pending;

  // Pending JS dialog callbacks, keyed by id. UI-thread-only.
  std::map<uint32_t, CefRefPtr<CefJSDialogCallback>> dialogs;
  uint32_t dialog_next = 1;

  // Visibility (kOpSetVisible -> WasHidden). UI-thread only. On Windows there
  // is no begin-frame pump to gate (LAW 1); this drives WasHidden plus the
  // hidden->visible repaint kick (the F-1 keystone, main.mm:1962-1985).
  bool visible = true;
  // F-1/F-2: a dpr change landing while hidden defers its screen-info
  // re-assert to the hidden->visible edge. UI-thread only.
  bool needs_screen_info_on_show = false;

  // The URL to navigate to once the browser binds (a navigate that raced a
  // still-queued create — main.mm:1876-1888 deferral). UI-thread only.
  std::string pending_nav_url;

  uint64_t diag_paint_count = 0;  // DIAG (FLUTTER_CEF_DEBUG logging)
};

// Routing map from a wire browser id to its Slot. MUTATED ONLY ON THE CEF UI
// THREAD (insert in DoCreateBrowser, erase in OnBeforeClose). The IPC reader
// thread takes g_slots_mutex, copies the shared_ptr, releases the lock, then
// operates — a slot stays alive for an in-flight op even if disposed
// (main.mm:276-293).
std::mutex g_slots_mutex;
std::map<uint32_t, std::shared_ptr<Slot>> g_slots_by_wire_id;

std::shared_ptr<Slot> LookupWireId(uint32_t wire_id) {
  if (wire_id == 0) return nullptr;
  std::lock_guard<std::mutex> lock(g_slots_mutex);
  auto it = g_slots_by_wire_id.find(wire_id);
  return it == g_slots_by_wire_id.end() ? nullptr : it->second;
}

// ---- Render handler: OSR -> legacy shared bridge texture ----
// One handler per browser; holds a shared_ptr to that browser's Slot. All
// bridge access is under slot_->surface_mutex; paints re-check slot_->closing
// after taking the lock since OnBeforeClose releases the bridge under the
// same lock.
class HostRenderHandler : public CefRenderHandler {
 public:
  explicit HostRenderHandler(std::shared_ptr<Slot> slot)
      : slot_(std::move(slot)) {}

  void GetViewRect(CefRefPtr<CefBrowser>, CefRect& rect) override {
    std::lock_guard<std::mutex> lock(slot_->surface_mutex);
    rect = CefRect(0, 0, slot_->width, slot_->height);
  }

  // The REAL display (DIP), not the tile: `window.screen == innerWidth` is a
  // textbook headless/OSR fingerprint (see main.mm RealScreenDip:586-609 and
  // commit 855042d). GetSystemMetrics returns px in this process's DPI
  // context; divide by dpr for DIP. Falls back to a plausible frame.
  static void RealScreenDip(double dpr, CefRect& full, CefRect& work) {
    const double s = dpr > 0.0 ? dpr : 1.0;
    const int pw = GetSystemMetrics(SM_CXSCREEN);
    const int ph = GetSystemMetrics(SM_CYSCREEN);
    RECT wa = {};
    if (pw <= 0 || ph <= 0 ||
        !SystemParametersInfoW(SPI_GETWORKAREA, 0, &wa, 0)) {
      full = CefRect(0, 0, 1920, 1080);       // headless fallback: common 24"
      work = CefRect(0, 0, 1920, 1080 - 48);  // minus a taskbar
      return;
    }
    full = CefRect(0, 0, static_cast<int>(pw / s), static_cast<int>(ph / s));
    work = CefRect(static_cast<int>(wa.left / s), static_cast<int>(wa.top / s),
                   static_cast<int>((wa.right - wa.left) / s),
                   static_cast<int>((wa.bottom - wa.top) / s));
  }

  // Device scale so CEF renders logical*dpr (HiDPI-native) + real screen
  // bounds and color depth (mirrors main.mm GetScreenInfo:614-625).
  bool GetScreenInfo(CefRefPtr<CefBrowser>, CefScreenInfo& info) override {
    std::lock_guard<std::mutex> lock(slot_->surface_mutex);
    info.device_scale_factor = static_cast<float>(slot_->dpr);
    info.depth = 24;  // screen.colorDepth — 0 was a headless tell
    info.depth_per_component = 8;
    info.is_monochrome = 0;
    CefRect full, work;
    RealScreenDip(slot_->dpr, full, work);
    info.rect = full;
    info.available_rect = work;
    return true;
  }

  // Plausible window frame at a non-zero offset, taller than the view by
  // typical browser chrome (outerHeight > innerHeight like a real window) —
  // main.mm GetRootScreenRect:633-638.
  bool GetRootScreenRect(CefRefPtr<CefBrowser>, CefRect& rect) override {
    std::lock_guard<std::mutex> lock(slot_->surface_mutex);
    constexpr int kChromeH = 87;
    rect = CefRect(100, 80, slot_->width, slot_->height + kChromeH);
    return true;
  }

  // PRODUCER-ALLOCATES: ensure the bridge is EXACTLY sw x sh — the dims CEF
  // actually painted. Because the CopyResource dst is then the same size as
  // the src, the copy is 1:1 and can never crop or leave stale margins
  // (main.mm EnsureSurfaceForPaint rationale). Re-mints on first paint or any
  // size change; the OLD bridge is parked in retired_bridge until the present
  // that announces its replacement is on the wire. Caller holds
  // slot_->surface_mutex AND g_d3d_mutex.
  bool EnsureBridgeForPaintLocked(int sw, int sh) {
    if (sw < 1 || sh < 1) return false;
    if (slot_->closing) return false;  // paint racing teardown: no re-mint
    if (slot_->bridge && slot_->bridge_w == sw && slot_->bridge_h == sh &&
        slot_->bridge_epoch == g_d3d_epoch.load())
      return true;  // steady state: zero allocation (same device + same size)
    D3D11_TEXTURE2D_DESC d = {};
    d.Width = static_cast<UINT>(sw);
    d.Height = static_cast<UINT>(sh);
    d.MipLevels = 1;
    d.ArraySize = 1;
    d.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    d.SampleDesc.Count = 1;
    d.Usage = D3D11_USAGE_DEFAULT;
    d.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    d.MiscFlags = D3D11_RESOURCE_MISC_SHARED;  // LEGACY handle (LAW 5)
    ComPtr<ID3D11Texture2D> fresh;
    HRESULT hr = g_d3d_device->CreateTexture2D(&d, nullptr, &fresh);
    if (FAILED(hr)) {
      SendLog(slot_->browser_id,
              "EnsureBridgeForPaint: CreateTexture2D failed hr=" +
                  std::to_string(static_cast<long>(hr)));
      return slot_->bridge != nullptr;  // keep the old bridge; retry next paint
    }
    ComPtr<IDXGIResource> res;
    HANDLE legacy = nullptr;
    if (FAILED(fresh.As(&res)) || FAILED(res->GetSharedHandle(&legacy)) ||
        !legacy) {
      SendLog(slot_->browser_id,
              "EnsureBridgeForPaint: GetSharedHandle failed");
      return slot_->bridge != nullptr;
    }
    // Park the old bridge until the present carrying the NEW handle is sent
    // (belt-1 friendliness — the plugin's own opened ref is the primary belt).
    slot_->retired_bridge = slot_->bridge;
    slot_->bridge = fresh;
    slot_->bridge_handle =
        static_cast<uint64_t>(reinterpret_cast<uintptr_t>(legacy));
    slot_->bridge_w = sw;
    slot_->bridge_h = sh;
    slot_->bridge_epoch = g_d3d_epoch.load();
    return true;
  }

  // Present the just-blitted bridge, tagging the frame with the bridge handle
  // (the identity, LAW 3) and the PHYSICAL px dims of the frame actually
  // composited (the size-gate signal, LAW 4 / PROTOCOL.md §5). Caller holds
  // slot_->surface_mutex. Windows payload (LAW 10):
  // {u64 bridgeHandle BE}{u32 srcW BE}{u32 srcH BE} = 16 bytes.
  void SendPresentLocked(int srcW, int srcH) {
    uint8_t p[16];
    WriteU64BE(p, slot_->bridge_handle);
    WriteU32BE(p + 8, static_cast<uint32_t>(srcW < 0 ? 0 : srcW));
    WriteU32BE(p + 12, static_cast<uint32_t>(srcH < 0 ? 0 : srcH));
    SendFrame(slot_->browser_id, kOpPresent, p, 16);
    // The present announcing the new bridge is on the wire — the old bridge
    // may now die (the plugin holds its own reference to it, LAW 6).
    slot_->retired_bridge.Reset();
  }

  // GPU pixel path (LAW 2, the S1 cef_leg.cpp recipe): CEF's GPU process
  // composites the page and hands an NT shared handle valid ONLY inside this
  // callback. Open it on our device, CopyResource into the legacy bridge,
  // Flush — all synchronously, never storing the NT handle.
  void OnAcceleratedPaint(CefRefPtr<CefBrowser>, PaintElementType type,
                          const RectList&,
                          const CefAcceleratedPaintInfo& info) override {
    slot_->diag_paint_count++;
    // Deferred navigate (a navigate that raced the async create — the browser
    // has certainly bound by first paint). Mirrors main.mm:1004-1008.
    if (!slot_->pending_nav_url.empty() && slot_->browser) {
      std::string nav = slot_->pending_nav_url;
      slot_->pending_nav_url.clear();
      if (auto frame = slot_->browser->GetMainFrame()) frame->LoadURL(nav);
    }
    if (type == PET_POPUP) {
      // <select>-dropdown compositing is post-slice (the macOS CPU-composite
      // popup path). Log once so the gap is visible, not silent.
      static std::atomic<bool> logged{false};
      if (!logged.exchange(true))
        SendLog(slot_->browser_id,
                "OnAcceleratedPaint: PET_POPUP compositing not implemented in "
                "the slice — dropdown pixels are dropped");
      return;
    }
    HANDLE nt = info.shared_texture_handle;
    if (!nt) {
      SendLog(slot_->browser_id, "OnAcceleratedPaint: null shared handle");
      return;
    }
    std::lock_guard<std::mutex> lock(slot_->surface_mutex);
    if (slot_->closing) return;
    if (!EnsureD3D()) {
      static std::atomic<bool> logged{false};
      if (!logged.exchange(true))
        SendLog(slot_->browser_id,
                "OnAcceleratedPaint: D3D11 unavailable — no pixel path");
      return;
    }
    int srcW = 0, srcH = 0;
    {
      std::lock_guard<std::mutex> d3d(g_d3d_mutex);
      // LAW 2: open + copy INSIDE the callback. `src` (the ComPtr) is
      // released before we return; the NT handle itself is never kept.
      ComPtr<ID3D11Texture2D> src;
      HRESULT hr = g_d3d_device1->OpenSharedResource1(
          nt, __uuidof(ID3D11Texture2D), &src);
      if (FAILED(hr)) {
        // #9: distinguish a transient bad-handle miss from real device loss. On
        // loss, drop the cached device (+ bump the epoch) so the next paint
        // re-creates the device and every bridge — otherwise the dead device is
        // cached forever and the tile never repaints.
        if (D3DDeviceLostLocked()) {
          SendLog(slot_->browser_id,
                  "OnAcceleratedPaint: D3D device lost (open) — resetting; next "
                  "paint re-creates");
          ResetD3DDeviceLocked();
        } else {
          SendLog(slot_->browser_id,
                  "OnAcceleratedPaint: OpenSharedResource1 failed hr=" +
                      std::to_string(static_cast<long>(hr)));
        }
        return;
      }
      // The opened texture's own desc is the truth about the frame's physical
      // dims (info.extra.coded_size matches it; the desc can't lie).
      D3D11_TEXTURE2D_DESC sd = {};
      src->GetDesc(&sd);
      srcW = static_cast<int>(sd.Width);
      srcH = static_cast<int>(sd.Height);
      if (!EnsureBridgeForPaintLocked(srcW, srcH)) return;
      g_d3d_ctx->CopyResource(slot_->bridge.Get(), src.Get());
      g_d3d_ctx->Flush();
      // CopyResource/Flush return void; device loss surfaces via
      // GetDeviceRemovedReason. If it went down mid-blit, reset and skip this
      // frame — never present pixels from a dead device (#9).
      if (D3DDeviceLostLocked()) {
        SendLog(slot_->browser_id,
                "OnAcceleratedPaint: D3D device lost (blit) — resetting; next "
                "paint re-creates");
        ResetD3DDeviceLocked();
        return;
      }
    }
    if (std::getenv("FLUTTER_CEF_DEBUG") &&
        (slot_->diag_paint_count <= 3 || slot_->diag_paint_count % 120 == 0)) {
      const int wantW = static_cast<int>(slot_->width * slot_->dpr + 0.5);
      const int wantH = static_cast<int>(slot_->height * slot_->dpr + 0.5);
      char buf[160];
      snprintf(buf, sizeof(buf),
               "diag wire=%u paint#%llu painted=%dx%d want=%dx%d bridge=%llu",
               slot_->browser_id,
               static_cast<unsigned long long>(slot_->diag_paint_count), srcW,
               srcH, wantW, wantH,
               static_cast<unsigned long long>(slot_->bridge_handle));
      SendLog(slot_->browser_id, buf);
    }
    SendPresentLocked(srcW, srcH);
  }

  // Software OSR fallback. GPU (OnAcceleratedPaint) is the slice's primary
  // and only pixel path — shared_texture_enabled is always set — so this
  // fires only if a build/driver leaves the accelerated path off. Log once
  // (process-wide) so the gap is visible, not silent (slice contract; a CPU
  // upload path into a staging bridge texture is the post-slice completion).
  void OnPaint(CefRefPtr<CefBrowser>, PaintElementType, const RectList&,
               const void*, int width, int height) override {
    static std::atomic<bool> logged{false};
    if (!logged.exchange(true)) {
      SendLog(slot_->browser_id,
              "OnPaint (software) fired — GPU shared-texture path inactive; "
              "the slice has no software present path, frame " +
                  std::to_string(width) + "x" + std::to_string(height) +
                  " dropped");
    }
  }

 private:
  std::shared_ptr<Slot> slot_;

  IMPLEMENT_REFCOUNTING(HostRenderHandler);
};

// Deny-default permission gate (verbatim port of main.mm:1068-1089): no
// per-site UI exists here, so every permission prompt and media-access
// request is denied up front.
class HostPermissionHandler : public CefPermissionHandler {
 public:
  bool OnRequestMediaAccessPermission(
      CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, const CefString&, uint32_t,
      CefRefPtr<CefMediaAccessCallback> callback) override {
    callback->Continue(CEF_MEDIA_PERMISSION_NONE);
    return true;
  }
  bool OnShowPermissionPrompt(
      CefRefPtr<CefBrowser>, uint64_t, const CefString&, uint32_t,
      CefRefPtr<CefPermissionPromptCallback> callback) override {
    callback->Continue(CEF_PERMISSION_RESULT_DENY);
    return true;
  }

  IMPLEMENT_REFCOUNTING(HostPermissionHandler);
};

class HostClient : public CefClient,
                   public CefLoadHandler,
                   public CefDisplayHandler,
                   public CefLifeSpanHandler,
                   public CefFindHandler,
                   public CefJSDialogHandler,
                   public CefDownloadHandler,
                   public CefRequestHandler,
                   public CefMessageRouterBrowserSide::Handler {
 public:
  explicit HostClient(std::shared_ptr<Slot> slot) : slot_(std::move(slot)) {
    // Browser-side message router (default config: window.cefQuery /
    // cefQueryCancel) — the SAME config the renderer half uses (main.mm:
    // 1228-1234). One router per HostClient, i.e. per browser: OnQuery below
    // stamps slot_->browser_id so a page message is delivered ONLY to the
    // originating session (per-session routing, channel_probe_shared).
    CefMessageRouterConfig config;
    router_ = CefMessageRouterBrowserSide::Create(config);
    router_->AddHandler(this, false);
    rh_ = new HostRenderHandler(slot_);
    ph_ = new HostPermissionHandler();
  }
  CefRefPtr<CefMessageRouterBrowserSide> router_;
  CefRefPtr<CefRenderHandler> rh_;
  CefRefPtr<CefPermissionHandler> ph_;
  CefRefPtr<CefRenderHandler> GetRenderHandler() override { return rh_; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override {
    return ph_;
  }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

  // CefDownloadHandler (main.mm:1251-1257): allow downloads + notify the
  // plugin. macOS Continues with an empty path + show_dialog so AppKit's
  // native save panel picks the location; a hidden-window OSR host on Windows
  // has no good save panel, so default to the user's Downloads folder
  // (SHGetKnownFolderPath FOLDERID_Downloads) with the suggested name, and
  // fall back to the Save-As dialog only if the folder can't be resolved.
  bool OnBeforeDownload(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem>,
                        const CefString& suggested_name,
                        CefRefPtr<CefBeforeDownloadCallback> callback) override {
    SendUtf8(slot_->browser_id, kOpDownload, suggested_name.ToString());
    const std::wstring dir = GetDownloadsDir();
    if (!dir.empty()) {
      // SECURITY: suggested_name is page-controlled (Content-Disposition), so
      // reduce it to a bare leaf before joining it to Downloads — a name like
      // "..\..\Startup\x.exe" or an absolute path would otherwise escape the
      // folder. Take the component after the last / or \, reject . / .. /
      // empty, and drop any residual separators.
      std::wstring leaf = suggested_name.ToWString();
      const size_t slash = leaf.find_last_of(L"/\\");
      if (slash != std::wstring::npos) leaf = leaf.substr(slash + 1);
      leaf.erase(std::remove_if(leaf.begin(), leaf.end(),
                                [](wchar_t c) { return c == L'/' || c == L'\\'; }),
                 leaf.end());
      if (leaf.empty() || leaf == L"." || leaf == L"..") leaf = L"download";
      CefString full;
      full.FromWString(dir + L"\\" + leaf);
      callback->Continue(full, /*show_dialog=*/false);
    } else {
      callback->Continue(CefString(), /*show_dialog=*/true);
    }
    return true;
  }

  // CefFindHandler (main.mm:1260-1275).
  void OnFindResult(CefRefPtr<CefBrowser>, int, int count, const CefRect&,
                    int activeMatchOrdinal, bool finalUpdate) override {
    uint8_t p[9];
    WriteU32BE(p, static_cast<uint32_t>(count));
    WriteU32BE(p + 4, static_cast<uint32_t>(activeMatchOrdinal));
    p[8] = finalUpdate ? 1 : 0;
    SendFrame(slot_->browser_id, kOpFindResult, p, 9);
  }

  // CefJSDialogHandler (main.mm:1279-1315): forward alert/confirm/prompt;
  // the plugin answers via kOpJsDialogResp -> DoJsDialogResp -> Continue.
  bool OnJSDialog(CefRefPtr<CefBrowser>, const CefString&,
                  JSDialogType dialog_type, const CefString& message_text,
                  const CefString& default_prompt_text,
                  CefRefPtr<CefJSDialogCallback> callback,
                  bool&) override {
    uint32_t id = slot_->dialog_next++;
    slot_->dialogs[id] = callback;
    uint32_t type = dialog_type == JSDIALOGTYPE_ALERT
                        ? 0
                        : (dialog_type == JSDIALOGTYPE_CONFIRM ? 1 : 2);
    std::string msg = message_text.ToString();
    std::string def = default_prompt_text.ToString();
    std::vector<uint8_t> p(12 + msg.size() + def.size());
    WriteU32BE(p.data(), id);
    WriteU32BE(p.data() + 4, type);
    WriteU32BE(p.data() + 8, static_cast<uint32_t>(msg.size()));
    memcpy(p.data() + 12, msg.data(), msg.size());
    memcpy(p.data() + 12 + msg.size(), def.data(), def.size());
    SendFrame(slot_->browser_id, kOpJsDialog, p.data(),
              static_cast<uint32_t>(p.size()));
    return true;  // answered asynchronously via Continue()
  }
  bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser>, const CefString&, bool,
                            CefRefPtr<CefJSDialogCallback> callback) override {
    callback->Continue(true, CefString());  // never block navigation away
    return true;
  }
  void OnResetDialogState(CefRefPtr<CefBrowser>) override {
    slot_->dialogs.clear();
  }

  // Renderer crash: reload rather than show a dead page (main.mm:1320-1327).
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                 TerminationStatus status, int,
                                 const CefString&) override {
    SendLog(slot_->browser_id, "renderer terminated (status " +
                                   std::to_string(status) + ") — reloading");
    if (router_) router_->OnRenderProcessTerminated(browser);
    if (browser) browser->ReloadIgnoreCache();
  }

  // CefMessageRouter wiring (main.mm:1468-1501). The renderer half (HostApp
  // below) injects window.cefQuery; queries land here. Forward the request to
  // the plugin: "eval:<id>:<json>" -> kOpEvalResult (a
  // runJavaScriptReturningResult result); "ch:<name>:<message>" ->
  // kOpChannelMsg (a JS-channel post). Both are stamped with slot_->browser_id
  // (this HostClient owns exactly one browser), so the message reaches ONLY the
  // originating session's Dart channel — the per-session routing boundary
  // (channel_probe_shared). 'eval:'/'ch:' are privileged (they hit the trusted
  // host eval path / the channel bridge) and the shim is injected per-frame, so
  // honor them ONLY from the MAIN frame; refuse a forged subframe query.
  bool OnQuery(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, int64_t,
               const CefString& request, bool,
               CefRefPtr<Callback> callback) override {
    std::string r = request.ToString();
    const bool main_frame = !frame || frame->IsMain();
    if (r.rfind("eval:", 0) == 0) {
      if (!main_frame) {
        callback->Failure(403, "subframe");
        return true;
      }
      SendUtf8(slot_->browser_id, kOpEvalResult, r.substr(5));
      callback->Success(CefString());
      return true;
    }
    if (r.rfind("ch:", 0) == 0) {
      if (!main_frame) {
        callback->Failure(403, "subframe");
        return true;
      }
      SendUtf8(slot_->browser_id, kOpChannelMsg, r.substr(3));
      callback->Success(CefString());
      return true;
    }
    return false;
  }

  // Route renderer->browser process messages through the message router
  // (main.mm:1495-1501). This carries the cefQuery payloads that surface in
  // OnQuery above.
  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                CefProcessId source_process,
                                CefRefPtr<CefProcessMessage> message) override {
    return router_->OnProcessMessageReceived(browser, frame, source_process,
                                             message);
  }

  // CefLoadHandler: spinner + back/forward enablement.
  void OnLoadingStateChange(CefRefPtr<CefBrowser>, bool isLoading,
                            bool canGoBack, bool canGoForward) override {
    SendLoadState(slot_->browser_id, isLoading, canGoBack, canGoForward);
  }
  void OnLoadStart(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                   TransitionType) override {
    if (frame && frame->IsMain()) {
      SendUtf8(slot_->browser_id, kOpPageStart, frame->GetURL().ToString());
      // SECURITY (main.mm:1339-1343): install the JS-channel shims ONLY into
      // the MAIN frame — injecting the privileged window.<name> bridge into a
      // cross-origin subframe would hand an untrusted iframe that bridge.
      for (const auto& name : g_channels) InjectChannelShim(frame, name);
    }
  }
  void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                 int) override {
    if (frame && frame->IsMain()) {
      SendUtf8(slot_->browser_id, kOpPageFinish, frame->GetURL().ToString());
      // C1 render floor (main.mm:1350-1363, minus the external begin-frame
      // per LAW 1): re-assert size + damage when the main frame finishes so a
      // coalesced/dropped first frame is re-driven. Hidden tiles stay paused.
      if (browser && browser->GetHost() && slot_->visible) {
        auto h = browser->GetHost();
        h->WasResized();
        h->Invalidate(PET_VIEW);
      }
    }
  }
  void OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, ErrorCode code,
                   const CefString& text, const CefString& url) override {
    if (code == ERR_ABORTED) return;
    SendCodePlusUtf8(slot_->browser_id, kOpLoadErr, static_cast<uint32_t>(code),
                     url.ToString() + "\n" + text.ToString());
  }

  // CefDisplayHandler: title / address / console / progress -> plugin.
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
    uint8_t p[4];
    WriteU32BE(p, static_cast<uint32_t>(progress * 100.0 + 0.5));
    SendFrame(slot_->browser_id, kOpProgress, p, 4);
  }

  // H3 (main.mm:1404-1426): async create completes here. Bind the browser,
  // ack kOpCreated (the plugin's create pacer), honor deferred close /
  // visibility intents. No begin-frame pump to start (LAW 1 — CEF's internal
  // frame timer drives paints).
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    if (std::getenv("FLUTTER_CEF_DEBUG"))
      LogErr("[cef_host] OnAfterCreated wire=%u", slot_->browser_id);
    slot_->browser = browser;
    SendFrame(slot_->browser_id, kOpCreated, nullptr, 0);
    if (slot_->close_requested) {
      browser->GetHost()->CloseBrowser(true);
      return;
    }
    if (!slot_->visible) browser->GetHost()->WasHidden(true);
    // A navigate arrived while the create was in flight — apply it now.
    if (!slot_->pending_nav_url.empty()) {
      std::string nav = slot_->pending_nav_url;
      slot_->pending_nav_url.clear();
      if (auto frame = browser->GetMainFrame()) frame->LoadURL(nav);
    }
  }

  // Popups. macOS (main.mm:1444-1451) splits by disposition: a SIZED popup
  // (CEF_WOD_NEW_POPUP — the window.open-with-features shape OAuth/"Sign in with
  // Google" uses) gets a REAL native window so window.opener/postMessage/
  // window.close work; everything else (target=_blank / plain new tab) diverts
  // to kOpNewWindow and loads in-place. The native-window port is post-slice on
  // Windows, so sized popups still divert in-tab — but that CANNOT complete the
  // opener/postMessage handshake (it strands sign-in). Emit a distinct log per
  // CEF_WOD_NEW_POPUP so the regression is visible, not silent.
  bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int,
                     const CefString& target_url, const CefString&,
                     CefLifeSpanHandler::WindowOpenDisposition disposition, bool,
                     const CefPopupFeatures&,
                     CefWindowInfo&, CefRefPtr<CefClient>&, CefBrowserSettings&,
                     CefRefPtr<CefDictionaryValue>&, bool*) override {
    if (disposition == CEF_WOD_NEW_POPUP) {
      static std::atomic<bool> logged{false};
      if (!logged.exchange(true))
        SendLog(slot_->browser_id,
                "OnBeforePopup: sized popup (CEF_WOD_NEW_POPUP) diverted in-tab "
                "— native OAuth-popup window is post-slice on Windows; "
                "window.open sign-in (opener/postMessage) will not complete "
                "(macOS OpenNativeAuthPopup, main.mm:1444)");
    }
    // Non-native case (matches macOS's non-popup branch, main.mm:1449-1451):
    // load the target in this tile.
    if (!target_url.empty())
      SendUtf8(slot_->browser_id, kOpNewWindow, target_url.ToString());
    return true;  // cancel the native popup
  }

  // Page cursor -> plugin (drives the Flutter MouseRegion cursor).
  bool OnCursorChange(CefRefPtr<CefBrowser>, CefCursorHandle,
                      cef_cursor_type_t type, const CefCursorInfo&) override {
    uint8_t p[4];
    WriteU32BE(p, static_cast<uint32_t>(type));
    SendFrame(slot_->browser_id, kOpCursor, p, 4);
    return true;
  }

  // Centralized per-browser teardown (main.mm:1510-1527): drop the routing
  // entry, release the bridge under the slot lock (closing set FIRST so a
  // racing paint can't re-mint), break the retain cycle.
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    if (router_) router_->OnBeforeClose(browser);
    {
      std::lock_guard<std::mutex> lock(g_slots_mutex);
      g_slots_by_wire_id.erase(slot_->browser_id);
    }
    {
      std::lock_guard<std::mutex> lock(slot_->surface_mutex);
      slot_->closing = true;
      slot_->bridge.Reset();
      slot_->retired_bridge.Reset();
      slot_->bridge_handle = 0;
      slot_->bridge_w = 0;
      slot_->bridge_h = 0;
    }
    slot_->browser = nullptr;
  }

  // Navigation scheme allowlist (main.mm:1528-1565). Empty allowlist = allow
  // all. Main-frame only; kOpLoadTrusted's exact-URL exemptions are consumed
  // here.
  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request, bool, bool) override {
    // Clean up any pending message-router queries for the frame about to
    // navigate (main.mm:1563) — otherwise a channel query in flight across a
    // navigation can misfire or leak its callback.
    if (router_) router_->OnBeforeBrowse(browser, frame);
    if (g_allowed_schemes.empty()) return false;  // allow
    const std::string url = request->GetURL().ToString();
    const bool main_frame = !frame || frame->IsMain();
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
      if (scheme != "about" && g_allowed_schemes.count(scheme) == 0)
        return true;  // cancel
    }
    return false;  // allow
  }

 private:
  std::shared_ptr<Slot> slot_;

  IMPLEMENT_REFCOUNTING(HostClient);
};

// ---- CEF app ----

// The one CefApp, used for BOTH the browser process (CefInitialize) and every
// re-exec'd sub-process (CefExecuteProcess). CEF calls GetBrowserProcessHandler
// in the browser process and GetRenderProcessHandler in the render process, so
// the SAME binary hosts both halves of CefMessageRouter (main.mm's split across
// main.mm + process_helper.mm collapses here — Windows re-runs cef_host.exe as
// the render subprocess, LAW 8). The renderer half owns a
// CefMessageRouterRendererSide with the DEFAULT config (must match the
// browser-side HostClient config); it injects window.cefQuery into every frame
// and relays cefQuery calls to the browser process.
class HostApp : public CefApp,
                public CefBrowserProcessHandler,
                public CefRenderProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }
  CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override {
    return this;
  }

  // ---- Render-process half (process_helper.mm:24-57 counterpart) ----
  // Render-process-only callback; create the renderer-side router here with the
  // default config (window.cefQuery / cefQueryCancel).
  void OnWebKitInitialized() override {
    CefMessageRouterConfig config;
    render_router_ = CefMessageRouterRendererSide::Create(config);
  }
  void OnContextCreated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefV8Context> context) override {
    if (render_router_) render_router_->OnContextCreated(browser, frame,
                                                         context);
  }
  void OnContextReleased(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefFrame> frame,
                         CefRefPtr<CefV8Context> context) override {
    if (render_router_)
      render_router_->OnContextReleased(browser, frame, context);
  }
  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                CefProcessId source_process,
                                CefRefPtr<CefProcessMessage> message) override {
    return render_router_ &&
           render_router_->OnProcessMessageReceived(browser, frame,
                                                    source_process, message);
  }

  void OnBeforeCommandLineProcessing(
      const CefString& process_type,
      CefRefPtr<CefCommandLine> command_line) override {
    (void)process_type;
    // OSR establishment latency (main.mm:1578-1592): OSR views have no real
    // OS window, so Chromium backgrounds their renderers during first load.
    if (!std::getenv("FLUTTER_CEF_KEEP_BG_THROTTLE")) {
      command_line->AppendSwitch("disable-renderer-backgrounding");
      command_line->AppendSwitch("disable-backgrounding-occluded-windows");
    }
    // Verbose Chromium logging (browser + propagated to children) only when
    // explicitly debugging (macOS main.mm:1627-1631 pattern).
    if (std::getenv("FLUTTER_CEF_DEBUG")) {
      char tmp[MAX_PATH] = {};
      GetTempPathA(MAX_PATH, tmp);
      command_line->AppendSwitch("enable-logging");
      command_line->AppendSwitchWithValue(
          "log-file", std::string(tmp) + "cef_host_chromium.log");
      command_line->AppendSwitchWithValue("v", "1");
    }
    // Agent-control CDP-over-pipe translation (S3, P9): the plugin passed the
    // two inherited pipe HANDLE values as --cdp-io-pipes=<read>,<write>; turn
    // them into Chromium's real switches. Browser process only (process_type
    // empty) — the renderer/GPU children never get the debugging pipe (and never
    // inherited the handles). Mirrors macOS main.mm's --cdp-pipe injection.
    // (disable-blink-features=AutomationControlled is post-slice.)
    if (process_type.empty() && !g_cdp_io_pipes.empty()) {
      command_line->AppendSwitch("remote-debugging-pipe");
      command_line->AppendSwitchWithValue("remote-debugging-io-pipes",
                                           g_cdp_io_pipes);
    }
  }

  // Announce readiness. Payload = {readyFlags, protocolVersion}
  // (main.mm:1664-1682). Bit0 (ad-hoc/mock-keychain build) is a macOS-only
  // concern — Windows sends 0. The plugin sends NOTHING until this arrives,
  // then refuses on protocolVersion skew.
  void OnContextInitialized() override {
    CEF_REQUIRE_UI_THREAD();
    if (std::getenv("FLUTTER_CEF_DEBUG"))
      LogErr("[cef_host] OnContextInitialized");
    const uint8_t ready_payload[2] = {0, kCefHostProtocolVersion};
    SendFrame(/*browser_id=*/0, kOpReady, ready_payload,
              sizeof(ready_payload));
  }

 private:
  // Renderer-side message router (render process only; created in
  // OnWebKitInitialized). Null in the browser process.
  CefRefPtr<CefMessageRouterRendererSide> render_router_;

  IMPLEMENT_REFCOUNTING(HostApp);
};

// ---- CEF-UI-thread op helpers (the IPC reader posts these) ----

// Create a windowless browser (kOpCreateBrowser). CEF UI thread.
// Producer-allocates: no surface/bridge is created here — the first
// OnAcceleratedPaint mints the bridge sized to the actual painted frame.
void DoCreateBrowser(uint32_t wire_id, int w, int h, double dpr,
                     std::string url) {
  CEF_REQUIRE_UI_THREAD();
  // Wire-id reuse guard (main.mm:1696-1708): a collision would let the OLD
  // browser's OnBeforeClose erase the NEW slot. Fail loudly.
  {
    std::lock_guard<std::mutex> lock(g_slots_mutex);
    if (g_slots_by_wire_id.count(wire_id)) {
      SendLog(wire_id,
              "createBrowser: wire id already in use — refusing (id-reuse bug)");
      SendFrame(wire_id, kOpCreateFailed, nullptr, 0);
      return;
    }
  }
  auto slot = std::make_shared<Slot>();
  slot->browser_id = wire_id;
  slot->width = w < 1 ? 1 : w;
  slot->height = h < 1 ? 1 : h;
  slot->dpr = dpr;
  {
    std::lock_guard<std::mutex> lock(g_slots_mutex);
    g_slots_by_wire_id[wire_id] = slot;
  }
  CefWindowInfo window_info;
  // The hidden per-process WS_POPUP window as the windowless parent so
  // dialogs/menus/IMM degrade gracefully (PLAN §4.3; null works too — S5).
  window_info.SetAsWindowless(g_hidden_hwnd);
  // GPU OSR: the GPU process composites and hands OnAcceleratedPaint an NT
  // shared handle (the S1 pixel path).
  window_info.shared_texture_enabled = true;
  // LAW 1: external_begin_frame_enabled stays FALSE (default). With the
  // external pump only the FIRST browser in the process ever paints (S4);
  // CEF's internal frame timer at windowless_frame_rate drives paints.
  window_info.external_begin_frame_enabled = false;
  CefBrowserSettings settings;
  settings.windowless_frame_rate = 60;
  // Render floor (main.mm:1747-1752): opaque background so a dropped frame
  // reads as a blank white tile, not an invisible transparent ghost.
  settings.background_color = CefColorSetARGB(255, 255, 255, 255);
  // create-with-html/file (main.mm:1763-1775): a data:/file: create URL is
  // host-trusted content injection — arm the exact-URL allowlist exemption
  // for the initial load.
  if (!g_allowed_schemes.empty() &&
      (url.rfind("data:", 0) == 0 || url.rfind("file:", 0) == 0)) {
    slot->trusted_pending.insert(url);
  }
  CefRefPtr<HostClient> client = new HostClient(slot);
  // H3: ASYNC create (main.mm:1777-1785). OnAfterCreated binds the browser +
  // acks kOpCreated so the plugin's pacer advances by COMPLETION.
  bool dispatched = CefBrowserHost::CreateBrowser(window_info, client, url,
                                                  settings, nullptr, nullptr);
  if (!dispatched) {
    // H7: reclaim the slot + tell the plugin (main.mm:1786-1805).
    SendLog(wire_id, "createBrowser: CreateBrowser dispatch failed");
    SendFrame(wire_id, kOpCreateFailed, nullptr, 0);
    {
      std::lock_guard<std::mutex> lock(g_slots_mutex);
      g_slots_by_wire_id.erase(wire_id);
    }
    std::lock_guard<std::mutex> slock(slot->surface_mutex);
    slot->closing = true;
    slot->bridge.Reset();
    slot->retired_bridge.Reset();
    slot->bridge_handle = 0;
  }
  if (std::getenv("FLUTTER_CEF_DEBUG"))
    LogErr("[cef_host] createBrowser wire=%u dispatched=%d", wire_id,
           dispatched ? 1 : 0);
}

// Close one browser (kOpDisposeBrowser). The map-erase + bridge release run
// in OnBeforeClose once CEF finishes closing (main.mm:1813-1826).
void DoDisposeBrowser(uint32_t wire_id) {
  CEF_REQUIRE_UI_THREAD();
  std::shared_ptr<Slot> slot = LookupWireId(wire_id);
  if (!slot) return;
  if (slot->browser) {
    slot->browser->GetHost()->CloseBrowser(true);
  } else {
    slot->close_requested = true;  // H3 deferred-close intent
  }
}

// LAW 4: every WasResized discards CEF's frame pool; late frames at the old
// size still arrive and are refused by the plugin's size-gate (each present
// carries its truthful dims). Producer-allocates: the bridge re-mints on the
// first NEW-size paint, not here (main.mm DoResize:1828-1874, with
// Invalidate standing in for SendExternalBeginFrame per LAW 1).
void DoResize(const std::shared_ptr<Slot>& slot, int w, int h, double dpr) {
  if (w < 1 || w > 16384 || h < 1 || h > 16384) {
    SendLog(slot->browser_id, "resize: out-of-range dims " + std::to_string(w) +
                                  "x" + std::to_string(h));
    return;
  }
  bool dpr_changed = false;
  {
    std::lock_guard<std::mutex> lock(slot->surface_mutex);
    slot->width = w;
    slot->height = h;
    if (dpr > 0.0 && dpr != slot->dpr) {
      slot->dpr = dpr;
      dpr_changed = true;
    }
  }
  if (slot->browser) {
    if (slot->visible) {
      if (dpr_changed) slot->browser->GetHost()->NotifyScreenInfoChanged();
      slot->browser->GetHost()->WasResized();
      slot->browser->GetHost()->Invalidate(PET_VIEW);
    } else {
      // F-2: hidden — no frame can result; defer the screen-info re-assert +
      // repaint to the hidden->visible edge (DoSetVisible).
      if (dpr_changed) slot->needs_screen_info_on_show = true;
    }
  }
}

void DoNavigate(const std::shared_ptr<Slot>& slot, const std::string& url) {
  if (!slot->browser) {
    // Browser not yet bound (async create in flight) — defer, don't drop
    // (main.mm:1876-1888).
    slot->pending_nav_url = url;
    return;
  }
  CefRefPtr<CefFrame> f = slot->browser->GetMainFrame();
  if (f) f->LoadURL(url);
}

// Host content-injection load: arm the exact-URL allowlist exemption
// (main.mm DoNavigateTrusted:1897-1901).
void DoNavigateTrusted(const std::shared_ptr<Slot>& slot,
                       const std::string& url) {
  if (!g_allowed_schemes.empty()) slot->trusted_pending.insert(url);
  DoNavigate(slot, url);
}

// Navigate/loadTrusted resolved by wire id ON the UI thread (FIFO behind a
// queued create) so a nav right behind a create is never dropped
// (main.mm:1910-1917).
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
// Focused-frame edit command (main.mm DoEditCommand:1943-1957): OSR has no
// native responder chain, so the plugin invokes these explicitly.
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
// Off-screen render gating + the F-1 hidden->visible repaint keystone
// (main.mm DoSetVisible:1962-1985, Invalidate in place of the external
// begin-frame per LAW 1).
void DoSetVisible(const std::shared_ptr<Slot>& slot, bool visible) {
  const bool was_visible = slot->visible;
  slot->visible = visible;
  if (!slot->browser) return;
  slot->browser->GetHost()->WasHidden(!visible);
  if (visible && !was_visible) {
    if (slot->needs_screen_info_on_show) {
      slot->browser->GetHost()->NotifyScreenInfoChanged();
      slot->needs_screen_info_on_show = false;
    }
    slot->browser->GetHost()->WasResized();
    slot->browser->GetHost()->Invalidate(PET_VIEW);
  }
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
  // On Windows, CefJSDialogCallback::Continue() synchronously re-enters
  // OnResetDialogState(), which clears slot->dialogs — so a Continue()-then-
  // erase(it) (as macOS does, where the reset is async) would erase() through an
  // invalidated iterator and crash the host. Take the ref and drop our map entry
  // BEFORE Continue(); the callback stays alive in `cb`. No wire-observable
  // difference from macOS — this only fixes the iterator lifetime on Windows.
  CefRefPtr<CefJSDialogCallback> cb = it->second;
  slot->dialogs.erase(it);
  cb->Continue(ok, text);
}

// runJavaScriptReturningResult (main.mm DoEvalReturning:2001-2018, verbatim).
// Evaluate the user expression and post its JSON result back through
// window.cefQuery (-> HostClient::OnQuery -> kOpEvalResult "id:json",
// correlated to the Dart Future). `code` is the trusted host's JS (same trust
// level as executeJavaScript) and must be a single expression. It is spliced
// (not eval()'d) so it works under a strict page CSP; the Dart side fails any
// pending result on navigation so a wedged callback can't leak a completer.
void DoEvalReturning(const std::shared_ptr<Slot>& slot, uint32_t id,
                     const std::string& code) {
  if (!slot->browser) return;
  CefRefPtr<CefFrame> frame = slot->browser->GetMainFrame();
  if (!frame) return;
  std::string js =
      "window.cefQuery({request:'eval:" + std::to_string(id) +
      ":'+(function(){try{return JSON.stringify({ok:true,v:(" + code +
      "\n)});}catch(e){return JSON.stringify({ok:false,v:String(e)});}})(),"
      "persistent:false,onSuccess:function(){},onFailure:function(){}});";
  frame->ExecuteJavaScript(js, "", 0);
}

// Register a JS channel (main.mm DoAddChannel:2019-2035, verbatim). Registers
// process-globally: OnLoadStart injects every g_channels entry into each
// freshly-loaded MAIN frame, so the shim lands on the next load. Null-safe on
// `slot` (a shared host may still be queuing this session's create). Also
// injects into the registering session's CURRENT frame, covering registration
// after the page already loaded.
void DoAddChannel(const std::shared_ptr<Slot>& slot, const std::string& name) {
  if (!IsValidChannelName(name)) {
    if (slot)
      SendLog(slot->browser_id,
              "addJavaScriptChannel: rejected invalid name '" + name +
                  "' (must be a JS identifier)");
    return;
  }
  g_channels.insert(name);
  if (slot && slot->browser)
    InjectChannelShim(slot->browser->GetMainFrame(), name);
}

// ---- Cookies (global manager = the shared profile jar; main.mm:2040-2140) ----

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

const char* SameSiteToString(cef_cookie_same_site_t v);
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

// Flushes the JSON array on destruction so the 0-cookie case still replies.
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
    SendCodePlusUtf8(browser_id_, kOpCookies, id_, "[" + json_ + "]");
  }

 private:
  uint32_t browser_id_;
  uint32_t id_;
  std::string json_;
  IMPLEMENT_REFCOUNTING(HostCookieVisitor);
};

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
  (void)slot;
  CefRefPtr<CefCookieManager> mgr = CefCookieManager::GetGlobalManager(nullptr);
  if (mgr) mgr->DeleteCookies(CefString(), CefString(), nullptr);
}
void DoVisitCookies(const std::shared_ptr<Slot>& slot, uint32_t id,
                    const std::string& url) {
  CefRefPtr<CefCookieManager> mgr = CefCookieManager::GetGlobalManager(nullptr);
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
  (void)slot;
  CefRefPtr<CefCookieManager> mgr = CefCookieManager::GetGlobalManager(nullptr);
  if (mgr) mgr->DeleteCookies(url, name, nullptr);
}

void DoShowDevTools(const std::shared_ptr<Slot>& slot) {
  if (!slot->browser) return;
  CefWindowInfo window_info;  // default = windowed DevTools
  CefBrowserSettings settings;
  slot->browser->GetHost()->ShowDevTools(window_info, nullptr, settings,
                                         CefPoint());
}

// ---- IME (main.mm:2219-2248) ----
void DoImeSetComposition(const std::shared_ptr<Slot>& slot,
                         const std::string& text) {
  if (!slot->browser) return;
  CefString t(text);
  uint32_t len = static_cast<uint32_t>(t.length());
  std::vector<CefCompositionUnderline> underlines;
  if (len > 0) {
    CefCompositionUnderline u;
    u.range = CefRange(0, len);
    u.color = 0;
    u.background_color = 0;
    u.thick = 0;
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

// type: 0=move 1=down 2=up 3=wheel 4=leave; button: 0=left 1=middle 2=right.
// x/y logical (DIP) view coords, exactly like macOS (main.mm:2251-2285).
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
      // Focus on press so text fields take input (CEF won't route keys to an
      // unfocused OSR browser).
      host->SetFocus(true);
      host->SendMouseClickEvent(
          ev, static_cast<cef_mouse_button_type_t>(button), false, click_count);
      break;
    case 2:
      host->SendMouseClickEvent(
          ev, static_cast<cef_mouse_button_type_t>(button), true, click_count);
      break;
    case 3:
      host->SendMouseWheelEvent(ev, static_cast<int>(dx), static_cast<int>(dy));
      break;
    case 4:
      host->SendMouseMoveEvent(ev, true);  // mouseLeave: clear hover state
      break;
    default:
      break;
  }
}

// type: 0=rawkeydown 2=keyup 3=char (cef_key_event_type_t). The Dart side
// sends REAL Windows virtual-key codes in windowsKeyCode on Windows (and the
// Unicode codepoint for char events) — native CefKeyEvent semantics, no
// translation needed (main.mm DoKey:2288-2305; character fields always set
// per the CEF t=11650 de-dup note, harmless on Windows).
void DoKey(const std::shared_ptr<Slot>& slot, int type, uint32_t modifiers,
           int32_t windows_key_code, int32_t native_key_code,
           uint32_t character) {
  if (!slot->browser) return;
  CefKeyEvent ev;
  ev.type = static_cast<cef_key_event_type_t>(type);
  ev.modifiers = modifiers;
  ev.windows_key_code = windows_key_code;
  ev.native_key_code = native_key_code;
  ev.is_system_key = 0;
  ev.character = static_cast<char16_t>(character);
  ev.unmodified_character = static_cast<char16_t>(character);
  slot->browser->GetHost()->SendKeyEvent(ev);
}

// C1: watchdog repaint re-kick (main.mm DoInvalidate:2310-2318). LAW 1: no
// SendExternalBeginFrame — the internal frame timer honors Invalidate.
void DoInvalidate(const std::shared_ptr<Slot>& slot) {
  CEF_REQUIRE_UI_THREAD();
  if (slot && slot->browser && slot->browser->GetHost())
    slot->browser->GetHost()->Invalidate(PET_VIEW);
}

// Quit the message loop exactly once (the FlushStore completion and the
// bounded fallback both route here; whichever wins quits, the other is a no-op).
std::atomic<bool> g_quit_posted{false};
void FinishShutdownQuit() {
  CEF_REQUIRE_UI_THREAD();
  if (g_quit_posted.exchange(true)) return;
  CefQuitMessageLoop();
}

// Cookie-store flush completion: once the on-disk jar is written, quit.
class ShutdownFlushCallback : public CefCompletionCallback {
 public:
  void OnComplete() override { FinishShutdownQuit(); }

 private:
  IMPLEMENT_REFCOUNTING(ShutdownFlushCallback);
};

// Tear down the WHOLE process (kOpShutdown / pipe EOF): close every browser,
// flush the cookie jar to disk, then quit the message loop. Per-slot cleanup
// runs in OnBeforeClose (main.mm DoShutdown:2324-2335).
//
// WINDOWS COOKIE DURABILITY (no macOS analogue): unlike macOS — where the
// implicit CefShutdown flush reliably persists the jar — a fast Windows teardown
// exits cleanly (code 0) yet leaves the on-disk cookie store EMPTY (verified:
// a plugin-driven dispose+kOpShutdown flushed nothing, while the SAME host binary
// under a slow standalone driver did). Session cookies (has_expires=false, kept
// by persist_session_cookies) are only guaranteed durable once explicitly
// flushed, so we FlushStore here and defer the quit into its completion — that is
// what makes "stay signed in" survive relaunch. A bounded fallback quits anyway
// if the callback never fires, so teardown can't wedge inside the plugin reaper's
// grace. macOS main.mm is unchanged (it does not need this).
void DoShutdown() {
  CEF_REQUIRE_UI_THREAD();
  std::vector<std::shared_ptr<Slot>> slots;
  {
    std::lock_guard<std::mutex> lock(g_slots_mutex);
    slots.reserve(g_slots_by_wire_id.size());
    for (auto& kv : g_slots_by_wire_id) slots.push_back(kv.second);
  }
  for (auto& slot : slots) {
    if (slot->browser) slot->browser->GetHost()->CloseBrowser(true);
  }
  CefRefPtr<CefCookieManager> mgr = CefCookieManager::GetGlobalManager(nullptr);
  if (mgr) {
    mgr->FlushStore(new ShutdownFlushCallback());
    // Fallback well inside the plugin reaper's 3s grace: never let a missing
    // flush callback wedge the quit.
    CefPostDelayedTask(TID_UI, base::BindOnce(&FinishShutdownQuit), 2000);
  } else {
    FinishShutdownQuit();
  }
}

// Reader thread: decode frames, marshal onto the CEF UI thread (mirrors
// main.mm IpcReadLoop:2338-2603; payload layouts PROTOCOL.md §2).
void IpcReadLoop() {
  HANDLE pipe = g_ipc_pipe.load();
  for (;;) {
    uint8_t hdr[4];
    if (!ReadAllPipe(pipe, hdr, 4)) break;
    uint32_t body_len = ReadU32BE(hdr);
    // Malformed/oversized length = wire desync: log + tear down everything
    // (the IPC peer is trusted, so this only fires on a framing bug).
    if (body_len < kMinBodyLen || body_len > kMaxBodyLen) {
      LogErr("[cef_host] rejecting malformed IPC frame, body_len=%u — exiting",
             body_len);
      break;
    }
    std::vector<uint8_t> body(body_len);
    if (!ReadAllPipe(pipe, body.data(), body_len)) break;
    uint32_t wire_id = ReadU32BE(body.data());
    uint8_t opcode = body[4];
    const uint8_t* p = body.data() + 5;
    uint32_t plen = body_len - 5;
    // Resolve the target slot once; per-browser ops bind this shared_ptr into
    // their UI task so the slot outlives a racing dispose. Ops marked "no
    // slot required" (create/navigate/loadTrusted/shutdown) handle null.
    std::shared_ptr<Slot> slot = LookupWireId(wire_id);
    switch (opcode) {
      case kOpCreateBrowser: {
        // {u32 w}{u32 h}{f64 dpr}{utf8 url}; frame browserId = the NEW id.
        if (plen < 16) break;
        int w = static_cast<int>(ReadU32BE(p));
        int h = static_cast<int>(ReadU32BE(p + 4));
        double dpr = ReadF64BE(p + 8);
        if (dpr <= 0.0 || dpr > 8.0) dpr = 1.0;  // guard a bad/forged dpr
        std::string url(reinterpret_cast<const char*>(p + 16), plen - 16);
        if (url.empty()) url = "about:blank";
        if (std::getenv("FLUTTER_CEF_DEBUG"))
          LogErr("[cef_host] reader: create wire=%u %dx%d dpr=%.2f url=%s",
                 wire_id, w, h, dpr, url.c_str());
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
        // {u32 w}{u32 h}[{f64 dpr}]; dpr 0/absent = unchanged.
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
        // Resolve by wire id on TID_UI: a nav right behind a queued create
        // must not drop (main.mm:2395-2402).
        std::string url(reinterpret_cast<const char*>(p), plen);
        CefPostTask(TID_UI,
                    base::BindOnce(&DoNavigateByWireId, wire_id, url, false));
        break;
      }
      case kOpLoadTrusted: {
        std::string url(reinterpret_cast<const char*>(p), plen);
        CefPostTask(TID_UI,
                    base::BindOnce(&DoNavigateByWireId, wire_id, url, true));
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
      case kOpImeCancel:
        if (!slot) break;
        CefPostTask(TID_UI, base::BindOnce(&DoImeCancel, slot));
        break;
      case kOpShowDevTools:
        if (!slot) break;
        CefPostTask(TID_UI, base::BindOnce(&DoShowDevTools, slot));
        break;
      case kOpInvalidate:
        if (!slot) break;
        CefPostTask(TID_UI, base::BindOnce(&DoInvalidate, slot));
        break;
      case kOpPointer: {
        // 40 bytes: {u8 type}{u8 btn}{u8 clicks}{u8 pad}{u32 mods}{f64 x}
        // {f64 y}{f64 dx}{f64 dy}.
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
        // 20 bytes: {u8 type}{pad*3}{u32 mods}{u32 wkc}{u32 nkc}{u32 char}.
        if (!slot) break;
        if (plen < 20) break;
        int type = p[0];
        uint32_t mods = ReadU32BE(p + 4);
        int32_t wkc = static_cast<int32_t>(ReadU32BE(p + 8));
        int32_t nkc = static_cast<int32_t>(ReadU32BE(p + 12));
        uint32_t ch = ReadU32BE(p + 16);
        CefPostTask(TID_UI,
                    base::BindOnce(&DoKey, slot, type, mods, wkc, nkc, ch));
        break;
      }
      case kOpEvalReturning: {
        // runJavaScriptReturningResult (main.mm:2475-2482). {u32 id}{utf8 code}
        // inbound; DoEvalReturning posts the value back via the message router
        // as kOpEvalResult "id:json", correlated to the Dart Future.
        if (!slot) break;
        if (plen < 4) break;
        uint32_t id = ReadU32BE(p);
        std::string code(reinterpret_cast<const char*>(p + 4), plen - 4);
        CefPostTask(TID_UI, base::BindOnce(&DoEvalReturning, slot, id, code));
        break;
      }
      case kOpAddChannel: {
        // Do NOT require `slot` (main.mm:2483-2494): on a shared host a
        // session's create may still be queued when this arrives; dropping it
        // is exactly why a peer session's window.<name> shim was never
        // injected. DoAddChannel registers the name process-globally
        // (OnLoadStart injects it on the next load) and, if the browser already
        // exists, into its current frame.
        std::string name(reinterpret_cast<const char*>(p), plen);
        CefPostTask(TID_UI, base::BindOnce(&DoAddChannel, slot, name));
        break;
      }
      case kOpResolveTargetId: {
        // Post-slice: needs the DevTools observer (macOS CEF-2b path). It can't
        // hang a Dart Future (fire-and-forget), so a logged drop is safe. Log
        // ONCE per opcode; never kill the stream.
        static bool logged_stub[256] = {false};
        if (!logged_stub[opcode]) {
          logged_stub[opcode] = true;
          SendLog(0, "cef_host: opcode " + std::to_string(opcode) +
                         " not implemented in the Windows slice — dropping");
        }
        break;
      }
      default: {
        // Unknown opcode = protocol skew. Log ONCE per opcode; never kill the
        // stream (main.mm:2583-2598).
        static bool logged_unknown[256] = {false};
        if (!logged_unknown[opcode]) {
          logged_unknown[opcode] = true;
          SendLog(0, "unknown opcode " + std::to_string(opcode) +
                         " (protocol skew? plugin newer than host) — dropping");
        }
        break;
      }
    }
  }
  // Plugin died / pipe closed: quit. (Orphan-kill backstop is the plugin's
  // Job Object — JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE — not a parent watch.)
  CefPostTask(TID_UI, base::BindOnce(&DoShutdown));
}

// Create the ONE hidden window this host passes to SetAsWindowless(parent).
// WS_POPUP, never shown. (PLAN §4.3: a null parent degrades dialogs/menus/
// IMM; browser_platform_delegate_native_win.cc bails on !msg.hwnd.)
HWND CreateHiddenHostWindow() {
  WNDCLASSW wc = {};
  wc.lpfnWndProc = DefWindowProcW;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = L"flutter_cef_host_hidden";
  RegisterClassW(&wc);
  return CreateWindowExW(0, wc.lpszClassName, L"flutter_cef_host", WS_POPUP, 0,
                         0, 1, 1, nullptr, nullptr, wc.hInstance, nullptr);
}

}  // namespace

// Entry point, invoked by CEF's bootstrap (bootstrapc.exe renamed to
// cef_host.exe — LAW 8). sandbox_info MUST be forwarded to both
// CefExecuteProcess and CefInitialize (SPIKES.md S2).
extern "C" CEF_BOOTSTRAP_EXPORT int RunConsoleMain(
    int argc,
    char* argv[],
    void* sandbox_info,
    cef_version_info_t* version_info) {
  (void)version_info;
  CefMainArgs main_args(GetModuleHandle(nullptr));

  // Sub-process (--type=renderer/gpu/...)? Let CEF take over. Windows
  // relaunches this same exe, so no helper-app fan-out (process_helper.mm's
  // 5-helper model collapses to this early return).
  CefRefPtr<HostApp> app(new HostApp);
  int code = CefExecuteProcess(main_args, app, sandbox_info);
  if (code >= 0) return code;

  // ---- Browser process from here on. ----
  std::string ipc_name = GetSwitch(argc, argv, "--ipc=");
  std::string profile_dir = GetSwitch(argc, argv, "--profile-dir=");
  std::string allowed = GetSwitch(argc, argv, "--allowed-schemes=");
  bool ephemeral = HasFlag(argc, argv, "--ephemeral");
  // Agent control (P9): "<read>,<write>" inherited-HANDLE values. Stored in the
  // file-global so OnBeforeCommandLineProcessing (called from CefInitialize
  // below) can inject the Chromium CDP-pipe switches. Empty when off.
  g_cdp_io_pipes = GetSwitch(argc, argv, "--cdp-io-pipes=");
  // NB: the PLUGIN owns ephemeral profile-dir deletion — its reaper deletes the
  // dir once this host is confirmed dead, and a startup sweep reclaims dirs
  // orphaned by a crash (FlutterCefPlugin.cpp TeardownSession reaper +
  // SweepStaleEphemeralProfiles; macOS CefProfileHost.swift:1004-1006). The
  // host need not delete its own dir (it can't reliably, holding it open).

  // Navigation scheme allowlist (lowercased csv; main.mm:2727-2737). Empty =
  // allow all.
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

  if (ipc_name.empty() && !std::getenv("FLUTTER_CEF_TEST_NOPIPE")) {
    LogErr("[cef_host] missing --ipc=<pipe name>");
    return 3;
  }

  if (!ipc_name.empty()) {
    // Connect the plugin's named pipe (the plugin created it BEFORE spawning
    // us, so a plain CreateFileW connects immediately). SECURITY_SQOS_PRESENT
    // | SECURITY_ANONYMOUS: never let a squatted pipe impersonate us.
    // FILE_FLAG_OVERLAPPED: full-duplex — see the OverlappedIo note above.
    HANDLE pipe = CreateFileW(Widen(ipc_name).c_str(),
                              GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                              OPEN_EXISTING,
                              FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT |
                                  SECURITY_ANONYMOUS,
                              nullptr);
    if (pipe == INVALID_HANDLE_VALUE) {
      LogErr("[cef_host] cannot open IPC pipe '%s' (gle=%lu)",
             ipc_name.c_str(), GetLastError());
      return 4;
    }
    g_ipc_pipe.store(pipe);
  }

  // Profile dir fallback: a per-pid ephemeral temp dir (defensive — the
  // plugin always supplies --profile-dir, mirroring main.mm:34-35).
  if (profile_dir.empty()) {
    char tmp[MAX_PATH] = {};
    GetTempPathA(MAX_PATH, tmp);
    profile_dir = std::string(tmp) + "flutter_cef_ephem_" +
                  std::to_string(GetCurrentProcessId());
    ephemeral = true;
  }
  CreateDirectoryW(Widen(profile_dir).c_str(), nullptr);  // ok if it exists

  // Cross-process single-writer lock on a PERSISTENT profile dir (C2,
  // main.mm:2786-2806): exclusive-open <profile>/.flutter_cef.lock; on
  // contention emit the machine-parseable kOpLog "profile-locked" and exit 2
  // (the plugin keys processGone("locked") on that pair). The handle is held
  // for the process lifetime — the OS drops it on exit. Ephemeral dirs are
  // per-spawn and can never contend.
  if (!ephemeral) {
    const std::wstring lock_path = Widen(profile_dir + "\\.flutter_cef.lock");
    // Retry with bounded backoff before declaring the profile locked. A rapid
    // dispose+recreate of the SAME profile (route change / hot reload) races
    // the OUTGOING host, which still holds this exclusive handle until it exits
    // — it defers its quit up to ~2s to flush cookies, and the plugin's reaper
    // waits up to 3s before Terminate. Without the retry the fresh host loses
    // the lock instantly and surfaces a spurious processGone("locked") with no
    // other app open. ~5s of 50ms tries covers the outgoing host's release;
    // a GENUINE cross-app conflict still reports "locked" after the window.
    HANDLE lock = INVALID_HANDLE_VALUE;
    for (int attempt = 0; attempt < 100; ++attempt) {
      lock = CreateFileW(lock_path.c_str(), GENERIC_READ | GENERIC_WRITE,
                         /*dwShareMode=*/0, nullptr, OPEN_ALWAYS,
                         FILE_ATTRIBUTE_NORMAL, nullptr);
      if (lock != INVALID_HANDLE_VALUE) break;
      const DWORD gle = GetLastError();
      if (gle != ERROR_SHARING_VIOLATION && gle != ERROR_ACCESS_DENIED) break;
      Sleep(50);
    }
    if (lock == INVALID_HANDLE_VALUE) {
      SendLog(0, "profile-locked");
      LogErr("[cef_host] profile already in use (%s, gle=%lu)",
             profile_dir.c_str(), GetLastError());
      return 2;
    }
    // Intentionally leaked: the lock must live as long as the profile does.
  }

  g_hidden_hwnd = CreateHiddenHostWindow();

  CefSettings settings;
  settings.windowless_rendering_enabled = 1;
  settings.no_sandbox = 1;  // SLICE: sandbox is P11. Do not enable here.
  settings.multi_threaded_message_loop = 0;
  // Per-profile cache: one root_cache_path shared by every browser in this
  // process is what makes login shared across the tiles on a profile
  // (CefCookieManager::GetGlobalManager -> this jar). persist_session_cookies
  // keeps session cookies across relaunch — set UNCONDITIONALLY, mirroring
  // main.mm:2869 (harmless for an ephemeral host, whose dir the plugin's reaper
  // deletes on teardown; required for a named profile's "stay signed in").
  //
  // AT-REST (SPIKES.md S2 / §7): Windows OSCrypt encrypts the cookie/login
  // stores with DPAPI, which is ALWAYS available and signing-INDEPENDENT — so a
  // named profile persists directly here, with NO analogue of the macOS ad-hoc
  // "mock-keychain -> downgrade named profile to ephemeral" rule (there is no
  // readyFlags bit0 gate on Windows; OnContextInitialized sends 0). DPAPI is
  // same-user-readable (weaker than the macOS Keychain), so the plugin's
  // current-user protected DACL on the profile dir is defense-in-depth.
  CefString(&settings.root_cache_path) = profile_dir;
  CefString(&settings.cache_path) = profile_dir;
  settings.persist_session_cookies = 1;
  if (std::getenv("FLUTTER_CEF_DEBUG"))
    settings.log_severity = LOGSEVERITY_INFO;
  else
    settings.log_severity = LOGSEVERITY_ERROR;

  // EMPIRICAL (S3 s3_dll.cc, reproduced here 2026-07-20): with the slice's
  // no_sandbox=1, CefInitialize must receive NULLPTR, not bootstrapc's
  // sandbox_info — passing the real sandbox_info while the sandbox is
  // disabled makes every child process fail its mojo handshake
  // ("Terminating current process after 15 seconds with no connection":
  // no renderer, no GPU, no network service, browsers never create).
  // sandbox_info IS still forwarded to CefExecuteProcess above (children
  // must see it — that half of LAW 8 stands). P11 (sandbox on) flips
  // no_sandbox=0 AND restores sandbox_info here, the S2-proven pair.
  if (!CefInitialize(main_args, settings, app, /*windows_sandbox_info=*/
                     nullptr)) {
    LogErr("[cef_host] CefInitialize failed, exit_code=%d", CefGetExitCode());
    return 10;
  }

  // Reader thread (same model as macOS main.mm: reader posts to TID_UI via
  // CefPostTask; CefRunMessageLoop owns the main thread).
  std::thread reader;
  if (g_ipc_pipe.load() != INVALID_HANDLE_VALUE) reader = std::thread(IpcReadLoop);
  // Standalone diagnostic mode (FLUTTER_CEF_TEST_NOPIPE): create one browser
  // directly so the process can be exercised without a plugin/pipe peer.
  if (std::getenv("FLUTTER_CEF_TEST_NOPIPE")) {
    CefPostTask(TID_UI, base::BindOnce(&DoCreateBrowser, 1u, 800, 600, 1.0,
                                       std::string("about:blank")));
    CefPostDelayedTask(TID_UI, base::BindOnce([]() {
      LogErr("[cef_host] NOPIPE probe: slots=%zu", g_slots_by_wire_id.size());
      auto slot = LookupWireId(1);
      LogErr("[cef_host] NOPIPE probe: browser bound=%d",
             slot && slot->browser ? 1 : 0);
      CefQuitMessageLoop();
    }), 25000);
  }

  CefRunMessageLoop();

  // Teardown: invalidate the pipe FIRST (atomic exchange), THEN close — so a
  // late SendFrame from a CEF thread can't write into a recycled handle
  // (mirrors main.mm:2910-2918 C3 ordering). Closing the pipe also unblocks
  // the reader's ReadFile, bounding the join... except a reader blocked in
  // ReadFile on a still-open pipe: cancel it explicitly first.
  {
    std::lock_guard<std::mutex> lock(g_ipc_write_mutex);
    HANDLE old = g_ipc_pipe.exchange(INVALID_HANDLE_VALUE);
    if (old != INVALID_HANDLE_VALUE) {
      CancelIoEx(old, nullptr);  // unblock a reader parked in ReadFile
      CloseHandle(old);
    }
  }
  if (reader.joinable()) reader.join();

  CefShutdown();
  return 0;
}
