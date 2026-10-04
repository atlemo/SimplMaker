# SimplCAD Privacy Policy

> **DRAFT: not yet reviewed by a lawyer.** Fill in the bracketed parts, and check the list below against what the shipped app and
> website actually do before publishing it (see "How to keep this true").

Version 0.1, [date]. The controller for the data described here is **[LEGAL NAME, address, organization number]**, contact **[email]**.

## The short version
SimplCAD has no accounts, no analytics and no tracking. Your parts and files never leave your Mac. The app talks to the internet in two cases only: to **update itself**, and to **activate or check a license key**.

## What is sent, and why

### 1. Checking for updates (simplcad.com)
SimplCAD asks `https://simplcad.com/updates/appcast.xml` whether a newer version exists. Like any web request this reveals your IP address and the app's user agent (SimplCAD and Sparkle versions, and macOS version) to our web host, **[one.com]**, which keeps server logs for **[period]** to run and secure the service. We do not send a system profile, and we do not use these logs to identify you. Basis: our legitimate interest in delivering updates securely (GDPR art. 6(1)(f)). You can turn automatic checks off in Settings.

### 2. License activation and checks (Polar)
When you enter a license key, SimplCAD sends the key, our organization id and **the name of your Mac** (the label you see in Sharing settings) to Polar (polar.sh), our payment and license provider, and about once a week while licensed, it sends the key and activation id to check that the license is still valid. Polar also sees your IP address. We use this to enforce the license and the activation limit. Basis: performance of the contract (art. 6(1)(b)). Polar acts for its own purposes as merchant of record for your purchase, and has its own privacy policy.

### 3. Your purchase (Polar)
When you buy a license, Polar collects your name, email, payment details and billing country to take payment, issue the key and handle tax. We receive from Polar your name, email address and country for the sale, to support you and meet our accounting duties (art. 6(1)(b) and (c)).

### 4. Stored on your Mac
SimplCAD keeps a trial start date, the last date it ran, and your activated license in your macOS keychain, with a copy of the dates in its preferences. This stays on your Mac. Deleting it resets nothing for us; it only removes the information that tells SimplCAD you are licensed, so you would enter your key again.

### 5. Support email
If you write to us, we keep the correspondence as long as needed to help you and for our records.

## Sharing and transfers
We do not sell data. Our processors are our web host and Polar. Some of them may process data outside the EEA; where they do, they rely on a lawful transfer mechanism such as the EU's standard contractual clauses or an adequacy decision.

## How long we keep it
Server logs: **[period]**. Sale records: as long as accounting law requires (in Norway, five years). Support email: **[period]**.

## Your rights
You can ask for access to, correction of, or deletion of your data, to restrict or object to its use, and to data portability, and you can withdraw consent where we rely on it. Write to **[email]**. You can complain to the Norwegian Data Protection Authority (Datatilsynet) or the authority where you live.

## Changes
We will post a new version here and date it.

---

### How to keep this true (not part of the published text)
- If the app ever sends anything else (crash reports, analytics, a system profile with Sparkle's `SUEnableSystemProfiling`...), update section "What is sent".
- The user agent and IP in the update check come from Sparkle and the web host; check the host's real log retention and fill in the periods.
- Polar's own role (controller or processor) for the license checks should be confirmed from its terms and data processing agreement.
