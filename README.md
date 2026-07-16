# CBE Tracker

Per-branch balances from CBE receipt screenshots, cross-checked against CBE
SMS. Built for a business owner running ~5 branches whose money moves through
the Commercial Bank of Ethiopia: photograph the receipt, the app reads it,
files it under a branch, checks it against the bank's own SMS, and produces
end-of-day PDF reports.

Money is integer cents everywhere. The CBE parser is pure Dart. The source of
truth for behaviour is `REQUIREMENTS.md`.

## Build

```sh
flutter analyze          # must be clean
flutter test             # must pass
flutter build apk --release
```

The plain build is fully local — no keys, no network, nothing leaves the phone
except what the owner shares herself.

### Optional build-time configuration (--dart-define)

| Define | Enables |
|---|---|
| `SUPABASE_URL` + `SUPABASE_KEY` | Daily cloud backup to the owner's Supabase project (Settings → Cloud backup). Setup: `docs/SUPABASE_SETUP.md`. |
| `GEMINI_API_KEY` | AI fallback for receipts the local parser can't read. Off by default; the local parser + manual entry cover normal use. Note: the key is embedded in the APK. |

```sh
flutter build apk --release \
  --dart-define=SUPABASE_URL=https://YOUR-PROJECT.supabase.co \
  --dart-define=SUPABASE_KEY=YOUR-PUBLISHABLE-KEY
```

### Release signing

`android/app/build.gradle.kts` still signs release builds with the debug key
(fine for sideloading on the owner's phone). Create a keystore and a
`key.properties` before distributing more widely.

## Device workflow

- Install preserving data: `adb install -r <apk>` — **never** `flutter install`,
  which uninstalls first and wipes the app's data.
- Manual regression script: `docs/MANUAL_TEST.md`. Run it on a real phone
  before calling a build done — this project has repeatedly caught things on
  device that 270 green tests missed.

## Layout

```
lib/core/parser/     CBE receipt + SMS parser (pure Dart, no Flutter imports)
lib/core/money/      integer-cents formatting
lib/data/db/         Drift schema, DAOs, providers
lib/services/        OCR, parse pipeline, bulk processor, backup (local+cloud),
                     PDF, notifications, SMS ingestion
lib/features/        one folder per screen/flow
docs/                Supabase setup, manual test script
```
