/// flutter_cef — embed a live Chromium (CEF) browser as a Flutter widget.
///
/// The page renders off-screen in a `cef_host` subprocess into a shared
/// surface (an IOSurface on macOS, a DXGI shared texture on Windows) and is
/// shown as a [Texture] (so it composites/transforms/clips like any widget).
/// Pointer + keyboard input is forwarded by coordinate, and the page cursor
/// drives a [MouseRegion]. macOS and Windows (the package is federated — see
/// `flutter_cef_macos`, `flutter_cef_windows`, and `PORTING.md`).
library;

export 'package:flutter_cef_platform_interface/flutter_cef_platform_interface.dart'
    show
        CefCookie,
        CefCookieSameSite,
        CefConsoleMessage,
        CefContextMenuItem,
        CefContextMenuItemType,
        CefContextMenuRequest,
        CefFindResult,
        CefJsDialogRequest,
        CefLoadError,
        CefSessionStats,
        CefMediaPermissionRequest,
        CefMediaSetting,
        CefMediaState,
        CefSurfaceInfo;
export 'src/cef_web_controller.dart' show CefWebController;
export 'src/cef_web_view.dart' show CefWebView;
