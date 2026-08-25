import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show FlutterError, TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_cef/flutter_cef.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('flutter_cef');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final log = <MethodCall>[];

  setUp(() {
    messenger.setMockMethodCallHandler(channel, (call) async {
      log.add(call);
      if (call.method == 'create') {
        return <String, dynamic>{'textureId': 7, 'width': 100, 'height': 80};
      }
      return null;
    });
  });

  tearDown(() {
    log.clear();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('create returns the host texture id and forwards args', () async {
    final c = CefWebController(sessionId: 's1');
    final id =
        await c.create(url: 'https://example.com', width: 100, height: 80);
    expect(id, 7);
    expect(c.textureId, 7);
    final args = (log.firstWhere((m) => m.method == 'create').arguments as Map)
        .cast<String, dynamic>();
    expect(args['sessionId'], 's1');
    expect(args['url'], 'https://example.com');
    expect(args['width'], 100);
  });

  test('create re-asserts last-known visibility only when explicitly set',
      () async {
    // Explicit setVisible(false) before create: the browser binds, then the
    // controller replays the recorded visibility so a create-burst race can't
    // leave the slot latched in the wrong state. Carries the explicit value.
    final hidden = CefWebController(sessionId: 'vis-false');
    await hidden.setVisible(false);
    log.clear();
    await hidden.create(url: 'about:blank', width: 1, height: 1);
    final reHidden = log.where((m) =>
        m.method == 'setVisible' &&
        (m.arguments as Map)['sessionId'] == 'vis-false');
    expect(reHidden, isNotEmpty,
        reason: 'an explicitly-set visibility must be re-asserted after bind');
    expect((reHidden.last.arguments as Map)['visible'], false);

    // Explicit setVisible(true) before create: replays true — the on-screen wedge
    // heal (a visible edge that raced the bind is re-applied so the tile paints).
    final shown = CefWebController(sessionId: 'vis-true');
    await shown.setVisible(true);
    log.clear();
    await shown.create(url: 'about:blank', width: 1, height: 1);
    final reShown = log.where((m) =>
        m.method == 'setVisible' &&
        (m.arguments as Map)['sessionId'] == 'vis-true');
    expect(reShown, isNotEmpty);
    expect((reShown.last.arguments as Map)['visible'], true);

    // Never set: NO re-assert. A fresh/recovered slot that was never told a
    // visibility keeps CEF's default-shown rather than being force-repainted, so
    // an off-screen tile isn't briefly pumped at 60fps on create/recover.
    final never = CefWebController(sessionId: 'vis-never');
    log.clear();
    await never.create(url: 'about:blank', width: 1, height: 1);
    expect(
      log.where((m) =>
          m.method == 'setVisible' &&
          (m.arguments as Map)['sessionId'] == 'vis-never'),
      isEmpty,
      reason: 'a never-set visibility must not be re-asserted (off-screen guard)',
    );
  });

  test('create forwards allowedSchemes as a lowercased CSV', () async {
    final c = CefWebController(sessionId: 's-allow');
    await c.create(
        url: 'https://example.com',
        width: 10,
        height: 10,
        allowedSchemes: {'HTTP', 'https', 'about'});
    final args = (log.firstWhere((m) => m.method == 'create').arguments as Map)
        .cast<String, dynamic>();
    expect(args['allowedSchemes'], 'http,https,about');
  });

  test('create omits allowedSchemes when unset or empty', () async {
    // Use a FRESH controller per case: a second create() on an already-created
    // controller short-circuits (textureId is set) and never re-invokes the channel.
    final c1 = CefWebController(sessionId: 's-noallow');
    await c1.create(url: 'about:blank', width: 1, height: 1);
    final none = (log.firstWhere((m) => m.method == 'create').arguments as Map);
    expect(none.containsKey('allowedSchemes'), isFalse);

    log.clear();
    final c2 = CefWebController(sessionId: 's-noallow2');
    await c2.create(
        url: 'about:blank', width: 1, height: 1, allowedSchemes: const {});
    final empty =
        (log.firstWhere((m) => m.method == 'create').arguments as Map);
    expect(empty.containsKey('allowedSchemes'), isFalse);
  });

  test('create forwards the controller profile when set', () async {
    // `profile` is a controller field (not a create() arg) — create() reads it.
    final c = CefWebController(sessionId: 's-prof', profile: 'work');
    await c.create(url: 'about:blank', width: 10, height: 10);
    final args = (log.firstWhere((m) => m.method == 'create').arguments as Map)
        .cast<String, dynamic>();
    expect(args['profile'], 'work');
  });

  test('create omits profile when null or empty (ephemeral default)', () async {
    // Default (no profile) — the map must be byte-identical to today (no key).
    final none0 = CefWebController(sessionId: 's-noprof');
    await none0.create(url: 'about:blank', width: 1, height: 1);
    final none = (log.firstWhere((m) => m.method == 'create').arguments as Map);
    expect(none.containsKey('profile'), isFalse);

    // An empty-string profile is treated as "no profile" too (omitted).
    log.clear();
    final empty0 = CefWebController(sessionId: 's-emptyprof', profile: '');
    await empty0.create(url: 'about:blank', width: 1, height: 1);
    final empty =
        (log.firstWhere((m) => m.method == 'create').arguments as Map);
    expect(empty.containsKey('profile'), isFalse);
  });

  test('CefWebController(profile:) exposes the profile name', () {
    expect(CefWebController(profile: 'work').profile, 'work');
    expect(CefWebController().profile, isNull);
  });

  test('create() asserts when enableCdp is combined with a named profile', () {
    // CDP is an unauthenticated localhost port that could read the shared
    // cookie jar, so it is mutually exclusive with a named profile. The guard
    // is a debug assert; it only fires in debug builds.
    final c = CefWebController(sessionId: 's-cdp-prof', profile: 'work');
    expect(
      () => c.create(
          url: 'about:blank', width: 1, height: 1, enableCdp: true),
      throwsA(isA<AssertionError>()),
    );
  });

  test('create() allows enableCdp with no profile (ephemeral)', () async {
    // The assert must NOT fire for the common ephemeral + CDP case.
    final c = CefWebController(sessionId: 's-cdp-noprof');
    await c.create(
        url: 'about:blank', width: 1, height: 1, enableCdp: true);
    final args = (log.firstWhere((m) => m.method == 'create').arguments as Map)
        .cast<String, dynamic>();
    expect(args['enableCdp'], true);
    expect(args.containsKey('profile'), isFalse);
  });

  test('create forwards agentControl only when true', () async {
    final c1 = CefWebController(sessionId: 'ac-on', profile: 'work');
    await c1.create(
        url: 'about:blank', width: 1, height: 1, agentControl: true);
    final on = (log.firstWhere((m) => m.method == 'create').arguments as Map);
    expect(on['agentControl'], true);

    log.clear();
    final c2 = CefWebController(sessionId: 'ac-off');
    await c2.create(url: 'about:blank', width: 1, height: 1);
    final off = (log.firstWhere((m) => m.method == 'create').arguments as Map);
    expect(off.containsKey('agentControl'), isFalse,
        reason: 'OFF path must be byte-identical to today (no key)');
  });

  test('agentControl suppresses the enableCdp×profile assert (private pipe)',
      () async {
    // agentControl is a private inherited-fd CDP pipe (no listening port), so it
    // is permitted with a named profile even alongside enableCdp.
    final c = CefWebController(sessionId: 'ac-prof', profile: 'work');
    await expectLater(
      c.create(
          url: 'about:blank',
          width: 1,
          height: 1,
          enableCdp: true,
          agentControl: true),
      completes,
    );
  });

  test('enableAgentControl sends the verb and decodes the brokered endpoint',
      () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      log.add(call);
      if (call.method == 'enableAgentControl') {
        return <String, dynamic>{
          'wsUrl': 'ws://127.0.0.1:5555/devtools/browser?token=abc',
          'token': 'abc',
          'port': 5555,
        };
      }
      return null;
    });
    final c = CefWebController(sessionId: 'ac-en');
    final ep = await c.enableAgentControl();
    expect(
        (log.firstWhere((m) => m.method == 'enableAgentControl').arguments
            as Map)['sessionId'],
        'ac-en');
    expect(ep, isNotNull);
    expect(ep!.port, 5555);
    expect(ep.token, 'abc');
    expect(ep.wsUrl, contains('token=abc'));
  });

  test('disableAgentControl sends the verb for the session', () async {
    final c = CefWebController(sessionId: 'ac-dis');
    await c.disableAgentControl();
    final m = log.firstWhere((m) => m.method == 'disableAgentControl');
    expect((m.arguments as Map)['sessionId'], 'ac-dis');
  });

  test('navigate forwards the url for this session', () async {
    final c = CefWebController(sessionId: 's2');
    await c.navigate('https://flutter.dev');
    final args =
        (log.firstWhere((m) => m.method == 'navigate').arguments as Map)
            .cast<String, dynamic>();
    expect(args['sessionId'], 's2');
    expect(args['url'], 'https://flutter.dev');
  });

  test('a host cursor event updates the controller cursor', () async {
    final c = CefWebController(sessionId: 's3');
    // create() installs the host->Dart handler and registers the session.
    await c.create(url: 'about:blank', width: 10, height: 10);
    expect(c.cursor.value, SystemMouseCursors.basic);

    // Simulate a host -> Dart cursor event: CT_IBEAM (3) -> text cursor.
    await messenger.handlePlatformMessage(
      'flutter_cef',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('cursor', {'sessionId': 's3', 'cursor': 3}),
      ),
      (_) {},
    );
    expect(c.cursor.value, SystemMouseCursors.text);
  });

  test('a media request reaches the handler and its answer is sent back',
      () async {
    final c = CefWebController(sessionId: 'm1');
    await c.create(url: 'about:blank', width: 10, height: 10);
    CefMediaPermissionRequest? seen;
    c.onMediaPermissionRequest = (req) async {
      seen = req;
      return true;
    };

    // permissions bits: audio = 1<<0, video = 1<<1 -> both requested.
    await messenger.handlePlatformMessage(
      'flutter_cef',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('mediaRequest', {
          'sessionId': 'm1',
          'id': 42,
          'permissions': 3,
          'origin': 'https://meet.google.com',
        }),
      ),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);

    expect(seen?.origin, 'https://meet.google.com');
    expect(seen?.camera, isTrue);
    expect(seen?.microphone, isTrue);
    final args =
        (log.firstWhere((m) => m.method == 'respondMediaRequest').arguments
                as Map)
            .cast<String, dynamic>();
    expect(args['sessionId'], 'm1');
    expect(args['id'], 42);
    expect(args['allow'], isTrue);
    expect(args['remember'], isTrue);
  });

  test('an abandoned media prompt denies WITHOUT remembering', () async {
    // Regression: a defensive deny (nobody chose — the prompt was dismissed by
    // a navigation / teardown) must not persist as a site-wide block. It did,
    // which silently killed camera/mic for the site with no prompt left to
    // undo it, because a remembered block is applied without ever asking.
    final c = CefWebController(sessionId: 'm6');
    await c.create(url: 'about:blank', width: 10, height: 10);
    c.onMediaPermissionRequest = (_) async => null;

    await messenger.handlePlatformMessage(
      'flutter_cef',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('mediaRequest', {
          'sessionId': 'm6',
          'id': 5,
          'permissions': 3,
          'origin': 'https://meet.google.com',
        }),
      ),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);

    final args =
        (log.firstWhere((m) => m.method == 'respondMediaRequest').arguments
                as Map)
            .cast<String, dynamic>();
    expect(args['allow'], isFalse);
    expect(args['remember'], isFalse);
  });

  test('an explicit block IS remembered', () async {
    final c = CefWebController(sessionId: 'm7');
    await c.create(url: 'about:blank', width: 10, height: 10);
    c.onMediaPermissionRequest = (_) async => false;

    await messenger.handlePlatformMessage(
      'flutter_cef',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('mediaRequest', {
          'sessionId': 'm7',
          'id': 9,
          'permissions': 3,
          'origin': 'https://example.com',
        }),
      ),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);

    final args =
        (log.firstWhere((m) => m.method == 'respondMediaRequest').arguments
                as Map)
            .cast<String, dynamic>();
    expect(args['allow'], isFalse);
    expect(args['remember'], isTrue);
  });

  test('a media request with no handler is denied, but not remembered',
      () async {
    // Fail closed: a host that never opted into showing permission UI must not
    // let a page reach the camera — transiently, so wiring the UI up later
    // still gets to ask.
    final c = CefWebController(sessionId: 'm2');
    await c.create(url: 'about:blank', width: 10, height: 10);

    await messenger.handlePlatformMessage(
      'flutter_cef',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('mediaRequest', {
          'sessionId': 'm2',
          'id': 7,
          'permissions': 2,
          'origin': 'https://example.com',
        }),
      ),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);

    final args =
        (log.firstWhere((m) => m.method == 'respondMediaRequest').arguments
                as Map)
            .cast<String, dynamic>();
    expect(args['allow'], isFalse);
    expect(args['remember'], isFalse);
  });

  test('a throwing media handler denies rather than granting', () async {
    final c = CefWebController(sessionId: 'm3');
    await c.create(url: 'about:blank', width: 10, height: 10);
    c.onMediaPermissionRequest = (_) async => throw StateError('boom');
    final reported = <Object>[];
    final previousOnError = FlutterError.onError;
    FlutterError.onError = (details) => reported.add(details.exception);
    addTearDown(() => FlutterError.onError = previousOnError);

    await messenger.handlePlatformMessage(
      'flutter_cef',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('mediaRequest', {
          'sessionId': 'm3',
          'id': 1,
          'permissions': 1,
          'origin': 'https://example.com',
        }),
      ),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);

    final args =
        (log.firstWhere((m) => m.method == 'respondMediaRequest').arguments
                as Map)
            .cast<String, dynamic>();
    expect(args['allow'], isFalse);
    // A handler that blew up is not a human choosing "block".
    expect(args['remember'], isFalse);
    // The consumer's bug is reported, not swallowed.
    expect(reported.single, isA<StateError>());
  });

  test('a media state event updates the controller status', () async {
    final c = CefWebController(sessionId: 'm4');
    await c.create(url: 'about:blank', width: 10, height: 10);
    expect(c.mediaState.value.isCapturing, isFalse);
    expect(c.mediaState.value.setting, CefMediaSetting.ask);

    await messenger.handlePlatformMessage(
      'flutter_cef',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('mediaState', {
          'sessionId': 'm4',
          'videoActive': true,
          'audioActive': false,
          'setting': 1,
        }),
      ),
      (_) {},
    );

    expect(c.mediaState.value.videoActive, isTrue);
    expect(c.mediaState.value.isCapturing, isTrue);
    expect(c.mediaState.value.setting, CefMediaSetting.allow);
  });

  test('setMediaSetting forwards the encoded decision', () async {
    final c = CefWebController(sessionId: 'm5');
    await c.setMediaSetting(CefMediaSetting.block);
    final args =
        (log.firstWhere((m) => m.method == 'setMediaSetting').arguments as Map)
            .cast<String, dynamic>();
    expect(args['sessionId'], 'm5');
    expect(args['value'], 2);
  });

  test('session ids are unique when not supplied', () {
    expect(CefWebController().sessionId,
        isNot(equals(CefWebController().sessionId)));
  });

  test('sendPointer clamps clickCount to Chromium-legal 1..3', () async {
    final c = CefWebController(sessionId: 'sp');
    c.sendPointer(type: 1, x: 5, y: 6, clickCount: 9);
    await Future<void>.delayed(Duration.zero);
    final args = (log.firstWhere((m) => m.method == 'pointer').arguments as Map)
        .cast<String, dynamic>();
    expect(args['clickCount'], 3);
  });

  // Simulate a host -> Dart event for [sessionId].
  Future<void> emit(String sessionId, String method, Map<String, Object?> a) {
    return messenger.handlePlatformMessage(
      'flutter_cef',
      const StandardMethodCodec().encodeMethodCall(
        MethodCall(method, {'sessionId': sessionId, ...a}),
      ),
      (_) {},
    );
  }

  test('navigation + script verbs are forwarded for the session', () async {
    final c = CefWebController(sessionId: 'nav');
    await c.reload();
    await c.stop();
    await c.goBack();
    await c.goForward();
    await c.executeJavaScript('1+1');
    expect(
        log.map((m) => m.method),
        containsAll(
            ['reload', 'stop', 'goBack', 'goForward', 'executeJavaScript']));
    for (final m in log) {
      expect((m.arguments as Map)['sessionId'], 'nav');
    }
    expect(
        (log.firstWhere((m) => m.method == 'executeJavaScript').arguments
            as Map)['code'],
        '1+1');
  });

  test('loadingState event updates loading + history notifiers', () async {
    final c = CefWebController(sessionId: 'ls');
    await c.create(url: 'about:blank', width: 1, height: 1);
    await emit('ls', 'loadingState',
        {'isLoading': true, 'canGoBack': true, 'canGoForward': false});
    expect(c.isLoading.value, true);
    expect(c.canGoBack.value, true);
    expect(c.canGoForward.value, false);
  });

  test('title + url events update notifiers', () async {
    final c = CefWebController(sessionId: 'tu');
    await c.create(url: 'about:blank', width: 1, height: 1);
    await emit('tu', 'title', {'title': 'Hello'});
    await emit('tu', 'url', {'url': 'https://x.test/'});
    expect(c.title.value, 'Hello');
    expect(c.url.value, 'https://x.test/');
  });

  test('loadError event invokes the callback with a CefLoadError', () async {
    final c = CefWebController(sessionId: 'le');
    await c.create(url: 'about:blank', width: 1, height: 1);
    CefLoadError? got;
    c.onLoadError = (e) => got = e;
    await emit('le', 'loadError', {
      'code': -105,
      'url': 'https://bad.test/',
      'text': 'ERR_NAME_NOT_RESOLVED'
    });
    expect(got, isNotNull);
    expect(got!.errorCode, -105);
    expect(got!.url, 'https://bad.test/');
    expect(got!.errorText, 'ERR_NAME_NOT_RESOLVED');
  });

  test('consoleMessage event invokes the callback', () async {
    final c = CefWebController(sessionId: 'cm');
    await c.create(url: 'about:blank', width: 1, height: 1);
    CefConsoleMessage? got;
    c.onConsoleMessage = (m) => got = m;
    await emit(
        'cm', 'consoleMessage', {'level': 4, 'message': 'app.js:3\tboom'});
    expect(got!.level, 4);
    expect(got!.message, 'app.js:3\tboom');
  });

  test('page lifecycle events invoke their callbacks', () async {
    final c = CefWebController(sessionId: 'pl');
    await c.create(url: 'about:blank', width: 1, height: 1);
    final events = <String>[];
    c.onPageStarted = (u) => events.add('start:$u');
    c.onPageFinished = (u) => events.add('finish:$u');
    c.onProgress = (p) => events.add('progress:$p');
    c.onUrlChange = (u) => events.add('urlChange:$u');
    await emit('pl', 'pageStarted', {'url': 'https://a.test/'});
    await emit('pl', 'progress', {'progress': 42});
    await emit('pl', 'url', {'url': 'https://a.test/page'});
    await emit('pl', 'pageFinished', {'url': 'https://a.test/'});
    expect(events, [
      'start:https://a.test/',
      'progress:42',
      'urlChange:https://a.test/page',
      'finish:https://a.test/',
    ]);
    // The url event still drives the notifier too.
    expect(c.url.value, 'https://a.test/page');
  });

  test('newWindow event routes the popup url to onCreateWindow', () async {
    final c = CefWebController(sessionId: 'nw');
    await c.create(url: 'about:blank', width: 1, height: 1);
    String? opened;
    c.onCreateWindow = (u) => opened = u;
    await emit('nw', 'newWindow', {'url': 'https://popup.test/'});
    expect(opened, 'https://popup.test/');
  });

  test('setVisible forwards the visible flag to native (pause/resume)',
      () async {
    final c = CefWebController(sessionId: 'vis');
    await c.setVisible(false);
    await c.setVisible(true);
    final calls =
        log.where((m) => m.method == 'setVisible').toList(growable: false);
    expect(calls, hasLength(2));
    expect((calls[0].arguments as Map)['visible'], false);
    expect((calls[1].arguments as Map)['visible'], true);
    expect((calls[0].arguments as Map)['sessionId'], 'vis');
  });

  test('zoom + find + load verbs are forwarded', () async {
    final c = CefWebController(sessionId: 'b2');
    await c.setZoomLevel(1.0);
    await c.find('hello', forward: false, matchCase: true);
    await c.stopFind();
    await c.loadHtmlString('<h1>hi</h1>');
    await c.loadFile('/tmp/x.html');
    final zoom =
        log.firstWhere((m) => m.method == 'setZoomLevel').arguments as Map;
    expect(zoom['level'], 1.0);
    final find = log.firstWhere((m) => m.method == 'find').arguments as Map;
    expect(find['text'], 'hello');
    expect(find['forward'], false);
    expect(find['matchCase'], true);
    expect(log.any((m) => m.method == 'stopFind'), true);
    // loadHtmlString + loadFile are host-trusted content loads: they route
    // through `loadTrusted` (NOT `navigate`), so they bypass the scheme
    // allowlist with their data:/file: urls.
    final loads = log
        .where((m) => m.method == 'loadTrusted')
        .map((m) => (m.arguments as Map)['url'] as String)
        .toList();
    expect(loads.any((u) => u.startsWith('data:text/html')), true);
    expect(loads, contains('file:///tmp/x.html'));
    // ...and specifically NOT through the gated navigate path.
    expect(log.any((m) => m.method == 'navigate'), false);
  });

  test('loadFile on Windows turns a drive-letter path into a file:/// URL',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final c = CefWebController(sessionId: 'winfile');
    await c.loadFile(r'C:\pages\Hello World.html');
    final loads = log
        .where((m) => m.method == 'loadTrusted')
        .map((m) => (m.arguments as Map)['url'] as String);
    expect(loads, contains('file:///C:/pages/Hello%20World.html'));
  });

  test('findResult event invokes onFindResult', () async {
    final c = CefWebController(sessionId: 'fr');
    await c.create(url: 'about:blank', width: 1, height: 1);
    CefFindResult? got;
    c.onFindResult = (r) => got = r;
    await emit('fr', 'findResult',
        {'count': 5, 'activeMatchOrdinal': 2, 'isFinal': true});
    expect(got!.numberOfMatches, 5);
    expect(got!.activeMatchOrdinal, 2);
    expect(got!.isFinalUpdate, true);
  });

  test('confirm dialog routes to the handler and responds', () async {
    final c = CefWebController(sessionId: 'jd');
    await c.create(url: 'about:blank', width: 1, height: 1);
    c.onJavaScriptConfirmDialog = (req) async => false;
    await emit('jd', 'jsDialog',
        {'id': 11, 'type': 1, 'message': 'sure?', 'defaultText': ''});
    await pumpEventQueue();
    final resp =
        log.firstWhere((m) => m.method == 'respondJsDialog').arguments as Map;
    expect(resp['id'], 11);
    expect(resp['ok'], false);
  });

  test('prompt dialog returns entered text via respondJsDialog', () async {
    final c = CefWebController(sessionId: 'jp');
    await c.create(url: 'about:blank', width: 1, height: 1);
    c.onJavaScriptTextInputDialog = (req) async => 'typed-${req.defaultText}';
    await emit('jp', 'jsDialog',
        {'id': 12, 'type': 2, 'message': 'name?', 'defaultText': 'x'});
    await pumpEventQueue();
    final resp =
        log.firstWhere((m) => m.method == 'respondJsDialog').arguments as Map;
    expect(resp['ok'], true);
    expect(resp['text'], 'typed-x');
  });

  test('runJavaScriptReturningResult resolves from an evalResult event',
      () async {
    final c = CefWebController(sessionId: 'ev');
    await c.create(url: 'about:blank', width: 1, height: 1);
    final future = c.runJavaScriptReturningResult('1+1');
    final call =
        log.firstWhere((m) => m.method == 'evalReturning').arguments as Map;
    expect(call['code'], '1+1');
    await emit(
        'ev', 'evalResult', {'payload': '${call['id']}:{"ok":true,"v":2}'});
    expect(await future, 2);
  });

  test('runJavaScriptReturningResult surfaces script errors', () async {
    final c = CefWebController(sessionId: 'ee');
    await c.create(url: 'about:blank', width: 1, height: 1);
    final future = c.runJavaScriptReturningResult('boom()');
    final id = (log.firstWhere((m) => m.method == 'evalReturning').arguments
        as Map)['id'];
    // Attach the matcher before the error is delivered (else the errored future
    // is briefly unhandled).
    final expectation = expectLater(future, throwsA(isA<Exception>()));
    await emit('ee', 'evalResult',
        {'payload': '$id:{"ok":false,"v":"ReferenceError"}'});
    await expectation;
  });

  test('addJavaScriptChannel delivers channel messages', () async {
    final c = CefWebController(sessionId: 'ch');
    await c.create(url: 'about:blank', width: 1, height: 1);
    String? got;
    await c.addJavaScriptChannel('Native', onMessageReceived: (m) => got = m);
    final call = log
        .firstWhere((m) => m.method == 'addJavaScriptChannel')
        .arguments as Map;
    expect(call['name'], 'Native');
    await emit('ch', 'channelMessage', {'payload': 'Native:hello world'});
    expect(got, 'hello world');
  });

  test('a channel added BEFORE create() is re-registered on create() '
      '(call-order independence — the shared-host channel regression)', () async {
    // On a SHARED host the session attaches LATE (createBrowser is queued), so an
    // addJavaScriptChannel issued before the widget mounts reaches the host before
    // the browser exists. The controller must re-register every channel on
    // create() so the host binds it to the now-attached browser; if this re-send
    // is dropped, the window.<name> shim is never injected and page->host messages
    // die — the exact B->A Campus regression. (Native end-to-end delivery on a
    // real cef_host is covered by test/run_channel_integration.sh.)
    final c = CefWebController(sessionId: 'prech');
    await c.addJavaScriptChannel('Early', onMessageReceived: (_) {});
    log.clear();
    await c.create(url: 'about:blank', width: 1, height: 1);
    final reSent = log.where((m) =>
        m.method == 'addJavaScriptChannel' &&
        (m.arguments as Map)['name'] == 'Early');
    expect(reSent, isNotEmpty,
        reason: 'a channel registered before create() must be re-sent on create()');
  });

  test('scroll + storage conveniences forward as JavaScript', () async {
    final c = CefWebController(sessionId: 'sc');
    await c.scrollTo(0, 100);
    await c.scrollBy(5, 6);
    await c.clearLocalStorage();
    final js = log
        .where((m) => m.method == 'executeJavaScript')
        .map((m) => (m.arguments as Map)['code'] as String)
        .toList();
    expect(js, contains('window.scrollTo(0, 100)'));
    expect(js, contains('window.scrollBy(5, 6)'));
    expect(js, contains('localStorage.clear()'));
  });

  test('getScrollPosition decodes the eval result into an Offset', () async {
    final c = CefWebController(sessionId: 'gp');
    await c.create(url: 'about:blank', width: 1, height: 1);
    final f = c.getScrollPosition();
    final id = (log.firstWhere((m) => m.method == 'evalReturning').arguments
        as Map)['id'];
    await emit('gp', 'evalResult', {'payload': '$id:{"ok":true,"v":[12,34]}'});
    expect(await f, const Offset(12, 34));
  });

  test('IME verbs forward to native', () async {
    final c = CefWebController(sessionId: 'im');
    await c.imeSetComposition('文');
    await c.imeCommitText('文字');
    await c.imeCancelComposition();
    expect(
        (log.firstWhere((m) => m.method == 'imeSetComposition').arguments
            as Map)['text'],
        '文');
    expect(
        (log.firstWhere((m) => m.method == 'imeCommitText').arguments
            as Map)['text'],
        '文字');
    expect(log.any((m) => m.method == 'imeCancelComposition'), true);
  });

  test('a host imeCompositionBounds event fires onImeCompositionBounds',
      () async {
    final c = CefWebController(sessionId: 'imb');
    await c.create(url: 'about:blank', width: 10, height: 10);
    Rect? got;
    c.onImeCompositionBounds = (r) => got = r;
    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(const MethodCall('imeCompositionBounds',
          {'sessionId': 'imb', 'x': 12, 'y': 34, 'w': 2, 'h': 18})),
      (_) {},
    );
    expect(got, const Rect.fromLTWH(12, 34, 2, 18));
    await c.dispose();
  });

  test('download event invokes onDownload', () async {
    final c = CefWebController(sessionId: 'dl');
    await c.create(url: 'about:blank', width: 1, height: 1);
    String? got;
    c.onDownload = (n) => got = n;
    await emit('dl', 'download', {'suggestedName': 'file.zip'});
    expect(got, 'file.zip');
  });

  test('dispose fails pending evals and ignores later events', () async {
    final c = CefWebController(sessionId: 'dp');
    await c.create(url: 'about:blank', width: 1, height: 1);
    final f = c.runJavaScriptReturningResult('x');
    final exp = expectLater(f, throwsA(isA<StateError>()));
    await c.dispose();
    await exp;
    var called = false;
    c.onPageStarted = (_) => called = true;
    await emit('dp', 'pageStarted', {'url': 'https://late.test/'});
    expect(called, false, reason: 'events after dispose must be ignored');
  });

  test('processGone fails pending eval + cookie futures (no indefinite hang)',
      () async {
    // The host crashing is the single most likely failure; in-flight round-trips
    // have no one left to answer them and must fail, not hang forever.
    final c = CefWebController(sessionId: 'pg');
    await c.create(url: 'about:blank', width: 1, height: 1);
    final evalF = c.runJavaScriptReturningResult('slow()');
    final cookieF = c.getCookies(url: 'https://x.test/');
    final evalExp = expectLater(evalF, throwsA(isA<StateError>()));
    final cookieExp = expectLater(cookieF, throwsA(isA<StateError>()));
    String? reason;
    c.onProcessGone = (r) => reason = r;
    await emit('pg', 'processGone', {'reason': 'crashed'});
    await evalExp;
    await cookieExp;
    expect(reason, 'crashed');
  });

  test('dispose() is idempotent — a second call does not throw', () async {
    // Externally-owned controllers can be disposed twice (app + a stale view);
    // the second pass must not throw via the ValueNotifier dispose asserts.
    final c = CefWebController(sessionId: 'dd');
    await c.create(url: 'about:blank', width: 1, height: 1);
    await c.dispose();
    await expectLater(c.dispose(), completes);
  });

  test('enableAgentControl returns null on a partial native reply', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      log.add(call);
      if (call.method == 'enableAgentControl') {
        return <String, dynamic>{'wsUrl': 'ws://x', 'token': 'abc'}; // no port
      }
      return null;
    });
    final c = CefWebController(sessionId: 'acp');
    // A missing key must yield null, not an uncatchable TypeError.
    expect(await c.enableAgentControl(), isNull);
  });

  test('removeJavaScriptChannel stops delivery to the handler', () async {
    final c = CefWebController(sessionId: 'rmch');
    await c.create(url: 'about:blank', width: 1, height: 1);
    final got = <String>[];
    await c.addJavaScriptChannel('Bridge', onMessageReceived: got.add);
    await emit('rmch', 'channelMessage', {'payload': 'Bridge:one'});
    c.removeJavaScriptChannel('Bridge');
    await emit('rmch', 'channelMessage', {'payload': 'Bridge:two'});
    expect(got, ['one'], reason: 'messages after removal must be dropped');
  });

  test('processGone defaults the reason to "crashed" / passes it through',
      () async {
    final c = CefWebController(sessionId: 'pgr');
    await c.create(url: 'about:blank', width: 1, height: 1);
    String? reason;
    c.onProcessGone = (r) => reason = r;
    await emit('pgr', 'processGone', <String, Object?>{}); // no reason
    expect(reason, 'crashed');
    await emit('pgr', 'processGone', {'reason': 'locked'});
    expect(reason, 'locked');
  });

  test('paintStalled event invokes onPaintStalled', () async {
    final c = CefWebController(sessionId: 'pstall');
    await c.create(url: 'about:blank', width: 1, height: 1);
    var stalled = false;
    c.onPaintStalled = () => stalled = true;
    await emit('pstall', 'paintStalled', <String, Object?>{});
    expect(stalled, isTrue);
  });

  test('alert dialog routes to the handler and acks', () async {
    final c = CefWebController(sessionId: 'al');
    await c.create(url: 'about:blank', width: 1, height: 1);
    String? msg;
    c.onJavaScriptAlertDialog = (req) async {
      msg = req.message;
    };
    await emit('al', 'jsDialog',
        {'id': 7, 'type': 0, 'message': 'hi', 'defaultText': ''});
    await pumpEventQueue();
    expect(msg, 'hi');
    final resp =
        log.firstWhere((m) => m.method == 'respondJsDialog').arguments as Map;
    expect(resp['ok'], true);
  });

  test('addJavaScriptChannel rejects a non-identifier name', () {
    final c = CefWebController(sessionId: 'cv');
    expect(
        () =>
            c.addJavaScriptChannel("x'];alert(1)//", onMessageReceived: (_) {}),
        throwsArgumentError);
  });

  test('cookie verbs forward to native', () async {
    final c = CefWebController(sessionId: 'ck');
    await c.setCookie(
        url: 'https://x.test/',
        name: 'sid',
        value: 'abc',
        domain: 'x.test',
        secure: true,
        sameSite: CefCookieSameSite.none);
    await c.clearCookies();
    final set = log.firstWhere((m) => m.method == 'setCookie').arguments as Map;
    expect(set['name'], 'sid');
    expect(set['value'], 'abc');
    expect(set['domain'], 'x.test');
    expect(set['secure'], true);
    expect(set['httpOnly'], false);
    expect(set['sameSite'], 'none');
    expect(log.any((m) => m.method == 'clearCookies'), true);
  });

  test('getCookies resolves from a host cookies event', () async {
    final c = CefWebController(sessionId: 'ckr');
    await c.create(url: 'about:blank', width: 1, height: 1);
    final future = c.getCookies(url: 'https://x.test/');
    final visit =
        log.firstWhere((m) => m.method == 'visitCookies').arguments as Map;
    expect(visit['url'], 'https://x.test/');
    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(MethodCall('cookies', {
        'sessionId': 'ckr',
        'id': visit['id'],
        'json': '[{"name":"sid","value":"abc","domain":"x.test","path":"/",'
            '"secure":true,"httpOnly":false,"sameSite":"none"}]',
      })),
      (_) {},
    );
    final cookies = await future;
    expect(cookies, hasLength(1));
    expect(cookies.single.name, 'sid');
    expect(cookies.single.value, 'abc');
    expect(cookies.single.secure, isTrue);
    expect(cookies.single.sameSite, CefCookieSameSite.none);
    await c.dispose();
  });

  test('deleteCookie + openDevTools forward to native', () async {
    final c = CefWebController(sessionId: 'ckd');
    await c.deleteCookie(url: 'https://x.test/', name: 'sid');
    await c.openDevTools();
    final del =
        log.firstWhere((m) => m.method == 'deleteCookie').arguments as Map;
    expect(del['url'], 'https://x.test/');
    expect(del['name'], 'sid');
    expect(log.any((m) => m.method == 'showDevTools'), isTrue);
  });

  test('showEmojiPicker forwards to native', () async {
    final c = CefWebController(sessionId: 'emo');
    await c.showEmojiPicker();
    final m = log.firstWhere((m) => m.method == 'showEmojiPicker');
    expect((m.arguments as Map)['sessionId'], 'emo');
  });

  // ── Added coverage: UTF-8 trusted load + defensive decode/fan-out paths.
  //    All headless (mock channel + emit). ──

  test('loadHtmlString base64-encodes via UTF-8 and round-trips intact',
      () async {
    final c = CefWebController(sessionId: 'html');
    const html = '<p>héllo 世界 🎉</p>';
    await c.loadHtmlString(html);
    final url = (log.firstWhere((m) => m.method == 'loadTrusted').arguments
        as Map)['url'] as String;
    expect(url, startsWith('data:text/html'));
    expect(url, contains('base64,'));
    final b64 = url.split('base64,').last;
    expect(utf8.decode(base64Decode(b64)), html,
        reason: 'Latin-1 encoding would mangle non-ASCII before the data: URL');
  });

  test('getScrollPosition falls back to Offset.zero on a non-list result',
      () async {
    final c = CefWebController(sessionId: 'gpz');
    await c.create(url: 'about:blank', width: 1, height: 1);
    final f = c.getScrollPosition();
    final id = (log.firstWhere((m) => m.method == 'evalReturning').arguments
        as Map)['id'];
    await emit('gpz', 'evalResult', {'payload': '$id:{"ok":true,"v":"nope"}'});
    expect(await f, Offset.zero);
  });

  test('a navigation (pageStarted) fails any in-flight eval future', () async {
    final c = CefWebController(sessionId: 'nav-fail');
    await c.create(url: 'about:blank', width: 1, height: 1);
    final f = c.runJavaScriptReturningResult('slow()');
    final pending = expectLater(f, throwsA(anything));
    await emit('nav-fail', 'pageStarted', {'url': 'https://next.test/'});
    await pending;
  });

  test('an event for an unknown / disposed session is dropped, not thrown',
      () async {
    // No controller is registered for 'ghost'; the global handler must ignore
    // it rather than crash (which would break every other live controller).
    await expectLater(emit('ghost', 'title', {'title': 'x'}), completes);
  });

  test('channel message body keeps colons after the first separator',
      () async {
    final c = CefWebController(sessionId: 'chc');
    await c.create(url: 'about:blank', width: 1, height: 1);
    String? got;
    await c.addJavaScriptChannel('Bridge', onMessageReceived: (m) => got = m);
    await emit('chc', 'channelMessage', {'payload': 'Bridge:ts=12:30:00'});
    expect(got, 'ts=12:30:00',
        reason: 'split-once on ":" — a split-all would truncate to "ts=12"');
  });

  test('create() throttles concurrent spawns to maxConcurrentCreates', () async {
    CefWebController.maxConcurrentCreates = 1;
    CefWebController.spawnSpacing = Duration.zero; // deterministic: no spacing
    addTearDown(() {
      CefWebController.maxConcurrentCreates = 3;
      CefWebController.spawnSpacing = const Duration(milliseconds: 120);
    });
    var creates = 0;
    final gate = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'create') {
        creates++;
        await gate.future; // hold the first spawn open
        return <String, dynamic>{'textureId': 1};
      }
      return null;
    });
    final f1 =
        CefWebController(sessionId: 'a').create(url: 'about:blank', width: 1, height: 1);
    final f2 =
        CefWebController(sessionId: 'b').create(url: 'about:blank', width: 1, height: 1);
    await pumpEventQueue();
    expect(creates, 1, reason: 'the 2nd spawn waits behind the 1st (cap = 1)');
    gate.complete();
    await Future.wait([f1, f2]);
    expect(creates, 2, reason: 'the 2nd spawn proceeds once a slot frees');
  });

  test('under contention a queued spawn is spaced after the prior one frees',
      () async {
    CefWebController.maxConcurrentCreates = 1;
    CefWebController.spawnSpacing = const Duration(milliseconds: 80);
    addTearDown(() {
      CefWebController.maxConcurrentCreates = 3;
      CefWebController.spawnSpacing = const Duration(milliseconds: 120);
    });
    final starts = <int>[];
    final sw = Stopwatch()..start();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'create') {
        starts.add(sw.elapsedMilliseconds);
        return <String, dynamic>{'textureId': 1};
      }
      return null;
    });
    // First create resolves immediately; the second is queued (cap=1) and must
    // wait ~spawnSpacing after the first frees before it starts.
    await Future.wait([
      CefWebController(sessionId: 'x')
          .create(url: 'about:blank', width: 1, height: 1),
      CefWebController(sessionId: 'y')
          .create(url: 'about:blank', width: 1, height: 1),
    ]);
    expect(starts, hasLength(2));
    expect(starts[1] - starts[0], greaterThanOrEqualTo(70),
        reason: 'the 2nd spawn is spaced (~80ms) after the 1st, not back-to-back');
  });

  test('a lone create() (no contention) is never delayed by spacing', () async {
    CefWebController.spawnSpacing = const Duration(seconds: 5); // huge, but…
    addTearDown(
        () => CefWebController.spawnSpacing = const Duration(milliseconds: 120));
    final sw = Stopwatch()..start();
    await CefWebController(sessionId: 'solo')
        .create(url: 'about:blank', width: 1, height: 1);
    expect(sw.elapsedMilliseconds, lessThan(1000),
        reason: 'spacing only applies under contention — a single spawn returns '
            'immediately and never waits the gap');
  });

  // ── context menu ────────────────────────────────────────────────────────
  //
  // The invariant under test is "answer exactly once". CEF requires the menu
  // callback be continued or cancelled; a dropped answer wedges the page's menu
  // handling so later right-clicks are silently ignored. So every path — chosen,
  // dismissed, no handler, throwing handler — must produce one
  // chooseContextMenu.

  Future<void> sendContextMenu(String json, {int id = 1}) =>
      messenger.handlePlatformMessage(
        'flutter_cef',
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('contextMenu', {
            'sessionId': 'cm',
            'id': id,
            'json': json,
          }),
        ),
        (_) {},
      );

  test('a chosen context-menu command is sent back', () async {
    final c = CefWebController(sessionId: 'cm');
    await c.create(url: 'about:blank', width: 10, height: 10);
    CefContextMenuRequest? seen;
    c.onContextMenu = (req) async {
      seen = req;
      return 101;
    };
    log.clear();

    await sendContextMenu(jsonEncode({
      'x': 12,
      'y': 34,
      'editable': true,
      'linkUrl': 'https://example.com/a',
      'sourceUrl': '',
      'selectionText': 'picked text',
      'misspelledWord': 'teh',
      'items': [
        {
          'type': 'command',
          'label': 'Back',
          'commandId': 100,
          'enabled': false,
          'checked': false,
        },
        {'type': 'separator'},
        {
          'type': 'command',
          'label': 'Copy',
          'commandId': 101,
          'enabled': true,
          'checked': false,
        },
        {
          'type': 'submenu',
          'label': 'Spelling',
          'commandId': 0,
          'enabled': true,
          'checked': false,
          'items': [
            {
              'type': 'command',
              'label': 'the',
              'commandId': 200,
              'enabled': true,
              'checked': false,
            },
          ],
        },
      ],
    }));

    // Chromium's own state survives the round trip — Back disabled, the
    // separator kept so grouping is drawable, the submenu nested.
    expect(seen, isNotNull);
    expect(seen!.x, 12);
    expect(seen!.editable, isTrue);
    expect(seen!.linkUrl, 'https://example.com/a');
    expect(seen!.selectionText, 'picked text');
    expect(seen!.misspelledWord, 'teh');
    expect(seen!.items, hasLength(4));
    expect(seen!.items[0].enabled, isFalse);
    expect(seen!.items[1].type, CefContextMenuItemType.separator);
    expect(seen!.items[3].type, CefContextMenuItemType.submenu);
    expect(seen!.items[3].items.single.commandId, 200);

    final call = log.singleWhere((m) => m.method == 'chooseContextMenu');
    final args = (call.arguments as Map).cast<String, dynamic>();
    expect(args['id'], 1);
    expect(args['commandId'], 101);
  });

  test('returning null dismisses rather than dropping the callback', () async {
    final c = CefWebController(sessionId: 'cm');
    await c.create(url: 'about:blank', width: 10, height: 10);
    c.onContextMenu = (_) async => null;
    log.clear();

    await sendContextMenu('{"items":[]}');

    final args = (log
            .singleWhere((m) => m.method == 'chooseContextMenu')
            .arguments as Map)
        .cast<String, dynamic>();
    expect(args['commandId'], 0);
  });

  test('no handler still answers (dismiss), so the menu is not wedged',
      () async {
    final c = CefWebController(sessionId: 'cm');
    await c.create(url: 'about:blank', width: 10, height: 10);
    log.clear();

    await sendContextMenu('{"items":[]}');

    final args = (log
            .singleWhere((m) => m.method == 'chooseContextMenu')
            .arguments as Map)
        .cast<String, dynamic>();
    expect(args['commandId'], 0);
  });

  test('a throwing handler is reported and still answers', () async {
    final c = CefWebController(sessionId: 'cm');
    await c.create(url: 'about:blank', width: 10, height: 10);
    c.onContextMenu = (_) async => throw StateError('boom');
    log.clear();

    final errors = <Object>[];
    final prior = FlutterError.onError;
    FlutterError.onError = (d) => errors.add(d.exception);
    try {
      await sendContextMenu('{"items":[]}');
    } finally {
      FlutterError.onError = prior;
    }

    expect(errors.single, isA<StateError>());
    final args = (log
            .singleWhere((m) => m.method == 'chooseContextMenu')
            .arguments as Map)
        .cast<String, dynamic>();
    expect(args['commandId'], 0);
  });

  test('malformed menu json is reported and answered, never silent', () async {
    final c = CefWebController(sessionId: 'cm');
    await c.create(url: 'about:blank', width: 10, height: 10);
    c.onContextMenu = (_) async => 5;
    log.clear();

    final errors = <Object>[];
    final prior = FlutterError.onError;
    FlutterError.onError = (d) => errors.add(d.exception);
    try {
      await sendContextMenu('not json at all');
    } finally {
      FlutterError.onError = prior;
    }

    expect(errors, isNotEmpty);
    final args = (log
            .singleWhere((m) => m.method == 'chooseContextMenu')
            .arguments as Map)
        .cast<String, dynamic>();
    expect(args['commandId'], 0);
  });
}
