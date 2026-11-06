@echo off
setlocal DisableDelayedExpansion
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Instaluj-MTZ-Logi.ps1"
if errorlevel 1 (
  echo Instalacja nie powiodla sie. Sprawdz komunikat powyzej.
  pause
  exit /b 1
)
