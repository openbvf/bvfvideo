# Privacy

BvfVideo collects nothing.

There is no analytics, no telemetry, no crash reporting, no advertising identifier, no usage measurement, no remote logging. No data leaves your device for our benefit, because there is no benefit for us to derive. There is no "us" in the operating sense; there is no server, no account system, and no backend.

## Your keys and passphrase

BvfVideo uses standard public-key encryption. Three things matter:

- **Public key**: encrypts new recordings. Safe to share or sync; that's the whole point.
- **Private key**: decrypts recordings. Encrypted with your passphrase (locked).
- **Passphrase**: decrypts (unlocks) the private key for playback.

The keys live on macOS. The public key gets synced to iCloud Drive if you enable it, but the private key never leaves. The passphrase ideally exists only in your head.

## Local-only operation

BvfVideo never makes a network call. It only reads and writes files on the local device, whether capturing or playing back. If you opt in, cross-device sync (recording on iOS, or syncing between your Macs) encrypts video files to a local folder which iCloud Drive syncs between devices. iCloud is doing the transport, not BvfVideo. Your passphrase never leaves your device, and the unlocked private key exists only in memory. Neither the maintainers of BvfVideo nor Apple can see your recordings.

Recording muxes and encrypts in memory; playback decrypts and decodes in memory. No plaintext video file is written to disk either way.

Transcription runs on-device through Apple's Speech framework: the recording's audio track is decoded and handed to the recognizer from memory and never leaves the device. The resulting transcript is written encrypted into your Bedit folder, never to disk in plaintext.

For the cryptographic details, see [BvfKit's SECURITY.md](https://github.com/openbvf/BvfKit/blob/main/SECURITY.md) and the [bvf file format spec](https://github.com/openbvf/bvf/blob/main/SPEC.md).

## What the app reads on your device

Apple requires that apps disclose use of certain system APIs even when no data is transmitted off-device. BvfVideo uses:

- **Camera** and **microphone**: while the capture screen is open. Both start when you open the screen to show a live preview; leaving the screen releases them.
- **Speech recognition** (macOS only): when you ask to transcribe a recording. Recognition runs on-device.
- **User defaults** (`UserDefaults`): to remember your preferences and a per-device identifier used to name unsaved drafts so multiple devices don't overwrite each other's work-in-progress.
- **File timestamps**: to detect changes to key files and to group saved recordings by date in the browser.

Every read stays on-device. Nothing is reported anywhere.

## What we don't have

- No account.
- No password reset, because there is no password we hold.
- No "your data" page, because there is no data on our side.
- No way to recover a forgotten passphrase. If you forget it, your recordings are unrecoverable. This is intentional.

## Third parties

The only third party is Apple, and only if you opt into iCloud Drive sync. Apple's own privacy policy covers iCloud storage. BvfVideo contacts no other service.

## Changes

This policy is versioned alongside the source at the [BvfVideo repository](https://github.com/openbvf/bvfvideo). Material changes are noted in release notes.

## Contact

Security disclosures and privacy questions: see [BvfVideo's SECURITY.md](https://github.com/openbvf/bvfvideo/blob/main/SECURITY.md) for the contact channel. Do not file public issues for security or privacy concerns.
