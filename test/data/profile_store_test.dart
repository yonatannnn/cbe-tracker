// Profiles: one folder of books per name, the first name keeping the root.

import 'dart:io';

import 'package:cbe_tracker/data/profiles/profile_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late ProfileStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cbe_profiles');
    store = ProfileStore(root);
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('an empty install has no profiles and nobody active', () {
    final registry = store.load();
    expect(registry.isEmpty, isTrue);
    expect(registry.active, isNull);
  });

  test(
    'the first user adopts the root, so pre-profile books are kept',
    () async {
      final registry = await store.enter(const ProfileRegistry(), 'Almaz');
      final almaz = registry.active!;
      expect(almaz.name, 'Almaz');
      expect(almaz.isRoot, isTrue);
      expect(store.directoryOf(almaz).path, root.path);
    },
  );

  test('a second user gets a folder of her own', () async {
    var registry = await store.enter(const ProfileRegistry(), 'Almaz');
    registry = await store.enter(registry, 'Bethel');
    final bethel = registry.active!;
    expect(bethel.isRoot, isFalse);
    expect(bethel.dir, startsWith('profiles/'));
    expect(store.directoryOf(bethel).existsSync(), isTrue);
    expect(registry.profiles.length, 2);
  });

  test('entering an existing name signs that user in, ignoring case', () async {
    var registry = await store.enter(const ProfileRegistry(), 'Almaz');
    final almazId = registry.active!.id;
    registry = await store.enter(registry, 'Bethel');
    registry = await store.enter(registry, '  almaz ');
    expect(registry.active!.id, almazId);
    expect(registry.profiles.length, 2, reason: 'no duplicate books');
  });

  test('the registry survives a reload', () async {
    var registry = await store.enter(const ProfileRegistry(), 'Almaz');
    registry = await store.enter(registry, 'Bethel');
    await store.switchTo(registry, registry.profiles.first.id);

    final again = ProfileStore(root).load();
    expect(again.profiles.map((p) => p.name), ['Almaz', 'Bethel']);
    expect(again.active!.name, 'Almaz');
  });

  test('a blank name is refused', () {
    expect(
      () => store.enter(const ProfileRegistry(), '   '),
      throwsArgumentError,
    );
  });

  test('a damaged registry file loads as empty rather than crashing', () {
    store.file.writeAsStringSync('{not json');
    expect(store.load().isEmpty, isTrue);
  });

  test('signing out keeps every profile and clears who is active', () async {
    var registry = await store.enter(const ProfileRegistry(), 'Almaz');
    registry = await store.enter(registry, 'Bethel');

    registry = await store.signOut(registry);
    expect(registry.active, isNull);
    expect(registry.profiles.map((p) => p.name), ['Almaz', 'Bethel']);

    // Survives a reload, and signing back in finds the same books.
    final again = ProfileStore(root).load();
    expect(again.active, isNull);
    final back = await store.enter(again, 'almaz');
    expect(back.active!.name, 'Almaz');
    expect(back.active!.isRoot, isTrue);
  });
}
