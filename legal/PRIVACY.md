# SimplMaker Privacy Policy

> Source text of the published page `website/src/pages/privacy/index.html` (simplmaker.com/privacy/). Keep the two in step.

Last updated 8 October 2026.

## The short version

SimplMaker has no accounts and no ads, and nothing is shared for advertising. Your parts and files never leave your Mac. The app talks to the internet in three cases only: to **look for updates**, to **activate and check a licence key**, and to send **anonymous usage statistics**, which you can turn off in Settings. This website sets no cookies and uses no analytics.

The data controller is Atle Mo, the person behind SimplMaker. Contact: support@simplmaker.com.

## What is sent, and why

### 1. Looking for updates

SimplMaker asks `simplmaker.com` whether a newer version exists. Like any web request, this shows your IP address and the app's user agent (the SimplMaker, Sparkle and macOS versions) to our web host, one.com, which keeps server logs for a limited time to run and secure the service. We send no system profile and do not use these logs to identify anyone. Basis: our legitimate interest in delivering updates securely (GDPR art. 6(1)(f)). You can turn the automatic check off in **Settings → General**.

### 2. Licence activation and checks (Polar)

When you enter a licence key, SimplMaker sends the key, our organisation id and **the name of your Mac** (the one shown in System Settings → Sharing) to Polar (polar.sh), our payment and licence provider. While your Mac is licensed it sends the key and activation id about once a week to check that the licence is still valid. Polar also sees your IP address. We use this to enforce the licence and its limit on the number of Macs. Basis: performance of the contract (art. 6(1)(b)).

### 3. Anonymous usage statistics (TelemetryDeck)

SimplMaker sends anonymous events to [TelemetryDeck](https://telemetrydeck.com), a privacy-focused analytics service, so that we can see how many people use the app and which features matter. We currently send an event when the app starts and when you finish the tutorial. Each event carries:

- the SimplMaker version and build number, and whether it is a debug build;
- the Mac model, processor architecture, macOS version, screen resolution and scale, and time zone;

- your language, region and light or dark appearance, and your accessibility display settings (such as reduced motion);
- the date and time parts of the event (day, week, hour), your first-use date and simple counts such as how many sessions and days you have used the app;

- a random identifier that SimplMaker creates on your Mac. It is made unreadable (hashed) *before* it leaves your Mac, and TelemetryDeck hashes it again, so it cannot be traced back to you, only used to count distinct users.

It never contains your parts, file names, licence key, name or email address. According to TelemetryDeck, it does not store IP addresses. Basis: our legitimate interest in understanding and improving the product (art. 6(1)(f)). It is **on by default and you can turn it off** in **Settings → General → Share anonymous usage statistics**; the change takes full effect the next time SimplMaker starts.

### 4. Your purchase (Polar)

When you buy a licence, Polar, acting as the merchant of record, collects your name, email, payment details and billing country to take payment, issue the key and handle tax. We receive your name, email address and country for the sale, to support you and to meet our accounting duties (art. 6(1)(b) and (c)). Polar has its own privacy policy.

### 5. Stored on your Mac

SimplMaker keeps your trial start date, the date it last ran and your activated licence in your macOS keychain, with a copy of the dates in its preferences, plus the random identifier used for usage statistics. This stays on your Mac. Deleting it only removes what tells SimplMaker you are licensed, so you would enter your key again.

### 6. This website

simplmaker.com sets no cookies, loads no third-party scripts, fonts or trackers, and has no analytics. Our web host logs requests (IP address, time, page, user agent) for a limited time to operate and secure the service. The Buy button takes you to Polar's checkout, which is covered by Polar's privacy policy.

### 7. Support email

If you write to us, we keep the correspondence as long as needed to help you and for our records. You can ask us to delete it.

## Sharing and transfers

We do not sell your data. Our processors and partners are our web host (one.com), Polar and TelemetryDeck. Some of them may process data outside the EU/EEA; where they do, they rely on a lawful transfer mechanism such as the EU's standard contractual clauses or an adequacy decision.

## How long we keep it

- **Server logs:** a limited time, set by our web host.
- **Sale records:** as long as accounting law requires (in Norway, five years).

- **Licence records:** while the licence is valid.
- **Usage statistics:** in aggregate form, as long as they are useful for improving SimplMaker.

- **Support email:** as long as needed to help you and for our records.

## Your rights

You can ask for access to, correction of or deletion of your data, to restrict or object to its use, and to data portability, and you can withdraw consent where we rely on it. Write to support@simplmaker.com. Because usage statistics are anonymous, we usually cannot link them to you; turning them off in Settings is the way to stop them. You can complain to the Norwegian Data Protection Authority ([Datatilsynet](https://www.datatilsynet.no)) or to the authority where you live.

## Changes

If this policy changes, the new version is posted here with a new date. If the app starts sending anything else, this page is updated before the release that does it.

---

### How to keep this true (not part of the published text)

- The usage-statistics section describes what the TelemetryDeck SDK (2.14.x) sends by default plus the signals in `Sources/SimplMaker/Telemetry.swift` and its callers. Re-check it when the SDK is updated or a signal is added.
- Confirm against TelemetryDeck's documentation that IP addresses are not stored, and sign their data processing agreement.

- Confirm Polar's role (controller or processor) for the licence checks from its terms, and the web host's real log retention.
- If the app ever sends anything else (crash reports, a Sparkle system profile with `SUEnableSystemProfiling`...), update this text before that release.

