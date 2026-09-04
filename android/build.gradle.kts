allprojects {
    repositories {
        // v0.4: dl.google.com is flaky on this network (large jars fail
        // mid-download while HEAD probes succeed). Aliyun's Google mirror
        // serves identical artifacts and is reachable from this region;
        // google() remains first for canonical resolution.
        google()
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        mavenCentral()
    }
}

// v0.4: Android Studio's bundled JBR (JDK 25) — the system PATH java is 1.8,
// which Gradle 9.3 rejects. Pinning via gradle.properties is the supported
// mechanism (org.gradle.java.home is not a build-script symbol).
// See gradle.properties in this directory.
//
// v0.4 NOTE: `flutter build apk` resolves :connectivity_plus lint toolchain
// from dl.google.com, which 404s these jars on this network. The jars ARE in
// the gradle modules cache (sha1-verified) — run the android build with
//   gradlew --offline :app:assembleDebug
// (see docs/android/v0.4-device-test.md) or `flutter run` after one offline
// priming build. The aliyun google-mirror fallback is also configured in
// settings.gradle.kts for fresh machines.

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
