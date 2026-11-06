# Dowody wydania 0.3.0-rc.2

Ten katalog zawiera schemat dowodów wymaganych przez `tools/build-release.py`.
Sam schemat nie potwierdza wykonania testów. Builder odmawia utworzenia
paczki bez rzeczywistego `release-validation.json` i wskazanych w nim plików.

## Co zebrać

1. Świeży `launch-results.json` z lokalnego uruchomienia
   `walidacja-launchera/Test-Launcher.ps1` dla RC2 oraz kod zakończenia procesu.
2. Świeży `launch-results.json` z Windows PowerShell 5.1 oraz kod zakończenia
   procesu. Test musi wykonać oba rzeczywiste przypadki CMD.
3. JSON przebiegu GitHub Actions pobrany po zakończeniu Windows CI.
   Można zachować pełny obiekt odpowiedzi API lub jego pola `status`,
   `conclusion`, `head_sha` i `html_url` bez zmieniania ich wartości.
4. Podsumowanie wydania z SHA-256 wszystkich plików `RUNTIME` i
   `PACKAGE_DOCUMENTS` zadeklarowanych w builderze, utworzone po sprawdzeniu
   wyników i zgodności pakowanych źródeł z testowaną rewizją.

Pliki dowodów przechowuj pod `validation/release-0.3.0-rc.2/`. Nie zapisuj
nowych wyników do katalogu historycznego RC1. Rozszerzenie obecnego raportu
o dodatkowe dane jest dozwolone; wymagane poniżej pola pozostają wiążące.

## Format podsumowania

Poniższy przykład jest **niewypełnionym szkieletem**. `pending` i znaczniki
w nawiasach celowo uniemożliwiają przejście kontroli. Dopiero faktycznie
udane sprawdzenia uzasadniają `status: passed-with-explicit-platform-limitations`
oraz `failed: 0`.

```json
{
  "application": "MTZ Zbieracz",
  "version": "0.3.0-rc.2",
  "status": "pending",
  "failed": null,
  "source_commit": "<dokladny SHA testowanej rewizji, 40 malych znakow hex>",
  "native_windows_validated": false,
  "live_opera_validated": false,
  "antivirus_resolution_verified": false,
  "production_sha256": {
    "<kazdy element RUNTIME, bez dodatkowych ani brakujacych sciezek>": "<SHA-256>"
  },
  "package_documents_sha256": {
    "PODMIANA-PL.txt": "<SHA-256>"
  },
  "evidence": {
    "local_launcher": {
      "path": "validation/release-0.3.0-rc.2/local/launch-results.json",
      "sha256": "<SHA-256 tego raportu>",
      "exit_code": null
    },
    "windows_launcher": {
      "path": "validation/release-0.3.0-rc.2/windows/launch-results.json",
      "sha256": "<SHA-256 tego raportu>",
      "exit_code": null
    },
    "windows_ci": {
      "path": "validation/release-0.3.0-rc.2/windows-ci.json",
      "sha256": "<SHA-256 pobranego obiektu przebiegu>"
    }
  }
}
```

Builder wymaga od obu testów kodu zakończenia `0`, stanu `PASS`,
`launcherRevision` równego `0.3.0-rc.2`, pełnej listy `checksPassed`
zgodnej z `checks` oraz co najmniej 68 sprawdzeń lokalnych i 70 Windows.
Hashe `launcherSha256` i `sharedLauncherSha256` muszą odpowiadać
pakowanym `Uruchom-MTZ-Logi.cmd` i `Launch-MTZ.ps1`.

Raport Windows musi mieć `actualWindowsRun: true`,
`actualWindowsPowerShell51: true`, wersję interpretera zaczynającą się
od `5.1.` oraz `nativeCmdPreflightRuns` co najmniej `2`.
Oba raporty zachowują `false` dla `actualGuiRun`, `actualComShortcut`,
`actualAntivirusTest` i `antivirusResolutionVerified`, zgodnie z zakresem
obecnego testu. Windows CI musi mieć `status: completed`,
`conclusion: success`, `head_sha` zgodne z `source_commit` oraz rzeczywisty
adres przebiegu w repozytorium `marcinzemojda06-collab/MTZ-Zbieracz-Logow`.

## Pakowanie

```text
python tools/build-release.py
```

Domyślny wynik to jeden ZIP z pełnym `Aplikacja/` i `PODMIANA-PL.txt` obok.
Builder tworzy `Aplikacja/release-manifest.json` z wersją, hashami,
identyfikatorem testowanej rewizji, liczbami sprawdzeń i adresem Windows CI.
Sprawdza CRC, listę wpisów oraz zgodność bajtów odczytanych z ZIP-a.
Obok ZIP-a zapisuje `release-files.json` i `SHA256SUMS.txt`.

`native_windows_validated: false` oznacza brak pełnej interaktywnej
akceptacji pulpitu Windows 10/11. Nie zaprzecza wykonaniu testu launchera
w Windows PowerShell 5.1. Wyniki CI nie rozstrzygają wykrycia RAV.
