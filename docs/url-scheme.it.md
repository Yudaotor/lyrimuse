# Schema URL di Lyrimuse

*[English](url-scheme.md) · [简体中文](url-scheme.zh-CN.md) · [日本語](url-scheme.ja.md) · [한국어](url-scheme.ko.md) · [Español](url-scheme.es.md) · [Français](url-scheme.fr.md) · [Deutsch](url-scheme.de.md) · **Italiano** · [Português (Brasil)](url-scheme.pt-BR.md) · [Tiếng Việt](url-scheme.vi.md) · [Русский](url-scheme.ru.md)*

I link che iniziano con `lyrimuse://` ti permettono di controllare Lyrimuse da Comandi Rapidi, Raycast, Alfred, Stream Deck, dal Terminale (`open 'lyrimuse://…'`) e da strumenti simili: aprire finestre e pagine delle impostazioni, mostrare o nascondere il testo, controllare la riproduzione, regolare il timing o sapere cosa è in riproduzione.

Quelli più comuni si possono copiare da **Deep link**, in fondo a Impostazioni › Scorciatoie da tastiera. Passa il puntatore su una scorciatoia per copiare il link della relativa azione.

## Regole generali

- I link non distinguono tra maiuscole e minuscole.
- Un link che Lyrimuse non riconosce non fa nulla e mostra “Link non riconosciuto”.
- Ogni link che apre una finestra accetta `background=1`: la finestra compare, ma Lyrimuse non passa in primo piano e non prende il focus della tastiera. Ad esempio `lyrimuse://lyrics-window?background=1`.
- Le azioni di attivazione/disattivazione accettano `on=1` o `on=0` per impostare uno stato preciso (funzionano anche `true` / `false` e `on` / `off`), così eseguirle due volte dà lo stesso risultato. Senza il parametro, invertono lo stato.
- Anche le pagine web possono aprire i link `lyrimuse://` (il browser chiede prima conferma), perciò sono esposte solo azioni facili da annullare: attivazioni/disattivazioni, apertura di finestre, controllo della riproduzione e piccoli spostamenti del timing. Nessun link elimina o modifica testi, né tocca i tuoi account.

## Aprire finestre

| Link | Cosa fa |
|---|---|
| `lyrimuse://lyrics-window` | Apre la Finestra testo |
| `lyrimuse://lyrics-window/search` | Apre la Finestra testo e la finestra “Cerca testi” (la stessa di `lyrics-search`) |
| `lyrimuse://lyrics-manager` | Apre Gestione testi |
| `lyrimuse://lyrics-search` | Apre la finestra “Cerca testi” per il brano attuale |
| `lyrimuse://menubar-panel` | Apre o chiude il pannello della barra dei menu |
| `lyrimuse://menubar-panel?quick=overlay` | Apre il pannello della barra dei menu sulle impostazioni rapide di un riquadro (lo apre soltanto, non lo chiude mai). `quick` è uno tra `overlay`, `notch`, `menubar`, `touchbar`, `lyrics-window`, `lyrics-manager` |
| `lyrimuse://menubar-menu` | Apre il menu dell’icona nella barra dei menu |
| `lyrimuse://onboarding` | Apre la guida di configurazione |
| `lyrimuse://whats-new` | Mostra le novità della versione installata |

## Aprire le impostazioni

`lyrimuse://settings` apre Impostazioni. Aggiungi un percorso per andare direttamente a una pagina, e un altro segmento per andare a una sezione di quella pagina.

| Percorso | Pagina | Sezioni |
|---|---|---|
| `/lyrics` | Testo | `/fetch` o `/sources` Fonte, `/translation` o `/language` Lingua, `/display` o `/timing` Timing, `/manage` o `/library` Libreria testi |
| `/player` | Player | `/players` Player, `/linkage` Avvio e uscita, `/permissions` Permessi e servizi |
| `/appearance` | Visualizzazione testo | `/overlay` Testo fluttuante, `/notch` Notch, `/menu-bar` Barra dei menu, `/touch-bar` Touch Bar, `/lyrics-window` Finestra testo |
| `/shortcuts` | Scorciatoie da tastiera | — |
| `/general` | Generali | — |
| `/about` | Info | — |
| `/account/lastfm` | Last.fm | `/stats` Statistiche, `/chart` Classifiche, `/on-this-day` Impronta, `/settings` Regole |
| `/account/listenbrainz` | ListenBrainz | — |
| `/account/discord` | Discord | `/display` Contenuto mostrato, `/buttons` Pulsanti, `/privacy` Privacy |
| `/account/relay` | Push web | — |
| `/account/bark` | Avvisi push | — |
| `/software-update` | Aggiornamento software | Aggiungi `?check=1` per verificare anche la presenza di aggiornamenti |
| `/lastfm-suggestions` | Suggerimenti per l’account Last.fm | — |
| `/labs` | Lab | — |

Ad esempio `lyrimuse://settings/appearance/overlay` o `lyrimuse://settings/software-update?check=1`. Un percorso sconosciuto apre semplicemente Impostazioni; una sezione sconosciuta apre la pagina sull’ultima sezione che hai visto.

## Azioni: `lyrimuse://action/<name>`

Sono le stesse azioni delle scorciatoie in Impostazioni › Scorciatoie da tastiera. Eseguono lo stesso codice e mostrano lo stesso feedback.

### Visualizzazione

| Nome | Cosa fa | Parametri |
|---|---|---|
| `toggle-overlay` | Mostra o nasconde il testo fluttuante | `on` |
| `toggle-notch` | Mostra o nasconde il testo nel notch | `on` |
| `peek-notch` | Espande il testo nel notch per qualche secondo; eseguila di nuovo per chiuderlo prima | — |
| `toggle-menubar-lyrics` | Mostra o nasconde il testo nella barra dei menu | `on` |
| `toggle-touchbar` | Espande o comprime il testo nella Touch Bar (solo Mac con Touch Bar) | — |
| `toggle-all-lyrics` | Nasconde tutto il testo: nasconde quelli attivi tra testo fluttuante, testo nel notch e testo nella barra dei menu; eseguendola di nuovo ricompaiono esattamente quelli | `on` (`0` nasconde, `1` ripristina) |
| `toggle-lock-position` | Blocca o sblocca la posizione del testo fluttuante | `on` |
| `toggle-translation` | Mostra o nasconde le traduzioni | `on` |
| `toggle-romanization` | Mostra o nasconde la pronuncia | `on` |
| `overlay-font-larger` | Ingrandisce il testo fluttuante | — |
| `overlay-font-smaller` | Rimpicciolisce il testo fluttuante | — |

### Finestre

| Nome | Cosa fa | Parametri |
|---|---|---|
| `open-lyrics-manager` | Apre Gestione testi | — |
| `open-lyrics-window` | Apre la Finestra testo | — |
| `toggle-lyrics-window-mini` | Passa la Finestra testo tra dimensione mini e completa; se è chiusa, la apre in dimensione mini | `on` (`1` mini, `0` completa) |
| `search-lyrics` | Apre la finestra “Cerca testi” | — |
| `open-settings` | Apre Impostazioni | — |
| `open-player` | Porta in primo piano il player che stai usando | — |
| `toggle-menubar-panel` | Apre o chiude il pannello della barra dei menu, come un clic sulla sua icona | — |

### Timing del testo

| Nome | Cosa fa | Parametri |
|---|---|---|
| `lyrics-advance` | Anticipa di un passo il testo di questo brano | `step`: secondi per questo spostamento (da 0 a 5); se omesso, il passo impostato in Impostazioni |
| `lyrics-delay` | Ritarda di un passo il testo di questo brano | `step`, come sopra |
| `lyrics-offset-reset` | Azzera l’offset del testo di questo brano | — |

### Riproduzione

| Nome | Cosa fa | Parametri |
|---|---|---|
| `play-pause` | Riproduci / pausa | — |
| `next-track` | Brano successivo | — |
| `previous-track` | Brano precedente | — |
| `toggle-favorite` | Aggiunge o rimuove il brano attuale dai preferiti (se il player lo supporta) | `on` (`1` aggiunge, `0` rimuove) |

Ad esempio `lyrimuse://action/toggle-overlay?on=0` o `lyrimuse://action/lyrics-advance?step=0.5`.

### Altre azioni

| Link | Cosa fa |
|---|---|
| `lyrimuse://action/copy-lyric` | Copia negli appunti la riga attuale del testo; aggiungi `?translation=1` per includere la traduzione |
| `lyrimuse://action/surfaces?overlay=1&notch=0&menubar=1` | Imposta in un colpo solo quali testi sono visibili: `overlay` (testo fluttuante), `notch`, `menubar`, ciascuno `1` per mostrarlo o `0` per nasconderlo. Includi solo quelli che vuoi cambiare |
| `lyrimuse://action/lyrics-offset?ms=-300` | Imposta l’offset del testo di questo brano su un valore esatto in millisecondi: positivo anticipa, negativo ritarda, entro ±10000 |
| `lyrimuse://action/play-mode?mode=shuffle` | Imposta la modalità di riproduzione: `mode` è `list`, `shuffle`, `repeat-all` o `repeat-one`. Le modalità che il player non supporta ripiegano su `list` |

## Ottenere cosa è in riproduzione (x-callback-url)

```
lyrimuse://x-callback-url/now-playing?x-success=<callback URL>
```

Lyrimuse apre l’URL `x-success` aggiungendo come parametri cosa è in riproduzione (gli eventuali parametri già presenti in `x-success` vengono mantenuti):

| Parametro | Valore |
|---|---|
| `title` | Titolo del brano |
| `artist` | Artista |
| `album` | Album |
| `lyric` | La riga attuale del testo |
| `player` | Nome del player |
| `playing` | `1` durante la riproduzione, `0` in pausa o se non c’è nulla di caricato (se non c’è nulla di caricato, i campi sopra sono vuoti) |

In Comandi Rapidi, usa l’azione **Apri URL X-Callback** con `lyrimuse://x-callback-url/now-playing` come URL. Comandi Rapidi aggiunge da solo `x-success`, e i parametri restituiti diventano l’output dell’azione.

Perché le pagine web non possano usare questo link per scoprire cosa stai ascoltando, l’URL di callback ha due limiti: non può essere un URL web, di file o di script (`http`, `https`, `file`, `ftp`, `javascript`, `data`, `about`, `blob`, né `lyrimuse` stesso), e sul tuo Mac deve essere aperto da un’app che non sia un browser. Altrimenti non viene restituito nulla.
