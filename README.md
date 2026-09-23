# MacBook Duo Glass

A macOS menu bar app that applies an angle-driven frosted perspective effect to the built-in display.

## Features

- Configurable effect threshold from 75° to 120° (100° by default).
- Exponential strength curve: the effect starts softly and becomes stronger near 0°.
- Metal rendering at a 60 Hz target.
- Screen capture starts only while the effect is active.
- Menu bar controls for pause, resume, and quit.

## Requirements

- macOS 14 or later
- Swift Package Manager and Command Line Tools
- Screen Recording permission when the effect is first activated

## Build and run

```sh
./scripts/build_app.sh
open dist/MacBookDuoGlass.app
```

Run the local self-test with:

```sh
swift run -c debug MacBookDuoGlass --self-test
```

The app processes the built-in display only. Lock screens, protected content, and some system full-screen surfaces follow macOS capture restrictions. Screen content is processed in memory and is not saved or uploaded.
