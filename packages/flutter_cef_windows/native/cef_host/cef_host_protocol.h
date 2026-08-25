// flutter_cef Windows — wire protocol constants + big-endian codecs.
//
// Shared by the cef_host process (native/cef_host/cef_host_win.cc) and the
// Flutter plugin (windows/ipc_pipe.cpp): plain C++/Win32, no CEF includes, so
// both builds can consume it.
//
// THE CONTRACT IS PROTOCOL.md (this directory) — transcribed from the macOS
// reference `packages/flutter_cef_macos/native/cef_host/main.mm:111-164`.
// Opcode numbers are copied VERBATIM from main.mm. Framing:
//   [u32 bodyLen BE][u32 browserId BE][u8 opcode][payload]
// bodyLen = 4 + 1 + payloadLen; guard 5 <= bodyLen <= 64 MiB; browserId 0 =
// process-level (kOpReady, process-level kOpLog, inbound kOpShutdown).
//
// ONE payload difference vs macOS (LAW 10): kOpPresent on Windows carries
//   {u64 bridgeHandle BE}{u32 srcW BE}{u32 srcH BE}   (16 bytes)
// instead of macOS's {u32 iosurfaceId}{u32 srcW}{u32 srcH} (12 bytes).
// bridgeHandle is the DXGI LEGACY shared handle (IDXGIResource::
// GetSharedHandle) of the host-minted D3D11_RESOURCE_MISC_SHARED bridge
// texture — the identity Flutter sees (LAW 3). srcW/srcH are the PHYSICAL
// pixel dims of the frame actually composited (the size-gate signal, LAW 4).

#ifndef FLUTTER_CEF_WINDOWS_NATIVE_CEF_HOST_CEF_HOST_PROTOCOL_H_
#define FLUTTER_CEF_WINDOWS_NATIVE_CEF_HOST_CEF_HOST_PROTOCOL_H_

#include <cstdint>
#include <cstring>

namespace flutter_cef {

// ---- Wire protocol version ----
// Announced in kOpReady's payload byte 1 (byte 0 is the ready-flags byte).
// Must stay equal to main.mm:108 kCefHostProtocolVersion and
// CefProfileHost.swift:42 — the wire is shared cross-platform.
constexpr uint8_t kCefHostProtocolVersion = 3;

// Framing guard (main.mm:2347): minimum body = 4 (browserId) + 1 (op).
constexpr uint32_t kMinBodyLen = 5;
constexpr uint32_t kMaxBodyLen = 64u << 20;  // 64 MiB

// ---- Opcodes: cef_host -> plugin (main.mm:111-133) ----
constexpr uint8_t kOpPresent = 0x01;    // WINDOWS: {u64 bridgeHandle}{u32 srcW}{u32 srcH}
constexpr uint8_t kOpReady = 0x02;      // {u8 readyFlags}{u8 protocolVersion} browserId 0
constexpr uint8_t kOpCursor = 0x03;     // {u32 cef_cursor_type_t}
constexpr uint8_t kOpLog = 0x04;        // {utf8}
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
constexpr uint8_t kOpTargetId = 0x1b;   // {utf8 targetId} this browser's CDP targetId
constexpr uint8_t kOpCreated = 0x1c;    // {} OnAfterCreated — browser is up
constexpr uint8_t kOpCreateFailed = 0x1d; // {} async CreateBrowser dispatch failed

// ---- Opcodes: plugin -> cef_host (main.mm:134-164) ----
constexpr uint8_t kOpPointer = 0x10;        // {u8 type}{u8 btn}{u8 clicks}{u8 pad}{u32 mods}{f64 x}{f64 y}{f64 dx}{f64 dy}
constexpr uint8_t kOpResize = 0x11;         // {u32 w}{u32 h}{f64 dpr} — producer-allocates: no sid
constexpr uint8_t kOpKey = 0x12;            // {u8 type}{pad*3}{u32 mods}{u32 wkc}{u32 nkc}{u32 char}
constexpr uint8_t kOpCreateBrowser = 0x13;  // {u32 w}{u32 h}{f64 dpr}{utf8 url}; frame browserId = NEW id
constexpr uint8_t kOpShutdown = 0x14;       // {} tear down the whole PROCESS; frame browserId 0
constexpr uint8_t kOpDisposeBrowser = 0x15; // {} close ONE browser; process survives
constexpr uint8_t kOpNavigate = 0x20;       // {utf8 url}
constexpr uint8_t kOpReload = 0x21;
constexpr uint8_t kOpStop = 0x22;
constexpr uint8_t kOpBack = 0x23;
constexpr uint8_t kOpForward = 0x24;
constexpr uint8_t kOpExecuteJs = 0x25;  // {utf8 code}
constexpr uint8_t kOpSetZoom = 0x26;    // {f64 level} (factor = 1.2^level)
constexpr uint8_t kOpFind = 0x27;       // {u8 fwd}{u8 matchCase}{u8 findNext}{utf8}
constexpr uint8_t kOpStopFind = 0x28;   // {u8 clearSelection}
constexpr uint8_t kOpJsDialogResp = 0x29;   // {u32 id}{u8 ok}{utf8 text}
constexpr uint8_t kOpEvalReturning = 0x2a;  // {u32 id}{utf8 code}
constexpr uint8_t kOpAddChannel = 0x2b;     // {utf8 name} register a JS channel
constexpr uint8_t kOpSetCookie = 0x2c;      // {utf8 url\0name\0value\0domain\0path[\0secure(0|1)\0httpOnly(0|1)\0sameSite(unspecified|none|lax|strict)]}
constexpr uint8_t kOpClearCookies = 0x2d;   // {} delete all cookies
constexpr uint8_t kOpVisitCookies = 0x2e;   // {u32 id}{utf8 url} enumerate (url empty = all)
constexpr uint8_t kOpDeleteCookie = 0x2f;   // {utf8 url\0name} delete one
constexpr uint8_t kOpImeSetComp = 0x30;     // {utf8 text} IME composition update
constexpr uint8_t kOpImeCommit = 0x31;      // {utf8 text} commit composed text
constexpr uint8_t kOpImeCancel = 0x32;      // {} cancel composition
constexpr uint8_t kOpShowDevTools = 0x33;   // {} open DevTools in a window
constexpr uint8_t kOpLoadTrusted = 0x34;    // {utf8 url} host content-load, exempt from allowlist
constexpr uint8_t kOpSetVisible = 0x35;     // {u8 visible} -> CefBrowserHost::WasHidden(!visible)
constexpr uint8_t kOpResolveTargetId = 0x36;// {} resolve CDP targetId -> kOpTargetId
constexpr uint8_t kOpInvalidate = 0x37;     // {} force a repaint (re-kick a stalled first frame)
constexpr uint8_t kOpEditCommand = 0x38;    // {u8 cmd} 0=copy 1=cut 2=paste 3=selectAll 4=undo 5=redo

// 0x1e is RESERVED (PLAN §4.3's kOpPresentV2 earmark) — do not assign.

// ---- Big-endian codecs (mirror main.mm ReadU32BE/WriteU32BE/ReadF64BE) ----

inline uint32_t ReadU32BE(const uint8_t* p) {
  return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) |
         (uint32_t(p[2]) << 8) | uint32_t(p[3]);
}

inline void WriteU32BE(uint8_t* p, uint32_t v) {
  p[0] = static_cast<uint8_t>((v >> 24) & 0xff);
  p[1] = static_cast<uint8_t>((v >> 16) & 0xff);
  p[2] = static_cast<uint8_t>((v >> 8) & 0xff);
  p[3] = static_cast<uint8_t>(v & 0xff);
}

inline uint64_t ReadU64BE(const uint8_t* p) {
  return (uint64_t(ReadU32BE(p)) << 32) | uint64_t(ReadU32BE(p + 4));
}

inline void WriteU64BE(uint8_t* p, uint64_t v) {
  WriteU32BE(p, static_cast<uint32_t>(v >> 32));
  WriteU32BE(p + 4, static_cast<uint32_t>(v & 0xffffffffu));
}

inline double ReadF64BE(const uint8_t* p) {
  uint64_t bits = ReadU64BE(p);
  double d;
  static_assert(sizeof(d) == sizeof(bits), "double must be 64-bit");
  std::memcpy(&d, &bits, sizeof(d));
  return d;
}

inline void WriteF64BE(uint8_t* p, double d) {
  uint64_t bits;
  std::memcpy(&bits, &d, sizeof(bits));
  WriteU64BE(p, bits);
}

}  // namespace flutter_cef

#endif  // FLUTTER_CEF_WINDOWS_NATIVE_CEF_HOST_CEF_HOST_PROTOCOL_H_
