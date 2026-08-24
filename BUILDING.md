# Building from source

> This section written by an LLM and untested.

BvfVideo is signed and provisioned against a specific Apple Developer team, so a fresh clone won't build as-is. To build locally, swap five identifiers for your own. The first four are in Xcode and config files; the fifth is in Swift source. Miss the fifth and the app will compile, sign, and launch, but read and write to the wrong iCloud container and app group at runtime.

1. **Team ID**: open `BvfVideo.xcodeproj`, select the *BvfVideo* project at the project navigator root, and under *Signing & Capabilities* change the team to yours. (This rewrites `DEVELOPMENT_TEAM` in `BvfVideo.xcodeproj/project.pbxproj`.)
2. **Bundle identifier**: the app ships as `io.bvf.bideo[.debug]`. Change to your own reverse-DNS prefix in the same *Signing & Capabilities* tab.
3. **iCloud container**: `BvfVideo/BvfVideo.entitlements` (macOS) and `BvfVideo-iOS/BvfVideo-iOS.entitlements` (iOS) list `iCloud.io.bvf.shared`. Replace with a container in your team.
4. **App group**: the same entitlements files also list `group.io.bvf.shared`. Replace with one in your team.
5. **Swift source**: the same `iCloud.io.bvf.shared` and `group.io.bvf.shared` strings also appear in `BvfVideo/BvfVideoApp.swift` (the `BvfAppKitEnvironment` initializer and the `PreferencesView` call), `BvfVideo/MainView.swift` (the `OnboardingView` call), and `BvfVideo-iOS/BvfVideo_iOSApp.swift` (the `iCloudManager` initializer). Replace each with the same identifiers you used in steps 3 and 4. `grep -r "io.bvf.shared"` will catch any stragglers.

iCloud containers and app groups require a paid Apple Developer account. On a free Personal Team, remove the iCloud and App Group capabilities in *Signing & Capabilities*, and adjust the Swift code in step 5 so it doesn't try to initialize them. The app will build and run as a local-only recorder but won't sync across devices, and the Bedit transcription handoff won't be available.

Then: `xcodebuild -scheme BvfVideo -configuration Debug -destination 'platform=macOS'`, or open in Xcode and Run.

The `BvfVideo-iOS` target is record-only: an iPhone or iPad can capture encrypted recordings into the shared iCloud container, but only the Mac holds the private key and can play them back. It shares `SecureVideoRecorder` (in the `Shared/` folder) with the macOS target and depends on iCloud being set up in the macOS app first. Build it with `xcodebuild -scheme BvfVideo-iOS -configuration Debug -destination 'generic/platform=iOS'`, or select the scheme in Xcode.
