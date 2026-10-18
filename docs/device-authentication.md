# Automatic QR / Device ID + Secret authentication

The existing pairing screens, layouts and QR payload format are preserved.
Users scan the same QR or enter the same ID and Secret. A trusted HTTPS function
checks a private salted scrypt hash and returns a Firebase custom token. The app
exchanges it automatically and Firebase restores/refreshes that session.
There is no email sign-in, registration screen or manual user approval.

## Deployment status and prerequisites

These are local implementation files. No Firebase rules, data, accounts,
functions, IAM permissions or billing settings have been changed by this work.
The existing public rules remain public until you replace them.

The supplied rules are **app-only**: publishing them will block the existing
unauthenticated ESP32 connection. There is no public-write workaround. Coordinate
this maintenance window, or finish authenticated firmware before production
cutover. Do not depend on Firebase access for physical safety controls.

Cloud Functions deployment needs a Firebase Blaze billing plan, Node.js 22,
Firebase CLI and administrator access. Initialize Authentication in the Firebase
console if it is not initialized. Custom-token authentication needs no email or
anonymous sign-in provider. Firebase may show automatic phone identities in its
Authentication user list; operators do not create or log into email accounts.

## Files

- `functions/index.js`: HTTPS verifier, generic failures, no credential logging,
  transaction-based rate limits (200 attempts/hour globally; 20/15 minutes per
  hashed IP bucket). Fixed 256 buckets bound storage; collisions or deliberate
  flooding can temporarily throttle legitimate pairing. This is not a billing
  cap or complete denial-of-service defense.
- `functions/provisioning.js` and `functions/scripts/provision-device.js`:
  administrator migration preserving ID, name, Secret and QR. The tool refuses to
  migrate unless the exact supplied rules have been deployed. It moves the old
  `AWG/device/deviceSecret` into `_private/deviceAuth` as a salted hash, then removes
  the plaintext in the same database update. It never prints the secret.
- `database.rules.json`: deny public/ordinary authenticated access, read AWG only
  with valid device claims, and allow only known app writes. Private hashes and
  rate counters are never client-readable. Parent AWG reads are blocked while a
  legacy plaintext device secret is still present.
- `firebase.test.json`: isolated local database/auth emulator configuration.

## Administrator setup (production maintenance window)

1. Export a database backup in Firebase Console and store it securely; it contains
   the old plaintext secret. Confirm the Device ID and keep your existing QR.
   Do not paste secrets or administrator keys into chat.
2. Install backend dependencies from the project root:

   ```powershell
   npm --prefix functions ci
   ```

3. Sign in to Firebase CLI using your administrator account. Deploy only the
   verifier initially (does not change the public database rules):

   ```powershell
   firebase deploy --only functions:awg-pairing --project awg-iot-system
   ```

   For automatic custom-token signing, enable the IAM Service Account Credentials
   API and grant the function's runtime service account permission to sign blobs
   on its signing service account. Use the Service Account Token Creator role
   scoped to that service account, not a project-wide owner role. Follow the
   official custom-token signing documentation below. Use Application Default
   Credentials for the migration, or keep an administrator service-account JSON
   outside this repository. Never bundle it into Flutter or ESP32 firmware.
4. At the agreed cutover, publish the entire `database.rules.json` file in
   Firebase Console > Realtime Database > Rules, or run:

   ```powershell
   firebase deploy --only database --project awg-iot-system
   ```

   Cloud reads/writes are now blocked until migration and new pairing complete.
   The ESP32 remains blocked pending the firmware work. If you need immediate
   lockdown before setup, use root `.read: false` and `.write: false`, accepting
   the cloud outage; the migration requires the final rules, not just lockdown.
5. Using administrator Application Default Credentials, migrate the existing
   secret. Replace `YOUR_EXISTING_DEVICE_ID` with the exact existing ID. Do not
   pass your secret as a command-line argument:

   ```powershell
   npm --prefix functions run provision -- awg-iot-system https://awg-iot-system-default-rtdb.asia-southeast1.firebasedatabase.app YOUR_EXISTING_DEVICE_ID
   ```

   The tool reads the existing credentials itself. It does not generate a new
   ID or Secret, change registration, rewrite sensor/history data, or print the
   secret. Rerunning migration preserves the private hash and disabled state.
   Confirm `AWG/registered` remains boolean `true` (legacy string `"true"` is also
   supported) and `AWG/device/deviceSecret` is absent after migration.
6. Rebuild/restart the updated Flutter app. The default verifier URL is
   `https://asia-southeast1-awg-iot-system.cloudfunctions.net/pairAwgDevice`.
   If deployment provides a different canonical HTTPS URL, use:

   ```powershell
   flutter run --dart-define=DEVICE_PAIRING_URL=YOUR_CANONICAL_HTTPS_FUNCTION_URL
   ```

   HTTP and redirects are rejected to avoid forwarding secrets. Existing local
   pairings without a Firebase session must pair once again with the **same** QR
   or credentials. Terms and guide completion stay saved. Disconnecting through
   the existing dialog signs the local Firebase session out. Tokens and secrets
   are not stored in SharedPreferences by app code; Firebase manages its own
   persistent session using its SDK.
7. Verify pairing (correct and incorrect secret), restart/session restoration,
   disconnect, dashboard access and each allowed write. Live sensor updates and
   physical controls require the authenticated ESP32 upgrade; they cannot be
   fully validated without the firmware.

## Permissions and revocation

An authenticated phone can read the existing AWG record after plaintext-secret
removal, write boolean `control/relay` and `control/systemEnabled`, manage
`live/notification`, and update validated weather data/location. It cannot rewrite
device credentials, register a device, forge sensor readings, read `_private`,
or delete the AWG/root. This project has a single shared AWG path; this is not a
multi-device ownership model.

The app uses a fresh automatic identity on each pairing. Access is granted by
signed `awgRole`, `awgDeviceId` and `awgAuthVersion` claims, never by a local
preferences flag or client-supplied role. Database rules also check the current
private device record and registration on requests.

To revoke all existing app sessions, change `_private/deviceAuth/authVersion` to
a new random value as administrator. The same credentials can pair again. Set
`_private/deviceAuth/enabled` to `false` to stop both pairing and database access.
Disconnect removes the local session; it does not revoke a token already stolen
from another phone. Per-phone administrative revocation is not part of this stage.

Keeping the same secret cannot undo earlier exposure under public rules. Anyone
who copied that secret or QR can still pair successfully; change it if exposure
is suspected. Strong secrets, protected QR labels, App Check and firmware/BLE
security remain relevant. App Check is not enabled here because ESP32 support
must be planned before enforcement. Review any other sensitive values inside AWG
before deployment; only the known legacy device secret is migrated by this tool.

## Local verification (no live Firebase writes)

```powershell
npm --prefix functions test
flutter test test/features/devices
```

For database-rule integration tests, install Java 21+ and run from project root:

```powershell
firebase emulators:exec --config firebase.test.json --only database,auth --project demo-awg-security "npm --prefix functions run test:rules"
```

The rules tests require emulator environment variables and cannot target a live
database. Production IAM, real token signing and ESP32 behavior still require
deployment verification.

Official references:
- https://firebase.google.com/docs/auth/flutter/custom-auth
- https://firebase.google.com/docs/auth/admin/create-custom-tokens
- https://firebase.google.com/docs/database/security
- https://firebase.google.com/docs/functions/get-started
