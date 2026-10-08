@echo off
rem Atlanhix build launcher — run from the D:\atlanhix junction (space-free path).
rem Usage: D:\dev\build_apk.bat [flutter args]   e.g.  build apk --debug
setlocal
set "JAVA_HOME=C:\Progra~1\Android\ANDROI~1\jbr"
set "ANDROID_SDK_ROOT=D:\Android\Sdk"
set "ANDROID_HOME=D:\Android\Sdk"
set "PUB_HOSTED_URL=https://pub.flutter-io.cn"
set "FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn"
set "PATH=D:\dev\flutter\bin;%JAVA_HOME%\bin;C:\Windows\System32\WindowsPowerShell\v1.0;C:\Windows\System32;C:\Windows;%PATH%"
cd /d D:\atlanhix
flutter %*
exit /b %ERRORLEVEL%
