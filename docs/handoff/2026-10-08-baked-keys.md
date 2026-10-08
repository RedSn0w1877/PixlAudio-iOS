# Built-in cloud keys (2026-10-08, branch `s23-baked-keys`)

Goal: Cloud Studio (instrumentals and word-timed lyrics on RunPod, songs through Cloudflare R2) works on a fresh
install with **nothing to fill in**. The app carries PixlAudio's own keys, encrypted. Anyone can still choose
"Use my own keys" and type their own, as before.

## What it does

- The app bundles `App/Resources/CloudDefaults.enc`: the RunPod endpoint ID, a **Restricted** RunPod key that can only
  use the `pixl-cloud-studio` endpoint, and an R2 key pair that can only use the `pixl-cloud-studio` bucket. The file
  is locked (AES-256-GCM); the committed one is a placeholder with dummy values until you bake the real one.
- The key that unlocks it is **not in the repository**. It is the GitHub secret `CLOUD_DEFAULTS_KEY`. Just before
  building, CI turns it into four pieces in `App/Generated/CloudDefaultsKey.swift` (`ci/write-cloud-defaults-key.sh`;
  the committed file stays empty, and `ci/check-forbidden.sh` fails if pieces are ever committed).
- No secret (forks, or before you bake): the build still passes, the app has no built-in keys, and Cloud processing
  looks and works exactly as before (off, fields empty). A secret that doesn't fit the blob counts as no keys too.
- With built-in keys, Settings › Developer › Experimental › Cloud processing shows "Using PixlAudio's built-in cloud
  keys" instead of the fields, with a **Use my own keys** switch. Your own keys always win when that is on, and anyone
  who set up their own keys before this update keeps using them.
- The "Process songs in the cloud" switch starts **on** with built-in keys, but nothing is ever uploaded until the
  person picks songs and taps Send on the confirm sheet (which says the songs go to PixlAudio's RunPod and bucket).
- Money: with built-in keys the monthly cap is **at most $3 per iPhone**, whatever the cap field says; estimates never
  use a GPU price below the endpoint's ($0.000192 a second); and removing or clearing finished jobs no longer frees
  room under the cap (the month's spend is remembered).
- The keys are unlocked once, in the background (not on the main thread), kept in memory only, and never logged,
  shown or saved anywhere else.

**Honest limit:** the key pieces are inside every IPA, so someone determined can dig the keys out of the app. That is
why the keys are scoped (the RunPod key only reaches this one endpoint; the R2 key only this one bucket), why the
$3 cap exists, and why the RunPod balance is the real ceiling. If the keys are ever abused: make new ones and bake
again (below), then delete the old ones in RunPod and Cloudflare.

## Your two steps

These need `s23-baked-keys` merged into `main` first, so the main checkout has the bake script and the empty key
file (the script warns if it doesn't).

**(a) RunPod console:** Settings › API Keys › Create API Key. Name it `pixl-iphone`, type **Restricted**, give it
access only to the endpoint **pixl-cloud-studio** (Read/Write), everything else None. Copy the key.

**(b) In PowerShell, from the main checkout:**

```
cd "C:\Users\Hoa\Downloads\Code Projects\PixlAudio-iOS"
node tools/cloud/bake-cloud-keys.mjs --commit
```

It asks, with hidden input, for three things: the `pixl-iphone` key from (a), and the R2 access key ID and R2 secret
access key of the token you made for the `pixl-cloud-studio` bucket. Paste each, then Enter. It prints only what it
changed, never a key. It then:

- makes the unlock key once (kept in `%USERPROFILE%\.pixlaudio\cloud_defaults_key`; keep that file),
- writes the locked file into the iOS repo (and the Android repo's `app/src/main/assets/cloud_defaults.enc`),
- sets the `CLOUD_DEFAULTS_KEY` secret on both GitHub repos,
- commits the locked file in each repo (it never pushes).

## What happens next

1. Push `main` (`git push` in the main checkout). CI builds the app with the keys built in; the IPA from that run
   (or the next release) has them. The unit test `testTheBundledBlobFitsThisBuild` fails if the blob and the secret
   don't match, so a mismatch can't ship silently.
2. GitHub › Actions › **cloud-e2e** › Run workflow. It does what a phone does with the built-in keys: uploads a 20 s
   test clip to R2, sends one job to RunPod, checks the instrumental that comes back, deletes the test files, and checks
   that no GPU worker is left running (it switches one off if it lingers). About a cent. Green means the keys work.
3. On the phone: install the new IPA, open Cloud processing, and it should say "Using PixlAudio's built-in cloud
   keys". Send one song from the Cloud queue.

To check anything locally without changing it: `node tools/cloud/bake-cloud-keys.mjs --check`.

## Files

- `Packages/PixlCore/Sources/PixlNet/Cloud/CloudDefaults.swift` — the file format, the pieces, and the rules (own keys
  win, $3 cap, minimum price). Tests: `PixlNetTests/CloudDefaultsTests`.
- `App/Services/Cloud/CloudDefaults.swift` — unlocking with CryptoKit, once, off the main thread.
- `App/Services/Cloud/CloudSettings.swift`, `CloudStudio.swift` — which keys a job uses, the cap, the remembered spend.
- `App/Features/CloudStudio/CloudProcessingSettingsView.swift` — the Keys section. Screenshot route
  `cloud.settings.builtin` (`CloudStudioScreenshotTests`).
- `ci/write-cloud-defaults-key.sh`, the "Built-in cloud keys" step in `ci.yml` and `release.yml`.
- `tools/cloud/bake-cloud-keys.mjs` (`--help` lists every flag; `--dry-run` rehearses without touching anything).
- `.github/workflows/cloud-e2e.yml` + `cloud/runpod-worker/deploy/e2e.py` (tests: `tests/test_e2e.py`).
