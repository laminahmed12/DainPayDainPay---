# DainPay — دَيْن

تطبيق عربي RTL لإدارة ديون العملاء والسداد والجمعيات للأفراد والتجار في ليبيا.

## الحالة الحالية
- Flutter Android project.
- واجهة عربية RTL.
- دفتر العملاء والبحث.
- تسجيل الدين والسداد.
- رصيد العميل والمدفوع والمتبقي.
- رسالة واتساب قابلة للتعديل.
- وضع فاتح/داكن.
- تجربة أولية لمدة 14 يوماً.
- GitHub Actions لبناء APK Release.
- حزم Firebase مضافة تمهيداً للربط السحابي.

## الربط السحابي
لإكمال Firebase فعلياً يجب إضافة إعدادات مشروع Firebase الخاص بالمالك، خصوصاً google-services.json وإعداد Authentication / Firestore / Storage وقواعد الأمان. لا يتم وضع مفاتيح أو رموز التفعيل السرية داخل الكود.

## بناء APK
من GitHub:
Actions → Build DainPay APK → Run workflow.

بعد نجاح البناء ستجد ملف DainPay-release ضمن Artifacts.

## الهوية
الاسم: DainPay | دَيْن
الحزمة: com.adreemk.dainpay
