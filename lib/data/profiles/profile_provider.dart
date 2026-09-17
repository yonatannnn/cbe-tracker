/// Riverpod wiring for user profiles.
///
/// Everything that touches disk — the database, the screenshot store, the
/// backup — hangs off [profileDirProvider], so switching user rebuilds the
/// whole data layer against a different directory. Nothing downstream needs
/// to know profiles exist; it just sees a documents directory.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'profile_store.dart';

/// The app documents directory — the root under which every user's data lives.
///
/// Resolving it is async, so main() looks it up once and overrides this;
/// nothing downstream has to await a directory. Throwing here rather than
/// returning a guess means a missing override fails loudly at startup instead
/// of silently writing images somewhere the backup will never find them.
final appDocsDirProvider = Provider<Directory>(
  (ref) => throw UnimplementedError('appDocsDirProvider must be overridden'),
);

final profileStoreProvider = Provider<ProfileStore>(
  (ref) => ProfileStore(ref.watch(appDocsDirProvider)),
);

/// The registry of users, loaded once at startup and rewritten on change.
class Profiles extends Notifier<ProfileRegistry> {
  @override
  ProfileRegistry build() => ref.watch(profileStoreProvider).load();

  /// Signs in as [name] — an existing user's books, or a fresh set.
  Future<Profile> enter(String name) async {
    state = await ref.read(profileStoreProvider).enter(state, name);
    return state.active!;
  }

  Future<void> switchTo(String id) async {
    state = await ref.read(profileStoreProvider).switchTo(state, id);
  }

  Future<void> signOut() async {
    state = await ref.read(profileStoreProvider).signOut(state);
  }
}

final profilesProvider = NotifierProvider<Profiles, ProfileRegistry>(
  Profiles.new,
);

/// The signed-in user, or null before the welcome screen has been answered.
final activeProfileProvider = Provider<Profile?>(
  (ref) => ref.watch(profilesProvider).active,
);

/// The directory the active user's database and screenshots live in.
///
/// Throws when nobody is signed in: the router sends her to the welcome
/// screen before anything DB-backed can build, so reaching this without a
/// profile is a wiring bug, and a loud one beats silently opening a stray
/// database at the root.
final profileDirProvider = Provider<Directory>((ref) {
  final profile = ref.watch(activeProfileProvider);
  if (profile == null) {
    throw StateError('profileDirProvider read with no active profile');
  }
  return ref.watch(profileStoreProvider).directoryOf(profile);
});
