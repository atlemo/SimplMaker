# Selling SimplCAD: setting up licensing

SimplCAD sells through [Polar](https://polar.sh), a merchant of record: Polar is the seller of record, charges
the customer, collects and pays the VAT and sales tax, and emails the license key. The app needs no server of
its own. It checks the trial itself and activates keys against Polar's public license endpoints.

How it behaves (see `Sources/SimplCAD/Licensing/`):

- **Trial:** 14 days from the first launch. The start date is kept in the macOS keychain, with a copy in
  UserDefaults, so trashing the app does not restart it. A clock set back does not add days.
- **After the trial** (or a lapsed license): parts open, show and export (STEP, STL), but cannot be changed or saved
  (`DocumentModel.mutate` refuses). A banner offers *Buy…* and *Enter License…*.
- **License:** the key is activated once per Mac (label = the Mac's name). The app asks Polar again about once a
  week, and works offline for 30 days after the last confirmation. A refunded or revoked key stops working at
  the next check. *License… ▸ Deactivate This Mac* frees the activation for another Mac.
- **Builds without licensing:** if `Packaging/licensing.conf` is missing the app does not enforce anything
  (development builds). `scripts/bundle-app.sh --release` and `scripts/release.sh` refuse to build without it.

## One-time setup (you do this; it needs your identity and bank details)

1. **Create the account.** Sign up at polar.sh, create an organization, and finish the payout setup (Polar pays out
   through Stripe Connect Express; Norway is supported). Individuals and companies can both sell; your legal note
   suggests selling through a company if you can.
2. **Create the product** "SimplCAD" with a one-time price. Add the **License Keys** benefit:
   - prefix `SIMPL`
   - activation limit: 3 (a desktop and a laptop, with one spare)
   - expiration: none for a perpetual license (set one for a time-limited license: the app then stops editing
     when it passes, and the key can be renewed)
   - no usage limit
3. **Make a checkout link** for the product (Polar dashboard ▸ Checkout Links). It looks like `https://buy.polar.sh/polar_cl_…`.
4. **Copy the organization id** (dashboard ▸ Settings ▸ General) and write both values to `Packaging/licensing.conf`
   (copy `Packaging/licensing.conf.example`; neither value is secret, so commit it):

   ```
   POLAR_ORGANIZATION_ID=<uuid>
   BUY_URL=https://buy.polar.sh/polar_cl_…
   ```

## Test it in Polar's sandbox first

Polar has a separate sandbox (https://sandbox.polar.sh) with its own organization, product and test card
`4242 4242 4242 4242`. Customer emails there only reach members of the sandbox organization, so add yourself
as a member and read the key in the sandbox customer portal.

1. Make the same organization, product, license-key benefit and checkout link in the sandbox.
2. Put the sandbox organization id and checkout link in `Packaging/licensing.conf`, and add
   `POLAR_API_BASE=https://sandbox-api.polar.sh`.
3. `scripts/bundle-app.sh --debug --open`. Buy with the test card, then enter the key under *SimplCAD ▸ License…*.
   Check: activating, the Mac showing in the sandbox customer portal, deactivating, a second Mac hitting the limit.
4. To test the end of the trial without waiting two weeks, move the stored start date back (the item is
   `org.simplcad.SimplCAD.license` in the login keychain, JSON with `trialStart` and `lastSeen`), then delete the
   `licenseStateBackup` default: `defaults delete org.simplcad.SimplCAD licenseStateBackup`.
5. Remove `POLAR_API_BASE` and put the real values back before releasing; `--release` refuses to build while it is set.

## Cost (checked October 2026; verify on polar.sh before relying on it)

- Polar: about 5 % + $0.50 per sale on the free plan; no monthly fee. Lower rates exist on paid plans.
- Already paid for: the Apple Developer Program ($99 a year), the domain and the hosting.
- No cost for the licensing code itself: there is no server to run.

## Still open

- Price, and whether updates are included forever or for a year (a year needs the key to expire and a
  renewal product, or version checks in the app).
- Publish the EULA and the privacy policy (drafts in `legal/`, after a lawyer has read them) on simplcad.com, and link
  them from the product page and the app.
- Polar needs a website with the product, a refund policy and support contact for its review.
