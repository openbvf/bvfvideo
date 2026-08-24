# Security

BvfVideo is a thin SwiftUI shell on [BvfAppKit](https://github.com/openbvf/BvfAppKit). This file covers only what's specific to recording-and-playing-video.

## Reporting vulnerabilities

If you find a security issue, **do not open a public issue.** Instead:

- **GitHub Security Advisories** (preferred): [Submit a private advisory](https://github.com/openbvf/bvfvideo/security/advisories/new)
- **Email**: bvf@newvoll.net

## Out of scope

- App-lifecycle surface: [BvfAppKit/SECURITY.md](https://github.com/openbvf/BvfAppKit/blob/main/SECURITY.md).
- Encryption, key derivation, libsodium interop: [BvfKit/SECURITY.md](https://github.com/openbvf/BvfKit/blob/main/SECURITY.md).
- The `.bvf` file format and its threat model: [bvf/SECURITY.md](https://github.com/openbvf/bvf/blob/main/SECURITY.md).

## In scope

### Plaintext video in memory during recording

Camera and microphone frames are muxed to fragmented MP4 entirely in memory by `AVAssetWriter` in segment mode; each emitted segment is streamed through the encryption context, which writes only ciphertext. Plaintext video and audio never reach disk. On the way in, the app hands the system decoded camera buffers, not a container; on the way out it writes only ciphertext, so no encoded container is ever spooled into the app container. This was verified on 2026-08-05 by capturing all file-write events during a record session via Apple's Endpoint Security framework: no decodable video or audio file appeared anywhere under the user's account. A memory attack on the running, unlocked process could observe in-flight buffers; the mitigation is the same as for any decrypted content in a running app: keep the device under your control while recording, and lock the app when you walk away.

### Plaintext video in memory during playback

Playing a recording decrypts the whole file into memory and serves it to `AVPlayer` through an in-memory resource loader: the player is answered byte ranges from the RAM buffer, never given a plaintext file or a file URL, and the app writes no plaintext to disk. Unlike recording, this is verified rather than structural. `AVPlayer` demuxes and decodes inside closed Apple code in this process, with a caching subsystem we can't inspect, so we can only observe that it writes nothing decodable, not prove it. An Endpoint Security capture during record, playback, and seeking (2026-08-05) found no decodable video file anywhere under the user's account, in the app container or system scratch; because that is monitored rather than guaranteed, it is re-checked per release and OS update. Removing the residual would mean owning the demuxer (reimplementing fragmented-MP4 parsing in-app), which a clean audit doesn't justify.

### Transcription handoff to Bedit

If you choose to transcribe a recording, the recording's audio track is decoded to PCM in memory and the transcript is held in memory during recognition, then written as a `.bvf`-encrypted text file into your [Bedit](https://github.com/openbvf/bedit) folder (encrypted to the same public key the recording was encrypted to). The transcript is never placed on disk in plaintext. Recognition runs on-device through Apple's Speech framework; the one residual is that it decodes the audio track to PCM and hands those samples to the recognizer, a closed on-device component. The audio stays in memory (never a file), nothing leaves the device, and any scratch the recognizer keeps lives in system space, outside the app container. The handoff requires Bedit to be configured against the same iCloud container; if it isn't, the transcribe action surfaces an error rather than writing anywhere unexpected.

### Camera and microphone active while the capture screen is open

Opening the capture screen starts the camera and microphone to show a live preview, before you start recording. Consequence: the system camera and mic in-use indicators light up whenever the capture screen is visible, even when you aren't recording. Leaving the capture screen stops the session and releases both devices.

### Video import

BvfVideo can import external video files, converting them to encrypted recordings. **The original source files are left in place.** BvfVideo does not delete, move, or sanitize them. If a source contains video you don't want sitting on disk in plaintext, delete it yourself.

### Fake recordings via iCloud

If you've enabled iCloud sync and your iCloud account is compromised, an adversary can write encrypted recording files into your video folder. BvfVideo will sync them down and present them as recordings. There is no per-file signature today that lets you distinguish your own writes from injected ones; the cryptographic guarantee is confidentiality of contents, not authenticity of authorship. Mitigation: protect your iCloud account.

### Public key substitution via iCloud

If you've enabled iCloud sync, BvfVideo publishes your public key to a shared iCloud location so captures encrypt to it. An adversary who can write to that location could swap your key with their own; subsequent captures would encrypt to the adversary's key and be readable by them. BvfAppKit's `PubkeyDistributor` watches that location and surfaces a mismatch when the remote key diverges from the local one. See [BvfAppKit/SECURITY.md](https://github.com/openbvf/BvfAppKit/blob/main/SECURITY.md) for the mechanism.
