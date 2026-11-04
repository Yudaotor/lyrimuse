# Lyrimuse-URL-Schema

*[English](url-scheme.md) · [简体中文](url-scheme.zh-CN.md) · [日本語](url-scheme.ja.md) · [한국어](url-scheme.ko.md) · [Español](url-scheme.es.md) · [Français](url-scheme.fr.md) · **Deutsch** · [Italiano](url-scheme.it.md) · [Português (Brasil)](url-scheme.pt-BR.md) · [Tiếng Việt](url-scheme.vi.md) · [Русский](url-scheme.ru.md)*

Mit Links, die mit `lyrimuse://` beginnen, steuerst du Lyrimuse aus der App „Kurzbefehle“, aus Raycast, Alfred, Stream Deck, dem Terminal (`open 'lyrimuse://…'`) und ähnlichen Tools: Fenster und Einstellungsseiten öffnen, Liedtexte ein- oder ausblenden, die Wiedergabe steuern, das Timing verschieben oder abfragen, was gerade läuft.

Die gängigsten kannst du unter **Deep Links** unten in Einstellungen › Tastaturkurzbefehle kopieren. Bewege den Zeiger dort über einen Kurzbefehl, um den Link für diese Aktion zu kopieren.

## Allgemeine Regeln

- Groß- und Kleinschreibung spielt bei Links keine Rolle.
- Ein Link, den Lyrimuse nicht erkennt, bewirkt nichts und zeigt „Unbekannter Link“ an.
- Jeder Link, der ein Fenster öffnet, akzeptiert `background=1`: Das Fenster erscheint, aber Lyrimuse kommt nicht in den Vordergrund und übernimmt nicht den Tastaturfokus. Zum Beispiel `lyrimuse://lyrics-window?background=1`.
- Umschaltaktionen akzeptieren `on=1` oder `on=0`, um einen Zielzustand festzulegen (`true` / `false` und `on` / `off` funktionieren ebenfalls), sodass zweimaliges Ausführen dasselbe Ergebnis liefert. Ohne diesen Parameter schalten sie um.
- Auch Webseiten können `lyrimuse://`-Links öffnen (dein Browser fragt vorher nach), deshalb sind nur leicht rückgängig zu machende Aktionen verfügbar: Umschalter, Fenster öffnen, Wiedergabesteuerung und Timing-Korrekturen. Nichts davon löscht oder bearbeitet Liedtexte oder greift auf deine Accounts zu.

## Fenster öffnen

| Link | Was er bewirkt |
|---|---|
| `lyrimuse://lyrics-window` | Öffnet das Liedtextfenster |
| `lyrimuse://lyrics-window/search` | Öffnet das Liedtextfenster und das Fenster „Liedtext suchen“ (dasselbe wie bei `lyrics-search`) |
| `lyrimuse://lyrics-manager` | Öffnet die Liedtext-Verwaltung |
| `lyrimuse://lyrics-search` | Öffnet das Fenster „Liedtext suchen“ für den aktuellen Titel |
| `lyrimuse://menubar-panel` | Öffnet oder schließt das Menüleisten-Panel |
| `lyrimuse://menubar-panel?quick=overlay` | Öffnet das Menüleisten-Panel bei den Schnelleinstellungen einer Kachel (öffnet nur, schließt nie). `quick` ist einer der Werte `overlay`, `notch`, `menubar`, `touchbar`, `lyrics-window`, `lyrics-manager` |
| `lyrimuse://menubar-menu` | Öffnet das Menü des Menüleistensymbols |
| `lyrimuse://onboarding` | Öffnet die Einrichtung |
| `lyrimuse://whats-new` | Zeigt, was in der installierten Version neu ist |

## Einstellungen öffnen

`lyrimuse://settings` öffnet die Einstellungen. Hänge einen Pfad an, um direkt zu einer Seite zu springen, und ein weiteres Segment, um zu einem Abschnitt dieser Seite zu springen.

| Pfad | Seite | Abschnitte |
|---|---|---|
| `/lyrics` | Liedtext | `/fetch` oder `/sources` Quelle, `/translation` oder `/language` Sprache, `/display` oder `/timing` Timing, `/manage` oder `/library` Liedtext-Bibliothek |
| `/player` | Player | `/players` Player, `/linkage` Starten & Beenden, `/permissions` Berechtigungen & Dienste |
| `/appearance` | Liedtext-Anzeige | `/overlay` Schwebender Text, `/notch` Notch, `/menu-bar` Menüleiste, `/touch-bar` Touch Bar, `/lyrics-window` Liedtextfenster |
| `/shortcuts` | Tastaturkurzbefehle | — |
| `/general` | Allgemein | — |
| `/about` | Über | — |
| `/account/lastfm` | Last.fm | `/stats` Statistik, `/chart` Charts, `/on-this-day` Spuren, `/settings` Regeln |
| `/account/listenbrainz` | ListenBrainz | — |
| `/account/discord` | Discord | `/display` Was angezeigt wird, `/buttons` Buttons, `/privacy` Datenschutz |
| `/account/relay` | Web-Push | — |
| `/account/bark` | Push-Mitteilungen | — |
| `/software-update` | Softwareupdate | Hänge `?check=1` an, um zusätzlich nach Updates zu suchen |
| `/lastfm-suggestions` | Vorschläge für den Last.fm-Account | — |
| `/labs` | Labor | — |

Zum Beispiel `lyrimuse://settings/appearance/overlay` oder `lyrimuse://settings/software-update?check=1`. Ein unbekannter Pfad öffnet einfach die Einstellungen; ein unbekannter Abschnitt öffnet die Seite bei dem Abschnitt, den du zuletzt angesehen hast.

## Aktionen: `lyrimuse://action/<name>`

Das sind dieselben Aktionen wie die Tastaturkurzbefehle unter Einstellungen › Tastaturkurzbefehle. Sie führen denselben Code aus und zeigen dieselbe Rückmeldung.

### Anzeige

| Name | Was sie bewirkt | Parameter |
|---|---|---|
| `toggle-overlay` | Blendet den schwebenden Text ein oder aus | `on` |
| `toggle-notch` | Blendet den Notch-Text ein oder aus | `on` |
| `peek-notch` | Klappt den Notch-Text für ein paar Sekunden aus; erneut ausführen schließt ihn früher | — |
| `toggle-menubar-lyrics` | Blendet den Menüleisten-Text ein oder aus | `on` |
| `toggle-touchbar` | Klappt den Touch Bar-Liedtext aus oder ein (nur Macs mit Touch Bar) | — |
| `toggle-all-lyrics` | Blendet alle Liedtexte aus: Was von schwebendem Text, Notch- und Menüleisten-Text eingeschaltet ist, wird ausgeblendet, und erneutes Ausführen holt genau diese zurück | `on` (`0` blendet aus, `1` stellt wieder her) |
| `toggle-lock-position` | Sperrt oder entsperrt die Position des schwebenden Texts | `on` |
| `toggle-translation` | Blendet Übersetzungen ein oder aus | `on` |
| `toggle-romanization` | Blendet die Umschrift ein oder aus | `on` |
| `overlay-font-larger` | Vergrößert den schwebenden Text | — |
| `overlay-font-smaller` | Verkleinert den schwebenden Text | — |

### Fenster

| Name | Was sie bewirkt | Parameter |
|---|---|---|
| `open-lyrics-manager` | Öffnet die Liedtext-Verwaltung | — |
| `open-lyrics-window` | Öffnet das Liedtextfenster | — |
| `toggle-lyrics-window-mini` | Schaltet das Liedtextfenster zwischen Mini und Vollgröße um; ist es geschlossen, wird es in Mini geöffnet | `on` (`1` Mini, `0` Vollgröße) |
| `search-lyrics` | Öffnet das Fenster „Liedtext suchen“ | — |
| `open-settings` | Öffnet die Einstellungen | — |
| `open-player` | Holt den Player, den du gerade nutzt, in den Vordergrund | — |
| `toggle-menubar-panel` | Öffnet oder schließt das Menüleisten-Panel, wie ein Klick auf das Symbol in der Menüleiste | — |

### Liedtext-Timing

| Name | Was sie bewirkt | Parameter |
|---|---|---|
| `lyrics-advance` | Verschiebt den Liedtext dieses Titels um einen Schritt nach vorn | `step`: Sekunden für diese Korrektur (0 bis 5); ohne Angabe gilt der Schritt aus den Einstellungen |
| `lyrics-delay` | Verschiebt den Liedtext dieses Titels um einen Schritt nach hinten | `step`, wie oben |
| `lyrics-offset-reset` | Setzt den Liedtext-Versatz dieses Titels auf null zurück | — |

### Wiedergabe

| Name | Was sie bewirkt | Parameter |
|---|---|---|
| `play-pause` | Wiedergabe / Pause | — |
| `next-track` | Nächster Titel | — |
| `previous-track` | Vorheriger Titel | — |
| `toggle-favorite` | Favorisiert den aktuellen Titel oder entfernt ihn aus den Favoriten (sofern der Player das unterstützt) | `on` (`1` favorisieren, `0` entfernen) |

Zum Beispiel `lyrimuse://action/toggle-overlay?on=0` oder `lyrimuse://action/lyrics-advance?step=0.5`.

### Weitere Aktionen

| Link | Was er bewirkt |
|---|---|
| `lyrimuse://action/copy-lyric` | Kopiert die aktuelle Liedtextzeile in die Zwischenablage; hänge `?translation=1` an, um die Übersetzung mitzukopieren |
| `lyrimuse://action/surfaces?overlay=1&notch=0&menubar=1` | Legt in einem Schritt fest, welche Liedtexte angezeigt werden: `overlay` (schwebender Text), `notch`, `menubar`, jeweils `1` zum Einblenden oder `0` zum Ausblenden. Gib nur die an, die du ändern willst |
| `lyrimuse://action/lyrics-offset?ms=-300` | Setzt den Liedtext-Versatz dieses Titels auf einen exakten Wert in Millisekunden: positiv ist früher, negativ ist später, innerhalb von ±10000 |
| `lyrimuse://action/play-mode?mode=shuffle` | Legt den Wiedergabemodus fest: `mode` ist `list`, `shuffle`, `repeat-all` oder `repeat-one`. Modi, die der Player nicht beherrscht, fallen auf `list` zurück |

## Abfragen, was gerade läuft (x-callback-url)

```
lyrimuse://x-callback-url/now-playing?x-success=<callback URL>
```

Lyrimuse öffnet die `x-success`-URL und hängt die Angaben zum aktuellen Titel als Parameter an (Parameter, die `x-success` bereits enthält, bleiben erhalten):

| Parameter | Wert |
|---|---|
| `title` | Titelname |
| `artist` | Künstler |
| `album` | Album |
| `lyric` | Die aktuelle Liedtextzeile |
| `player` | Name des Players |
| `playing` | `1`, solange etwas läuft, `0` bei Pause oder wenn nichts geladen ist (ist nichts geladen, sind die Felder oben leer) |

Verwende in der App „Kurzbefehle“ die Aktion **X-Callback-URL öffnen** mit `lyrimuse://x-callback-url/now-playing` als URL. Die App fügt `x-success` selbst hinzu, und die zurückgegebenen Parameter werden zur Ausgabe der Aktion.

Damit Webseiten über diesen Link nicht sehen können, was du hörst, gelten für die Callback-URL zwei Einschränkungen: Sie darf keine Web-, Datei- oder Skript-URL sein (`http`, `https`, `file`, `ftp`, `javascript`, `data`, `about`, `blob` oder `lyrimuse` selbst), und sie muss auf deinem Mac von einer App geöffnet werden, die kein Browser ist. Andernfalls wird nichts zurückgesendet.
