# Wie Lyrimuse zu Last.fm scrobbelt

*[English](scrobbling.md) · [简体中文](scrobbling.zh-CN.md) · [日本語](scrobbling.ja.md) · [한국어](scrobbling.ko.md) · [Español](scrobbling.es.md) · [Français](scrobbling.fr.md) · **Deutsch** · [Italiano](scrobbling.it.md) · [Português (Brasil)](scrobbling.pt-BR.md) · [Tiếng Việt](scrobbling.vi.md)*

## 1. Wann eine Wiedergabe zählt

Eine Wiedergabe wird übermittelt, sobald **alle** diese Bedingungen erfüllt sind:

| Regel | Wert |
|---|---|
| Lange genug gehört | die Hälfte des Titels, höchstens 240 s – oder 240 s, wenn die Länge unbekannt ist. Strengere Zeitpunkte nur für Last.fm – siehe §1b |
| Titel ist lang genug | `≥ 30s` (Titel unbekannter Länge werden durchgelassen). Abschaltbar – siehe §1a |
| Keine Werbung | Werbepausen bei Spotify werden erkannt und übersprungen |

Die Wiedergabe wird alle 5 Sekunden abgefragt, und die verstrichene Zeit wird nach der realen Uhrzeit gezählt: Pausieren hält die Zählung an, und Vorspulen bläht sie nicht auf. Liegen zwei Abfragen mehr als 60 Sekunden auseinander – der Mac war im Ruhezustand oder die Engine wurde neu gestartet –, wird diese Lücke verworfen statt angerechnet.

Diese Schwellen entsprechen den [Scrobbling-Richtlinien von Last.fm](https://www.last.fm/api/scrobbling).

### 1a. Titel unter 30 Sekunden

Einstellungen → Verknüpfte Dienste → Last.fm → *Regeln* → **Titel unter 30 Sekunden scrobbeln** (`scrobble_short_tracks`, standardmäßig **aus**). Die Last.fm-Regel *„The track must be longer than 30 seconds“* (der Titel muss länger als 30 Sekunden sein) ist eine clientseitige Regel – der Server lehnt kurze Titel nicht ab und hat keinen Ignorier-Code für „zu kurz“ –, und alle gängigen Scrobbler halten sich daran, also standardmäßig auch Lyrimuse. Schaltest du die Option ein, zählen kurze Titel, sobald sie die Hälfte-Regel erfüllen (ein 20-Sekunden-Titel braucht 10 Sekunden). Die Einstellung gilt **nur für Last.fm**: Kurze Titel werden zu Last.fm gescrobbelt (und im lokalen Protokoll vermerkt, aus dem das Nachreichen bei Last.fm schöpft), aber nie an ListenBrainz übermittelt, dessen Verhalten in beiden Fällen gleich bleibt.

### 1b. Scrobble-Zeitpunkt

Einstellungen → Verknüpfte Dienste → Last.fm → *Regeln* → **Scrobbeln bei** (`lastfm_scrobble_point`, standardmäßig **50 %**). Wie weit ein Titel gespielt sein muss, bevor er zu Last.fm gescrobbelt wird:

| Einstellung | Wert | Gescrobbelt, wenn |
|---|---|---|
| **50 %** (Standard) | `50` | die Last.fm-Regel oben erfüllt ist: die Hälfte des Titels, höchstens 4 Minuten |
| 75 % / 90 % | `75` / `90` | 75 % / 90 % der Titellänge gespielt wurden – nur die tatsächlich gespielte Zeit, ohne 4-Minuten-Grenze |
| Titelende | `end` | der Titel bis zum Ende durchläuft; Vorspulen zählt nicht |

Die Last.fm-Regel ist eine Untergrenze, deshalb gibt es keine Einstellung unter 50 %. Sie gilt **nur für Last.fm**: ListenBrainz und das Web-Relay übermitteln weiterhin bei 50 %; nur der Last.fm-Scrobble (und das lokale Protokoll, aus dem das Nachreichen bei Last.fm schöpft) wartet auf den gewählten Zeitpunkt. Ein Titel, der vor diesem Zeitpunkt übersprungen wird, sendet nichts an Last.fm – das ist die Einstellung, die ihre Arbeit tut, kein verlorener Scrobble. Titel unbekannter Länge folgen der Standardregel.

*Titelende* wird beim Titelwechsel anhand der zuletzt beobachteten Wiedergabeposition beurteilt: Innerhalb von 12 Sekunden vor dem Ende (bei kurzen Titeln 10 % der Länge) gilt der Titel als durchgespielt, sodass Überblenden im Player oder ein lückenloser Übergang den Scrobble nicht zurückhält.

## 2. Was gesendet wird

`track.scrobble` schreibt den dauerhaften Eintrag in deinen Verlauf; `track.updateNowPlaying` setzt die Anzeige „hört gerade“ und speichert nichts.

| Feld | `track.scrobble` | `track.updateNowPlaying` |
|---|---|---|
| `artist` | ✅ | ✅ |
| `track` | ✅ | ✅ |
| `timestamp` | ✅ | — |
| `album` | wenn nicht leer | wenn nicht leer |
| `duration` | wenn bekannt | wenn bekannt |

Sonst erreicht nichts Last.fm. Die API akzeptiert bei einem Scrobble auch `mbid`, `albumArtist`, `trackNumber`, `chosenByUser`, `streamId` und `context`; Lyrimuse sendet nichts davon.

## 3. Was nicht umgeschrieben wird

Auf dem Weg zu ListenBrainz sowie in den Last.fm-Modi *Alle* und *Nur erster* werden Künstler-, Titel- und Albumnamen genau so übermittelt, wie der Player sie gemeldet hat. (Der Last.fm-Modus *Smart* schreibt Künstler und Titel passend zum Katalogeintrag um – siehe nächster Abschnitt.)

Die einzige Verarbeitung ist das Bereinigen unsichtbarer Zeichen: Geschützte und vollbreite Leerzeichen werden zu normalen Leerzeichen, Nullbreitenzeichen und BOMs werden entfernt, mehrere Leerzeichen hintereinander werden zu einem zusammengefasst, und Leerzeichen am Anfang und Ende werden abgeschnitten. Ohne diesen Schritt legt ein unsichtbares geschütztes Leerzeichen auf Last.fm einen eigenen Künstlereintrag an.

Nichts Sichtbares wird verändert – weder Groß- und Kleinschreibung noch traditionelles oder vereinfachtes Chinesisch, weder Untertitel in Klammern noch Angaben mehrerer Künstler. `PRINCE` bleibt `PRINCE`, `無所謂` bleibt `無所謂`, und `一口 (The Day You Left Me)` behält seinen Untertitel.

Warum es standardmäßig keine externe Abfrage gibt, um Namen zu „vereinheitlichen“:

- Genau das hat Lyrimuse früher getan. Eine Prüfung einer echten Bibliothek mit rund 2.500 Titeln fand etwa 200 umgeschriebene Künstlernamen, darunter `USA for Africa` → `Xtc Planet` und `LBI利比` → `Safehse`. Scrobbles, die bereits auf einer öffentlichen Last.fm-Künstlerseite stehen, lassen sich nachträglich nicht mehr korrigieren – die Korrekturdatenbank ist eingefroren.
- Der Scrobbling-Leitfaden von Last.fm sagt gleich zweimal: *„Do not use the corrections returned by the now playing service as input for the scrobble request, unless they have been explicitly approved by the user.“* (Verwende die vom Now-Playing-Dienst zurückgegebenen Korrekturen nicht als Eingabe für die Scrobble-Anfrage, sofern der Nutzer sie nicht ausdrücklich bestätigt hat.) Das Flag `autocorrect` ist [als veraltet dokumentiert](https://support.last.fm/t/scrobbles-of-japanese-artists-getting-separated-by-romanization-of-their-name/119906).
- Von neun untersuchten Open-Source-Scrobblern (Web Scrobbler, Pano Scrobbler, Navidrome, Maloja, rescrobbled, mpdscribble, mpdas, Koito, multi-scrobbler) schreibt keiner standardmäßig Künstlernamen anhand einer externen Abfrage um.

## 4. Abgleichmodus

Einstellungen → Verknüpfte Dienste → Last.fm → *Regeln* → **Abgleichmodus** (`lastfm_match_mode` in `~/Library/Application Support/me.yudaotor.lyrimuse/lyrimuse-features.json`):

| Modus | Wert | Wirkung |
|---|---|---|
| **Smart** (Standard bei Neuinstallationen) | `smart` | Sucht den Eintrag dieses Titels im Last.fm-Katalog und sendet Künstler und Titel dieses Eintrags (siehe unten) |
| Eigene | `custom` | Du wählst, welche Teile sich ändern dürfen – siehe unten |
| **Original** (Standard bei bestehenden Installationen) | `raw` | Genau das, was der Player meldet, ohne Netzwerkzugriff |

*Eigene* fügt zwei Zeilen hinzu, eine pro Feld:

| Zeile | Option | Wirkung |
|---|---|---|
| **Titel** | Abgleich | Der Titel darf durch die Schreibweise des Katalogeintrags ersetzt werden, und ` - Single` / ` - EP` fällt beim Album weg (`lastfm_match_track`) |
| | Original | Der Titel wird wie gemeldet gesendet |
| **Künstler** | Abgleich | Der Künstler darf durch die Schreibweise des Katalogeintrags ersetzt werden (`lastfm_match_artist`) |
| | Nur erster | Kürzt eine gemeinsame Künstlerangabe auf den ersten Künstler (`Khalil Fong & Fiona Sit` → `Khalil Fong`) – reine Zeichenkettenverarbeitung, ohne Netzwerkzugriff (`lastfm_match_first_artist_only`) |
| | Original | Der Künstler wird wie gemeldet gesendet |

Ist *Abgleich* nur in einer der beiden Zeilen gewählt, **wird ein Treffer nur übernommen, wenn das andere Feld bereits übereinstimmt** – sonst entstünde eine Kombination, die es im Katalog nicht gibt, und die Wiedergabe landete wieder auf einem Geistereintrag mit einem einzigen Hörer: dir.

*Nur erster* unterscheidet sich von *Abgleich*: Es greift **nur, wenn nichts abgeglichen wurde**. Eine abgeglichene Schreibweise ist bereits der Eintrag, den Last.fm kennt, und sie zu kürzen würde daraus einen Eintrag machen, den es nicht gibt – `Hall & Oates / Maneater` (800.000 Hörer) würde zu `Hall`. Titel *Original* mit Künstler *Nur erster* entspricht deshalb Byte für Byte dem früheren Modus *Nur erster*, weiterhin ohne Netzwerkzugriff.

*Original* bleibt überall dort Standard, wo bereits eine `lyrimuse-features.json` existiert, denn das Kürzen einer Künstlerangabe lässt sich nicht rückgängig machen – es entfernt Fiona Sit aus deinem Verlauf. Die gleichnamige Option von Navidrome (`Lastfm.ScrobbleFirstArtistOnly`) ist ebenfalls standardmäßig aus.

Das Aufteilen ist zurückhaltend: `/` wird getrennt von `,` und `&` behandelt, sodass `K/DA` und `AC/DC` nicht in `K` und `AC` zerlegt werden.

### Smart-Modus

Was der Player meldet und wie der Last.fm-Katalog dieselbe Aufnahme nennt, sind oft nicht dieselben Zeichen, und unverändert übermittelt landet die Wiedergabe auf einem „Geistereintrag“ – keine MBID, kein Album, Dauer null, ein einziger Hörer: du. Gemessen an David Taos 《那个女孩》: Der Player meldet `陶喆, 卢广仲 / 那个女孩`, was Last.fm gar nicht kennt; die vereinfachte Form `陶喆 / 那个女孩` hat 126 Hörer; und der eigentliche Eintrag des Titels ist die traditionelle Form **`陶喆 / 那個女孩` – 889 Hörer, 4.580 Wiedergaben, mit Katalogdauer**. Das Last.fm-eigene `autocorrect` hilft nicht: Es ordnet traditionelles und vereinfachtes Chinesisch einander nicht zu.

Deshalb schlägt *Smart* den Titel vor dem Übermitteln nach:

1. `track.getInfo` wie gemeldet. **Hat der Eintrag eine MBID**, wird nichts angefasst, für immer. Eine MBID ist das stärkste Zeichen für eine echte Katalogidentität, und sie verhindert, dass eine korrekt angegebene Zusammenarbeit (Hall & Oates) wegen „mehr Hörern“ auf eine Solo-Seite verschoben wird.
2. Andernfalls werden Treffer aus **genau drei Quellen** gesammelt: wie gemeldet, der erste angegebene Künstler und Einträge dieses Künstlers, deren Titel sich auf denselben Schlüssel zurückführen lässt (`artist.getTopTracks`, bereits nach Hörern sortiert).
3. Unter den Treffern, die Last.fm tatsächlich im Katalog hat (eine MBID, ≥ 500 Hörer oder eine Katalogdauer – ein Geistereintrag hat nichts davon), gewinnt der meistgehörte, seine Dauer wird geprüft, und sein Künstler und Titel werden übermittelt – einmal entschieden, für immer behalten. Erfüllt kein Treffer die Bedingungen, wird wie gemeldet gesendet und nach 90 Tagen erneut geprüft.

`track.search` wird bewusst **nicht** verwendet: Es sucht nach der wörtlichen Zeichenkette, findet also weder den traditionellen Eintrag noch schließt es gleichnamige andere Lieder wie `张泽熙 / 那个女孩` aus. Das Zurückführen des Titels gleicht nur Schreibunterschiede einer einzigen Aufnahme an – traditionell vs. vereinfacht, Zeichenvarianten, diakritische Zeichen, Gastangaben (`(feat. X)`) und Neuauflage-Vermerke (`(Remastered 2014)`, `(Bonus Track)`). **Live-, Remix-, Akustik- und Instrumental-Vermerke bleiben immer erhalten**: Das sind andere Aufnahmen. Der siegreiche Treffer muss außerdem eine Dauerprüfung bestehen (abgelehnt, wenn beide Seiten eine Dauer kennen und diese um mehr als 8 Sekunden voneinander abweichen).

Gemessen an 240 echten Titeln: 33 umgeschrieben, 162 unverändert gesendet, 45 nicht entscheidbar. Beispiele:

| Gemeldet | Gesendet | Hörer |
|---|---|---|
| `周杰倫 / 手写的从前` | `周杰倫 / 手寫的從前` | 100 → 4.515 |
| `Wang Leehom / 奇遇的起点` | `王力宏 / 奇遇的起點` | 1 → 144 |
| `SZA & Phoebe Bridgers / Ghost in the Machine` | `SZA / Ghost in the Machine (feat. Phoebe Bridgers)` | 175 → 856.376 |
| `PRINCE / Walk Don't Walk (2023 Remaster)` | `Prince / Walk Don't Walk` | 231 → 16.178 |

Jeder Fehler bei der Abfrage (Netzwerk, Ratenlimit, fehlerhafte Antwort, nicht erreichbare Titelliste) sendet die Angaben wie gemeldet und speichert nichts im Cache, sodass ein Aussetzer nie zu einer dauerhaften Entscheidung wird. Die Entscheidungen liegen in `~/Library/Application Support/me.yudaotor.lyrimuse/lyrimuse-lastfm-catalog.json`, zusammen mit den Belegen, die zu ihnen geführt haben; lösche die Datei, um alles neu zu entscheiden.

Die alten Schlüssel werden weiterhin gelesen, aber nicht mehr geschrieben, und ohne Verhaltensänderung übernommen: `lastfm_scrobble_artist_mode` ordnet `smart` → Smart, `all` → Original und `first` → Eigene zu, mit Titel auf Original und Künstler auf Nur erster; der ältere Boolesche Wert `lastfm_scrobble_first_artist_only=true` entspricht `first`.

## 5. Wenn ein Scrobble fehlschlägt

Fehler werden eingeordnet, weil die richtige Reaktion jeweils eine andere ist. „Vermerken“ heißt unten, dass die Wiedergabe in ein lokales Protokoll geschrieben wird, aus dem ein **Nachreichen** – manuell gestartet mit **Nachreichen** neben der Zahl „zu übermittelnder Wiedergaben“ unter deinen letzten Wiedergaben – sie später übermitteln kann.

| Was passiert ist | Was wir tun |
|---|---|
| Die Anfrage hat deinen Mac nachweislich nie verlassen (DNS, Verbindungsaufbau gescheitert) | Vermerken; Nachreichen kann sie übermitteln |
| Der Server hat sie aus einem Grund abgelehnt, der sicher bedeutet, dass sie nicht gespeichert wurde (ungültige Zugangsdaten, Ratenlimit) | Vermerken; Nachreichen kann sie übermitteln |
| Gesendet, aber mit unbekanntem Ausgang (Zeitüberschreitung, abgebrochene Verbindung, uneindeutiger Serverfehler) | Vermerken, aber Nachreichen versucht sie **nie** automatisch erneut |
| Der Server hat den Titel erhalten und den Inhalt selbst abgelehnt | Nicht vermerken; den tatsächlichen Grund des Servers anzeigen |

Die dritte Zeile gibt es, weil eine Zeitüberschreitung bedeuten kann, dass Last.fm die Wiedergabe gespeichert hat und nur die Bestätigung verloren ging. Ein erneuter Versuch würde ein Duplikat erzeugen, das von Hand gelöscht werden muss, deshalb wird ein uneindeutiger Fehler nie automatisch wiederholt.

Nachreichen reicht nur **13 Tage** zurück. Wurde eine Wiedergabe einmal versucht, sendet der Echtzeitweg sie nie wieder: Die Wiedergabe wird als versucht markiert, *bevor* die Anfrage hinausgeht, nicht erst nach ihrem Erfolg, sodass ein Absturz mitten in der Anfrage keine zweite Übermittlung erzeugen kann.

## 6. Wo zusammengeführt wird

Last.fm erhält, was der Player gemeldet hat. Eine Bibliothek, die dieselbe Person sowohl als `Khalil Fong` als auch als `方大同` meldet, zeigt dort also zwei Künstler.

Innerhalb von Lyrimuse werden sie bei Wiedergabezahlen, Charts und „Wiedergabe #N“-Angaben zusammengeführt – über das Angleichen von traditionellem und vereinfachtem Chinesisch, Aliasse für romanisierte Namen, das Entfernen von Katalogzusätzen (`(Remastered 2014)`, `(feat. …)`, `(Explicit)`) und eine Alias-Tabelle pro Künstler. Zusammengeführt wird lokal statt vor dem Übermitteln, weil eine falsche lokale Zusammenführung mit einer Aktualisierung behoben ist, ein falscher Scrobble dagegen eine dauerhafte Änderung an einer öffentlichen Seite ist.

## 7. Häufige Fragen

**Kann ich Lyrimuse ohne Scrobbeln nutzen?**
Ja, das ist der Standard – es wird nichts gescrobbelt, bis du unter Einstellungen → Verknüpfte Dienste einen Last.fm-Account verbindest. Das Abrufen von Liedtexten und Covern ist davon getrennt: Es sendet Künstler- und Titelnamen an die öffentlichen Liedtextanbieter (Netease, QQ, Kugou, LRCLIB, Musixmatch, AMLL), unabhängig davon, ob ein Account verbunden ist. Diese Quellen kannst du in den Einstellungen einschränken oder deaktivieren.

**Warum erscheint derselbe Künstler zweimal in meinem Last.fm-Profil?**
Dein Player hat zwei verschiedene Namen gemeldet, und beide wurden wie gemeldet übermittelt. Lyrimuse führt sie in seiner eigenen Statistik zusammen; um sie auf Last.fm zusammenzuführen, musst du die Scrobbles dort bearbeiten.

**Können Namen vor dem Senden bereinigt werden?**
Nein. Wenn du das möchtest, ist eine vom Nutzer bearbeitbare Regeltabelle der gangbare Weg statt einer automatischen Abfrage – sieh dir an, wie [Maloja](https://github.com/krateng/maloja) das löst.

**Was ist mit Wiedergaben auf meinem iPhone?**
Lyrimuse übermittelt sie nie an Last.fm; sie gelangen über Apples eigenes Scrobbling dorthin. Lyrimuse liest sie zurück, damit sie in seiner Statistik neben den Wiedergaben auf dem Mac erscheinen.

**Lassen sich Künstler auf Last.fm zusammenführen, ohne Namen umzuschreiben?**
Nicht über die API. Der Last.fm-Parameter `mbid` bezeichnet einen *Titel*, keinen Künstler, es gibt also kein Feld, mit dem man „diese zwei Namen sind dieselbe Person“ sagen und dabei beide Namen unverändert lassen könnte.

**Doppelt das lokale Wiedergabeprotokoll meine Scrobbles?**
Nein. Es vermerkt eine Wiedergabe nur, wenn kein Last.fm-Account verbunden ist oder eine Übermittlung fehlgeschlagen ist. Ist Last.fm verbunden und funktioniert, bleibt es leer.

---

*Implementierung: [`lyrimuse-engine/lastfm.go`](../lyrimuse-engine/lastfm.go)
(`resolveScrobbleArtist`, `scrobble`, `updateNowPlaying`),
[`lyrimuse-engine/poller.go`](../lyrimuse-engine/poller.go)
(`listenThreshold`, `recordFailedMirror`).*
