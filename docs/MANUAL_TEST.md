# Manual test script (§9 regression)

Run on a physical Android phone with real data. Every line should pass before a
release build ships. Items marked ☐ are the §9 checklist; the rest cover
features added after it was written.

## Adding money

- ☐ **Same screenshot twice** → second attempt is blocked with "Already
  recorded on <date>" and a working **View existing** button that opens the
  original transaction. Nothing saved twice; no stray image left behind.
- ☐ **Blurry/unreadable image** → "Couldn't read this screenshot", with
  **Try another image** and **Enter manually** offered. Nothing saved.
- ☐ **Bulk with mixed states** → pick a batch containing a clean receipt, a
  duplicate, and an unreadable image. The review sheet shows each in its own
  state; the save button states the exact count ("Save N transactions");
  saving is all-or-nothing; the saved count lands in the right branch.
- Bulk cap: picking more than 50 says "Only 50 images at a time — N not added".

## SMS shadow ledger

- ☐ **SMS arrives while app closed** → visible in Reconcile on next open
  (launch re-arms the listener and re-reads the inbox).
- ☐ **Ignore an SMS ("Mark as personal")** → gone from that day now AND still
  absent from that day after switching days and back. The Undo snackbar
  disappears by itself after a few seconds.
- ☐ **Two same-amount candidates, no reference** → the SMS stays unmatched
  rather than guessing which transaction it belongs to.
- Refresh button reports its result ("Up to date…" / "Found N new…") and says
  so if the inbox can't be read.

## Reports

- ☐ **Report for a past date == the report generated on that date** — figures
  are recomputed from the ledger, so regenerating an old day matches what it
  said at the time.
- ☐ **Balance audit** — the dashboard total equals the sum of the branch
  balances, which equal the sums of their visible transactions.
- Combined PDF and per-branch PDFs share correctly; per-branch files are one
  per branch (never the same file repeated).
- Reports refresh live: add a transaction, the open report updates.

## Dashboard periods

- Default view shows ALL TIME = total balance, with "+X today" under it.
- Today / This week / This month / Pick dates all retune the headline AND the
  branch cards; movement is signed and coloured, all-time is a plain balance.
- Leave the app open across midnight (or fake it: change the phone date) →
  "today" rolls over without a restart.

## Backup

- Local: Settings → Back up now → share sheet → the zip restores on the same
  or another phone with balances and screenshots intact.
- Restore of a wrong/corrupt file is refused with nothing changed.
- Cloud (if configured): sign in → Back up now → file appears in Supabase;
  Restore from cloud brings everything back. Auto-backup uploads on the first
  online launch of the day.

## Platform

- ☐ **iOS build (static expectation)** — no SMS UI anywhere: Reconcile shows
  "available on Android", the dashboard strip says cross-check is off (never a
  false green tick), reports and PDFs say "SMS cross-check not active" instead
  of counts, and no verification badges/ticks appear. Everything else works.
- Notifications: the reminder survives a reboot; toggling it off and on
  restores the chosen time, not 18:00.
