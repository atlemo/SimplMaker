# Licensing the iPad app (decision notes)

Not legal advice: these are the facts and the options, for the author to decide on, ideally after a short check with someone who
does open-source licensing.

## Where things stand (2026-11-05)

- SimplMaker is GPL-3.0-or-later. Every commit so far is by the author (plus commits co-authored by Claude, which the author
  directed and owns), so **the author holds the copyright to all of the code** and can also distribute it under other terms, such
  as the App Store's. A copyright holder is not bound by the GPL for their own work.
- That stops being true the day an outside contribution is merged: with DCO sign-off only (see `CONTRIBUTING.md`), a
  contributor licenses their change under the GPL and nothing more. Such code could not go into an App Store build, because the
  App Store's terms (a usage licence, DRM, no replacing the app) conflict with the GPL's. This is why VLC left the App Store
  in 2011.
- Third-party code in the iPad build: OpenCASCADE (LGPL-2.1 with the OCCT exception), linked **statically** on iOS (an app cannot
  ship a user-replaceable dylib). The LGPL wants users to be able to relink the application with a changed library. The source,
  the build script (`scripts/build-occt-ios.sh`) and the project (`iPad/project.yml`) are public, so anyone can rebuild and sign
  the app themselves; that is the usual answer for LGPL libraries in App Store apps, but it is worth having read once by someone
  qualified, including the OCCT exception's own wording. DelaBella (MIT) is bundled inside OCCT's build; its notice must be shown.

## Options for outside contributions

1. **Keep things as they are and accept no outside code into the iPad app.** Simple, but it splits the project: a change merged
   for the Mac would have to be kept out of the iPad target, which in practice is impossible (they share `Sources/SimplMaker`).
2. **Contributor licence agreement (recommended).** Contributors keep their copyright and grant the project a broad licence to
   use it under other terms too (an Apache-style ICLA, or the shorter "inbound = GPL, plus the right to relicense for app-store
   distribution"). Cheap to run with a bot (CLA Assistant) on pull requests. Nothing changes for contributors' own rights.
3. **DCO plus a standing additional permission.** The DCO stays, and `CONTRIBUTING.md` says that by contributing you also grant
   permission to distribute your contribution as part of an app-store build. Lighter than a CLA, but the legal footing for a
   grant given by a sign-off line is weaker than for a signed agreement.
4. **Copyright assignment.** Strongest for the project, hardest to ask of volunteers. Not recommended.

## What to do before the first iPad release

- Choose between 2 and 3 and put it in `CONTRIBUTING.md` (and, for 2, set up the pull-request check) *before* the first outside
  pull request is merged. There is nothing to clean up today because there are no outside contributions.
- Add the OCCT and DelaBella notices to the iPad app (a Settings or About screen listing them, plus the GPL text and the source
  link); the Mac app already has `LicenseTexts.swift`, which the iPad project currently leaves out.
- Keep the source public and the build reproducible (xcframework script, `project.yml`): that is what makes the GPL and LGPL
  stories true for the App Store build.
- App Store listing: the 9.99 price, the privacy "data not collected" answers (the app sends nothing; the Mac-only telemetry is
  not in the iPad build) and the export-compliance answer (`ITSAppUsesNonExemptEncryption` is false) are already consistent
  with the code.
