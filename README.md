# MacBook Duo Glass

A macOS menu bar app that uses the MacBook lid angle to apply a perspective and frosted-glass effect to the built-in display.

## Features

- Starts screen capture only while the effect is enabled and the lid is below the selected angle. Frames are processed in memory and are not saved or uploaded.
- Sets an activation angle from 75° to 120° (100° by default). Perspective changes with the lid angle; the effect-curve control changes the frosted-effect strength without changing perspective.
- Two perspective styles. **Fold plane** (default) tilts the whole picture back about the hinge: the hinge edge stays put, the far edge recedes into a trapezoid, nothing is cropped, and the plane fades out as the lid closes. **Classic glass** is the original model, a glass pane swinging in front of fixed content. Switch between them with the **折叠平面透视** toggle in the menu.
- Includes a projection-only Mirror Mode and an Adaptive Angle option. Adaptive Angle uses a steady position held for 3 seconds, then sets the threshold to that angle minus 3°. Its minimum threshold is 75°.
- Provides menu bar controls, a diagnostics view, and a screen-recording permission recheck.
- Targets 60 Hz for angle sampling, capture, and rendering, and restarts capture after sleep, wake, or display changes.

## Compatibility

- macOS 14 or later.
- Tested on one MacBook Air with Apple M4, running macOS 26.5.2. The built-in display must expose a compatible lid-angle HID sensor. Other MacBook models have not been verified.
- The downloadable app is built for Apple Silicon (`arm64`). Intel compatibility is unverified.
- macOS may restrict capture of protected video, the login screen, and some full-screen system content.

## Install the prebuilt app

1. Open the [v0.2.0 release](https://github.com/spdore/MacBookDuoGlass/releases/tag/v0.2.0) and download `MacBookDuoGlass-0.2.0-macos-arm64.zip`.
2. Double-click the ZIP file in Finder to extract `MacBookDuoGlass.app`.
3. If the app is already running, quit it from the menu bar. Move the extracted app into **Applications**. Use one copy of the app so macOS permission settings stay associated with the same app identity.
4. Open the app from **Applications**. This release is ad-hoc signed and is not notarized. If macOS blocks the first launch, Control-click the app in Finder, choose **Open**, and confirm the prompt.
5. Open **System Settings → Privacy & Security → Screen Recording** (called **Screen & System Audio Recording** on some macOS versions). Allow **MacBook Duo Glass**, then quit and reopen the app.
6. Click **Duo** in the menu bar and open the diagnostics view. The screen-capture status should become ready when the lid is below the activation angle.

## Use the app

The app's menu controls are currently displayed in Chinese. They provide these functions:

- The main switch turns the effect on or off.
- The activation-angle slider chooses a threshold from 75° to 120°.
- The effect-curve slider adjusts how quickly the frosted effect grows as the lid closes. It does not change the perspective.
- The fold-plane toggle chooses the perspective style (on: fold plane, off: classic glass). Both styles use the same frosted material.
- Mirror Mode shows the perspective without blur or frosted-material effects. With the fold-plane style that means a plain trapezoid on a black background: no hinge smear, edge light or surround glow.
- Adaptive Angle learns a stationary angle after 3 seconds and sets the threshold to that angle minus 3° (minimum 75°). Turning it off restores the previous manual threshold.
- A permission-recheck control is available if screen-recording access was granted while the app was running.

Capture stops when the effect is disabled or the lid returns to or above the selected angle. The app excludes its own overlay from the captured display to avoid recursive images.

## Build from source

You need macOS 14 or later and Apple's Command Line Tools. Install the tools if needed, then clone and build:

```sh
xcode-select --install
git clone https://github.com/spdore/MacBookDuoGlass.git
cd MacBookDuoGlass
./scripts/build_app.sh
```

The script builds a Release app at `dist/MacBookDuoGlass.app`, includes the app icon, removes local debug paths from the executable, and applies an ad-hoc signature using the existing bundle identifier `com.spdor.MacBookDuoGlass`. The build uses the architecture of the Mac performing the build.

To run the project self-test:

```sh
swift run -c debug MacBookDuoGlass --self-test
```

To render offscreen previews of both perspective styles on a synthetic desktop, without screen-recording permission or a moving lid:

```sh
swift run -c debug MacBookDuoGlass --render-preview /tmp/duo-fold --style fold
swift run -c debug MacBookDuoGlass --render-preview /tmp/duo-classic --style classic
```

Each run writes one PNG per angle and a contact sheet. Only the generated fixture is drawn; no screen content is read.

## Permission troubleshooting

If capture is not ready, quit every running copy, open the copy in **Applications**, check **System Settings → Privacy & Security → Screen Recording**, and reopen the app. If needed, use the permission-recheck control in the Duo menu and review the diagnostics view. macOS can show duplicate entries when copies from different folders have been launched.

## Acknowledgements

The fold-plane style follows the fold-transition study in [DuoLauncher](https://github.com/jakesgoodapps/DuoLauncher) (MIT License, Copyright (c) 2026 Duo Launcher contributors): a picture plane anchored at the hinge whose far edge recedes into a trapezoid, a short smear confined to a band beside the hinge, and a late fade of the plane. That study is a timed Android snapshot animation; this app derives the same silhouette in closed form from a rigid plane tilted about the hinge and drives it from the lid angle. No DuoLauncher source code is included. Its proportions (a 7.5% hinge band, five smear copies weighted (6−k)/18, a fade starting at 78% of the motion) were reused as tuning constants.

## Uninstall

Quit the app and move **MacBook Duo Glass.app** from **Applications** to the Trash. You can also disable its screen-recording permission in System Settings.
