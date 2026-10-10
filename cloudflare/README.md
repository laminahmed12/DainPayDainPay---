# DainPay Cloudflare activation service (V82)

The Worker endpoint used by the app is `https://dainpay-activation.lamin-ahmed12.workers.dev`.

## Required Worker configuration
- KV binding: `ACTIVATION_CODES` → namespace `dainpay_activation_codes` (created for this deployment).
- Secret binding: `OWNER_ADMIN_PIN` → set privately in Cloudflare Workers & Pages → dainpay-activation → Settings → Variables and Secrets. Use the owner PIN intended for the production app; do not put it in source control.
- The Worker uses 15-minute, random, server-verified owner sessions. Activation codes are random, expire after one year, and can be redeemed once.

## Release note
The Worker has been deployed and the workers.dev endpoint enabled. The owner PIN secret must be configured before owner login and code generation will work; until then the Worker deliberately returns `service_not_configured`. Firebase remains in place for customer/transaction sync and the optional activation-state mirror. Owner login, code generation, and code redemption are routed through Cloudflare.
