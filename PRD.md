# 📋 PRD & Architecture Document: DainPay Project

## 1. Project Overview (نظرة عامة)
- **Project Name:** DainPay
- **Core Purpose:** نظام إداري ومالي ذكي للمدارس يربط بين (سجل الحضور والغياب)، (إدارة الديون والرسوم الماليّة)، و(صلاحيات المواد والمدرسين).
- **Tech Stack:** 
  - Frontend: React / Next.js (أو المنصة المستهدفة)
  - Backend & Database: Firebase (Firestore, Firebase Auth, Cloud Functions)
  - Repository: GitHub
  - Hosting/Cloud: Firebase Hosting / Vercel

---

## 2. User Roles & Access Control (RBAC - الصلاحيات)
يتم تحديد الدور لكل مستخدم في Firebase Auth عبر `Custom Claims` أو مجموعة `users`:

1. **Super Admin (مدير النظام / المدرسة):**
   - كامل الصلاحيات (إدارة الماليات، المواد، الحضور، الحسابات).
2. **Accountant / Financial Officer (المحاسب):**
   - صلاحيات كاملة على وحدة الديون والرسوم، قراءة فقط للحضور.
3. **Teacher (المعلم):**
   - صلاحيات إدخال الحضور والغياب وتعديله **فقط للمواد والصفوف المصرح له بها**.
4. **Student / Parent (الاهل / الطالب):**
   - قراءة فقط لحالة الحضور والغياب، وجدول الديون والاقساط المتبقية الخاصة به.

---

## 3. Database Schema (Firestore Collections)

### A. Collection: `users`
```json
{
  "uid": "STRING (Primary Key)",
  "name": "STRING",
  "email": "STRING",
  "role": "STRING (admin | accountant | teacher | student)",
  "createdAt": "TIMESTAMP"
}
