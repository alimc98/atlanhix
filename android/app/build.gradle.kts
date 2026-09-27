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

    packaging {
        jniLibs {
            // libxray_core.so must be a real executable file in the native
            // lib dir — a compressed/packed .so cannot be exec()'d (v0.4.3).
            useLegacyPackaging = true
        }
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
        // v0.5.0 §release: `flutter build apk --split-per-abi` sets its own
        // splits.abiFilters (armeabi-v7a, arm64-v8a) — a hard ndk.abiFilters
        // here conflicts ("cannot be present when splits abi filters are
        // set") and kills the per-ABI release builds. The override property
        // still wins; the default arm64 pin applies ONLY when no override
        // AND no split run is in flight (the split run passes
        // -Psplit-per-abi=true through the flutter tool).
        val abiOverride = (project.findProperty("abi-filters") as String?)
            ?.split(',')?.map { it.trim() }?.filter { it.isNotEmpty() }
        val splitPerAbi = project.findProperty("split-per-abi") == "true"
        if (abiOverride != null) {
            ndk { abiFilters += abiOverride }
        } else if (!splitPerAbi) {
            ndk { abiFilters += listOf("arm64-v8a") }
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
