---
title: License and source
description: SimplMaker is free and open source under the GNU GPL, version 3 or later. Where the code is, how to build it, and the licenses of the parts it includes.
---

## Free software

SimplMaker is free, and its source code is open. It is released under the **GNU General Public License, version 3 or later** (GPL-3.0-or-later). You may use it for anything, including work you are paid for, read and change the code, and share your changes, as long as the changes you share are under the same license.

There is no trial, no license key and no activation. The parts you make are yours; the GPL covers the program, not what you draw with it.

The short license page is at [simplmaker.com/license](/license/). The code and the license text are on GitHub: [github.com/atlemo/SimplMaker](https://github.com/atlemo/SimplMaker).

## The name and icon

The GPL does not cover the name **SimplMaker** or the app icon. If you share a modified build, give it another name and another icon. Saying it is "based on SimplMaker" is fine.

## Build it yourself

In outline (the README in the repository has the current details and versions):

1. Install Xcode, CMake and Ninja on a Mac with Apple silicon.
2. Clone the repository.
3. Run `scripts/build-occt.sh` once. It builds the Open CASCADE geometry kernel, which takes a while.
4. Run `scripts/bundle-app.sh --open` to build `SimplMaker.app` into `dist/` and start it. Or open `SimplMaker.xcodeproj` in Xcode and run it from there.
5. Run `swift test` to run the tests.

A build you make yourself is signed ad hoc on your own Mac. The disk image from the [download page](/download/) is the official build, signed and notarised by Apple. See [Install](doc:start/install).

## Parts that have their own license

SimplMaker includes other free software, and each part keeps its own license. The full texts are under **SimplMaker → About SimplMaker**.

| Part | What it does | License |
|---|---|---|
| Open CASCADE Technology | The geometry kernel | GNU LGPL 2.1 with the Open CASCADE exception |
| DelaBella | Triangulation, inside Open CASCADE | MIT |
| Sparkle | Updates | MIT, with bundled BSD and zlib-style code |
| Lucide and Feather | Icons | ISC and MIT |
| TelemetryDeck SDK | Anonymous usage statistics | MIT |

Open CASCADE is a separate library in the app, and you can replace it with your own build. See [Open CASCADE and replacing the library](doc:reference/open-cascade).
