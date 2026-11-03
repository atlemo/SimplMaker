# Contributing to SimplMaker

Thank you for wanting to help. SimplMaker is free software (GPL-3.0-or-later), and bug reports, ideas, documentation fixes and code are all welcome.

## Before you start

- **Bugs:** open an issue with what you did, what you expected, what happened, your macOS version and the SimplMaker version
  (SimplMaker → About). A `.simplmaker` file that shows the problem is worth a thousand words; you can attach it.
- **Features and larger changes:** open an issue first, so we can agree on the idea before you spend a weekend on it. SimplMaker
  stays deliberately small, and some good ideas will not fit.
- **Questions:** the [documentation](https://simplmaker.com/docs/) answers most; otherwise open an issue.

## Building and testing

The build steps are in the [README](README.md). Before you open a pull request:

```sh
swift test                 # all Swift tests
scripts/test-kernel.sh     # the C kernel test, if you touched Sources/CKernel
```

CI runs the same on every pull request. A change in behaviour comes with a test. A change in what users see comes with a change in
the documentation: `website/src/docs/` holds it, and `docs/FEATURE-NOTES.md` has the notes for developers.

## Code

- Match the code around yours: naming, comment density and idiom. Comments say why, not what.
- `Sources/CADCore` is pure Swift with no UI and no kernel; keep it that way. Geometry that needs OpenCASCADE goes through
  `Sources/CKernel` and `Sources/CADKernel`.
- Keep dependencies out unless they are really needed, and only ones whose license works with the GPL.
- Anything that sends data over the network needs a good reason, and the privacy page on simplmaker.com has to say so.
- The app's own copyright line and SPDX identifier go at the top of new source files:

  ```swift
  // Copyright © <year> <your name>
  // SPDX-License-Identifier: GPL-3.0-or-later
  ```

## License of your contribution

SimplMaker is licensed under the GPL, version 3 or later, and your contribution is too. By sending a pull request you certify the
[Developer Certificate of Origin](https://developercertificate.org): that you wrote the change or have the right to submit it under
this license. Say so by signing off your commits (`git commit -s`), which adds a `Signed-off-by:` line.

## Name and icon

Please do not use the SimplMaker name or icon for a modified version of your own: see [TRADEMARK.md](TRADEMARK.md).
