// SameSite/Secure cookie attribute END-TO-END probe (macOS + Windows).
//
// Auto-running, no-interaction self-test for the setCookie attribute fields
// (secure / httpOnly / sameSite) added for the FlutterFlow Test Mode preview:
// the worker's `session_jwt` must be stored `SameSite=None; Secure` or CEF
// sends the top-level load authenticated but every cross-site subresource
// (assets, the DWDS websocket) cookie-less, and the preview renders blank.
//
// Drives the REAL integrated stack — CefWebController -> method channel ->
// platform plugin -> the cef_host beside the app (or $FLUTTER_CEF_HOST) — via
// the cookie API alone (no page load / GPU paint needed):
//
//   NONE+SECURE  — setCookie(sameSite: none, secure: true) round-trips through
//                  the host jar and getCookies reports secure && sameSite=none.
//   DEFAULT      — a plain setCookie stays sameSite=unspecified, NOT secure.
//   LAX          — sameSite: lax round-trips as lax.
//   FORCE-SECURE — sameSite: none WITHOUT secure is stored Secure anyway (the
//                  host forces it, since Chromium drops None-without-Secure).
//
// A `CEF_PROBE_RESULT PASS|FAIL` line is printed to stdout at the end.
//
// Run:  flutter run -d macos -t lib/samesite_probe.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_cef/flutter_cef.dart';

const _url = 'https://samesite.evi.example/';

void main() => runApp(const ProbeApp());

class ProbeApp extends StatefulWidget {
  const ProbeApp({super.key});
  @override
  State<ProbeApp> createState() => _ProbeAppState();
}

class _ProbeAppState extends State<ProbeApp> {
  final List<String> _lines = [];
  bool _pass = true;

  void _check(String name, bool cond) {
    if (!cond) _pass = false;
    _log('${cond ? "PASS" : "FAIL"}  $name');
  }

  void _log(String s) {
    _lines.add(s);
    // ignore: avoid_print
    print('CEF_PROBE_LOG  $s');
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<List<CefCookie>> _cookies(CefWebController c) async {
    // The host registers the browser slot on an async UI task; retry until a
    // visit round-trips (same rationale as profile_probe._cookies).
    Object? lastErr;
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        return await c
            .getCookies(url: _url)
            .timeout(const Duration(milliseconds: 1500));
      } catch (e) {
        lastErr = e;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    throw StateError('getCookies never answered: $lastErr');
  }

  CefCookie? _find(List<CefCookie> jar, String name) {
    for (final c in jar) {
      if (c.name == name) return c;
    }
    return null;
  }

  Future<void> _run() async {
    final c = CefWebController();
    try {
      await c
          .create(url: 'about:blank', width: 400, height: 300, dpr: 1.0)
          .timeout(const Duration(seconds: 20));
      await _cookies(c); // wait for the slot to be live before setting

      await c.setCookie(
          url: _url,
          name: 'none_secure',
          value: 'v1',
          secure: true,
          sameSite: CefCookieSameSite.none);
      await c.setCookie(url: _url, name: 'plain', value: 'v2');
      await c.setCookie(
          url: _url,
          name: 'laxy',
          value: 'v3',
          sameSite: CefCookieSameSite.lax);
      await c.setCookie(
          url: _url,
          name: 'none_unsecure',
          value: 'v4',
          sameSite: CefCookieSameSite.none);

      // Poll until the async jar commit shows all four.
      List<CefCookie> jar = const [];
      for (var i = 0; i < 40; i++) {
        jar = await _cookies(c);
        if (jar.length >= 4) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      _log('jar: $jar');

      final ns = _find(jar, 'none_secure');
      _check('none+secure stored', ns != null);
      _check('none+secure: secure', ns?.secure == true);
      _check('none+secure: sameSite=none',
          ns?.sameSite == CefCookieSameSite.none);

      final plain = _find(jar, 'plain');
      _check('default stored', plain != null);
      _check('default: not secure', plain?.secure == false);
      _check('default: sameSite=unspecified',
          plain?.sameSite == CefCookieSameSite.unspecified);

      final laxy = _find(jar, 'laxy');
      _check('lax: sameSite=lax', laxy?.sameSite == CefCookieSameSite.lax);

      final nu = _find(jar, 'none_unsecure');
      _check('none w/o secure: stored anyway', nu != null);
      _check('none w/o secure: host forced Secure', nu?.secure == true);
      _check(
          'none w/o secure: sameSite=none', nu?.sameSite == CefCookieSameSite.none);
    } catch (e) {
      _pass = false;
      _log('EXCEPTION: $e');
    } finally {
      // ignore: avoid_print
      print('CEF_PROBE_RESULT ${_pass ? "PASS" : "FAIL"}');
      _log(_pass ? 'ALL PASS' : 'FAILED');
      try {
        await c.dispose();
      } catch (_) {}
      await Future<void>.delayed(const Duration(seconds: 1));
      exit(_pass ? 0 : 1);
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [for (final l in _lines) Text(l)],
          ),
        ),
      );
}
