import 'dart:io';

import 'package:copymanga_reader/services/copy_device_identity.dart';
import 'package:copymanga_reader/services/local_app_database.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  const channel = MethodChannel(
    'com.othbradar.copymangareader/device_identity',
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory temp;
  late LocalAppDatabase db;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('reader-identity-test-');
    db = LocalAppDatabase(
      factory: databaseFactoryFfi,
      supportDirectoryProvider: () async => temp,
    );
    await db.open();
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => {
        'device': 'Fixture',
        'deviceInfo': 'Fixture-fixture_device',
        'platformId': 'BUILD.FIXTURE.001',
      },
    );
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await db.close();
    await temp.delete(recursive: true);
  });

  test(
    'own persistent base62 pseudoID survives restart and simultaneous loads',
    () async {
      final identities = await Future.wait(
        List.generate(5, (_) => CopyDeviceIdentityService.load(db)),
      );
      final id = identities.first;
      expect(id.isReady, isTrue);
      expect(id.androidId, 'BUILD.FIXTURE.001');
      expect(id.deviceInfo, 'Fixture-fixture_device');
      expect(id.pseudoId, matches(RegExp(r'^[0-9a-zA-Z]{16}$')));
      expect(identities.map((x) => x.pseudoId).toSet(), {id.pseudoId});
      await db.close();
      await db.open();
      expect((await CopyDeviceIdentityService.load(db)).pseudoId, id.pseudoId);
    },
  );

  test(
    'portable app backup never copies installation identity between devices',
    () async {
      final first = await CopyDeviceIdentityService.load(db);
      final backup = File('${temp.path}/portable.db');
      await db.exportPortableBackup(backup, libraryKey: 'source-library');
      final other = LocalAppDatabase(
        factory: databaseFactoryFfi,
        supportDirectoryProvider: () async => Directory('${temp.path}/other'),
      );
      await other.open();
      try {
        final second = await CopyDeviceIdentityService.load(other);
        expect(first.pseudoId, isNot(second.pseudoId));
        await other.importPortableBackup(backup, libraryKey: 'target-library');
        expect(
          (await CopyDeviceIdentityService.load(other)).pseudoId,
          second.pseudoId,
        );
        final copy = await databaseFactoryFfi.openDatabase(
          backup.path,
          options: OpenDatabaseOptions(readOnly: true),
        );
        try {
          expect(await copy.rawQuery('SELECT * FROM device_identity'), isEmpty);
        } finally {
          await copy.close();
        }
      } finally {
        await other.close();
      }
    },
  );

  test(
    'native failure produces an invalid identity, never shared zero values',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(code: 'unavailable'),
      );
      final id = await CopyDeviceIdentityService.load(db);
      expect(id.isReady, isFalse);
      expect(id.androidId, isEmpty);
      expect(id.pseudoId, isEmpty);
    },
  );
}
