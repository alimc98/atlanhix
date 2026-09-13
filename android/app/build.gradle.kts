plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// v0.4.1: the REAL sing-box engine — libbox compiled from sing-box v1.14.0
// source with gomobile (arm64-v8a). Bundled as a local AAR; see
// docs/android/v0.4.1-routing.md for the reproducible build recipe.
dependencies {
    implementation(files("libs/libbox.aar"))
}

android {
    namespace = "com.example.nexus"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.nexus"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // v0.4 (§23): arm64-v8a is the primary Android target. Fat APKs
        // (~154 MB with all ABIs) exceeded real-device storage during the
        // §26 install E2E, so the default packages arm64 only. Restore the
        // fat build (or target the x86_64 emulator — which additionally
        // requires a hypervisor: AEHD/WHPX) with:
        //   gradlew :app:assembleDebug -Pabi-filters=arm64-v8a,x86_64
        ndk {
            val abiOverride = (project.findProperty("abi-filters") as String?)
                ?.split(',')?.map { it.trim() }?.filter { it.isNotEmpty() }
            abiFilters += abiOverride ?: listOf("arm64-v8a")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
