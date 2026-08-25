// One live CEF webview, rendered off-screen by a cef_host.app subprocess into a
// shared IOSurface and surfaced to Flutter as a FlutterTexture.
//
// Mirrors the flutter_embed transport (macos/Runner/FlutterEmbed): the host
// allocates a global IOSurface + CVPixelBuffer, registers a FlutterTexture, and
// the owning CefProfileHost tells cef_host (via opCreateBrowser) to bind a
// browser to that IOSurface id. cef_host paints the page into the IOSurface and
// sends a "present" frame; we then poke the engine to re-sample the texture.
// Because the page renders off-screen, it keeps updating even when the tile isn't
// engaged — the whole point of the CEF path.
//
// This is just the per-VIEW half: a session owns its texture/IOSurface/geometry
// and the per-view verbs. The process/socket/reader layer (one subprocess per
// `profile:`, multiplexing N of these by browserId) lives on CefProfileHost.
// sendFrame delegates to host.send(browserId, ...); the host routes inbound
// frames back via handleFrame(). See native/cef_host/main.mm for the renderer and
// the IPC opcode definitions.

import Cocoa
import CoreVideo
import FlutterMacOS
import IOSurface

final class CefWebSession: NSObject, FlutterTexture {
  // IPC opcodes (must match native/cef_host/main.mm). Process-level + control
  // ops (ready/log/create/dispose/shutdown) live on CefProfileHost; this list is
  // the per-view ops a session names directly.
  private static let opPresent: UInt8 = 0x01
  private static let opLog: UInt8 = 0x04
  private static let opCursor: UInt8 = 0x03
  private static let opLoadState: UInt8 = 0x05
  private static let opTitle: UInt8 = 0x06
  private static let opUrl: UInt8 = 0x07
  private static let opLoadErr: UInt8 = 0x08
  private static let opConsole: UInt8 = 0x09
  private static let opPageStart: UInt8 = 0x0a
  private static let opPageFinish: UInt8 = 0x0b
  private static let opProgress: UInt8 = 0x0c
  private static let opNewWindow: UInt8 = 0x0d
  private static let opPointer: UInt8 = 0x10
  private static let opResize: UInt8 = 0x11
  private static let opInvalidate: UInt8 = 0x37  // us -> cef_host: force a repaint (re-kick a stuck resize)
  private static let opEditCommand: UInt8 = 0x38 // us -> cef_host: {u8 cmd} run a focused-frame edit command (copy/cut/paste/selectAll/undo/redo)
  private static let opKey: UInt8 = 0x12
  private static let opFindResult: UInt8 = 0x0e
  private static let opJsDialog: UInt8 = 0x0f
  private static let opEvalResult: UInt8 = 0x16
  private static let opChannelMsg: UInt8 = 0x17
  private static let opDownload: UInt8 = 0x18
  private static let opImeBounds: UInt8 = 0x19
  private static let opCookies: UInt8 = 0x1a
  // cef_host -> us: a page called getUserMedia and the site has no remembered
  // decision, so the host must show a permission prompt. {u32 id}{u32 mask}{utf8 origin}
  private static let opMediaRequest: UInt8 = 0x1e
  private static let opContextMenu: UInt8 = 0x40
  // cef_host -> us: {u8 videoActive}{u8 audioActive}{u8 setting 0=ask 1=allow}
  private static let opMediaState: UInt8 = 0x1f
  private static let opNavigate: UInt8 = 0x20
  private static let opReload: UInt8 = 0x21
  private static let opStop: UInt8 = 0x22
  private static let opBack: UInt8 = 0x23
  private static let opForward: UInt8 = 0x24
  private static let opExecuteJs: UInt8 = 0x25
  private static let opSetZoom: UInt8 = 0x26
  private static let opFind: UInt8 = 0x27
  private static let opStopFind: UInt8 = 0x28
  private static let opJsDialogResp: UInt8 = 0x29
  private static let opEvalReturning: UInt8 = 0x2a
  private static let opAddChannel: UInt8 = 0x2b
  private static let opSetCookie: UInt8 = 0x2c
  private static let opClearCookies: UInt8 = 0x2d
  private static let opVisitCookies: UInt8 = 0x2e
  private static let opDeleteCookie: UInt8 = 0x2f
  private static let opImeSetComp: UInt8 = 0x30
  private static let opImeCommit: UInt8 = 0x31
  private static let opImeCancel: UInt8 = 0x32
  private static let opShowDevTools: UInt8 = 0x33
  private static let opLoadTrusted: UInt8 = 0x34
  private static let opSetVisible: UInt8 = 0x35
  // us -> cef_host: answer a permission prompt {u32 id}{u8 allow}{u8 remember};
  // remembered per-origin only when a human chose, exactly like a browser.
  private static let opMediaResponse: UInt8 = 0x3c
  private static let opContextMenuCommand: UInt8 = 0x3e
  // us -> cef_host: {u8 0=ask 1=allow 2=block} rewrite this site's remembered
  // camera/mic decision (the URL-bar "site settings" path). No reload.
  private static let opSetMediaSetting: UInt8 = 0x3d
  private static let opOpenAuthWindow: UInt8 = 0x39
  private static let opSetAudioMuted: UInt8 = 0x3a    // {u8 muted} -> CefBrowserHost::SetAudioMuted
  private static let opSetPumpInterval: UInt8 = 0x3b  // {u16 BE ms} visible begin-frame cadence

  // Event callbacks (fired off the main thread). The registrar relays each to a
  // Dart channel message.
  var onCursor: ((Int) -> Void)?
  var onLoadState: ((Bool, Bool, Bool) -> Void)?  // loading, back, forward
  var onTitle: ((String) -> Void)?
  var onUrl: ((String) -> Void)?
  var onLoadError: ((Int, String, String) -> Void)?  // code, url, text
  var onConsole: ((Int, String) -> Void)?  // level, "source:line\tmsg"
  var onPageStarted: ((String) -> Void)?  // url
  var onPageFinished: ((String) -> Void)?  // url
  var onProgress: ((Int) -> Void)?  // 0-100
  var onNewWindow: ((String) -> Void)?  // popup/target=_blank url
  var onFindResult: ((Int, Int, Bool) -> Void)?  // count, activeOrdinal, isFinal
  var onJsDialog: ((Int, Int, String, String) -> Void)?  // id, type, msg, default
  var onEvalResult: ((String) -> Void)?  // "id:json"
  var onChannelMsg: ((String) -> Void)?  // "name:message"
  var onDownload: ((String) -> Void)?  // suggested name
  var onImeBounds: ((Int, Int, Int, Int) -> Void)?  // caret rect x,y,w,h (DIP)
  var onCookies: ((Int, String) -> Void)?  // request id, json array
  var onMediaRequest: ((Int, Int, String) -> Void)?  // id, permission mask, origin
  /// Right-click in the page. `json` carries Chromium's own menu model + hit
  /// context; the Flutter side draws it and answers with `chooseContextMenu`.
  var onContextMenu: ((Int, String) -> Void)?  // id, json
  var onMediaState: ((Bool, Bool, Int) -> Void)?  // videoActive, audioActive, setting
  // Fired when the backing IOSurface is (re)allocated — at create and on every
  // resize() (which reallocs). Args are the live global surface id and the
  // PHYSICAL (Retina) pixel dims. A consumer that mirrors the live frame
  // (e.g. an off-Flutter capturer) reads the surface by id and must re-read on
  // each fire, since resize() frees the old surface and allocs a new one.
  var onSurface: ((UInt32, Int, Int) -> Void)?  // surfaceId, physW, physH

  let sessionId: String
  private(set) var textureId: Int64 = 0

  // ── Present liveness counters ────────────────────────────────────────────
  // Pixel liveness had NO observable signal: a probe could prove the renderer's
  // JS loop was alive (eval round-trip) while the texture had been frozen for
  // minutes — the exact "JS alive, pixels dead" wedge. These count what actually
  // reaches the texture, so a consumer can tell a live page from a stale one
  // without guessing. Written on the reader thread, read from the main thread
  // via sessionStats(), so both go through presentStatsLock.
  private let presentStatsLock = NSLock()
  private var _presentCount: UInt64 = 0
  private var _lastPresentUptimeNs: UInt64 = 0

  /// Total presents this session has delivered, the wall-clock age of the most
  /// recent one (nil if none), and whether it ever painted.
  func presentStats() -> (count: UInt64, lastAgoMs: Int?, firstSeen: Bool) {
    presentStatsLock.lock()
    defer { presentStatsLock.unlock() }
    let ago: Int? = _lastPresentUptimeNs == 0
      ? nil
      : Int((DispatchTime.now().uptimeNanoseconds &- _lastPresentUptimeNs) / 1_000_000)
    return (_presentCount, ago, _presentCount > 0)
  }

  private func notePresent() {
    presentStatsLock.lock()
    _presentCount &+= 1
    _lastPresentUptimeNs = DispatchTime.now().uptimeNanoseconds
    presentStatsLock.unlock()
  }

  // Wire binding to the owning host: the host this session is multiplexed on and
  // the Swift-assigned browserId it routes by. Set once via attach() right after
  // CefProfileHost.createBrowser() allocates the id.
  private weak var host: CefProfileHost?
  private(set) var browserId: UInt32 = 0
  // JS-channel names registered for this session. Buffered here so a registration
  // that arrives BEFORE attach() assigns the wire browserId — which happens on a
  // shared host, where createBrowser is queued (pendingCreates) — is flushed with
  // a VALID browserId once attached (and re-sent on a re-home to a new host).
  // Without this the addChannel op would go out with browserId=0 and the host
  // couldn't bind it to this browser, so the window.<name> shim was never injected.
  private var channels: Set<String> = []
  // C1: set once when this browser delivers its first present frame. Owned/guarded by
  // CefProfileHost under its browsersLock (the reader flips it there) — a cheap per-frame
  // first-paint check that avoids a second lock on the hot paint path.
  var firstPresentSeen = false
  // Count of present frames delivered (guarded by CefProfileHost.browsersLock, like
  // firstPresentSeen). The create-pacer advances to the next browser only once this
  // reaches a small threshold — i.e. the browser is STABLY producing, not just one
  // first frame — so the next create's first-frame GPU allocation can't knock a barely-
  // established browser back out.
  var presentCount = 0
  // F-6 steady-state liveness watchdog (guarded by CefProfileHost.browsersLock, like
  // presentCount). `lastPresentNs` = the most recent present's uptime; `livenessNudgedAt`
  // = uptime of an outstanding discriminating opInvalidate (0 = none). The host's periodic
  // sweep reads these to catch a browser that painted ≥1 frame then WEDGED (the first-paint
  // watchdog retires at first paint, so post-establishment wedges had no detector).
  var lastPresentNs: UInt64 = 0
  var livenessNudgedAt: UInt64 = 0

  private weak var registry: FlutterTextureRegistry?
  private var width: Int
  private var height: Int
  // Device pixel ratio. Mutable: a canvas-zoom crispness re-render changes it (same logical
  // w/h, higher density) so the surface reallocates at logical*dpr px. Guarded by bufferLock
  // (read on the host reader thread via `scale`/createSnapshot).
  private var dpr: CGFloat

  // PRODUCER-ALLOCATES: the consumer no longer owns/allocates an IOSurface. `pixelBuffer` wraps
  // the PRODUCER-owned surface adopted from the latest present (handleFrame); the "which sid am I
  // backed by" is derived on the fly from CVPixelBufferGetIOSurface(pixelBuffer), so there is no
  // separate ioSurface/pendingBuffer/pendingSurfaceId state to drift out of sync. The no-flash
  // guarantee (keep serving the old buffer until the new one is painted) now comes from the
  // producer: it presents a sid only after it has painted that surface.
  private var pixelBuffer: CVPixelBuffer?
  // Resize flow-control: keep at most ONE resize in flight (sent, not yet promoted by its
  // present). cef_host coalesces rapid resizes and only paints the latest, so sending at the
  // full drag rate left every present tagged with an already-superseded surface id → the
  // texture promoted only at drag pauses (~1-2s). Instead send one resize, wait for its
  // present, then send the latest size requested since — so every paint promotes and the page
  // reflows at cef_host's actual rate. All guarded by bufferLock.
  private var resizeInFlight = false
  private var pendingRequestedW = 0
  private var pendingRequestedH = 0
  private var pendingRequestedDpr: CGFloat = 0  // 0 = no dpr change requested
  private var resizeSentAtNs: UInt64 = 0
  // Bumped on every sendResize. The resize watchdog captures it and bails if a newer resize
  // has since gone out — so during a smoothly-advancing drag the watchdog is a no-op, and it
  // only acts when a resize wedges (generation stops advancing because no present came).
  private var resizeGen: UInt64 = 0
  // F-4: mirrors the cef_host slot's hidden state (set by setVisible). While hidden the
  // begin-frame pump is gated off so no present can land — the resize watchdog must NOT
  // force-promote a never-painted (blank) buffer; it waits for the native un-hide repaint
  // (F-1) to drive a real present. Guarded by bufferLock like the rest of the buffer state.
  private var hidden = false
  private let bufferLock = NSLock()

  /// The live IOSurface id this session's buffer is backed by, or 0 before
  /// allocation. The host reads this to build the opCreateBrowser payload.
  var surfaceId: UInt32 {
    bufferLock.lock(); defer { bufferLock.unlock() }
    return pixelBuffer.flatMap { CVPixelBufferGetIOSurface($0) }
      .map { IOSurfaceGetID($0.takeUnretainedValue()) } ?? 0
  }
  // Geometry, exposed for the host's opCreateBrowser payload. width/height/dpr are
  // mutated by resize() on the main thread and read by the host on its reader
  // thread, so guard them with bufferLock.
  var w: Int { bufferLock.lock(); defer { bufferLock.unlock() }; return width }
  var h: Int { bufferLock.lock(); defer { bufferLock.unlock() }; return height }
  var scale: CGFloat { bufferLock.lock(); defer { bufferLock.unlock() }; return dpr }

  init(sessionId: String, width: Int, height: Int, dpr: CGFloat,
       registry: FlutterTextureRegistry) {
    self.sessionId = sessionId
    self.width = max(1, width)
    self.height = max(1, height)
    self.dpr = dpr
    self.registry = registry
    super.init()
    // PRODUCER-ALLOCATES: no surface is created here. pixelBuffer stays nil until the first
    // present adopts the producer-minted surface (copyPixelBuffer returns nil safely until then).
    self.textureId = registry.register(self)
  }

  /// Bind this session to its host + wire browserId (called by
  /// CefProfileHost.createBrowser). All sendFrame calls route through the host
  /// after this.
  func attach(host: CefProfileHost, browserId: UInt32) {
    self.host = host
    self.browserId = browserId
    // Flush channels registered before the wire id existed (and re-send them on a
    // re-home to a new host) now that sendFrame can route with a valid browserId.
    for name in channels { sendFrame(Self.opAddChannel, Array(name.utf8)) }
  }

  /// Freeze support: unbind from the (already-unregistered, about-to-close)
  /// browser while KEEPING the texture and the adopted pixelBuffer — its
  /// CVPixelBuffer retains the producer's IOSurface (a kernel object), so the
  /// tile keeps serving its last painted frame even after the whole cef_host
  /// process exits. Also resets the establishment counters: the thaw's
  /// recreated browser must look FRESH to the create pacer and first-present
  /// watchdog (both gate on the FIRST present, which a stale presentCount
  /// would never report). Call AFTER CefProfileHost.removeBrowser — once the
  /// browser is out of the host's map no reader thread touches these fields,
  /// so the pacer counters are safe to reset unlocked.
  func detachForFreeze() {
    bufferLock.lock()
    hidden = true
    resizeInFlight = false
    bufferLock.unlock()
    host = nil
    browserId = 0
    firstPresentSeen = false
    presentCount = 0
    lastPresentNs = 0
    livenessNudgedAt = 0
  }

  // MARK: FlutterTexture

  private var diagCopyCount = 0  // DIAG
  private var diagPresentCount = 0  // DIAG
  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    bufferLock.lock()
    defer { bufferLock.unlock() }
    diagCopyCount += 1  // DIAG — logged BEFORE the nil guard so a nil-buffer session shows
    if ProcessInfo.processInfo.environment["FLUTTER_CEF_DEBUG"] != nil
      && diagCopyCount % 120 == 0 {
      let liveSid = pixelBuffer.flatMap { CVPixelBufferGetIOSurface($0) }.map { IOSurfaceGetID($0.takeUnretainedValue()) } ?? 0
      NSLog("[cefdiag] copy bid=\(browserId) tex=\(textureId) hasPB=\(pixelBuffer != nil) liveSurf=\(liveSid) inFlight=\(resizeInFlight)")
    }
    guard let pb = pixelBuffer else { return nil }
    return Unmanaged.passRetained(pb)
  }

  // MARK: Public control

  func resize(width newW: Int, height newH: Int, dpr newDpr: CGFloat) {
    let w = max(1, newW), h = max(1, newH)
    let d = newDpr > 0 ? newDpr : dpr  // 0/invalid keeps the current density
    bufferLock.lock()
    // Always record the latest requested size+dpr; it's what maybeSendNextResize sends when
    // the in-flight resize promotes.
    pendingRequestedW = w
    pendingRequestedH = h
    pendingRequestedDpr = d
    var blocked = resizeInFlight
    // A dpr change (canvas-zoom crispness) re-rasters just like a size change.
    let same = (w == width && h == height && d == dpr)
    // SUPERSEDE A WEDGED RESIZE: if cef_host never produced a new-size paint (no present to
    // adopt), resizeInFlight would stay true forever and the `blocked` guard would drop every
    // later resize — the tile would stop tracking its size. Past a grace, clear the flag so this
    // newer size goes out. (Producer-allocates: there's no consumer pending buffer to drop; the
    // newest opResize + the producer's next paint converge the surface.)
    let wedged = ResizeSupersedePolicy.shouldClearWedged(
      inFlight: resizeInFlight, elapsedNs: nowNs() &- resizeSentAtNs, graceNs: 450_000_000)
    if wedged {
      resizeInFlight = false
      blocked = false
    }
    let curW = width, curH = height, curD = dpr
    bufferLock.unlock()
    if ProcessInfo.processInfo.environment["FLUTTER_CEF_DEBUG"] != nil {
      NSLog("[cefdiag-rsz] bid=\(browserId) req=\(w)x\(h)@\(d) cur=\(curW)x\(curH)@\(curD) "
        + "blocked=\(blocked) same=\(same) wedged=\(wedged)")
    }
    // While a resize is still painting, just record the latest size (above). Its present sends
    // the next one (maybeSendNextResize); if cef_host drops that paint, the resizeWatchdog
    // re-kicks it. This one-in-flight pacing keeps the page reflowing at cef_host's actual rate
    // instead of racing ahead (which tagged every present with an already-superseded surface id
    // → froze mid-drag). NOTE: no inline timeout here — racing ahead on a slow/heavy page is
    // exactly what desynced the presents and left the page stuck; the watchdog handles wedges.
    if blocked || same { return }
    sendResize(w, h, d)
  }

  /// PRODUCER-ALLOCATES: send the DESIRED geometry only — cef_host re-rasters, mints a new
  /// surface sized to its own paint, and presents the new id, which handleFrame(opPresent)
  /// adopts. No consumer-side IOSurface allocation, no pending-buffer handoff (the producer
  /// presents a sid only once it's painted, so adopt-on-change is always non-blank). We keep
  /// serving the current pixelBuffer (the old surface, held alive by its CVPixelBuffer) until
  /// the new present adopts — same no-flash guarantee, sourced from the producer.
  /// Main-thread only, so sendFrame stays serialized.
  private func sendResize(_ w: Int, _ h: Int, _ d: CGFloat) {
    bufferLock.lock()
    width = w
    height = h
    dpr = d
    resizeInFlight = true
    resizeSentAtNs = nowNs()
    resizeGen &+= 1
    let gen = resizeGen
    bufferLock.unlock()
    var payload = [UInt8]()
    appendU32(&payload, UInt32(w))
    appendU32(&payload, UInt32(h))
    appendF64(&payload, Double(d))  // cef_host updates slot->dpr → re-renders at new density
    sendFrame(Self.opResize, payload)
    // Re-kick if cef_host hasn't produced a new-size paint (and thus a new present to adopt).
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
      self?.resizeWatchdog(gen)
    }
  }

  /// Re-kick a wedged resize. Bails immediately if a newer resize has gone out (gen advanced)
  /// or this one already promoted (not in flight). Otherwise cef_host hasn't yet painted into
  /// the new (pending) surface — nudge it to repaint (opInvalidate), retrying every ~80ms.
  /// Under ALWAYS-LATEST promotion the resulting paint into the pending surface promotes it on
  /// sid match (handleFrame), so this re-kick is what rescues a STATIC page (one frame per
  /// resize) whose single post-resize frame was dropped. No force-promote needed: we never have
  /// to guess: a real paint into the new surface always promotes it. Main-thread only.
  private func resizeWatchdog(_ gen: UInt64) {
    bufferLock.lock()
    let isHidden = hidden
    var active = ResizeWatchdogPolicy.shouldKeepWaiting(
      inFlight: resizeInFlight, gen: gen, currentGen: resizeGen)
    // SELF-HEAL a wedged resize whose adopt never landed (producer freed the surface racing the
    // present, or a dropped frame with no follow-up paint). Without this, resizeInFlight would
    // stay true until the NEXT resize() call — blocking coalescing + re-kicking opInvalidate
    // forever. Clearing is safe under producer-allocates: always-latest adopts on the next
    // present regardless of the flag. (Previously this clear lived ONLY in resize(), so a tile
    // the user stopped interacting with could stay wedged-in-flight indefinitely.)
    if active, gen == resizeGen,
       ResizeSupersedePolicy.shouldClearWedged(
        inFlight: resizeInFlight, elapsedNs: nowNs() &- resizeSentAtNs, graceNs: 450_000_000) {
      resizeInFlight = false
      active = false
    }
    bufferLock.unlock()
    // If a paint already landed in the pending surface, handleFrame promoted it + cleared
    // resizeInFlight → `active` is false → stop. Otherwise re-kick (opInvalidate forces cef_host
    // to repaint the pending surface; the 16ms begin-frame pump also drives it), and the next
    // present promotes via sid match. The texture meanwhile keeps serving the last good surface
    // scaled to the tile (momentarily soft if the box grew) — never blank, never frozen-wrong.
    guard active else { return }
    // While hidden the pump is gated off, so opInvalidate can't paint — skip the nudge but keep
    // the watchdog alive; the native un-hide repaint (F-1) drives a real present that promotes.
    if !isHidden { sendFrame(Self.opInvalidate, []) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
      self?.resizeWatchdog(gen)
    }
  }

  /// Main-thread follow-up after a present promotes: if the page was resized again while the
  /// last resize painted, send the newest size now so the reflow keeps pace with the drag.
  private func maybeSendNextResize() {
    bufferLock.lock()
    let w = pendingRequestedW, h = pendingRequestedH
    let d = pendingRequestedDpr > 0 ? pendingRequestedDpr : dpr
    let need = !resizeInFlight && w > 0 && (w != width || h != height || d != dpr)
    bufferLock.unlock()
    if need { sendResize(w, h, d) }
  }

  private func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

  func navigate(_ url: String) {
    sendFrame(Self.opNavigate, Array(url.utf8))
  }

  /// Open a windowed Chrome-runtime browser at |url| for a WebAuthn / Touch ID
  /// ceremony the OSR tile cannot host. Shares this session's cookie jar.
  ///
  /// Defense-in-depth: this pops a cookie-bearing, user-navigable top-level window
  /// outside OSR containment, so only ever launch it at a real web origin. Reject
  /// anything that isn't http(s) (javascript:/data:/file:/about: ...) -- the tile's
  /// own `navigate` is scheme-gated in cef_host; keep this entry point in step.
  func openAuthWindow(_ url: String) {
    guard let scheme = URL(string: url)?.scheme?.lowercased(),
          scheme == "https" || scheme == "http" else {
      NSLog("[flutter_cef] openAuthWindow refused non-http(s) URL")
      return
    }
    sendFrame(Self.opOpenAuthWindow, Array(url.utf8))
  }

  /// A host content-injection load (loadHtmlString -> data:, loadFile -> file:):
  /// exempt from the navigation scheme allowlist, unlike `navigate`.
  func loadTrusted(_ url: String) {
    sendFrame(Self.opLoadTrusted, Array(url.utf8))
  }

  func reload() { sendFrame(Self.opReload) }
  func stopLoad() { sendFrame(Self.opStop) }
  func goBack() { sendFrame(Self.opBack) }
  func goForward() { sendFrame(Self.opForward) }
  func executeJavaScript(_ code: String) {
    sendFrame(Self.opExecuteJs, Array(code.utf8))
  }

  func setZoomLevel(_ level: Double) {
    var p = [UInt8]()
    appendF64(&p, level)
    sendFrame(Self.opSetZoom, p)
  }

  /// Run a browser edit command (0=copy 1=cut 2=paste 3=selectAll 4=undo
  /// 5=redo) on the focused frame in the cef_host subprocess.
  func editCommand(_ command: Int) {
    sendFrame(Self.opEditCommand, [UInt8(truncatingIfNeeded: command)])
  }

  /// Pause/resume frame production in the cef_host subprocess. `false` calls
  /// CefBrowserHost::WasHidden(true) so an off-screen tile stops rendering; the
  /// session and browser stay alive, so it's a cheap toggle, not a teardown.
  func setVisible(_ visible: Bool) {
    bufferLock.lock()
    hidden = !visible
    bufferLock.unlock()
    sendFrame(Self.opSetVisible, [visible ? 1 : 0])
  }

  /// Owner opt-in for camera/mic (getUserMedia) on this browser. Deny-default in
  /// cef_host; this flips the per-browser gate. Grants only device capture
  /// (camera/mic), never screen capture.
  /// Answer a pending camera/mic prompt. The host remembers the choice for the
  /// requesting origin, so the page is asked once — the browser contract.
  /// `remember` only when a human actually chose — a defensive auto-deny must
  /// not persist as a site-wide block.
  func respondMediaRequest(id: Int, allow: Bool, remember: Bool) {
    var p = [UInt8]()
    appendU32(&p, UInt32(truncatingIfNeeded: id))
    p.append(allow ? 1 : 0)
    p.append(remember ? 1 : 0)
    sendFrame(Self.opMediaResponse, p)
  }

  /// Answer a context menu. `commandId` 0 means dismissed without choosing —
  /// which must still be sent: CEF requires the menu callback be answered
  /// exactly once, and skipping it wedges the page's menu handling.
  func chooseContextMenu(id: Int, commandId: Int) {
    var p = [UInt8]()
    appendU32(&p, UInt32(truncatingIfNeeded: id))
    appendU32(&p, UInt32(truncatingIfNeeded: commandId))
    sendFrame(Self.opContextMenuCommand, p)
  }

  /// Rewrite this site's remembered camera/mic decision (0 = ask again, 1 =
  /// allow, 2 = block). No reload — it applies next time the page asks.
  func setMediaSetting(_ value: Int) {
    sendFrame(Self.opSetMediaSetting, [UInt8(clamping: value)])
  }


  /// Mute/unmute the page's audio. Besides silencing it, a hidden AND muted
  /// page regains Chromium's intensive wake-up throttling (audible pages are
  /// exempt), so muting on hide keeps a background tile's timers cheap.
  func setAudioMuted(_ muted: Bool) {
    sendFrame(Self.opSetAudioMuted, [muted ? 1 : 0])
  }

  /// Set the visible begin-frame pump interval (ms) — the OSR frame clock for
  /// this browser. 16 ≈ 60fps (default), 33 ≈ 30fps; cef_host clamps to
  /// [8, 250]. Hidden tiles produce no frames regardless.
  func setFrameInterval(_ ms: Int) {
    let clamped = UInt16(clamping: ms)
    sendFrame(Self.opSetPumpInterval, [UInt8(clamped >> 8), UInt8(clamped & 0xff)])
  }

  func find(_ text: String, forward: Bool, matchCase: Bool, findNext: Bool) {
    var p: [UInt8] = [forward ? 1 : 0, matchCase ? 1 : 0, findNext ? 1 : 0]
    p.append(contentsOf: Array(text.utf8))
    sendFrame(Self.opFind, p)
  }

  func stopFind(_ clearSelection: Bool) {
    sendFrame(Self.opStopFind, [clearSelection ? 1 : 0])
  }

  func respondJsDialog(id: Int, ok: Bool, text: String) {
    var p = [UInt8]()
    appendU32(&p, UInt32(truncatingIfNeeded: id))
    p.append(ok ? 1 : 0)
    p.append(contentsOf: Array(text.utf8))
    sendFrame(Self.opJsDialogResp, p)
  }

  func evalReturning(id: Int, code: String) {
    var p = [UInt8]()
    appendU32(&p, UInt32(truncatingIfNeeded: id))
    p.append(contentsOf: Array(code.utf8))
    sendFrame(Self.opEvalReturning, p)
  }

  func addChannel(_ name: String) {
    channels.insert(name)
    // Ship now only if we already have a wire id; otherwise attach() flushes it.
    if browserId != 0 { sendFrame(Self.opAddChannel, Array(name.utf8)) }
  }

  func setCookie(url: String, name: String, value: String, domain: String,
                 path: String, secure: Bool = false, httpOnly: Bool = false,
                 sameSite: String = "unspecified") {
    // Eight NUL-separated fields. Hosts older than the attribute fields read
    // only the first five and ignore the rest; newer hosts pad missing ones.
    let payload = [url, name, value, domain, path,
                   secure ? "1" : "0", httpOnly ? "1" : "0", sameSite]
      .joined(separator: "\u{0}")
    sendFrame(Self.opSetCookie, Array(payload.utf8))
  }

  func clearCookies() { sendFrame(Self.opClearCookies) }

  func visitCookies(id: Int, url: String) {
    var payload = [UInt8]()
    appendU32(&payload, UInt32(truncatingIfNeeded: id))
    payload.append(contentsOf: Array(url.utf8))
    sendFrame(Self.opVisitCookies, payload)
  }

  func deleteCookie(url: String, name: String) {
    sendFrame(Self.opDeleteCookie, Array((url + "\u{0}" + name).utf8))
  }

  /// Open DevTools. With a point (page DIP coords) it opens INSPECTING the
  /// element there — the right-click "Inspect" path.
  func showDevTools(inspectAt: (x: Int, y: Int)? = nil) {
    guard let at = inspectAt else {
      sendFrame(Self.opShowDevTools)
      return
    }
    var p = [UInt8]()
    appendU32(&p, UInt32(truncatingIfNeeded: max(0, at.x)))
    appendU32(&p, UInt32(truncatingIfNeeded: max(0, at.y)))
    sendFrame(Self.opShowDevTools, p)
  }

  func imeSetComposition(_ text: String) {
    sendFrame(Self.opImeSetComp, Array(text.utf8))
  }

  func imeCommitText(_ text: String) {
    sendFrame(Self.opImeCommit, Array(text.utf8))
  }

  func imeCancelComposition() { sendFrame(Self.opImeCancel) }

  // type: 0=move 1=down 2=up 3=wheel; button: 0=left 1=middle 2=right.
  func sendPointer(type: Int, button: Int, clickCount: Int, modifiers: UInt32,
                   x: Double, y: Double, dx: Double, dy: Double) {
    var p = [UInt8]()
    p.append(UInt8(truncatingIfNeeded: type))
    p.append(UInt8(truncatingIfNeeded: button))
    p.append(UInt8(truncatingIfNeeded: clickCount))
    p.append(0)
    appendU32(&p, modifiers)
    appendF64(&p, x); appendF64(&p, y); appendF64(&p, dx); appendF64(&p, dy)
    sendFrame(Self.opPointer, p)
  }

  // type: 0=rawkeydown 2=keyup 3=char.
  func sendKey(type: Int, modifiers: UInt32, windowsKeyCode: Int32,
               nativeKeyCode: Int32, character: UInt32) {
    var p = [UInt8]()
    p.append(UInt8(truncatingIfNeeded: type))
    p.append(0); p.append(0); p.append(0)
    appendU32(&p, modifiers)
    appendU32(&p, UInt32(bitPattern: windowsKeyCode))
    appendU32(&p, UInt32(bitPattern: nativeKeyCode))
    appendU32(&p, character)
    sendFrame(Self.opKey, p)
  }

  /// Release the texture + buffers. The process/socket teardown (and the
  /// opDisposeBrowser/opShutdown signalling + reader join) is the owning
  /// CefProfileHost's job — by the time this runs the host has already
  /// unregistered this browser, so there's no reader racing the free.
  func dispose() {
    // Zero textureId under bufferLock so a reader-thread opPresent can't read it
    // torn or schedule a frame for an id we're about to unregister (it re-reads
    // under the lock on main). unregisterTexture itself runs on the main thread.
    bufferLock.lock()
    let tid = textureId
    textureId = 0
    pixelBuffer = nil  // drops the consumer's ref on the producer-owned surface (CVPixelBuffer deinit)
    resizeInFlight = false
    pendingRequestedW = 0
    pendingRequestedH = 0
    bufferLock.unlock()
    if tid != 0 { registry?.unregisterTexture(tid) }
  }

  // MARK: Buffers

  /// PRODUCER-ALLOCATES: wrap a producer-owned IOSurface (looked up by the id cef_host sent in
  /// a present) in a CVPixelBuffer for Flutter. cef_host created the surface IOSurfaceIsGlobal,
  /// so IOSurfaceLookup resolves it cross-process. IOSurfaceLookup is CF_RETURNS_RETAINED, so
  /// Swift manages that +1 and releases it when `surf` leaves scope; the CVPixelBuffer takes its
  /// OWN retain on the surface for as long as Flutter may sample it — so the surface lives until
  /// this CVPixelBuffer is overwritten/niled (consumer ref) AND cef_host has released its ref.
  /// Returns nil if the id no longer resolves (producer freed it racing a close) — the caller
  /// keeps the current buffer and retries on the next present. Called under bufferLock.
  private func adoptSurfaceLocked(_ sid: UInt32) -> CVPixelBuffer? {
    guard let surf = IOSurfaceLookup(sid) else { return nil }
    var pbOut: Unmanaged<CVPixelBuffer>?
    let attrs: [CFString: Any] = [
      kCVPixelBufferMetalCompatibilityKey: true,
      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    ]
    let rc = CVPixelBufferCreateWithIOSurface(
      kCFAllocatorDefault, surf, attrs as CFDictionary, &pbOut)
    guard rc == kCVReturnSuccess, let pb = pbOut?.takeRetainedValue() else {
      NSLog("[cef] adoptSurface: CVPixelBufferCreateWithIOSurface failed rc=\(rc) sid=\(sid)")
      return nil
    }
    return pb
  }

  /// WebRTC frame export: notify any consumer that the live surface (re)allocated, so it
  /// can IOSurfaceLookup the new id and re-point its capture (R2). Call OUTSIDE bufferLock
  /// so the callback can read session accessors without self-deadlock. Reports PHYSICAL
  /// (Retina) pixel dims = logical * dpr.
  private func notifySurface(_ sid: UInt32, _ logicalW: Int, _ logicalH: Int) {
    guard sid != 0 else { return }
    // dpr is mutable (canvas-zoom crispness) and read off the reader thread here, so snapshot
    // it under bufferLock; then invoke onSurface UNLOCKED (the callback reads session accessors).
    bufferLock.lock(); let s = Double(dpr); bufferLock.unlock()
    onSurface?(sid, Int((Double(logicalW) * s).rounded()),
               Int((Double(logicalH) * s).rounded()))
  }

  /// Re-emit the current live surface to a just-attached onSurface (WebRTC) consumer. With
  /// producer-allocates the live surface is whatever backs the current pixelBuffer (nil until
  /// the first present adopts one), so read it from there.
  func emitCurrentSurface() {
    bufferLock.lock()
    let sid = pixelBuffer.flatMap { CVPixelBufferGetIOSurface($0) }
      .map { IOSurfaceGetID($0.takeUnretainedValue()) } ?? 0
    let w = width, h = height
    bufferLock.unlock()
    if sid != 0 { notifySurface(sid, w, h) }
  }

  /// Read (w, h, dpr) as ONE consistent tuple under a single bufferLock acquisition — the host
  /// builds opCreateBrowser from this. Producer-allocates: no surface id (cef_host mints its own).
  func createSnapshot() -> (w: Int, h: Int, dpr: CGFloat) {
    bufferLock.lock(); defer { bufferLock.unlock() }
    return (width, height, dpr)
  }

  // MARK: Inbound frames

  /// Handle one inbound frame routed to this browser by the host. `payload` has
  /// already had the [bodyLen][browserId][op] header stripped, so all offsets
  /// start at 0 (the old per-view switch read from offset 1, after the op byte).
  func handleFrame(_ op: UInt8, _ payload: [UInt8]) {
    switch op {
    case Self.opPresent:
      // Count FIRST: a present that arrives but fails to adopt is still proof
      // the producer is painting, which is what liveness asks about.
      notePresent()
      // Read textureId under bufferLock — dispose() writes it under the same
      // lock on the main thread, so this avoids a data race on the Int64.
      bufferLock.lock()
      // PRODUCER-ALLOCATES ADOPT: the present names the PRODUCER-OWNED surface id cef_host just
      // painted (+ its physical dims). The producer mints a new surface (new id) whenever it
      // re-rasters at a new size/dpr, so a present whose id differs from the one currently
      // backing our pixelBuffer means "adopt the new surface." We IOSurfaceLookup it (cross-
      // process, resolvable because cef_host created it IOSurfaceIsGlobal) and wrap it in a
      // CVPixelBuffer. src==dst by construction (cef_host sized the surface to its own paint),
      // so there is no crop/stretch/stale class anymore. We keep serving the current pixelBuffer
      // until the new one is wrapped (no flash), and the producer only ever presents a sid after
      // it has painted that surface (never blank). Newest id wins.
      var promotedSid: UInt32 = 0
      var promotedW = 0, promotedH = 0
      if payload.count >= 4 {
        let psid = (UInt32(payload[0]) << 24) | (UInt32(payload[1]) << 16)
          | (UInt32(payload[2]) << 8) | UInt32(payload[3])
        let srcW = payload.count >= 12 ? Int((UInt32(payload[4]) << 24) | (UInt32(payload[5]) << 16)
          | (UInt32(payload[6]) << 8) | UInt32(payload[7])) : 0
        let srcH = payload.count >= 12 ? Int((UInt32(payload[8]) << 24) | (UInt32(payload[9]) << 16)
          | (UInt32(payload[10]) << 8) | UInt32(payload[11])) : 0
        // Dedupe against the surface ACTUALLY backing the live pixelBuffer (not a cached var),
        // so a stable producer sid Lookups exactly ZERO times after the first adopt.
        let curSid = pixelBuffer.flatMap { CVPixelBufferGetIOSurface($0) }
          .map { IOSurfaceGetID($0.takeUnretainedValue()) } ?? 0
        if psid != 0, psid != curSid {
          if let pb = adoptSurfaceLocked(psid) {
            pixelBuffer = pb
            resizeInFlight = false  // a new-size paint landed and we adopted it
            promotedSid = psid
            promotedW = srcW > 0 ? srcW : Int((Double(width) * dpr).rounded())
            promotedH = srcH > 0 ? srcH : Int((Double(height) * dpr).rounded())
            if ProcessInfo.processInfo.environment["FLUTTER_CEF_DEBUG"] != nil {
              NSLog("[cefdiag-resize] bid=\(browserId) ADOPT psid=\(psid) src=\(srcW)x\(srcH) "
                + "logical=\(width)x\(height) dpr=\(dpr)")
            }
          }
          // adopt failed (Lookup nil — producer raced a free): keep current buffer, next present retries.
        }
      }
      let tid = textureId
      bufferLock.unlock()
      diagPresentCount += 1  // DIAG
      if ProcessInfo.processInfo.environment["FLUTTER_CEF_DEBUG"] != nil
        && diagPresentCount % 120 == 0 {
        NSLog("[cefdiag] present bid=\(browserId) tex=\(tid) count=\(diagPresentCount)")
      }
      // R2: a resized surface just went live — tell WebRTC consumers to re-point their
      // IOSurface capture at the new id (this is the "fires on each resize" half).
      if promotedSid != 0 { notifySurface(promotedSid, promotedW, promotedH) }
      if tid != 0 {
        DispatchQueue.main.async { [weak self] in
          // Re-read on main (serialized with dispose()): the texture may have
          // been unregistered between the reader capturing tid and here, so
          // don't poke a stale id into the registry.
          guard let self = self else { return }
          self.bufferLock.lock()
          let live = self.textureId
          self.bufferLock.unlock()
          if live != 0 { self.registry?.textureFrameAvailable(live) }
          // A resize may have promoted above — send the newest requested size now so the
          // reflow advances at cef_host's paint rate (on main, so sendFrame stays serialized).
          self.maybeSendNextResize()
        }
      }
    case Self.opLog:
      // Per-browser diagnostic from cef_host (paint/renderer/resize/etc.). Surface
      // it with this session's context (process-level logs go via the host).
      NSLog("[cef_host:\(sessionId)] \(String(bytes: payload, encoding: .utf8) ?? "")")
    case Self.opCursor:
      if payload.count >= 4 {
        let c = (Int(payload[0]) << 24) | (Int(payload[1]) << 16)
          | (Int(payload[2]) << 8) | Int(payload[3])
        onCursor?(c)
      }
    case Self.opLoadState:
      if payload.count >= 3 {
        onLoadState?(payload[0] != 0, payload[1] != 0, payload[2] != 0)
      }
    case Self.opTitle:
      onTitle?(String(bytes: payload, encoding: .utf8) ?? "")
    case Self.opUrl:
      onUrl?(String(bytes: payload, encoding: .utf8) ?? "")
    case Self.opLoadErr:
      if payload.count >= 4 {
        let code = readU32(payload, 0)
        let s = String(bytes: payload[4...], encoding: .utf8) ?? ""
        let parts = s.split(separator: "\n", maxSplits: 1,
                            omittingEmptySubsequences: false)
        onLoadError?(code, parts.count > 0 ? String(parts[0]) : "",
                     parts.count > 1 ? String(parts[1]) : "")
      }
    case Self.opConsole:
      if payload.count >= 4 {
        onConsole?(readU32(payload, 0),
                   String(bytes: payload[4...], encoding: .utf8) ?? "")
      }
    case Self.opPageStart:
      onPageStarted?(String(bytes: payload, encoding: .utf8) ?? "")
    case Self.opPageFinish:
      onPageFinished?(String(bytes: payload, encoding: .utf8) ?? "")
    case Self.opProgress:
      if payload.count >= 4 { onProgress?(readU32(payload, 0)) }
    case Self.opNewWindow:
      onNewWindow?(String(bytes: payload, encoding: .utf8) ?? "")
    case Self.opFindResult:
      if payload.count >= 9 {
        onFindResult?(readU32(payload, 0), readU32(payload, 4), payload[8] != 0)
      }
    case Self.opJsDialog:
      if payload.count >= 12 {
        let type = readU32(payload, 4)
        let msgLen = readU32(payload, 8)
        let msgEnd = min(12 + msgLen, payload.count)
        let msg = String(bytes: payload[12..<msgEnd], encoding: .utf8) ?? ""
        let def = msgEnd < payload.count
            ? (String(bytes: payload[msgEnd...], encoding: .utf8) ?? "")
            : ""
        onJsDialog?(readU32(payload, 0), type, msg, def)
      }
    case Self.opEvalResult:
      onEvalResult?(String(bytes: payload, encoding: .utf8) ?? "")
    case Self.opChannelMsg:
      onChannelMsg?(String(bytes: payload, encoding: .utf8) ?? "")
    case Self.opDownload:
      onDownload?(String(bytes: payload, encoding: .utf8) ?? "")
    case Self.opImeBounds:
      if payload.count >= 16 {
        onImeBounds?(readU32(payload, 0), readU32(payload, 4),
                     readU32(payload, 8), readU32(payload, 12))
      }
    case Self.opCookies:
      if payload.count >= 4 {
        onCookies?(readU32(payload, 0),
                   String(bytes: payload[4...], encoding: .utf8) ?? "[]")
      }
    case Self.opMediaRequest:
      if payload.count >= 8 {
        let origin = payload.count > 8
            ? (String(bytes: payload[8...], encoding: .utf8) ?? "")
            : ""
        onMediaRequest?(readU32(payload, 0), readU32(payload, 4), origin)
      }
    case Self.opContextMenu:
      if payload.count >= 4 {
        let json = payload.count > 4
            ? (String(bytes: payload[4...], encoding: .utf8) ?? "{}")
            : "{}"
        onContextMenu?(readU32(payload, 0), json)
      }
    case Self.opMediaState:
      if payload.count >= 3 {
        onMediaState?(payload[0] != 0, payload[1] != 0, Int(payload[2]))
      }
    default:
      break
    }
  }

  // MARK: Wire helpers

  /// Send a per-view frame: delegates to the owning host, which prepends the
  /// browserId and length and routes it over the shared pipe.
  private func sendFrame(_ op: UInt8, _ payload: [UInt8] = []) {
    host?.send(browserId, op, payload)
  }

  private func appendU32(_ a: inout [UInt8], _ v: UInt32) {
    a.append(UInt8((v >> 24) & 0xff))
    a.append(UInt8((v >> 16) & 0xff))
    a.append(UInt8((v >> 8) & 0xff))
    a.append(UInt8(v & 0xff))
  }

  private func appendF64(_ a: inout [UInt8], _ v: Double) {
    let bits = v.bitPattern
    for shift in stride(from: 56, through: 0, by: -8) {
      a.append(UInt8((bits >> UInt64(shift)) & 0xff))
    }
  }

  private func readU32(_ b: [UInt8], _ o: Int) -> Int {
    return (Int(b[o]) << 24) | (Int(b[o + 1]) << 16) | (Int(b[o + 2]) << 8)
      | Int(b[o + 3])
  }
}
