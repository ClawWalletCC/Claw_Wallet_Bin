@echo off
setlocal

if /I not "%~1"=="binary-upgrade" (
  echo unknown command: %~1
  exit /b 1
)

set "CURRENT_VERSION=%~2"
set "LATEST_VERSION=%~3"
set "TARGET_BIN=%~4"
set "OLD_PID=%~5"

if "%TARGET_BIN%"=="" (
  echo missing target bin path
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sandbox-binary-upgrade.ps1" ^
  -CurrentVersion "%CURRENT_VERSION%" ^
  -LatestVersion "%LATEST_VERSION%" ^
  -TargetBin "%TARGET_BIN%" ^
  -OldPid "%OLD_PID%"

exit /b %ERRORLEVEL%
