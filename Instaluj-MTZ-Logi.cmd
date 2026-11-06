@echo off
setlocal DisableDelayedExpansion
rem Check the whole extracted application before starting PowerShell.
for %%F in (
  "%~dp0Launch-MTZ.ps1"
  "%~dp0MTZ-Logi.ps1"
  "%~dp0core.ps1"
  "%~dp0session.ps1"
  "%~dp0full-bundle.ps1"
  "%~dp0Collect-Worker.ps1"
  "%~dp0Restore-MTZ-Paczka.ps1"
  "%~dp0bridge\Bridge.cs"
  "%~dp0Instaluj-MTZ-Logi.ps1"
  "%~dp0Instaluj-MTZ-Logi.cmd"
  "%~dp0rozszerzenie\manifest.json"
  "%~dp0rozszerzenie\common.js"
  "%~dp0rozszerzenie\content.js"
  "%~dp0rozszerzenie\service-worker.js"
  "%~dp0rozszerzenie\README-PL.txt"
  "%~dp0INSTRUKCJA-PL.txt"
  "%~dp0WERYFIKACJA-PL.txt"
  "%~dp0LICENSE.txt"
  "%~dp0Uruchom-MTZ-Logi.cmd"
) do (
  if not exist "%%~fF" (
    set "MTZ_MISSING_FILE=%%~fF"
    goto :mtz_missing_file
  )
  if exist "%%~fF\" (
    set "MTZ_MISSING_FILE=%%~fF"
    goto :mtz_missing_file
  )
  if "%%~zF"=="0" (
    set "MTZ_MISSING_FILE=%%~fF"
    goto :mtz_missing_file
  )
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Instaluj-MTZ-Logi.ps1"
set "MTZ_INSTALL_EXIT=%ERRORLEVEL%"
if not "%MTZ_INSTALL_EXIT%"=="0" (
  echo Nie udalo sie zainstalowac MTZ. Sprawdz komunikat powyzej.
  echo Jesli komunikat dotyczy braku lub blokady pliku, sprawdz zawartosc paczki i historie ochrony.
  echo Szczegoly moga byc w blad-instalacji.txt w folderze danych MTZ-Logi.
  pause
)
exit /b %MTZ_INSTALL_EXIT%

:mtz_missing_file
echo Wymagany plik jest niedostepny lub pusty:
echo "%MTZ_MISSING_FILE%"
echo Paczka moze byc niekompletnie rozpakowana albo plik mogl zostac usuniety
echo lub przeniesiony do kwarantanny przez ochrone. Sprawdz zawartosc paczki
echo i historie ochrony. Operacja zostala przerwana przed uruchomieniem PowerShell.
pause
exit /b 2
