# DainPay Working Reference Baseline

Date: 2026-10-10

## Reference name
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
