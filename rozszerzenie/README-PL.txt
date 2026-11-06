MTZ — rozszerzenie do przekazywania logów do rozmowy ChatGPT
Wersja 0.1.1, beta. Opera / przeglądarki oparte na Chromium.
Rozszerzenie jest opcjonalne. Bez niego gotowy ZIP można przeciągnąć do rozmowy.

INSTALACJA JEDNORAZOWA
1. Wypakuj cały ZIP lub podmień cały dotychczasowy folder programu nową zawartością.
2. W Operze otwórz opera://extensions.
3. Włącz „Tryb programisty”. Wybierz „Załaduj rozpakowane” / „Wczytaj rozpakowane”.
4. Wskaż TEN folder „rozszerzenie”, zawierający manifest.json.
   Po opcjonalnej instalacji to %LOCALAPPDATA%\MTZ-Logi\Aplikacja\rozszerzenie.
5. Jeżeli Opera poprosi o dostęp do chatgpt.com lub połączenia lokalnego, zezwól
   temu rozszerzeniu. Nie wymaga dostępu do innych stron ani klucza API.
6. Po instalacji odśwież otwartą rozmowę ChatGPT.

UŻYWANIE
- Zbieracz działa na Twoim komputerze. Dopiero po kliknięciu przycisku
  „Przekaż wybraną do ChatGPT” udostępnia wybrany ZIP przez 127.0.0.1:17643.
  Dostęp wymaga losowego kodu ważnego przez 15 minut.
- W zbieraczu ustaw dokładny adres tej rozmowy, np. https://chatgpt.com/c/...
  Pozostaw zbieracz otwarty. Przycisk przekazania otworzy rozmowę w domyślnej
  przeglądarce. Ustaw Operę jako domyślną albo otwórz wygenerowany adres w Operze.
- Rozszerzenie podejmuje jedną próbę dołączenia wybranego ZIP-a do wskazanej rozmowy.
  Przy pełnej paczce wybieraj kolejne części z listy zbieracza i przekazuj osobno.
  Surowe pełne pliki nie są filtrowane; osobny ZIP diagnostyczny maskuje dane w logach.
- ZACZEKAJ, sprawdź, czy załącznik jest widoczny i gotowy. Kliknij zwykłe „Wyślij”
  w ChatGPT. Rozszerzenie nigdy nie wysyła wiadomości samo.
- Odbiór w formularzu nie oznacza zakończonego wysłania. ChatGPT może odrzucić
  plik, format lub rozmiar; wtedy przeczytaj komunikat strony.
- Nie zmienia tekstu wiadomości ani istniejących załączników. Gdy formularz
  ma zablokowane dodawanie plików, rozszerzenie czeka na jego odblokowanie.
- Zamknięcie panelu przerywa próbę dołączenia. Zmiana rozmowy podczas odbioru
  uniemożliwia dołączenie paczki w nowej rozmowie.

GDY NIE DZIAŁA
- Pozostaw otwarte okno zbieracza i tę samą rozmowę.
- Po przeładowaniu lub aktualizacji rozszerzenia odśwież stronę rozmowy.
- Jeśli trzeba, kliknij „Ponów dołączenie”.
- Jeżeli formularz ChatGPT został zmieniony, dołączenie może przestać działać.
  Przeciągnij wtedy ZIP z folderu otwartego przez zbieracz do rozmowy i wyślij.
- Nie wyłączaj zabezpieczeń przeglądarki. Brak połączenia lokalnego można obejść
  ręcznym dołączeniem gotowej paczki.

ZAKRES DOSTĘPU
Rozszerzenie ma skrypt tylko na https://chatgpt.com/* oraz dostęp sieciowy tylko
do http://127.0.0.1:17643/*. Nie odczytuje cookies, haseł, kluczy API ani tokenów
konta. Nie zapisuje kodu przekazania ani paczki. Działa dopiero po otrzymaniu
specjalnego adresu ze zbieracza; bez niego nie czyta formularza rozmowy.
Paczka trafia do OpenAI przez zwykłe dodanie pliku w wybranej rozmowie.
Nie używa prywatnych endpointów ChatGPT ani publicznego API OpenAI.

OGRANICZENIA TESTÓW
Automatyczne testy obejmują kontrolę nadawcy, kodów, adresów, nazw, rozmiarów,
formatu ZIP i wybór jednoznacznego pola załącznika. Testy te nie potwierdzają
bieżącego interfejsu strony ChatGPT ani działania rozszerzenia w Twojej Operze.
Pełne przekazanie w zalogowanej rozmowie wymaga sprawdzenia po instalacji.

ŹRÓDŁA TECHNICZNE (dokumentacja odczytana 2026-10-30)
https://developer.chrome.com/docs/extensions/develop/concepts/network-requests
https://developer.chrome.com/docs/extensions/develop/concepts/match-patterns
https://developer.chrome.com/docs/extensions/develop/concepts/messaging
https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts
https://developer.mozilla.org/en-US/docs/Web/API/HTMLInputElement/files
https://developer.mozilla.org/en-US/docs/Web/API/DataTransfer/DataTransfer
https://dev.opera.com/extensions/basics/
https://help.opera.com/en/extensions/
https://developers.openai.com/api/reference/resources/files/methods/create
