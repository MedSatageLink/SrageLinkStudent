# دليل نشر تطبيق الطالب StageLink Student على Google Play (من الصفر حتى النشر الرسمي)

هذا الملف مكتوب ليكون عملي جدًا: اتبع الخطوات بالترتيب و انسخ/الصق النصوص كما هي.

---

## 0) ما الذي تم تجهيزه مسبقًا داخل المشروع

تم تجهيز إعدادات أندرويد الأساسية للنشر في:
- `applicationId`: `com.stagelink.student`
- `namespace`: `com.stagelink.student`
- اسم التطبيق على الجهاز: `StageLink Student`
- تفعيل إعدادات `release` مع `R8/Proguard` وتصغير الحجم
- إضافة ملف مثال للتوقيع: `android/key.properties.example`
- تأمين git بعدم رفع أسرار التوقيع (`.jks` و `key.properties`)

> مهم: لا تغيّر `applicationId` بعد أول إصدار منشور.

---

## 1) المتطلبات قبل البدء

1. حساب Google Play Developer مفعل.
2. وجود سياسة خصوصية منشورة على رابط عام (HTTPS).
3. كمبيوتر عليه Flutter + Android SDK + Java 17.
4. أيقونة تطبيق احترافية (موجودة عندك غالبًا).

---

## 2) إنشاء مفتاح التوقيع (Upload Key)

من جذر مشروع الطالب `stagelink_student` افتح Terminal ونفّذ:

```powershell
Set-Location "d:\med\stagelink_student"
keytool -genkeypair -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

أدخل كلمة مرور قوية واحفظها في مكان آمن.

---

## 3) ربط المفتاح مع المشروع

### 3.1 أنشئ ملف `android/key.properties`

انسخ ملف المثال:

```powershell
Copy-Item "d:\med\stagelink_student\android\key.properties.example" "d:\med\stagelink_student\android\key.properties"
```

ثم عدّل الملف `android/key.properties` ليصبح (غيّر القيم):

```properties
storePassword=YOUR_STORE_PASSWORD
keyPassword=YOUR_KEY_PASSWORD
keyAlias=upload
storeFile=../../upload-keystore.jks
```

---

## 4) رفع رقم النسخة قبل كل إصدار

في `pubspec.yaml` غيّر السطر:

```yaml
version: 1.0.0+9
```

القاعدة:
- `1.0.1` = نسخة للمستخدم (`versionName`)
- `+10` = رقم بناء داخلي (`versionCode`) ويجب أن يزيد كل مرة.

---

## 5) بناء نسخة AAB رسمية

```powershell
Set-Location "d:\med\stagelink_student"
flutter clean
flutter pub get
flutter build appbundle --release
```

ملف الرفع الناتج:

```text
build\app\outputs\bundle\release\app-release.aab
```

---

## 6) إنشاء التطبيق في Play Console

1. Play Console > **Create app**
2. App name: **StageLink Student**
3. Default language: Arabic (Saudi Arabia) أو اللغة التي تريدها
4. App or game: App
5. Free or paid: حسب قرارك
6. أكمِل التصريحات المطلوبة

---

## 7) نصوص متجر Google Play (جاهزة للنسخ)

## اسم التطبيق

```text
StageLink Student
```

## وصف قصير (<= 80 حرف)

```text
تطبيق الطالب لإدارة التدريب السريري والمهام والحضور والتواصل الأكاديمي.
```

## وصف كامل

```text
StageLink Student هو تطبيق مخصص للطلاب لإدارة الرحلة التدريبية السريرية بشكل منظم وسهل.

أهم الميزات:
- متابعة المهام والتكليفات التدريبية.
- إدارة الحضور والأنشطة اليومية.
- تتبع التقدم في المتطلبات العملية.
- تجربة استخدام سريعة وآمنة.

نطوّر التطبيق باستمرار لتحسين الأداء وإضافة مزايا جديدة تدعم الطالب أثناء التدريب.

للدعم الفني:
[PUT_SUPPORT_EMAIL]
```

---

## 8) الأصول المطلوبة للمتجر (Store Listing Assets)

جهّز التالي قبل الإرسال:

1. **App icon**: 512x512 PNG
2. **Feature graphic**: 1024x500 PNG
3. **Phone screenshots**: على الأقل 2 (يفضل 4-8)
4. (اختياري) **7-inch/10-inch tablet screenshots**

نصيحة: التقط صور حقيقية من التطبيق الفعلي، بدون بيانات حساسة.

---

## 9) سياسة الخصوصية (إجباري غالبًا)

بسبب استخدام الإنترنت + معرفات جهاز + Bluetooth/Location في بعض السيناريوهات، ضع رابط سياسة خصوصية عامة.

قالب سريع (انسخه إلى صفحة ويب عامة وعدّل الحقول):

```text
Privacy Policy - StageLink Student

We respect your privacy. StageLink Student may process account information and technical identifiers required to deliver educational training features, authentication, attendance workflows, and app security.

Data may include:
- Account identifiers (such as email/phone if provided by your institution)
- Device/app technical identifiers for security and reliability
- Connectivity permissions (Bluetooth/Network) only when features require them

We do not sell personal data.

Contact: [PUT_SUPPORT_EMAIL]
Last updated: [PUT_DATE]
```

---

## 10) تعبئة نماذج الامتثال داخل Play Console

## 10.1 Data safety
أجب بدقة حسب السلوك الفعلي للتطبيق (لا تجيب عشوائيًا). غالبًا ستحتاج التصريح عن:
- معلومات الحساب (إن كانت تُستخدم)
- معرّفات الجهاز/التطبيق
- ممارسات الحماية (التشفير أثناء النقل)

## 10.2 App content
- Privacy policy: أدخل الرابط
- Ads: غالبًا **No** (إلا إذا عندكم إعلانات فعلًا)
- Target audience: اختر الفئة الصحيحة
- News/Health/Government: حسب طبيعة التطبيق (غالبًا لا)

## 10.3 Permissions declaration (مهم)
إذا ظهر طلب تفسير صلاحيات حساسة، استخدم نص واضح مثل:

```text
The app uses Bluetooth permissions to support educational attendance and proximity-based training workflows where enabled by the institution. Location permission on older Android versions is requested only as a technical requirement for Bluetooth scanning compatibility and is not used to track user location.
```

---

## 11) إنشاء إصدار داخلي ثم رسمي

1. **Testing > Internal testing**
2. Create new release
3. ارفع `app-release.aab`
4. اكتب Release notes (جاهز):

```text
Initial production-ready release for StageLink Student with performance and stability improvements.
```

5. انشر على Internal Testing
6. ثبّت التطبيق من رابط الاختبار وتحقق من:
   - تسجيل الدخول
   - الحضور/المهام
   - الميزات المعتمدة على Bluetooth (إن وجدت)

بعد نجاح الاختبار:
1. انتقل إلى **Production**
2. Create new release
3. اختر نفس الـ AAB (أو نسخة أحدث)
4. Review ثم Submit for review

---

## 12) قائمة فحص قبل الضغط على Submit

- [ ] ملف AAB مبني بنجاح
- [ ] `versionCode` مرفوع
- [ ] سياسة الخصوصية مضافة
- [ ] كل أقسام App content مكتملة
- [ ] Data safety مكتمل بدقة
- [ ] صور المتجر والأيقونة والـ feature graphic مرفوعة
- [ ] تم اختبار الإصدار داخليًا على جهاز حقيقي

---

## 13) بعد النشر الرسمي

1. راقب **Android vitals** (crashes / ANR)
2. راقب تقييمات المستخدمين
3. لأي تحديث لاحق:
   - ارفع `versionCode`
   - ابنِ AAB جديد
   - ارفع على Production

---

## 14) أوامر سريعة (نسخ/لصق)

```powershell
Set-Location "d:\med\stagelink_student"
flutter clean
flutter pub get
flutter build appbundle --release
```

```text
AAB Path:
build\app\outputs\bundle\release\app-release.aab
```

---

## 15) حل خطأ: failed to strip debug symbols

إذا ظهر هذا الخطأ، السبب غالبًا أن مسار Android SDK يحتوي مسافات (مثل اسم مستخدم ويندوز فيه مسافة).

الحل الأفضل (نهائي):
1. انقل Android SDK إلى مسار بدون مسافات مثل: `D:\Android\Sdk`
2. حدّث متغير النظام `ANDROID_HOME` إلى المسار الجديد
3. حدّث `android/local.properties` ليكون:

```properties
sdk.dir=D:\\Android\\Sdk
flutter.sdk=D:\\flutter_windows_3.32.8-stable\\flutter
```

4. أعد البناء.

مؤقتًا: تم تفعيل إعداد يمنع stripping للملفات الأصلية، لذلك قد يتم إنشاء AAB صالح لكن بحجم أكبر قليلًا.
