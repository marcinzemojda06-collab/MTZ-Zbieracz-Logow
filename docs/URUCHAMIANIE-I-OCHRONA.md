# Problemy uruchamiania i komunikaty ochrony

**Experimental / Early Access — stan na 7 listopada 2026 r.**

**Nie zaleca się pobierania ani instalowania tej wersji do czasu wydania pełnej, stabilnej wersji.**

## Potwierdzona blokada 0.3.0 RC2

Zrzut z RAV Endpoint Protection pokazuje wykrycie
**`Risk.Powershell.Script.Gen.D!YST`** z 6 listopada 2026 r., godz. **23:54**,
dotyczące pliku `Launch-MTZ.ps1` w wypakowanym folderze aplikacji w Pobranych.
Wyświetlany status to **„Wymagane działanie”**; nie potwierdza on wykonania
kwarantanny ani usunięcia pliku. Przy próbie kopiowania Windows zgłosił
**`0x800700E1`** i przerwał operację.

Porównano SHA-1 pokazany przez RAV z rzeczywistą zawartością
`Aplikacja/Launch-MTZ.ps1` w przekazanym ZIP-ie RC2. Skróty są identyczne.
Plik ma **14 130 bajtów**:

```text
SHA-1:   365ee1b5d2daecf6f1336695bf693db45e986c3b
SHA-256: 045e5b55bd32d534fa912632c49c5daf8d378e98280e2137393abc4d311efc8e
```

[Niezmienna wersja kodu launchera RC2](https://github.com/marcinzemojda06-collab/MTZ-Zbieracz-Logow/blob/6717527b1c4612f86537a7df339e832badd8befa/Launch-MTZ.ps1).

Potwierdzono więc, że nowe zgłoszenie obejmuje plik z paczki RC2.
Dokładna reguła detekcji i prawidłowość klasyfikacji nadal nie są ustalone.
Nie ma odpowiedzi producenta ani potwierdzenia fałszywego alarmu.

Przy tej blokadzie anuluj podmianę. Pominięcie wymaganego pliku może zostawić
niekompletną aplikację lub mieszaninę wersji. Zachowaj `ustawienia.json`,
`Paczki` i `Zadania`; pozostają poza folderem `Aplikacja`. Nie uruchamiaj
częściowo nadpisanej aplikacji. Powrót do poprzedniej wersji wymaga
zachowanej, kompletnej kopii oraz rozstrzygnięcia ewentualnej blokady ochrony.

Zgodnie z [dokumentacją kodów Windows](https://learn.microsoft.com/en-us/windows/win32/debug/system-error-codes--0-499-)
kod Win32 225 (`0xE1`, `ERROR_VIRUS_INFECTED`) oznacza przerwanie operacji
z powodu wykrycia wirusa lub potencjalnie niechcianego oprogramowania.
Sam kod nie rozstrzyga, czy detekcja jest trafna.

## Historyczne zgłoszenie dotyczące 0.3.0 RC1

Przy uruchamianiu instalatora zgłoszono dwa komunikaty:

- program ochronny **RAV Endpoint Protection (ReasonLabs)**:
  **„Suspicious PowerShell script activity”** dla `Launch-MTZ.ps1`,
  nazwa wykrycia **`Risk.Powershell.Script.Gen.D!YST`**;
- instalator: **`CommandNotFoundException`**, wskazujący ten sam plik.

Te komunikaty wskazują na powiązany problem z dostępnością launchera.
Szczegóły zdarzenia pokazują status **„Wymagane działanie”**. Nie ustalają,
czy plik został usunięty, poddany kwarantannie, czy odmówiono jego odczytu
lub wykonania. Producent został potwierdzony dodatkowym zrzutem nazwy
produktu. Przyczyna wykrycia pozostaje otwarta.

## Potwierdzone porównanie pliku RC1

Skrót SHA-1 widoczny w zgłoszeniu z 6 listopada 2026 r. jest zgodny
z `Launch-MTZ.ps1` w obu archiwach 0.3.0 RC1: aplikacji i źródeł.
Zgłoszony plik ma 12 870 bajtów.

```text
SHA-1:   27ac9b7d580b3a61c5c9eacbace183e264d53142
SHA-256: c602575082e84831389501e88464b9032e0f0378f9a6f0a0262c95bafea2820a
```

[Niezmienna wersja kodu zgłoszonego launchera](https://github.com/marcinzemojda06-collab/MTZ-Zbieracz-Logow/blob/230d17c8a243824a2bfbf2e69c490d890c771d0c/Launch-MTZ.ps1).

Porównanie identyfikuje wersję pliku; nie jest werdyktem bezpieczeństwa.
Launcher RC2 ma zmienioną zawartość i inne skróty. Jego osobne,
potwierdzone zgłoszenie opisano powyżej.

Historia zawiera też starsze wpisy z 1 listopada dotyczące pliku CMD,
pliku VBS i dwóch skrótów LNK. Zgodność zawartości tych starszych plików
z dostępnymi archiwami nie została potwierdzona. Archiwa RC1 nie zawierają
plików VBS; skrót LNK tworzy instalator. Starszych zgłoszeń nie należy
traktować jako wyników skanowania obecnego RC1.

## Co ustalono w kodzie

Przegląd pełnych launcherów RC1 i RC2 potwierdził kopiowanie lokalnych
plików aplikacji, tworzenie skrótu oraz uruchamianie PowerShella z ukrytą
konsolą i parametrem `-ExecutionPolicy Bypass`. W tych plikach nie znaleziono
mechanizmu pobierania plików z internetu, kodowanego polecenia ani zmiany
konfiguracji antywirusa. Ogólny opis alarmu wymienia przykłady zachowań;
nie jest zapisem wykonania każdego z tych działań.

Opis parametrów w dokumentacji Microsoftu:
[powershell.exe](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_powershell_exe?view=powershell-5.1)
oraz [polityki wykonywania](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies?view=powershell-5.1).
Parametr polityki dotyczy uruchamianej sesji. Sam nie wyłącza antywirusa.
Dokładna reguła, która wywołała wykrycie RAV, nie została potwierdzona.

## Kontakt z producentem ochrony

ReasonLabs udostępnia [ogólny formularz pomocy](https://reasonlabs.com/contact-us)
oraz adres `support@reasonlabs.com`. Jest to zweryfikowany punkt kontaktowy;
nie potwierdzono osobnego publicznego formularza dla tego wykrycia ani
zasad przesyłania próbek. O sposób bezpiecznego dostarczenia próbki należy
zapytać wsparcie.

[Opis techniczny do zgłoszenia](ZGLOSZENIE-RAV.txt) zawiera identyfikator
wykrycia, osobne skróty RC1 i RC2 oraz odnośniki do ich niezmiennego kodu. To przygotowany
materiał; zgłoszenie nie zostało wysłane i nie ma jeszcze odpowiedzi
producenta. Materiał nie zawiera zrzutów, prywatnych ścieżek ani logów gry.

## Co zrobić po takim komunikacie

1. Zamknij nieudany instalator.
2. W programie ochronnym otwórz **„Przejrzyj szczegóły”** lub historię zdarzenia.
3. Zachowaj nazwę programu ochronnego, pełną nazwę wykrycia, nazwę pliku
   i opis wykonanej czynności, np. blokada, usunięcie albo kwarantanna.
4. Przekaż te informacje autorowi. Przed publikacją zrzutu usuń prywatne
   ścieżki i inne dane konta.

Nie dodawaj wyjątku ani nie wyłączaj ochrony na podstawie samego tego opisu.
Nie przywracaj automatycznie zgłoszonego pliku z kwarantanny.
Rozpakowanie paczki ponownie nie rozstrzyga przyczyny alarmu.

## Zakres poprawki instalatora RC2

Oba pliki CMD sprawdzają wymagane pliki przed uruchomieniem PowerShella.
Wrapper instalatora osobno sprawdza dostępność `Launch-MTZ.ps1`.
Wspólny instalator ponownie kontroluje przygotowany katalog przed
zastąpieniem wcześniejszej instalacji.

Brakujący lub niedostępny plik powinien zakończyć próbę jasnym komunikatem
i niezerowym kodem wyjścia. Komunikat wymienia niepełne rozpakowanie
oraz możliwe działanie ochrony jako przyczyny do sprawdzenia.

Poprawka nie zmienia konfiguracji antywirusa, nie odtwarza kwarantanny
i nie próbuje ukrywać zgłoszonego skryptu. Została włączona do paczki
**0.3.0 RC2**, która ma własny numer wersji i instrukcję podmiany.
Nowe zgłoszenie potwierdza, że blokada ochrony wystąpiła również dla RC2.

## Granice weryfikacji

Testy odtwarzają brak pliku, odmowę odczytu i utratę pliku w katalogu
przygotowanym do instalacji. Sprawdzają także zachowanie wcześniejszej
aplikacji, ustawień i paczek po odmowie instalacji.

Testy automatyczne uruchamiania nie zastępują oceny używanego antywirusa,
interaktywnego testu okna WinForms ani działania skrótu na komputerze
użytkownika. Suma SHA-256 pozwala porównać bajty pliku; sama nie jest
werdyktem bezpieczeństwa ani podpisem wydawcy.
