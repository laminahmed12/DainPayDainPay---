# DainPay Cloud Functions deployment

## Required owner PIN secret

The owner PIN is intentionally not stored in source code or the Flutter application.

Before deploying the owner verification and activation-code functions, configure a 6–12 digit PIN in Firebase Secret Manager:

```sh
firebase functions:secrets:set OWNER_ADMIN_PIN --project dainpay-a29fc
```

Use a unique PIN; do not reuse a password used elsewhere. Then deploy the callable functions:

```sh
firebase deploy --only functions:verifyOwnerPin,functions:generateActivationCode,functions:redeemActivationCode --project dainpay-a29fc
```

Do not put the PIN in GitHub source, workflow YAML, app constants, or build arguments. The secret must be configured before deploying the two functions that consume it.

## App Check

App Check enforcement is not enabled in these callables yet. Register and configure the Android app in Firebase App Check, initialize the matching provider in the Flutter app, verify valid tokens on a test build, and only then enable enforcement on the callables. Enabling enforcement before client registration can block legitimate owner verification and activation.

## Release safety

Pull-request CI runs static analysis, regression tests, and a pre-release build only. It must not deploy Firestore rules or Cloud Functions to the production Firebase project. Production deployment is a separate, deliberate operation after validation.
