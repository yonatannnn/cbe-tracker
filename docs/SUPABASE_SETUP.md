# Cloud backup setup (Phase 10)

The app can upload its backup — the same sqlite-plus-screenshots zip you can
already share locally — to your own Supabase project once a day, protected by an
email/password login. This is opt-in: with no project wired in, the whole
feature stays hidden and the app is 100% local.

You do this once. About 10 minutes.

## 1. Create a free Supabase project

1. Go to <https://supabase.com>, sign up, and **New project**.
2. Pick a name and a database password (you won't need the DB password in the
   app). Choose the region closest to Ethiopia (e.g. `eu-central` / Frankfurt).
3. Wait for it to finish provisioning.

## 2. Create the storage bucket and its access rules

1. Left sidebar → **SQL Editor** → **New query**.
2. Paste this and **Run**. It makes a *private* bucket called `backups` and
   rules so each signed-in user can only touch files inside their own folder —
   nobody can read your backups but you.

```sql
-- Private bucket for the backup zips.
insert into storage.buckets (id, name, public)
values ('backups', 'backups', false)
on conflict (id) do nothing;

-- Each user may only read/write files under a folder named with their own id.
-- The app uploads to "<your-user-id>/CBETracker_....zip", so these four rules
-- (read, create, overwrite, delete) scope everything to you.
create policy "own backups - read" on storage.objects
  for select to authenticated
  using (bucket_id = 'backups'
         and (storage.foldername(name))[1] = auth.uid()::text);

create policy "own backups - insert" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'backups'
              and (storage.foldername(name))[1] = auth.uid()::text);

create policy "own backups - update" on storage.objects
  for update to authenticated
  using (bucket_id = 'backups'
         and (storage.foldername(name))[1] = auth.uid()::text);

create policy "own backups - delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'backups'
         and (storage.foldername(name))[1] = auth.uid()::text);
```

## 3. Turn on email sign-in

1. Left sidebar → **Authentication** → **Providers** → **Email**: make sure it's
   enabled (it is by default).
2. Recommended for a single-owner app: **Authentication → Providers → Email →
   "Confirm email" OFF**. Then creating your account signs you in immediately.
   If you leave it ON, after "Create an account" you must click the link
   Supabase emails you before you can sign in — the app will tell you to.

## 4. Copy your two values

Left sidebar → **Project Settings** → **API**:

- **Project URL** — looks like `https://abcdefgh.supabase.co`
- The public API key — labelled **"Publishable key"** (newer projects) or
  **"anon public"** (older ones). Either works. It is safe to embed in the app;
  your data is protected by the login and the rules above, not by hiding this
  key.

Send me those two values, or build it yourself with step 5.

## 5. Build the app with cloud backup enabled

```sh
flutter build apk --release \
  --dart-define=SUPABASE_URL=https://YOUR-PROJECT.supabase.co \
  --dart-define=SUPABASE_KEY=YOUR-PUBLISHABLE-OR-ANON-KEY
```

(Leave both `--dart-define`s off and you get the normal local-only app.)

## 6. Use it

- Install that build, open **Settings → Cloud backup → Sign in for cloud
  backup**, and create your account (email + a password you'll remember).
- From then on, each day you open the app while online it uploads a fresh copy
  automatically. You can also **Back up now** any time.
- On a lost or new phone: install the app, sign in with the same email and
  password, and **Restore from cloud** — your branches, transactions and
  screenshots come back.

Your password is the key to your records. If you forget it, the backups can't be
recovered — so keep it somewhere safe.
