@echo off
setlocal DisableDelayedExpansion
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Launch-MTZ.ps1"
set "MTZ_LAUNCH_EXIT=%ERRORLEVEL%"
if not "%MTZ_LAUNCH_EXIT%"=="0" (
  echo Nie udalo sie uruchomic MTZ. Sprawdz komunikat powyzej.
  echo Szczegoly sa w blad-instalacji.txt w folderze danych MTZ-Logi.
  pause
)
exit /b %MTZ_LAUNCH_EXIT%
