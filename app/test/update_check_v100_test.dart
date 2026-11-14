import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ipchakra/services/update_service.dart';
import 'package:ipchakra/widgets/update_dialog.dart';

// Tests for the v1.0.0 in-app updater (Shiv's request): Settings →
// Check for update asks GitHub for the latest release, compares
// its tag with the running build, and — when a newer release
// carries an APK — downloads it into the app cache and hands it
// to the system installer through the FileProvider channel.
// The check never lies: up-to-date, available and failed checks
// each say what they are, and a release with no APK offers its
// release page instead of a download button.

String _releaseJson({
  String tag = 'v1.0.1',
  List<Map<String, String>>? assets,
  String body = 'Fixes and improvements.',
}) {
  return jsonEncode({
    'tag_name': tag,
    'name': 'IPChakra $tag',
    'body': body,
    'html_url': 'https://github.com/shivytyahoo/IPChakra/releases/tag/$tag',
    'assets': assets ??
        [
          {
            'name': 'IPChakra-$tag.apk',
            'browser_download_url':
                'https://github.com/shivytyahoo/IPChakra/releases/download/$tag/IPChakra-$tag.apk',
          },
        ],
  });
}

void main() {
  group('isNewerVersion', () {
    test('numeric parts compare numerically, not lexicographically', () {
      expect(UpdateService.isNewerVersion('1.10.0', '1.9.0'), isTrue);
      expect(UpdateService.isNewerVersion('1.9.0', '1.10.0'), isFalse);
      expect(UpdateService.isNewerVersion('2.0.0', '1.9.9'), isTrue);
      expect(UpdateService.isNewerVersion('1.0.1', '1.0.0'), isTrue);
      expect(UpdateService.isNewerVersion('1.1.0', '1.0.9'), isTrue);
    });

    test('equal versions are not newer, with or without a v prefix', () {
      expect(UpdateService.isNewerVersion('1.0.0', '1.0.0'), isFalse);
      expect(UpdateService.isNewerVersion('v1.0.0', '1.0.0'), isFalse);
      expect(UpdateService.isNewerVersion('1.0.0', 'v1.0.0'), isFalse);
      expect(UpdateService.isNewerVersion('1.0', '1.0.0'), isFalse);
    });

    test('an older tag is not newer', () {
      expect(UpdateService.isNewerVersion('0.9.9', '1.0.0'), isFalse);
      expect(UpdateService.isNewerVersion('1.0.0', '1.0.1'), isFalse);
    });

    test('a pre-release is older than the same numbers released', () {
      expect(UpdateService.isNewerVersion('1.0.0-beta', '1.0.0'), isFalse);
      expect(UpdateService.isNewerVersion('1.0.0', '1.0.0-beta'), isTrue);
    });
  });

  group('checkForUpdate', () {
    test('a newer release with an APK is available, fields parsed', () async {
      final client = MockClient((request) async {
        expect(request.headers['User-Agent'], 'IPChakra',
            reason: 'GitHub requires a User-Agent on API calls');
        return http.Response(
          _releaseJson(
            tag: 'v1.0.1',
            assets: [
              {'name': 'notes.txt', 'browser_download_url': 'https://x/notes'},
              {
                'name': 'IPChakra-v1.0.1.apk',
                'browser_download_url':
                    'https://github.com/x/IPChakra-v1.0.1.apk',
              },
            ],
          ),
          200,
        );
      });
      final service =
          UpdateService(client: client, currentVersion: '1.0.0');
      final result = await service.checkForUpdate();
      expect(result.status, UpdateCheckStatus.available);
      expect(result.latestVersion, '1.0.1');
      expect(result.releaseName, 'IPChakra v1.0.1');
      expect(result.releaseNotes, 'Fixes and improvements.');
      expect(result.apkUrl,
          'https://github.com/x/IPChakra-v1.0.1.apk',
          reason: 'the .apk asset is picked, not the first asset');
      expect(result.releaseUrl, contains('/releases/tag/v1.0.1'));
    });

    test('the running version is up to date', () async {
      final client = MockClient(
          (_) async => http.Response(_releaseJson(tag: 'v1.0.0'), 200));
      final service =
          UpdateService(client: client, currentVersion: '1.0.0');
      final result = await service.checkForUpdate();
      expect(result.status, UpdateCheckStatus.upToDate);
      expect(result.latestVersion, '1.0.0');
    });

    test('an older tag is up to date too', () async {
      final client = MockClient(
          (_) async => http.Response(_releaseJson(tag: 'v0.9.9'), 200));
      final service =
          UpdateService(client: client, currentVersion: '1.0.0');
      expect((await service.checkForUpdate()).status,
          UpdateCheckStatus.upToDate);
    });

    test('a newer release with no APK is available but has no download',
        () async {
      final client = MockClient((_) async => http.Response(
          _releaseJson(tag: 'v1.0.2', assets: []), 200));
      final service =
          UpdateService(client: client, currentVersion: '1.0.0');
      final result = await service.checkForUpdate();
      expect(result.status, UpdateCheckStatus.available);
      expect(result.apkUrl, isNull,
          reason: 'no APK asset — the dialog must offer the page, '
              'not a download button');
      expect(result.releaseUrl, isNotNull);
    });

    test('GitHub errors become error results, never throws', () async {
      for (final code in [404, 500, 403]) {
        final client = MockClient(
            (_) async => http.Response('{"message":"nope"}', code));
        final service =
            UpdateService(client: client, currentVersion: '1.0.0');
        final result = await service.checkForUpdate();
        expect(result.status, UpdateCheckStatus.error);
        expect(result.message, isNotEmpty);
      }
      final badJson = MockClient((_) async => http.Response('not json', 200));
      expect(
          (await UpdateService(client: badJson, currentVersion: '1.0.0')
                  .checkForUpdate())
              .status,
          UpdateCheckStatus.error);
      final throwing = MockClient((_) async => throw const SocketException(
          'Failed host lookup'));
      expect(
          (await UpdateService(client: throwing, currentVersion: '1.0.0')
                  .checkForUpdate())
              .status,
          UpdateCheckStatus.error);
    });
  });

  group('downloadApk', () {
    test('writes the bytes to the updates cache and reports progress',
        () async {
      final bytes = Uint8List.fromList(List.generate(1024, (i) => i % 256));
      final client = MockClient((_) async => http.Response.bytes(
            bytes,
            200,
            headers: {'content-length': '${bytes.length}'},
          ));
      final service =
          UpdateService(client: client, currentVersion: '1.0.0');
      final seen = <double>[];
      final path = await service.downloadApk(
        'https://github.com/x/IPChakra-v1.0.1.apk',
        '1.0.1',
        onProgress: seen.add,
      );
      expect(path, isNotNull);
      final file = File(path!);
      expect(await file.exists(), isTrue);
      expect(await file.readAsBytes(), bytes);
      expect(path, contains('updates/IPChakra-v1.0.1.apk'));
      expect(seen, isNotEmpty);
      expect(seen.last, 1.0);
      await file.delete();
    });

    test('a non-200 download returns null', () async {
      final client =
          MockClient((_) async => http.Response('gone', 404));
      final service =
          UpdateService(client: client, currentVersion: '1.0.0');
      expect(
          await service.downloadApk('https://github.com/x/a.apk', '1.0.1'),
          isNull);
    });
  });

  group('installApk / openUrl channel', () {
    const channel = MethodChannel('ipchakra/app_update');
    late TestDefaultBinaryMessenger messenger;

    setUp(() {
      messenger = TestDefaultBinaryMessengerBinding.instance
          .defaultBinaryMessenger;
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
    });

    test('true from the platform comes back true, null comes back false',
        () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'installApk') {
          expect((call.arguments as Map)['path'], '/tmp/a.apk');
          return true;
        }
        return null;
      });
      final service = UpdateService(currentVersion: '1.0.0');
      expect(await service.installApk('/tmp/a.apk'), isTrue);
      expect(await service.openUrl('https://example.com'), isFalse);
    });

    test('a platform exception becomes false, never a throw', () async {
      messenger.setMockMethodCallHandler(
          channel, (_) async => throw PlatformException(code: 'NO'));
      final service = UpdateService(currentVersion: '1.0.0');
      expect(await service.installApk('/tmp/a.apk'), isFalse);
      expect(await service.openUrl('https://example.com'), isFalse);
    });
  });

  group('UpdateAvailableDialog', () {
    late _FakeUpdateService fake;

    setUp(() {
      fake = _FakeUpdateService();
    });

    Future<void> pumpDialog(
      WidgetTester tester, {
      UpdateCheckResult? result,
    }) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => UpdateAvailableDialog(
                  result: result ??
                      const UpdateCheckResult.available(
                        latestVersion: '1.0.1',
                        releaseName: 'IPChakra v1.0.1',
                        releaseNotes: 'Faster connects.',
                        apkUrl: 'https://github.com/x/IPChakra-v1.0.1.apk',
                        releaseUrl:
                            'https://github.com/shivytyahoo/IPChakra/releases/tag/v1.0.1',
                      ),
                  service: fake,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('Download & install downloads, then opens the installer',
        (tester) async {
      await pumpDialog(tester);
      expect(find.text('Update available — v1.0.1'), findsOneWidget);
      expect(find.text('Faster connects.'), findsOneWidget);
      await tester.tap(find.text('Download & install'));
      await tester.pumpAndSettle();
      expect(fake.installCalls, ['/tmp/IPChakra-v1.0.1.apk']);
      expect(find.text('Installer opened — tap Install to update.'),
          findsOneWidget);
    });

    testWidgets('a failed download stays in the dialog with Retry',
        (tester) async {
      fake.failDownload = true;
      await pumpDialog(tester);
      await tester.tap(find.text('Download & install'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Download failed'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(fake.installCalls, isEmpty);
      fake.failDownload = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(fake.installCalls, ['/tmp/IPChakra-v1.0.1.apk']);
    });

    testWidgets('no APK asset means no download button, View release works',
        (tester) async {
      await pumpDialog(
        tester,
        result: const UpdateCheckResult.available(
          latestVersion: '1.0.2',
          releaseName: 'IPChakra v1.0.2',
          apkUrl: null,
          releaseUrl:
              'https://github.com/shivytyahoo/IPChakra/releases/tag/v1.0.2',
        ),
      );
      expect(find.text('Download & install'), findsNothing);
      await tester.tap(find.text('View release'));
      await tester.pumpAndSettle();
      expect(fake.openedUrls, [
        'https://github.com/shivytyahoo/IPChakra/releases/tag/v1.0.2',
      ]);
    });
  });
}

/// Fake updater for the dialog tests: download is a canned path,
/// install/open are recorded, nothing touches the network or the
/// platform channel.
class _FakeUpdateService extends UpdateService {
  _FakeUpdateService()
      : super(
          client: MockClient((_) async => http.Response('', 404)),
          currentVersion: '1.0.0',
        );

  bool failDownload = false;
  final installCalls = <String>[];
  final openedUrls = <String>[];

  @override
  Future<String?> downloadApk(
    String apkUrl,
    String version, {
    void Function(double progress)? onProgress,
  }) async {
    if (failDownload) return null;
    onProgress?.call(1.0);
    return '/tmp/IPChakra-v$version.apk';
  }

  @override
  Future<bool> installApk(String path) async {
    installCalls.add(path);
    return true;
  }

  @override
  Future<bool> openUrl(String url) async {
    openedUrls.add(url);
    return true;
  }
}
