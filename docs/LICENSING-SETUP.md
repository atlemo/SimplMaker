# Selling SimplMaker: setting up licensing

SimplMaker sells through [Polar](https://polar.sh), a merchant of record: Polar is the seller of record, charges
the customer, collects and pays the VAT and sales tax, and emails the license key. The app needs no server of
its own. It checks the trial itself and activates keys against Polar's public license endpoints.

**The model: $49 per major version.** A license covers one major version (1.x, 2.x) for good, with all its
updates. SimplMaker 1 keeps working, and keeps getting its own updates, when SimplMaker 2 comes out; whoever wants
2.0 buys it again. In the code this is the *generation* (`LICENSE_GENERATION` in `Packaging/licensing.conf`):

- each major version is its own Polar **product**, with its own License Keys benefit, so a key for 1 is turned
  away by 2 (and the activation it briefly made is freed straight away);
- each has its own **14-day trial** (kept under its own keychain item), so a trial or key from 1 does not touch 2;
- each has its own **update feed** (`https://simplmaker.com/updates/v1/appcast.xml`, `…/v2/…`), so Sparkle never
  offers 2 to a copy of 1; users hear about 2 from the website or your email list;
- keys do not expire (leave the expiration empty); the app is tied to the product, not to a date.

How it behaves (see `Sources/SimplMaker/Licensing/`):

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
2. **Create the product** "SimplMaker 1" at $49, one-time. Add the **License Keys** benefit:
   - prefix `SIMPL`
   - **activation limit: 2** (a desktop and a laptop). This is Polar's *activation* limit, a different field from the
     *usage* limit, which must stay empty: the app never counts usage, and a key whose benefit has no activation
     limit cannot be activated at all (Polar answers 403, and the app says the key cannot be activated)
   - expiration: none (a version-1 license never expires)
   - no usage limit

   For version 2 you make a separate product, "SimplMaker 2", with its own benefit. For people who own 1, make a
   Polar **discount code** for 2 and email it to them (the app does not know who bought what).
3. **Make a checkout link** for the product (Polar dashboard ▸ Checkout Links). It looks like `https://buy.polar.sh/polar_cl_…`.
4. **Copy the organization id** (dashboard ▸ Settings ▸ General). Find the **benefit id** of the License Keys
   benefit. Polar's public customer-portal page for the organization lists its products and their benefits, so no
   purchase is needed (use `sandbox-api.polar.sh` for the sandbox):

   ```bash
   curl -s https://api.polar.sh/v1/customer-portal/organizations/<organization slug> | python3 -m json.tool
   ```

   Under `products` ▸ `benefits`, copy the `id` of the `license_keys` benefit; the same answer shows the product's
   price, which is a good check. (After a purchase you can also ask about a key: `POST
   /v1/customer-portal/license-keys/validate` with `key` and `organization_id` returns `benefit_id`; it does not
   use up an activation.) Write the values to `Packaging/licensing.conf` (copy
   `Packaging/licensing.conf.example`; none of them is secret, so commit it):

   ```
   POLAR_ORGANIZATION_ID=<uuid>
   BUY_URL=https://buy.polar.sh/polar_cl_…
   POLAR_BENEFIT_ID=<uuid>
   LICENSE_GENERATION=1
   ```

   A release build refuses to be made without the benefit id, since without it a key for any major version
   would unlock the app.

## Test it in Polar's sandbox first

Polar has a separate sandbox (https://sandbox.polar.sh) with its own organization, product and test card
`4242 4242 4242 4242`. Customer emails there only reach members of the sandbox organization, so add yourself
as a member and read the key in the sandbox customer portal.

1. Make the same organization, product, license-key benefit and checkout link in the sandbox.
2. Put the sandbox organization id, benefit id and checkout link in `Packaging/licensing.sandbox.conf` (git
   ignores it), and add `POLAR_API_BASE=https://sandbox-api.polar.sh`. Keep the real values in `Packaging/licensing.conf`.
3. `LICENSING_CONF=Packaging/licensing.sandbox.conf scripts/bundle-app.sh --debug --licensed --open`. Without
   `--licensed` a development build does not ask for a license at all (so your own copy never locks); release
   builds always do. Buy with the test card, then enter the key under *SimplMaker ▸ License…*.
   Check: activating, the Mac showing in the sandbox customer portal, deactivating, a second Mac hitting the limit.
4. To test the end of the trial without waiting two weeks, move the stored start date back (the item is
   `com.simplmaker.SimplMaker.license` in the login keychain, JSON with `trialStart` and `lastSeen`), then delete the
   `licenseStateBackup` default: `defaults delete com.simplmaker.SimplMaker licenseStateBackup`.
5. A release uses `Packaging/licensing.conf` and refuses to build while `POLAR_API_BASE` is set.

## Cost (checked October 2026; verify on polar.sh before relying on it)

- Polar: 5 % + $0.50 per sale on the free plan, no monthly fee, so about $2.95 of each $49 (6.0 %). The Pro plan
  ($20 a month) is 3.8 % + $0.40: it pays for itself above roughly 30 sales a month. Prices are
  tax-inclusive: for a buyer in Norway the checkout shows $49 total, of which $9.80 is 25 % VAT (so you receive
  less than $49 there; Polar's fee comes off the total and the VAT is passed on). Other countries differ.
- Already paid for: the Apple Developer Program ($99 a year), the domain and the hosting.
- No cost for the licensing code itself: there is no server to run.

## Still open

- When 1.0 ships: set `VERSION` to `1.0.0` (0.x versions count as betas of version 1; `scripts/release.sh` accepts them).
- Telling owners of version 1 about version 2: the website and email. (Sparkle can also show a one-off
  "version 2 is available" note from the version-1 feed; not set up.)
- Publish the EULA and the privacy policy (drafts in `legal/`, after a lawyer has read them) on simplmaker.com, and link
  them from the product page and the app.
- Polar needs a website with the product, a refund policy and support contact for its review.
