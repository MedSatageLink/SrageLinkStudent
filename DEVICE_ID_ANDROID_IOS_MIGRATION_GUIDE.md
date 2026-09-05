# دليل نقل نفس آلية `device_id` (Android / iOS)

## الهدف
هذا الدليل يشرح **نفس الآلية المستخدمة حالياً في تطبيق الطالب** للحصول على `device_id` وربطه بالاشتراك:
- Android: استخدام `ANDROID_ID` عبر حزمة `android_id`
- iOS: استخدام `identifierForVendor` عبر `device_info_plus`
- حفظ القيمة في `flutter_secure_storage` حتى لا تتغير بسبب إعادة القراءة

---

## 1) الحزم المطلوبة
أضف هذه الحزم في `pubspec.yaml` في المشروع الجديد:

```yaml
dependencies:
  flutter_secure_storage: ^9.2.4
  device_info_plus: ^12.1.0
  android_id: ^0.4.0
```

ثم نفّذ:

```bash
flutter pub get
```

---

## 2) أنشئ خدمة `device_id`
أنشئ ملف جديد: `lib/data/services/device_service.dart`

> هذه النسخة تطبق نفس الفكرة الحالية في تطبيق الطالب للموبايل (Android/iOS) مع fallback آمن.

```dart
import 'dart:io';
import 'package:android_id/android_id.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class DeviceService {
  static const String _deviceIdKey = 'device_id';

  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();

  Future<String> getDeviceId() async {
    // 1) إرجاع القيمة المحفوظة إذا كانت موجودة
    final cached = await _storage.read(key: _deviceIdKey);
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }

    // 2) توليد المعرف حسب المنصة
    final generated = await _generateDeviceId();

    // 3) حفظ المعرف للاستخدامات القادمة
    await _storage.write(key: _deviceIdKey, value: generated);

    return generated;
  }

  Future<String> _generateDeviceId() async {
    try {
      if (Platform.isAndroid) {
        // App-Scoped ANDROID_ID
        final value = await const AndroidId().getId();
        return value ?? _fallback();
      }

      if (Platform.isIOS) {
        // identifierForVendor
        final ios = await _deviceInfo.iosInfo;
        return ios.identifierForVendor ?? _fallback();
      }

      return _fallback();
    } catch (_) {
      return _fallback();
    }
  }

  String _fallback() {
    final now = DateTime.now();
    return 'fallback_${now.millisecondsSinceEpoch}_${now.microsecondsSinceEpoch}';
  }
}
```

---

## 3) استخدم `device_id` أثناء تفعيل الاشتراك
في خدمة التفعيل (مثلاً `AuthService` أو `SubscriptionService`):

```dart
final deviceId = await DeviceService().getDeviceId();

final response = await supabase.rpc(
  'activate_subscription_code',
  params: {
    'code_text': code,
    'device_id_param': deviceId,
    // باقي الباراميترات...
  },
);
```

> المهم: نفس `device_id` الذي أرسلته عند التفعيل يجب أن تستخدمه في أي عمليات لاحقة (مثل refresh/validation وربط FCM).

---

## 4) نقاط مهمة جداً قبل الاعتماد في الإنتاج

1. **Android (`ANDROID_ID`)**
   - مستقر غالباً على نفس الجهاز.
   - قد يتغير بعد `Factory Reset`.
   - هو **App-Scoped** في الإصدارات الحديثة، لذلك لا تتوقع دائماً نفس القيمة بين تطبيقين مختلفين.

2. **iOS (`identifierForVendor`)**
   - مستقر داخل نفس Vendor (نفس Team/Bundle Vendor).
   - قد يتغير إذا تم حذف كل تطبيقات نفس الـ Vendor من الجهاز ثم التثبيت مجدداً.

3. **التخزين الآمن**
   - استخدام `flutter_secure_storage` يقلل تغيّر القيمة من القراءة المتكررة ويجعل السلوك متناسقاً داخل التطبيق.

4. **لا تستخدم Advertising ID**
   - آلية التفعيل هنا لا تعتمد على `AD_ID`.

---

## 5) Checklist سريعة للمبرمج
- [ ] إضافة الحزم الثلاث (`android_id`, `device_info_plus`, `flutter_secure_storage`)
- [ ] إنشاء `DeviceService` بنفس منطق Android/iOS أعلاه
- [ ] استدعاء `getDeviceId()` قبل `activate_subscription_code`
- [ ] إرسال `device_id_param` للباك-إند
- [ ] استخدام نفس `device_id` في أي RPC لاحقة تعتمد على الجهاز
- [ ] اختبار على جهاز Android حقيقي وجهاز iPhone حقيقي

---

## 6) مرجع من تطبيق الطالب (الحالي)
- منطق `device_id` موجود في:
  - `lib/data/services/device_service.dart`
- استخدامه في تفعيل الاشتراك موجود في:
  - `lib/data/services/auth_service.dart`

إذا أردت، أستطيع أيضاً تجهيز نسخة ثانية من هذا الدليل بصيغة "اختلافات فقط" ليستخدمها الفريق بسرعة أثناء نقل الكود بين المشاريع.