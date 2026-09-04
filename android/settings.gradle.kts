pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        // v0.4: mirror fallback order matching build.gradle.kts (dl.google.com
        // is flaky on this network; aliyun serves identical artifacts).
        google()
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        mavenCentral()
        gradlePluginPortal()
    }
}

// v0.4: same repository order for every plugin module's own resolutions
// (connectivity_plus et al fetch the lint toolchain from here).
// PREFER_SETTINGS forces project-level repositories (set by the Flutter
// plugin loader) to defer to THIS list — required because dl.google.com
// 404s the lint jars on this network while the aliyun mirror serves them.
// NOTE: two runs of the same build may be needed after cache invalidation —
// Gradle re-downloads artifact metadata even when the file cache is warm.
dependencyResolutionManagement {
    repositoriesMode = RepositoriesMode.PREFER_SETTINGS
    repositories {
        google()
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        // Flutter engine artifacts (io.flutter:arm64_v8a_debug et al)
        maven { url = uri("https://storage.googleapis.com/download.flutter.io") }
        mavenCentral()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

include(":app")
