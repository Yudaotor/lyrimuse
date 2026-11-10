<!-- Generato da scripts/gen-feature-list.py a partire da shared/feature-list.json e shared/settings-catalog.json; per modificare l’elenco, modifica questi file. -->

# Elenco delle funzioni di Lyrimuse

[English](feature-list.md) · [简体中文](feature-list.zh-CN.md) · [繁體中文](feature-list.zh-Hant.md) · [日本語](feature-list.ja.md) · [한국어](feature-list.ko.md) · [Español](feature-list.es.md) · [Français](feature-list.fr.md) · [Deutsch](feature-list.de.md) · Italiano · [Português (Brasil)](feature-list.pt-BR.md) · [Tiếng Việt](feature-list.vi.md) · [Русский](feature-list.ru.md) · [Українська](feature-list.uk.md) · [ไทย](feature-list.th.md)

Lyrimuse è un’app per Mac open source (GPL-3.0) per testi sincronizzati parola per parola, per macOS 14 o versioni successive su Apple Silicon e Intel. Mostra il testo di Apple Music, Spotify, QQ Music, NetEase Cloud Music, Kugou, Soda Music, KKBOX, Amazon Music, LX Music, Kaset, Pear Desktop, reAMP, VOX, Pine Player, foobar2000, Swinsian, Plexamp, MyGo Music e di YouTube Music o Spotify Web in riproduzione in un browser: fluttuante sulla scrivania, accanto al notch, nella barra dei menu, sulla Touch Bar o in una finestra testo completa, con traduzioni e pronuncia (pinyin, jyutping cantonese, romaji giapponese, romanizzazione del coreano). Fa lo scrobble su Last.fm e ListenBrainz e può mostrare su Discord cosa stai ascoltando. L’interfaccia è disponibile in inglese, cinese semplificato, cinese tradizionale, giapponese, coreano, spagnolo, francese, tedesco, italiano, portoghese brasiliano, vietnamita, russo, ucraino e thailandese.

Questo elenco riporta ogni funzione di Lyrimuse: cosa fa, dove si trova nelle impostazioni e se è attiva o no dopo l’installazione; in fondo ci sono tutte le impostazioni della finestra Impostazioni. Viene mantenuto insieme al codice e aggiornato a ogni modifica.

## Indice

- [Disattivate finché non le attivi](#section-off-by-default)
- [Ricerca dei testi](#section-lyrics)
- [Traduzione, pronuncia e gestione delle righe](#section-text)
- [Dove compare il testo e che aspetto ha](#section-display)
- [Player e riproduzione](#section-players)
- [Scrobble, Last.fm e condivisione](#section-listening)
- [Uso quotidiano](#section-general)
- [Tutte le impostazioni](#section-all-settings)

<a id="section-off-by-default"></a>

## Disattivate finché non le attivi

Queste funzioni restano disattivate dopo l’installazione. Attivale prima nelle impostazioni (alcune richiedono anche un account o un’autorizzazione):

| Funzione | Dove attivarla |
|---|---|
| [I testi di Apple Music](#feature-apple-music-lyrics) | Impostazioni › Testo › Fonte › Fonti dei testi |
| [Usa i testi già salvati dal player](#feature-player-local-lyrics) | Impostazioni › Player › Permessi e servizi › Accesso completo al disco |
| [Preferisci il testo del file del brano](#feature-prefer-local-file-lyrics) | Impostazioni › Testo › Fonte › Preferisci il testo del file del brano |
| [Blocca testi scelti a mano](#feature-lock-hand-picked) | Impostazioni › Testo › Fonte › Blocca testi scelti a mano |
| [Traduci se manca](#feature-machine-translation) | Impostazioni › Testo › Lingua › Traduci se manca |
| [Dividi le righe lunghe, unisci quelle brevi](#feature-split-join-lines) | Impostazioni › Testo › Timing e a capo › Dividi righe lunghe |
| [Testo nel notch](#feature-notch-lyrics) | Impostazioni › Visualizzazione testo › Notch › Testo nel notch |
| [Testo nella barra dei menu](#feature-menu-bar-lyrics) | Impostazioni › Visualizzazione testo › Barra dei menu › Testo nella barra dei menu |
| [Testo sulla Touch Bar](#feature-touch-bar-lyrics) | Impostazioni › Visualizzazione testo › Touch Bar › Testo Touch Bar |
| [La Touch Bar si fa da parte mentre scrivi](#feature-touch-bar-collapse-while-typing) | Impostazioni › Visualizzazione testo › Touch Bar › Comportamento › Comprimi durante la digitazione |
| [Evidenziazione HDR nella finestra testo](#feature-lyrics-window-hdr) | Impostazioni › Visualizzazione testo › Finestra testo › Colore › Evidenziazione HDR |
| [La finestra Mini si nasconde in pausa o a tutto schermo](#feature-mini-window-auto-hide) | Impostazioni › Visualizzazione testo › Finestra testo › Comportamento › Nascondi in pausa |
| [Sfondo Spotify Canvas](#feature-spotify-canvas) | Impostazioni › Visualizzazione testo › Finestra testo › Sfondo › Spotify Canvas |
| [Transizione righe](#feature-line-transition) | Impostazioni › Visualizzazione testo › Testo fluttuante › Layout › Transizione righe |
| [Due righe alternate](#feature-alternate-next-line) | Impostazioni › Visualizzazione testo › Testo fluttuante › Contenuto › Disposizione riga successiva |
| [Sfuma al passaggio del mouse](#feature-fade-on-hover) | Impostazioni › Visualizzazione testo › Testo fluttuante › Comportamento › Sfuma al passaggio del mouse |
| [Blocca la posizione, tieni premuto per trascinare](#feature-lock-position) | Impostazioni › Visualizzazione testo › Testo fluttuante › Comportamento › Blocca posizione |
| [Nascosto negli screenshot e nella condivisione dello schermo](#feature-hide-in-screenshots) | Impostazioni › Visualizzazione testo › Testo fluttuante › Comportamento › Nascondi negli screenshot |
| [Nascondi o riduci in pausa](#feature-hide-when-paused) | Impostazioni › Visualizzazione testo › Testo fluttuante › Comportamento › Nascondi in pausa |
| [Nascondi se non c’è testo](#feature-hide-when-no-lyrics) | Impostazioni › Visualizzazione testo › Testo fluttuante › Comportamento › Nascondi se non c’è testo |
| [Si fa da parte durante la pubblicità](#feature-hide-during-ads) | Impostazioni › Visualizzazione testo › Testo fluttuante › Comportamento › Nascondi durante la pubblicità |
| [Notch sulla schermata di blocco](#feature-notch-show-on-lock-screen) | Impostazioni › Visualizzazione testo › Notch › Comportamento › Mostra in schermata di blocco |
| [Il testo fluttuante si fa da parte a tutto schermo](#feature-overlay-hide-in-full-screen) | Impostazioni › Visualizzazione testo › Testo fluttuante › Comportamento › Nascondi a tutto schermo |
| [Sfuma la riga del testo del notch al passaggio del mouse](#feature-notch-lyric-row-fade) | Impostazioni › Visualizzazione testo › Notch › Riga del testo › Sfuma al passaggio del mouse |
| [Testo web: un telefono o un tablet come secondo schermo, o una sorgente browser di OBS](#feature-web-lyrics) | Impostazioni › Visualizzazione testo › Finestra testo › Testo web |
| [YouTube Music e Spotify Web nel browser](#feature-web-players) | Impostazioni › Player › Web |
| [Salta automaticamente la pubblicità di YouTube Music](#feature-skip-youtube-ads) | Impostazioni › Player › Web › Salta pubblicità |
| [Apri e chiudi insieme al player](#feature-player-linkage) | Impostazioni › Player › Avvio e uscita › Apri player all’avvio |
| [Scrobble su Last.fm e profilo d’ascolto](#feature-lastfm) | Impostazioni › Last.fm › Regole › Regole scrobble |
| [Scrobble anche su ListenBrainz](#feature-listenbrainz) | Impostazioni › Lab › ListenBrainz › Info account |
| [Mostra su Discord cosa stai ascoltando](#feature-discord) | Impostazioni › Discord › Mostra su Discord |
| [Una pagina web “In riproduzione” da condividere](#feature-now-playing-page) | Impostazioni › Lab › Push web › Info connessione |
| [Riepiloghi di ascolto giornalieri, settimanali, mensili e annuali](#feature-digests) | Impostazioni › Avvisi push › Canali |
| [Avvio silenzioso](#feature-silent-launch) | Impostazioni › Generali › Avvio e notifiche › Avvio silenzioso |
| [Notifica al cambio brano](#feature-song-notifications) | Impostazioni › Generali › Avvio e notifiche › Notifica al cambio brano |
| [Aggiornamenti automatici e beta](#feature-updates) | Impostazioni › Aggiornamento software › Impostazioni aggiornamenti › Verifica automaticamente |

<a id="section-lyrics"></a>

## Ricerca dei testi

<a id="feature-lyric-sources"></a>

### 15 fonti dei testi, consultate automaticamente

NetEase Cloud Music, QQ Music, Kugou, Kuwo, Migu, Musixmatch, LRCLIB, LyricFind, Deezer, AMLL, Soda Music, VIBE, Genie, PetitLyrics e Apple Music. Ogni fonte si può disattivare, spostare nell’ordine o testare per vedere se è raggiungibile in questo momento.

- Attiva di default
- Impostazioni: Testo › Fonte › Fonti dei testi

<a id="feature-network-proxy"></a>

### Riprova le fonti estere tramite proxy

Quando una fonte dei testi estera non è raggiungibile direttamente, Lyrimuse riprova tramite il proxy di sistema o un proxy locale come Clash. Puoi anche inserire tu un server proxy, oppure disattivare l’opzione. Le fonti dei testi della Cina continentale si connettono sempre direttamente.

- Attiva di default
- Impostazioni: Generali › Rete › Proxy

<a id="feature-apple-music-lyrics"></a>

### I testi di Apple Music

Collega il tuo account Apple Music in “Fonti dei testi” per usare i testi di Apple Music, molti dei quali sincronizzati parola per parola. Richiede un abbonamento ad Apple Music.

- Disattivata di default
- Impostazioni: Testo › Fonte › Fonti dei testi

<a id="feature-matching"></a>

### Associazione intelligente

Per impostazione predefinita ogni risultato riceve un punteggio in base a titolo, artista, durata e versione (live, strumentale e così via), e vince quello più adatto al brano in riproduzione. In alternativa puoi seguire l’ordine delle fonti: nessun punteggio, si usa la prima fonte del tuo elenco che ha il testo.

- Impostazioni: Testo › Fonte › Algoritmo di associazione

<a id="feature-auto-upgrade"></a>

### Nuova scelta del testo quando l’associazione migliora

Quando una nuova versione migliora l’associazione o il punteggio, i testi che hai già vengono ricontrollati in background e sostituiti se si trova una versione migliore. Disattiva l’opzione per tenere i testi una volta scelti.

- Attiva di default
- Impostazioni: Testo › Fonte › Riscegli dopo aggiornamento algoritmo

<a id="feature-prefetch"></a>

### Testo pronto prima del brano successivo

Legge la coda del player e cerca in anticipo i testi dei prossimi brani; quando non c’è una coda da leggere, procede con il resto dell’album. Per questo QQ Music, NetEase Cloud Music, Kugou, Soda Music e VOX richiedono il permesso “Accesso completo al disco”.

- Attiva di default
- Impostazioni: Testo › Fonte › Prepara brani successivi
- Impostazioni: Player › Permessi e servizi › Accesso completo al disco

<a id="feature-player-local-lyrics"></a>

### Usa i testi già salvati dal player

I testi che Apple Music, Spotify, Kugou, KKBOX, Amazon Music e LX Music hanno già salvato su questo Mac si possono usare direttamente: la stessa versione mostrata dal player, e più in fretta (per Apple Music e Spotify, solo i brani di cui il player ha mostrato il testo). Per QQ Music e NetEase Cloud Music il brano viene riconosciuto dalla libreria locale del player, così si recupera proprio quella versione senza cercarla. Per reAMP, VOX, Pine Player, foobar2000, Swinsian e MyGo Music, e con Apple Music o LX Music quando riproducono un file locale della libreria o dell’elenco locale, si usa il testo contenuto nel file in riproduzione o in un file .lrc con lo stesso nome. QQ Music, NetEase Cloud Music e Kugou richiedono che Lyrimuse abbia “Accesso completo al disco” in Impostazioni di Sistema; senza, i testi vengono comunque trovati online.

- Disattivata di default
- Impostazioni: Player › Permessi e servizi › Accesso completo al disco

<a id="feature-prefer-local-file-lyrics"></a>

### Preferisci il testo del file del brano

Quando il brano in riproduzione è un file su questo Mac, il suo .lrc con lo stesso nome o il testo incorporato hanno la precedenza, invece di essere confrontati con i testi trovati online. Funziona con qualsiasi player che riproduce file locali. Se quel testo non corrisponde a questa versione (per esempio la durata non coincide), il testo viene cercato online come al solito.

- Disattivata di default
- Impostazioni: Testo › Fonte › Preferisci il testo del file del brano

<a id="feature-lock-hand-picked"></a>

### Blocca testi scelti a mano

Se attiva, i testi che scegli a mano dai risultati di ricerca vengono bloccati, così l’associazione automatica e le riassociazioni successive non li sostituiscono mai.

- Disattivata di default
- Impostazioni: Testo › Fonte › Blocca testi scelti a mano

<a id="feature-lyrics-manager"></a>

### Gestione testi

Sfoglia, modifica, elimina o cerca di nuovo il testo di qualsiasi brano, elimina in blocco e ripulisci le voci vuote lasciate da pubblicità e podcast. Assegna a un singolo brano un offset tutto suo. Riprova in un colpo solo tutti i brani ancora senza testo, o riassocia l’intera libreria con le regole attuali, con una pausa regolabile tra un brano e l’altro; tutto ciò che hai modificato a mano resta com’è.

- Impostazioni: Testo › Libreria testi › Libreria testi
- Impostazioni: Testo › Libreria testi › Associa testi mancanti
- Impostazioni: Testo › Libreria testi › Riassocia tutta la libreria
- Impostazioni: Scorciatoie da tastiera › Apri Gestione testi
- Impostazioni: Testo › Libreria testi › Intervallo di scansione

<a id="feature-song-entries"></a>

### Voci dello stesso brano

Lo stesso brano riprodotto in player diversi o da edizioni diverse viene riconosciuto come un unico brano: le sue voci condividono un solo testo, le modifiche manuali e le correzioni del timing vengono mantenute e gli ascolti si sommano. In Gestione testi, “Voci di questo brano” confronta riga per riga il testo di ogni voce, e una voce associata per errore si può separare e riunire in seguito. Disattiva la condivisione per associare ogni voce separatamente.

- Attiva di default
- Impostazioni: Testo › Fonte › Condividi testo tra voci dello stesso brano

<a id="feature-fix-lyrics"></a>

### Cambia o correggi il testo al volo

Dal menu ⋯ della finestra testo cerca un altro testo, ripeti l’associazione o modificalo nel tuo editor di testo. Modificare un testo parola per parola cambia solo le parole, mai il loro timing.

- Impostazioni: Scorciatoie da tastiera › Cerca testo

<a id="feature-import-lyrics"></a>

### Importa i testi dai tuoi file

Importa testi in LRC, Enhanced LRC, TTML, QRC, KRC, YRC o testo semplice per un brano, o un’intera cartella in una volta: i file vengono associati ai brani della tua libreria e mostrati in anteprima prima di scrivere qualsiasi cosa. Scegli se i testi importati sostituiscono quelli attuali, li sostituiscono bloccandoli o completano solo i brani senza testo. I file dei brani che non hai ancora ascoltato vengono conservati e usati alla loro prima riproduzione. Una cartella monitorata importa automaticamente i nuovi file.

- Impostazioni: Testo › Libreria testi › Importa cartella testi
- Impostazioni: Testo › Libreria testi › Importazione cartelle
- Impostazioni: Testo › Libreria testi › Cartella monitorata
- Impostazioni: Testo › Libreria testi › Libreria importazioni

<a id="feature-offline"></a>

### Funziona offline; i testi sono semplici file .lrc

Ogni testo trovato viene salvato nella cache del Mac e si vede anche senza connessione. Ogni brano ha un file .lrc, più .tr.lrc e .roma.lrc per traduzione e pronuncia. Il timing parola per parola viene salvato in TTML per impostazione predefinita, oppure in .yrc, Enhanced LRC, QRC o KRC. Per impostazione predefinita i file si trovano in ~/Library/Application Support/me.yudaotor.lyrimuse/lyrics/, e la cartella si può spostare.

- Impostazioni: Testo › Libreria testi › Cartella testi
- Impostazioni: Testo › Libreria testi › Formato testo parola per parola

<a id="section-text"></a>

## Traduzione, pronuncia e gestione delle righe

<a id="feature-translation"></a>

### Traduzioni

Le traduzioni che accompagnano il testo compaiono sotto ogni riga. NetEase Cloud Music, QQ Music e Kugou traducono in cinese; Musixmatch e la traduzione automatica seguono la lingua di traduzione che scegli, tra 17. Testo fluttuante, finestra testo, notch, barra dei menu e Touch Bar decidono ciascuno se mostrarle. Visibili per impostazione predefinita quando tra le lingue del Mac c’è il cinese.

- Impostazioni: Testo › Lingua › Lingua di traduzione
- Impostazioni: Visualizzazione testo › Testo fluttuante › Contenuto › Traduzione
- Impostazioni: Scorciatoie da tastiera › Mostra/nascondi traduzione

<a id="feature-machine-translation"></a>

### Traduci se manca

Quando nessuna fonte ha una traduzione, il testo viene tradotto automaticamente. Su macOS 15 o versioni successive, con la lingua scaricata, se ne occupa la traduzione integrata di Apple direttamente sul Mac e il testo non esce dal computer; altrimenti le righe da tradurre vengono inviate a Google Traduttore e poi a MyMemory. Le lingue di traduzione si scaricano dalla stessa scheda.

- Disattivata di default
- Impostazioni: Testo › Lingua › Traduci se manca
- Impostazioni: Testo › Lingua › Lingue per la traduzione

<a id="feature-romanization"></a>

### Pronuncia

Romaji giapponese, romanizzazione del coreano, pinyin del mandarino e jyutping cantonese, parola per parola sopra il testo, più altre diciotto lingue come russo, thailandese, greco e hindi, secondo il sistema ufficiale di ciascuna lingua o uno standard ISO. La lingua viene riconosciuta riga per riga, così in un brano cinese viene annotata solo la riga in giapponese. Scegli qui quali lingue annotare; con l’interfaccia in cinese il pinyin parte disattivato. Ogni visualizzazione decide se mostrarla.

- Attiva di default
- Impostazioni: Testo › Lingua › Lingue con pronuncia
- Impostazioni: Testo › Lingua › Pronuncia giapponese
- Impostazioni: Visualizzazione testo › Testo fluttuante › Contenuto › Pronuncia
- Impostazioni: Scorciatoie da tastiera › Mostra/nascondi pronuncia

<a id="feature-chinese-script"></a>

### Cinese semplificato o tradizionale

Mostra tutti i testi in cinese con caratteri semplificati o tradizionali, qualunque sia la lingua dell’app.

- Impostazioni: Testo › Lingua › Scrittura cinese

<a id="feature-split-join-lines"></a>

### Dividi le righe lunghe, unisci quelle brevi

Testo fluttuante, notch, barra dei menu e Touch Bar dividono le righe troppo lunghe per la loro larghezza e uniscono quelle che passano troppo in fretta, ciascuno in base alla propria larghezza. Nella finestra testo ogni riga resta com’è. Due opzioni separate.

- Disattivata di default
- Impostazioni: Testo › Timing e a capo › Dividi righe lunghe
- Impostazioni: Testo › Timing e a capo › Unisci righe brevi

<a id="feature-timing-offset"></a>

### Offset del timing

Anticipa o ritarda tutti i testi, anche solo per un player. I singoli brani hanno un offset tutto loro in Gestione testi, e con le scorciatoie puoi anticiparlo, ritardarlo o azzerarlo al volo.

- Impostazioni: Testo › Timing e a capo › Offset del timing
- Impostazioni: Scorciatoie da tastiera › Anticipa testo
- Impostazioni: Scorciatoie da tastiera › Ritarda testo
- Impostazioni: Scorciatoie da tastiera › Azzera offset testo

<a id="section-display"></a>

## Dove compare il testo e che aspetto ha

<a id="feature-floating-lyrics"></a>

### Testo fluttuante

Testo che fluttua sopra tutte le finestre, sempre in primo piano, e si illumina parola per parola. Lascialo dove lo trascini, oppure fissalo in alto al centro dello schermo o appena sopra il Dock. Con più schermi può restare su uno solo o seguire lo schermo della finestra che stai usando. Pronuncia, traduzione e riga successiva possono comparire insieme.

- Attiva di default
- Impostazioni: Visualizzazione testo › Testo fluttuante › Testo fluttuante
- Impostazioni: Visualizzazione testo › Testo fluttuante › Posizione
- Impostazioni: Visualizzazione testo › Testo fluttuante › Contenuto › Riga successiva
- Impostazioni: Scorciatoie da tastiera › Mostra/nascondi testo fluttuante
- Impostazioni: Visualizzazione testo › Testo fluttuante › Posizione › Mostra su

<a id="feature-notch-lyrics"></a>

### Testo nel notch

Una capsula in stile Dynamic Island accanto al notch, in alto sullo schermo; ce l’hanno anche i Mac senza notch e gli schermi esterni. Ogni lato può mostrare titolo, artista, album, illustrazione, controlli di riproduzione, o tempo trascorso o rimanente, accanto a un’onda audio animata. Passaci sopra con il puntatore per espanderla e avere i controlli, una barra di avanzamento su cui spostarti, il timing del testo e pulsanti rapidi come Preferito e Cerca testo. Durante la pubblicità mostra il conto alla rovescia del tempo rimanente.

- Disattivata di default
- Impostazioni: Visualizzazione testo › Notch › Testo nel notch
- Impostazioni: Visualizzazione testo › Notch › Stile
- Impostazioni: Visualizzazione testo › Notch › Schermo
- Impostazioni: Visualizzazione testo › Notch › Sinistra
- Impostazioni: Scorciatoie da tastiera › Mostra/nascondi testo nel notch
- Impostazioni: Scorciatoie da tastiera › Espandi il notch per un attimo
- Impostazioni: Visualizzazione testo › Notch › Espanso › Azioni rapide

<a id="feature-menu-bar-lyrics"></a>

### Testo nella barra dei menu

La riga attuale direttamente nella barra dei menu, che scorre quando è troppo lunga invece di essere tagliata. Aggiungi una seconda riga per la riga successiva, la traduzione o la pronuncia. Può anche stare al centro della barra dei menu, proprio accanto al notch sugli schermi che ce l’hanno, oppure mostrare solo il titolo, con o senza l’artista.

- Disattivata di default
- Impostazioni: Visualizzazione testo › Barra dei menu › Testo nella barra dei menu
- Impostazioni: Visualizzazione testo › Barra dei menu › Layout › Posizione
- Impostazioni: Visualizzazione testo › Barra dei menu › Contenuto › Contenuto mostrato
- Impostazioni: Visualizzazione testo › Barra dei menu › Contenuto › Seconda riga
- Impostazioni: Scorciatoie da tastiera › Alterna testo nella barra dei menu

<a id="feature-touch-bar-lyrics"></a>

### Testo sulla Touch Bar

Su un MacBook Pro con Touch Bar, la riga attuale scorre mentre viene cantata, con illustrazione e controlli di riproduzione facoltativi. Il testo può essere bianco, seguire l’illustrazione, usare un colore a tua scelta o scorrere come un arcobaleno, con luminosità regolabile per la parte non ancora cantata. Può espandersi quando parte la riproduzione e ritirarsi in pausa, e un pulsante “Altro” mostra timing, Preferito, Casuale e Ripeti, volume e un cursore di avanzamento.

- Disattivata di default
- Impostazioni: Visualizzazione testo › Touch Bar › Testo Touch Bar
- Impostazioni: Scorciatoie da tastiera › Espandi/Contrai testo Touch Bar
- Impostazioni: Visualizzazione testo › Touch Bar › Colore › Colore testo
- Impostazioni: Visualizzazione testo › Touch Bar › Comportamento › Espandi all’avvio della riproduzione
- Impostazioni: Visualizzazione testo › Touch Bar › Layout › Mostra pulsante “Altro”

<a id="feature-touch-bar-collapse-while-typing"></a>

### La Touch Bar si fa da parte mentre scrivi

Mentre il cursore è in un campo di testo, il testo sulla Touch Bar può comprimersi per mostrare i candidati del metodo di input e i suggerimenti, e riespandersi all’uscita dal campo. Richiede il permesso “Accessibilità”.

- Disattivata di default
- Impostazioni: Visualizzazione testo › Touch Bar › Comportamento › Comprimi durante la digitazione

<a id="feature-lyrics-window"></a>

### Finestra testo

Testo a tutta pagina ispirato alla vista del testo di Apple Music: illustrazione sfocata sullo sfondo, l’intero brano che scorre fino alla riga attuale, duetti divisi per cantante, cori su una riga a parte, note tenute che si gonfiano e brillano. Lo sfondo può seguire l’illustrazione o essere uniforme, a gradiente o smerigliato, e puoi cambiare spessore del testo, colore cantato e allineamento. Aprila dall’icona nella barra dei menu o con una scorciatoia.

- Impostazioni: Visualizzazione testo › Finestra testo › Finestra testo
- Impostazioni: Visualizzazione testo › Finestra testo › Sfondo › Sfondo
- Impostazioni: Scorciatoie da tastiera › Apri finestra testo
- Impostazioni: Visualizzazione testo › Finestra testo › Layout › Allineamento
- Impostazioni: Visualizzazione testo › Finestra testo › Layout › Dimensioni dei controlli

<a id="feature-lyrics-window-hdr"></a>

### Evidenziazione HDR nella finestra testo

Su uno schermo HDR, la parte cantata della riga attuale nella finestra testo diventa più luminosa del bianco normale. Disattivata per impostazione predefinita, consuma più energia quando è attiva. Solo nella dimensione Completa.

- Disattivata di default
- Impostazioni: Visualizzazione testo › Finestra testo › Colore › Evidenziazione HDR

<a id="feature-mini-lyrics-window"></a>

### Finestra testo Mini

La finestra testo ridotta a una piccola scheda: solo la riga attuale, la riga attuale e la successiva, oppure un’intera pagina che scorre. Sfondo, colore del testo, font, spessore, colore cantato e titolo, illustrazione e tempo in alto si impostano tutti separatamente.

- Impostazioni: Visualizzazione testo › Finestra testo › Layout › Layout testo
- Impostazioni: Scorciatoie da tastiera › Alterna dimensione Mini/Completa

<a id="feature-mini-window-auto-hide"></a>

### La finestra Mini si nasconde in pausa o a tutto schermo

La finestra Mini può sparire in pausa o quando non c’è riproduzione e tornare quando la riproduzione riparte, e farsi da parte quando un’app è a tutto schermo sul suo schermo (un video, un gioco). Ciascuna è un’opzione separata.

- Disattivata di default
- Impostazioni: Visualizzazione testo › Finestra testo › Comportamento › Nascondi in pausa
- Impostazioni: Visualizzazione testo › Finestra testo › Comportamento › Nascondi a tutto schermo

<a id="feature-animated-artwork"></a>

### Illustrazione animata

Gli album con illustrazione animata su Apple Music, QQ Music o NetEase Cloud Music si animano anche nella finestra testo in dimensione Completa, così come gli album di cui Kugou Music ha salvato l’illustrazione animata quando li hai ascoltati lì. Va in pausa con Risparmio energetico o con “Riduci movimento” attivo. Puoi vedere quanto spazio occupano le animazioni scaricate ed eliminarle.

- Attiva di default
- Impostazioni: Visualizzazione testo › Finestra testo › Illustrazione › Illustrazione animata
- Impostazioni: Visualizzazione testo › Finestra testo › Illustrazione › Cache illustrazioni animate

<a id="feature-spotify-canvas"></a>

### Sfondo Spotify Canvas

Quando un brano ha un video Canvas in loop su Spotify, la finestra testo in dimensione Completa lo riproduce come sfondo al posto dell’illustrazione sfocata. Si usano solo i video che Spotify ha già salvato su questo Mac, quindi ne hanno uno i brani che hai ascoltato in Spotify, anche quando li riproduci in un altro player. Va in pausa con Risparmio energetico o con “Riduci movimento” attivo.

- Disattivata di default
- Impostazioni: Visualizzazione testo › Finestra testo › Sfondo › Spotify Canvas

<a id="feature-idle-overview"></a>

### Panoramica degli ascolti tra un brano e l’altro

Quando non c’è niente in riproduzione, la finestra testo mostra l’ultimo brano con una riga del suo testo e un pulsante “Riprendi”. Con Last.fm collegato mostra anche quanto hai ascoltato oggi, negli ultimi 7 giorni e in totale, l’andamento degli ultimi 30 giorni, “Accadde oggi” e i tuoi ascolti recenti con le illustrazioni.

<a id="feature-look"></a>

### Aspetto

Font (quello di sistema o un tuo .ttf / .otf), dimensione, spessore, colori del testo e dello sfondo, contorno ed effetto smerigliato. Il testo fluttuante ha dei temi di colore e può salvare i tuoi; il colore del testo può seguire l’illustrazione dell’album, e testo fluttuante, notch, barra dei menu e Touch Bar possono anche scorrere come un arcobaleno. Con le scorciatoie, o scorrendo sul testo tenendo premuto ⌘ (rotella del mouse o scorrimento con due dita), puoi anche ingrandire o rimpicciolire al volo il testo fluttuante.

- Impostazioni: Visualizzazione testo › Testo fluttuante › Tema
- Impostazioni: Visualizzazione testo › Testo fluttuante › Tema › I miei temi
- Impostazioni: Visualizzazione testo › Notch › Riga del testo › Colore testo
- Impostazioni: Visualizzazione testo › Barra dei menu › Colore › Arcobaleno
- Impostazioni: Visualizzazione testo › Testo fluttuante › Font › Font
- Impostazioni: Visualizzazione testo › Testo fluttuante › Colore › Sfondo smerigliato
- Impostazioni: Scorciatoie da tastiera › Ingrandisci testo fluttuante
- Impostazioni: Scorciatoie da tastiera › Rimpicciolisci testo fluttuante

<a id="feature-karaoke"></a>

### Effetto karaoke parola per parola

Ogni parola si illumina mentre viene cantata. Testo fluttuante, notch, barra dei menu, Touch Bar ed entrambe le dimensioni della finestra testo hanno ciascuno la propria opzione; se è disattivata, l’intera riga si illumina in una volta.

- Attiva di default
- Impostazioni: Visualizzazione testo › Testo fluttuante › Colore › Effetto karaoke
- Impostazioni: Visualizzazione testo › Notch › Riga del testo › Effetto karaoke
- Impostazioni: Visualizzazione testo › Barra dei menu › Colore › Effetto karaoke
- Impostazioni: Visualizzazione testo › Touch Bar › Colore › Effetto karaoke
- Impostazioni: Visualizzazione testo › Finestra testo › Colore › Effetto karaoke

<a id="feature-line-transition"></a>

### Transizione righe

Quando il testo fluttuante passa alla riga successiva, la vecchia riga scorre verso l’alto e la nuova la segue, invece di sostituirla sul posto.

- Disattivata di default
- Impostazioni: Visualizzazione testo › Testo fluttuante › Layout › Transizione righe

<a id="feature-alternate-next-line"></a>

### Due righe alternate

Il testo fluttuante può mostrare anche la riga successiva a grandezza piena, una a sinistra e una a destra, a turno come il classico karaoke da desktop: la riga appena cantata viene sostituita da quella dopo la successiva e quella in corso resta ferma.

- Disattivata di default
- Impostazioni: Visualizzazione testo › Testo fluttuante › Contenuto › Disposizione riga successiva

<a id="feature-fade-on-hover"></a>

### Sfuma al passaggio del mouse

Il testo fluttuante diventa trasparente quando ci passi sopra con il puntatore, così non copre mai ciò che c’è sotto. La finestra testo Mini ha una sua opzione e, mentre è sfumata, può anche lasciar passare i clic alla finestra sottostante; tieni premuto ⌥ per usare la finestra Mini.

- Disattivata di default
- Impostazioni: Visualizzazione testo › Testo fluttuante › Comportamento › Sfuma al passaggio del mouse
- Impostazioni: Visualizzazione testo › Finestra testo › Comportamento › Sfuma al passaggio del mouse
- Impostazioni: Visualizzazione testo › Finestra testo › Comportamento › Clic passante se sfumato

<a id="feature-lock-position"></a>

### Blocca la posizione, tieni premuto per trascinare

Blocca il testo fluttuante dov’è, o richiedi una pressione prolungata prima di trascinarlo, così non si sposta mai per errore.

- Disattivata di default
- Impostazioni: Visualizzazione testo › Testo fluttuante › Comportamento › Blocca posizione
- Impostazioni: Visualizzazione testo › Testo fluttuante › Comportamento › Tieni premuto per trascinare
- Impostazioni: Scorciatoie da tastiera › Blocca/sblocca posizione

<a id="feature-hover-controls"></a>

### Controlli al passaggio del mouse

Quando punti il testo fluttuante compare una fila di pulsanti rapidi. Anche il testo nella barra dei menu può mostrare i controlli di riproduzione al passaggio del mouse.

- Attiva di default
- Impostazioni: Visualizzazione testo › Testo fluttuante › Comportamento › Mostra controlli al passaggio
- Impostazioni: Visualizzazione testo › Barra dei menu › Comportamento › Mostra controlli al passaggio

<a id="feature-hide-in-screenshots"></a>

### Nascosto negli screenshot e nella condivisione dello schermo

Screenshot, registrazioni e schermi condivisi non includono il testo, mentre tu continui a vederlo. Testo fluttuante e notch hanno ciascuno un’opzione.

- Disattivata di default
- Impostazioni: Visualizzazione testo › Testo fluttuante › Comportamento › Nascondi negli screenshot
- Impostazioni: Visualizzazione testo › Notch › Comportamento › Nascondi negli screenshot

<a id="feature-hide-when-paused"></a>

### Nascondi o riduci in pausa

Testo fluttuante e notch spariscono in pausa o quando non c’è riproduzione; il notch può invece ridursi alle dimensioni del notch fisico.

- Disattivata di default
- Impostazioni: Visualizzazione testo › Testo fluttuante › Comportamento › Nascondi in pausa
- Impostazioni: Visualizzazione testo › Notch › Comportamento › Nascondi in pausa
- Impostazioni: Visualizzazione testo › Notch › Comportamento › Comprimi in pausa

<a id="feature-hide-when-no-lyrics"></a>

### Nascondi se non c’è testo

Quando un brano è strumentale, o la ricerca è finita senza trovare un testo, il testo fluttuante e la finestra testo Mini possono nascondersi, e notch e Touch Bar possono comprimere la loro riga del testo. Niente si nasconde mentre la ricerca è ancora in corso. Ciascuno ha la propria opzione.

- Disattivata di default
- Impostazioni: Visualizzazione testo › Testo fluttuante › Comportamento › Nascondi se non c’è testo
- Impostazioni: Visualizzazione testo › Finestra testo › Comportamento › Nascondi se non c’è testo
- Impostazioni: Visualizzazione testo › Notch › Comportamento › Comprimi riga se non c’è testo
- Impostazioni: Visualizzazione testo › Touch Bar › Comportamento › Comprimi per strumentali e senza testo

<a id="feature-hide-during-ads"></a>

### Si fa da parte durante la pubblicità

Mentre il player riproduce una pubblicità, il testo fluttuante può nascondersi e il notch può ridursi alla striscia superiore; passandoci sopra con il puntatore il notch si espande comunque. Ciascuno ha la propria opzione.

- Disattivata di default
- Impostazioni: Visualizzazione testo › Testo fluttuante › Comportamento › Nascondi durante la pubblicità
- Impostazioni: Visualizzazione testo › Notch › Comportamento › Comprimi durante la pubblicità

<a id="feature-hide-in-full-screen"></a>

### Il notch si fa da parte a tutto schermo

Il testo nel notch si ritira mentre un video, un gioco o qualsiasi app è a tutto schermo.

- Attiva di default
- Impostazioni: Visualizzazione testo › Notch › Comportamento › Nascondi a tutto schermo

<a id="feature-notch-show-on-lock-screen"></a>

### Notch sulla schermata di blocco

Il notch continua a mostrare il brano in riproduzione e il suo testo sulla schermata di blocco.

- Disattivata di default
- Impostazioni: Visualizzazione testo › Notch › Comportamento › Mostra in schermata di blocco

<a id="feature-overlay-hide-in-full-screen"></a>

### Il testo fluttuante si fa da parte a tutto schermo

Normalmente il testo fluttuante resta sopra le app a tutto schermo. Attiva questa opzione per nasconderlo mentre un video, un gioco o qualsiasi app è a tutto schermo; ricompare quando esci dal tutto schermo.

- Disattivata di default
- Impostazioni: Visualizzazione testo › Testo fluttuante › Comportamento › Nascondi a tutto schermo

<a id="feature-title-on-change"></a>

### Titolo al cambio brano

Il titolo e l’artista di ogni nuovo brano escono per un attimo dal notch, poi rientrano.

- Attiva di default
- Impostazioni: Visualizzazione testo › Notch › Comportamento › Titolo al cambio brano

<a id="feature-listening-milestones"></a>

### Traguardi di ascolto

Quando un brano raggiunge il 100°, il 1.000° o il 10.000° ascolto, o il tuo totale su Last.fm supera un traguardo, il notch si apre per festeggiare. Richiede Last.fm collegato.

- Attiva di default
- Impostazioni: Visualizzazione testo › Notch › Comportamento › Traguardi di ascolto

<a id="feature-notch-gestures"></a>

### Gesti trackpad sul notch

Con il puntatore sul notch, scorri a sinistra o a destra con due dita per cambiare brano, o in alto e in basso per regolare il volume di sistema.

- Attiva di default
- Impostazioni: Visualizzazione testo › Notch › Comportamento › Gesti trackpad
- Impostazioni: Visualizzazione testo › Notch › Comportamento › Mostra con tasti volume

<a id="feature-notch-lyric-row-fade"></a>

### Sfuma la riga del testo del notch al passaggio del mouse

Con il puntatore sulla riga del testo del notch, la riga si attenua invece di espandersi e i clic passano alla finestra sottostante; il notch si espande solo dal notch stesso o dai suoi lati.

- Disattivata di default
- Impostazioni: Visualizzazione testo › Notch › Riga del testo › Sfuma al passaggio del mouse

<a id="feature-notch-multiline-lyrics"></a>

### Testo su più righe nel notch espanso

Quando il notch si espande sotto il puntatore, l’area del testo diventa un elenco di 3, 5 o 7 righe, con la riga attuale che si illumina parola per parola e l’elenco che scorre verso l’alto a ogni nuova riga; fai clic su una riga per saltarci. Se la riga del testo è disattivata, il notch resta una sottile striscia di stato e mostra il testo solo quando è espanso.

- Attiva di default
- Impostazioni: Visualizzazione testo › Notch › Espanso › Testo su più righe
- Impostazioni: Visualizzazione testo › Notch › Espanso › Righe

<a id="feature-web-lyrics"></a>

### Testo web: un telefono o un tablet come secondo schermo, o una sorgente browser di OBS

Il testo in un browser web. “Testo web” mostra esattamente ciò che mostra la finestra testo; “Uscita OBS” ha uno sfondo trasparente e gli stessi font e colori del testo fluttuante, più una scheda del titolo (titolo, artista e illustrazione) nell’angolo in alto a sinistra che può comparire sempre, al cambio brano o mai. Ciascuno ha la propria porta e la propria impostazione di rete locale. Entrambi sono disponibili solo su questo Mac finché non attivi “Consenti accesso dalla rete locale”; a quel punto i dispositivi della stessa rete possono scansionare un codice QR per connettersi, tramite un link con una chiave di accesso. Con “Consenti controllo remoto” attivo, la pagina può anche controllare la riproduzione e saltare a una riga.

- Disattivata di default
- Impostazioni: Visualizzazione testo › Finestra testo › Testo web
- Impostazioni: Visualizzazione testo › Finestra testo › Testo web › Consenti accesso dalla rete locale
- Impostazioni: Visualizzazione testo › Testo fluttuante › OBS › Uscita OBS
- Impostazioni: Visualizzazione testo › Testo fluttuante › OBS › Scheda titolo
- Impostazioni: Visualizzazione testo › Finestra testo › Testo web › Consenti controllo remoto

<a id="section-players"></a>

## Player e riproduzione

<a id="feature-players"></a>

### Diciannove player, scegline più di uno o rilevali automaticamente

Apple Music, Spotify, QQ Music, NetEase Cloud Music, Kugou, Soda Music, LX Music, KKBOX, Amazon Music, reAMP in stile Winamp, VOX, player locale lossless e hi-res, Pine Player, player locale gratuito che riproduce quasi ogni formato, foobar2000, il classico player locale arrivato da Windows, Swinsian, player locale pensato per librerie di grandi dimensioni, Plexamp, il lettore musicale di Plex per il proprio server, MyGo Music, player open source che riproduce file locali e aggiunge altre fonti tramite plugin, Kaset, l’app di YouTube Music, Pear Desktop, un’app desktop open source per YouTube Music, e WeRead per gli audiolibri. Scegline più di uno insieme, o lascia il rilevamento automatico per seguire ciò che macOS mostra come “In riproduzione”. Funziona anche la radio di Apple Music, con nome e logo della stazione mentre parla il conduttore.

- Impostazioni: Player › App musicali

<a id="feature-web-players"></a>

### YouTube Music e Spotify Web nel browser

Abbina il browser una volta e anche la musica riprodotta lì avrà il testo, seguendo l’avanzamento della pagina stessa. Una verifica con un clic ti dice prima se quel browser può essere controllato. Durante la pubblicità il notch mostra il tempo rimanente e di quale pubblicità si tratta.

- Disattivata di default
- Impostazioni: Player › Web

<a id="feature-skip-youtube-ads"></a>

### Salta automaticamente la pubblicità di YouTube Music

Su YouTube Music nel browser o in Pear Desktop la pubblicità viene saltata appena compare il pulsante “Salta”. Con l’opzione disattivata puoi comunque saltarla tu dal notch. Richiede il permesso “Accessibilità”.

- Disattivata di default
- Impostazioni: Player › Web › Salta pubblicità
- Impostazioni: Player › Permessi e servizi › Accessibilità

<a id="feature-other-players"></a>

### Aggiungi altri player

I player che non sono in elenco si possono aggiungere ai tuoi player affidabili dalla cartella Applicazioni, e Lyrimuse te lo chiede quando nota un player sconosciuto che riproduce musica.

- Impostazioni: Player › Altre app
- Impostazioni: Player › Aggiungi app…
- Impostazioni: Player › Avvisi nuovi player

<a id="feature-permissions"></a>

### Permessi, solo dove servono

Apple Music, Spotify, Kaset, VOX e Swinsian richiedono il permesso “Automazione” per leggere cosa è in riproduzione. QQ Music, NetEase Cloud Music e Kugou richiedono “Accesso completo al disco” per i testi salvati e le code, Soda Music e VOX per le code. La calibrazione dell’avanzamento per Amazon Music e Pine Player, la playlist di Pine Player, i pulsanti Casuale, Ripeti e Preferito di QQ Music, NetEase Cloud Music, Kugou Music, Soda Music, Amazon Music, reAMP, Pine Player e foobar2000, il volume di foobar2000 e i pulsanti di riproduzione di QQ Music, NetEase Cloud Music, Soda Music, Pine Player, foobar2000 e MyGo Music quando un’altra app occupa “In riproduzione” richiedono “Accessibilità”. I player web richiedono “Automazione” per il browser e la sua opzione “Consenti JavaScript da Apple Events”. Gli altri player non richiedono nulla. In Impostazioni vedi lo stato attuale di ciascuno.

- Impostazioni: Player › Permessi e servizi › Permesso Automazione
- Impostazioni: Player › Permessi e servizi › Accesso completo al disco
- Impostazioni: Player › Permessi e servizi › Accessibilità

<a id="feature-controls"></a>

### Controlli di riproduzione e spostamento nel brano

Riproduci, metti in pausa, passa a un altro brano e trascina la barra di avanzamento dalla finestra testo o dal notch espanso. Casuale, Ripeti, Preferito e volume dipendono dal player: Apple Music, Spotify, Kaset, QQ Music, Amazon Music, reAMP, VOX, Pine Player, foobar2000, Swinsian, Plexamp, Pear Desktop e YouTube Music nel browser ne supportano alcuni o tutti, mentre NetEase Cloud Music, Kugou Music, Soda Music, LX Music e MyGo Music hanno Preferito, e LX Music anche il volume dopo aver attivato Open API nelle sue impostazioni. Riproduzione, pausa, cambio brano e Preferito possono avere scorciatoie globali. Quando qualcosa come un video nel browser occupa “In riproduzione”, riproduzione, pausa e cambio brano per QQ Music, NetEase Cloud Music, Soda Music, Pine Player, foobar2000 e MyGo Music passano dai loro menu o dalla loro barra di riproduzione, e non è possibile spostarsi nel brano.

- Impostazioni: Visualizzazione testo › Notch › Espanso › Mostra controlli
- Impostazioni: Scorciatoie da tastiera › Riproduci/Pausa
- Impostazioni: Scorciatoie da tastiera › Brano successivo
- Impostazioni: Scorciatoie da tastiera › Brano precedente
- Impostazioni: Scorciatoie da tastiera › Aggiungi/rimuovi dai preferiti
- Impostazioni: Player › Permessi e servizi › Open API di LX Music

<a id="feature-song-pages"></a>

### Apri la pagina del brano con un clic

Un clic nel menu ⋯ apre il brano, il suo album o il suo artista sulla piattaforma da cui stai ascoltando. Apple Music e KKBOX si aprono nelle rispettive app e Spotify va al brano nella sua app; il resto si apre sul web: album e artisti di Spotify, QQ Music, Soda Music, Amazon Music e YouTube Music. NetEase Cloud Music e Kugou hanno solo la pagina del brano.

<a id="feature-about-panels"></a>

### Note su brano, album e artista

Fai clic su titolo, artista o album nella finestra testo o nel notch espanso per saperne di più. Le note dell’album e dell’artista arrivano prima da Apple Music; in mancanza, da Soda Music, Kugou Music e NetEase Cloud Music (solo con l’interfaccia in cinese), poi da Wikipedia tramite YouTube Music, infine da Last.fm. Le note del brano arrivano da QQ Music (solo con l’interfaccia in cinese) o da Last.fm. Last.fm richiede il tuo account collegato.

<a id="feature-player-linkage"></a>

### Apri e chiudi insieme al player

Per ogni player: apri il player all’apertura di Lyrimuse, apri Lyrimuse all’apertura del player, o esci da Lyrimuse quando tutti i player che segue sono stati chiusi.

- Disattivata di default
- Impostazioni: Player › Avvio e uscita › Apri player all’avvio
- Impostazioni: Player › Avvio e uscita › Apri con il player
- Impostazioni: Player › Avvio e uscita › Esci con il player

<a id="section-listening"></a>

## Scrobble, Last.fm e condivisione

<a id="feature-lastfm"></a>

### Scrobble su Last.fm e profilo d’ascolto

Collega Last.fm con un clic, senza token da copiare. Guarda gli ascolti di oggi, di questa settimana e di sempre, le classifiche di artisti, album e brani con le variazioni di posizione, e “Impronta”: una mappa di calore dell’anno in cui, facendo clic su un giorno, vedi i brani più ascoltati, le ore di ascolto, la provenienza dei tuoi artisti e “Accadde oggi”. Metti Mi piace a qualsiasi brano recente con un clic.

- Disattivata di default
- Impostazioni: Last.fm › Regole › Regole scrobble

<a id="feature-scrobble-rules"></a>

### Regole di scrobble personalizzate

Conta un ascolto al 50%, al 75%, al 90% o solo alla fine; decidi cosa fare con i brani sotto i 30 secondi; per impostazione predefinita artisti ospiti, varianti di scrittura del cinese e suffissi come “- Single” vengono ricondotti alla voce del catalogo di Last.fm, oppure invia tutto così com’è; escludi del tutto qualsiasi player da Last.fm.

- Impostazioni: Last.fm › Regole › Momento scrobble
- Impostazioni: Last.fm › Regole › Scrobble dei brani sotto i 30 secondi
- Impostazioni: Last.fm › Regole › Modalità di associazione
- Impostazioni: Last.fm › Regole › Player da scrobblare

<a id="feature-local-log"></a>

### Ogni ascolto viene prima registrato in locale

Gli ascolti fatti mentre Last.fm non è collegato vengono registrati sul Mac; una volta collegato, fai clic su “Recupera” sotto “Scrobble in sospeso” nella pagina Last.fm. Un ascolto che potrebbe non essere arrivato a Last.fm mentre l’account era collegato viene verificato con Last.fm e reinviato automaticamente. Last.fm accetta solo gli ascolti delle ultime due settimane circa.

<a id="feature-listenbrainz"></a>

### Scrobble anche su ListenBrainz

Ogni ascolto va a Last.fm e a ListenBrainz a partire dalla stessa lettura, così i due coincidono. Anche gli ascolti che il tuo iPhone invia a Last.fm si possono copiare in ListenBrainz. In “Lab” nella barra laterale.

- Disattivata di default
- Impostazioni: Lab › ListenBrainz › Info account

<a id="feature-discord"></a>

### Mostra su Discord cosa stai ascoltando

Il tuo profilo e l’elenco degli amici mostrano player, titolo, artista, illustrazione e una barra di avanzamento; facendo clic sul titolo o sull’artista si apre la pagina web del player. La riga dell’album può mostrare la riga che si sta cantando, e si possono aggiungere fino a due pulsanti. Scegli come disporre il testo, quali player contano, se lo stato resta visibile in pausa e quale badge compare sull’illustrazione, mostra solo il player senza indicare il brano, o nascondilo per un po’.

- Disattivata di default
- Impostazioni: Discord › Mostra su Discord
- Impostazioni: Discord › Player mostrati
- Impostazioni: Discord › Alla pausa
- Impostazioni: Discord › Nascondi temporaneamente
- Impostazioni: Discord › Contenuto mostrato
- Impostazioni: Discord › Pulsanti
- Impostazioni: Discord › Nascondi dettagli brano

<a id="feature-now-playing-page"></a>

### Una pagina web “In riproduzione” da condividere

Una pagina pubblica con ciò che stai ascoltando e la tua cronologia, con libro degli ospiti, reazioni, contatore delle visite, i tuoi 10 artisti più ascoltati e un look da vinile, tutti facoltativi. Il solo ListenBrainz basta per riproduzione in diretta e cronologia; per il resto, distribuisci un Cloudflare Worker seguendo la guida. In “Lab”.

- Disattivata di default
- Impostazioni: Lab › Push web › Info connessione

<a id="feature-digests"></a>

### Riepiloghi di ascolto giornalieri, settimanali, mensili e annuali

Inviati ai canali che configuri, quanti ne vuoi: Bark, ntfy, ServerChan, Feishu, DingTalk, WeCom, Telegram, Discord, Slack o un webhook generico. Ogni canale può mostrare l’anteprima di un invio e mandare un test, e la cronologia degli invii mostra se ogni push è arrivato, con la possibilità di reinviare quelli non arrivati. I report si confrontano con il periodo precedente, indicano gli artisti ascoltati per la prima volta e stimano quanto hai ascoltato, formattati per ogni piattaforma con la copertina dell’album e un link alla classifica completa. Ognuno dei quattro ha la propria opzione e, con più canali, la propria scelta di canali; scegli tu l’ora d’invio (nel fuso orario attuale del Mac) e quante voci mostra ogni classifica, e ogni canale può usare il report completo, quello breve o la panoramica, oppure titolo e testo personalizzati con segnaposto.

- Disattivata di default
- Impostazioni: Avvisi push › Canali
- Impostazioni: Avvisi push › Ora di invio
- Impostazioni: Avvisi push › Report di ascolto
- Impostazioni: Avvisi push › Fonte dati
- Impostazioni: Avvisi push › Voci per elenco
- Impostazioni: Avvisi push › Report di ascolto giornaliero
- Impostazioni: Avvisi push › Riepilogo ascolti settimanale
- Impostazioni: Avvisi push › Riepilogo ascolti mensile
- Impostazioni: Avvisi push › Riepilogo ascolti annuale
- Impostazioni: Avvisi push › Cronologia invii

<a id="section-general"></a>

## Uso quotidiano

<a id="feature-onboarding"></a>

### Configurazione al primo avvio

La prima volta che apri Lyrimuse, ti guida nella scelta dei player, nell’abbinamento di un browser e nella scelta di dove mostrare il testo, e controlla ogni permesso necessario così puoi sistemare subito ciò che manca.

<a id="feature-language"></a>

### Inglese, cinese semplificato e tradizionale, giapponese, coreano, spagnolo, francese, tedesco, italiano, portoghese brasiliano, vietnamita, russo, ucraino e thailandese

Per impostazione predefinita segue la lingua di sistema, e usa l’inglese quando la lingua di sistema non è tra queste; il cambio ha effetto subito, senza riavviare.

- Impostazioni: Generali › Aspetto e lingua › Lingua

<a id="feature-appearance"></a>

### Chiaro, scuro o automatico

Impostazioni, finestra testo, Gestione testi e pannello della barra dei menu possono restare chiari o scuri; per impostazione predefinita seguono il sistema. Il testo fluttuante segue comunque il sistema, e il notch è sempre scuro.

- Impostazioni: Generali › Aspetto e lingua › Aspetto

<a id="feature-shortcuts"></a>

### Scorciatoie da tastiera globali

Mostrare o nascondere ogni tipo di testo (o tutti insieme, per riunioni e condivisione dello schermo), aprire la finestra testo e Gestione testi, la ricerca, il timing, la riproduzione, Preferito e il passaggio al player possono avere tutti una scorciatoia. Per impostazione predefinita non ne è assegnata nessuna.

- Impostazioni: Scorciatoie da tastiera › Apri Impostazioni
- Impostazioni: Scorciatoie da tastiera › Nascondi/ripristina tutti i testi
- Impostazioni: Scorciatoie da tastiera › Passa al player
- Impostazioni: Scorciatoie da tastiera › Apri/chiudi pannello della barra dei menu

<a id="feature-deep-links"></a>

### Deep link (lyrimuse://)

I link lyrimuse:// aprono qualsiasi pagina delle impostazioni, la finestra testo o Gestione testi, ed eseguono ogni azione che può avere una scorciatoia, come riproduzione, Preferito o nascondere tutti i testi, da Comandi Rapidi, Raycast, Alfred e strumenti simili. Aperto con x-callback-url da Comandi Rapidi, un link può anche restituire titolo, artista, album e riga attuale. La scheda “Deep link” nella pagina “Scorciatoie da tastiera” elenca tutti i link, pronti da copiare.

- Impostazioni: Scorciatoie da tastiera › Deep link

<a id="feature-settings-search"></a>

### Ricerca nelle impostazioni

Digita in cima alla barra laterale delle impostazioni per andare dritto a un’impostazione, evidenziata, anche dentro le sezioni compresse. Puoi cercare in inglese o in cinese.

<a id="feature-menu-bar-panel"></a>

### Pannello della barra dei menu

Fai clic sull’icona nella barra dei menu per aprire un pannello ispirato al Centro di Controllo di macOS: una scheda di riproduzione con illustrazione, testo, avanzamento e controlli, e riquadri che attivano o disattivano ogni tipo di testo e finestra. Tieni premuto o fai clic destro su un riquadro per girarlo e vedere le sue impostazioni più usate. Disponilo come preferisci: trascina i riquadri per spostarli, trascina un angolo per ridimensionarli e aggiungi o rimuovi riquadri e pulsanti della barra in basso. La barra spaziatrice e le frecce controllano la riproduzione e spostano la sincronizzazione del testo, e una scorciatoia può aprire il pannello.

- Attiva di default
- Impostazioni: Scorciatoie da tastiera › Apri/chiudi pannello della barra dei menu

<a id="feature-menu-bar-icon"></a>

### Icona nella barra dei menu

Dodici icone in tre dimensioni, che si muovono con la musica durante la riproduzione, oppure l’illustrazione dell’album in riproduzione. Le azioni di tutti i giorni sono nel suo menu.

- Attiva di default
- Impostazioni: Generali › Barra dei menu e Dock › Icona nella barra dei menu
- Impostazioni: Generali › Barra dei menu e Dock › Illustrazione album
- Impostazioni: Generali › Barra dei menu e Dock › Dimensioni icona
- Impostazioni: Generali › Barra dei menu e Dock › Icona animata

<a id="feature-dock-icon"></a>

### Mostra nel Dock

Disattiva l’opzione per tenere solo l’icona nella barra dei menu.

- Attiva di default
- Impostazioni: Generali › Barra dei menu e Dock › Mostra nel Dock

<a id="feature-launch-at-login"></a>

### Apri al login

Apre Lyrimuse quando accedi al Mac.

- Attiva di default
- Impostazioni: Generali › Avvio e notifiche › Apri al login

<a id="feature-silent-launch"></a>

### Avvio silenzioso

Si avvia senza aprire alcuna finestra, solo con l’icona nella barra dei menu.

- Disattivata di default
- Impostazioni: Generali › Avvio e notifiche › Avvio silenzioso

<a id="feature-song-notifications"></a>

### Notifica al cambio brano

Una notifica di sistema per ogni nuovo brano.

- Disattivata di default
- Impostazioni: Generali › Avvio e notifiche › Notifica al cambio brano

<a id="feature-backup"></a>

### Backup delle impostazioni, passaggio a un nuovo Mac

Esporta tutte le impostazioni in un unico file, salvato su iCloud Drive per impostazione predefinita o in una cartella a tua scelta; quando un nuovo Mac apre Lyrimuse per la prima volta e lo trova in iCloud, propone di importarlo.

- Impostazioni: Generali › Backup e migrazione › Backup iCloud
- Impostazioni: Generali › Backup e migrazione › File impostazioni

<a id="feature-updates"></a>

### Aggiornamenti automatici e beta

Cerca da solo le nuove versioni; leggi le note e installa dalla pagina “Aggiornamento software”. Attiva “Aggiornamenti beta” per provare le novità in anticipo.

- Disattivata di default
- Impostazioni: Aggiornamento software › Impostazioni aggiornamenti › Verifica automaticamente
- Impostazioni: Aggiornamento software › Impostazioni aggiornamenti › Scarica e installa automaticamente
- Impostazioni: Aggiornamento software › Impostazioni aggiornamenti › Aggiornamenti beta

<a id="feature-diagnostics"></a>

### Diagnosi e segnalazione dei bug con un clic

Raccoglie log, resoconti di arresto anomalo e stato dell’app in un unico file, senza credenziali né nome utente. “Segnala un problema” apre una issue su GitHub con versione, macOS e player già compilati.

- Impostazioni: Info › Diagnosi e dati › Esporta diagnosi
- Impostazioni: Info › Aggiornamenti e aiuto › Segnala un problema

<a id="feature-telemetry"></a>

### Dati di utilizzo anonimi, disattivabili

Al massimo una volta al giorno invia versione, macOS, funzioni attive e riepiloghi degli arresti anomali al server dell’autore, per decidere cosa correggere prima. Mai titoli dei brani, artisti, percorsi locali o account. Attivo per impostazione predefinita; disattivalo in Impostazioni o nella schermata di benvenuto.

- Impostazioni: Info › Diagnosi e dati › Condividi dati di utilizzo anonimi

<a id="section-all-settings"></a>

## Tutte le impostazioni

Tutte le impostazioni della finestra Impostazioni, per posizione: 316 in tutto. Scrivi un nome nel campo di ricerca in cima alla barra laterale delle Impostazioni per andarci direttamente.

### Testo › Fonte

- **Fonti dei testi**
- **Algoritmo di associazione**
- **Preferisci il testo del file del brano**: Riproducendo un file locale, usa prima il .lrc con lo stesso nome o il testo incorporato
- **Riscegli dopo aggiornamento algoritmo**: Rivalutato in background; può passare a una versione migliore
- **Condividi testo tra voci dello stesso brano**: Una copia per la stessa registrazione tra player e versioni dell’album; anche le modifiche si sincronizzano
- **Blocca testi scelti a mano**: Il testo scelto manualmente non viene mai sostituito dall’associazione automatica
- **Prepara brani successivi**: Recupera in anticipo il testo dei brani in arrivo

### Testo › Lingua

- **Lingua di traduzione**
- **Traduci se manca**: Traduce prima su questo Mac, e online quando non è possibile
- **Lingue per la traduzione**: Lingue di sistema usate per la traduzione sul dispositivo
- **Scrittura cinese**
- **Lingue con pronuncia**
- **Pronuncia giapponese**: Romaji, o hiragana solo per i kanji

### Testo › Timing e a capo

- **Dividi righe lunghe**: Le righe troppo lunghe vengono divise e mostrate in più parti
- **Unisci righe brevi**: Le righe brevi vicine vengono unite se stanno su una riga
- **Offset del timing**: Valori positivi anticipano il testo, valori negativi lo ritardano

### Testo › Libreria testi

- **Libreria testi**
- **Associa testi mancanti**: Solo brani senza testo o con testo semplice
- **Riassocia tutta la libreria**: Include i brani che hanno già un testo, tranne quelli modificati, calibrati e strumentali
- **Intervallo di scansione**: Secondi tra un brano e l’altro; si consigliano almeno 2 secondi per evitare limiti di richieste
- **Cartella testi**: I file esistenti restano dove sono quando cambi la posizione
- **Formato testo parola per parola**
- **Importa cartella testi**: Associa i file dei testi di una cartella ai brani della libreria, con un’anteprima prima dell’importazione
- **Importazione cartelle**
- **Cartella monitorata**: I file dei testi nuovi o modificati nella cartella vengono importati automaticamente: i brani senza testo lo ricevono subito, quelli con testo restano invariati
- **Libreria importazioni**: Visualizza ed elimina i testi importati

### Player

- **App musicali**
- **Web**: Il testo funziona anche con la musica riprodotta in un browser. Fai clic su + per abbinare il browser che usi; la posizione viene letta direttamente dalla pagina, quindi il testo si sincronizza subito dopo un cambio di brano
- **Altre app**: Anche le app non elencate sopra possono essere usate come player: una volta aggiunte, i loro brani mostrano il testo e contano nella cronologia ascolti
- **Aggiungi app…**: Scegline una da Applicazioni, senza aspettare che inizi a riprodurre
- **Avvisi nuovi player**

### Player › Web

- **Salta pubblicità**: Le pubblicità che si possono saltare vengono saltate appena compaiono

### Player › Permessi e servizi

- **Permesso Automazione**
- **Accesso completo al disco**
- **Accessibilità**
- **Open API di LX Music**: Lyrimuse legge la posizione di riproduzione di LX Music e ne regola il volume tramite questa API
- **API di Pear Desktop**: Lyrimuse legge da Pear Desktop l’ID e il tipo del brano in riproduzione e la coda tramite questa API
- **Motore dei testi**: Legge lo stato di riproduzione e recupera testi e illustrazioni

### Player › Avvio e uscita

- **Avvio e uscita**: Sono elencati solo i player selezionati. Con “Rilevamento auto” attivo, compaiono anche i player installati su questo Mac
- **Apri player all’avvio**
- **Apri con il player**
- **Esci con il player**

### Visualizzazione testo › Testo fluttuante

- **Testo fluttuante**
- **OBS**
- **Tema**
- **Larghezza**
- **Posizione**
- **Ripristina default**: Reimposta solo tema, font e colori

### Visualizzazione testo › Testo fluttuante › OBS

- **Uscita OBS**: Sovrapponi il testo alla diretta come fonte browser. Imposta larghezza e altezza sulle dimensioni del canvas di OBS
- **URL della fonte browser**
- **Scheda titolo**: Mostra titolo, artista e illustrazione in alto a sinistra
- **Consenti accesso dalla rete locale**: I dispositivi sulla stessa rete possono connettersi con un link che include una chiave di accesso
- **Link di accesso**
- **Link alternativo (indirizzo IP)**
- **Reimposta chiave di accesso**: I link già condivisi smetteranno di funzionare
- **Porta**: Dopo la modifica, aggiorna l’URL in OBS

### Visualizzazione testo › Testo fluttuante › Tema

- **I miei temi**

### Visualizzazione testo › Testo fluttuante › Font

- **Font**
- **Spessore**
- **Corpo**
- **Corpo pronuncia**
- **Corpo traduzione**
- **Corpo riga seguente**

### Visualizzazione testo › Testo fluttuante › Colore

- **Effetto karaoke**
- **Colore testo**
- **Contorno testo**
- **Colore contorno**
- **Colore non cantato**
- **Colore di sfondo**
- **Sfondo smerigliato**
- **Densità vetro**

### Visualizzazione testo › Testo fluttuante › Contenuto

- **Pronuncia**
- **Traduzione**
- **Riga successiva**
- **Disposizione riga successiva**: Sfalsato: due righe della stessa dimensione, una a sinistra e una a destra; la riga appena cantata lascia il posto a quella dopo la successiva. Traduzione e pronuncia di riga sono nascoste

### Visualizzazione testo › Testo fluttuante › Layout

- **Allineamento**
- **Righe lunghe**
- **Transizione righe**: Al cambio di riga, la successiva sale in posizione. Se disattivata, le righe cambiano all’istante
- **Pronuncia**
- **Traduzione**
- **Riga successiva**

### Visualizzazione testo › Testo fluttuante › Comportamento

- **Blocca posizione**
- **Tieni premuto per trascinare**
- **Sfuma al passaggio del mouse**
- **Mostra controlli al passaggio**
- **Nascondi negli screenshot**
- **Nascondi in pausa**
- **Nascondi se non c’è testo**
- **Nascondi durante la pubblicità**
- **Nascondi a tutto schermo**

### Visualizzazione testo › Testo fluttuante › Posizione

- **Mostra su**

### Visualizzazione testo › Notch

- **Testo nel notch**
- **Stile**
- **Schermo**
- **Sinistra**
- **Destra**
- **Larghezza**
- **Larghezza espansa**
- **Ripristina default**: Larghezza e interruttore “Testo nel notch” restano invariati

### Visualizzazione testo › Notch › Stile

- **Sfondo espanso**
- **Angoli**
- **Angoli espansi**
- **Linea di avanzamento**: Mostra l’avanzamento della riproduzione quando non è espanso

### Visualizzazione testo › Notch › Sinistra

- **Onda audio**: Appare su un lato alla volta

### Visualizzazione testo › Notch › Riga del testo

- **Mostra testo se compresso**: Se disattivato, resta solo una striscia alta quanto il notch finché non ci passi sopra per espanderla
- **Allineamento**
- **Colore testo**
- **Seconda riga**
- **Anteprima riga successiva da espanso**
- **Altezza**
- **Effetto karaoke**
- **Mostra illustrazione**
- **Posizione illustrazione**
- **Sfuma al passaggio del mouse**

### Visualizzazione testo › Notch › Font

- **Font**
- **Spessore**
- **Corpo**

### Visualizzazione testo › Notch › Espanso

- **Testo su più righe**: Da espanso mostra più righe di testo, con la riga attuale evidenziata parola per parola
- **Righe**
- **Mostra controlli**
- **Mostra offset testo**
- **Azioni rapide**
- **Info brano**

### Visualizzazione testo › Notch › Comportamento

- **Comprimi in pausa**
- **Nascondi negli screenshot**
- **Nascondi in pausa**
- **Comprimi riga se non c’è testo**
- **Comprimi durante la pubblicità**
- **Nascondi a tutto schermo**
- **Mostra in schermata di blocco**
- **Traguardi di ascolto**
- **Titolo al cambio brano**
- **Mostra con tasti volume**
- **Gesti trackpad**

### Visualizzazione testo › Barra dei menu

- **Testo nella barra dei menu**
- **Ripristina default**: La larghezza e l’opzione “Testo nella barra dei menu” restano invariate

### Visualizzazione testo › Barra dei menu › Contenuto

- **Contenuto mostrato**
- **Seconda riga**
- **Icona accanto al testo**: L’icona si riempie dal basso verso l’alto per mostrare l’avanzamento, con i colori impostati in “Colore”

### Visualizzazione testo › Barra dei menu › Layout

- **Posizione**: Al centro: il testo appare al centro della barra dei menu, lontano dai menu delle app, dalle icone a destra e dal notch
- **Mostra su**
- **Modalità larghezza**: Fisso: tutti i brani usano la larghezza impostata Adattivo: ogni brano ha una larghezza in base al suo testo, fino a quella impostata
- **Allineamento**

### Visualizzazione testo › Barra dei menu › Colore

- **Effetto karaoke**
- **Arcobaleno**: Il testo scorre da sinistra a destra nei colori dell’arcobaleno, scurito su una barra dei menu chiara; i colori di sistema tornano mentre il menu è aperto
- **Colore testo**
- **Colore cantato**

### Visualizzazione testo › Barra dei menu › Font

- **Font**
- **Spessore**
- **Corpo**

### Visualizzazione testo › Barra dei menu › Larghezza

- **Larghezza max**

### Visualizzazione testo › Barra dei menu › Comportamento

- **Mostra controlli al passaggio**
- **Mostra titolo senza testo**: Mostra il titolo del brano al posto del testo quando non c’è o è ancora in ricerca

### Visualizzazione testo › Touch Bar

- **Testo Touch Bar**
- **Ripristina default**: L’interruttore “Testo Touch Bar” resta com’è

### Visualizzazione testo › Touch Bar › Contenuto

- **Seconda riga**
- **Senza traduzione**
- **Senza pronuncia**
- **Corpo**

### Visualizzazione testo › Touch Bar › Layout

- **Allineamento**
- **Mostra illustrazione**
- **Posizione illustrazione**
- **Mostra controlli**: Precedente, Riproduci/Pausa e Successivo, più un pulsante impostazioni
- **Posizione controlli**
- **Mostra pulsante “Altro”**: Toccalo per passare a posizione di riproduzione, calibrazione del testo, Preferito, Casuale/Ripeti e volume. Le voci non supportate dal player attuale sono nascoste
- **Nascondi Control Strip se espanso**: Il testo occupa tutta la Touch Bar. Per raggiungere luminosità, volume e altri pulsanti di sistema, tocca prima ✕ a sinistra per chiudere il testo
- **Control Strip**: Aggiungi, rimuovi o riordina i pulsanti di luminosità, volume e gli altri pulsanti di sistema a destra della Touch Bar in Impostazioni di Sistema › Tastiera › Impostazioni Touch Bar…

### Visualizzazione testo › Touch Bar › Colore

- **Effetto karaoke**
- **Colore testo**: Bianco, colore dell’illustrazione, colore personalizzato o arcobaleno
- **Luminosità testo attenuato**: Luminosità delle parole non cantate e della seconda riga

### Visualizzazione testo › Touch Bar › Comportamento

- **Espandi all’avvio della riproduzione**: Mostra il testo quando la riproduzione riprende dalla pausa. Cambiare brano durante la riproduzione non lo espande, e il testo che hai compresso resta compresso
- **Comprimi in pausa**: Si comprime nel pulsante della Control Strip dopo 10 secondi di pausa e si espande di nuovo alla ripresa
- **Comprimi per strumentali e senza testo**: Si comprime solo dopo aver confermato che non c’è testo e si espande di nuovo quando viene trovato. Resta visibile durante la ricerca
- **Comprimi durante la digitazione**: Si comprime mentre il cursore è in un campo di testo, così compaiono i candidati del metodo di input e i suggerimenti, e si espande all’uscita dal campo. Richiede il permesso “Accessibilità”

### Visualizzazione testo › Finestra testo

- **Finestra testo**
- **Testo web**: Mostra la finestra testo in un browser web
- **Ripristina default**

### Visualizzazione testo › Finestra testo › Testo web

- **Indirizzo locale**
- **Consenti accesso dalla rete locale**: I dispositivi sulla stessa rete possono connettersi con un link che include una chiave di accesso
- **Consenti controllo remoto**: Controlla la riproduzione e salta nel testo da altri dispositivi
- **Link di accesso**
- **Link alternativo (indirizzo IP)**
- **Reimposta chiave di accesso**: I link già condivisi smetteranno di funzionare
- **Porta**: Dopo la modifica, scansiona di nuovo il codice QR per riconnetterti

### Visualizzazione testo › Finestra testo › Sfondo

- **Sfondo**: Sfondo della finestra testo: illustrazione, uniforme, gradiente o smerigliato
- **Direzione**
- **Spotify Canvas** (solo Completa): Usa il video in loop del brano su Spotify come sfondo; solo per brani riprodotti in Spotify
- **Densità vetro**: Densità del vetro smerigliato (cinque livelli)
- **Colore in basso**

### Visualizzazione testo › Finestra testo › Font

- **Corpo** (solo Mini): Dimensione massima del testo in formato Mini
- **Font**: Font della finestra testo (testo principale, traduzione, pronuncia)
- **Spessore**

### Visualizzazione testo › Finestra testo › Layout

- **Righe lunghe** (solo Mini): Se nella vista Mini le righe lunghe vanno a capo o scorrono
- **Layout testo** (solo Mini): Una riga: solo la riga attuale Due righe: la riga attuale e la successiva Multiriga: una pagina di testo che scorre, come nella vista Completa
- **Allineamento** (solo Completa): Allineamento del testo nella dimensione Completa; “Auto” segue le parti del duetto
- **Dimensioni dei controlli** (solo Completa): Ingrandisce i controlli di riproduzione e gli altri pulsanti, anche nel testo web

### Visualizzazione testo › Finestra testo › Comportamento

- **Sfuma al passaggio del mouse** (solo Mini)
- **Clic passante se sfumato** (solo Mini): Quando è sfumato, i clic passano alla finestra sottostante. Tieni premuto ⌥ per renderlo opaco e interagire
- **Nascondi in pausa** (solo Mini)
- **Nascondi se non c’è testo** (solo Mini)
- **Nascondi a tutto schermo** (solo Mini)

### Visualizzazione testo › Finestra testo › Colore

- **Effetto karaoke**
- **Colore testo**: Colore del testo della finestra testo. “Auto” passa da chiaro a scuro in base alla luminosità dello sfondo
- **Colore personalizzato**
- **Colore cantato**
- **Evidenziazione HDR** (solo Completa): Illumina la parte cantata sugli schermi HDR. Consuma più energia se attiva

### Visualizzazione testo › Finestra testo › Contenuto

- **Pronuncia**
- **Traduzione**
- **Barra di avanzamento** (solo Mini): Se disattivata, appare solo quando compaiono i controlli di riproduzione al passaggio del mouse

### Visualizzazione testo › Finestra testo › Intestazione

- **Titolo** (solo Mini): Mostra titolo, artista e album in alto nella vista Mini
- **Artista** (solo Mini)
- **Album** (solo Mini)
- **Illustrazione** (solo Mini): Miniatura dell’illustrazione accanto all’intestazione della vista Mini
- **Tempo** (solo Mini): Mostra il tempo trascorso e la durata del brano in alto nella vista Mini
- **Larghezza** (solo Mini): Quanta larghezza della finestra occupa l’intestazione della vista Mini
- **Altezza** (solo Mini): Quanta altezza della finestra occupa l’intestazione della vista Mini; testo e illustrazione si ridimensionano di conseguenza

### Visualizzazione testo › Finestra testo › Illustrazione

- **Illustrazione animata** (solo Completa): Solo su alcuni album; in pausa con Risparmio energetico o con “Riduci movimento” attivo
- **Cache illustrazioni animate** (solo Completa): Spazio su disco delle illustrazioni animate scaricate; ciò che viene cancellato si riscarica alla prossima visualizzazione

### Scorciatoie da tastiera

- **Deep link**: Aprili da Comandi Rapidi, Raycast, Alfred e strumenti simili. Passa il puntatore su una scorciatoia qui sopra per copiare il link di quell’azione
- **Mostra/nascondi testo fluttuante**
- **Mostra/nascondi testo nel notch**
- **Espandi il notch per un attimo**
- **Alterna testo nella barra dei menu**
- **Espandi/Contrai testo Touch Bar**
- **Nascondi/ripristina tutti i testi**
- **Blocca/sblocca posizione**
- **Mostra/nascondi traduzione**
- **Mostra/nascondi pronuncia**
- **Ingrandisci testo fluttuante**
- **Rimpicciolisci testo fluttuante**
- **Apri Gestione testi**
- **Apri finestra testo**
- **Alterna dimensione Mini/Completa**
- **Cerca testo**
- **Apri Impostazioni**
- **Passa al player**
- **Apri/chiudi pannello della barra dei menu**
- **Anticipa testo**
- **Ritarda testo**
- **Azzera offset testo**
- **Passo**: Valore per ogni pressione
- **Riproduci/Pausa**
- **Brano successivo**
- **Brano precedente**
- **Aggiungi/rimuovi dai preferiti**

### Generali › Barra dei menu e Dock

- **Icona nella barra dei menu**
- **Illustrazione album**
- **Dimensioni icona**
- **Icona animata**
- **Mostra nel Dock**

### Generali › Aspetto e lingua

- **Aspetto**: Colori di Impostazioni, Finestra testo, Gestione testi e pannello della barra dei menu
- **Lingua**

### Generali › Avvio e notifiche

- **Apri al login**
- **Avvio silenzioso**
- **Notifica al cambio brano**

### Generali › Rete

- **Proxy**

### Generali › Backup e migrazione

- **Backup iCloud**
- **File impostazioni**: Include credenziali in chiaro. Esporta impostazioni e libreria testi in due file; l’importazione sostituisce tutte le impostazioni
- **Cancella tutte le impostazioni**: Cancella solo le impostazioni su questo Mac; backup e file esportati restano. Non si può annullare

### Aggiornamento software

- **Aggiornamento software**

### Aggiornamento software › Impostazioni aggiornamenti

- **Verifica automaticamente**: Cerca una nuova versione una volta al giorno
- **Scarica e installa automaticamente**: Scarica in background e installa quando esci da Lyrimuse
- **Aggiornamenti beta**: Versioni preliminari; possono essere instabili

### Info › Aggiornamenti e aiuto

- **Segnala un problema**: Apre una nuova issue su GitHub con versione, macOS e player già compilati
- **Ottieni aiuto**: Chiedi nella categoria Q&A di GitHub Discussions
- **Elenco funzioni**: Tutte le funzioni, dove trovarle nelle Impostazioni e il loro stato predefinito

### Info

- **Sito web**
- **Community Discord**: Parla con altri utenti, fai domande o proponi idee
- **Gruppo Telegram**: Parla con altri utenti, fai domande o proponi idee
- **Gruppo QQ**: Parla con altri utenti, fai domande o proponi idee
- **Avviso di copyright**
- **Licenze di terze parti**: Componenti e dizionari open source
- **Licenza open source**: GPL-3.0

### Info › Diagnosi e dati

- **Esporta diagnosi**: Log, report dei crash e stato dell’app in un unico file, senza credenziali degli account. Nomi dei brani e percorsi locali restano: controllalo prima di pubblicarlo
- **Log attività**: Il log grezzo del motore dei testi, per risolvere i problemi da te
- **Cartella dati**: Solo testo. Credenziali degli account, aspetto e scorciatoie non sono inclusi; per migrare tutto, usa “Backup e migrazione”
- **Condividi dati di utilizzo anonimi**: Aiuta a migliorare Lyrimuse: versione, sistema, funzioni usate e resoconti dei blocchi. Mai titoli dei brani o account
- **Cache**: Illustrazioni e ricerche che si possono recuperare di nuovo

### Lab › ListenBrainz

- **Info account**

### Last.fm › Regole

- **Regole scrobble**
- **Modalità di associazione**: Artista e titolo inviati a Last.fm Smart: usa la grafia più ascoltata su Last.fm, oppure li invia così come sono se non c’è corrispondenza. Dagli album vengono tolti “ - Single” / “ - EP” Personalizzato: imposta titolo e artista separatamente Originale: invia esattamente ciò che riporta il player
- **Titolo**
- **Artista**
- **Momento scrobble**
- **Scrobble dei brani sotto i 30 secondi**: Se attiva, questi brani vengono scrobblati a metà ascolto. Le regole ufficiali di Last.fm li escludono
- **Player da scrobblare**

### Lab › Push web

- **Info connessione**

### Avvisi push

- **Canali**: I report di ascolto vanno a tutti i canali attivi. Con più canali, scegli quelli di ogni report in “Report di ascolto” qui sotto. Fai clic su una riga per modificarla o inviare una prova; clic destro per eliminarla
- **Ora di invio**
- **Report di ascolto**
- **Fonte dati**
- **Voci per elenco**: Quanti artisti, album e brani elencare
- **Riepilogo ascolti settimanale**
- **Report di ascolto giornaliero**
- **Riepilogo ascolti mensile**
- **Riepilogo ascolti annuale**
- **Cronologia invii**

### Discord

- **Mostra su Discord**: Se attivo, il brano che ascolti appare sul tuo profilo Discord e nell’elenco amici. Se gli amici non lo vedono, in Discord vai in Impostazioni utente › Privacy delle attività e attiva la condivisione delle attività
- **Contenuto mostrato**
- **Dopo “Sta ascoltando”**: Il “××” di “Sta ascoltando ××” nel tuo profilo. Discord su iOS e sul web lo ignora e continua a mostrare il player Con “Titolo” o “Artista” qui, “Sotto il tuo nome” non può mostrare il player
- **Sotto il tuo nome**: Discord può mostrare sotto il tuo nome solo la prima riga, la seconda o ciò che segue “Sta ascoltando”. Se né il titolo né l’artista si trovano in una di queste posizioni, l’opzione non è disponibile
- **Badge illustrazione**
- **Alla pausa**
- **Info brano**
- **Testo di stato**
- **Illustrazione e avanzamento**
- **Prefissi per artista e album**: Aggiunge “di” prima dell’artista e “da” prima dell’album. Non viene aggiunto se titolo e artista sono sulla stessa riga
- **Pulsanti**
- **Pulsante personalizzato**
- **“Ascolta sul player”**: Apre la pagina di questo brano sul sito del player attuale, come facendo clic sul titolo. Nascosto se non c’è una pagina
- **“Ottieni Lyrimuse”**
- **Privacy**
- **Nascondi temporaneamente**
- **Nascondi dettagli brano**: Mostra solo il player che usi e l’avanzamento. Titolo, artista, album, testo, link e pulsante “Ascolta sul player” non vengono inviati
- **Mostra barra di avanzamento**: Se disattivata, non c’è la barra di avanzamento; Discord mostra invece il tempo trascorso, che non si può disattivare
- **Player mostrati**
