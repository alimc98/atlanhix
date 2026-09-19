@echo off
rem TEMPORARY helper (not for commit): detached flutter build with mirror env
cd /d "%~dp0"
set PUB_HOSTED_URL=https://pub.flutter-io.cn
set FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
set JAVA_HOME=C:\Program Files\Android\Android Studio\jbr
set PATH=%JAVA_HOME%\bin;%USERPROFILE%\dev\flutter\bin;%PATH%
call flutter build apk --debug > "%~dp0android\build_apk_log.txt" 2>&1
echo EXITCODE=%ERRORLEVEL% >> "%~dp0android\build_apk_log.txt"
