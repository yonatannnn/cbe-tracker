/// User profiles: who the books belong to, and where each user's data lives.
///
/// The app asks for a name on first open and files EVERYTHING under it — the
/// database and the screenshot evidence. Two users on one phone therefore
/// never share a table, a balance or an image: each profile is its own
/// directory with its own `cbe_tracker.sqlite` and `screenshots/` inside.
///
/// Pure Dart. The registry is a tiny JSON file at the root of the app's
/// documents directory, because the choice of database has to be made BEFORE
/// any database is open — it can't live in the settings table.
library;

import 'dart:convert';
import 'dart:io';

import '../../core/ids.dart';

/// One user of the app.
class Profile {
  const Profile({required this.id, required this.name, required this.dir});

  final String id;

  /// The name she typed on the welcome screen, trimmed.
  final String name;

  /// Directory holding this profile's data, RELATIVE to the documents root.
  ///
  /// Empty for the very first profile: that one adopts the root itself, so the
  /// books an install kept before profiles existed become the first user's
  /// books instead of vanishing behind a new folder.
  final String dir;

  bool get isRoot => dir.isEmpty;

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'dir': dir};

  static Profile? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    final dir = raw['dir'];
    if (id is! String || name is! String || dir is! String) return null;
    return Profile(id: id, name: name, dir: dir);
  }
}

/// The registry: every profile plus which one is signed in.
class ProfileRegistry {
  const ProfileRegistry({this.profiles = const [], this.activeId});

  final List<Profile> profiles;
  final String? activeId;

  Profile? get active {
    for (final p in profiles) {
      if (p.id == activeId) return p;
    }
    return null;
  }

  bool get isEmpty => profiles.isEmpty;

  /// Case-insensitive name lookup — "abebe" and "Abebe" are one person, not
  /// two sets of books.
  Profile? byName(String name) {
    final key = _nameKey(name);
    for (final p in profiles) {
      if (_nameKey(p.name) == key) return p;
    }
    return null;
  }

  static String _nameKey(String name) => name.trim().toLowerCase();

  ProfileRegistry copyWith({List<Profile>? profiles, String? activeId}) =>
      ProfileRegistry(
        profiles: profiles ?? this.profiles,
        activeId: activeId ?? this.activeId,
      );

  /// Nobody signed in; every profile and its data stay on disk.
  ProfileRegistry signedOut() => ProfileRegistry(profiles: profiles);

  Map<String, Object?> toJson() => {
    'active': activeId,
    'profiles': [for (final p in profiles) p.toJson()],
  };

  static ProfileRegistry fromJson(Object? raw) {
    if (raw is! Map) return const ProfileRegistry();
    final list = raw['profiles'];
    final profiles = <Profile>[
      if (list is List)
        for (final item in list) ?Profile.fromJson(item),
    ];
    final active = raw['active'];
    return ProfileRegistry(
      profiles: profiles,
      activeId: active is String ? active : null,
    );
  }
}

/// Reads and writes the registry file.
class ProfileStore {
  ProfileStore(this.rootDir);

  /// The app documents directory. Profiles live under it.
  final Directory rootDir;

  static const String fileName = 'profiles.json';
  static const String profilesSubdir = 'profiles';

  File get file => File('${rootDir.path}/$fileName');

  /// Synchronous on purpose: it runs once at startup, before the router can
  /// decide where to send her, and the file is a few hundred bytes.
  ProfileRegistry load() {
    try {
      if (!file.existsSync()) return const ProfileRegistry();
      return ProfileRegistry.fromJson(jsonDecode(file.readAsStringSync()));
    } on Object {
      // A damaged registry must not brick the app: she gets the welcome
      // screen again, and her data directories are still on disk.
      return const ProfileRegistry();
    }
  }

  Future<void> save(ProfileRegistry registry) async {
    if (!rootDir.existsSync()) await rootDir.create(recursive: true);
    // Write-then-rename so a crash mid-write leaves the old file, not half a
    // JSON document.
    final staged = File('${file.path}.tmp');
    await staged.writeAsString(jsonEncode(registry.toJson()), flush: true);
    await staged.rename(file.path);
  }

  /// The absolute directory a profile's data lives in.
  Directory directoryOf(Profile profile) =>
      profile.isRoot ? rootDir : Directory('${rootDir.path}/${profile.dir}');

  /// Signs in as [name]: switches to the existing profile with that name, or
  /// creates one. The first profile ever created takes the root directory so
  /// pre-existing books are kept (see [Profile.dir]).
  Future<ProfileRegistry> enter(ProfileRegistry current, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw ArgumentError.value(name, 'name', 'is empty');

    final existing = current.byName(trimmed);
    if (existing != null) {
      final next = current.copyWith(activeId: existing.id);
      await save(next);
      return next;
    }

    final id = uuidV4();
    final rootTaken = current.profiles.any((p) => p.isRoot);
    final profile = Profile(
      id: id,
      name: trimmed,
      dir: rootTaken ? '$profilesSubdir/$id' : '',
    );
    await directoryOf(profile).create(recursive: true);

    final next = ProfileRegistry(
      profiles: [...current.profiles, profile],
      activeId: id,
    );
    await save(next);
    return next;
  }

  /// Signs the current user out. Her books are untouched — she, or anyone,
  /// signs back in from the welcome screen.
  Future<ProfileRegistry> signOut(ProfileRegistry current) async {
    final next = current.signedOut();
    await save(next);
    return next;
  }

  Future<ProfileRegistry> switchTo(ProfileRegistry current, String id) async {
    if (!current.profiles.any((p) => p.id == id)) {
      throw ArgumentError.value(id, 'id', 'unknown profile');
    }
    final next = current.copyWith(activeId: id);
    await save(next);
    return next;
  }
}
