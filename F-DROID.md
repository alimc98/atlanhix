# F-Droid Publication Guide (راهنمای انتشار در F-Droid)

F-Droid **خودش APK را از سورس بیلد می‌کند** — فایل APK آپلود نمی‌شود. یعنی پروژه باید
بامتاباداده (metadata) در مخزن `fdroiddata` بیلدپذیر و بازتولیدپذیر (reproducible) باشد.

## وضعیت فعلی پروژه (بررسی انجام‌شده)

| الزام | وضعیت | توضیح |
|---|---|---|
| لایسنس متن‌باز | ✅ MIT | فایل `LICENSE` موجود؛ فیلد `license: MIT` به pubspec اضافه شد |
| بدون دانلود کد اجرایی در زمان اجرا | ✅ | `BinaryManager` هرگز خودش باینری دانلود نمی‌کند؛ coreها بیرونی/باندل هستند |
| بدون تبلیغات/tracking | ✅ | فقط اتصال به سرورهای کاربر + probe سرویس‌دهی سلامت (Cloudflare trace) |
| AppID یکتا | ✅ | `com.atlanhix.app` |
| نسخه‌بندی صحیح | ✅ | `0.6.5+20` — versionCode افزایشی |
| **libbox.aar باینری از پیش بیلدشده** | ❌ **مسدودکننده اصلی** | فایل 26MB در `android/app/libs/` کامیت شده — F-Droid باینری از پیش ساخته در سورس را نمی‌پذیرد |
| Update checker درون‌برنامه‌ای | ⚠️ مرزی | فقط باز کردن مرورگر روی GitHub Releases است (نصب خودکار انجام نمی‌دهد) — معمولاً پذیرفته می‌شود ولی باید در متادیتا توضیح داده شود |
| **بیلد Flutter در fdroidserver** | ⚠️ | نیاز به recipe دقیق با نسخه‌های پین‌شده دارد |

## مسدودکننده اصلی: libbox.aar

F-Droid اجازه نمی‌دهد باینری (AAR/JAR/so) کامیت‌شده در سورس باشد، مگر اینکه در recipe
از سورس بیلد شود. libbox (سینگ‌باکس) GPL-3.0 است و باید با `gomobile` در خود recipe بیلد شود.
اسکریپت مرجع: [`tools/build_libbox.sh`](tools/build_libbox.sh) — همین منطق را در recipe استفاده می‌کنیم.

> نکته لایسنس: چون libbox (GPL-3.0) به اپ MIT لینک می‌شود، عملاً اپ اندروید باید تحت
> GPL-3.0 توزیع شود. در متادیتای F-Droid مقدار `License: MIT` اپ اصلی + ذکر باندل
> GPL-3.0 معمولاً پذیرفته می‌شود؛ در صورت درخواست reviewers، `License: GPL-3.0-or-later` بگذارید.

## مراحل ارسال (خلاصه اجرایی)

1. **بیلد libbox از سورس** را محلی تست کنید:
   ```bash
   tools/build_libbox.sh v1.14.0        # خروجی: android/app/libs/libbox.aar
   flutter build apk --release          # باید مثل قبل بیلد شود
   ```
2. **Fork** کنید: `gitlab.com/fdroid/fdroiddata`
3. متادیتای آماده را کپی کنید: [`fdroid/com.atlanhix.app.yml`](fdroid/com.atlanhix.app.yml)
   → به ریشه fdroiddata با نام `com.atlanhix.app.yml`.
4. تست محلی با fdroidserver:
   ```bash
   pip install fdroidserver
   fdroid readmeta
   fdroid build -v -l com.atlanhix.app
   ```
5. **Merge Request** به `fdroid/fdroiddata` با توضیح این موارد:
   - منشأ libbox: بیلد از سورس sing-box v1.14.0 با gomobile داخل recipe
   - engineهای دسکتاپ (xray/mihomo) فقط روی دسکتاپ استفاده می‌شوند و کاربر خودش تأمین می‌کند — در بیلد اندروید حضور ندارند
   - Update checker فقط مرورگر را باز می‌کند (بدون sideload)

## نکات مهم برای پذیرش سریع‌تر

- **شبکه در بیلد F-Droid محدود است**: gradle فقط از mavenCentral/google (از طریق پراکسی
  خودشان) و flutter فقط از pub (میرور fdroidserver) می‌گیرد. همه وابستگی‌ها باید از این
  مبابع بیایند — داریم ✓ (چک شد: همه پکیج‌ها pub.dev و maven استاندارد هستند؛ فایل
  محلی `libs/libbox.aar` با gomobile در recipe جایگزین می‌شود).
- **NDK/CMake**: recipe باید `ndk: r28` و نسخه cmake را مشخص کند (فعلأ r28c استفاده می‌شود).
- **بازتولیدپذیری**: fdroidserver از Flutter builds خروجی reproducible نمی‌گیرد مگر با
  پین کردن دقیق ابزارها؛ reviewers معمولاً diff بایت‌به‌بایت را از Flutter apps نمی‌خواهند.

## پس از پذیرش

- هر نسخه جدید = یک MR جدید در fdroiddata (فقط اضافه شدن بلاک `Build:` با versionCode جدید)
- ریلیزهای GitHub می‌توانند موازی ادامه یابند (کانال خودتان) — در اپ، update checker
  بهتر است نسخه‌های F-Droid را تشخیص ندهد/نWireها... (فعلاً فقط notification است، کافی است)
