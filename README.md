# MTZ — Zbieracz logów Minecrafta

**Experimental / Early Access — wersja eksperymentalna we wczesnym dostępie.**

**Nie zaleca się pobierania ani instalowania tej wersji do czasu wydania pełnej, stabilnej wersji.**

Aktualna wersja źródeł: **0.3.0-rc.2**, Windows 10/11.
Projekt jest nadal rozwijany; funkcje i sposób instalacji mogą się zmieniać.
To wersja testowa, która nie została zatwierdzona jako stabilna.

> [!WARNING]
> **Potwierdzona blokada RC2 przez RAV Endpoint Protection.**
> Zgłoszenie z 6 listopada 2026 r., godz. 23:54, dotyczy `Launch-MTZ.ps1`
> z dostarczonej paczki RC2. Tożsamość pliku potwierdzono skrótem SHA-1.
> Przyczyna wykrycia i jego prawidłowość pozostają niewyjaśnione.
> Poprawki instalatora i zaliczone testy kodu nie potwierdzają akceptacji przez RAV.
> Jeśli ochrona blokuje plik, przerwij instalację lub podmianę.

Status aktualny na **7 listopada 2026 r.**:
[szczegóły znanego problemu](docs/URUCHAMIANIE-I-OCHRONA.md)
oraz [status projektu](PROJECT-STATUS.json).
Repozytorium udostępnia kod źródłowy. GitHub Release nie został opublikowany.

Lokalny program do zbierania diagnostyki Minecraft Java i tworzenia pełnych
kopii instancji. Okno korzysta z Windows Forms oraz Windows PowerShell 5.1.

## Instalacja i podmiana podczas testów

Poniższa instrukcja opisuje wcześniej przygotowaną paczkę testową
`MTZ-Zbieracz-Logow-Podmiana-0.3.0-rc.2.zip`. Na komputerze z potwierdzoną
blokadą ochrony aktualizację należy przerwać. Zachowaj ustawienia i archiwa;
po częściowym nadpisaniu nie uruchamiaj mieszanki plików różnych wersji.

Jeśli masz kompletną paczkę testową, rozpakuj ją. Zamknij okno zbieracza
i poczekaj na zakończenie jego pracy.
W **Win + R** otwórz:

```text
explorer.exe "%LOCALAPPDATA%\MTZ-Logi\Aplikacja"
```

Skopiuj tam **całą zawartość** dołączonego folderu `Aplikacja`, razem
z podfolderami `bridge` i `rozszerzenie`, i zatwierdź zastąpienie plików.
Pliki mają trafić bezpośrednio do istniejącego `Aplikacja`.
Pierwszy start wykonaj przez **nowy `Uruchom-MTZ-Logi.cmd` w folderze docelowym**.
Tytuł okna powinien zawierać `0.3.0 RC2`.

Szczegółowe kroki: [PODMIANA-PL.txt](PODMIANA-PL.txt).
Ręczna podmiana nie tworzy automatycznej kopii poprzedniej aplikacji.
Ustawienia i zebrane ZIP-y są przechowywane obok folderu `Aplikacja`.

### Aktualizacja z kopią poprzedniej aplikacji

Z osobno rozpakowanej paczki można uruchomić `Aplikacja/Instaluj-MTZ-Logi.cmd`.
Instalator przygotuje i sprawdzi nową kopię przed podmianą; wcześniejszy
program zachowa w `Kopie-aplikacji`. Ten wariant obsługuje też pierwszą
instalację. Nie należy jednocześnie uruchamiać dwóch aktualizacji.

## Co zmienia RC2

- Kontrola wymaganych plików przez oba CMD przed uruchomieniem PowerShella.
- Osobne sprawdzenie dostępności `Launch-MTZ.ps1` przez wrapper instalatora.
- Kontrola kompletności przygotowanej kopii przed zastąpieniem starej aplikacji.
- Czytelne zatrzymanie próby, gdy pliku brakuje, jest pusty lub niedostępny.
- Kompletny folder aplikacji i instrukcja podmiany w jednym ZIP-ie.
- Numer RC2 w oknie i manifestach zbieracza.

Pełny opis: [ZMIANY-0.3.0-rc.2.txt](ZMIANY-0.3.0-rc.2.txt).

## Funkcje

- Szybka diagnostyka: ograniczone logi, raporty awarii i lista modów.
- Osobny tryb pełnej kopii, z podziałem dużych plików i SHA-256.
- Rzeczywisty procent wykonanej pracy i kooperatywne anulowanie.
- Wykrywanie zakończenia sesji wybranej instancji Minecraft Java.
- Wybór standardowych profili CurseForge lub ręcznej lokalizacji.
- Aktualizacja z zachowaniem ustawień i wcześniejszych archiwów.
- Opcjonalne rozszerzenie Opery/Chromium do dołączania ZIP-a do ChatGPT.
- Brak telemetrii i wymogu klucza API; wiadomości wysyła użytkownik.

Pełna kopia zachowuje oryginalne bajty i nie jest anonimizowana.
Przed udostępnieniem archiwum użytkownik sprawdza jego zawartość.

Instrukcja: [INSTRUKCJA-PL.txt](INSTRUKCJA-PL.txt).
Krótki start: [START-TUTAJ.txt](START-TUTAJ.txt).
Zakres danych: [PRYWATNOSC-PL.txt](PRYWATNOSC-PL.txt).

## Weryfikacja i zgłoszenie RAV

Builder wymaga świeżych wyników RC2 dla lokalnego testu launchera i Windows
PowerShell 5.1, udanego CI oraz sum wszystkich pakowanych plików.
Szczegóły i schemat dowodów:
[validation/release-0.3.0-rc.2/README.md](validation/release-0.3.0-rc.2/README.md).

Testy launchera używają prawdziwych plików i blokad, lecz tworzenie skrótu
COM oraz start GUI są symulowane. Interaktywne WinForms na Windows 10/11,
bieżąca Opera i zachowanie RAV wymagają osobnego sprawdzenia.
Historyczne raporty RC1 pozostają w swoim katalogu, bez przepisywania
ich jako wyników RC2. Zakres: [WERYFIKACJA-PL.txt](WERYFIKACJA-PL.txt).

**Wykrycia launchera RC1 oraz RC2 przez RAV Endpoint Protection pozostają
niewyjaśnione.** Nowy raport potwierdza, że blokada obejmuje również plik
RC2 wypakowany do Pobranych. Materiał do weryfikacji przez producenta
jest przygotowany, ale nie został wysłany. Opis:
[Problemy uruchamiania i komunikaty ochrony](docs/URUCHAMIANIE-I-OCHRONA.md).

## Testy kodu

Ze źródeł, z katalogu głównego aplikacji, kieruj nowe wyniki do katalogu RC2:

```powershell
New-Item -ItemType Directory -Force -Path @(
  '.\validation\release-0.3.0-rc.2\local',
  '.\validation\release-0.3.0-rc.2\session',
  '.\validation\release-0.3.0-rc.2\restore'
) | Out-Null
.\walidacja-launchera\Test-Launcher.ps1 -OutputDirectory .\validation\release-0.3.0-rc.2\local
.\session.tests.ps1 -OutputDirectory .\validation\release-0.3.0-rc.2\session
.\restore-release.tests.ps1 -OutputDirectory .\validation\release-0.3.0-rc.2\restore
```

Testy tworzą dane syntetyczne w katalogach tymczasowych. Na Linuksie użyj
`pwsh -NoProfile -File ...`. Test Windows uruchamia systemowy PowerShell 5.1.
Wyników zapisanych na Linuksie nie przedstawia się jako testu Windows.

## Budowanie paczki

Python 3.11 lub nowszy, bez dodatkowych bibliotek:

```text
python tools/build-release.py
```

Skrypt wymaga podsumowania i dowodów RC2. Domyślnie tworzy jeden ZIP podmiany
z folderem `Aplikacja` i instrukcją `PODMIANA-PL.txt`, a obok sumy SHA-256.
Źródła można dodatkowo spakować opcją `--with-sources`.
Builder nie publikuje plików przez Internet.

## Publikacja

Repozytorium:
[marcinzemojda06-collab/MTZ-Zbieracz-Logow](https://github.com/marcinzemojda06-collab/MTZ-Zbieracz-Logow).
Status publikacyjny: **Experimental / Early Access**. Ewentualne wydanie
GitHub należy oznaczyć jako **pre-release** i opisać znane ograniczenia.
Przygotowanie paczki do pobrania nie oznacza utworzenia GitHub Release.
Planowany tag tego kandydata: `v0.3.0-rc.2`.
Oznaczenie projektu nie zmienia numeru ani zawartości wcześniej przekazanego
ZIP-a. `VERSION.json` i raporty weryfikacji zachowują historyczne dane RC2;
bieżący status rozwoju i blokady opisuje `PROJECT-STATUS.json`.
Materiały: [PUBLIKACJA-PL.txt](PUBLIKACJA-PL.txt).

## Licencja

MIT — [LICENSE.txt](LICENSE.txt).
