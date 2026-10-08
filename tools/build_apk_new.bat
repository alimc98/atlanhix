@echo off
rem Atlanhix APK build (Flutter 3.47.4 + local Android SDK on D:)
rem Survives spaces in the profile path by using 8.3-safe pushd.
setlocal
set "FLUTTER_ROOT=D:\dev\flutter"
set "PUB_HOSTED_URL=https://pub.flutter-io.cn"
set "FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn"
set "JAVA_HOME=C:\Program Files\Android\Android Studio\jbr"
set "ANDROID_SDK_ROOT=D:\Android\Sdk"
set "ANDROID_HOME=D:\Android\Sdk"
set "PATH=D:\dev\flutter\bin;C:\Program Files\Android\Android Studio\jbr\bin;C:\Program Files\Git\cmd;C:\Windows\System32\WindowsPowerShell\v1.0;C:\Windows\System32;C:\Windows;%PATH%"

cd /d "%~dp0.."
pushd "C:\Users\Alireza & Hosna\Documents\Atlanhix\android" || exit /b 1
call gradlew.bat %*
set GRADLE_EXIT=%ERRORLEVEL%
popd
exit /b %GRADLE_EXIT%
