# MacBook Duo Glass

A macOS menu bar utility that applies an angle-driven perspective and frosted-glass effect to the built-in MacBook display. The app reads the lid angle, captures the display only when the effect is active, and renders everything locally with Metal.

## Features

- Automatically enables the effect from the lid angle. The activation threshold is configurable from `75°` to `120°` and defaults to `100°`.
- Keeps perspective projection continuous as the lid moves. A separate exponential curve controls the frosted material strength, so smaller angles produce a stronger effect without changing the projection limit.
- Provides spatial blur, directional reflection, distance-based transmission, chromatic dispersion, hinge-area highlights, a fade to black, a soft edge mask, and motion scattering.
- **Mirror mode** keeps only the perspective projection and disables blur, frost, reflection, and dispersion.
- **Adaptive angle** learns a stationary viewing angle after 3 seconds and sets the activation threshold to the learned angle minus `3°`. The built-in minimum is `75°`.
- Includes native menu bar switches, threshold and curve sliders, diagnostics, and a permission recheck action.
- Targets 60 Hz for sensor updates and rendering. Screen capture starts only below the activation threshold and stops when the display returns above it.
- Recovers from sleep, wake, and display changes. The app excludes its own overlay from capture to prevent recursive rendering.

## Compatibility

- macOS 14 Sonoma or later.
- Apple Silicon MacBook Air and MacBook Pro models with a built-in display and a compatible lid-angle HID sensor.
- The current implementation is intended for the built-in display. External displays, desktop Macs, and Intel Macs without the supported sensor are not guaranteed to work.
- macOS capture restrictions still apply to the lock screen, protected video, and some system full-screen surfaces.

## Installation

This repository currently provides a source build. It does not include a prebuilt bundle tied to a local signing identity or local file paths.

### 1. Prepare the environment

1. Confirm that macOS 14 or later is installed.
2. Install Apple's Command Line Tools:

   ```sh
   xcode-select --install
   ```

3. Verify that Swift is available:

   ```sh
   swift --version
   ```

### 2. Clone and build

Run the following commands in Terminal:

```sh
git clone https://github.com/spdore/MacBookDuoGlass.git
cd MacBookDuoGlass
./scripts/build_app.sh
```

The script builds a Release configuration and creates `dist/MacBookDuoGlass.app`. It also applies an ad-hoc macOS bundle signature. The `dist/` directory is a local build output and is not committed to the repository.

### 3. Install the application

1. Open the project's `dist` folder in Finder.
2. Drag `MacBookDuoGlass.app` into the **Applications** folder.
3. If an older copy is running, quit it from the menu bar first. Open only the copy in **Applications** so that macOS does not associate permissions with a different duplicate.
4. On the first launch, macOS may say that the developer cannot be verified. In Finder, Control-click the app, choose **Open**, and confirm. Alternatively, choose **Open Anyway** at the bottom of **System Settings → Privacy & Security**.

### 4. Grant Screen Recording permission

Screen Recording permission is required to read the current display and generate the live effect. Frames are processed in memory and are not saved, uploaded, or sent anywhere. The app does not request camera, microphone, or Accessibility permission.

1. Open **System Settings → Privacy & Security → Screen Recording**.
2. Enable **MacBook Duo Glass**.
3. If macOS asks to reopen the app, choose **Quit & Reopen**. Otherwise, quit the app manually and launch it again.
4. Open the menu bar item and choose **Show Diagnostics**. Screen capture should be shown as ready.
5. Capture starts only when the lid angle is below the selected threshold and the effect switch is enabled. It stops again when the angle returns above the threshold.

If the permission list contains an older duplicate, quit every copy, disable the old entry, launch the copy from **Applications**, and grant permission to that copy. macOS binds Screen Recording permission to the signed app identity, so avoid alternating between copies in different folders.

### 5. Use the effect

1. Click **Duo** in the menu bar.
2. Use **Activation Angle** to choose a threshold from `75°` to `120°`.
3. Use **Effect Curve** to control how quickly the frosted effect grows. This slider does not change the perspective limit.
4. Enable **Mirror Mode** when you want to see projection changes without the material effect.
5. Enable **Adaptive Angle** and hold the display at a preferred angle for at least 3 seconds to learn it automatically.

### 6. Optional self-test

From the project directory, run:

```sh
swift run -c debug MacBookDuoGlass --self-test
```

The self-test checks angle mapping, threshold limits, Metal rendering, Screen Recording permission, and the lid-angle sensor.

## Uninstall

Quit the menu bar app, then move `MacBookDuoGlass.app` from **Applications** to the Trash. If you no longer need capture access, disable the app under **System Settings → Privacy & Security → Screen Recording**.
