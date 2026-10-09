# iOS batch complete: your iPhone checklist (2026-10-08)

Everything from the 2026-10-07 batch is now built and merged into `main`. None of it has been tried on a real
iPhone yet, so this one list is what to check. Tick a box when it works; if something looks wrong, write down what
you tapped and what happened and tell the next session.

## Your iPhone checklist

### Lyrics page
- [ ] Open lyrics with the music paused: the screen never goes dark or locks. Leave lyrics: it locks normally again.
- [ ] On a song in another language, tap **Translate**: translations appear and the button lights up. Tap again: they hide.
- [ ] Hold **Translate**: "Translate via AI" works; "Show romanization" appears on a Japanese or Korean song.
- [ ] Tap **Sing** on a downloaded song: the first time it says "Removing vocals…", then the vocals go away. Tap again: they come back without a skip.
- [ ] While playing on a Spotify Connect speaker, Sing is greyed out.
- [ ] With immersive lyrics on (Settings), tapping Translate or Sing keeps the controls on screen.
- [ ] The ⋯ button opens a see-through half-height sheet; drag it up and it stays see-through. Readable over bright album art?
- [ ] "Show as plain text" and "Show translations" switch on the first tap, whether you tap the switch or the row's name. The next song goes back to normal.
- [ ] The buttons look like the full player's glass, not dark plastic, over both bright and dark album art.
- [ ] Drag the seek bar: the dot stays under your finger.
- [ ] Tip: if all the glass looks too solid or too clear, try iPhone Settings › Display & Brightness › Liquid Glass (Tinted), or Reduce Transparency.

### Syncing lyrics yourself
- [ ] Open the sync screen three ways: the sync chip on lyrics, ⋯ › "Sync the words yourself" (try a BiniLyrics song too), and Edit song › Fix timing.
- [ ] It no longer just shows "loading" and disappears. Tap along, tap Save: you're back on lyrics with a "Saved" message.
- [ ] While playing on a Connect speaker, it tells you syncing only works on this iPhone and closes.

### Player
- [ ] Tap the heart in the full player: it fills or empties right away. Same in the song sheet and the lyrics ⋯ sheet.
- [ ] Shuffle and repeat also change right away.
- [ ] Previous / next feel as quick as play / pause.
- [ ] The top of the full player shows where the sound is going (AirPods, car, AirPlay, Echo). On the phone speaker it's just an icon. Very long names end neatly with "…".
- [ ] Optional: check whether a "Like" button appears anywhere (Lock Screen, CarPlay, watch). iOS decides this, so it may not show.
- [ ] With VoiceOver on, slide a finger over the shuffle / repeat / heart row: it never reads "Home", "Search" or "Library".

### Glass look and queue
- [ ] The queue and song options sheets look see-through, and text is still readable over bright album art.
- [ ] In the queue, tap ⋯: the circle smoothly turns into "Save as playlist" and back.
- [ ] "Save as playlist" shows in full on its own line; "Deselect all" fits on one line.
- [ ] A genre page › ⋮ › Quick Fill: "Select all", "Clear" and "Next" are readable; after Next it says "Select a genre", then "Genre: …".
- [ ] Taizo's chat over Home is readable.

### Accent colour
- [ ] Settings: pick a few preset colours, then a custom one. The app changes colour shortly after you stop dragging.
- [ ] Pop-up alerts (like "Delete?") use your colour for their buttons.
- [ ] In dark mode the colours look softer (on purpose). Do they look OK?
- [ ] Restoring an Android or older backup resets the colour to purple (expected).

### Volume buttons with Spotify Connect
- [ ] Play on the Echo, stay in PixlAudio, press volume up/down: the Echo changes about 5 % per press and PixlAudio's own glass volume pop-up shows (not the iPhone's).
- [ ] Settings › Developer › Diagnostics › Volume Buttons says **Re-centre**. If it says Relative, note the line under it.
- [ ] Hold a button: the volume keeps stepping smoothly, no "Spotify is busy" spam.
- [ ] Leave the app and come back: your phone's own volume is where it was.
- [ ] Control Center's volume slider does not change the Echo.
- [ ] The pop-up shows over the full player, lyrics and queue, but not over the devices sheet.
- [ ] Equalizer › Volume shows and changes the Echo's volume.
- [ ] Music playing in another app keeps playing when you open PixlAudio.
- [ ] Stop the Echo: music on the phone plays at normal volume with the normal iPhone pop-up.

### AI (on-device)
With Apple Intelligence turned on in iPhone Settings:
- [ ] Settings › AI features says "On-device model · in use".
- [ ] Daily Mix sparkle, type "rainy day indie", 10–15 songs: you get a playlist, even offline.
- [ ] Library › Create playlist › With AI, 100 songs: you get 100.
- [ ] Taizo: "what are my top artists?" answers from your library; a follow-up question remembers the last answer; "play some chill songs" shows a card first.
- [ ] Lyrics: hold Translate › "Translate via AI" works.
- [ ] Home: the greeting turns into an AI line; opening the card writes an insight.
- [ ] Turn Apple Intelligence off: the With AI card explains why and offers "Open AI settings".

### Downloaded AI model (optional, needs Wi-Fi and about 2 GB free)
- [ ] Settings › AI features: "Use downloaded AI model" is off at first.
- [ ] Turn it on: it shows "Not downloaded · 896.3 MB" and a Download button; nothing downloads by itself.
- [ ] Download: the bar moves; Cancel works. After it finishes it says "Checking and installing…" for a while, then "Downloaded".
- [ ] Repeat the AI checks above with it on. Note how long the first answer takes and whether speed and quality feel OK.
- [ ] Play music in the background for 10+ minutes after using it: music never stops.
- [ ] Ask Taizo something, lock the phone right away, unlock after a minute: you get an answer or a clear error, and music keeps playing.
- [ ] Delete the model: the space comes back and the switch turns off.
- [ ] Make a backup and restore it: the switch keeps its setting.

### Streaming speed
- [ ] Play 5 streamed songs from cold and do 5 skips, then go to Settings › Developer › Test playback › "Stream start timings" and copy them. Do it again on mobile data and in Low Data Mode. Give the numbers to the next session.

### New logo
- [ ] Look at the app icon in Default, Dark, Clear and Tinted (hold the Home Screen › Edit › Customize), plus in Settings and Spotlight.
- [ ] Check the launch screen in light and dark. If you still see the old icon, restart the phone.

### Cloud Studio (after the setup steps below)
- [ ] Settings › Developer › Experimental shows **Cloud processing**.
- [ ] Enter the values, tap **Test connection**: RunPod and Storage both green. Change one value on purpose: the error makes sense.
- [ ] **Run selftest** (about 1 cent): shows the version and GPU. The first time can take a few minutes.
- [ ] Cloud queue › Add › Current song with a downloaded song › Send. It goes Preparing → Uploading → Waiting for a GPU → Separating vocals → Done. Sing then uses the new version and lyrics are timed word by word. Cost about a cent.
- [ ] Try a streamed song and a Spotify song: they download first, then upload and come back fine.
- [ ] Send 3 songs, lock the phone for 30+ minutes, reopen: the results are there.
- [ ] Send 3 songs with nothing playing, leave the app in the background until uploads finish, reopen: all 3 still listed.
- [ ] Swipe the app away during an upload: it says it stopped; reopening restarts it.
- [ ] A playlist's ⋯ › "Process all in the cloud" (about 10 songs): the first is slow, then roughly 20–30 s each.
- [ ] Set the monthly limit to $0.01: Send is turned off.

### Active jobs on Home and work in the background (added later on 10-08)
- [ ] Follow the checklist in [2026-10-08-active-jobs-background.md](2026-10-08-active-jobs-background.md): the jobs
      button on Home, and "Your instrumentals are ready" arriving with the phone locked.

## Cloud Studio: your remaining steps

1. After main's `cloud-worker-build` finishes pushing the image, make the package public (once): GitHub profile →
   Packages → pixl-cloud-worker → Package settings → Change visibility → Public.
2. GitHub → Actions → cloud-worker-deploy → Run workflow, once, with **bench** ticked.
3. RunPod → Serverless → pixl-cloud-studio → copy the **Endpoint ID**.
4. RunPod → Settings → API Keys → Create a key named `pixl-iphone`, type **Restricted**: pixl-cloud-studio
   Read/Write, everything else None.
5. In the app: Settings → Developer → Experimental → Cloud processing. Enter the Endpoint ID, the `pixl-iphone` key,
   the R2 endpoint `https://49083275082e89f3a024292385941801.r2.cloudflarestorage.com`, bucket `pixl-cloud-studio`,
   and the R2 access key ID and secret you saved. Then tap **Test connection**. Never paste keys into chat.

## Known limits

- Nothing here has been tried on a real iPhone yet; it was checked only by builds and automated tests.
- Volume buttons control the speaker only while PixlAudio is open on screen, using an unofficial iOS trick; a press can occasionally be missed.
- After "Change the words" in Edit song, Edit song shows the old words until you reopen it.
- Cloud Studio: no "Better in the cloud" option in Sing, and only Cloudflare R2 storage. (The "results ready" notification now exists: see the active-jobs handoff.)
- The downloaded AI model is meant for when the app is open; how it behaves in the background is still unknown.
