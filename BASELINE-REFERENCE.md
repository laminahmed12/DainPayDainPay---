# DainPay Working Reference Baseline

Date: 2026-10-10

## Current working reference (latest)
**DainPay V84 — Voice recording verified on the user's Samsung phone; Google Drive backup issue remains open**

- Working branch: `v84-voice-timeout-diagnostics`
- Voice-fix commit: `0858b6ece539f4065ebcf78eba41aad3fd394f21`.
- Backup diagnostic commit: `be93fbb0998e3b8434b7d83b341644ac98b8a779` (shows the underlying Google Drive failure class instead of a generic message).
- Workflow diagnostic commit: `b52940cbd120c3d0952c3799968e85689fbd9925` (makes signing-certificate extraction fail visibly rather than silently returning an empty certificate file).
- Latest code state at this reference update: branch `v84-voice-timeout-diagnostics`; see branch HEAD for the exact current SHA.
- Android Release workflow run: `38026394107` — completed successfully (analysis + release APK build + artifact upload).
- APK artifact: `dainpay-v84-voice-timeout-diagnostics-release` (artifact ID `11660241624`; expires 2027-01-08).
- On-device verification: user confirmed voice recording now works and screenshot shows a saved voice draft with recognized Arabic text and amount. Preserve this working voice flow; do not refactor it while fixing backup.
- Current open issue: Settings shows local encrypted backup succeeded, but Google Drive access failed at 2026-10-10 07:25. `android/app/google-services.json` currently has an empty `oauth_client` array for `com.adreemk.dainpay`; this strongly suggests missing/incomplete Android OAuth configuration, but the exact failure should be confirmed from the improved app error. Do not change customer-data storage or the working voice flow. Configure/verify the app's signing SHA-1/SHA-256, Google Sign-In provider, and Google Drive API as needed; use a stable release signing key for release builds.

## Earlier reference
**DainPay Cloudflare Owner Login + Code Generation — Working Reference**

## Verified from the user's device
- The app opens the Activation Management page.
- Owner mode/login succeeded after the Cloudflare Worker was updated.
- The Generate Activation Code action succeeded and displayed a code.
- Cloudflare Production Worker is `dainpay-activation`.
- Production bindings include KV namespace `ACTIVATION_CODES` and secret `OWNER_ADMIN_PIN`.
- Worker endpoint: `https://dainpay-activation.lamin-ahmed12.workers.dev`.

## Source reference
- Repository: `laminahmed12/DainPayDainPay---`
- Working branch: `v82-unified-repair`
- Worker normalization commit: `28af9a6ff520ac322efe1cc34c3bfea4fe617154`
- Worker was deployed to Cloudflare Production with PIN normalization on both the submitted PIN and configured secret.

## Not yet verified
- Redeeming a generated activation code on a separate test installation/device.
- Full regression tests for voice recording, local encrypted backup, Google Drive backup/restore, and existing customer/transaction flows.
- A final Release APK built from this exact working state.

## Rules for all future modifications
1. Treat this state as the baseline; do not start from scratch.
2. Make changes incrementally and keep them on a separate branch until tested.
3. Do not remove or regress owner login, activation-code generation/redemption, voice recording, local encrypted backup, Google Drive backup/restore, or customer/transaction data handling.
4. After every change, run static analysis/build checks and verify the affected feature on-device when possible.
5. Keep the known-good reference intact so a failed change can be reverted.
6. Do not claim full release readiness until activation redemption and regression tests pass.
