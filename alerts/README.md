# Pivot Alerts — تنبيهات البيفوت (alerts.twsiat.com)

تطبيق خاص على الموبايل: إشعار كل ما يوصل السعر لمستوى دعم أو مقاومة يومي (S1–S3، P، R1–R3)،
نزولاً أو صعوداً، مع الميل العام كمعلومة. الصياغة إخبارية فقط، بدون نصائح شراء أو بيع.

## من وين بتيجي الأسعار

```
MT5 (Exness Standard) + TwsiatPriceBridge 2.1
   ├─ شموع M5 المغلقة كل 30 ثانية  → prices_m5   (نفس جدول الموقع والمحرك)
   └─ آخر سعر كل 5 ثواني           → prices_live (جديد، db/020_alerts.sql)
                     │
          Supabase (alerts_feed / alerts_daily — محمية بـ ALERTS_TOKEN)
                     │
          alerts container على Hetzner → https://alerts.twsiat.com → إشعارات الموبايل
```

- المستويات: بيفوت يومي كلاسيكي من شمعة امبارح (يوم UTC = يوم سيرفر Exness)، مطابق لشارت MT5.
- إذا آخر سعر أقدم من دقيقتين (مثلاً الجسر لسا ما تحدّث لنسخة 2.1)، بيستعمل إغلاق آخر شمعة M5.

## التركيب (مرة وحدة)

1. **Supabase → SQL Editor:** شغّل `db/020_alerts.sql`. آخر سطر بيطبع `alerts_token`. انسخه.
2. **الجسر:** استبدل `TwsiatPriceBridge.mq5` بنسخة 2.1 بـ MetaEditor واضغط Compile (F7).
   الإعدادات القديمة (التوكن وقائمة الرموز) بتضل، والرموز الإضافية بتنضاف لحالها.
   تاريخ الرموز الجديدة بينبعث رمز كل 30 ثانية (حوالي 20 دقيقة للكل).
3. **GoDaddy → DNS:** سجل `A` باسم `alerts` يشير لـ IP السيرفر.
4. **على السيرفر:**
   ```
   ssh -t root@SERVER "curl -fsSL https://raw.githubusercontent.com/MorissSarkis/twsiat-rooms/main/deploy/alerts-install.sh | sh"
   ```
   بيسألك عن التوكن وعن كلمة سر التطبيق، وبيحفظهم بـ `deploy/.env` (ما بينرفعوا على GitHub).
5. افتح https://alerts.twsiat.com على الموبايل، سجّل دخول، الإعدادات ← تفعيل الإشعارات ← تنبيه تجريبي.
   على الآيفون: Safari ← مشاركة ← «إضافة إلى الشاشة الرئيسية» أول، وافتحه من الأيقونة.

## تحديث لاحقاً

```
cd /opt/twsiat-rooms && git pull && cd deploy && docker compose up -d --build alerts
```

## ملفات

| ملف | شو بيعمل |
|---|---|
| `engine.py` | قواعد التنبيه (وصول/اقتراب/كسر، ضد التذبذب) |
| `levels.py` | البيفوت، ATR، الميل العام (القاع/القمة) |
| `feeds.py` | مصادر الأسعار: `supabase` (السيرفر)، `mt5` (ويندوز)، `demo` |
| `service.py` | الحلقة كل 10 ثواني + حالة التطبيق |
| `server.py` / `web/` | التطبيق (تسجيل دخول، شاشات، إشعارات) |
| `webpush.py` | تشفير إشعارات الموبايل (RFC 8291/8292) |
| `config.yaml` | الأدوات والإعدادات — بدون أسرار |

البيانات (الأجهزة المسجلة، السجل، مفتاح الإشعارات) بـ `/opt/alerts-data` على السيرفر.
**لا تحذف `vapid.json`** وإلا لازم كل الأجهزة تفعّل الإشعارات من جديد.

تجربة على ويندوز بدون سيرفر: `python main.py --feed demo` (أسعار وهمية) أو `--feed mt5` مع MT5 مفتوح.
اختبارات: `python -m pytest tests`.
