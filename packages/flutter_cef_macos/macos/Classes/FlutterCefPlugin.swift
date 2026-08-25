import Cocoa
import FlutterMacOS

/// macOS plugin entry point. Channel `flutter_cef`. The host->native verbs (the
/// `case` labels in `handle(_:result:)`) and the native->Dart events (the
/// `emit(...)` calls in `create`) together form the cross-platform method-channel
/// protocol — see PORTING.md for the authoritative list. Each verb carries a
/// `sessionId`; `create` returns `{textureId, width, height, cdpPort}`. The Swift
/// side only relays: it spawns and talks to a per-PROFILE `cef_host` subprocess
/// (see `CefProfileHost`), which multiplexes N per-view `CefWebSession` browsers
/// over one IPC pipe. Views sharing a non-empty `profile` share one host -> one
/// cookie jar -> one login.
public class FlutterCefPlugin: NSObject, FlutterPlugin {
  private weak var textureRegistry: FlutterTextureRegistry?
  private var channel: FlutterMethodChannel?
  // Two-level registry: one host per profile, many sessions per host.
  private var profiles: [String: CefProfileHost] = [:]   // key: profile name OR "~ephemeral~"+sessionId
  private var sessions: [String: CefWebSession] = [:]     // sessionId -> session (verb routing)
  private var sessionHost: [String: CefProfileHost] = [:] // sessionId -> its host
  private var sessionKey: [String: String] = [:]          // sessionId -> profiles[] key, for teardown
  // C2: per-session create args, so when a shared host turns out to be ad-hoc and
  // refuses its named profile we can re-home EVERY session on it onto ephemeral hosts
  // (not just the last one whose closure was installed), preserving each session's
  // url + schemes + agent-control transport. Also the freeze/thaw recipe: thaw
  // respawns a host of the ORIGINAL kind (profile / enableCdp) and recreates the
  // browser at the original url unless the thaw call overrides it.
  private var sessionCreateArgs: [String: (url: String, allowedSchemes: String,
                                           agentControl: Bool, profile: String?,
                                           enableCdp: Bool)] = [:]
  // Sessions whose native browser was torn down by freezeSession while the
  // session + texture live on serving the last painted frame. Not in
  // sessionHost/sessionKey while frozen (their host may be gone entirely).
  private var frozenSessions: Set<String> = []
  // C2: named profiles a running ad-hoc host already refused — future creates for them
  // go straight to ephemeral instead of racing onto a doomed shared host.
  private var adhocBlockedProfiles: Set<String> = []

  /// Raise the soft open-file limit toward the hard cap (best-effort, once at plugin
  /// registration). Each cef_host costs several fds (IPC + CDP pipes + per-relay
  /// listener), so many agent-controlled tiles can approach a GUI app's default soft
  /// RLIMIT_NOFILE (often 256) and fail spawns with EMFILE.
  private static func raiseOpenFileLimit() {
    var rl = rlimit()
    guard getrlimit(RLIMIT_NOFILE, &rl) == 0 else { return }
    let want: rlim_t = 4096
    if rl.rlim_cur < want {
      rl.rlim_cur = min(want, rl.rlim_max)
      _ = setrlimit(RLIMIT_NOFILE, &rl)
    }
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    raiseOpenFileLimit()
    let instance = FlutterCefPlugin()
    instance.textureRegistry = registrar.textures
    let channel = FlutterMethodChannel(
      name: "flutter_cef", binaryMessenger: registrar.messenger)
    instance.channel = channel
    registrar.addMethodCallDelegate(instance, channel: channel)
    sweepStaleEphemeralProfiles()
    // On app quit, SIGTERM+reap every live cef_host so none is orphaned. Each
    // posix-spawned cef_host holds its named profile's Chromium SingletonLock; an
    // orphan keeps it held and the next launch collides ("already open elsewhere").
    // The macOS FlutterPlugin protocol has no detachFromEngine hook (that's iOS-
    // only), so we observe NSApplication.willTerminateNotification directly — fires
    // regardless of how the host app wires its delegate. The closure captures
    // `instance` strongly (intended: keep it alive to term so shutdownAllHosts can
    // run), and removes itself so it can't fire twice. Idempotent: shutdownAllHosts
    // tolerates an already-clean state, and CefProfileHost.shutdown() is itself
    // idempotent, so this is safe even after normal per-tile teardown.
    instance.terminateObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { [weak instance] _ in
      instance?.shutdownAllHosts()
    }
  }

  /// Token for the willTerminateNotification observer (Task D). Held so we keep the
  /// closure registered for the plugin's lifetime; removed once it has fired.
  private var terminateObserver: NSObjectProtocol?

  /// Shut down EVERY live cef_host (SIGTERM+SIGKILL escalation + reap, via the host's
  /// own shutdown()) so app termination leaves no orphaned subprocess holding a
  /// profile's Chromium SingletonLock. Main-thread confined like the other map
  /// accessors (H3); the willTerminate observer is queued on .main. Idempotent: clears
  /// the maps so a stray second call (or a later normal teardown) is a no-op, and
  /// drops the self-observer.
  private func shutdownAllHosts() {
    dispatchPrecondition(condition: .onQueue(.main))
    if let tok = terminateObserver {
      NotificationCenter.default.removeObserver(tok)
      terminateObserver = nil
    }
    // De-dup: several sessions can share one host (one named profile -> one host).
    var seen = Set<ObjectIdentifier>()
    for host in profiles.values where seen.insert(ObjectIdentifier(host)).inserted {
      host.shutdown()
    }
    profiles.removeAll()
    sessions.removeAll()
    sessionHost.removeAll()
    sessionKey.removeAll()
  }

  /// Reclaim ephemeral (throwaway) profile temp dirs orphaned by a previous crash/
  /// SIGKILL — they're normally removed on clean shutdown(), but a hard exit leaves
  /// `flutter_cef_ephem_*` (a throwaway cookie jar) behind. At plugin init no host is
  /// live yet, so sweeping every match is safe. Same-UID, 0700; this bounds disk
  /// growth and stale at-rest session data.
  private static func sweepStaleEphemeralProfiles() {
    let tmp = NSTemporaryDirectory()
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(atPath: tmp) else { return }
    for name in entries where name.hasPrefix("flutter_cef_ephem_") {
      try? fm.removeItem(atPath: tmp + name)
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "create": create(args, result)
    case "navigate": navigate(args, result)
    case "openAuthWindow": openAuthWindow(args, result)
    case "loadTrusted": loadTrusted(args, result)
    case "resize": resize(args, result)
    case "getFrameSurface": getFrameSurface(args, result)
    case "sessionStats":
      // Pixel liveness, for a consumer that needs to tell a live page from a
      // stale texture. A JS round-trip proves only that the renderer executes
      // script; presentCount/lastPresentAgoMs prove frames are still reaching
      // the texture, which is what "frozen" actually means to a user.
      guard let sid = args["sessionId"] as? String, let s = sessions[sid] else {
        result(nil); return
      }
      let st = s.presentStats()
      result([
        "presentCount": Int(clamping: st.count),
        "lastPresentAgoMs": st.lastAgoMs as Any,
        "firstPresentSeen": st.firstSeen,
        "frozen": frozenSessions.contains(sid),
      ])
    case "dispose": destroy(args, result)
    case "pointer": pointer(args, result)
    case "key": key(args, result)
    case "reload": withSession(args) { $0.reload() }; result(nil)
    case "stop": withSession(args) { $0.stopLoad() }; result(nil)
    case "goBack": withSession(args) { $0.goBack() }; result(nil)
    case "goForward": withSession(args) { $0.goForward() }; result(nil)
    case "executeJavaScript":
      if let code = args["code"] as? String {
        withSession(args) { $0.executeJavaScript(code) }
      }
      result(nil)
    case "setZoomLevel":
      withSession(args) { $0.setZoomLevel(args["level"] as? Double ?? 0) }
      result(nil)
    case "editCommand":
      withSession(args) { $0.editCommand(args["command"] as? Int ?? -1) }
      result(nil)
    case "setVisible":
      withSession(args) { $0.setVisible(args["visible"] as? Bool ?? true) }
    case "respondMediaRequest":
      withSession(args) {
        $0.respondMediaRequest(id: args["id"] as? Int ?? 0,
                               allow: args["allow"] as? Bool ?? false,
                               remember: args["remember"] as? Bool ?? false)
      }
      result(nil)
    case "chooseContextMenu":
      withSession(args) {
        $0.chooseContextMenu(id: args["id"] as? Int ?? 0,
                             commandId: args["commandId"] as? Int ?? 0)
      }
      result(nil)
    case "setMediaSetting":
      withSession(args) { $0.setMediaSetting(args["value"] as? Int ?? 0) }
      result(nil)
    case "setAudioMuted":
      withSession(args) { $0.setAudioMuted(args["muted"] as? Bool ?? true) }
      result(nil)
    case "setFrameInterval":
      withSession(args) { $0.setFrameInterval(args["ms"] as? Int ?? 16) }
      result(nil)
    case "freezeSession": freezeSession(args, result)
    case "thawSession": thawSession(args, result)
    case "find":
      if let text = args["text"] as? String {
        withSession(args) {
          $0.find(text, forward: args["forward"] as? Bool ?? true,
                  matchCase: args["matchCase"] as? Bool ?? false,
                  findNext: args["findNext"] as? Bool ?? false)
        }
      }
      result(nil)
    case "stopFind":
      withSession(args) { $0.stopFind(args["clearSelection"] as? Bool ?? true) }
      result(nil)
    case "respondJsDialog":
      withSession(args) {
        $0.respondJsDialog(id: args["id"] as? Int ?? 0,
                           ok: args["ok"] as? Bool ?? true,
                           text: args["text"] as? String ?? "")
      }
      result(nil)
    case "evalReturning":
      if let code = args["code"] as? String {
        withSession(args) {
          $0.evalReturning(id: args["id"] as? Int ?? 0, code: code)
        }
      }
      result(nil)
    case "addJavaScriptChannel":
      if let name = args["name"] as? String {
        withSession(args) { $0.addChannel(name) }
      }
      result(nil)
    case "setCookie":
      withSession(args) {
        $0.setCookie(url: args["url"] as? String ?? "",
                     name: args["name"] as? String ?? "",
                     value: args["value"] as? String ?? "",
                     domain: args["domain"] as? String ?? "",
                     path: args["path"] as? String ?? "/",
                     secure: args["secure"] as? Bool ?? false,
                     httpOnly: args["httpOnly"] as? Bool ?? false,
                     sameSite: args["sameSite"] as? String ?? "unspecified")
      }
      result(nil)
    case "clearCookies":
      withSession(args) { $0.clearCookies() }
      result(nil)
    case "visitCookies":
      withSession(args) {
        $0.visitCookies(id: args["id"] as? Int ?? 0,
                        url: args["url"] as? String ?? "")
      }
      result(nil)
    case "deleteCookie":
      withSession(args) {
        $0.deleteCookie(url: args["url"] as? String ?? "",
                        name: args["name"] as? String ?? "")
      }
      result(nil)
    case "showDevTools":
      withSession(args) {
        if let x = args["inspectX"] as? Int, let y = args["inspectY"] as? Int {
          $0.showDevTools(inspectAt: (x: x, y: y))
        } else {
          $0.showDevTools()
        }
      }
      result(nil)
    case "enableAgentControl":
      // CEF-2b: broker a token-gated CDP endpoint scoped to THIS tile's CDP target.
      // Async (resolves the targetId via cef_host first). Requires the session to
      // have been created with agentControl (pipe) mode.
      guard let sid = args["sessionId"] as? String, let host = sessionHost[sid],
            let session = sessions[sid] else {
        result(FlutterError(code: "agent_control", message: "no such session", details: nil))
        return
      }
      host.enableAgentControl(browserId: session.browserId) { info in
        DispatchQueue.main.async {
          if let info = info {
            result(["wsUrl": info.wsUrl, "token": info.token, "port": info.port])
          } else {
            result(FlutterError(code: "agent_control",
                                message: "enableAgentControl failed: not in agent-control mode, host down, or targetId unresolved",
                                details: nil))
          }
        }
      }
    case "disableAgentControl":
      // CEF-2b: route by this session's browserId (mirrors enableAgentControl) so
      // only THIS tile's relay is torn down — siblings on the same shared host stay
      // agent-controlled.
      if let sid = args["sessionId"] as? String, let session = sessions[sid] {
        sessionHost[sid]?.disableAgentControl(browserId: session.browserId)
      }
      result(nil)
    case "showEmojiPicker":
      // The Character Viewer targets the current first responder's input
      // context — Flutter's text-input plugin while the CefWebView is focused.
      NSApplication.shared.orderFrontCharacterPalette(nil)
      result(nil)
    case "imeSetComposition":
      withSession(args) { $0.imeSetComposition(args["text"] as? String ?? "") }
      result(nil)
    case "imeCommitText":
      withSession(args) { $0.imeCommitText(args["text"] as? String ?? "") }
      result(nil)
    case "imeCancelComposition":
      withSession(args) { $0.imeCancelComposition() }
      result(nil)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func withSession(_ a: [String: Any], _ body: (CefWebSession) -> Void) {
    if let id = a["sessionId"] as? String, let s = sessions[id] { body(s) }
  }

  /// Relay an event from a session (any thread) to Dart on the main thread.
  private func emit(_ method: String, _ args: [String: Any]) {
    DispatchQueue.main.async { [weak self] in
      self?.channel?.invokeMethod(method, arguments: args)
    }
  }

  private func create(_ a: [String: Any], _ result: @escaping FlutterResult) {
    // The session/profile dictionaries below are unlocked and rely on being
    // touched only from the main thread (H3) — the method-channel handler always
    // runs here. Assert it so a future off-main caller fails loudly, not silently
    // corrupting the maps.
    dispatchPrecondition(condition: .onQueue(.main))
    guard let sessionId = a["sessionId"] as? String,
          let registry = textureRegistry else {
      result(FlutterError(code: "bad_args", message: "missing sessionId/registry",
                          details: nil))
      return
    }
    guard let cefHost = resolveCefHostPath() else {
      result(FlutterError(code: "no_cef_host",
                          message: "cef_host not found (set FLUTTER_CEF_HOST)",
                          details: nil))
      return
    }
    let url = a["url"] as? String ?? "about:blank"
    let width = a["width"] as? Int ?? 800
    let height = a["height"] as? Int ?? 600
    let dpr = (a["dpr"] as? Double).map { CGFloat($0) } ?? 1.0
    let allowedSchemes = a["allowedSchemes"] as? String ?? ""
    let enableCdp = a["enableCdp"] as? Bool ?? false
    // Agent-control / pipe mode (CEF-1): CDP rides cef_host's inherited fds 3/4
    // (a private, NUL-framed pipe) instead of a TCP port. Because there's no
    // listening socket, the open-port cookie-exfil rationale doesn't apply, so
    // (unlike TCP enableCdp) it's permitted on a named profile — see below. Omit-
    // when-false from Dart, like enableCdp.
    let agentControl = a["agentControl"] as? Bool ?? false
    // A non-empty `profile` => a persistent, shared host; absent/empty => an
    // ephemeral throwaway host. Backward-compat is structural: no `profile`
    // behaves exactly as before.
    let profile = a["profile"] as? String
    let namedProfile = profile != nil && !profile!.isEmpty

    // Dispose any prior session with this id first (route teardown through its
    // host), so re-creating the same id is idempotent and doesn't trip the
    // single-view guard below on itself.
    disposeSession(sessionId)

    // Safety rail (a): TCP CDP is an unauthenticated localhost port that could
    // read the shared cookie jar, so it's incompatible with a named profile.
    // Reject before spawn, so --cdp-port and --profile-dir never co-arrive at
    // cef_host. The agent-control PIPE path is exempt: it exposes no listening
    // socket (CDP rides inherited fds 3/4, private to this app), so the exfil
    // rationale doesn't apply — and when agentControl is set, spawn() passes
    // --cdp-pipe and never --cdp-port even if enableCdp was also requested, so no
    // TCP port opens. Hence the rejection gates only the plain-TCP case
    // (enableCdp && !agentControl). The TCP enableCdp+named lockdown is unchanged.
    if enableCdp && namedProfile && !agentControl {
      result(FlutterError(
        code: "cdp_with_profile",
        message: "enableCdp cannot be combined with a named profile: CDP exposes "
          + "an unauthenticated localhost port that could read the profile's "
          + "shared cookie jar. (Agent-control pipe mode is exempt — it opens no "
          + "port.)",
        details: nil))
      return
    }
    // P2-step1: the single-view guard is lifted — multiple views on a named
    // profile now share ONE cef_host (resolveOrSpawnHost de-dups by key), so
    // every web tile renders and shares one cookie jar (sign-in persists across
    // tiles + relaunch). P2-step2: agent-control is now multi-tile — N tiles on
    // one shared host can be agent-controlled concurrently, each via its own
    // per-target CDP relay (one relay per browserId, demuxed over the shared pipe
    // by the per-relay CDP-id rewrite — see CdpRelay's multiplex note).

    // C2: if a running ad-hoc host already refused this named profile, don't race onto
    // a doomed shared host — go ephemeral directly.
    let effectiveNamed = namedProfile && !adhocBlockedProfiles.contains(profile ?? "")
    let (profileDir, isEphemeral) = resolveProfileDir(effectiveNamed ? profile : nil)
    let key = effectiveNamed ? profile! : "~ephemeral~" + sessionId

    guard let host = resolveOrSpawnHost(
      key: key, profileDir: profileDir, isEphemeral: isEphemeral,
      cefHostPath: cefHost, enableCdp: enableCdp, allowedSchemes: allowedSchemes,
      agentControl: agentControl)
    else {
      result(FlutterError(code: "spawn_failed",
                          message: "failed to spawn cef_host", details: nil))
      return
    }

    // F.5 dev safety-rail: an ad-hoc (mock-keychain) host refuses a named
    // persistent profile at opReady (nothing's been written, so no creds leak).
    // When that fires, tear the host down and respawn an EPHEMERAL host for this
    // same session, then re-issue createBrowser. Wired only for named profiles;
    // an already-ephemeral host never refuses.
    if effectiveNamed {
      // C2: re-home the WHOLE shared host's sessions onto ephemeral hosts on refusal —
      // not just this one. The closure captures the host, not a single sessionId, so a
      // burst of tiles that all attached before opReady are all rescued.
      host.onInsecureProfileRefused = { [weak self, weak host] in
        DispatchQueue.main.async {
          guard let self = self, let host = host, let prof = profile else { return }
          self.respawnHostEphemeral(host, refusedProfile: prof)
        }
      }
    }

    let session = CefWebSession(
      sessionId: sessionId, width: width, height: height, dpr: dpr,
      registry: registry)
    session.onCursor = { [weak self] cursor in
      self?.emit("cursor", ["sessionId": sessionId, "cursor": cursor])
    }
    session.onLoadState = { [weak self] loading, back, forward in
      self?.emit("loadingState", [
        "sessionId": sessionId, "isLoading": loading,
        "canGoBack": back, "canGoForward": forward,
      ])
    }
    session.onTitle = { [weak self] t in
      self?.emit("title", ["sessionId": sessionId, "title": t])
    }
    session.onUrl = { [weak self] u in
      self?.emit("url", ["sessionId": sessionId, "url": u])
    }
    session.onLoadError = { [weak self] code, url, text in
      self?.emit("loadError", [
        "sessionId": sessionId, "code": code, "url": url, "text": text,
      ])
    }
    session.onConsole = { [weak self] level, message in
      self?.emit("consoleMessage", [
        "sessionId": sessionId, "level": level, "message": message,
      ])
    }
    session.onPageStarted = { [weak self] u in
      self?.emit("pageStarted", ["sessionId": sessionId, "url": u])
    }
    session.onPageFinished = { [weak self] u in
      self?.emit("pageFinished", ["sessionId": sessionId, "url": u])
    }
    session.onProgress = { [weak self] p in
      self?.emit("progress", ["sessionId": sessionId, "progress": p])
    }
    session.onNewWindow = { [weak self] u in
      self?.emit("newWindow", ["sessionId": sessionId, "url": u])
    }
    session.onFindResult = { [weak self] count, ordinal, isFinal in
      self?.emit("findResult", [
        "sessionId": sessionId, "count": count,
        "activeMatchOrdinal": ordinal, "isFinal": isFinal,
      ])
    }
    session.onJsDialog = { [weak self] id, type, message, defaultText in
      self?.emit("jsDialog", [
        "sessionId": sessionId, "id": id, "type": type,
        "message": message, "defaultText": defaultText,
      ])
    }
    session.onEvalResult = { [weak self] payload in
      self?.emit("evalResult", ["sessionId": sessionId, "payload": payload])
    }
    session.onChannelMsg = { [weak self] payload in
      self?.emit("channelMessage", ["sessionId": sessionId, "payload": payload])
    }
    session.onDownload = { [weak self] name in
      self?.emit("download", ["sessionId": sessionId, "suggestedName": name])
    }
    session.onImeBounds = { [weak self] x, y, w, h in
      self?.emit("imeCompositionBounds", [
        "sessionId": sessionId, "x": x, "y": y, "w": w, "h": h,
      ])
    }
    session.onCookies = { [weak self] id, json in
      self?.emit("cookies", ["sessionId": sessionId, "id": id, "json": json])
    }
    session.onMediaRequest = { [weak self] id, permissions, origin in
      self?.emit("mediaRequest", [
        "sessionId": sessionId, "id": id,
        "permissions": permissions, "origin": origin,
      ])
    }
    session.onContextMenu = { [weak self] id, json in
      self?.emit("contextMenu", [
        "sessionId": sessionId, "id": id, "json": json,
      ])
    }
    session.onMediaState = { [weak self] video, audio, setting in
      self?.emit("mediaState", [
        "sessionId": sessionId, "videoActive": video,
        "audioActive": audio, "setting": setting,
      ])
    }
    session.onSurface = { [weak self] surfaceId, width, height in
      self?.emit("onSurface", [
        "sessionId": sessionId, "surfaceId": Int(surfaceId),
        "width": width, "height": height,
      ])
    }
    // The session's init publish fired onSurface before the callback above existed, so
    // deliver the current surface now (no-op until the first surface is allocated).
    session.emitCurrentSurface()
    // Allocate the wire browserId + (when ready) issue opCreateBrowser. The
    // process arg --allowed-schemes is shared by every browser in the profile;
    // it's taken from the first browser that triggered the spawn.
    _ = host.createBrowser(session, url: url, allowedSchemes: allowedSchemes)
    sessions[sessionId] = session
    sessionHost[sessionId] = host
    sessionKey[sessionId] = key
    // C2 re-home + freeze/thaw recipe.
    sessionCreateArgs[sessionId] = (url, allowedSchemes, agentControl, profile, enableCdp)
    result([
      "textureId": session.textureId, "width": width, "height": height,
      "cdpPort": host.cdpPort,
    ])
  }

  /// Resolve an existing host for `key`, or spawn a fresh one. Returns nil if the
  /// spawn fails. `agentControl` switches the launch to posix_spawn (CDP over
  /// inherited fds 3/4) — see CefProfileHost.spawn. Only meaningful when this call
  /// actually spawns; an EXISTING host keeps its original transport. Since P2,
  /// a named profile is MULTI-view (N tiles share one host), so an agent-control
  /// create() resolving to a pre-existing host is the normal path for the 2nd+
  /// tile — the host was already spawned in agent-control mode by the first, and
  /// each tile gets its own per-target CDP relay (see CefProfileHost.enableAgentControl).
  private func resolveOrSpawnHost(
    key: String, profileDir: String, isEphemeral: Bool, cefHostPath: String,
    enableCdp: Bool, allowedSchemes: String, agentControl: Bool
  ) -> CefProfileHost? {
    if let existing = profiles[key] { return existing }
    let host = CefProfileHost(
      profileId: key, profileDir: profileDir, isEphemeral: isEphemeral)
    guard host.spawn(cefHostPath: cefHostPath, enableCdp: enableCdp,
                     allowedSchemes: allowedSchemes, agentControl: agentControl)
    else {
      return nil
    }
    wireHostDied(host)
    profiles[key] = host
    return host
  }

  /// C1: install the host-died handler. When `cef_host` dies unexpectedly (its
  /// reader hit EOF while running, or a write hit a dead pipe — see
  /// CefProfileHost.handleHostDeath), tell every session on this host that its
  /// process is gone, drop those sessions and the host so the profile_in_use
  /// guard unblocks (hasLiveBrowser also goes false via the host's crashed flag),
  /// and reap the process. `onHostDied` is dispatched on the main thread by the
  /// host, so the unlocked dictionaries are touched only here on main (H3).
  /// Fail every session attached to `host` (emit processGone with `reason` + dispose),
  /// drop the host from the profile registry, and reap it. Main-thread only (the maps
  /// are main-thread confined — H3). Shared by the host-death and protocol-mismatch
  /// paths, which differ only in the reason string.
  private func failHost(_ host: CefProfileHost, reason: String) {
    dispatchPrecondition(condition: .onQueue(.main))
    // Every session still routed to this host loses its browser. Snapshot first
    // (we mutate the maps in the loop).
    let goneSessions = sessionHost.compactMap { $0.value === host ? $0.key : nil }
    for sid in goneSessions {
      emit("processGone", ["sessionId": sid, "reason": reason])
      // F-5: dispose the session BEFORE niling the maps. dispose() is the only caller of
      // registry.unregisterTexture (+ frees the CVPixelBuffer / IOSurface / any pending
      // buffer). If we just nil sessions[sid], the later Dart controller.dispose ->
      // disposeSession early-returns on the now-missing session, so the texture + surfaces
      // leak for the engine's lifetime — on EVERY host crash, exactly when recovery (a
      // fresh create) happens most. (onBrowserFailed / respawn-failure already dispose;
      // this path was the asymmetric leak.)
      sessions[sid]?.dispose()
      sessions[sid] = nil
      sessionHost[sid] = nil
      sessionKey[sid] = nil
      sessionCreateArgs[sid] = nil
    }
    // Drop the host from the profile registry so a re-create spawns a fresh
    // one. Snapshot the matching keys first — never mutate a Dictionary while
    // iterating it.
    let goneKeys = profiles.compactMap { $0.value === host ? $0.key : nil }
    for k in goneKeys { profiles[k] = nil }
    // Reap: idempotent SIGTERM(+SIGKILL escalation), a no-op if already exited.
    host.shutdown()
  }

  private func wireHostDied(_ host: CefProfileHost) {
    host.onHostDied = { [weak self, weak host] status in
      dispatchPrecondition(condition: .onQueue(.main))
      guard let self = self, let host = host else { return }
      // C2 cross-group contract: cef_host exits 2 (after SendLog "profile-locked")
      // when it loses the cache singleton lock to another process. Surface that as
      // a distinct reason so the widget can say "already open elsewhere" instead of
      // a generic crash.
      self.failHost(host, reason: (status == 2) ? "locked" : "crashed")
    }
    // Protocol handshake refusal: the host announced a wire-protocol version this
    // plugin doesn't speak (see CefProfileHost.protocolVersion). Nothing was flushed
    // to it, so nothing mis-parsed — fail its sessions with a distinct reason and
    // tear it down. Deliberately NO auto-respawn (a respawn would re-resolve the
    // same mismatched binary and loop); the consumer's bounded recovery surfaces it.
    host.onProtocolMismatch = { [weak self, weak host] hostVersion in
      DispatchQueue.main.async {
        guard let self = self, let host = host else { return }
        self.failHost(host, reason: "protocolMismatch(host=v\(hostVersion))")
      }
    }
    // H7: a SINGLE browser's create failed (host otherwise healthy) — drop just that
    // session + emit processGone for it, so Dart stops waiting on a browser that will
    // never paint (the host's create-pacer already advanced).
    host.onBrowserFailed = { [weak self, weak host] browserId in
      DispatchQueue.main.async {
        guard let self = self, let host = host,
              let sid = self.sessionId(forBrowserId: browserId, on: host) else { return }
        self.emit("processGone", ["sessionId": sid, "reason": "createFailed"])
        let session = self.sessions[sid]
        self.sessions[sid] = nil
        self.sessionHost[sid] = nil
        self.sessionKey[sid] = nil
        self.sessionCreateArgs[sid] = nil
        _ = host.removeBrowser(browserId)
        session?.dispose()
      }
    }
    // C1: a browser never painted its first frame despite a re-kick — surface
    // paintStalled so Dart/the consumer can recover (e.g. recreate the view) instead of
    // a silent, unrecoverable blank tile. The browser stays alive (it may yet paint).
    host.onPaintStalled = { [weak self, weak host] browserId in
      DispatchQueue.main.async {
        guard let self = self, let host = host,
              let sid = self.sessionId(forBrowserId: browserId, on: host) else { return }
        self.emit("paintStalled", ["sessionId": sid])
      }
    }
  }

  /// Find the sessionId of the session bound to `browserId` on `host` (main-thread maps).
  private func sessionId(forBrowserId browserId: UInt32, on host: CefProfileHost) -> String? {
    for (sid, s) in sessions where s.browserId == browserId && sessionHost[sid] === host {
      return sid
    }
    return nil
  }

  /// C2/F.5: a running cef_host turned out to be an ad-hoc (mock-keychain) build and
  /// refused its named profile (at opReady, BEFORE any browser was created — so nothing
  /// rendered or leaked). Re-home EVERY session that was on that shared host onto its
  /// own ephemeral host, preserving each session's url/schemes/agent-control, and
  /// remember the profile so later creates skip the doomed shared host. This replaces
  /// the old per-session respawn that shut the whole shared host down — which stranded
  /// every sibling tile blank-and-dead with no error.
  private func respawnHostEphemeral(_ oldHost: CefProfileHost, refusedProfile: String) {
    // The unlocked session/profile dictionaries are confined to the main thread (H3);
    // reached from onInsecureProfileRefused via DispatchQueue.main.
    dispatchPrecondition(condition: .onQueue(.main))
    guard let cefHost = resolveCefHostPath() else { return }
    adhocBlockedProfiles.insert(refusedProfile)
    let victims = sessionHost.compactMap { $0.value === oldHost ? $0.key : nil }
    // Forget + tear down the refused host (every session on it is about to move off).
    let goneKeys = profiles.compactMap { $0.value === oldHost ? $0.key : nil }
    for k in goneKeys { profiles[k] = nil }
    oldHost.shutdown()
    for sid in victims {
      guard let session = sessions[sid], let args = sessionCreateArgs[sid] else { continue }
      let (profileDir, isEphemeral) = resolveProfileDir(nil)
      let key = "~ephemeral~" + sid
      let host = CefProfileHost(profileId: key, profileDir: profileDir, isEphemeral: isEphemeral)
      guard host.spawn(cefHostPath: cefHost, enableCdp: false,
                       allowedSchemes: args.allowedSchemes,
                       agentControl: args.agentControl) else {
        // The old host is already shut down, so a bare `continue` would strand this
        // session bound to a dead host: blank tile, no signal, leaked session+texture.
        // Fail it explicitly instead — processGone lets the consumer recreate.
        NSLog("[cef] C2 respawn ephemeral host failed for \(sid)")
        emit("processGone", ["sessionId": sid, "reason": "respawnFailed"])
        sessions[sid] = nil
        sessionHost[sid] = nil
        sessionKey[sid] = nil
        sessionCreateArgs[sid] = nil
        session.dispose()
        continue
      }
      wireHostDied(host)
      profiles[key] = host
      _ = host.createBrowser(session, url: args.url, allowedSchemes: args.allowedSchemes)
      sessionHost[sid] = host
      sessionKey[sid] = key
    }
  }

  private func navigate(_ a: [String: Any], _ result: @escaping FlutterResult) {
    if let id = a["sessionId"] as? String, let url = a["url"] as? String {
      sessions[id]?.navigate(url)
    }
    result(nil)
  }

  /// Open a windowed Chrome-runtime browser at |url| for a WebAuthn / Touch ID
  /// ceremony the OSR tile cannot host. Shares the session's cookie jar so the
  /// sign-in propagates back to the tile.
  private func openAuthWindow(_ a: [String: Any], _ result: @escaping FlutterResult) {
    if let id = a["sessionId"] as? String, let url = a["url"] as? String {
      sessions[id]?.openAuthWindow(url)
    }
    result(nil)
  }

  /// Host content-injection load (loadHtmlString/loadFile) — bypasses the
  /// navigation scheme allowlist in cef_host.
  private func loadTrusted(_ a: [String: Any], _ result: @escaping FlutterResult) {
    if let id = a["sessionId"] as? String, let url = a["url"] as? String {
      sessions[id]?.loadTrusted(url)
    }
    result(nil)
  }

  private func resize(_ a: [String: Any], _ result: @escaping FlutterResult) {
    if let id = a["sessionId"] as? String, let s = sessions[id] {
      s.resize(width: a["width"] as? Int ?? 800, height: a["height"] as? Int ?? 600,
               dpr: (a["dpr"] as? Double).map { CGFloat($0) } ?? 0)
      result(["textureId": s.textureId])
    } else {
      result(nil)
    }
  }

  /// Read the session's live frame surface synchronously: the global IOSurface
  /// id its CVPixelBuffer is backed by, plus the PHYSICAL (Retina) pixel dims
  /// (logical w/h * dpr, matching allocateBuffers' rounding). A frame-export
  /// consumer resolves the surface by id; the `onSurface` event fires it on each
  /// (re)alloc, this verb is the on-demand pull. Returns nil for an unknown
  /// session, or `surfaceId: 0` before the buffer is allocated.
  private func getFrameSurface(_ a: [String: Any], _ result: @escaping FlutterResult) {
    guard let id = a["sessionId"] as? String, let s = sessions[id] else {
      result(nil)
      return
    }
    let dpr = Double(s.scale)
    let pw = max(1, Int((Double(s.w) * dpr).rounded()))
    let ph = max(1, Int((Double(s.h) * dpr).rounded()))
    result(["surfaceId": Int(s.surfaceId), "width": pw, "height": ph])
  }

  private func destroy(_ a: [String: Any], _ result: @escaping FlutterResult) {
    if let id = a["sessionId"] as? String { disposeSession(id) }
    result(nil)
  }

  /// Tear down one session: close its browser on the shared host, then dispose
  /// the session. ORDERING (binding, F.3): if this was the host's last browser,
  /// `host.shutdown()` (which joins the reader, so no more inbound) runs BEFORE
  /// `session.dispose()` and the profile is dropped. Otherwise `removeBrowser`
  /// has already unregistered this browser under lock, so `session.dispose()`
  /// runs safely while the shared reader keeps serving the siblings.
  private func disposeSession(_ id: String) {
    // Unlocked session/profile dictionaries — main-thread confined (H3). Reached
    // from create()/destroy() (channel handler, on main) and never off-main.
    dispatchPrecondition(condition: .onQueue(.main))
    guard let session = sessions[id] else { return }
    let host = sessionHost[id]
    let key = sessionKey[id]
    sessions[id] = nil
    sessionHost[id] = nil
    sessionKey[id] = nil
    sessionCreateArgs[id] = nil
    // A frozen session has no host on record; the guard below releases it.
    frozenSessions.remove(id)
    guard let host = host else {
      // No host on record (shouldn't happen) — just release the session.
      session.dispose()
      return
    }
    let remaining = host.removeBrowser(session.browserId)
    if remaining == 0 {
      host.shutdown()
      session.dispose()
      if let key = key { profiles[key] = nil }
    } else {
      session.dispose()
    }
  }

  /// Freeze one session: close its native browser — and, when that was the
  /// host's last live browser, the whole cef_host process tree — while KEEPING
  /// the session + texture. The consumer-held CVPixelBuffer retains the
  /// producer's IOSurface (a kernel object), so the tile keeps serving its
  /// last painted frame; thawSession recreates a browser onto the same
  /// session. Returns false when there is nothing to freeze (unknown session,
  /// already frozen, or its host already died — processGone handles that path).
  private func freezeSession(_ a: [String: Any], _ result: @escaping FlutterResult) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let id = a["sessionId"] as? String, let session = sessions[id],
          !frozenSessions.contains(id), let host = sessionHost[id] else {
      result(false)
      return
    }
    let key = sessionKey[id]
    // Same F.3 ordering discipline as disposeSession: removeBrowser unregisters
    // under lock (reader stops routing to this session), and a last-browser
    // host is fully shut down (reader joined) BEFORE the session's unlocked
    // establishment counters are reset in detachForFreeze.
    let remaining = host.removeBrowser(session.browserId)
    if remaining == 0 {
      host.shutdown()
      if let key = key { profiles[key] = nil }
    }
    session.detachForFreeze()
    frozenSessions.insert(id)
    sessionHost[id] = nil
    sessionKey[id] = nil
    result(true)
  }

  /// Thaw a frozen session: resolve/spawn a host of the ORIGINAL kind (same
  /// profile / transport, from sessionCreateArgs) and recreate a browser onto
  /// the SAME session + texture — attach() re-binds the wire id and re-flushes
  /// JS channels, and the create pacer / first-present watchdog treat it as a
  /// fresh establishment. The frozen frame keeps showing until the new
  /// browser's first paint adopts (no flash). `url` overrides the original
  /// create URL (pass the page's current address for fidelity). Returns nil
  /// when there is nothing to thaw.
  private func thawSession(_ a: [String: Any], _ result: @escaping FlutterResult) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let id = a["sessionId"] as? String, frozenSessions.contains(id),
          let session = sessions[id], let args = sessionCreateArgs[id] else {
      result(nil)
      return
    }
    guard let cefHost = resolveCefHostPath() else {
      result(FlutterError(code: "no_cef_host",
                          message: "cef_host not found (set FLUTTER_CEF_HOST)",
                          details: nil))
      return
    }
    let url = (a["url"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? args.url
    let profile = args.profile
    let namedProfile = profile != nil && !profile!.isEmpty
    // Mirrors create(): skip a named profile a running ad-hoc host already refused.
    let effectiveNamed = namedProfile && !adhocBlockedProfiles.contains(profile ?? "")
    let (profileDir, isEphemeral) = resolveProfileDir(effectiveNamed ? profile : nil)
    let key = effectiveNamed ? profile! : "~ephemeral~" + id
    guard let host = resolveOrSpawnHost(
      key: key, profileDir: profileDir, isEphemeral: isEphemeral,
      cefHostPath: cefHost, enableCdp: args.enableCdp,
      allowedSchemes: args.allowedSchemes, agentControl: args.agentControl)
    else {
      result(FlutterError(code: "spawn_failed",
                          message: "failed to spawn cef_host", details: nil))
      return
    }
    // F.5 wiring, same as create(): an ad-hoc host refusing the named profile
    // re-homes every session on it onto ephemeral hosts.
    if effectiveNamed {
      host.onInsecureProfileRefused = { [weak self, weak host] in
        DispatchQueue.main.async {
          guard let self = self, let host = host, let prof = profile else { return }
          self.respawnHostEphemeral(host, refusedProfile: prof)
        }
      }
    }
    frozenSessions.remove(id)
    _ = host.createBrowser(session, url: url, allowedSchemes: args.allowedSchemes)
    sessionHost[id] = host
    sessionKey[id] = key
    // sessionCreateArgs keeps the ORIGINAL url: a later thaw without an
    // override falls back to it again (the thaw url is transient).
    result(["textureId": session.textureId])
  }

  /// Resolve the on-disk cache dir for a profile. F.4: a null/empty profile gets
  /// a unique throwaway temp dir (ephemeral, removed on host shutdown); a named
  /// profile gets a stable 0700 dir under Application Support that survives
  /// relaunch. Both go through one downstream code path: the host always receives
  /// --profile-dir=<dir>.
  private func resolveProfileDir(_ profile: String?) -> (dir: String, ephemeral: Bool) {
    let fm = FileManager.default
    guard let profile = profile, !profile.isEmpty else {
      let dir = NSTemporaryDirectory() + "flutter_cef_ephem_" + UUID().uuidString
      try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true,
                              attributes: [.posixPermissions: 0o700])
      return (dir, true)
    }
    // Sanitize to a filesystem-safe leaf; anything outside [A-Za-z0-9._-] -> '_'.
    let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
    let sanitized = String(profile.map { allowed.contains($0) ? $0 : "_" })
    // '/' is already mapped to '_', but a leaf of all dots ("." / ".." / "...")
    // survives and resolves to the profiles/ container or its PARENT — a
    // one-level containment escape whose 0700 chmod would clobber a shared
    // ancestor. Neutralize it to a literal name.
    let safe = sanitized.allSatisfy { $0 == "." } ? "_" : sanitized
    let bundleId = Bundle.main.bundleIdentifier ?? "flutter_cef"
    let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    let base = (appSupport?.path ?? NSTemporaryDirectory())
    let dir = base + "/" + bundleId + "/flutter_cef/profiles/" + safe
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true,
                            attributes: [.posixPermissions: 0o700])
    // Re-chmod the leaf: createDirectory's attributes apply only to dirs it
    // creates, and an existing leaf from a prior run keeps its old mode.
    try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
    return (dir, false)
  }

  private func pointer(_ a: [String: Any], _ result: @escaping FlutterResult) {
    if let id = a["sessionId"] as? String, let s = sessions[id] {
      s.sendPointer(
        type: a["type"] as? Int ?? 0, button: a["button"] as? Int ?? 0,
        clickCount: a["clickCount"] as? Int ?? 1,
        modifiers: UInt32(truncatingIfNeeded: a["modifiers"] as? Int ?? 0),
        x: a["x"] as? Double ?? 0, y: a["y"] as? Double ?? 0,
        dx: a["dx"] as? Double ?? 0, dy: a["dy"] as? Double ?? 0)
    }
    result(nil)
  }

  private func key(_ a: [String: Any], _ result: @escaping FlutterResult) {
    if let id = a["sessionId"] as? String, let s = sessions[id] {
      s.sendKey(
        type: a["type"] as? Int ?? 0,
        modifiers: UInt32(truncatingIfNeeded: a["modifiers"] as? Int ?? 0),
        windowsKeyCode: Int32(truncatingIfNeeded: a["windowsKeyCode"] as? Int ?? 0),
        nativeKeyCode: Int32(truncatingIfNeeded: a["nativeKeyCode"] as? Int ?? 0),
        character: UInt32(truncatingIfNeeded: a["character"] as? Int ?? 0))
    }
    result(nil)
  }

  /// FLUTTER_CEF_HOST env override -> bundled in the app -> nil.
  private func resolveCefHostPath() -> String? {
    let fm = FileManager.default
    if let env = ProcessInfo.processInfo.environment["FLUTTER_CEF_HOST"],
       !env.isEmpty, fm.fileExists(atPath: env) {
      return env
    }
    let inner = "/cef_host.app/Contents/MacOS/cef_host"
    // The plugin podspec's :after_compile script phase embeds cef_host.app into THIS framework's
    // Versions/A/Frameworks (a pod build phase can't reach the app's top-level Contents/Frameworks —
    // it runs before the app bundle exists). The framework exposes no top-level `Frameworks` symlink,
    // so reach it through `Versions/Current/Frameworks`. This makes a prebuilt-bundled host resolve
    // with zero consumer wiring. The Contents/Frameworks + Contents/Helpers probes remain for a
    // consumer that copies the host to the app's top level itself.
    let fwFrameworks = Bundle(for: FlutterCefPlugin.self).bundleURL
      .appendingPathComponent("Versions/Current/Frameworks").path
    for base in [
      fwFrameworks,
      Bundle(for: FlutterCefPlugin.self).resourceURL?.path,
      Bundle.main.bundlePath + "/Contents/Frameworks",
      Bundle.main.bundlePath + "/Contents/Helpers",
    ] {
      if let b = base, fm.fileExists(atPath: b + inner) { return b + inner }
    }
    return nil
  }
}
