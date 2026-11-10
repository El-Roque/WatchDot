# Validation

## Functional baseline accepted on physical devices

Before the final WatchDot identity change, the project owner validated the following behavior on 2026-11-09:

| Feature | Result |
| --- | --- |
| Browser/device-code account authorization from the Watch | Accepted |
| Conversation with the account's existing Dot | Accepted |
| Nearby paired iPhone Internet with Wi-Fi disabled in Settings on both devices | Accepted by the user |
| Continued conversation with the iPhone locked and the wrist lowered | Accepted by the user |
| Ending with one action and returning to the call screen | Accepted by the user |
| App display name and original icon | Installed and verified |
| Circular/corner face launcher | User placed a shortcut and confirmed that it opened WatchDot |
| Conversation after the original iPhone and companion Watch apps were removed | Accepted by the user |

A preserved earlier sample showed authenticated media/events, packets in both directions, playback starting, a remote stop accepted with HTTP 200, and no remaining system calls. Some later diagnostic transfers timed out through CoreDevice; their remote HTTP results must not be inferred from that earlier sample. No audio or conversation transcripts are included in this repository.

The user's network conditions and functional reports are the physical validation evidence. Network.framework path flags alone did not independently identify the physical radio. Tests with one account/device do not establish service access, quality, battery life or indefinite background continuity for all users.

## Build 4: first-response admission

The user waits for Dot to finish the greeting before replying. The preserved build-3 call was retrieved after the Watch was made available. It showed first authenticated media at 12,142.6 ms and local call readiness at 19,522.1 ms, a 7,379.5 ms gap. The controller kept microphone PCM muted until the attachment HTTP response completed, even when authenticated media had already arrived. This is a local startup admission delay and a candidate contributor to the reported first-turn latency; the trace has no user-speech-end marker and does not prove the exact service response time. Playback recorded zero packet drops, zero resets and zero interruptions in this sample. Remote stop returned HTTP 200 and no system call remained.

Build 4 (`voice-admission-1`) allows microphone admission once media, events, attachment intent and authenticated remote audio are ready, after checking current account and active call generation. A successful attachment response remains the fallback for silent calls. The attachment response is still validated, and late rejection still ends the call. Cancellation and cleanup retain ownership fences. A one-shot `firstMicrophonePacket` marker was added without storing audio. Buffer settings, routing, accepted UI and optimized Swift settings remain unchanged.

All 186 optimized Swift tests passed, including six readiness-order/account/cancellation tests. Signed device builds for both architectures, the arm64 simulator build, deep signature verification and actual `-O` compiler checks passed. Twenty-nine staged source/project inputs matched current source. Build 4 was installed successfully with a CoreDevice installation receipt. A subsequent independent installed-version query timed out establishing the development tunnel; it did not invalidate the successful installation receipt. The user completed the requested first-response test and confirmed that the first response improved. This is physical acceptance for the reported Wi-Fi scenario; no exact response-time reduction has been measured. Two bounded attempts to retrieve the post-fix timing file timed out establishing the development connection, including one after restarting the Mac CoreDevice worker. No post-fix timings or packet counters were obtained; the confirmed improvement is the user report. No further physical test is required to record that acceptance. Preserve the build-3 sample outside the public tree.

## Build-4 source-distribution audit

The completed 2026-11-10 audit matched 309 app/project/resource/native-framework/notice files against the retained installed-build snapshot by SHA-256, with no differences. This includes all 27 Swift app/extension files, the resources, project/shared scheme, native module map and all four static libraries. Personal signing is excluded intentionally; the public signing example is provided separately.

All 841 files in the Git publication inventory were copied and hash-verified in a complete local public tree. Its 329 staged source/test/configuration/resource/framework/project files and Package.swift match the inputs that passed 186 optimized Swift tests and the unsigned device build for both architectures. The built public app and extension use their example identifiers and build number 4, with no personal signing override or embedded provisioning profile. Project and shared-scheme regeneration in the relocated tree is byte-identical. The content comparison closes the earlier native-module-map gap without changing the accepted application or requiring another device installation.

The final preflight passes: 35 portable project references, two Watch-only targets, 134 dependency notices, no cloud placeholders, no reported sensitive-file/name/path markers and no broken local documentation links. The exact Git inventory includes required source, native libraries, license and documentation, and excludes local signing, credentials, build products and caches. The largest file is 98,500,760 bytes. Project-owned documentation is in English and reflects build 4.

The final 48 iCloud placeholders were upstream Opus 1.6.1 files. Recovery used the [official source archive](https://downloads.xiph.org/releases/opus/opus-1.6.1.tar.gz), verified against the SHA-256 published on the [Opus download page](https://opus-codec.org/downloads/). All 434 already-readable local source files matched, as did the pending files' sizes. Only those 48 placeholders were restored; all 482 included upstream source files match that release. No dependency update, Swift app change, native-library rebuild or device installation was performed during this recovery.

**Source-publication readiness passed.** The complete repository root is the publication unit, including source, scripts, documentation, license and notices. The readiness audit did not itself publish the tree. The owner subsequently authorized publication, and the source is now public at [El-Roque/WatchDot](https://github.com/El-Roque/WatchDot), branch main. The initial source commit is `f714c99df48e7c98b397d3ef0b039fb708311569`; the remote branch matched that local commit after upload. Git preserves the upstream source and notice bytes without line-ending normalization. Compilation and content checks do not establish Dot availability or voice quality for other accounts/devices; the functional limits above still apply.

## Build 3: English interface and compact screens

Build 3 translates app-owned UI, status/error messages, accessibility and microphone permission text to English, and restores the earlier circular controls. All 180 optimized Swift tests passed. Signed device and arm64 simulator builds, deep signature verification and optimized compiler checks passed. Static-source comparison confirmed the call/audio/transport structure matches accepted build 2 outside string literals.

Layout-only simulator modes were reviewed at 40 mm and 46 mm for the call surface, account setup and authorization, account information and ending state. They use no account, microphone or call services and are not live voice tests. Small-screen clipping found during review was corrected. Build 3 was then installed on the physical Watch, and its device-reported bundle version was verified. A remote-launch attempt lost its XPC connection. The user manually opened the app and accepted its English interface and visual design. They also reported roughly five seconds of delay after their first spoken reply to Dot, with later turns working well. The user subsequently confirmed that build 4 improved that first response; the UI review itself passed. The accepted build-2 voice result below remains the audio baseline.

## Post-rename incoming-audio correction

On 2026-11-10, the user confirmed account authorization in WatchDot but reported incoming speech cuts on Wi-Fi, sometimes lasting three to four seconds. Preserved technical timings show a multi-second playback-reset stall and local packet-admission drops. Retained build tasks also exposed an unintended configuration change: the earlier accepted Debug build used `-O`, while the generated public project used `-Onone`. The project now restores `-O` in both configurations. The `voice-fluency-1` correction also separates player operations from the capture-admission mutex and adds reset-stop timing. All 180 Swift tests passed in both debug and optimized configurations, and the optimized signed device build and deep signature verification passed. After recovery of a blocked Xcode session and its development connection, build 2 was installed and launched successfully on 2026-11-10. The installed bundle version was verified on the Watch. The user then completed the requested Wi-Fi call with 60–90 seconds of incoming speech and confirmed that the voice remained fluent. This validates the corrected build for that physical scenario; it is separate from the earlier pre-rename baseline. Two bounded attempts to retrieve the post-fix diagnostics timed out establishing the development tunnel. No post-fix drop/reset counters were obtained; the physical acceptance is the user-reported fluent call.

## Public-package verification

The public package keeps the already-active independent TCP code path and removes the obsolete iPhone app, app-owned Bluetooth/UDP implementation, old projects, desktop-client extracts, local toolchains, caches, device/account diagnostics and nested Git history.

- The original packaging baseline passed **180 Swift core tests** after removing tests specific to deleted legacy flows. Build 4 passed **186 optimized Swift core tests**, including six new admission-readiness tests.
- **23 native Rust tests passed**, including translated TCP peers, authenticated media/events, source rejection and candidate budgets.
- The packaging baseline built successfully with local signing and passed deep signature verification before the identity rename.
- The renamed `src/WatchDot.xcodeproj` builds successfully with local signing for physical watchOS devices and without signing for the arm64 Watch simulator. Both built app/extension bundles have the expected WatchDot names and new identifiers. The signed build and deep signature verification passed on 2026-11-10.
- The new WatchDot identity was installed and launched successfully on the physical Watch on 2026-11-10 after Xcode showed the device connected. Fresh account authorization and build-2 incoming-audio fluency on Wi-Fi are confirmed by the user. The user also confirmed that the renamed face shortcut opens WatchDot. The user removed the previous installed app manually after the remote attempt could not establish a development tunnel, and confirmed that WatchDot still opens.
- The renamed native libraries were rebuilt for device `arm64` / `arm64_32` and simulator `arm64`; the Opus packet-loss/FEC probe passed.
- The public-tree preflight reports zero references to the previous app name, including the static libraries.
- Project regeneration after relocation was byte-identical. All 825 moved source/dependency files were verified by SHA-256 during migration.
- The exact Git publication inventory includes the required libraries and native build inputs, and excludes the local signing override.
- Native device/simulator libraries were rebuilt with private path remapping.
- All 134 locked dependency entries have license notices in the component index.
- Project references, bundled architectures, file sizes, links and sensitive-file markers are checked by `scripts/check_project.py`.

The existing account-record compatibility types remain because they are part of the persisted session schema and shared verification code. Their presence does not add an iOS application or a phone relay.

The environment used Xcode 26.6 (17F113) with watchOS SDK 26.5. A machine-readable summary is in [VALIDATION-RESULTS.json](VALIDATION-RESULTS.json).

## Changes made for redistribution

The waiting sound previously extracted from a desktop application was replaced with an original generated tone. It retains the one-second tone / three-second silence cadence and existing playback volume control, but is a different waveform. Its format and generation are checked locally; it has not received a separate physical listening approval.

The project, app, extension, native wrapper module, exported native symbols, signing variables, diagnostic labels and account-storage identifiers are named WatchDot. References are relative, signing is supplied by each installer, and documentation is in English. The renamed app uses a new installation identity and a separate Keychain service. Existing users must authorize their account again and replace their face shortcut. No account tokens, signing certificates, provisioning profiles or device-specific inventories are distributed.

No new remote call is created by the preparation, tests, project generator or native build. The public package has not been published or uploaded automatically. Reorganization/build checks do not constitute an additional physical-device or multi-account test.

## Reproduce the local checks

From the repository root on a Mac with Xcode:

```sh
python3 scripts/check_project.py
swift test --package-path src
xcodebuild -project src/WatchDot.xcodeproj -scheme WatchDot \
  -destination 'generic/platform=watchOS' -derivedDataPath .build/watch \
  -jobs 2 CODE_SIGNING_ALLOWED=NO build
xcodebuild -project src/WatchDot.xcodeproj -scheme WatchDot \
  -destination 'generic/platform=watchOS Simulator' -derivedDataPath .build/simulator \
  -jobs 2 ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build
```

For native tests, install the pinned Rust toolchain and run:

```sh
cargo +nightly-2026-10-02 test --locked --manifest-path src/Native/RTC/Cargo.toml
```

A generic destination builds only. Physical installation requires your own signing settings and an actual Watch destination in Xcode.
