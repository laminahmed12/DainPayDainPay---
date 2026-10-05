// PATCH v78: customer deletion uses local zero-balance as the user-visible eligibility gate,
// then performs a strict Firestore verification only when cloud access is available.
// If cloud verification is unavailable, deletion is blocked with a specific connectivity message.
// This file is intentionally updated on the repair branch only; main/90% is untouched.

// NOTE: Full source is preserved in the repair branch; this marker is used by the controlled
// workflow patcher to replace the deletion implementation without changing unrelated features.
