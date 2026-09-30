# DainPay — Installment Removal Audit

Date: 2026-09-30
Branch: `feature/remove-installments`

## Result

The current DainPay repository contains no implementation of debt installments. A repository-wide code search found no references to:

- `installment`
- `installments`
- `installment_plan`
- `due_dates_array`
- `تقسيط`

Therefore no installment screen, widget, Dart model, Firestore field, Cloud Function, or workflow code was removed because none is present in the current repository.

## Actual financial model

DainPay currently represents financial movements with `Tx.type` values:

- `debt` — full debt entry
- `payment` — partial or full payment

The customer balance is calculated as:

`sum(debt) - sum(payment)`

The current Flutter source stores transactions locally and synchronizes them to Firebase Firestore under:

- `users/{uid}/customers`
- `users/{uid}/transactions`

No installment-specific collection or field is present in the current source.

## Backend finding

This repository is Firebase-based, not Supabase-based. It contains Firebase initialization, Firestore access, Firebase Auth, Firestore rules, and Firebase configuration. No Supabase client/configuration, Edge Function, migration, or SQL schema for DainPay exists in this repository.

The connected Supabase account was inspected separately. Its available projects are unrelated to DainPay (including School-Management, Adreemk-Attendance, etc.). No DainPay Supabase project was identified, so no unrelated production database was modified.

## Files reviewed

- `lib/main.dart` — transaction model and balance logic reviewed; no installment model or UI.
- `firestore.rules` — Firebase rules are present; no installment collection rule was found through repository search.
- `firebase.json` — Firebase project configuration.
- `.github/workflows/build-apk.yml` — release workflow; no installment logic.
- `pubspec.yaml` — Flutter dependencies; no installment package.
- `lib/voice_draft_page.dart` — unrelated voice-draft feature.
- `lib/pdf_service.dart` — unrelated legacy PDF service; not changed by this installment audit.

## Required invariant going forward

Any new financial feature must preserve the two-entry-type model:

1. `debt`
2. `payment`

A payment may be partial or complete. The remaining balance is always computed from the transaction ledger rather than an installment schedule.

No monthly installment notifications, installment plans, installment due-date arrays, or installment-specific tables should be introduced.
