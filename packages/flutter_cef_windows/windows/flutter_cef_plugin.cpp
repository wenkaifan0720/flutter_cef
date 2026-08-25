// cdp_relay.h pulls in <winsock2.h> BEFORE <windows.h>; it must lead so the
// winsock2/windows.h ordering holds for the whole TU (windows.h's default
// winsock.h would otherwise conflict — the classic WSA redefinition).
#include "cdp_relay.h"

#include "flutter_cef_plugin.h"

#include <windows.h>
#include <sddl.h>

#include <flutter/encodable_value.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <sstream>
#include <string>
#include <vector>

#include "cef_host_protocol.h"
#include "include/flutter_cef_windows/flutter_cef_plugin.h"

// The persistent-profile DACL uses the token/SID/SDDL APIs. advapi32.lib is
// already pulled in by ipc_pipe.cpp (same target); re-declaring is harmless and
// keeps this TU self-documenting.
#pragma comment(lib, "advapi32.lib")

namespace flutter_cef {
namespace {

constexpr wchar_t kMessageWindowClass[] = L"FlutterCefPluginMessageWindow";
constexpr UINT kDrainMessage = WM_APP + 1;

// C1 first-present watchdog grace (macOS firstPaintGrace = 10s, env
// FLUTTER_CEF_FIRSTPAINT_MS; CefProfileHost.swift:649-653).
UINT WatchdogGraceMs() {
  wchar_t buf[32] = {};
  const DWORD n =
      GetEnvironmentVariableW(L"FLUTTER_CEF_FIRSTPAINT_MS", buf, 32);
  if (n > 0 && n < 32) {
    const long ms = wcstol(buf, nullptr, 10);
    if (ms > 0) return static_cast<UINT>(ms);
  }
  return 10000;
}

void Log(const std::string& msg) {
  OutputDebugStringA(("[flutter_cef_windows] " + msg + "\n").c_str());
}

void WarnStub(const std::string& verb) {
  Log("verb '" + verb + "' not implemented (slice stub) — replying success");
}

// ---- EncodableMap arg helpers (mirror the tolerant Swift `as?` reads) ----

std::string GetString(const flutter::EncodableMap& m, const char* key,
                      const std::string& fallback = std::string()) {
  auto it = m.find(flutter::EncodableValue(std::string(key)));
  if (it == m.end()) return fallback;
  const auto* s = std::get_if<std::string>(&it->second);
  return s ? *s : fallback;
}

int64_t GetInt(const flutter::EncodableMap& m, const char* key,
               int64_t fallback = 0) {
  auto it = m.find(flutter::EncodableValue(std::string(key)));
  if (it == m.end()) return fallback;
  if (const auto* i32 = std::get_if<int32_t>(&it->second)) return *i32;
  if (const auto* i64 = std::get_if<int64_t>(&it->second)) return *i64;
  return fallback;
}

double GetDouble(const flutter::EncodableMap& m, const char* key,
                 double fallback = 0.0) {
  auto it = m.find(flutter::EncodableValue(std::string(key)));
  if (it == m.end()) return fallback;
  if (const auto* d = std::get_if<double>(&it->second)) return *d;
  if (const auto* i32 = std::get_if<int32_t>(&it->second))
    return static_cast<double>(*i32);
  if (const auto* i64 = std::get_if<int64_t>(&it->second))
    return static_cast<double>(*i64);
  return fallback;
}

bool GetBool(const flutter::EncodableMap& m, const char* key, bool fallback) {
  auto it = m.find(flutter::EncodableValue(std::string(key)));
  if (it == m.end()) return fallback;
  const auto* b = std::get_if<bool>(&it->second);
  return b ? *b : fallback;
}

// A `profile` arg is "named" only when present AND non-empty (Swift:288-289).
bool HasNamedProfile(const flutter::EncodableMap& m) {
  auto it = m.find(flutter::EncodableValue(std::string("profile")));
  if (it == m.end()) return false;
  const auto* s = std::get_if<std::string>(&it->second);
  return s && !s->empty();
}

// ---- wire payload builders (BE, per cef_host_protocol.h codecs) ----

void AppendU32(std::vector<uint8_t>& out, uint32_t v) {
  uint8_t b[4];
  WriteU32BE(b, v);
  out.insert(out.end(), b, b + 4);
}

void AppendF64(std::vector<uint8_t>& out, double v) {
  uint8_t b[8];
  WriteF64BE(b, v);
  out.insert(out.end(), b, b + 8);
}

void AppendUtf8(std::vector<uint8_t>& out, const std::string& s) {
  out.insert(out.end(), s.begin(), s.end());
}

// ---- inbound payload decoding ----

std::string PayloadString(const std::vector<uint8_t>& payload,
                          size_t offset = 0) {
  if (payload.size() <= offset) return std::string();
  return std::string(reinterpret_cast<const char*>(payload.data()) + offset,
                     payload.size() - offset);
}

uint32_t PayloadU32(const std::vector<uint8_t>& payload, size_t offset) {
  return ReadU32BE(payload.data() + offset);
}

flutter::EncodableValue Ev(const char* s) {
  return flutter::EncodableValue(std::string(s));
}

// Sanitize a profile name to a filesystem-safe leaf: anything outside
// [A-Za-z0-9._-] -> '_' (macOS resolveProfileDir, FlutterCefPlugin.swift:
// 710-717). A leaf of all dots ("."/".."/"...") would resolve to the
// profiles/ container or its PARENT — a one-level containment escape whose
// protected-DACL apply would clobber a shared ancestor — so neutralize it.
std::wstring SanitizeProfileLeaf(const std::string& profile) {
  std::wstring out;
  out.reserve(profile.size());
  bool all_dots = !profile.empty();
  for (unsigned char c : profile) {
    const bool ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                    (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-';
    out.push_back(ok ? static_cast<wchar_t>(c) : L'_');
    if (c != '.') all_dots = false;
  }
  if (out.empty() || all_dots) return L"_";
  // Windows silently drops trailing dots/spaces from a path component, which
  // would let "work." and "work" resolve to the SAME dir (jar confusion) and
  // fight over the profile lock. Spaces already map to '_' via the allowlist;
  // strip trailing dots here so the on-disk leaf is exactly what we keyed on.
  while (!out.empty() && out.back() == L'.') out.pop_back();
  if (out.empty()) return L"_";
  // Reserved DOS device basenames (CON/PRN/AUX/NUL/COM1-9/LPT1-9) are illegal
  // directory names even with an extension — neutralize by prefixing '_'.
  std::wstring base = out.substr(0, out.find(L'.'));
  for (wchar_t& ch : base)
    if (ch >= L'a' && ch <= L'z') ch = static_cast<wchar_t>(ch - 32);
  static const wchar_t* kReserved[] = {
      L"CON",  L"PRN",  L"AUX",  L"NUL",  L"COM1", L"COM2", L"COM3", L"COM4",
      L"COM5", L"COM6", L"COM7", L"COM8", L"COM9", L"LPT1", L"LPT2", L"LPT3",
      L"LPT4", L"LPT5", L"LPT6", L"LPT7", L"LPT8", L"LPT9"};
  for (const wchar_t* r : kReserved)
    if (base == r) return L"_" + out;
  return out;
}

// Build a SECURITY_ATTRIBUTES whose DACL is PROTECTED and grants the current
// user's SID full control only — the same #3 hardening the IPC pipe uses
// (ipc_pipe.cpp BuildCurrentUserOnlySD). On success *out_sd is a LocalAlloc'd
// descriptor the caller must LocalFree AFTER the API call that consumed the SA.
// On Windows the on-disk profile is DPAPI-encrypted (OSCrypt), same-user-
// readable — so this DACL is defense-in-depth (see MakePersistentProfileDir).
bool BuildCurrentUserOnlySD(PSECURITY_DESCRIPTOR* out_sd) {
  *out_sd = nullptr;
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return false;
  DWORD len = 0;
  GetTokenInformation(token, TokenUser, nullptr, 0, &len);
  if (len == 0) {
    CloseHandle(token);
    return false;
  }
  std::vector<uint8_t> buf(len);
  const bool got =
      GetTokenInformation(token, TokenUser, buf.data(), len, &len) != FALSE;
  CloseHandle(token);
  if (!got) return false;
  auto* tu = reinterpret_cast<TOKEN_USER*>(buf.data());
  LPWSTR sid_str = nullptr;
  if (!ConvertSidToStringSidW(tu->User.Sid, &sid_str)) return false;
  // OICI = OBJECT_INHERIT | CONTAINER_INHERIT: the ACE must be INHERITABLE, or
  // files/subdirs Chromium creates under the profile (Default/Network/Cookies,
  // Local State, …) do NOT inherit the user's access — the owner is left without
  // FILE_READ_DATA, so a *freshly spawned* cef_host cannot read the on-disk
  // cookie store it wrote last run and "stay signed in" silently fails (the
  // marker cookie is written but unreadable across a host restart). The pipe's
  // SD (ipc_pipe.cpp) is a single non-inheriting kernel object so it omits OICI;
  // a directory tree must propagate the grant to its children.
  std::wstring sddl = std::wstring(L"D:P(A;OICI;GA;;;") + sid_str + L")";
  LocalFree(sid_str);
  return ConvertStringSecurityDescriptorToSecurityDescriptorW(
             sddl.c_str(), SDDL_REVISION_1, out_sd, nullptr) != FALSE;
}

// Create `dir` with a current-user-only protected DACL if we can build one;
// fall back to a default-DACL create otherwise (never leave the tree
// uncreated). ok-if-exists.
void CreateDirProtected(const std::wstring& dir) {
  PSECURITY_DESCRIPTOR sd = nullptr;
  if (BuildCurrentUserOnlySD(&sd)) {
    SECURITY_ATTRIBUTES sa = {};
    sa.nLength = sizeof(sa);
    sa.lpSecurityDescriptor = sd;
    sa.bInheritHandle = FALSE;
    CreateDirectoryW(dir.c_str(), &sa);
    LocalFree(sd);
  } else {
    CreateDirectoryW(dir.c_str(), nullptr);
  }
}

}  // namespace

// ---- registration / lifecycle ----

// static
void FlutterCefPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<FlutterCefPlugin>(registrar);
  registrar->AddPlugin(std::move(plugin));
}

FlutterCefPlugin::FlutterCefPlugin(flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar) {
  // Reclaim ephemeral profile dirs orphaned by a previous crash/kill before we
  // start minting new ones (macOS sweepStaleEphemeralProfiles at plugin init,
  // FlutterCefPlugin.swift:97-109). No host is live yet.
  SweepStaleEphemeralProfiles();
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), "flutter_cef",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result));
      });
  texture_bridge_ =
      std::make_unique<TextureBridge>(registrar->texture_registrar());

  // Message-only window: the platform-thread drain target for reader/watcher
  // events (flutter::MethodChannel is not thread-safe).
  WNDCLASSEXW wc = {};
  wc.cbSize = sizeof(wc);
  wc.lpfnWndProc = &FlutterCefPlugin::MsgWndProc;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = kMessageWindowClass;
  RegisterClassExW(&wc);
  message_window_ =
      CreateWindowExW(0, kMessageWindowClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE,
                      nullptr, wc.hInstance, nullptr);
  if (message_window_) {
    SetWindowLongPtrW(message_window_, GWLP_USERDATA,
                      reinterpret_cast<LONG_PTR>(this));
  } else {
    Log("FATAL: message window creation failed — host events cannot be "
        "delivered");
  }
}

FlutterCefPlugin::~FlutterCefPlugin() {
  channel_->SetMethodCallHandler(nullptr);
  // Graceful path for every live host (the Job Object guarantees no orphan even
  // on a hard kill). Snapshot keys — TeardownHost mutates the maps.
  std::vector<std::string> keys;
  for (const auto& kv : hosts_) keys.push_back(kv.first);
  for (const auto& k : keys) TeardownHost(k, /*send_shutdown=*/true);
  // Reapers are bounded (<=3s wait, then kill); joining them here guarantees no
  // thread outlives `this`.
  for (auto& r : reapers_) {
    if (r.thread.joinable()) r.thread.join();
  }
  if (message_window_) {
    SetWindowLongPtrW(message_window_, GWLP_USERDATA, 0);
    DestroyWindow(message_window_);
    message_window_ = nullptr;
  }
}

// static
LRESULT CALLBACK FlutterCefPlugin::MsgWndProc(HWND hwnd, UINT msg,
                                              WPARAM wparam, LPARAM lparam) {
  if (msg == kDrainMessage) {
    auto* self = reinterpret_cast<FlutterCefPlugin*>(
        GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (self) self->DrainEvents();
    return 0;
  }
  if (msg == WM_TIMER) {
    auto* self = reinterpret_cast<FlutterCefPlugin*>(
        GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (self) self->OnWatchdogTimer(static_cast<UINT_PTR>(wparam));
    return 0;
  }
  return DefWindowProcW(hwnd, msg, wparam, lparam);
}

void FlutterCefPlugin::PostEvent(HostEvent event) {
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    queue_.push_back(std::move(event));
  }
  if (message_window_) PostMessageW(message_window_, kDrainMessage, 0, 0);
}

void FlutterCefPlugin::DrainEvents() {
  std::deque<HostEvent> events;
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    events.swap(queue_);
  }
  for (auto& e : events) {
    switch (e.kind) {
      case HostEvent::Kind::kFrame:
        HandleHostFrame(e.host_key, e.generation, e.browser_id, e.opcode,
                        e.payload);
        break;
      case HostEvent::Kind::kDisconnect:
        HandleHostGone(e.host_key, e.generation, /*exit_code_known=*/false, 0);
        break;
      case HostEvent::Kind::kExited:
        HandleHostGone(e.host_key, e.generation, /*exit_code_known=*/true,
                       e.exit_code);
        break;
    }
  }
}

void FlutterCefPlugin::EmitEvent(const std::string& method,
                                 const std::string& session_id,
                                 flutter::EncodableMap args) {
  args[Ev("sessionId")] = flutter::EncodableValue(session_id);
  channel_->InvokeMethod(
      method, std::make_unique<flutter::EncodableValue>(std::move(args)));
}

// ---- channel dispatch ----

void FlutterCefPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* args_ptr = std::get_if<flutter::EncodableMap>(call.arguments());
  const flutter::EncodableMap args =
      args_ptr ? *args_ptr : flutter::EncodableMap();
  const std::string& method = call.method_name();

  if (method == "create") {
    HandleCreate(args, result);
    return;
  }
  if (method == "resize") {
    HandleResize(args, result);
    return;
  }
  if (method == "dispose") {
    DisposeSession(GetString(args, "sessionId"));
    result->Success();
    return;
  }

  Session* s = FindSession(args);

  if (method == "navigate" || method == "loadTrusted") {
    const std::string url = GetString(args, "url");
    if (s && !url.empty()) {
      std::vector<uint8_t> p;
      AppendUtf8(p, url);
      SendOrQueue(s, method == "navigate" ? kOpNavigate : kOpLoadTrusted,
                  std::move(p));
    }
    result->Success();
    return;
  }
  if (method == "reload" || method == "stop" || method == "goBack" ||
      method == "goForward") {
    if (s) {
      uint8_t op = kOpReload;
      if (method == "stop") op = kOpStop;
      if (method == "goBack") op = kOpBack;
      if (method == "goForward") op = kOpForward;
      SendOrQueue(s, op, {});
    }
    result->Success();
    return;
  }
  if (method == "executeJavaScript") {
    const std::string code = GetString(args, "code");
    if (s && !code.empty()) {
      std::vector<uint8_t> p;
      AppendUtf8(p, code);
      SendOrQueue(s, kOpExecuteJs, std::move(p));
    }
    result->Success();
    return;
  }
  if (method == "pointer") {
    // {u8 type}{u8 button}{u8 clickCount}{u8 pad}{u32 modifiers}
    // {f64 x}{f64 y}{f64 dx}{f64 dy} = 40 bytes (main.mm:2560-2570).
    if (s) {
      std::vector<uint8_t> p;
      p.reserve(40);
      p.push_back(static_cast<uint8_t>(GetInt(args, "type", 0)));
      p.push_back(static_cast<uint8_t>(GetInt(args, "button", 0)));
      p.push_back(static_cast<uint8_t>(GetInt(args, "clickCount", 1)));
      p.push_back(0);
      AppendU32(p, static_cast<uint32_t>(GetInt(args, "modifiers", 0)));
      AppendF64(p, GetDouble(args, "x"));
      AppendF64(p, GetDouble(args, "y"));
      AppendF64(p, GetDouble(args, "dx"));
      AppendF64(p, GetDouble(args, "dy"));
      SendOrQueue(s, kOpPointer, std::move(p));
    }
    result->Success();
    return;
  }
  if (method == "key") {
    // {u8 type}{u8 pad×3}{u32 modifiers}{u32 wkc}{u32 nkc}{u32 char} = 20 bytes.
    if (s) {
      std::vector<uint8_t> p;
      p.reserve(20);
      p.push_back(static_cast<uint8_t>(GetInt(args, "type", 0)));
      p.push_back(0);
      p.push_back(0);
      p.push_back(0);
      AppendU32(p, static_cast<uint32_t>(GetInt(args, "modifiers", 0)));
      AppendU32(p, static_cast<uint32_t>(GetInt(args, "windowsKeyCode", 0)));
      AppendU32(p, static_cast<uint32_t>(GetInt(args, "nativeKeyCode", 0)));
      AppendU32(p, static_cast<uint32_t>(GetInt(args, "character", 0)));
      SendOrQueue(s, kOpKey, std::move(p));
    }
    result->Success();
    return;
  }
  if (method == "setVisible") {
    if (s) {
      const bool visible = GetBool(args, "visible", true);
      SendOrQueue(s, kOpSetVisible, {visible ? uint8_t{1} : uint8_t{0}});
      // C1 watchdog: a hidden CEF browser produces no frames by design, so
      // suspend the first-present watchdog while hidden and re-arm it on show
      // if still blank (macOS noteVisibility, CefProfileHost.swift:706-729).
      s->visible = visible;
      if (!visible) {
        CancelWatchdog(s);
      } else if (!s->painted && !s->watchdog_active) {
        ArmWatchdog(s);
      }
    }
    result->Success();
    return;
  }
  if (method == "setZoomLevel") {
    if (s) {
      std::vector<uint8_t> p;
      AppendF64(p, GetDouble(args, "level", 0.0));
      SendOrQueue(s, kOpSetZoom, std::move(p));
    }
    result->Success();
    return;
  }
  if (method == "editCommand") {
    if (s) {
      SendOrQueue(s, kOpEditCommand,
                  {static_cast<uint8_t>(GetInt(args, "command", 0))});
    }
    result->Success();
    return;
  }
  if (method == "find") {
    const std::string text = GetString(args, "text");
    if (s && !text.empty()) {
      std::vector<uint8_t> p;
      p.push_back(GetBool(args, "forward", true) ? 1 : 0);
      p.push_back(GetBool(args, "matchCase", false) ? 1 : 0);
      p.push_back(GetBool(args, "findNext", false) ? 1 : 0);
      AppendUtf8(p, text);
      SendOrQueue(s, kOpFind, std::move(p));
    }
    result->Success();
    return;
  }
  if (method == "stopFind") {
    if (s) {
      SendOrQueue(
          s, kOpStopFind,
          {GetBool(args, "clearSelection", true) ? uint8_t{1} : uint8_t{0}});
    }
    result->Success();
    return;
  }
  if (method == "respondJsDialog") {
    if (s) {
      std::vector<uint8_t> p;
      AppendU32(p, static_cast<uint32_t>(GetInt(args, "id", 0)));
      p.push_back(GetBool(args, "ok", true) ? 1 : 0);
      AppendUtf8(p, GetString(args, "text"));
      SendOrQueue(s, kOpJsDialogResp, std::move(p));
    }
    result->Success();
    return;
  }
  if (method == "evalReturning") {
    const std::string code = GetString(args, "code");
    if (s && !code.empty()) {
      std::vector<uint8_t> p;
      AppendU32(p, static_cast<uint32_t>(GetInt(args, "id", 0)));
      AppendUtf8(p, code);
      SendOrQueue(s, kOpEvalReturning, std::move(p));
    }
    result->Success();
    return;
  }
  if (method == "addJavaScriptChannel") {
    const std::string name = GetString(args, "name");
    if (s && !name.empty()) {
      std::vector<uint8_t> p;
      AppendUtf8(p, name);
      SendOrQueue(s, kOpAddChannel, std::move(p));
    }
    result->Success();
    return;
  }
  // ---- Cookies (shared per-profile jar; verbs match main.mm byte-for-byte).
  // The four verbs operate on the process-wide CefCookieManager inside the
  // host, so on a shared persistent profile every session sees one jar (macOS
  // parity). getCookies (Dart) rides the visitCookies verb, correlated back by
  // request id via the 'cookies' event (kOpCookies).
  if (method == "setCookie") {
    if (s) {
      // {utf8 url\0name\0value\0domain\0path\0secure\0httpOnly\0sameSite}
      // (main.mm kOpSetCookie). Hosts older than the attribute fields read
      // only the first five.
      const std::string payload = GetString(args, "url") + '\0' +
                                  GetString(args, "name") + '\0' +
                                  GetString(args, "value") + '\0' +
                                  GetString(args, "domain") + '\0' +
                                  GetString(args, "path", "/") + '\0' +
                                  (GetBool(args, "secure", false) ? "1" : "0") +
                                  '\0' +
                                  (GetBool(args, "httpOnly", false) ? "1"
                                                                    : "0") +
                                  '\0' +
                                  GetString(args, "sameSite", "unspecified");
      std::vector<uint8_t> p(payload.begin(), payload.end());
      SendOrQueue(s, kOpSetCookie, std::move(p));
    }
    result->Success();
    return;
  }
  if (method == "clearCookies") {
    if (s) SendOrQueue(s, kOpClearCookies, {});
    result->Success();
    return;
  }
  if (method == "visitCookies") {
    if (s) {
      // {u32 id}{utf8 url} — url empty = all (main.mm kOpVisitCookies:154).
      std::vector<uint8_t> p;
      AppendU32(p, static_cast<uint32_t>(GetInt(args, "id", 0)));
      AppendUtf8(p, GetString(args, "url"));
      SendOrQueue(s, kOpVisitCookies, std::move(p));
    }
    result->Success();
    return;
  }
  if (method == "deleteCookie") {
    if (s) {
      // {utf8 url\0name} (main.mm kOpDeleteCookie:155).
      const std::string payload =
          GetString(args, "url") + '\0' + GetString(args, "name");
      std::vector<uint8_t> p(payload.begin(), payload.end());
      SendOrQueue(s, kOpDeleteCookie, std::move(p));
    }
    result->Success();
    return;
  }
  if (method == "showDevTools") {
    if (s) SendOrQueue(s, kOpShowDevTools, {});
    result->Success();
    return;
  }
  if (method == "imeSetComposition" || method == "imeCommitText") {
    if (s) {
      std::vector<uint8_t> p;
      AppendUtf8(p, GetString(args, "text"));
      SendOrQueue(s,
                  method == "imeSetComposition" ? kOpImeSetComp : kOpImeCommit,
                  std::move(p));
    }
    result->Success();
    return;
  }
  if (method == "imeCancelComposition") {
    if (s) SendOrQueue(s, kOpImeCancel, {});
    result->Success();
    return;
  }
  if (method == "enableAgentControl") {
    EnableAgentControl(args, result);
    return;
  }
  if (method == "disableAgentControl") {
    DisableAgentControl(args, result);
    return;
  }
  if (method == "getFrameSurface") {
    if (s) {
      result->Success(flutter::EncodableValue(flutter::EncodableMap{
          {Ev("surfaceId"),
           flutter::EncodableValue(static_cast<int64_t>(s->current_handle))},
          {Ev("width"),
           flutter::EncodableValue(static_cast<int64_t>(s->expected_pw))},
          {Ev("height"),
           flutter::EncodableValue(static_cast<int64_t>(s->expected_ph))},
      }));
    } else {
      result->Success();
    }
    return;
  }

  // SLICE RULE: every not-yet-implemented verb replies success/null with an
  // OutputDebugString warning. NEVER an error, NEVER NotImplemented.
  WarnStub(method);
  result->Success();
}

// ---- create / resize / dispose ----

void FlutterCefPlugin::HandleCreate(
    const flutter::EncodableMap& args,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result) {
  const std::string session_id = GetString(args, "sessionId");
  if (session_id.empty()) {
    result->Error("bad_args", "missing sessionId");
    return;
  }
  const int64_t width = (std::max)(int64_t{1}, GetInt(args, "width", 800));
  const int64_t height = (std::max)(int64_t{1}, GetInt(args, "height", 600));
  double dpr = GetDouble(args, "dpr", 1.0);
  if (!(dpr > 0.0) || dpr > 8.0) dpr = 1.0;  // main.mm:2364-2376 guard
  const std::string url = GetString(args, "url", "about:blank");
  const std::string allowed_schemes = GetString(args, "allowedSchemes");
  const bool named_profile = HasNamedProfile(args);
  const std::string profile = GetString(args, "profile");
  // Agent control (P9): CDP-over-pipe launch. Off by default; when set, the host
  // is spawned with the two inherited CDP pipes (the S3 recipe). Independent of
  // enableCdp (TCP) — the pipe path never opens a listening port.
  const bool agent_control = GetBool(args, "agentControl", false);

  // Re-creating the same id is idempotent (Swift:293-295) — route teardown
  // through its host first.
  DisposeSession(session_id);

  const std::wstring host_exe = ResolveCefHostPath();
  if (host_exe.empty()) {
    result->Error("no_cef_host",
                  "cef_host.exe not found (set FLUTTER_CEF_HOST)");
    return;
  }

  // Resolve the profile dir + host key. A named profile -> a shared persistent
  // dir + a host keyed by name (reused by every session naming it); ephemeral
  // -> a throwaway dir + a host keyed uniquely per session.
  std::wstring profile_dir;
  bool ephemeral = true;
  std::string key;
  if (named_profile) {
    profile_dir = MakePersistentProfileDir(profile);
    if (profile_dir.empty()) {
      result->Error("spawn_failed", "failed to create persistent profile dir");
      return;
    }
    ephemeral = false;
    key = profile;
  } else {
    profile_dir = MakeEphemeralProfileDir();
    ephemeral = true;
    key = "~ephemeral~" + session_id;
  }

  Host* host = ResolveOrSpawnHost(key, profile_dir, ephemeral, host_exe,
                                  allowed_schemes, agent_control);
  if (!host) {
    result->Error("spawn_failed", "failed to spawn cef_host");
    return;
  }

  // SECURITY (P9 single-tile invariant): the CDP relay is a BROWSER-LEVEL
  // passthrough (the per-tile CEF-2b Target filter is deferred — PROTOCOL.md
  // §8.4). So an active agent-control grant must own a host with exactly ONE
  // tile; otherwise the agent driving this host could Target.getTargets/attach
  // the new sibling tile. Refuse a second tile joining a host whose grant is
  // live. (The complementary guard is in EnableAgentControl: no grant on a
  // multi-tile host.) Co-locate an agent-controlled view on its OWN profile.
  if (host->agent_control && !host->browsers.empty() && host->cdp) {
    bool grant_active;
    {
      std::lock_guard<std::mutex> lk(host->cdp->relay_mutex);
      grant_active = host->cdp->relay != nullptr;
    }
    if (grant_active) {
      result->Error(
          "agent_control_active",
          "cannot add a tile to a profile whose agent-control grant is active "
          "(per-tile CDP scoping is not yet implemented on Windows — give the "
          "agent-controlled view its own profile)");
      return;
    }
  }

  const int64_t texture_id = texture_bridge_->RegisterSessionTexture();
  if (texture_id < 0) {
    // Roll back a host we just spawned solely for this session (no other
    // browsers yet) so a texture failure doesn't strand a live process.
    if (host->browsers.empty()) TeardownHost(key, /*send_shutdown=*/true);
    result->Error("texture", "texture registration failed");
    return;
  }

  const uint32_t browser_id = host->next_browser_id++;

  auto session = std::make_unique<Session>();
  session->id = session_id;
  session->host_key = key;
  session->browser_id = browser_id;
  session->texture_id = texture_id;
  session->width = static_cast<int>(width);
  session->height = static_cast<int>(height);
  session->dpr = dpr;
  session->expected_pw = static_cast<uint32_t>(
      (std::max)(1.0, std::round(static_cast<double>(width) * dpr)));
  session->expected_ph = static_cast<uint32_t>(
      (std::max)(1.0, std::round(static_cast<double>(height) * dpr)));
  session->watchdog_id = next_timer_id_++;

  // kOpCreateBrowser: {u32 w}{u32 h}{f64 dpr}{utf8 url}; frame browserId = the
  // NEW wire id. Send directly on a ready host (2nd+ tile on a shared host),
  // else queue on the host for flush at kOpReady.
  std::vector<uint8_t> create;
  AppendU32(create, static_cast<uint32_t>(width));
  AppendU32(create, static_cast<uint32_t>(height));
  AppendF64(create, dpr);
  AppendUtf8(create, url);
  if (host->ready) {
    host->pipe->SendFrame(browser_id, kOpCreateBrowser, create.data(),
                          static_cast<uint32_t>(create.size()));
  } else {
    host->pending_frames.push_back(
        PendingFrame{browser_id, kOpCreateBrowser, std::move(create)});
  }

  host->browsers[browser_id] = session_id;
  Session* raw = session.get();
  sessions_[session_id] = std::move(session);
  // C1 first-present watchdog: start the first-paint clock now.
  ArmWatchdog(raw);
  result->Success(flutter::EncodableValue(flutter::EncodableMap{
      {Ev("textureId"), flutter::EncodableValue(texture_id)},
      {Ev("width"), flutter::EncodableValue(width)},
      {Ev("height"), flutter::EncodableValue(height)},
      {Ev("cdpPort"), flutter::EncodableValue(0)},
  }));
}

void FlutterCefPlugin::HandleResize(
    const flutter::EncodableMap& args,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result) {
  Session* s = FindSession(args);
  if (!s) {
    result->Success();
    return;
  }
  const int64_t width = GetInt(args, "width", 800);
  const int64_t height = GetInt(args, "height", 600);
  if (width < 1 || width > 16384 || height < 1 || height > 16384) {
    result->Success(flutter::EncodableValue(flutter::EncodableMap{
        {Ev("textureId"), flutter::EncodableValue(s->texture_id)},
    }));
    return;
  }
  double dpr = GetDouble(args, "dpr", 0.0);
  if (!(dpr > 0.0) || dpr > 8.0) dpr = s->dpr;

  s->width = static_cast<int>(width);
  s->height = static_cast<int>(height);
  s->dpr = dpr;
  s->expected_pw = static_cast<uint32_t>(
      (std::max)(1.0, std::round(static_cast<double>(width) * dpr)));
  s->expected_ph = static_cast<uint32_t>(
      (std::max)(1.0, std::round(static_cast<double>(height) * dpr)));

  std::vector<uint8_t> p;
  AppendU32(p, static_cast<uint32_t>(width));
  AppendU32(p, static_cast<uint32_t>(height));
  AppendF64(p, dpr);
  SendOrQueue(s, kOpResize, std::move(p));

  result->Success(flutter::EncodableValue(flutter::EncodableMap{
      {Ev("textureId"), flutter::EncodableValue(s->texture_id)},
  }));
}

FlutterCefPlugin::Session* FlutterCefPlugin::FindSession(
    const flutter::EncodableMap& args) {
  auto it = sessions_.find(GetString(args, "sessionId"));
  return it == sessions_.end() ? nullptr : it->second.get();
}

FlutterCefPlugin::Host* FlutterCefPlugin::HostForSession(
    const Session* session) {
  if (!session) return nullptr;
  auto it = hosts_.find(session->host_key);
  return it == hosts_.end() ? nullptr : it->second.get();
}

FlutterCefPlugin::Host* FlutterCefPlugin::ResolveOrSpawnHost(
    const std::string& key, const std::wstring& profile_dir, bool ephemeral,
    const std::wstring& host_exe, const std::string& allowed_schemes,
    bool agent_control) {
  // Reuse a live host for this key (a shared persistent profile's 2nd+ tile).
  // agent_control (like allowed_schemes) is a process arg fixed at the host's
  // spawn — a reuse ignores it (macOS parity, CefProfileHost.swift:456-471).
  auto existing = hosts_.find(key);
  if (existing != hosts_.end() && !existing->second->closing) {
    return existing->second.get();
  }

  // Pipe FIRST (so the child's CreateFileW connects first try), then spawn.
  auto pipe = std::make_unique<IpcPipe>();
  if (!pipe->Create(IpcPipe::NextPipeName())) {
    if (ephemeral) DeleteDirRecursive(profile_dir);
    return nullptr;
  }
  auto process = std::make_unique<HostProcess>();
  HANDLE cdp_read = nullptr, cdp_write = nullptr;
  if (!process->Spawn(host_exe, pipe->pipe_name(), profile_dir, ephemeral,
                      allowed_schemes, agent_control,
                      agent_control ? &cdp_read : nullptr,
                      agent_control ? &cdp_write : nullptr)) {
    if (ephemeral) DeleteDirRecursive(profile_dir);  // no host will own it
    return nullptr;
  }

  auto host = std::make_unique<Host>();
  host->key = key;
  host->generation = next_generation_++;
  host->ephemeral = ephemeral;
  host->profile_dir = profile_dir;
  host->pipe = std::move(pipe);
  host->process = std::move(process);
  host->agent_control = agent_control;
  // Agent control: own the parent-side CDP pipe ends and start the always-on
  // reader that fans NUL-framed CDP messages to the (later-created) relay.
  if (agent_control) {
    host->cdp = std::make_shared<CdpTransport>();
    host->cdp->read = cdp_read;
    host->cdp->write = cdp_write;
    host->cdp_reader = std::thread(&FlutterCefPlugin::CdpReadLoop, host->cdp);
  }

  const std::string host_key = key;
  const uint64_t gen = host->generation;
  // Reader thread: frames + EOF, posted to the platform thread. host_key + gen
  // are captured by value so a stale OLD-host event posted during the reaper
  // grace of a same-profile respawn is dropped on drain (C1).
  host->pipe->StartReader(
      [this, host_key, gen](uint32_t browser_id, uint8_t opcode,
                            std::vector<uint8_t> payload) {
        HostEvent e;
        e.kind = HostEvent::Kind::kFrame;
        e.host_key = host_key;
        e.generation = gen;
        e.browser_id = browser_id;
        e.opcode = opcode;
        e.payload = std::move(payload);
        PostEvent(std::move(e));
      },
      [this, host_key, gen]() {
        HostEvent e;
        e.kind = HostEvent::Kind::kDisconnect;
        e.host_key = host_key;
        e.generation = gen;
        PostEvent(std::move(e));
      });

  // Process-exit watcher: catches a host that dies BEFORE ever connecting the
  // pipe (bad exe, startup crash, exit 2 on a locked profile). Waits on its own
  // dup'd handle so reaper handle-closes can't race it.
  HANDLE process_dup = host->process->DuplicateProcessHandle();
  if (process_dup) {
    host->exit_watcher = std::thread([this, host_key, gen, process_dup]() {
      WaitForSingleObject(process_dup, INFINITE);
      DWORD code = 0;
      GetExitCodeProcess(process_dup, &code);
      CloseHandle(process_dup);
      HostEvent e;
      e.kind = HostEvent::Kind::kExited;
      e.host_key = host_key;
      e.generation = gen;
      e.exit_code = code;
      PostEvent(std::move(e));
    });
  }

  Host* raw = host.get();
  hosts_[key] = std::move(host);
  return raw;
}

void FlutterCefPlugin::DisposeSession(const std::string& session_id) {
  auto it = sessions_.find(session_id);
  if (it == sessions_.end()) return;
  Session* s = it->second.get();
  CancelWatchdog(s);
  const uint32_t browser_id = s->browser_id;
  const std::string host_key = s->host_key;
  if (s->texture_id >= 0) {
    texture_bridge_->Unregister(s->texture_id);
    s->texture_id = -1;
  }

  Host* host = HostForSession(s);
  sessions_.erase(it);

  if (!host) return;
  // Drop this browser's routing entry + any still-queued pre-ready frames.
  host->browsers.erase(browser_id);
  if (!host->pending_frames.empty()) {
    host->pending_frames.erase(
        std::remove_if(host->pending_frames.begin(), host->pending_frames.end(),
                       [browser_id](const PendingFrame& f) {
                         return f.browser_id == browser_id;
                       }),
        host->pending_frames.end());
  }
  // Close just this browser if the host is live + already ready (the create was
  // flushed). A not-yet-ready host never created the browser, so nothing to
  // close on the wire.
  if (!host->closing && host->ready && host->pipe && host->pipe->connected()) {
    host->pipe->SendFrame(browser_id, kOpDisposeBrowser, nullptr, 0);
  }
  // Last session gone -> tear the whole host down; otherwise keep it serving
  // the siblings (distinct per-session vs whole-host teardown).
  if (host->browsers.empty()) {
    TeardownHost(host_key, /*send_shutdown=*/true);
  }
}

void FlutterCefPlugin::TeardownHost(const std::string& host_key,
                                    bool send_shutdown) {
  auto it = hosts_.find(host_key);
  if (it == hosts_.end()) return;
  Host* h = it->second.get();
  h->closing = true;

  // Defensive: release any session still attached (the FailHost path clears
  // them first, but a direct teardown must not leak textures/timers).
  for (const auto& kv : h->browsers) {
    auto sit = sessions_.find(kv.second);
    if (sit == sessions_.end()) continue;
    Session* s = sit->second.get();
    CancelWatchdog(s);
    if (s->texture_id >= 0) {
      texture_bridge_->Unregister(s->texture_id);
      s->texture_id = -1;
    }
    sessions_.erase(sit);
  }
  h->browsers.clear();

  if (send_shutdown && h->pipe && h->pipe->connected()) {
    h->pipe->SendFrame(0, kOpShutdown, nullptr, 0);
  }

  // Prune reapers that already finished so the vector can't grow unbounded.
  for (auto rit = reapers_.begin(); rit != reapers_.end();) {
    if (rit->done->load()) {
      if (rit->thread.joinable()) rit->thread.join();
      rit = reapers_.erase(rit);
    } else {
      ++rit;
    }
  }
  // Bounded reaper: give the host time to exit cleanly, then kill. Owns the
  // pipe (reader join / deliberate leak), the process handles (job close =
  // kernel-guaranteed kill) and the exit watcher. Deletes an EPHEMERAL profile
  // dir once the host is confirmed dead — NEVER a persistent one.
  auto done = std::make_shared<std::atomic<bool>>(false);
  const bool ephemeral = h->ephemeral;
  std::wstring profile_dir = ephemeral ? h->profile_dir : std::wstring();
  reapers_.push_back(Reaper{
      std::thread([pipe = std::move(h->pipe), process = std::move(h->process),
                   watcher = std::move(h->exit_watcher),
                   cdp = std::move(h->cdp),
                   cdp_reader = std::move(h->cdp_reader),
                   profile_dir = std::move(profile_dir), done]() mutable {
        // Agent control: stop the relay FIRST (closes its WS sockets, so no more
        // client IO or sendToPipe) before we kill the host.
        if (cdp) {
          std::shared_ptr<CdpRelay> relay;
          {
            std::lock_guard<std::mutex> lk(cdp->relay_mutex);
            relay = std::move(cdp->relay);
          }
          if (relay) relay->Stop();
        }
        if (process) {
          if (process->WaitForExit(3000) == HostProcess::kStillRunning) {
            process->Terminate();
            process->WaitForExit(1000);
          }
        }
        if (pipe && !pipe->Close()) {
          pipe.release();  // wedged reader: leak by contract
        }
        if (watcher.joinable()) watcher.join();
        // CDP reader: the host is dead now, so the child's CDP write end closed
        // -> the reader's ReadFile hits EOF and exits. CancelIoEx unblocks it
        // defensively; then join and close the parent-side handles (only after
        // the join, so the reader never touches a closed handle).
        if (cdp && cdp->read) CancelIoEx(cdp->read, nullptr);
        if (cdp_reader.joinable()) cdp_reader.join();
        if (cdp) {
          // Close under write_mutex: send_to_pipe (the relay's client->pipe
          // writer) takes the same mutex and checks cdp->write, so serializing
          // the close+null against it prevents a WriteFile on a freed handle
          // even if a relay bridge thread outlived relay->Stop() above.
          std::lock_guard<std::mutex> lk(cdp->write_mutex);
          if (cdp->read) CloseHandle(cdp->read);
          if (cdp->write) CloseHandle(cdp->write);
          cdp->read = cdp->write = nullptr;
        }
        if (!profile_dir.empty()) DeleteDirRecursive(profile_dir);
        done->store(true);
      }),
      done});
  hosts_.erase(it);
}

void FlutterCefPlugin::FailHost(const std::string& host_key,
                                const std::string& reason) {
  auto it = hosts_.find(host_key);
  if (it == hosts_.end()) return;
  Host* h = it->second.get();
  // Snapshot sessionIds (we mutate sessions_ as we release each one).
  std::vector<std::string> gone;
  for (const auto& kv : h->browsers) gone.push_back(kv.second);
  for (const auto& sid : gone) {
    EmitEvent("processGone", sid,
              {{Ev("reason"), flutter::EncodableValue(reason)}});
    auto sit = sessions_.find(sid);
    if (sit == sessions_.end()) continue;
    Session* s = sit->second.get();
    CancelWatchdog(s);
    if (s->texture_id >= 0) {
      texture_bridge_->Unregister(s->texture_id);
      s->texture_id = -1;
    }
    sessions_.erase(sit);
  }
  h->browsers.clear();
  TeardownHost(host_key, /*send_shutdown=*/false);
}

void FlutterCefPlugin::SendOrQueue(Session* session, uint8_t opcode,
                                   std::vector<uint8_t> payload) {
  Host* host = HostForSession(session);
  if (!host) return;
  if (!host->ready) {
    host->pending_frames.push_back(
        PendingFrame{session->browser_id, opcode, std::move(payload)});
    return;
  }
  host->pipe->SendFrame(session->browser_id, opcode, payload.data(),
                        static_cast<uint32_t>(payload.size()));
}

// ---- agent control (P9) ----

// static
void FlutterCefPlugin::CdpReadLoop(std::shared_ptr<CdpTransport> transport) {
  HANDLE read = transport->read;
  if (!read) return;
  std::string acc;
  std::vector<char> buf(64 * 1024);
  for (;;) {
    DWORD got = 0;
    if (!ReadFile(read, buf.data(), static_cast<DWORD>(buf.size()), &got,
                  nullptr) ||
        got == 0) {
      break;  // EOF / error / CancelIoEx: host gone or teardown
    }
    acc.append(buf.data(), got);
    // Split the NUL-delimited JSON stream into complete messages (a message can
    // span reads; one read can carry several / straddle a boundary — mirror
    // macOS readCdpLoop).
    size_t nul;
    while ((nul = acc.find('\0')) != std::string::npos) {
      std::string msg = acc.substr(0, nul);
      acc.erase(0, nul + 1);
      std::shared_ptr<CdpRelay> relay;
      {
        std::lock_guard<std::mutex> lk(transport->relay_mutex);
        relay = transport->relay;  // snapshot; deliver OUTSIDE the lock
      }
      if (relay) relay->DeliverToClient(msg);
    }
    // Bound the accumulator (mirror the IPC reader cap): a malformed never-NUL
    // stream must not grow unbounded. The peer is our own cef_host (Chromium
    // always NUL-frames), so this is defensive.
    if (acc.size() > (64u << 20)) break;
  }
}

void FlutterCefPlugin::EnableAgentControl(
    const flutter::EncodableMap& args,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result) {
  Session* s = FindSession(args);
  Host* h = HostForSession(s);
  if (!h || !h->agent_control || !h->cdp) {
    // macOS throws a PlatformException when the tile isn't agent-control mode.
    result->Error("no_agent_control",
                  "enableAgentControl requires a session created with "
                  "agentControl: true");
    return;
  }
  // SECURITY (P9 single-tile invariant, see HandleCreate): the browser-level
  // relay would expose every sibling tile on this host to the agent. Until the
  // per-tile Target filter lands, refuse a grant while the host serves >1 tile.
  if (h->browsers.size() > 1) {
    result->Error(
        "agent_control_shared",
        "enableAgentControl needs a single-tile host: this profile has other "
        "tiles that a browser-level grant would expose. Give the "
        "agent-controlled view its own profile.");
    return;
  }

  std::shared_ptr<CdpTransport> cdp = h->cdp;
  std::shared_ptr<CdpRelay> relay;
  {
    std::lock_guard<std::mutex> lk(cdp->relay_mutex);
    relay = cdp->relay;  // idempotent fast-path: return the live relay
  }
  if (!relay) {
    // sendToPipe: NUL-frame the client's CDP command onto the host's command
    // pipe. A WEAK transport ref avoids a relay<->transport cycle, and a dead
    // transport (post-teardown) just drops the write.
    std::weak_ptr<CdpTransport> weak = cdp;
    auto send_to_pipe = [weak](const std::string& json) {
      auto t = weak.lock();
      if (!t) return;
      std::lock_guard<std::mutex> lk(t->write_mutex);
      if (!t->write) return;
      std::string framed = json;
      framed.push_back('\0');
      DWORD wrote = 0;
      WriteFile(t->write, framed.data(), static_cast<DWORD>(framed.size()),
                &wrote, nullptr);
    };
    auto fresh = std::make_shared<CdpRelay>(send_to_pipe);
    if (!fresh->Start()) {
      result->Error("relay_failed", "failed to start the CDP relay");
      return;
    }
    std::lock_guard<std::mutex> lk(cdp->relay_mutex);
    if (cdp->relay) {
      // A concurrent enable raced us: keep the existing relay, drop ours.
      fresh->Stop();
      relay = cdp->relay;
    } else {
      cdp->relay = fresh;
      relay = fresh;
    }
  }

  // Match the Swift return shape EXACTLY (CefProfileHost.endpoint):
  //   ws://127.0.0.1:<port>/devtools/browser?token=<token>
  const int port = relay->port();
  const std::string token = relay->token();
  std::ostringstream ws;
  ws << "ws://127.0.0.1:" << port << "/devtools/browser?token=" << token;
  result->Success(flutter::EncodableValue(flutter::EncodableMap{
      {Ev("wsUrl"), flutter::EncodableValue(ws.str())},
      {Ev("token"), flutter::EncodableValue(token)},
      {Ev("port"), flutter::EncodableValue(port)},
  }));
}

void FlutterCefPlugin::DisableAgentControl(
    const flutter::EncodableMap& args,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result) {
  Session* s = FindSession(args);
  Host* h = HostForSession(s);
  if (h && h->cdp) {
    std::shared_ptr<CdpRelay> relay;
    {
      std::lock_guard<std::mutex> lk(h->cdp->relay_mutex);
      relay = std::move(h->cdp->relay);
    }
    if (relay) relay->Stop();  // outside the lock (Stop closes sockets)
  }
  result->Success();  // idempotent — no-op if that tile has no relay
}

// ---- inbound host events (platform thread) ----

void FlutterCefPlugin::HandleHostGone(const std::string& host_key,
                                      uint64_t generation, bool exit_code_known,
                                      unsigned long exit_code) {
  auto it = hosts_.find(host_key);
  if (it == hosts_.end()) return;
  Host* h = it->second.get();
  // C1: a death event from a PRIOR host (posted during the reaper grace of a
  // same-profile respawn) must not kill the freshly re-created host.
  if (h->generation != generation) return;
  if (h->closing) return;  // expected death (teardown in flight)

  unsigned long code = exit_code;
  if (!exit_code_known) {
    // Pipe EOF: the process is (about to be) gone. Poll non-blocking (H18).
    code = h->process ? h->process->WaitForExit(0) : HostProcess::kStillRunning;
  }
  // Exit code 2 after kOpLog "profile-locked" = profile already open elsewhere
  // (main.mm:2786-2806, Swift:521).
  const std::string reason = (code == 2) ? "locked" : "crashed";
  Log("host gone for profile '" + host_key + "' (reason=" + reason + ")");
  FailHost(host_key, reason);
}

void FlutterCefPlugin::HandleHostFrame(const std::string& host_key,
                                       uint64_t generation, uint32_t browser_id,
                                       uint8_t opcode,
                                       const std::vector<uint8_t>& payload) {
  auto it = hosts_.find(host_key);
  if (it == hosts_.end()) return;
  Host* h = it->second.get();
  // C1: drop a frame from a PRIOR host of this same profile key.
  if (h->generation != generation) return;
  if (h->closing) return;

  // ---- process-level frames (browser_id 0) ----
  if (opcode == kOpReady) {
    // A legacy 1-byte kOpReady (no version byte) is a v0 host: treat as
    // host_version 0 and fall into the mismatch path (else create never
    // flushes). PROTOCOL.md §2: v>=3 carries {readyFlags, protocolVersion}.
    const uint8_t host_version = payload.size() >= 2 ? payload[1] : 0;
    if (host_version != kCefHostProtocolVersion) {
      // Nothing flushed yet, so nothing mis-parsed. No auto-respawn (it would
      // re-resolve the same binary and loop) — fail every session (Swift:
      // 528-533).
      std::ostringstream reason;
      reason << "protocolMismatch(host=v" << static_cast<int>(host_version)
             << ")";
      FailHost(host_key, reason.str());
      return;
    }
    h->ready = true;
    // Flush in order — each create's kOpCreateBrowser was queued before any of
    // its follow-up verbs.
    auto pending = std::move(h->pending_frames);
    h->pending_frames.clear();
    for (auto& f : pending) {
      h->pipe->SendFrame(f.browser_id, f.opcode, f.payload.data(),
                         static_cast<uint32_t>(f.payload.size()));
    }
    return;
  }
  if (opcode == kOpLog) {
    Log("[cef_host:" + host_key + "] " + PayloadString(payload));
    return;
  }

  // ---- per-browser frames: route by wire id to the owning Session ----
  auto bit = h->browsers.find(browser_id);
  if (bit == h->browsers.end()) return;  // unknown/disposed browser
  auto sit = sessions_.find(bit->second);
  if (sit == sessions_.end()) return;
  HandleSessionFrame(sit->second.get(), opcode, payload);
}

void FlutterCefPlugin::HandleSessionFrame(
    Session* s, uint8_t opcode, const std::vector<uint8_t>& payload) {
  const std::string& session_id = s->id;
  switch (opcode) {
    case kOpPresent:
      // C1: any present retires the first-present watchdog (macOS
      // firstPresentArrived), even a size-gated one.
      if (!s->painted) {
        s->painted = true;
        CancelWatchdog(s);
      }
      HandlePresent(s, payload);
      break;
    case kOpCursor:
      if (payload.size() >= 4) {
        EmitEvent("cursor", session_id,
                  {{Ev("cursor"), flutter::EncodableValue(static_cast<int64_t>(
                                      PayloadU32(payload, 0)))}});
      }
      break;
    case kOpLoadState:
      if (payload.size() >= 3) {
        EmitEvent("loadingState", session_id,
                  {{Ev("isLoading"), flutter::EncodableValue(payload[0] != 0)},
                   {Ev("canGoBack"), flutter::EncodableValue(payload[1] != 0)},
                   {Ev("canGoForward"),
                    flutter::EncodableValue(payload[2] != 0)}});
      }
      break;
    case kOpTitle:
      EmitEvent("title", session_id,
                {{Ev("title"), flutter::EncodableValue(PayloadString(payload))}});
      break;
    case kOpUrl:
      EmitEvent("url", session_id,
                {{Ev("url"), flutter::EncodableValue(PayloadString(payload))}});
      break;
    case kOpLoadErr: {
      if (payload.size() < 4) break;
      // {u32 code}{utf8 "url\ntext"} — split at the FIRST '\n' (Swift:374-378).
      const std::string combined = PayloadString(payload, 4);
      const size_t nl = combined.find('\n');
      const std::string err_url =
          nl == std::string::npos ? combined : combined.substr(0, nl);
      const std::string text =
          nl == std::string::npos ? std::string() : combined.substr(nl + 1);
      // Emit the code bit-identically to macOS (unsigned widened to Int).
      EmitEvent("loadError", session_id,
                {{Ev("code"), flutter::EncodableValue(static_cast<int64_t>(
                                  PayloadU32(payload, 0)))},
                 {Ev("url"), flutter::EncodableValue(err_url)},
                 {Ev("text"), flutter::EncodableValue(text)}});
      break;
    }
    case kOpConsole:
      if (payload.size() >= 4) {
        EmitEvent("consoleMessage", session_id,
                  {{Ev("level"), flutter::EncodableValue(static_cast<int64_t>(
                                     PayloadU32(payload, 0)))},
                   {Ev("message"),
                    flutter::EncodableValue(PayloadString(payload, 4))}});
      }
      break;
    case kOpPageStart:
      EmitEvent("pageStarted", session_id,
                {{Ev("url"), flutter::EncodableValue(PayloadString(payload))}});
      break;
    case kOpPageFinish:
      EmitEvent("pageFinished", session_id,
                {{Ev("url"), flutter::EncodableValue(PayloadString(payload))}});
      break;
    case kOpProgress:
      if (payload.size() >= 4) {
        EmitEvent("progress", session_id,
                  {{Ev("progress"), flutter::EncodableValue(static_cast<int64_t>(
                                        PayloadU32(payload, 0)))}});
      }
      break;
    case kOpNewWindow:
      EmitEvent("newWindow", session_id,
                {{Ev("url"), flutter::EncodableValue(PayloadString(payload))}});
      break;
    case kOpFindResult:
      if (payload.size() >= 9) {
        EmitEvent(
            "findResult", session_id,
            {{Ev("count"), flutter::EncodableValue(static_cast<int64_t>(
                               PayloadU32(payload, 0)))},
             {Ev("activeMatchOrdinal"),
              flutter::EncodableValue(static_cast<int64_t>(
                  PayloadU32(payload, 4)))},
             {Ev("isFinal"), flutter::EncodableValue(payload[8] != 0)}});
      }
      break;
    case kOpJsDialog: {
      if (payload.size() < 12) break;
      const uint32_t msg_len = PayloadU32(payload, 8);
      const size_t msg_end =
          (std::min)(static_cast<size_t>(12) + msg_len, payload.size());
      const std::string msg(
          reinterpret_cast<const char*>(payload.data()) + 12, msg_end - 12);
      const std::string def = msg_end < payload.size()
                                  ? PayloadString(payload, msg_end)
                                  : std::string();
      EmitEvent("jsDialog", session_id,
                {{Ev("id"), flutter::EncodableValue(static_cast<int64_t>(
                                PayloadU32(payload, 0)))},
                 {Ev("type"), flutter::EncodableValue(static_cast<int64_t>(
                                  PayloadU32(payload, 4)))},
                 {Ev("message"), flutter::EncodableValue(msg)},
                 {Ev("defaultText"), flutter::EncodableValue(def)}});
      break;
    }
    case kOpEvalResult:
      EmitEvent("evalResult", session_id,
                {{Ev("payload"),
                  flutter::EncodableValue(PayloadString(payload))}});
      break;
    case kOpChannelMsg:
      EmitEvent("channelMessage", session_id,
                {{Ev("payload"),
                  flutter::EncodableValue(PayloadString(payload))}});
      break;
    case kOpDownload:
      EmitEvent("download", session_id,
                {{Ev("suggestedName"),
                  flutter::EncodableValue(PayloadString(payload))}});
      break;
    case kOpImeBounds:
      if (payload.size() >= 16) {
        EmitEvent("imeCompositionBounds", session_id,
                  {{Ev("x"), flutter::EncodableValue(static_cast<int64_t>(
                                 PayloadU32(payload, 0)))},
                   {Ev("y"), flutter::EncodableValue(static_cast<int64_t>(
                                 PayloadU32(payload, 4)))},
                   {Ev("w"), flutter::EncodableValue(static_cast<int64_t>(
                                 PayloadU32(payload, 8)))},
                   {Ev("h"), flutter::EncodableValue(static_cast<int64_t>(
                                 PayloadU32(payload, 12)))}});
      }
      break;
    case kOpCookies:
      // {u32 id}{utf8 json-array} — correlated back to the Dart getCookies
      // Future by request id (main.mm kOpCookies:130; Swift onCookies:422-424).
      if (payload.size() >= 4) {
        EmitEvent("cookies", session_id,
                  {{Ev("id"), flutter::EncodableValue(static_cast<int64_t>(
                                  PayloadU32(payload, 0)))},
                   {Ev("json"),
                    flutter::EncodableValue(PayloadString(payload, 4))}});
      }
      break;
    case kOpCreated:
      // Browser is up (host-side create signal). Nothing to emit — Dart learns
      // liveness from loadingState/present.
      break;
    case kOpCreateFailed: {
      // H7: this browser's create failed; the host process is otherwise
      // healthy — drop just this ONE session (emit processGone, close its
      // browser, keep the host for its siblings; Swift:537-549). Copy the id
      // first: DisposeSession frees `s`, dangling session_id (an alias of
      // s->id).
      const std::string sid = session_id;
      EmitEvent("processGone", sid,
                {{Ev("reason"), flutter::EncodableValue("createFailed")}});
      DisposeSession(sid);
      break;
    }
    case kOpTargetId:
      Log("kOpTargetId (agent control is post-slice) — dropped");
      break;
    default:
      if (std::find(warned_opcodes_.begin(), warned_opcodes_.end(), opcode) ==
          warned_opcodes_.end()) {
        warned_opcodes_.push_back(opcode);
        char buf[64];
        _snprintf_s(buf, _TRUNCATE, "unknown inbound opcode 0x%02x — dropped",
                    opcode);
        Log(buf);
      }
      break;
  }
}

void FlutterCefPlugin::HandlePresent(Session* s,
                                     const std::vector<uint8_t>& payload) {
  // WINDOWS kOpPresent: {u64 bridgeHandle BE}{u32 srcW BE}{u32 srcH BE} = 16
  // bytes (PROTOCOL.md §2, LAW 10).
  if (payload.size() < 16) return;
  const uint64_t bridge_handle = ReadU64BE(payload.data());
  const uint32_t src_w = PayloadU32(payload, 8);
  const uint32_t src_h = PayloadU32(payload, 12);

  const auto within_one = [](uint32_t a, uint32_t b) {
    return (a > b ? a - b : b - a) <= 1;
  };
  if (!within_one(src_w, s->expected_pw) ||
      !within_one(src_h, s->expected_ph)) {
    if (++s->gate_misses <= 5 || s->gate_misses % 60 == 0) {
      char buf[128];
      _snprintf_s(buf, _TRUNCATE,
                  "present size-gated: got %ux%u expected %ux%u (miss #%u)",
                  src_w, src_h, s->expected_pw, s->expected_ph,
                  s->gate_misses);
      Log(buf);
    }
    return;
  }

  bool handle_changed = false;
  if (!texture_bridge_->Present(s->texture_id, bridge_handle, src_w, src_h,
                                &handle_changed)) {
    return;
  }
  if (handle_changed) {
    s->current_handle = bridge_handle;
    EmitEvent("onSurface", s->id,
              {{Ev("surfaceId"), flutter::EncodableValue(
                                     static_cast<int64_t>(bridge_handle))},
               {Ev("width"),
                flutter::EncodableValue(static_cast<int64_t>(src_w))},
               {Ev("height"),
                flutter::EncodableValue(static_cast<int64_t>(src_h))}});
  }
}

// ---- host exe / profile dir resolution ----

// static
std::wstring FlutterCefPlugin::ResolveCefHostPath() {
  wchar_t env[MAX_PATH] = {};
  const DWORD n =
      GetEnvironmentVariableW(L"FLUTTER_CEF_HOST", env, MAX_PATH);
  if (n > 0 && n < MAX_PATH) {
    if (GetFileAttributesW(env) != INVALID_FILE_ATTRIBUTES) {
      return std::wstring(env);
    }
  }
  wchar_t exe[MAX_PATH] = {};
  if (GetModuleFileNameW(nullptr, exe, MAX_PATH) == 0) return std::wstring();
  std::wstring path(exe);
  const size_t slash = path.find_last_of(L"\\/");
  if (slash == std::wstring::npos) return std::wstring();
  path = path.substr(0, slash + 1) + L"cef_host.exe";
  if (GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES) return path;
  return std::wstring();
}

// static
std::wstring FlutterCefPlugin::MakeEphemeralProfileDir() {
  static std::atomic<uint32_t> counter{0};
  wchar_t tmp[MAX_PATH] = {};
  const DWORD n = GetTempPathW(MAX_PATH, tmp);
  std::wstring base = (n > 0 && n < MAX_PATH) ? std::wstring(tmp) : L".\\";
  std::wostringstream dir;
  dir << base << L"flutter_cef_ephem_" << GetCurrentProcessId() << L"_"
      << GetTickCount64() << L"_" << counter.fetch_add(1);
  CreateDirectoryW(dir.str().c_str(), nullptr);
  return dir.str();
}

// static
std::wstring FlutterCefPlugin::MakePersistentProfileDir(
    const std::string& profile) {
  // %LOCALAPPDATA%\flutter_cef\profiles\<sanitize(name)>, created with a
  // current-user-SID protected DACL (the #3 pipe hardening pattern applied to
  // the profile tree). Mirrors macOS resolveProfileDir's stable 0700 dir under
  // Application Support (FlutterCefPlugin.swift:702-728).
  //
  // AT-REST NOTE (SPIKES.md S2 / §7): unlike macOS — where an ad-hoc (unsigned)
  // build has no real Keychain, so OSCrypt falls back to a MOCK key and named
  // profiles are downgraded to ephemeral — Windows OSCrypt uses DPAPI, which is
  // ALWAYS available and signing-INDEPENDENT. So a named profile just persists
  // directly on Windows; there is no ad-hoc downgrade rule and no mock-keychain
  // gate. DPAPI is same-user-readable (weaker than the macOS Keychain — another
  // process running as this user can decrypt the store), so the protected DACL
  // below is defense-in-depth, not the primary secret boundary. CAVEAT: every
  // flutter_cef app for this user shares this profiles root (the Windows
  // analogue of the macOS shared-keychain caveat) — a named profile is a shared
  // login surface across apps.
  wchar_t local[MAX_PATH] = {};
  const DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", local, MAX_PATH);
  std::wstring base;
  if (n > 0 && n < MAX_PATH) {
    base = std::wstring(local);
  } else {
    wchar_t tmp[MAX_PATH] = {};
    const DWORD tn = GetTempPathW(MAX_PATH, tmp);
    if (tn == 0 || tn >= MAX_PATH) return std::wstring();
    base = std::wstring(tmp);
  }
  const std::wstring flutter_root = base + L"\\flutter_cef";
  const std::wstring profiles_root = flutter_root + L"\\profiles";
  const std::wstring leaf = profiles_root + L"\\" + SanitizeProfileLeaf(profile);
  CreateDirProtected(flutter_root);
  CreateDirProtected(profiles_root);
  CreateDirProtected(leaf);
  if (GetFileAttributesW(leaf.c_str()) == INVALID_FILE_ATTRIBUTES) {
    return std::wstring();
  }
  return leaf;
}

// static
void FlutterCefPlugin::DeleteDirRecursive(const std::wstring& dir) {
  if (dir.empty()) return;
  const std::wstring pattern = dir + L"\\*";
  WIN32_FIND_DATAW fd;
  HANDLE h = FindFirstFileW(pattern.c_str(), &fd);
  if (h != INVALID_HANDLE_VALUE) {
    do {
      const std::wstring name = fd.cFileName;
      if (name == L"." || name == L"..") continue;
      const std::wstring full = dir + L"\\" + name;
      if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
        DeleteDirRecursive(full);
      } else {
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_READONLY)
          SetFileAttributesW(full.c_str(), FILE_ATTRIBUTE_NORMAL);
        DeleteFileW(full.c_str());
      }
    } while (FindNextFileW(h, &fd));
    FindClose(h);
  }
  RemoveDirectoryW(dir.c_str());
}

// static
void FlutterCefPlugin::SweepStaleEphemeralProfiles() {
  wchar_t tmp[MAX_PATH] = {};
  const DWORD n = GetTempPathW(MAX_PATH, tmp);
  if (n == 0 || n >= MAX_PATH) return;
  const std::wstring base(tmp);
  const std::wstring prefix = L"flutter_cef_ephem_";
  const std::wstring pattern = base + prefix + L"*";
  WIN32_FIND_DATAW fd;
  HANDLE h = FindFirstFileW(pattern.c_str(), &fd);
  if (h == INVALID_HANDLE_VALUE) return;
  do {
    if (!(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) continue;
    const std::wstring name = fd.cFileName;
    if (name.rfind(prefix, 0) != 0) continue;
    const std::wstring rest = name.substr(prefix.size());
    const size_t us = rest.find(L'_');
    const std::wstring pid_str =
        us == std::wstring::npos ? rest : rest.substr(0, us);
    const DWORD pid =
        static_cast<DWORD>(wcstoul(pid_str.c_str(), nullptr, 10));
    bool owner_alive = false;
    if (pid != 0) {
      HANDLE p = OpenProcess(SYNCHRONIZE, FALSE, pid);
      if (p) {
        owner_alive = WaitForSingleObject(p, 0) == WAIT_TIMEOUT;
        CloseHandle(p);
      }
    }
    if (!owner_alive) DeleteDirRecursive(base + name);
  } while (FindNextFileW(h, &fd));
  FindClose(h);
}

// ---- C1 first-present watchdog (platform thread) ----

void FlutterCefPlugin::ArmWatchdog(Session* session) {
  if (!session || !message_window_ || session->painted ||
      session->watchdog_active)
    return;
  if (session->watchdog_id == 0) session->watchdog_id = next_timer_id_++;
  session->watchdog_phase = 0;
  session->watchdog_active = true;
  // Periodic WM_TIMER delivered to MsgWndProc on this (platform) thread; fires
  // every grace until a present arrives or teardown.
  SetTimer(message_window_, session->watchdog_id, WatchdogGraceMs(), nullptr);
}

void FlutterCefPlugin::CancelWatchdog(Session* session) {
  if (!session || !session->watchdog_active) return;
  if (message_window_) KillTimer(message_window_, session->watchdog_id);
  session->watchdog_active = false;
}

void FlutterCefPlugin::OnWatchdogTimer(UINT_PTR timer_id) {
  Session* s = nullptr;
  for (auto& kv : sessions_) {
    if (kv.second->watchdog_active && kv.second->watchdog_id == timer_id) {
      s = kv.second.get();
      break;
    }
  }
  if (!s) {
    if (message_window_) KillTimer(message_window_, timer_id);  // orphan
    return;
  }
  if (s->painted || !s->visible) {
    CancelWatchdog(s);
    return;
  }
  if (s->watchdog_phase == 0) {
    // First grace elapsed with no present — cheap re-kick, then wait one more
    // grace before declaring a stall (macOS checkFirstPresent opInvalidate).
    SendOrQueue(s, kOpInvalidate, {});
    s->watchdog_phase = 1;
    return;
  }
  // Still blank after the re-kick grace: surface paintStalled (a REPEATING
  // signal; macOS re-arms the same way, CefProfileHost.swift:756-764). Event
  // shape = {sessionId} only.
  EmitEvent("paintStalled", s->id, {});
  SendOrQueue(s, kOpInvalidate, {});
}

}  // namespace flutter_cef

// ---- C API (called by generated_plugin_registrant.cc) ----
void FlutterCefPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  flutter_cef::FlutterCefPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
