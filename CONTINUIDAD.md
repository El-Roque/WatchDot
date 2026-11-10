# WatchDot continuity

Updated: 2026-11-10, America/Argentina/Buenos_Aires.

## Current project

This is the standalone Watch-only version of WatchDot, prepared for source distribution. The only application project is `src/WatchDot.xcodeproj`, scheme **WatchDot**, with the **WatchDot** application and **WatchDotLauncher** WidgetKit extension. There is no iPhone app target. The app's visible name is WatchDot and it uses the previous blue icon.

The user explicitly authorized removing the original project, replacing the alternate source directory with the current `src/`, and deleting unrelated files. They approved **GPL-3.0-only** after the inherited third-party license was verified, and approved replacing the extracted waiting sound with an original generated tone. All project documentation must be in English. On 2026-11-10 the user explicitly requested publishing the verified project in a public GitHub repository named WatchDot. This authorizes the initial repository creation, commits and source upload.

## Accepted behavior

The pre-rename build was physically validated for account connection, conversation with the existing Dot without an iPhone app installed, nearby-iPhone Internet with Wi-Fi disabled, locked-iPhone/wrist-down continuity, one-action hang-up, the app icon and face launcher. In WatchDot build 2, the user separately confirmed account connection, fluent incoming speech on Wi-Fi, opening the app after removing its predecessor, and the renamed face shortcut.

The user approved renaming the app and all internal identifiers to WatchDot, including installation identity and account storage. The new local app identifier is `ar.rochi.watchdot`, with extension `ar.rochi.watchdot.launcher`. The user confirmed fresh account authorization in WatchDot. The renamed face shortcut is confirmed, and the user manually removed the earlier installed app after authorizing its removal. For the public project, installers must configure their own team and unique app/extension identifiers. Local signing overrides belong in the ignored `src/Config/Signing.local.xcconfig` file; do not commit that file.

## Key paths

| Path | Purpose |
| --- | --- |
| `README.md` | Public overview, requirements and license |
| `docs/INSTALLATION.md` | Xcode signing and Watch installation |
| `docs/ARCHITECTURE.md` | Account, CallKit, TCP and audio boundaries |
| `docs/VALIDATION.md` | Confirmed behavior and validation limits |
| `src/Sources/WatchDotApp` | Current app UI, call owner and native media integration |
| `src/Sources/WatchDotCore` | Shared account, Dot-routing and media helpers |
| `src/Sources/WatchDotLauncher` | Face shortcut |
| `src/Vendor` | Device/simulator libraries and dependency notices |
| `src/Native` | Native engine/wrapper sources and libopus source |
| `scripts/generate_project.py` | Deterministic project generation |
| `scripts/generate_ringback.py` | Original generated waiting sound |
| `scripts/check_project.py` | Portability, dependencies and publication hygiene |

## Preserve these decisions

- The Watch runs RTC, DTLS/SRTP, Opus and audio; the paired iPhone supplies system Internet connectivity, without WatchDot code or a custom relay.
- CallKit activates audio before low-level networking. Do not re-enable the previously failing explicit voice-processing mode.
- Register the actual observed TCP peer tuple against its original ICE candidate; preserve candidate attributes and DTLS identity. Do not invent local addresses.
- Preserve generation/account fences, bounded queues, immediate local cancellation, allocation cleanup and one-action ending.
- The shortcut opens the containing app and does not start a call automatically.
- Do not change accepted audio buffers, interruption handling or network routing merely because files were reorganized.
- Do not store or publish credentials, device/account diagnostics, audio, transcripts, provisioning profiles or private signing material.
- Do not delete installed apps, publish, commit or push by inference. A request to prepare a GitHub-ready tree is not publication authority.

## Verification and next work

Current source is WatchDot 1.0, build 4. All 186 optimized Swift tests, signed device builds for both architectures, the arm64 simulator build, deep signature verification and optimized compiler checks passed. Build 4 was installed successfully, and the user confirmed that its first response improved. The English interface and compact controls were accepted in build 3. The per-build evidence and diagnostic limits are recorded below and in `docs/VALIDATION.md`.

The packaging baseline passed 23 native Rust tests and the Opus packet-loss/FEC probe. Native libraries were rebuilt for device and simulator, with private path remapping and complete dependency notices. The original project was removed, source was relocated to `src/`, and the former extracted ringback was replaced with an original generated waveform. The waveform has not had a separate physical listening approval. No publication, repository creation, commit or push is authorized by a readiness check.

## Completed source and publication audit

The current source matches the retained inputs for installed build 4: 309 app/project/resource/native-framework/notice files matched by SHA-256 with no differences, including the formerly unavailable native module map and all four static libraries. The private signing override is intentionally excluded from this comparison. The public signing example is included for installers.

The complete public copy contains 841 files, all hash-verified after copying. Its 329 staged source/test/configuration/resource/framework/project inputs and Package.swift are identical to the inputs that passed all 186 optimized Swift tests and the unsigned public-default device build. Both public targets use build 4, the example identifiers and no personal signing configuration. Project and shared-scheme regeneration in a relocated copy is byte-identical. No additional app rebuild or installation was needed after this content comparison.

The final preflight passes: 35 portable project references, two Watch-only targets, 134 dependency notices, zero cloud placeholders and no reported hygiene or local-link errors. The largest file is 98,500,760 bytes, within the regular-Git file limit. Git's publication inventory excludes signing overrides, credentials, build products and caches. Documentation is in English, reflects the accepted build-4 behavior and explains publishing the repository root rather than src/ alone.

The last 48 cloud placeholders were unmodified upstream Opus source files. They were restored from the official Opus 1.6.1 archive after verifying its published SHA-256, matching all 434 readable local files, and checking the pending files' sizes. All 482 included Opus source files now match that official release. The dependency version, Swift application code, prebuilt native libraries and installed app were not changed. Details and the archive checksum are in src/Native/README.md and docs/VALIDATION.md.

The user explicitly authorized publication after the readiness audit. The verified source is published in the public repository https://github.com/El-Roque/WatchDot on main. The initial source commit is f714c99df48e7c98b397d3ef0b039fb708311569. GitHub received that exact commit, and the repository is public. Git is initialized at the project root with this repository as origin. The publication uses a GitHub noreply author address and excludes local signing. Further publication requires its own user instruction. Build-4 physical acceptance remains valid; the previously recorded single-device/service-access limits still apply.

## Public README screenshots

The user requested screenshots in the public README. Two unmodified 416 × 496 PNG captures show the current English home screen and call controls. They were captured in watchOS Simulator using the existing layout-only preview modes, without a live account or call, and were visually reviewed before inclusion. README captions and alternative text are English and identify the simulator previews. Assets are in docs/screenshots/home.png and docs/screenshots/call.png. No application source, installed app or voice behavior changed. The public inventory now contains 843 files.

## Build-4 first-response validation

The user waits for Dot to finish the greeting before replying. The preserved build-3 call was retrieved after the Watch was made available. It showed first authenticated media at 12,142.6 ms and local call readiness at 19,522.1 ms, a 7,379.5 ms gap. The controller kept microphone PCM muted until the attachment HTTP response completed, even when authenticated media had already arrived. This is a local startup admission delay and a candidate contributor to the reported first-turn latency; the trace has no user-speech-end marker and does not prove the exact service response time. Playback recorded zero packet drops, zero resets and zero interruptions in this sample. Remote stop returned HTTP 200 and no system call remained.

Build 4 (`voice-admission-1`) allows microphone admission once media, events, attachment intent and authenticated remote audio are ready, after checking current account and active call generation. A successful attachment response remains the fallback for silent calls. The attachment response is still validated, and late rejection still ends the call. Cancellation and cleanup retain ownership fences. A one-shot `firstMicrophonePacket` marker was added without storing audio. Buffer settings, routing, accepted UI and optimized Swift settings remain unchanged.

All 186 optimized Swift tests passed, including six readiness-order/account/cancellation tests. Signed device builds for both architectures, the arm64 simulator build, deep signature verification and actual `-O` compiler checks passed. Twenty-nine staged source/project inputs matched current source. Build 4 was installed successfully with a CoreDevice installation receipt. A subsequent independent installed-version query timed out establishing the development tunnel; it did not invalidate the successful installation receipt. The user completed the requested first-response test and confirmed that the first response improved. This is physical acceptance for the reported Wi-Fi scenario; no exact response-time reduction has been measured. Two bounded attempts to retrieve the post-fix timing file timed out establishing the development connection, including one after restarting the Mac CoreDevice worker. No post-fix timings or packet counters were obtained; the confirmed improvement is the user report. No further physical test is required to record that acceptance. Preserve the build-3 sample outside the public tree.

## Build-3 English interface

The user requested English throughout the app and the slimmer screens from the earlier accepted design. All app-owned labels, account/call status and error messages, accessibility text, widget metadata and the microphone permission explanation are now English. The call surface restores the green circular call action, light timer and round microphone/end controls. The finishing state has no second hang-up action. Call and authorization layouts adapt to small displays.

All 180 optimized Swift tests passed after updating five expectations for translated messages. Both signed device architectures and the arm64 simulator build passed; deep signature and `-O` compiler checks passed. Screens were visually checked in 40 mm and 46 mm simulators. The simulator modes use an empty session store and no account, microphone or call services. Call/audio/transport structure in six implementation files is identical to accepted build 2 outside string literals.

The user prepared the Watch and build 3 was installed successfully. A device query independently confirmed installed bundle version 3. The remote launch lost its XPC connection, but the user manually opened WatchDot and confirmed that the interface is English and looks good. They then reported a first-response delay: Dot greets them, their first spoken reply is followed by roughly five seconds before Dot answers, and subsequent turns work well. The UI review passed. The user confirmed that they wait for the greeting to finish. The sample was retrieved, and the user later confirmed that the build-4 admission change improved the first response. Do not reset the working account or replace the restored optimized settings.

## Build-2 fluency validation

- **Reported failure:** incoming Dot speech on Watch Wi-Fi cut roughly every five seconds, sometimes for three to four seconds. The original trace recorded 183 admission drops, two reservoir resets, a 4,231 ms scheduling stall at a reset and 4,265 ms maximum playback queue wait; decode stayed below 1.1 ms and no local interruptions were recorded. These are historical measurements; the earlier temporary raw files were subsequently unavailable.
- **Verified configuration difference:** the retained accepted-build tasks used Swift `-O`, while public-project generation had introduced `-Onone` for Debug. Both configurations now restore `-O`, enforced by the publication preflight.
- **Correction:** `voice-fluency-1` moves player scheduling/reset operations outside the capture-admission mutex, preserves serial playback ownership and cancellation checks, and measures player-stop duration separately. Buffer limits and network routing were not changed.
- **Local validation:** 180 Swift tests passed in both debug and optimized configurations. Signed device builds passed for both architectures with verified `-O`, and deep signature verification passed. The locally staged inputs were matched to source; build-2 project/scheme files and built bundle versions were separately verified.
- **Environment recovery:** Xcode blocked reading the iCloud-hosted local signing configuration. Normal quit timed out; the user approved force-quit and reopening only the local project copy. Xcode is now responsive at the local copy, and the Mac CoreDevice worker was restarted. Use the local copy for the remaining installation/debugging session.
- **Build-2 installed state:** WatchDot build **2** (`ar.rochi.watchdot`) was installed, its device-reported bundle version was verified, and it was launched successfully. The user completed the requested Wi-Fi call with 60–90 seconds of incoming speech and confirmed that the voice stayed fluent. This is the physical acceptance of the build-2 fluency correction for that scenario. Post-fix diagnostic retrieval timed out twice while establishing the development tunnel; no post-fix counters were obtained. The physical acceptance is the user report, not an inferred zero-drop measurement. The user confirmed that the renamed face shortcut opens WatchDot. The user explicitly authorized removing the earlier installed app and then confirmed its manual deletion from the Watch and that WatchDot still opens. That removal is physically confirmed by the user. The user also confirmed that the renamed face shortcut opens WatchDot. No setup check remains pending.

If a new runtime problem is reported, preserve that call's bounded diagnostics before another call overwrites them. Failed developer-device transfers are not evidence that an accepted user test failed. Do not infer a later call's HTTP stop result from an earlier sample.

Update this same file after meaningful progress and when preparing a handoff. Keep it an operational summary rather than a chat transcript.
