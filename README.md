# MTZ — Zbieracz logów Minecrafta

**0.3.0-rc.1 — kandydat do wydania na Windows 10/11.**

Lokalna aplikacja do zbierania diagnostyki Minecraft Java i tworzenia pełnych
kopii instancji. Powstała jako narzędzie MTZ-belarus. Okno korzysta z Windows
Forms oraz systemowego Windows PowerShell 5.1.

## Uruchomienie

Wypakuj kompletną paczkę i uruchom `Uruchom-MTZ-Logi.cmd`.
Wybierz profil, pozostaw okno otwarte na czas sesji gry albo kliknij
**Przygotuj paczkę**. Po zakończeniu pokaż ZIP i dołącz go do zgłoszenia.

Instrukcja: [INSTRUKCJA-PL.txt](INSTRUKCJA-PL.txt).
Krótki start: [START-TUTAJ.txt](START-TUTAJ.txt).
Zakres danych: [PRYWATNOSC-PL.txt](PRYWATNOSC-PL.txt).

### Zgłoszony problem uruchamiania RC1

Zgłoszono alarm ochrony „Suspicious PowerShell script activity” dotyczący
`Launch-MTZ.ps1`, a następnie błąd instalatora wskazujący niedostępność tego
pliku. Przyczyna alarmu pozostaje nierozstrzygnięta. Poprawka w tej gałęzi
sprawdza kompletność plików i zatrzymuje niekompletną instalację; nie stanowi
potwierdzenia usunięcia alarmu antywirusowego.

Opis i potrzebne informacje diagnostyczne:
[Problemy uruchamiania i komunikaty ochrony](docs/URUCHAMIANIE-I-OCHRONA.md).

## Funkcje

- Szybka diagnostyka: ograniczone logi, raporty awarii i lista modów.
- Osobny tryb pełnej kopii, z podziałem dużych plików oraz SHA-256.
- Rzeczywisty procent wykonanej pracy i kooperatywne anulowanie.
- Wykrywanie zakończenia sesji wybranej instancji Minecraft Java.
- Wybór standardowych profili CurseForge lub ręcznej lokalizacji.
- Aktualizacja aplikacji z zachowaniem ustawień i wcześniejszych archiwów.
- Opcjonalne rozszerzenie Opery/Chromium do dołączania ZIP-a do ChatGPT.
- Brak telemetrii i wymogu klucza API. Wysłanie wiadomości pozostaje ręczne.

Pełna kopia zachowuje oryginalne bajty i nie jest anonimizowana.
Przed udostępnieniem archiwum użytkownik sprawdza jego zawartość.

## Status weryfikacji

Testy silnika, protokołu, odtwarzania, instalatora i logiki GUI wykonano na
PowerShell 7.4.13 / Linux oraz Node. Raporty zawierają jawne granice testów.
Atrapy kontrolek, COM i CIM nie zastępują testu na Windows.
Uruchomienie Windows PowerShell 5.1, wygląd WinForms, skrót pulpitu,
bieżąca Opera i zachowanie antywirusa wymagają końcowego sprawdzenia.

Nie oznaczać tego wydania jako stabilnej wersji 1.0 na podstawie samych
testów Linuksa. Bieżące wyniki: [WERYFIKACJA-PL.txt](WERYFIKACJA-PL.txt).

## Testy kodu

Ze źródeł, z katalogu głównego aplikacji:

```powershell
.\core.tests.ps1
.\full-bundle.tests.ps1
.\session.tests.ps1
.\restore-release.tests.ps1
.\walidacja-launchera\Test-Launcher.ps1
.\bridge\Test-Bridge.ps1
.\validation\release-0.3.0-rc.1\Test-Release-Core.ps1
.\validation\release-0.3.0-rc.1\Test-Progress.ps1 -Suite All
```

Testy tworzą syntetyczne dane w katalogach tymczasowych.
Na Linuksie użyj `pwsh -NoProfile -File ...`.
Testy rozszerzenia wymagają Node i zależności z dołączonego lockfile.
W katalogu `rozszerzenie/tests` wykonaj `npm ci`, potem `npm test`.

## Budowanie paczek

Python 3.11 lub nowszy, bez dodatkowych bibliotek:

```text
python tools/build-release.py
```

Skrypt wymaga zatwierdzonego raportu walidacji dołączonego do źródeł.
Tworzy osobny ZIP aplikacji i źródeł w `dist`, z sumami SHA-256.
Katalogi node_modules, dane użytkownika i historyczne raporty nie trafiają
do paczki aplikacji. Skrypt niczego nie publikuje przez Internet.

## Publikacja

Repozytorium projektu:
[marcinzemojda06-collab/MTZ-Zbieracz-Logow](https://github.com/marcinzemojda06-collab/MTZ-Zbieracz-Logow).

Pierwszy import zawiera źródła, dokumentację i testy wersji
**0.3.0-rc.1 (RC1)**. To kandydat do wydania, wymagający końcowego
sprawdzenia na Windows zgodnie z opisem weryfikacji powyżej.

Wydanie GitHub Release tej wersji nie zostało jeszcze opublikowane.
Planowany tag wydania: `v0.3.0-rc.1`.
Materiały do opisu i dalsze kroki znajdują się w
[PUBLIKACJA-PL.txt](PUBLIKACJA-PL.txt).

## Licencja

MIT — [LICENSE.txt](LICENSE.txt).
