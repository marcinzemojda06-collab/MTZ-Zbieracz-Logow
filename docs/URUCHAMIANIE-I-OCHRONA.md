# Problemy uruchamiania i komunikaty ochrony

## Zgłoszenie dotyczące 0.3.0 RC1

Przy uruchamianiu instalatora zgłoszono dwa komunikaty:

- program ochronny: **„Suspicious PowerShell script activity”** dla `Launch-MTZ.ps1`;
- instalator: **`CommandNotFoundException`**, wskazujący ten sam plik.

Te komunikaty wskazują na powiązany problem z dostępnością launchera.
Sam zrzut nie ustala, czy plik został usunięty, poddany kwarantannie,
czy odmówiono jego odczytu lub wykonania. Nie identyfikuje też jednoznacznie
producenta programu ochronnego. Przyczyna alarmu pozostaje otwarta.

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

## Zakres przygotowanej poprawki

Oba pliki CMD sprawdzają wymagane pliki przed uruchomieniem PowerShella.
Wrapper instalatora osobno sprawdza dostępność `Launch-MTZ.ps1`.
Wspólny instalator ponownie kontroluje przygotowany katalog przed
zastąpieniem wcześniejszej instalacji.

Brakujący lub niedostępny plik powinien zakończyć próbę jasnym komunikatem
i niezerowym kodem wyjścia. Komunikat wymienia niepełne rozpakowanie
oraz możliwe działanie ochrony jako przyczyny do sprawdzenia.

Poprawka nie zmienia konfiguracji antywirusa, nie odtwarza kwarantanny
i nie próbuje ukrywać zgłoszonego skryptu. Nie jest nowym wydaniem RC
ani potwierdzeniem, że antywirus zaakceptuje aplikację.

## Granice weryfikacji

Testy odtwarzają brak pliku, odmowę odczytu i utratę pliku w katalogu
przygotowanym do instalacji. Sprawdzają także zachowanie wcześniejszej
aplikacji, ustawień i paczek po odmowie instalacji.

Testy automatyczne uruchamiania nie zastępują oceny używanego antywirusa,
interaktywnego testu okna WinForms ani działania skrótu na komputerze
użytkownika. Suma SHA-256 pozwala porównać bajty pliku; sama nie jest
werdyktem bezpieczeństwa ani podpisem wydawcy.
