// v0.4: dl.google.com is flaky on this network (large jars fail mid-download
// while HEAD probes succeed). Force ALL plugin modules to the same repo
// order; buildscript too, so lint toolchain resolves from a reachable host.
subprojects {
    buildscript {
        repositories {
            mavenCentral()
            google()
        }
    }
    repositories {
        mavenCentral()
        google()
    }
}


// v0.4: Android Studio's bundled JBR (JDK 25) — the system PATH java is 1.8,
// which Gradle 9.3 rejects. Pinning via gradle.properties is the supported
// mechanism (org.gradle.java.home is not a build-script symbol).
// See gradle.properties in this directory.

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
