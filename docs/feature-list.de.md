<!-- Erzeugt von scripts/gen-feature-list.py aus shared/feature-list.json und shared/settings-catalog.json; um die Liste zu ändern, bearbeite diese Dateien. -->

# Lyrimuse-Funktionsliste

[English](feature-list.md) · [简体中文](feature-list.zh-CN.md) · [繁體中文](feature-list.zh-Hant.md) · [日本語](feature-list.ja.md) · [한국어](feature-list.ko.md) · [Español](feature-list.es.md) · [Français](feature-list.fr.md) · Deutsch · [Italiano](feature-list.it.md) · [Português (Brasil)](feature-list.pt-BR.md)

Lyrimuse ist eine Open-Source-App (GPL-3.0) für wortgenau synchronisierte Liedtexte auf dem Mac, für macOS 14 oder neuer auf Apple Silicon und Intel. Sie zeigt Liedtexte für Apple Music, Spotify, QQ Music, NetEase Cloud Music, Kugou, Soda Music, KKBOX, Amazon Music, LX Music, Kaset, reAMP, VOX, Pine Player, foobar2000 sowie YouTube Music oder Spotify Web im Browser: schwebend auf dem Schreibtisch, neben der Notch, in der Menüleiste, auf der Touch Bar oder in einem eigenen Liedtextfenster, mit Übersetzungen und Umschrift (Pinyin, kantonesisches Jyutping, japanisches Romaji, koreanische Umschrift). Sie scrobbelt zu Last.fm und ListenBrainz und kann auf Discord zeigen, was du hörst. Die Oberfläche gibt es auf Englisch, vereinfachtem Chinesisch, traditionellem Chinesisch, Japanisch, Koreanisch, Spanisch, Französisch, Deutsch, Italienisch und brasilianisches Portugiesisch.

Diese Liste führt jede Funktion von Lyrimuse auf: was sie macht, wo sie in den Einstellungen liegt und ob sie nach der Installation ein- oder ausgeschaltet ist; am Ende stehen alle Einstellungen des Einstellungsfensters. Sie wird mit dem Code gepflegt und bei jeder Änderung aktualisiert.

## Inhalt

- [Aus, bis du sie einschaltest](#section-off-by-default)
- [Liedtexte finden](#section-lyrics)
- [Übersetzung, Umschrift und Zeilen](#section-text)
- [Wo Liedtexte erscheinen und wie sie aussehen](#section-display)
- [Player und Wiedergabe](#section-players)
- [Scrobbeln, Last.fm und Teilen](#section-listening)
- [Alltag](#section-general)
- [Alle Einstellungen](#section-all-settings)

<a id="section-off-by-default"></a>

## Aus, bis du sie einschaltest

Diese Funktionen bleiben nach der Installation aus. Schalte sie zuerst in den Einstellungen ein (manche brauchen zusätzlich ein Konto oder eine Berechtigung):

| Funktion | Wo einschalten |
|---|---|
| [Liedtexte direkt von Apple Music](#feature-apple-music-lyrics) | Einstellungen › Liedtext › Quelle › Liedtextquellen |
| [Vom Player gespeicherte Liedtexte nutzen](#feature-player-local-lyrics) | Einstellungen › Player › Berechtigungen & Dienste › Festplattenvollzugriff |
| [Liedtext aus der Datei bevorzugen](#feature-prefer-local-file-lyrics) | Einstellungen › Liedtext › Quelle › Liedtext aus der Datei bevorzugen |
| [Manuell gewählte Texte sperren](#feature-lock-hand-picked) | Einstellungen › Liedtext › Quelle › Manuell gewählte Texte sperren |
| [Übersetzen, wenn keine Übersetzung vorliegt](#feature-machine-translation) | Einstellungen › Liedtext › Sprache › Übersetzen, wenn keine vorhanden |
| [Lange Zeilen teilen, kurze zusammenfassen](#feature-split-join-lines) | Einstellungen › Liedtext › Timing und Umbrüche › Lange Zeilen teilen |
| [Liedtext an der Notch](#feature-notch-lyrics) | Einstellungen › Liedtext-Anzeige › Notch › Notch-Text |
| [Liedtext in der Menüleiste](#feature-menu-bar-lyrics) | Einstellungen › Liedtext-Anzeige › Menüleiste › Menüleisten-Text |
| [Liedtext auf der Touch Bar](#feature-touch-bar-lyrics) | Einstellungen › Liedtext-Anzeige › Touch Bar › Touch Bar-Liedtext |
| [HDR-Hervorhebung im Liedtextfenster](#feature-lyrics-window-hdr) | Einstellungen › Liedtext-Anzeige › Liedtextfenster › Farbe › HDR-Hervorhebung |
| [Mini-Fenster blendet sich bei Pause oder Vollbild aus](#feature-mini-window-auto-hide) | Einstellungen › Liedtext-Anzeige › Liedtextfenster › Verhalten › Bei Pause ausblenden |
| [Spotify Canvas als Hintergrund](#feature-spotify-canvas) | Einstellungen › Liedtext-Anzeige › Liedtextfenster › Hintergrund › Spotify Canvas |
| [Zeilenwechsel](#feature-line-transition) | Einstellungen › Liedtext-Anzeige › Schwebender Text › Layout › Zeilenwechsel |
| [Abblenden, wenn der Zeiger darauf zeigt](#feature-fade-on-hover) | Einstellungen › Liedtext-Anzeige › Schwebender Text › Verhalten › Beim Überfahren abblenden |
| [Position sperren, zum Ziehen lange drücken](#feature-lock-position) | Einstellungen › Liedtext-Anzeige › Schwebender Text › Verhalten › Position sperren |
| [Unsichtbar in Bildschirmfotos und bei Bildschirmfreigabe](#feature-hide-in-screenshots) | Einstellungen › Liedtext-Anzeige › Schwebender Text › Verhalten › In Bildschirmfotos ausblenden |
| [Bei Pause ausblenden oder verkleinern](#feature-hide-when-paused) | Einstellungen › Liedtext-Anzeige › Schwebender Text › Verhalten › Bei Pause ausblenden |
| [Bei Instrumentals und Titeln ohne Liedtext ausblenden](#feature-hide-when-no-lyrics) | Einstellungen › Liedtext-Anzeige › Schwebender Text › Verhalten › Bei Instrumental & ohne Text ausblenden |
| [Bei Werbung ausweichen](#feature-hide-during-ads) | Einstellungen › Liedtext-Anzeige › Schwebender Text › Verhalten › Bei Werbung ausblenden |
| [Notch auf dem Sperrbildschirm](#feature-notch-show-on-lock-screen) | Einstellungen › Liedtext-Anzeige › Notch › Verhalten › Auf Sperrbildschirm zeigen |
| [Schwebender Text weicht im Vollbild aus](#feature-overlay-hide-in-full-screen) | Einstellungen › Liedtext-Anzeige › Schwebender Text › Verhalten › Im Vollbild ausblenden |
| [Textzeile der Notch beim Daraufzeigen abblenden](#feature-notch-lyric-row-fade) | Einstellungen › Liedtext-Anzeige › Notch › Textzeile › Beim Überfahren abblenden |
| [Web-Liedtext: Smartphone oder Tablet als zweiter Bildschirm oder OBS-Browserquelle](#feature-web-lyrics) | Einstellungen › Liedtext-Anzeige › Liedtextfenster › Web-Liedtext |
| [YouTube Music und Spotify Web im Browser](#feature-web-players) | Einstellungen › Player › Web |
| [YouTube Music-Werbung automatisch überspringen](#feature-skip-youtube-ads) | Einstellungen › Player › Web › Werbung in YouTube Music überspringen |
| [Zusammen mit dem Player starten und beenden](#feature-player-linkage) | Einstellungen › Player › Starten & Beenden › Player beim Start öffnen |
| [Scrobbeln zu Last.fm und Hörprofil](#feature-lastfm) | Einstellungen › Last.fm › Regeln › Scrobble-Regeln |
| [Auch zu ListenBrainz scrobbeln](#feature-listenbrainz) | Einstellungen › Labor › ListenBrainz › Account-Infos |
| [Auf Discord zeigen, was du hörst](#feature-discord) | Einstellungen › Discord › Auf Discord anzeigen |
| [Eine teilbare Webseite mit dem, was du hörst](#feature-now-playing-page) | Einstellungen › Labor › Web-Push › Verbindungsinfo |
| [Tägliche, wöchentliche, monatliche und jährliche Hörrückblicke](#feature-digests) | Einstellungen › Push-Mitteilungen › Kanäle |
| [Still starten](#feature-silent-launch) | Einstellungen › Allgemein › Start & Mitteilungen › Still starten |
| [Bei Titelwechsel mitteilen](#feature-song-notifications) | Einstellungen › Allgemein › Start & Mitteilungen › Bei Titelwechsel mitteilen |
| [Automatische Updates und Betas](#feature-updates) | Einstellungen › Softwareupdate › Update-Einstellungen › Automatisch prüfen |

<a id="section-lyrics"></a>

## Liedtexte finden

<a id="feature-lyric-sources"></a>

### 15 Liedtextquellen, automatisch durchsucht

NetEase Cloud Music, QQ Music, Kugou, Kuwo, Migu, Musixmatch, LRCLIB, LyricFind, Deezer, AMLL, Soda Music, VIBE, Genie, PetitLyrics und Apple Music. Jede Quelle lässt sich ausschalten, umsortieren oder testen, um zu sehen, ob sie gerade erreichbar ist.

- Standardmäßig ein
- Einstellungen: Liedtext › Quelle › Liedtextquellen

<a id="feature-network-proxy"></a>

### Quellen außerhalb Chinas über einen Proxy erreichen

Ist eine Liedtextquelle außerhalb Chinas direkt nicht erreichbar, versucht Lyrimuse es erneut über den System-Proxy oder einen lokalen Proxy wie Clash. Du kannst auch selbst einen Proxyserver eingeben oder die Funktion ausschalten. Liedtextquellen in Festlandchina verbinden sich immer direkt.

- Standardmäßig ein
- Einstellungen: Allgemein › Netzwerk › Proxy

<a id="feature-apple-music-lyrics"></a>

### Liedtexte direkt von Apple Music

Verbinde dein Apple Music-Konto unter „Liedtextquellen“, um die Liedtexte von Apple Music selbst zu nutzen, viele davon Wort für Wort getimt. Erfordert ein Apple Music-Abo.

- Standardmäßig aus
- Einstellungen: Liedtext › Quelle › Liedtextquellen

<a id="feature-matching"></a>

### Smarte Zuordnung

Standardmäßig wird jedes Ergebnis nach Titel, Künstler, Länge und Version (live, instrumental usw.) bewertet, und das am besten zum laufenden Titel passende gewinnt. Du kannst stattdessen auf Quellenreihenfolge umstellen: keine Bewertung, verwendet wird die erste Quelle in deiner Reihenfolge, die einen Liedtext hat.

- Einstellungen: Liedtext › Quelle › Zuordnungsalgorithmus

<a id="feature-auto-upgrade"></a>

### Neu wählen, wenn die Zuordnung besser wird

Verbessert eine neue Version die Zuordnung oder Bewertung, werden vorhandene Liedtexte im Hintergrund erneut geprüft und ersetzt, wenn sich eine bessere Version findet. Schalte das aus, um einmal gewählte Liedtexte zu behalten.

- Standardmäßig ein
- Einstellungen: Liedtext › Quelle › Nach Algorithmus-Update neu wählen

<a id="feature-prefetch"></a>

### Liedtexte schon vor dem nächsten Titel

Liest die Warteschlange deines Players und sucht die Liedtexte der nächsten Titel im Voraus; gibt es keine Warteschlange, geht Lyrimuse den Rest des Albums durch. QQ Music, NetEase Cloud Music, Kugou, Soda Music und VOX brauchen dafür Festplattenvollzugriff.

- Standardmäßig ein
- Einstellungen: Liedtext › Quelle › Nächste Titel vorbereiten
- Einstellungen: Player › Berechtigungen & Dienste › Festplattenvollzugriff

<a id="feature-player-local-lyrics"></a>

### Vom Player gespeicherte Liedtexte nutzen

Liedtexte, die Apple Music, Spotify, Kugou, KKBOX, Amazon Music und LX Music bereits auf diesem Mac gespeichert haben, lassen sich direkt nutzen: dieselbe Version, die der Player zeigt, und schneller (bei Apple Music und Spotify nur für Titel, deren Liedtext der Player schon angezeigt hat). Bei QQ Music und NetEase Cloud Music wird der Titel anhand der lokalen Mediathek des Players erkannt, sodass genau diese Version ohne Suche geladen wird. Bei reAMP, VOX, Pine Player und foobar2000 sowie bei Apple Music oder LX Music, wenn eine lokale Datei aus deiner Mediathek oder lokalen Liste läuft, wird der Liedtext in der laufenden Datei oder eine gleichnamige .lrc-Datei verwendet. QQ Music, NetEase Cloud Music und Kugou brauchen dafür Festplattenvollzugriff für Lyrimuse in den Systemeinstellungen; ohne ihn werden Liedtexte weiterhin online gefunden.

- Standardmäßig aus
- Einstellungen: Player › Berechtigungen & Dienste › Festplattenvollzugriff

<a id="feature-prefer-local-file-lyrics"></a>

### Liedtext aus der Datei bevorzugen

Ist der laufende Titel eine Datei auf diesem Mac, wird zuerst ihre gleichnamige .lrc-Datei oder ihr eingebetteter Liedtext verwendet, statt mit online gefundenen Liedtexten verglichen zu werden. Das funktioniert mit jedem Player, der lokale Dateien abspielt. Passt dieser Liedtext nicht zu dieser Version (etwa weil die Länge abweicht), wird wie gewohnt online gesucht.

- Standardmäßig aus
- Einstellungen: Liedtext › Quelle › Liedtext aus der Datei bevorzugen

<a id="feature-lock-hand-picked"></a>

### Manuell gewählte Texte sperren

Wenn aktiviert, werden Liedtexte, die du von Hand aus den Suchergebnissen wählst, gesperrt, sodass spätere automatische Zuordnung und Neuzuordnung sie nie ersetzen.

- Standardmäßig aus
- Einstellungen: Liedtext › Quelle › Manuell gewählte Texte sperren

<a id="feature-lyrics-manager"></a>

### Liedtext-Verwaltung

Sieh dir den Liedtext jedes Titels an, bearbeite oder lösche ihn oder suche erneut danach, lösche mehrere auf einmal und räume die leeren Einträge auf, die Werbung und Podcasts hinterlassen. Gib einem einzelnen Titel einen eigenen Timing-Versatz. Versuche es bei allen Titeln ohne Liedtext in einem Durchgang erneut oder ordne die ganze Bibliothek nach den aktuellen Regeln neu zu, mit einstellbarer Pause zwischen den Titeln; alles, was du von Hand bearbeitet hast, bleibt unberührt.

- Einstellungen: Liedtext › Liedtext-Bibliothek › Liedtext-Bibliothek
- Einstellungen: Liedtext › Liedtext-Bibliothek › Fehlende Liedtexte zuordnen
- Einstellungen: Liedtext › Liedtext-Bibliothek › Ganze Bibliothek neu zuordnen
- Einstellungen: Tastaturkurzbefehle › Liedtext-Verwaltung öffnen
- Einstellungen: Liedtext › Liedtext-Bibliothek › Scanintervall

<a id="feature-song-entries"></a>

### Einträge desselben Titels

Derselbe Titel, in verschiedenen Playern oder aus verschiedenen Veröffentlichungen gespielt, wird als ein Titel erkannt: Seine Einträge teilen sich einen Liedtext, manuelle Bearbeitungen und Timing-Korrekturen werden übernommen, und die Wiedergaben werden zusammengezählt. In der Liedtext-Verwaltung vergleicht „Einträge dieses Titels“ den Liedtext jedes Eintrags Zeile für Zeile, und ein falsch zugeordneter Eintrag lässt sich abtrennen und später wieder zusammenführen. Schalte das Teilen aus, damit jeder Eintrag einzeln zugeordnet wird.

- Standardmäßig ein
- Einstellungen: Liedtext › Quelle › Liedtext für gleiche Titel teilen

<a id="feature-fix-lyrics"></a>

### Liedtext direkt tauschen oder korrigieren

Über das Menü ⋯ im Liedtextfenster suchst du nach anderen Liedtexten, startest die Zuordnung erneut oder bearbeitest den Liedtext in deinem eigenen Texteditor. Beim Bearbeiten wortgenau getimter Liedtexte ändern sich nur die Wörter, nie ihr Timing.

- Einstellungen: Tastaturkurzbefehle › Liedtext suchen

<a id="feature-import-lyrics"></a>

### Eigene Liedtext-Dateien importieren

Importiere Liedtexte als LRC, erweitertes LRC, TTML, QRC, KRC, YRC oder reinen Text für einen Song oder einen ganzen Ordner auf einmal: Die Dateien werden den Songs in deiner Bibliothek zugeordnet und vor dem Schreiben in einer Vorschau gezeigt. Wähle, ob importierte Texte den aktuellen ersetzen, ihn ersetzen und sperren oder nur Songs ohne Text ergänzen. Dateien zu Songs, die du noch nicht gehört hast, werden aufbewahrt und beim ersten Abspielen verwendet. Ein überwachter Ordner importiert neue Dateien automatisch.

- Einstellungen: Liedtext › Liedtext-Bibliothek › Liedtext-Ordner importieren
- Einstellungen: Liedtext › Liedtext-Bibliothek › Ordner-Import
- Einstellungen: Liedtext › Liedtext-Bibliothek › Überwachter Ordner
- Einstellungen: Liedtext › Liedtext-Bibliothek › Import-Bibliothek

<a id="feature-offline"></a>

### Funktioniert offline; Liedtexte sind einfache .lrc-Dateien

Jeder gefundene Liedtext wird auf deinem Mac zwischengespeichert und erscheint auch ohne Verbindung. Jeder Titel hat eine .lrc-Datei, dazu .tr.lrc und .roma.lrc für Übersetzungen und Umschrift. Das Wort-Timing wird standardmäßig als TTML gesichert, alternativ als .yrc, Enhanced LRC, QRC oder KRC. Die Dateien liegen standardmäßig in ~/Library/Application Support/me.yudaotor.lyrimuse/lyrics/, und der Ordner lässt sich verschieben.

- Einstellungen: Liedtext › Liedtext-Bibliothek › Liedtext-Ordner
- Einstellungen: Liedtext › Liedtext-Bibliothek › Wort-für-Wort-Format

<a id="section-text"></a>

## Übersetzung, Umschrift und Zeilen

<a id="feature-translation"></a>

### Übersetzungen

Übersetzungen, die mit dem Liedtext kommen, erscheinen unter jeder Zeile. NetEase Cloud Music, QQ Music und Kugou übersetzen ins Chinesische; Musixmatch und die maschinelle Übersetzung folgen der Übersetzungssprache, die du aus 17 wählst. Schwebender Text, Liedtextfenster, Notch, Menüleiste und Touch Bar entscheiden jeweils selbst, ob sie sie zeigen. Standardmäßig eingeblendet, wenn die Sprachen deines Mac Chinesisch enthalten.

- Einstellungen: Liedtext › Sprache › Übersetzungssprache
- Einstellungen: Liedtext-Anzeige › Schwebender Text › Inhalt › Übersetzung
- Einstellungen: Tastaturkurzbefehle › Übersetzung ein-/ausblenden

<a id="feature-machine-translation"></a>

### Übersetzen, wenn keine Übersetzung vorliegt

Hat keine Quelle eine Übersetzung, wird der Liedtext maschinell übersetzt. Unter macOS 15 oder neuer mit geladener Sprache übersetzt Apple Translation direkt auf deinem Mac, und der Liedtext bleibt dort; andernfalls werden die zu übersetzenden Zeilen an Google Übersetzer und dann an MyMemory gesendet. Übersetzungssprachen werden auf derselben Karte geladen.

- Standardmäßig aus
- Einstellungen: Liedtext › Sprache › Übersetzen, wenn keine vorhanden
- Einstellungen: Liedtext › Sprache › Übersetzungssprachen

<a id="feature-romanization"></a>

### Umschrift

Japanisches Romaji, koreanische Umschrift, Mandarin-Pinyin und kantonesisches Jyutping, Wort für Wort über dem Liedtext, dazu 18 weitere Sprachen wie Russisch, Thai, Griechisch und Hindi nach dem offiziellen System der jeweiligen Sprache oder einer ISO-Norm. Die Sprache wird Zeile für Zeile erkannt, sodass in einem chinesischen Titel nur die japanische Zeile markiert wird. Hier wählst du, welche Sprachen markiert werden; bei chinesischer Oberfläche ist Pinyin anfangs aus. Jede Anzeige entscheidet selbst, ob sie die Umschrift zeigt.

- Standardmäßig ein
- Einstellungen: Liedtext › Sprache › Sprachen für Umschrift
- Einstellungen: Liedtext › Sprache › Japanische Umschrift
- Einstellungen: Liedtext-Anzeige › Schwebender Text › Inhalt › Umschrift
- Einstellungen: Tastaturkurzbefehle › Umschrift ein-/ausblenden

<a id="feature-chinese-script"></a>

### Vereinfachtes oder traditionelles Chinesisch

Zeigt alle chinesischen Liedtexte in vereinfachten oder traditionellen Zeichen, unabhängig von der Sprache der App.

- Einstellungen: Liedtext › Sprache › Chinesische Schrift

<a id="feature-split-join-lines"></a>

### Lange Zeilen teilen, kurze zusammenfassen

Schwebender Text, Notch, Menüleiste und Touch Bar teilen Zeilen, die für ihre Breite zu lang sind, und fassen Zeilen zusammen, die zu schnell vorbeihuschen, jeweils nach der eigenen Breite. Das Liedtextfenster zeigt jede Zeile unverändert. Zwei getrennte Schalter.

- Standardmäßig aus
- Einstellungen: Liedtext › Timing und Umbrüche › Lange Zeilen teilen
- Einstellungen: Liedtext › Timing und Umbrüche › Kurze Zeilen zusammenfassen

<a id="feature-timing-offset"></a>

### Timing-Versatz

Verschiebe alle Liedtexte nach vorn oder hinten, auf Wunsch nur für einen Player. Einzelne Titel erhalten in der Liedtext-Verwaltung ihren eigenen Versatz, und Tastaturkurzbefehle können ihn jederzeit vorziehen, verzögern oder zurücksetzen.

- Einstellungen: Liedtext › Timing und Umbrüche › Timing-Versatz
- Einstellungen: Tastaturkurzbefehle › Text früher
- Einstellungen: Tastaturkurzbefehle › Text später
- Einstellungen: Tastaturkurzbefehle › Liedtext-Versatz zurücksetzen

<a id="section-display"></a>

## Wo Liedtexte erscheinen und wie sie aussehen

<a id="feature-floating-lyrics"></a>

### Schwebender Text

Liedtext, der über allen Fenstern schwebt, immer im Vordergrund, Wort für Wort aufleuchtend. Lass ihn dort, wohin du ihn ziehst, oder hefte ihn oben mittig auf dem Bildschirm oder direkt über dem Dock an. Bei mehreren Displays bleibt er auf einem Bildschirm oder folgt dem Bildschirm des Fensters, das du gerade nutzt. Umschrift, Übersetzung und die nächste Zeile können dazu erscheinen.

- Standardmäßig ein
- Einstellungen: Liedtext-Anzeige › Schwebender Text › Schwebender Text
- Einstellungen: Liedtext-Anzeige › Schwebender Text › Position
- Einstellungen: Liedtext-Anzeige › Schwebender Text › Inhalt › Nächste Zeile
- Einstellungen: Tastaturkurzbefehle › Schwebenden Text ein-/ausblenden
- Einstellungen: Liedtext-Anzeige › Schwebender Text › Position › Anzeigen auf

<a id="feature-notch-lyrics"></a>

### Liedtext an der Notch

Eine Kapsel im Stil der Dynamic Island neben der Notch oben auf dem Bildschirm; Macs ohne Notch und externe Displays bekommen ebenfalls eine. Jede Seite kann Titel, Künstler, Album, Cover, Wiedergabesteuerung oder verstrichene bzw. verbleibende Zeit zeigen, neben einer bewegten Audiowelle. Zeige darauf, um sie auszuklappen: mit Steuerung, verschiebbarem Fortschrittsbalken, Liedtext-Timing und Schnelltasten wie Favorit und Liedtext suchen. Während Werbung zählt sie die verbleibende Zeit herunter.

- Standardmäßig aus
- Einstellungen: Liedtext-Anzeige › Notch › Notch-Text
- Einstellungen: Liedtext-Anzeige › Notch › Stil
- Einstellungen: Liedtext-Anzeige › Notch › Display
- Einstellungen: Liedtext-Anzeige › Notch › Linkes Ohr
- Einstellungen: Tastaturkurzbefehle › Notch-Text ein-/ausblenden
- Einstellungen: Tastaturkurzbefehle › Notch-Liedtext kurz einblenden
- Einstellungen: Liedtext-Anzeige › Notch › Ausgeklappt › Schnellaktionen

<a id="feature-menu-bar-lyrics"></a>

### Liedtext in der Menüleiste

Die aktuelle Zeile direkt in der Menüleiste; ist sie zu lang, läuft sie durch, statt abgeschnitten zu werden. Füge eine zweite Zeile für die nächste Zeile, die Übersetzung oder die Umschrift hinzu. Sie kann auch mittig in der Menüleiste sitzen, auf Displays mit Notch direkt daneben, oder nur den Titel zeigen, mit oder ohne Künstler.

- Standardmäßig aus
- Einstellungen: Liedtext-Anzeige › Menüleiste › Menüleisten-Text
- Einstellungen: Liedtext-Anzeige › Menüleiste › Layout › Liedtext-Position
- Einstellungen: Liedtext-Anzeige › Menüleiste › Inhalt › Was angezeigt wird
- Einstellungen: Liedtext-Anzeige › Menüleiste › Inhalt › Zweitzeile
- Einstellungen: Tastaturkurzbefehle › Menüleisten-Text ein-/ausblenden

<a id="feature-touch-bar-lyrics"></a>

### Liedtext auf der Touch Bar

Auf einem MacBook Pro mit Touch Bar läuft die aktuelle Zeile mit, während sie gesungen wird, auf Wunsch mit Cover und Wiedergabesteuerung. Der Liedtext kann weiß sein, der Coverfarbe folgen, eine eigene Farbe nutzen oder als Regenbogen fließen, mit einstellbarer Helligkeit für den noch nicht gesungenen Teil. Er kann sich bei Wiedergabebeginn ausklappen und bei Pause einklappen, und die Taste „Mehr“ öffnet Timing, Favorit, Zufallswiedergabe und Wiederholen, Lautstärke und einen Fortschrittsregler.

- Standardmäßig aus
- Einstellungen: Liedtext-Anzeige › Touch Bar › Touch Bar-Liedtext
- Einstellungen: Tastaturkurzbefehle › Touch Bar-Liedtext ein-/ausklappen
- Einstellungen: Liedtext-Anzeige › Touch Bar › Farbe › Textfarbe
- Einstellungen: Liedtext-Anzeige › Touch Bar › Verhalten › Bei Wiedergabe ausklappen
- Einstellungen: Liedtext-Anzeige › Touch Bar › Layout › Taste „Mehr“ anzeigen

<a id="feature-lyrics-window"></a>

### Liedtextfenster

Ganzseitiger Liedtext nach dem Vorbild der Liedtextansicht von Apple Music: unscharfes Cover im Hintergrund, der ganze Titel scrollt zur aktuellen Zeile, Duette nach Stimme getrennt, Hintergrundgesang in eigener Zeile, gehaltene Töne, die anschwellen und leuchten. Der Hintergrund kann dem Cover folgen oder einfarbig, ein Verlauf oder Milchglas sein, und Schriftstärke, Farbe für Gesungenes und Ausrichtung lassen sich ändern. Öffne es über das Menüleistensymbol oder einen Tastaturkurzbefehl.

- Einstellungen: Liedtext-Anzeige › Liedtextfenster › Liedtextfenster
- Einstellungen: Liedtext-Anzeige › Liedtextfenster › Hintergrund › Hintergrund
- Einstellungen: Tastaturkurzbefehle › Liedtextfenster öffnen
- Einstellungen: Liedtext-Anzeige › Liedtextfenster › Layout › Ausrichtung

<a id="feature-lyrics-window-hdr"></a>

### HDR-Hervorhebung im Liedtextfenster

Auf einem HDR-Display wird der gesungene Teil der aktuellen Zeile im Liedtextfenster heller als normales Weiß dargestellt. Standardmäßig aus; verbraucht eingeschaltet mehr Energie. Nur in Vollgröße.

- Standardmäßig aus
- Einstellungen: Liedtext-Anzeige › Liedtextfenster › Farbe › HDR-Hervorhebung

<a id="feature-mini-lyrics-window"></a>

### Mini-Liedtextfenster

Das Liedtextfenster, verkleinert zu einer kleinen Karte: nur die aktuelle Zeile, aktuelle und nächste Zeile oder eine ganze scrollende Seite. Hintergrund, Textfarbe, Schrift, Stärke, Farbe für Gesungenes sowie Titel, Cover und Zeit oben werden alle separat eingestellt.

- Einstellungen: Liedtext-Anzeige › Liedtextfenster › Layout › Liedtext-Layout
- Einstellungen: Tastaturkurzbefehle › Mini/Vollgröße umschalten

<a id="feature-mini-window-auto-hide"></a>

### Mini-Fenster blendet sich bei Pause oder Vollbild aus

Das Mini-Fenster kann bei Pause oder Leerlauf verschwinden und bei Wiedergabebeginn zurückkehren, und es weicht aus, solange auf seinem Display eine App im Vollbild läuft (ein Video, ein Spiel). Für beides gibt es einen eigenen Schalter.

- Standardmäßig aus
- Einstellungen: Liedtext-Anzeige › Liedtextfenster › Verhalten › Bei Pause ausblenden
- Einstellungen: Liedtext-Anzeige › Liedtextfenster › Verhalten › Im Vollbild ausblenden

<a id="feature-animated-artwork"></a>

### Animiertes Cover

Alben mit animiertem Cover auf Apple Music, QQ Music oder NetEase Cloud Music bewegen sich auch im Liedtextfenster in Vollgröße, ebenso Alben, deren animiertes Cover Kugou Music beim Abspielen dort gespeichert hat. Im Stromsparmodus oder mit „Bewegung reduzieren“ pausiert es. Du siehst, wie viel Platz die geladenen Animationen belegen, und kannst sie löschen.

- Standardmäßig ein
- Einstellungen: Liedtext-Anzeige › Liedtextfenster › Cover › Animiertes Cover
- Einstellungen: Liedtext-Anzeige › Liedtextfenster › Cover › Cache für animierte Cover

<a id="feature-spotify-canvas"></a>

### Spotify Canvas als Hintergrund

Hat ein Titel auf Spotify ein Canvas-Video in Endlosschleife, spielt das Liedtextfenster in Vollgröße es statt des unscharfen Covers als Hintergrund ab. Verwendet werden nur Videos, die Spotify bereits auf diesem Mac gespeichert hat; Titel, die du in Spotify gehört hast, bekommen also eines, auch wenn du sie in einem anderen Player abspielst. Im Stromsparmodus oder mit „Bewegung reduzieren“ pausiert es.

- Standardmäßig aus
- Einstellungen: Liedtext-Anzeige › Liedtextfenster › Hintergrund › Spotify Canvas

<a id="feature-idle-overview"></a>

### Hörübersicht zwischen den Titeln

Läuft nichts, zeigt das Liedtextfenster den letzten Titel mit einer Zeile aus seinem Liedtext und der Taste „Fortsetzen“. Mit verbundenem Last.fm zeigt es außerdem, wie viel du heute, in den letzten 7 Tagen und insgesamt gehört hast, einen 30-Tage-Verlauf, „An diesem Tag“ und deine letzten Wiedergaben mit Cover.

<a id="feature-look"></a>

### Erscheinungsbild

Schrift (die des Systems oder deine eigene .ttf / .otf), Größe, Stärke, Text- und Hintergrundfarbe, Kontur und Milchglas. Der schwebende Text bringt Farbdesigns mit und kann eigene sichern; die Textfarbe kann dem Albumcover folgen, und schwebender Text, Notch, Menüleiste und Touch Bar können auch als Regenbogen fließen. Tastaturkurzbefehle oder Scrollen über dem Liedtext bei gedrückter ⌘-Taste (Mausrad oder Streichen mit zwei Fingern) machen den schwebenden Text auch spontan größer oder kleiner.

- Einstellungen: Liedtext-Anzeige › Schwebender Text › Design
- Einstellungen: Liedtext-Anzeige › Schwebender Text › Design › Meine Designs
- Einstellungen: Liedtext-Anzeige › Notch › Textzeile › Liedtextfarbe
- Einstellungen: Liedtext-Anzeige › Menüleiste › Farbe › Regenbogen
- Einstellungen: Liedtext-Anzeige › Schwebender Text › Schrift › Schrift
- Einstellungen: Liedtext-Anzeige › Schwebender Text › Farbe › Milchglas-Hintergrund
- Einstellungen: Tastaturkurzbefehle › Schwebenden Text vergrößern
- Einstellungen: Tastaturkurzbefehle › Schwebenden Text verkleinern

<a id="feature-karaoke"></a>

### Karaoke Wort für Wort

Jedes Wort leuchtet auf, während es gesungen wird. Schwebender Text, Notch, Menüleiste, Touch Bar und beide Größen des Liedtextfensters haben jeweils einen eigenen Schalter; aus heißt, dass die ganze Zeile auf einmal aufleuchtet.

- Standardmäßig ein
- Einstellungen: Liedtext-Anzeige › Schwebender Text › Farbe › Karaoke-Effekt
- Einstellungen: Liedtext-Anzeige › Notch › Textzeile › Karaoke-Effekt
- Einstellungen: Liedtext-Anzeige › Menüleiste › Farbe › Karaoke-Effekt
- Einstellungen: Liedtext-Anzeige › Touch Bar › Farbe › Karaoke-Effekt
- Einstellungen: Liedtext-Anzeige › Liedtextfenster › Farbe › Karaoke-Effekt

<a id="feature-line-transition"></a>

### Zeilenwechsel

Wechselt der schwebende Text zur nächsten Zeile, gleitet die alte Zeile nach oben und die neue folgt, statt an Ort und Stelle ausgetauscht zu werden.

- Standardmäßig aus
- Einstellungen: Liedtext-Anzeige › Schwebender Text › Layout › Zeilenwechsel

<a id="feature-fade-on-hover"></a>

### Abblenden, wenn der Zeiger darauf zeigt

Der schwebende Text wird durchsichtig, solange der Zeiger darauf zeigt, und verdeckt so nie, was darunter liegt. Das Mini-Liedtextfenster hat einen eigenen Schalter und kann im abgeblendeten Zustand Klicks auch an das Fenster darunter durchlassen; halte ⌥ gedrückt, um das Mini-Fenster zu bedienen.

- Standardmäßig aus
- Einstellungen: Liedtext-Anzeige › Schwebender Text › Verhalten › Beim Überfahren abblenden
- Einstellungen: Liedtext-Anzeige › Liedtextfenster › Verhalten › Beim Überfahren abblenden
- Einstellungen: Liedtext-Anzeige › Liedtextfenster › Verhalten › Verblasst durchklickbar

<a id="feature-lock-position"></a>

### Position sperren, zum Ziehen lange drücken

Sperre den schwebenden Text an seinem Platz oder verlange ein langes Drücken vor dem Ziehen, damit er sich nie versehentlich bewegt.

- Standardmäßig aus
- Einstellungen: Liedtext-Anzeige › Schwebender Text › Verhalten › Position sperren
- Einstellungen: Liedtext-Anzeige › Schwebender Text › Verhalten › Gedrückt halten zum Verschieben
- Einstellungen: Tastaturkurzbefehle › Position sperren/entsperren

<a id="feature-hover-controls"></a>

### Steuerung beim Daraufzeigen

Zeigst du auf den schwebenden Text, erscheint eine Reihe von Schnelltasten. Auch der Liedtext in der Menüleiste kann beim Daraufzeigen die Wiedergabesteuerung einblenden.

- Standardmäßig ein
- Einstellungen: Liedtext-Anzeige › Schwebender Text › Verhalten › Steuerung beim Überfahren zeigen
- Einstellungen: Liedtext-Anzeige › Menüleiste › Verhalten › Steuerung beim Überfahren zeigen

<a id="feature-hide-in-screenshots"></a>

### Unsichtbar in Bildschirmfotos und bei Bildschirmfreigabe

Bildschirmfotos, Aufnahmen und geteilte Bildschirme lassen den Liedtext weg, während du ihn weiterhin siehst. Schwebender Text und Notch haben jeweils einen Schalter.

- Standardmäßig aus
- Einstellungen: Liedtext-Anzeige › Schwebender Text › Verhalten › In Bildschirmfotos ausblenden
- Einstellungen: Liedtext-Anzeige › Notch › Verhalten › In Bildschirmfotos ausblenden

<a id="feature-hide-when-paused"></a>

### Bei Pause ausblenden oder verkleinern

Schwebender Text und Notch verschwinden bei Pause oder Leerlauf; die Notch kann stattdessen auf die Größe der Notch schrumpfen.

- Standardmäßig aus
- Einstellungen: Liedtext-Anzeige › Schwebender Text › Verhalten › Bei Pause ausblenden
- Einstellungen: Liedtext-Anzeige › Notch › Verhalten › Bei Pause ausblenden
- Einstellungen: Liedtext-Anzeige › Notch › Verhalten › Bei Pause einklappen

<a id="feature-hide-when-no-lyrics"></a>

### Bei Instrumentals und Titeln ohne Liedtext ausblenden

Ist ein Titel instrumental oder hat die Suche keinen Liedtext gefunden, können sich der schwebende Text und das Mini-Liedtextfenster ausblenden, und Notch und Touch Bar können ihre Textzeile einklappen. Solange die Suche läuft, wird nichts ausgeblendet. Jede Anzeige hat einen eigenen Schalter.

- Standardmäßig aus
- Einstellungen: Liedtext-Anzeige › Schwebender Text › Verhalten › Bei Instrumental & ohne Text ausblenden
- Einstellungen: Liedtext-Anzeige › Liedtextfenster › Verhalten › Bei Instrumental & ohne Text ausblenden
- Einstellungen: Liedtext-Anzeige › Notch › Verhalten › Bei Instrumental & ohne Text einklappen
- Einstellungen: Liedtext-Anzeige › Touch Bar › Verhalten › Bei Instrumental & ohne Text einklappen

<a id="feature-hide-during-ads"></a>

### Bei Werbung ausweichen

Spielt der Player Werbung, kann sich der schwebende Text ausblenden und die Notch auf ihren oberen Streifen schrumpfen; zeigst du auf die Notch, klappt sie trotzdem aus. Beide haben einen eigenen Schalter.

- Standardmäßig aus
- Einstellungen: Liedtext-Anzeige › Schwebender Text › Verhalten › Bei Werbung ausblenden
- Einstellungen: Liedtext-Anzeige › Notch › Verhalten › Bei Werbung einklappen

<a id="feature-hide-in-full-screen"></a>

### Notch weicht im Vollbild aus

Der Liedtext an der Notch verschwindet, solange ein Video, ein Spiel oder eine andere App im Vollbild läuft.

- Standardmäßig ein
- Einstellungen: Liedtext-Anzeige › Notch › Verhalten › Im Vollbild ausblenden

<a id="feature-notch-show-on-lock-screen"></a>

### Notch auf dem Sperrbildschirm

Die Notch zeigt den laufenden Titel und seinen Liedtext auch auf dem Sperrbildschirm.

- Standardmäßig aus
- Einstellungen: Liedtext-Anzeige › Notch › Verhalten › Auf Sperrbildschirm zeigen

<a id="feature-overlay-hide-in-full-screen"></a>

### Schwebender Text weicht im Vollbild aus

Schwebender Text bleibt normalerweise über Apps im Vollbild. Schalte dies ein, damit er sich ausblendet, solange ein Video, ein Spiel oder eine andere App im Vollbild läuft, und zurückkehrt, wenn du den Vollbildmodus verlässt.

- Standardmäßig aus
- Einstellungen: Liedtext-Anzeige › Schwebender Text › Verhalten › Im Vollbild ausblenden

<a id="feature-title-on-change"></a>

### Titel bei Wechsel einblenden

Name und Künstler jedes neuen Titels gleiten kurz aus der Notch heraus und dann wieder hinein.

- Standardmäßig ein
- Einstellungen: Liedtext-Anzeige › Notch › Verhalten › Titel bei Wechsel anzeigen

<a id="feature-listening-milestones"></a>

### Hör-Meilensteine

Erreicht ein Titel seine 100., 1.000. oder 10.000. Wiedergabe oder überschreitet deine Last.fm-Gesamtzahl einen Meilenstein, öffnet sich die Notch zum Feiern. Erfordert ein verbundenes Last.fm.

- Standardmäßig ein
- Einstellungen: Liedtext-Anzeige › Notch › Verhalten › Meilensteine

<a id="feature-notch-gestures"></a>

### Trackpad-Gesten an der Notch

Ist der Zeiger über der Notch, streiche mit zwei Fingern nach links oder rechts, um den Titel zu wechseln, oder nach oben und unten, um die Systemlautstärke zu ändern.

- Standardmäßig ein
- Einstellungen: Liedtext-Anzeige › Notch › Verhalten › Trackpad-Gesten
- Einstellungen: Liedtext-Anzeige › Notch › Verhalten › Bei Lautstärketasten anzeigen

<a id="feature-notch-lyric-row-fade"></a>

### Textzeile der Notch beim Daraufzeigen abblenden

Zeigt der Zeiger auf die Textzeile der Notch, blendet die Zeile ab, statt auszuklappen, und Klicks gehen an das Fenster darunter; ausgeklappt wird die Notch nur über der Notch selbst oder an ihren Seiten.

- Standardmäßig aus
- Einstellungen: Liedtext-Anzeige › Notch › Textzeile › Beim Überfahren abblenden

<a id="feature-notch-multiline-lyrics"></a>

### Mehrzeiliger Liedtext in der ausgeklappten Notch

Klappt die Notch unter dem Zeiger aus, wird der Textbereich zu einer Liste mit 3, 5 oder 7 Zeilen; die aktuelle Zeile leuchtet Wort für Wort auf, und die Liste scrollt bei jeder neuen Zeile nach oben. Klicke auf eine Zeile, um dorthin zu springen. Ist die Textzeile ausgeschaltet, bleibt die Notch ein schmaler Statusstreifen und zeigt Liedtext nur ausgeklappt.

- Standardmäßig ein
- Einstellungen: Liedtext-Anzeige › Notch › Ausgeklappt › Mehrzeiliger Liedtext
- Einstellungen: Liedtext-Anzeige › Notch › Ausgeklappt › Zeilen

<a id="feature-web-lyrics"></a>

### Web-Liedtext: Smartphone oder Tablet als zweiter Bildschirm oder OBS-Browserquelle

Liedtext im Webbrowser. „Web-Liedtext“ zeigt genau, was das Liedtextfenster zeigt; „OBS-Ausgabe“ hat einen transparenten Hintergrund und dieselben Schriften und Farben wie der schwebende Text, dazu oben links eine Titelkarte (Titel, Künstler und Cover), die immer, bei Titelwechsel oder nie erscheint. Jede hat einen eigenen Port und eine eigene Einstellung fürs lokale Netzwerk. Beide sind nur auf diesem Mac verfügbar, bis du „Zugriff im lokalen Netzwerk erlauben“ einschaltest; dann können Geräte im selben Netzwerk einen QR-Code scannen und sich über einen Link mit Zugriffsschlüssel verbinden. Mit „Fernsteuerung erlauben“ kann die Seite auch die Wiedergabe steuern und zu einer Zeile springen.

- Standardmäßig aus
- Einstellungen: Liedtext-Anzeige › Liedtextfenster › Web-Liedtext
- Einstellungen: Liedtext-Anzeige › Liedtextfenster › Web-Liedtext › Zugriff im lokalen Netzwerk erlauben
- Einstellungen: Liedtext-Anzeige › Schwebender Text › OBS › OBS-Ausgabe
- Einstellungen: Liedtext-Anzeige › Schwebender Text › OBS › Titelkarte
- Einstellungen: Liedtext-Anzeige › Liedtextfenster › Web-Liedtext › Fernsteuerung erlauben

<a id="section-players"></a>

## Player und Wiedergabe

<a id="feature-players"></a>

### 14 Player, mehrere wählbar oder automatisch erkannt

Apple Music, Spotify, QQ Music, NetEase Cloud Music, Kugou, Soda Music, LX Music, KKBOX, Amazon Music, reAMP im Winamp-Stil, der verlustfreie Hi-Res-Player VOX für lokale Dateien, der kostenlose lokale Player Pine Player, der fast jedes Format abspielt, der klassische lokale Player foobar2000, von Windows portiert, und die YouTube Music-App Kaset. Wähle mehrere gleichzeitig oder lass die automatische Erkennung an, um dem zu folgen, was macOS unter „Jetzt läuft“ zeigt. Auch Radio in Apple Music funktioniert und zeigt Sendername und Logo, während moderiert wird.

- Einstellungen: Player › Musik-Apps

<a id="feature-web-players"></a>

### YouTube Music und Spotify Web im Browser

Kopple deinen Browser einmal, und Musik, die darin läuft, bekommt ebenfalls Liedtext, der dem Fortschritt der Seite folgt. Eine Prüfung mit einem Klick zeigt dir vorher, ob sich dieser Browser steuern lässt. Während Werbung zeigt die Notch die verbleibende Zeit und welche Werbung gerade läuft.

- Standardmäßig aus
- Einstellungen: Player › Web

<a id="feature-skip-youtube-ads"></a>

### YouTube Music-Werbung automatisch überspringen

Bei YouTube Music im Browser wird Werbung übersprungen, sobald die Taste „Überspringen“ erscheint. Ist die Funktion aus, kannst du sie weiterhin selbst über die Notch überspringen. Erfordert die Berechtigung „Bedienungshilfen“.

- Standardmäßig aus
- Einstellungen: Player › Web › Werbung in YouTube Music überspringen
- Einstellungen: Player › Berechtigungen & Dienste › Bedienungshilfen

<a id="feature-other-players"></a>

### Weitere Player hinzufügen

Player, die nicht in der Liste stehen, lassen sich aus dem Ordner „Programme“ zu deinen vertrauenswürdigen Playern hinzufügen, und Lyrimuse fragt nach, wenn es einen unbekannten Player bemerkt, der Musik abspielt.

- Einstellungen: Player › Andere Apps
- Einstellungen: Player › App hinzufügen …
- Einstellungen: Player › Hinweis auf neue Player

<a id="feature-permissions"></a>

### Berechtigungen nur, wo nötig

Apple Music, Spotify, Kaset und VOX brauchen die Berechtigung „Automation“, um zu lesen, was läuft. QQ Music, NetEase Cloud Music und Kugou brauchen Festplattenvollzugriff für ihre gespeicherten Liedtexte und Warteschlangen, Soda Music und VOX für ihre Warteschlangen. Die Fortschrittskalibrierung für Amazon Music und Pine Player, die Playlist von Pine Player, die Tasten für Zufallswiedergabe, Wiederholen und Favorit von QQ Music, NetEase Cloud Music, Kugou Music, Soda Music, Amazon Music, reAMP, Pine Player und foobar2000, die Lautstärke von foobar2000 sowie die Wiedergabetasten von QQ Music, NetEase Cloud Music, Soda Music, Pine Player und foobar2000, während eine andere App „Jetzt läuft“ belegt, brauchen „Bedienungshilfen“. Web-Player brauchen „Automation“ für den Browser und dessen Option „JavaScript von Apple Events erlauben“. Die übrigen Player brauchen nichts. Die Einstellungen zeigen jeweils den aktuellen Stand.

- Einstellungen: Player › Berechtigungen & Dienste › Automation-Berechtigung
- Einstellungen: Player › Berechtigungen & Dienste › Festplattenvollzugriff
- Einstellungen: Player › Berechtigungen & Dienste › Bedienungshilfen

<a id="feature-controls"></a>

### Wiedergabesteuerung und Spulen

Wiedergabe, Pause, Titel überspringen und den Fortschrittsbalken ziehen – im Liedtextfenster oder in der ausgeklappten Notch. Zufallswiedergabe, Wiederholen, Favorit und Lautstärke hängen vom Player ab: Apple Music, Spotify, Kaset, QQ Music, Amazon Music, reAMP, VOX, Pine Player, foobar2000 und YouTube Music im Browser unterstützen jeweils einige oder alle davon, und NetEase Cloud Music, Kugou Music, Soda Music und LX Music haben Favorit, LX Music zusätzlich Lautstärke, sobald „Open API“ in seinen Einstellungen aktiviert ist. Wiedergabe, Pause, Überspringen und Favorit können globale Tastaturkurzbefehle bekommen. Belegt etwa ein Browservideo „Jetzt läuft“, laufen Wiedergabe, Pause und Überspringen für QQ Music, NetEase Cloud Music, Soda Music, Pine Player und foobar2000 über deren eigene Menüs oder Wiedergabeleiste, und Spulen ist nicht möglich.

- Einstellungen: Liedtext-Anzeige › Notch › Ausgeklappt › Steuerung
- Einstellungen: Tastaturkurzbefehle › Wiedergabe/Pause
- Einstellungen: Tastaturkurzbefehle › Nächster Titel
- Einstellungen: Tastaturkurzbefehle › Vorheriger Titel
- Einstellungen: Tastaturkurzbefehle › Favorisieren/Favorit entfernen
- Einstellungen: Player › Berechtigungen & Dienste › LX Music Open API

<a id="feature-song-pages"></a>

### Titelseite mit einem Klick öffnen

Ein Klick im Menü ⋯ öffnet den Titel, sein Album oder seinen Künstler auf der Plattform, auf der du gerade hörst. Apple Music und KKBOX öffnen in ihren eigenen Apps, und Spotify springt in seiner App zum Titel; der Rest öffnet im Web: Alben und Künstler bei Spotify, QQ Music, Soda Music, Amazon Music und YouTube Music. NetEase Cloud Music und Kugou haben nur die Titelseite.

<a id="feature-about-panels"></a>

### Infos zu Titel, Album und Künstler

Klicke im Liedtextfenster oder in der ausgeklappten Notch auf Titel, Künstler oder Album, um mehr darüber zu lesen. Infos zu Album und Künstler kommen zuerst von Apple Music; sonst von Soda Music, Kugou Music und NetEase Cloud Music (nur bei chinesischer Oberfläche), dann von Wikipedia über YouTube Music, dann von Last.fm. Infos zu Titeln kommen von QQ Music (nur bei chinesischer Oberfläche) oder Last.fm. Für Last.fm muss dein Konto verbunden sein.

<a id="feature-player-linkage"></a>

### Zusammen mit dem Player starten und beenden

Pro Player: den Player öffnen, wenn Lyrimuse startet, Lyrimuse öffnen, wenn der Player startet, oder Lyrimuse beenden, sobald alle Player, denen es folgt, beendet sind.

- Standardmäßig aus
- Einstellungen: Player › Starten & Beenden › Player beim Start öffnen
- Einstellungen: Player › Starten & Beenden › Mit Player starten
- Einstellungen: Player › Starten & Beenden › Mit Player beenden

<a id="section-listening"></a>

## Scrobbeln, Last.fm und Teilen

<a id="feature-lastfm"></a>

### Scrobbeln zu Last.fm und Hörprofil

Verbinde Last.fm mit einem Klick, ohne Token zu kopieren. Sieh deine Wiedergaben von heute, dieser Woche und insgesamt, Charts für Künstler, Alben und Titel mit Auf- und Abstiegen sowie „Hörspuren“: eine Jahres-Heatmap, in der ein Klick auf einen Tag dessen meistgespielte Titel zeigt, deine Hörzeiten, die Herkunft deiner Künstler und „An diesem Tag“. Jeden kürzlich gehörten Titel kannst du mit einem Klick auf Last.fm lieben.

- Standardmäßig aus
- Einstellungen: Last.fm › Regeln › Scrobble-Regeln

<a id="feature-scrobble-rules"></a>

### Eigene Scrobble-Regeln

Zähle eine Wiedergabe bei 50 %, 75 %, 90 % oder erst am Ende; entscheide über Titel unter 30 Sekunden; standardmäßig werden Gastkünstler, chinesische Schriftvarianten und Zusätze wie „- Single“ dem Katalogeintrag von Last.fm zugeordnet, oder du sendest alles unverändert; nimm beliebige Player ganz von Last.fm aus.

- Einstellungen: Last.fm › Regeln › Scrobbeln bei
- Einstellungen: Last.fm › Regeln › Titel unter 30 Sekunden scrobbeln
- Einstellungen: Last.fm › Regeln › Abgleichmodus
- Einstellungen: Last.fm › Regeln › Player zum Scrobbeln

<a id="feature-local-log"></a>

### Jede Wiedergabe wird zuerst lokal erfasst

Wiedergaben, während Last.fm nicht verbunden ist, werden auf deinem Mac gespeichert; klicke nach dem Verbinden auf der Last.fm-Seite unter „Ausstehende Scrobbles“ auf „Nachreichen“. Eine Wiedergabe, die Last.fm bei bestehender Verbindung womöglich nicht erreicht hat, wird mit Last.fm abgeglichen und automatisch erneut gesendet. Last.fm nimmt nur Wiedergaben aus etwa den letzten zwei Wochen an.

<a id="feature-listenbrainz"></a>

### Auch zu ListenBrainz scrobbeln

Jede Wiedergabe geht aus derselben Erfassung an Last.fm und ListenBrainz, sodass beide übereinstimmen. Wiedergaben, die dein iPhone an Last.fm sendet, lassen sich ebenfalls in ListenBrainz übernehmen. Unter „Labor“ in der Seitenleiste.

- Standardmäßig aus
- Einstellungen: Labor › ListenBrainz › Account-Infos

<a id="feature-discord"></a>

### Auf Discord zeigen, was du hörst

Dein Profil und deine Freundesliste zeigen Player, Titel, Künstler, Cover und einen Fortschrittsbalken; ein Klick auf Titel oder Künstler öffnet die Webseite des Players. Die Albumzeile kann die gerade gesungene Zeile zeigen, und bis zu zwei Tasten lassen sich hinzufügen. Wähle, wie der Text angeordnet ist, welche Player zählen, ob die Anzeige bei Pause bleibt und welches Abzeichen auf dem Cover sitzt, zeige nur den Player, ohne den Titel zu nennen, oder blende die Anzeige eine Weile aus.

- Standardmäßig aus
- Einstellungen: Discord › Auf Discord anzeigen
- Einstellungen: Discord › Angezeigte Player
- Einstellungen: Discord › Bei Pause
- Einstellungen: Discord › Vorübergehend ausblenden
- Einstellungen: Discord › Was angezeigt wird
- Einstellungen: Discord › Buttons
- Einstellungen: Discord › Titeldetails ausblenden

<a id="feature-now-playing-page"></a>

### Eine teilbare Webseite mit dem, was du hörst

Eine öffentliche Seite mit dem, was du gerade hörst, und deinem Verlauf, auf Wunsch mit Gästebuch, Reaktionen, Besucherzähler, Top 10 der Künstler und Vinyl-Optik. ListenBrainz allein liefert Live-Wiedergabe und Verlauf; für den Rest richtest du nach der Anleitung einen Cloudflare Worker ein. Unter „Labor“.

- Standardmäßig aus
- Einstellungen: Labor › Web-Push › Verbindungsinfo

<a id="feature-digests"></a>

### Tägliche, wöchentliche, monatliche und jährliche Hörrückblicke

Gesendet an die Kanäle, die du einrichtest, so viele du willst: Bark, ntfy, ServerChan, Feishu, DingTalk, WeCom, Telegram, Discord, Slack oder ein allgemeiner Webhook. Jeder Kanal zeigt eine Vorschau der Mitteilung und kann einen Test senden, und der Sendeverlauf zeigt, ob jede Mitteilung angekommen ist, mit erneutem Senden für die nicht angekommenen. Die Berichte vergleichen mit dem vorherigen Zeitraum, nennen die Künstler, die du zum ersten Mal gehört hast, und schätzen, wie lange du gehört hast, für jede Plattform mit Albumcover und Link zur vollständigen Rangliste aufbereitet. Jeder der vier hat einen eigenen Schalter und bei mehreren Kanälen eine eigene Kanalauswahl; du wählst, wann sie gesendet werden (in der aktuellen Zeitzone des Mac) und wie viele Top-Einträge jede Liste zeigt, und jeder Kanal kann den Bericht „Vollständig“, „Kurz“ oder „Übersicht“ nutzen oder deinen eigenen Titel und Text mit Platzhaltern.

- Standardmäßig aus
- Einstellungen: Push-Mitteilungen › Kanäle
- Einstellungen: Push-Mitteilungen › Sendezeit
- Einstellungen: Push-Mitteilungen › Hörberichte
- Einstellungen: Push-Mitteilungen › Datenquelle
- Einstellungen: Push-Mitteilungen › Einträge je Liste
- Einstellungen: Push-Mitteilungen › Täglicher Hörbericht
- Einstellungen: Push-Mitteilungen › Wöchentlicher Hörrückblick
- Einstellungen: Push-Mitteilungen › Monatlicher Hörrückblick
- Einstellungen: Push-Mitteilungen › Jährlicher Hörrückblick
- Einstellungen: Push-Mitteilungen › Sendeverlauf

<a id="section-general"></a>

## Alltag

<a id="feature-onboarding"></a>

### Einrichtung beim ersten Start

Beim ersten Öffnen führt dich Lyrimuse durch die Wahl der Player, das Koppeln eines Browsers und die Wahl, wo Liedtexte erscheinen, und prüft jede nötige Berechtigung, damit du Fehlendes sofort beheben kannst.

<a id="feature-language"></a>

### Englisch, vereinfachtes und traditionelles Chinesisch, Japanisch, Koreanisch, Spanisch, Französisch, Deutsch, Italienisch und brasilianisches Portugiesisch

Folgt standardmäßig deinem System und nutzt Englisch, wenn deine Systemsprache keine davon ist; ein Wechsel wirkt sofort, ohne Neustart.

- Einstellungen: Allgemein › Erscheinungsbild & Sprache › Sprache

<a id="feature-appearance"></a>

### Hell, dunkel oder automatisch

Einstellungen, Liedtextfenster, Liedtext-Verwaltung und das Menüleisten-Panel können hell oder dunkel bleiben; standardmäßig folgen sie deinem System. Schwebender Text folgt weiterhin dem System, und die Notch ist immer dunkel.

- Einstellungen: Allgemein › Erscheinungsbild & Sprache › Erscheinungsbild

<a id="feature-shortcuts"></a>

### Globale Tastaturkurzbefehle

Ein- und Ausblenden jeder Liedtextanzeige (oder aller zugleich, für Meetings und Bildschirmfreigabe), Öffnen von Liedtextfenster und Liedtext-Verwaltung, Suchen, Timing, Wiedergabe, Favorit und Wechsel zum Player können Kurzbefehle bekommen. Standardmäßig ist keiner belegt.

- Einstellungen: Tastaturkurzbefehle › Einstellungen öffnen
- Einstellungen: Tastaturkurzbefehle › Alle Liedtexte aus-/einblenden
- Einstellungen: Tastaturkurzbefehle › Zum Player wechseln

<a id="feature-deep-links"></a>

### Deep Links (lyrimuse://)

lyrimuse://-Links öffnen jede Seite der Einstellungen, das Liedtextfenster oder die Liedtext-Verwaltung und führen jede Aktion aus, die einen Kurzbefehl haben kann, etwa Wiedergabe, Favorit oder alle Liedtexte ausblenden – aus der App „Kurzbefehle“, Raycast, Alfred und ähnlichen Tools. Aus „Kurzbefehle“ mit x-callback-url geöffnet, kann ein Link auch Titel, Künstler, Album und aktuelle Zeile zurückgeben. Die Karte „Deep Links“ auf der Seite „Tastaturkurzbefehle“ listet jeden Link zum Kopieren auf.

- Einstellungen: Tastaturkurzbefehle › Deep Links

<a id="feature-settings-search"></a>

### Durchsuchbare Einstellungen

Tippe oben in der Seitenleiste der Einstellungen, um direkt zu einer Einstellung zu springen, die dann hervorgehoben wird, auch in eingeklappten Bereichen. Suche auf Englisch oder Chinesisch.

<a id="feature-menu-bar-icon"></a>

### Menüleistensymbol

12 Symbole in 3 Größen, die sich bei Wiedergabe mit der Musik bewegen, oder das Albumcover des laufenden Titels. Alltägliche Aktionen findest du in seinem Menü.

- Standardmäßig ein
- Einstellungen: Allgemein › Menüleiste & Dock › Menüleistensymbol
- Einstellungen: Allgemein › Menüleiste & Dock › Albumcover
- Einstellungen: Allgemein › Menüleiste & Dock › Symbolgröße
- Einstellungen: Allgemein › Menüleiste & Dock › Symbol animieren

<a id="feature-dock-icon"></a>

### Im Dock zeigen

Schalte es aus, um nur das Menüleistensymbol zu behalten.

- Standardmäßig ein
- Einstellungen: Allgemein › Menüleiste & Dock › Im Dock zeigen

<a id="feature-launch-at-login"></a>

### Bei Anmeldung öffnen

Öffnet Lyrimuse, wenn du dich an deinem Mac anmeldest.

- Standardmäßig ein
- Einstellungen: Allgemein › Start & Mitteilungen › Bei Anmeldung öffnen

<a id="feature-silent-launch"></a>

### Still starten

Startet, ohne ein Fenster zu öffnen, nur mit dem Menüleistensymbol.

- Standardmäßig aus
- Einstellungen: Allgemein › Start & Mitteilungen › Still starten

<a id="feature-song-notifications"></a>

### Bei Titelwechsel mitteilen

Eine Systemmitteilung für jeden neuen Titel.

- Standardmäßig aus
- Einstellungen: Allgemein › Start & Mitteilungen › Bei Titelwechsel mitteilen

<a id="feature-backup"></a>

### Einstellungen sichern, auf einen neuen Mac umziehen

Exportiere alle Einstellungen in eine Datei, standardmäßig in iCloud Drive oder in einen Ordner deiner Wahl; öffnet ein neuer Mac Lyrimuse zum ersten Mal und findet die Datei in iCloud, bietet Lyrimuse an, sie zu importieren.

- Einstellungen: Allgemein › Backup & Migration › iCloud-Backup
- Einstellungen: Allgemein › Backup & Migration › Einstellungsdatei

<a id="feature-updates"></a>

### Automatische Updates und Betas

Sucht selbst nach neuen Versionen; lies die Hinweise und installiere über die Seite „Softwareupdate“. Aktiviere „Beta-Updates“, um Neues früh auszuprobieren.

- Standardmäßig aus
- Einstellungen: Softwareupdate › Update-Einstellungen › Automatisch prüfen
- Einstellungen: Softwareupdate › Update-Einstellungen › Automatisch laden und installieren
- Einstellungen: Softwareupdate › Update-Einstellungen › Beta-Updates

<a id="feature-diagnostics"></a>

### Diagnose und Fehlerberichte mit einem Klick

Bündelt Protokolle, Absturzberichte und App-Status in einer Datei, ohne Zugangsdaten und deinen Benutzernamen. „Problem melden“ öffnet ein GitHub-Issue, in dem Version, macOS und Player bereits ausgefüllt sind.

- Einstellungen: Über › Diagnose & Daten › Diagnose exportieren
- Einstellungen: Über › Updates & Hilfe › Problem melden

<a id="feature-telemetry"></a>

### Anonyme Nutzungsdaten, abschaltbar

Sendet höchstens einmal täglich Version, macOS, aktivierte Funktionen und Absturzzusammenfassungen an den eigenen Server des Entwicklers, um zu entscheiden, was zuerst behoben wird. Nie Titelnamen, Künstler, lokale Pfade oder Konten. Standardmäßig an; schalte es in den Einstellungen oder auf dem Willkommensbildschirm aus.

- Einstellungen: Über › Diagnose & Daten › Anonyme Nutzungsdaten senden

<a id="section-all-settings"></a>

## Alle Einstellungen

Alle Einstellungen des Einstellungsfensters nach Ort: insgesamt 309. Gib einen Namen in das Suchfeld oben in der Seitenleiste der Einstellungen ein, um direkt dorthin zu springen.

### Liedtext › Quelle

- **Liedtextquellen**
- **Zuordnungsalgorithmus**
- **Liedtext aus der Datei bevorzugen**: Bei lokalen Dateien zuerst die gleichnamige .lrc-Datei oder eingebetteten Liedtext nutzen
- **Nach Algorithmus-Update neu wählen**: Im Hintergrund neu bewertet; kann zu einer besseren Version wechseln
- **Liedtext für gleiche Titel teilen**: Eine Kopie pro Aufnahme über Player und Albumversionen hinweg; Änderungen gelten überall
- **Manuell gewählte Texte sperren**: Manuell gewählte Liedtexte werden nie durch die automatische Zuordnung ersetzt
- **Nächste Titel vorbereiten**: Lädt Liedtexte für kommende Titel vorab

### Liedtext › Sprache

- **Übersetzungssprache**
- **Übersetzen, wenn keine vorhanden**: Übersetzt zuerst auf diesem Mac und online, wenn das nicht möglich ist
- **Übersetzungssprachen**: Systemsprachen für die Übersetzung auf dem Gerät
- **Chinesische Schrift**
- **Sprachen für Umschrift**
- **Japanische Umschrift**: Romaji oder Hiragana nur für Kanji

### Liedtext › Timing und Umbrüche

- **Lange Zeilen teilen**: Zu lange Zeilen werden geteilt und nacheinander angezeigt
- **Kurze Zeilen zusammenfassen**: Benachbarte kurze Zeilen werden zusammengefasst, wenn sie in eine Zeile passen
- **Timing-Versatz**: Positive Werte zeigen den Liedtext früher, negative später

### Liedtext › Liedtext-Bibliothek

- **Liedtext-Bibliothek**
- **Fehlende Liedtexte zuordnen**: Nur Titel ohne Liedtext oder mit reinem Text
- **Ganze Bibliothek neu zuordnen**: Inklusive Titel mit Liedtext, außer bearbeiteten, kalibrierten und instrumentalen
- **Scanintervall**: Sekunden zwischen Titeln; mindestens 2 Sekunden werden empfohlen, um Drosselung zu vermeiden
- **Liedtext-Ordner**: Vorhandene Dateien bleiben, wo sie sind, wenn du den Ort änderst
- **Wort-für-Wort-Format**
- **Liedtext-Ordner importieren**: Ordnet die Liedtextdateien eines Ordners den Titeln deiner Bibliothek zu, mit Vorschau vor dem Import
- **Ordner-Import**
- **Überwachter Ordner**: Neue oder geänderte Liedtextdateien im Ordner werden automatisch importiert: Titel ohne Liedtext erhalten ihn sofort, Titel mit Liedtext bleiben unverändert
- **Import-Bibliothek**: Importierte Liedtexte ansehen und löschen

### Player

- **Musik-Apps**
- **Web**: Liedtext funktioniert auch bei Musik im Browser. Klicke auf „+“, um deinen Browser zu koppeln; die Position wird direkt von der Seite gelesen, sodass der Text nach einem Titelwechsel sofort synchron ist
- **Andere Apps**: Nicht aufgeführte Apps können auch als Player dienen: Nach dem Hinzufügen zeigen ihre Titel Liedtext und zählen zu deinem Hörverlauf
- **App hinzufügen …**: Wähle eine App im Ordner „Programme“, ohne zu warten, bis sie etwas abspielt
- **Hinweis auf neue Player**

### Player › Web

- **Werbung in YouTube Music überspringen**: Überspringbare Werbung wird sofort übersprungen

### Player › Berechtigungen & Dienste

- **Automation-Berechtigung**
- **Festplattenvollzugriff**
- **Bedienungshilfen**
- **LX Music Open API**: Lyrimuse liest über diese API die Wiedergabeposition von LX Music und regelt seine Lautstärke
- **Liedtext-Engine**: Liest den Wiedergabestatus und lädt Liedtext und Cover

### Player › Starten & Beenden

- **Starten & Beenden**: Nur ausgewählte Player werden aufgeführt. Mit „Automatisch erkennen“ auch die auf diesem Mac installierten
- **Player beim Start öffnen**
- **Mit Player starten**
- **Mit Player beenden**

### Liedtext-Anzeige › Schwebender Text

- **Schwebender Text**
- **OBS**
- **Design**
- **Breite**
- **Position**
- **Standard**: Setzt nur Design, Schrift und Farben zurück

### Liedtext-Anzeige › Schwebender Text › OBS

- **OBS-Ausgabe**: Lege den Liedtext als Browserquelle über deinen Stream. Setze Breite und Höhe auf deine OBS-Leinwandgröße
- **URL der Browserquelle**
- **Titelkarte**: Zeigt Titel, Künstler und Cover oben links
- **Zugriff im lokalen Netzwerk erlauben**: Geräte im selben Netzwerk können sich über einen Link mit Zugriffsschlüssel verbinden
- **Zugriffslink**
- **Ersatzlink (IP-Adresse)**
- **Zugriffsschlüssel zurücksetzen**: Bereits geteilte Links funktionieren dann nicht mehr
- **Port**: Aktualisiere danach die URL in OBS

### Liedtext-Anzeige › Schwebender Text › Design

- **Meine Designs**

### Liedtext-Anzeige › Schwebender Text › Schrift

- **Schrift**
- **Stärke**
- **Größe**
- **Größe Umschrift**
- **Größe Übersetzung**
- **Größe nächste Zeile**

### Liedtext-Anzeige › Schwebender Text › Farbe

- **Karaoke-Effekt**
- **Textfarbe**
- **Textkontur**
- **Konturfarbe**
- **Farbe ungesungen**
- **Hintergrundfarbe**
- **Milchglas-Hintergrund**
- **Glasdichte**

### Liedtext-Anzeige › Schwebender Text › Inhalt

- **Umschrift**
- **Übersetzung**
- **Nächste Zeile**

### Liedtext-Anzeige › Schwebender Text › Layout

- **Ausrichtung**
- **Überlauf**
- **Zeilenwechsel**: Beim Zeilenwechsel rückt die nächste Zeile nach oben. Ist dies aus, wechseln die Zeilen sofort
- **Abstand Umschrift**
- **Abstand Übersetzung**
- **Abstand nächste Zeile**

### Liedtext-Anzeige › Schwebender Text › Verhalten

- **Position sperren**
- **Gedrückt halten zum Verschieben**
- **Beim Überfahren abblenden**
- **Steuerung beim Überfahren zeigen**
- **In Bildschirmfotos ausblenden**
- **Bei Pause ausblenden**
- **Bei Instrumental & ohne Text ausblenden**
- **Bei Werbung ausblenden**
- **Im Vollbild ausblenden**

### Liedtext-Anzeige › Schwebender Text › Position

- **Anzeigen auf**

### Liedtext-Anzeige › Notch

- **Notch-Text**
- **Stil**
- **Display**
- **Linkes Ohr**
- **Rechtes Ohr**
- **Breite**
- **Breite ausgeklappt**
- **Standard**: Breite und der Schalter „Notch-Text“ bleiben unverändert

### Liedtext-Anzeige › Notch › Stil

- **Hintergrund ausgeklappt**
- **Ecken**
- **Ecken ausgeklappt**
- **Fortschrittslinie**: Zeigt den Wiedergabefortschritt, wenn nicht ausgeklappt

### Liedtext-Anzeige › Notch › Linkes Ohr

- **Audiowelle**: Nur auf einer Seite gleichzeitig

### Liedtext-Anzeige › Notch › Textzeile

- **Liedtext eingeklappt zeigen**: Wenn aus, bleibt nur ein Streifen in Notch-Höhe, bis du zum Ausklappen darauf zeigst
- **Ausrichtung**
- **Liedtextfarbe**
- **Zweitzeile**
- **Ausgeklappt nächste Zeile zeigen**
- **Höhe**
- **Karaoke-Effekt**
- **Cover anzeigen**
- **Coverposition**
- **Beim Überfahren abblenden**

### Liedtext-Anzeige › Notch › Schrift

- **Schrift**
- **Stärke**
- **Größe**

### Liedtext-Anzeige › Notch › Ausgeklappt

- **Mehrzeiliger Liedtext**: Zeigt ausgeklappt mehrere Liedzeilen, die aktuelle Zeile leuchtet Wort für Wort auf
- **Zeilen**
- **Steuerung**
- **Textversatz anzeigen**
- **Schnellaktionen**
- **Titelinfos**

### Liedtext-Anzeige › Notch › Verhalten

- **Bei Pause einklappen**
- **In Bildschirmfotos ausblenden**
- **Bei Pause ausblenden**
- **Bei Instrumental & ohne Text einklappen**
- **Bei Werbung einklappen**
- **Im Vollbild ausblenden**
- **Auf Sperrbildschirm zeigen**
- **Meilensteine**
- **Titel bei Wechsel anzeigen**
- **Bei Lautstärketasten anzeigen**
- **Trackpad-Gesten**

### Liedtext-Anzeige › Menüleiste

- **Menüleisten-Text**
- **Standard**: Breite und der Schalter „Menüleisten-Text“ bleiben unverändert

### Liedtext-Anzeige › Menüleiste › Inhalt

- **Was angezeigt wird**
- **Zweitzeile**
- **Symbol neben Liedtext**: Das Symbol füllt sich von unten, um den Fortschritt zu zeigen, in den Farben unter „Farbe“

### Liedtext-Anzeige › Menüleiste › Layout

- **Liedtext-Position**: Mitte: Der Text erscheint in der Mitte der Menüleiste, abseits von App-Menüs, den Symbolen rechts und der Notch
- **Anzeigen auf**
- **Breitenmodus**: Fest: Alle Titel nutzen die eingestellte Breite Adaptiv: Jeder Titel erhält eine eigene Breite nach seinem Liedtext, höchstens die eingestellte
- **Ausrichtung**

### Liedtext-Anzeige › Menüleiste › Farbe

- **Karaoke-Effekt**
- **Regenbogen**: Der Text fließt in Regenbogenfarben von links nach rechts, auf heller Menüleiste abgedunkelt; bei geöffnetem Menü gelten die Systemfarben
- **Textfarbe**
- **Farbe gesungen**

### Liedtext-Anzeige › Menüleiste › Schrift

- **Schrift**
- **Stärke**
- **Größe**

### Liedtext-Anzeige › Menüleiste › Breite

- **Maximalbreite**

### Liedtext-Anzeige › Menüleiste › Verhalten

- **Steuerung beim Überfahren zeigen**
- **Titel zeigen, wenn kein Text**: Zeigt den Titelnamen anstelle des Liedtexts, solange keiner da ist oder noch gesucht wird

### Liedtext-Anzeige › Touch Bar

- **Touch Bar-Liedtext**
- **Standard**: Der Schalter „Touch Bar-Liedtext“ bleibt unverändert

### Liedtext-Anzeige › Touch Bar › Inhalt

- **Zweitzeile**
- **Größe**

### Liedtext-Anzeige › Touch Bar › Layout

- **Ausrichtung**
- **Cover anzeigen**
- **Coverposition**
- **Steuerung**: Zurück, Wiedergabe/Pause und Weiter, plus eine Einstellungstaste
- **Position der Steuerung**
- **Taste „Mehr“ anzeigen**: Tippe darauf, um zu Wiedergabeposition, Kalibrierung, Favorit, Zufall/Wiederholen und Lautstärke zu wechseln. Was der Player nicht unterstützt, wird ausgeblendet
- **Control Strip beim Ausklappen ausblenden**: Der Liedtext füllt die ganze Touch Bar. Um Helligkeit, Lautstärke und andere Systemtasten zu erreichen, tippe zuerst links auf ✕, um den Text einzuklappen
- **Control Strip**: Füge die Tasten für Helligkeit, Lautstärke und mehr rechts in der Touch Bar in „Systemeinstellungen › Tastatur › Touch Bar-Einstellungen …“ hinzu, entferne oder ordne sie neu

### Liedtext-Anzeige › Touch Bar › Farbe

- **Karaoke-Effekt**
- **Textfarbe**: Weiß, Coverfarbe, eigene Farbe oder Regenbogen
- **Helligkeit gedimmter Text**: Helligkeit ungesungener Wörter und der zweiten Zeile

### Liedtext-Anzeige › Touch Bar › Verhalten

- **Bei Wiedergabe ausklappen**: Zeigt den Liedtext, wenn die Wiedergabe nach einer Pause weitergeht. Ein Titelwechsel während der Wiedergabe klappt ihn nicht aus, und eingeklappter Text bleibt eingeklappt
- **Bei Pause einklappen**: Klappt nach 10 Sekunden Pause zur Control Strip-Taste ein und bei Wiedergabe wieder aus
- **Bei Instrumental & ohne Text einklappen**: Klappt erst ein, wenn sicher kein Liedtext existiert, und wieder aus, sobald einer gefunden wird. Bleibt während der Suche sichtbar

### Liedtext-Anzeige › Liedtextfenster

- **Liedtextfenster**
- **Web-Liedtext**: Liedtextfenster im Webbrowser anzeigen
- **Standard**

### Liedtext-Anzeige › Liedtextfenster › Web-Liedtext

- **Lokale Adresse**
- **Zugriff im lokalen Netzwerk erlauben**: Geräte im selben Netzwerk können sich über einen Link mit Zugriffsschlüssel verbinden
- **Fernsteuerung erlauben**: Von anderen Geräten Wiedergabe steuern und im Liedtext springen
- **Zugriffslink**
- **Ersatzlink (IP-Adresse)**
- **Zugriffsschlüssel zurücksetzen**: Bereits geteilte Links funktionieren dann nicht mehr
- **Port**: Scanne danach den QR-Code erneut, um dich neu zu verbinden

### Liedtext-Anzeige › Liedtextfenster › Hintergrund

- **Hintergrund**: Hintergrund des Liedtextfensters: Cover, einfarbig, Verlauf oder Milchglas
- **Richtung**
- **Spotify Canvas** (nur Vollgröße): Nutzt das Endlosvideo des Titels auf Spotify als Hintergrund; nur für Titel, die du in Spotify abgespielt hast
- **Glasdichte**: Dichte des Milchglases (fünf Stufen)
- **Farbe unten**

### Liedtext-Anzeige › Liedtextfenster › Schrift

- **Größe** (nur Mini): Obergrenze der Textgröße in Mini
- **Schrift**: Schrift für den Text im Liedtextfenster (Haupttext, Übersetzung, Umschrift)
- **Stärke**

### Liedtext-Anzeige › Liedtextfenster › Layout

- **Überlauf** (nur Mini): Ob lange Zeilen in der Mini-Größe umbrechen oder scrollen
- **Liedtext-Layout** (nur Mini): Einzeilig: nur die aktuelle Zeile Zweizeilig: aktuelle und nächste Zeile Mehrzeilig: eine scrollende Seite mit Liedtext wie bei Vollgröße
- **Ausrichtung** (nur Vollgröße): Ausrichtung des Liedtexts in Vollgröße; „Auto“ folgt den Duettstimmen

### Liedtext-Anzeige › Liedtextfenster › Verhalten

- **Beim Überfahren abblenden** (nur Mini)
- **Verblasst durchklickbar** (nur Mini): Im verblassten Zustand gehen Klicks an das Fenster darunter. Halte ⌥ gedrückt, um es deckend zu machen und zu bedienen
- **Bei Pause ausblenden** (nur Mini)
- **Bei Instrumental & ohne Text ausblenden** (nur Mini)
- **Im Vollbild ausblenden** (nur Mini)

### Liedtext-Anzeige › Liedtextfenster › Farbe

- **Karaoke-Effekt**
- **Textfarbe**: Textfarbe des Liedtextfensters. „Auto“ wechselt je nach Helligkeit des Hintergrunds zwischen hell und dunkel
- **Eigene Farbe**
- **Farbe gesungen**
- **HDR-Hervorhebung** (nur Vollgröße): Hellt den gesungenen Teil auf HDR-Displays auf. Verbraucht mehr Energie

### Liedtext-Anzeige › Liedtextfenster › Inhalt

- **Umschrift**
- **Übersetzung**
- **Fortschrittsbalken** (nur Mini): Wenn aus, nur mit der Wiedergabesteuerung beim Darüberfahren sichtbar

### Liedtext-Anzeige › Liedtextfenster › Kopfzeile

- **Titel** (nur Mini): Titel, Künstler und Album oben in der Mini-Größe anzeigen
- **Künstler** (nur Mini)
- **Album** (nur Mini)
- **Cover** (nur Mini): Das kleine Cover neben den Titelinfos der Mini-Größe
- **Zeit** (nur Mini): Zeigt oben in der Mini-Größe die verstrichene Zeit und die Titellänge
- **Breite** (nur Mini): Anteil der Fensterbreite für den Kopfbereich der Mini-Größe
- **Höhe** (nur Mini): Anteil der Fensterhöhe für den Kopfbereich der Mini-Größe; Text und Cover skalieren mit

### Liedtext-Anzeige › Liedtextfenster › Cover

- **Animiertes Cover** (nur Vollgröße): Nur bei manchen Alben; pausiert im Stromsparmodus oder mit „Bewegung reduzieren“
- **Cache für animierte Cover** (nur Vollgröße): Speicherplatz der geladenen animierten Cover; Gelöschtes wird bei der nächsten Anzeige neu geladen

### Tastaturkurzbefehle

- **Deep Links**: Öffne sie über „Kurzbefehle“, Raycast, Alfred und ähnliche Tools. Bewege den Zeiger über einen Tastaturkurzbefehl oben, um den Link für diese Aktion zu kopieren
- **Schwebenden Text ein-/ausblenden**
- **Notch-Text ein-/ausblenden**
- **Notch-Liedtext kurz einblenden**
- **Menüleisten-Text ein-/ausblenden**
- **Touch Bar-Liedtext ein-/ausklappen**
- **Alle Liedtexte aus-/einblenden**
- **Position sperren/entsperren**
- **Übersetzung ein-/ausblenden**
- **Umschrift ein-/ausblenden**
- **Schwebenden Text vergrößern**
- **Schwebenden Text verkleinern**
- **Liedtext-Verwaltung öffnen**
- **Liedtextfenster öffnen**
- **Mini/Vollgröße umschalten**
- **Liedtext suchen**
- **Einstellungen öffnen**
- **Zum Player wechseln**
- **Text früher**
- **Text später**
- **Liedtext-Versatz zurücksetzen**
- **Schrittweite**: Schritt pro Tastendruck
- **Wiedergabe/Pause**
- **Nächster Titel**
- **Vorheriger Titel**
- **Favorisieren/Favorit entfernen**

### Allgemein › Menüleiste & Dock

- **Menüleistensymbol**
- **Albumcover**
- **Symbolgröße**
- **Symbol animieren**
- **Im Dock zeigen**

### Allgemein › Erscheinungsbild & Sprache

- **Erscheinungsbild**: Farben von Einstellungen, Liedtextfenster, Liedtext-Verwaltung und Menüleisten-Panel
- **Sprache**

### Allgemein › Start & Mitteilungen

- **Bei Anmeldung öffnen**
- **Still starten**
- **Bei Titelwechsel mitteilen**

### Allgemein › Netzwerk

- **Proxy**

### Allgemein › Backup & Migration

- **iCloud-Backup**
- **Einstellungsdatei**: Enthält Zugangsdaten im Klartext. Exportiert Einstellungen und Liedtext-Bibliothek als zwei Dateien; der Import ersetzt alle Einstellungen
- **Alle Einstellungen löschen**: Löscht nur die Einstellungen auf diesem Mac; Backups und exportierte Dateien bleiben erhalten. Kann nicht widerrufen werden

### Softwareupdate

- **Softwareupdate**

### Softwareupdate › Update-Einstellungen

- **Automatisch prüfen**: Sucht einmal täglich nach einer neuen Version
- **Automatisch laden und installieren**: Lädt im Hintergrund und installiert beim Beenden von Lyrimuse
- **Beta-Updates**: Vorabversionen, möglicherweise instabil

### Über › Updates & Hilfe

- **Problem melden**: Öffnet ein neues GitHub-Issue mit deiner Version, macOS und Player bereits ausgefüllt
- **Hilfe erhalten**: Frag in der Q&A-Kategorie der GitHub Discussions
- **Funktionsliste**: Alle Funktionen, wo sie in den Einstellungen zu finden sind, und ihr Standardzustand

### Über

- **Website**
- **Discord-Community**: Tausche dich mit anderen aus, stelle Fragen oder schlage Funktionen vor
- **Telegram-Gruppe**: Tausche dich mit anderen aus, stelle Fragen oder schlage Funktionen vor
- **QQ-Gruppe**: Tausche dich mit anderen aus, stelle Fragen oder schlage Funktionen vor
- **Urheberrechtshinweis**
- **Lizenzen von Drittanbietern**: Open-Source-Komponenten und Wörterbücher
- **Open-Source-Lizenz**: GPL-3.0

### Über › Diagnose & Daten

- **Diagnose exportieren**: Protokolle, Absturzberichte und App-Status in einer Datei, ohne Accountdaten. Titelnamen und lokale Pfade bleiben enthalten – prüfe sie vor dem Veröffentlichen
- **Aktivitätsprotokoll**: Das Rohprotokoll der Liedtext-Engine, zur eigenen Fehlersuche
- **Datenordner**: Reiner Text. Accountdaten, Erscheinungsbild und Kurzbefehle sind nicht enthalten; für eine vollständige Migration nutze „Backup & Migration“
- **Anonyme Nutzungsdaten senden**: Hilft, Lyrimuse zu verbessern: Version, System, genutzte Funktionen und Absturzberichte. Nie Titel oder Accounts
- **Cache**: Cover und Abfragen, die erneut geladen werden können

### Labor › ListenBrainz

- **Account-Infos**

### Last.fm › Regeln

- **Scrobble-Regeln**
- **Abgleichmodus**: Künstler und Titel für Last.fm Smart: nutzt die meistgehörte Schreibweise auf Last.fm, sonst unverändert. Bei Alben fällt „ - Single“ / „ - EP“ weg Eigene: Titel und Künstler getrennt festlegen Original: sendet genau, was der Player meldet
- **Titel**
- **Künstler**
- **Scrobbeln bei**
- **Titel unter 30 Sekunden scrobbeln**: Wenn aktiv, werden diese Titel nach der Hälfte gescrobbelt. Nach den offiziellen Last.fm-Regeln nicht
- **Player zum Scrobbeln**

### Labor › Web-Push

- **Verbindungsinfo**

### Push-Mitteilungen

- **Kanäle**: Hörberichte gehen an alle aktiven Kanäle. Bei mehreren Kanälen wählst du sie für jeden Bericht unten unter „Hörberichte“. Klicke auf eine Zeile, um sie zu bearbeiten oder einen Test zu senden; Rechtsklick zum Löschen
- **Sendezeit**
- **Hörberichte**
- **Datenquelle**
- **Einträge je Liste**: Wie viele Top-Künstler, -Alben und -Titel aufgelistet werden
- **Wöchentlicher Hörrückblick**
- **Täglicher Hörbericht**
- **Monatlicher Hörrückblick**
- **Jährlicher Hörrückblick**
- **Sendeverlauf**

### Discord

- **Auf Discord anzeigen**: Wenn aktiviert, erscheint der Titel, den du hörst, in deinem Discord-Profil und in der Freundesliste. Sehen ihn deine Freunde nicht, schalte in Discord unter „Benutzereinstellungen › Aktivitätsprivatsphäre“ die Aktivitätsfreigabe ein
- **Was angezeigt wird**
- **Nach „Hört“**: Das „××“ in „Hört ××“ in deinem Profil. Discord für iOS und im Web ignoriert dies und zeigt weiter den Player Mit Titel oder Künstler hier kann „Unter deinem Namen“ nicht den Player zeigen
- **Unter deinem Namen**: Discord kann nur die erste Zeile, die zweite Zeile oder den Text nach „Hört“ unter deinem Namen zeigen. Steht weder Titel noch Künstler an einer dieser Stellen, ist die Option nicht verfügbar
- **Cover-Badge**
- **Bei Pause**
- **Titelinfos**
- **Statustext**
- **Cover und Fortschritt**
- **Künstler und Album beschriften**: Fügt „von“ vor dem Künstler und „auf“ vor dem Album hinzu. Entfällt, wenn Titel und Künstler in einer Zeile stehen
- **Buttons**
- **Eigener Button**
- **„Auf Player anhören“**: Öffnet die Seite dieses Titels auf der Website des aktuellen Players, wie ein Klick auf den Titel. Ausgeblendet, wenn keine Seite vorhanden ist
- **„Lyrimuse laden“**
- **Datenschutz**
- **Vorübergehend ausblenden**
- **Titeldetails ausblenden**: Zeigt nur deinen Player und den Fortschritt. Titel, Künstler, Album, Liedtext, Links und die Taste „Im Player anhören“ werden nicht gesendet
- **Fortschrittsbalken anzeigen**: Wenn deaktiviert, gibt es keinen Fortschrittsbalken; Discord zeigt stattdessen die verstrichene Zeit, die sich nicht abschalten lässt
- **Angezeigte Player**
