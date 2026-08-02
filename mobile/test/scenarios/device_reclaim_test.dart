/// Reclaim a known server device_id after prefs wipe / reinstall.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestCatalogHarness harness;

  tearDown(() async {
    await harness.close();
  });

  test('reclaim switches device_id and re-registers', () async {
    const oldId = 'd1';
    const reclaimId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
    var registered = <String>[];

    harness = await TestCatalogHarness.open(
      MockClient((request) async {
        if (request.method == 'POST' && request.url.path.endsWith('/devices')) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          registered.add(body['device_id'] as String);
          return http.Response(
            jsonEncode({
              'device_id': body['device_id'],
              'name': body['name'],
              'kind': body['kind'] ?? 'android',
              'created_at': '2026-08-03T00:00:00Z',
              'last_seen_at': '2026-08-03T00:00:00Z',
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'GET' &&
            request.url.path.endsWith('/devices') &&
            !request.url.path.contains('/devices/')) {
          return http.Response(
            jsonEncode([
              {
                'device_id': reclaimId,
                'name': 'pixel-old',
                'kind': 'android',
                'created_at': '2026-07-01T00:00:00Z',
                'last_seen_at': '2026-08-01T00:00:00Z',
              },
              {
                'device_id': oldId,
                'name': 'android',
                'kind': 'android',
                'created_at': '2026-08-03T00:00:00Z',
                'last_seen_at': '2026-08-03T00:00:00Z',
              },
            ]),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'GET' &&
            request.url.path.contains('/catalog/delta')) {
          return http.Response(
            '''
{
  "next_cursor": "",
  "files": [],
  "tags": [],
  "file_tags": [],
  "paths": [],
  "availability": [
    {"file_id":"f1","device_id":"$reclaimId","mode":"pinned","updated_at":"a"}
  ]
}
''',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('unexpected ${request.method} ${request.url}', 500);
      }),
    );

    // Fixture identity seeds d1 via settings.
    expect(await harness.identity.ensureDeviceId(), oldId);
    expect((await harness.sync.sync()).ok, isTrue);
    expect(registered, contains(oldId));

    final devices = await harness.api.listDevices();
    expect(devices.map((d) => d.deviceId), containsAll([reclaimId, oldId]));

    final result = await harness.sync.reclaimDevice(reclaimId);
    expect(result.ok, isTrue);
    expect(harness.identity.currentDeviceId, reclaimId);
    expect(registered.last, reclaimId);
    expect(registered, containsAll([oldId, reclaimId]));
  });

  test('resetDeviceIdentity mints a new id', () async {
    harness = await TestCatalogHarness.open(
      MockClient((request) async {
        if (request.method == 'POST' && request.url.path.endsWith('/devices')) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'device_id': body['device_id'],
              'name': body['name'] ?? 'android',
              'kind': 'android',
              'created_at': '2026-08-03T00:00:00Z',
              'last_seen_at': '2026-08-03T00:00:00Z',
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'GET' &&
            request.url.path.contains('/catalog/delta')) {
          return http.Response(
            '{"next_cursor":"","files":[],"tags":[],"file_tags":[],"paths":[],"availability":[]}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('unexpected', 500);
      }),
    );

    final before = await harness.identity.ensureDeviceId();
    final result = await harness.sync.resetDeviceIdentity();
    expect(result.ok, isTrue);
    expect(harness.identity.currentDeviceId, isNot(before));
    expect(harness.identity.currentDeviceId, isNotNull);
  });
}
