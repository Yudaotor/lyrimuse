<div align="center">

<img src="docs/images/app-icon.png" width="120" alt="Icona di Lyrimuse">

# Lyrimuse

**Il testo sulla scrivania, reinventato per il Mac.**

**Language / 语言 / 語言 / 言語 / 언어 / Idioma / Langue / Sprache / Lingua:** [English](README.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | **Italiano** | [Português (Brasil)](README.pt-BR.md)

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Architecture](https://img.shields.io/badge/arch-Apple%20Silicon%20%2B%20Intel-blue)
[![Latest release](https://img.shields.io/github/v/release/Yudaotor/lyrimuse)](https://github.com/Yudaotor/lyrimuse/releases/latest)
[![Last commit](https://img.shields.io/github/last-commit/Yudaotor/lyrimuse/dev)](https://github.com/Yudaotor/lyrimuse/commits/dev)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-ea4aaa?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/Yudaotor)
[![Discord](https://img.shields.io/badge/Discord-Join-5865F2?logo=discord&logoColor=white)](https://discord.gg/N7gVy66Gp3)
[![Telegram](https://img.shields.io/badge/Telegram-Join-26A5E4?logo=telegram&logoColor=white)](https://t.me/lyrimuse)
[![QQ](https://img.shields.io/badge/QQ-Join-1EBAFC?logo=qq&logoColor=white)](https://qm.qq.com/q/Nb4TlwfnQy)

</div>

https://github.com/user-attachments/assets/88b951ee-4ecf-4985-b1cb-eee6afdd5510

Lyrimuse è un’app open source per macOS che mostra il testo dei brani sulla scrivania. Vive nella barra dei menu ed evidenzia il testo parola per parola mentre il brano suona: fluttuante sopra tutte le finestre, nella barra dei menu, in una capsula in stile Dynamic Island sotto il notch, sulla Touch Bar o in una finestra dedicata. Funziona con 14 player, tra cui Apple Music, Spotify, Amazon Music e Kaset, l’app per YouTube Music, oltre ai player web nel browser, e sceglie il testo più adatto tra 15 fonti dei testi, con traduzione e romanizzazione quando le vuoi. Tiene anche un profilo d’ascolto su Last.fm e fa lo scrobble dei tuoi ascolti.

**Arrivi da LyricsX?** LyricsX non ha più nuove versioni da aprile 2022. Lyrimuse fa quello che faceva LyricsX, continua a ricevere aggiornamenti e aggiunge il supporto ai player in lingua cinese, KKBOX, Amazon Music, Kaset, reAMP, VOX, Pine Player, foobar2000 e ai player web. Per i dettagli, vedi il [confronto verificato con LyricsX e Lyric Fever](docs/lyrics-apps-comparison.md).

**Installa** con Homebrew, su Apple Silicon o Intel. Ti evita anche l’avviso di Gatekeeper al primo avvio. Preferisci scaricarla da te? Prendi l’[ultima versione](https://github.com/Yudaotor/lyrimuse/releases/latest) e leggi [Per iniziare](#per-iniziare).

```bash
brew tap yudaotor/lyrimuse
brew trust --cask yudaotor/lyrimuse/lyrimuse   # one-time: Homebrew asks you to trust non-official taps
brew install --cask lyrimuse
```

<img src="docs/images/hero-surfaces.jpg" alt="Dove Lyrimuse mostra il testo — finestra testo in stile Apple Music, capsula in stile Dynamic Island, testo fluttuante evidenziato parola per parola, testo nella barra dei menu">
<p align="center"><sub>Quattro modi per mostrare il testo: la Finestra testo, la capsula in stile Dynamic Island, il testo fluttuante evidenziato parola per parola e la barra dei menu</sub></p>

<img src="docs/images/hero-engine.jpg" alt="Il motore dei testi di Lyrimuse — Gestione testi, pannello che spiega la scelta del testo per ogni brano con il punteggio di ogni risultato">
<p align="center"><sub>Gestione testi, la ricerca manuale con un punteggio su ogni risultato e il pannello che spiega perché un brano ha ricevuto proprio quel testo</sub></p>

<img src="docs/images/hero-profile.jpg" alt="Il profilo d’ascolto di Lyrimuse — statistiche Last.fm, classifiche, panoramica degli ascolti quando non suona niente, mappa di calore annuale degli ascolti">
<p align="center"><sub>I tuoi numeri e le tue classifiche di Last.fm, la panoramica che vedi quando non suona niente e una mappa di calore del tuo anno in stile GitHub</sub></p>

<img src="docs/images/hero-customize.jpg" alt="Le impostazioni di Lyrimuse — editor con anteprima dal vivo, scelta di più player compresi i player web, testo nella Touch Bar">
<p align="center"><sub>Ogni pagina delle impostazioni ha un’anteprima dal vivo, puoi scegliere più di un player (anche player web) e il menu a discesa della barra dei menu fa il resto</sub></p>

## Funzionalità

> Dove si trova ogni funzionalità nelle Impostazioni e se è attiva o no dopo l’installazione: vedi l’**[elenco delle funzionalità](docs/feature-list.it.md)**.

### Testo sincronizzato parola per parola, trovato in automatico
- **Evidenziazione parola per parola** che va a tempo con il brano mentre suona.
- **15 fonti dei testi, interrogate al posto tuo**: NetEase Cloud Music, QQ Music, Kugou, Kuwo, Migu, Musixmatch, LRCLIB, LyricFind (tramite YouTube Music), Deezer, AMLL (un database di testi parola per parola curato a mano), Soda Music (con i suoi tempi parola per parola), VIBE e Genie (entrambe forti sui brani coreani), PetitLyrics (forte sui brani giapponesi) e i testi di Apple Music, se colleghi il tuo account nelle Impostazioni. I testi di Apple Music richiedono un abbonamento, e molti dei suoi brani hanno i tempi parola per parola. Non devi mai cercare da te.
- **Traduzione e romanizzazione** sotto il testo originale. Se la fonte ha una traduzione della community, ricevi quella. Altrimenti attiva “Traduzione di riserva del sistema” nelle Impostazioni (è disattivata per impostazione predefinita) e il Mac traduce il testo con il framework Translation di Apple, quindi il testo non lascia mai il tuo computer; quando non ci riesce, interviene un traduttore online. Le lingue di destinazione sono 17. La romanizzazione si decide riga per riga: un brano cinese con una riga in giapponese riceve la pronuncia solo su quella riga, non il pinyin su tutto il resto. I brani in cantonese hanno il Jyutping, che riconosce le parole intere. Per il giapponese puoi scegliere invece il furigana: hiragana solo sopra i kanji, comodo se impari il giapponese con le canzoni. Hanno la pronuncia anche altre 18 lingue, tra cui russo, thailandese, greco e hindi, secondo la romanizzazione ufficiale di ciascuna lingua o uno standard ISO.
- **Duetti divisi per cantante.** Quando la fonte (o una voce di AMLL) indica chi canta quale riga, ogni parte viene mostrata a sé invece di due voci fuse in un unico blocco.
- **I tocchi di Apple Music nella Finestra testo**: i cori su una riga a parte sotto quella principale, le righe dei duetti che si sovrappongono illuminate insieme finché non finiscono entrambe, e le parole inglesi tenute a lungo che si gonfiano e brillano come fa Apple Music.
- **Cinese semplificato o tradizionale** per il testo, impostato a parte rispetto alla lingua dell’app.
- **Gestione testi**, per quando vuoi mettere ordine. Sfoglia, modifica, elimina o cerca di nuovo il testo di qualsiasi brano, eliminane molti in una volta e fai pulizia delle voci vuote lasciate da pubblicità e podcast. Se i tempi di un brano sono sfasati, sposta solo quel brano. Un pulsante riprova tutti i brani ancora senza testo, e una nuova scansione completa riassegna il testo a tutta la libreria con le regole di abbinamento attuali. Quello che hai corretto a mano non viene toccato. Puoi anche importare file .lrc o un’intera cartella, anche per brani che non hai ancora ascoltato, oppure lasciare che tenga d’occhio una cartella.
- **Un brano, un solo testo.** Lo stesso brano ascoltato in player diversi o da edizioni diverse viene riconosciuto come uno solo: le sue voci condividono il testo e le tue modifiche manuali, e i loro ascolti si sommano. “Voci di questo brano” in Gestione testi le confronta riga per riga e separa quella abbinata per errore.
- **Correggi il testo direttamente dalla Finestra testo.** Cerca altri testi, riassocia il brano o modifica il testo nel tuo editor di testo. Quando modifichi un testo parola per parola cambiano solo le parole, quindi ogni parola mantiene i suoi tempi.
- **Funziona offline** per ogni brano il cui testo è già nella cache.

### Profilo d’ascolto su Last.fm e scrobble
- **Un profilo d’ascolto completo.** Collega Last.fm con un clic dalla sezione degli account (nessun token da copiare e incollare) e hai i totali di oggi, degli ultimi 7 giorni e di sempre, un indicatore “scrobble in corso” in tempo reale e i tuoi ascolti recenti con le copertine, ognuno con un cuore per mettere “Mi piace” (o toglierlo) su Last.fm. Per impostazione predefinita ogni ascolto viene inviato come il brano corrispondente nel catalogo di Last.fm, così i crediti dei duetti, le grafie in cinese semplificato / tradizionale e suffissi come “ - Single” o “(Remastered)” finiscono sulla pagina giusta del brano; passa a “Originale” nelle Impostazioni per inviare esattamente quello che ha riportato il player. ListenBrainz riceve sempre i tag originali ([come funziona lo scrobble](docs/scrobbling.it.md)).
- **Top artisti, album e brani** degli ultimi 7 giorni, degli ultimi 30 giorni, dell’anno o di sempre, ognuno con quanto è salito o sceso rispetto al periodo precedente. Fai clic su un artista per vedere i suoi brani che ascolti di più.
- **Impronta**, una scheda tutta sua. Si apre con i tuoi totali: quanti giorni sono passati dal primo scrobble, in quanti di questi hai ascoltato qualcosa e la media giornaliera, il tuo giorno record, la serie attuale e quella più lunga, quest’anno fino a oggi confrontato con lo stesso periodo di un anno precedente, e quanto manca al prossimo traguardo tondo. Sotto trovi una mappa di calore dell’anno in stile GitHub (fai clic su un giorno per vedere cosa hai ascoltato di più), quando ascolti per ora e giorno della settimana, da dove vengono i tuoi artisti più ascoltati e “Accadde oggi”, con quello che hai ascoltato in questa data negli anni passati.
- **Ogni ascolto viene salvato prima sul tuo Mac**, anche prima di collegare Last.fm. Collegalo più tardi e invia con un clic le ultime due settimane circa (Last.fm non accetta ascolti più vecchi).
- **Decidi tu quando un ascolto conta**: al 50% come l’impostazione predefinita di Last.fm, al 75% o al 90%, oppure solo quando il brano finisce davvero. Per ListenBrainz non cambia nulla. Puoi anche escludere del tutto un player da Last.fm, così i suoi ascolti non compaiono mai nella tua cronologia.
- **La stessa cronologia compare nella Finestra testo** quando non suona niente, così vedi una panoramica invece di uno schermo vuoto (ne parliamo più sotto).

### Testo fluttuante, nella barra dei menu, Dynamic Island, Touch Bar o in una finestra dedicata
- **Usa più player o lascia scegliere a Lyrimuse.** Apple Music, Spotify e Kaset vengono letti con il permesso di Automazione. QQ Music, NetEase Cloud Music, Kugou Music, Soda Music, KKBOX, Amazon Music e LX Music vengono letti tramite MediaRemote di macOS e non richiedono alcun permesso. Attiva la combinazione che vuoi nelle Impostazioni, oppure lascia il rilevamento automatico e Lyrimuse segue quello che macOS mostra in “In riproduzione”.
- **Funziona anche la radio di Apple Music.** Il testo segue ogni brano di una stazione. Mentre parla il conduttore vedi il nome e il logo della stazione, non il brano precedente. La radio ha un offset dei tempi tutto suo, così sistemi una stazione una volta e non ci pensi più.
- **E anche i player nel browser.** Abbina il browser una volta e YouTube Music o Spotify Web funziona come qualsiasi altro player, con il testo sincronizzato sulla barra di avanzamento della pagina stessa. Una prova con un clic ti dice subito se il browser si può controllare. Durante una pubblicità la capsula diventa nera e mostra quanto manca e quale pubblicità è su quante. Le pubblicità di YouTube Music hanno un pulsante per saltarle, oppure si possono saltare in automatico.
- **Scegli come vederlo**, in qualsiasi combinazione o per niente:
  - un testo fluttuante sulla scrivania che puoi trascinare ovunque, oppure fissare in alto al centro o appena sopra il Dock;
  - una capsula in stile Dynamic Island in cima allo schermo, che può mostrare l’illustrazione dell’album e sfocarla dietro la capsula, attenuare la riga del testo così che i clic ci passino attraverso, e comparire sulla schermata di blocco se lo attivi;
  - la Touch Bar di un MacBook Pro che ce l’ha, con la riga che scorre mentre viene cantata, più l’illustrazione dell’album e i controlli di riproduzione se li vuoi;
  - una Finestra testo ridimensionabile, ispirata alla pagina del testo di Apple Music, con due colonne, una copertina sfocata sullo sfondo, l’intero brano che scorre fino alla riga corrente, l’illustrazione animata quando Apple Music ha una copertina animata per quel disco, e il video Spotify Canvas in loop del brano come sfondo quando c’è. Le parole si riempiono mentre vengono cantate, con lo spessore, il colore cantato e l’allineamento che scegli tu, ed “Evidenziazione HDR” può illuminare la parte cantata oltre il bianco su uno schermo HDR.
- **Testo nella barra dei menu (modalità testo).** La riga corrente sta direttamente nella barra dei menu. Le righe lunghe scorrono invece di essere troncate a metà (puoi tornare al troncamento). Una seconda riga può mostrare la riga successiva, la traduzione o la romanizzazione, e la capsula può fare lo stesso.
- **Trascina la barra di avanzamento per spostarti nel brano**, nella Finestra testo e nella capsula.
- **Casuale, ripetizione, Preferito e volume** direttamente nella Finestra testo, dove il player lo consente: Apple Music, Spotify, Kaset, QQ Music, Amazon Music e YouTube Music nel browser supportano ciascuno alcuni o tutti questi controlli, e NetEase Cloud Music, Kugou Music, Soda Music e LX Music hanno Preferito. Preferito c’è anche nella capsula espansa, e gli si può assegnare una scorciatoia.
- **Apri il brano là dove si trova** dal menu “⋯” o dal pannello delle informazioni. Apple Music lo apre nell’app, Spotify salta al brano in riproduzione e KKBOX apre il brano, l’album o l’artista nella sua app. QQ Music, Soda Music, Spotify, Amazon Music e YouTube Music (quando lo ascolti in Kaset) aprono la pagina web del brano, dell’album o dell’artista, e NetEase Cloud Music apre la pagina del brano. Lyrimuse ha trovato il link mentre cercava il testo, oppure l’ha letto dai dati del player sul tuo Mac, quindi non c’è niente da cercare.
- **Quando non suona niente**, la Finestra testo mostra i totali di oggi e di questa settimana, una scheda “Accadde oggi” e i tuoi ascolti recenti con le copertine, ognuno con il link alla pagina dell’album o dell’artista in Apple Music.
- **Una Finestra testo in formato mini**: una piccola scheda che mostra una riga, due righe o l’intero testo che scorre, con sfondo, colore del testo, font, spessore e colore cantato tutti suoi; il karaoke parola per parola si può disattivare solo per lei.
- **Testo web su telefono, tablet o in diretta.** Apri la Finestra testo in un browser su un altro dispositivo e usala come secondo schermo, con i controlli di riproduzione e il tocco per saltare a una riga, se li consenti. “Uscita OBS” porta il testo fluttuante nella tua diretta come fonte browser trasparente. Entrambi restano su questo Mac finché non consenti l’accesso dalla rete locale, e gli altri dispositivi si collegano scansionando un codice QR.
- **Note sul brano, note sull’album e biografie degli artisti.** Fai clic sul titolo, sull’artista o sul nome dell’album nella Finestra testo o nella capsula espansa per saperne di più. Le note sull’album e le biografie degli artisti vengono da Apple Music oppure, quando non ha niente, da Soda Music (brani ascoltati in Soda Music, solo con l’interfaccia in cinese), Kugou Music (brani ascoltati in Kugou Music, solo con l’interfaccia in cinese), NetEase Cloud Music (solo con l’interfaccia in cinese), dagli articoli di Wikipedia mostrati da YouTube Music (nella lingua dell’interfaccia) o da Last.fm; le note sul brano vengono da QQ Music (solo con l’interfaccia in cinese) o da Last.fm.
- **Personalizza l’aspetto come preferisci**: il font (quello di sistema o i tuoi file .ttf / .otf), la dimensione, i colori di testo / sfondo / ombra, temi salvati o un colore preso dall’illustrazione dell’album in riproduzione, la larghezza del testo fluttuante e in più un colore arcobaleno che scorre sul testo.
- **Nascosto in screenshot, registrazioni e condivisioni dello schermo.** Tu lo vedi, gli altri no.
- **Si nasconde quando metti in pausa**, così non resta sulla scrivania a far niente. Può anche farsi da parte durante i brani strumentali, i brani senza testo e le app a schermo intero, e il testo fluttuante può seguirti sullo schermo della finestra che stai usando.

### Dettagli di tutti i giorni
- **Inglese, cinese semplificato, cinese tradizionale, giapponese, coreano, spagnolo, francese, tedesco, italiano e portoghese brasiliano**, e il cambio di lingua ha effetto subito, senza riavviare. Hai notato una traduzione goffa? Le pull request sono benvenute; ogni lingua ha una guida di stile in `lyrimuse/Localization/`.
- **Liquid Glass su macOS 26.** Le Impostazioni, il pannello della barra dei menu, la Finestra testo, Gestione testi e la guida di configurazione lo usano, e quasi tutti possono restare chiari o scuri invece di seguire il sistema.
- **Scorciatoie da tastiera** per ogni azione, da nascondere tutti i testi ad aggiungere il brano ai preferiti. Di serie non ne è impostata nessuna, quindi i tasti li scegli tu. Ogni azione ha anche un link `lyrimuse://` che puoi richiamare da Comandi Rapidi, Raycast o Alfred, e da Comandi Rapidi un link può restituire il brano in riproduzione ([Schema URL](docs/url-scheme.it.md)).
- **Cerca nelle Impostazioni.** Scrivi nella barra laterale e la pagina scorre fino alla riga corrispondente e la evidenzia, aprendo un gruppo chiuso se serve.
- **Si aggiorna da sé.** Controlla per conto suo, o quando lo chiedi dalla barra dei menu. Gli aggiornamenti si installano dalla pagina “Aggiornamento software” nelle Impostazioni, con le note di rilascio e l’avanzamento proprio lì, e puoi scegliere di ricevere le versioni beta.
- **Si avvia insieme ai player**, con un’impostazione per ogni player e in entrambe le direzioni: aprili quando si apre Lyrimuse, apri Lyrimuse quando si aprono loro e, se vuoi, chiudi Lyrimuse quando tutti i player che segue sono stati chiusi.
- **Avvio silenzioso**, se preferisci che parta senza nessuna finestra, solo con l’icona nella barra dei menu.
- **Passi a un nuovo Mac?** Esporta tutta la configurazione e importala lì. Se qualcosa va storto, c’è anche l’esportazione della diagnosi con un clic.

### Extra facoltativi

<details>
<summary>ListenBrainz, stato su Discord, una pagina “in riproduzione” da condividere e riepiloghi giornalieri / settimanali / mensili / annuali</summary>

Sono tutti disattivati finché non li attivi nelle Impostazioni:

- **Scrobble anche su [ListenBrainz](https://listenbrainz.org).** Ogni ascolto va a entrambi i servizi dalla stessa lettura del player, così le due cronologie restano allineate. Anche gli ascolti dal tuo iPhone (registrati tramite Last.fm) vengono copiati in ListenBrainz, così hai un’unica cronologia per entrambi i dispositivi invece di due.
- **Una pagina pubblica “in riproduzione” da condividere**: riproduzione in tempo reale, cronologia, un libro degli ospiti, reazioni, un contatore delle visite, una classifica dei 10 artisti più ascoltati, un look da disco in vinile, temi chiaro e scuro e anteprime dei link come si deve nelle app di chat. La **[guida alle funzioni web](https://github.com/Yudaotor/nowplaying-workers#readme)** la illustra passo per passo con gli screenshot.
- **Riepiloghi degli ascolti giornalieri, settimanali, mensili e annuali**, inviati a tutti i canali che vuoi: Bark, ntfy, ServerChan, Feishu, DingTalk, WeCom, Telegram, Discord, Slack o un webhook generico. Ogni canale può inviare una prova, e una cronologia delle consegne mostra cosa è arrivato.
- **Mostra su Discord cosa stai ascoltando.** Il tuo profilo e l’elenco degli amici mostrano il player che usi, il brano, l’artista, l’illustrazione dell’album e una barra di avanzamento, e il titolo del brano e l’artista rimandano alle loro pagine sul sito di quel player. La riga dell’album può mostrare la riga cantata, e puoi aggiungere fino a due pulsanti. Nell’angolo della copertina c’è un piccolo badge di Lyrimuse o del player (o nessuno), e un brano in pausa può restare visibile con un’icona di pausa. Scegli tu quali player contano, puoi mostrare solo il player senza nominare il brano e puoi nasconderlo per un po’.

ListenBrainz e “Push web” sono sotto **Lab** nella barra laterale delle Impostazioni, “Avvisi push” sta con le altre sezioni e Discord ha una voce tutta sua in alto. Ogni scheda spiega i suoi passaggi di configurazione: dove ottenere una chiave API o un token, come collegare un account, come ottenere l’URL webhook del tuo servizio push. La pagina web è l’unica con una guida a parte, e non ti serve tutta. Con il solo ListenBrainz configurato, la pagina mostra già la riproduzione in tempo reale e la cronologia, senza bisogno di un Cloudflare Worker. Pubblicane uno se vuoi anche il libro degli ospiti, le reazioni, il contatore delle visite, la classifica dei 10 artisti e aggiornamenti più rapidi; la guida spiega come.

</details>

## Per iniziare

Le versioni sono firmate con il certificato del progetto, non con un Apple Developer ID, quindi nessuna delle opzioni qui sotto richiede un account Apple Developer. Il rovescio della medaglia è che la prima volta che apri l’app, Gatekeeper dice che “proviene da un’azienda di sviluppo non identificata”. Homebrew (opzione A) risolve la cosa per te. Con le altre opzioni è previsto, non è un bug, e l’opzione B spiega come superarlo una volta per tutte.
### Opzione 0: affida l’installazione a un’IA

Usi un agente IA che può usare il terminale del tuo Mac (Claude Code, Codex CLI, Gemini CLI, …)? Incollagli il blocco qui sotto così com’è e farà per te tutto quello che c’è nelle opzioni A/B. Le istruzioni gli permettono di installare solo questa app. Non userà `sudo` e non toccherà le impostazioni di sicurezza dell’intero sistema:

```text
Please install Lyrimuse — an open-source macOS menu-bar lyrics app
(https://github.com/Yudaotor/lyrimuse) — on this Mac, following these rules exactly:

1. Preferred path (if `brew` exists):
     brew tap yudaotor/lyrimuse
     brew trust --cask yudaotor/lyrimuse/lyrimuse
     brew install --cask lyrimuse
   If this Homebrew doesn't know the `trust` subcommand, skip that line — older
   versions don't need it.
2. If Homebrew is not installed, do NOT install Homebrew. Instead: check the CPU
   with `uname -m`, download the latest release asset from
   https://github.com/Yudaotor/lyrimuse/releases — `Lyrimuse-v<version>-macos.zip`
   for arm64, `Lyrimuse-v<version>-macos-intel.zip` for x86_64 — verify it against
   its `.sha256` file (`shasum -c`), unzip, move `Lyrimuse.app` into
   /Applications, then clear the Gatekeeper quarantine flag on that one app only:
     xattr -dr com.apple.quarantine /Applications/Lyrimuse.app
3. Safety rails: no `sudo` anywhere (nothing here needs it); never run
   `spctl --master-disable` or otherwise weaken Gatekeeper system-wide; never
   remove the quarantine flag from anything except /Applications/Lyrimuse.app.
4. Do not build from source unless I explicitly ask.
5. Launch it (`open -a Lyrimuse`) and verify it is running (`pgrep -x Lyrimuse`
   prints a PID).
6. A first-run wizard will appear — that part is mine to click through. Tell me
   it will ask me to pick a music player, to grant Automation access to
   Music.app and/or Spotify (only if I pick them), and to enable the background
   lyrics engine — then hand control back to me.
Finally, report what you did and anything that failed.
```

### Opzione A: installa con Homebrew (consigliata)

```bash
brew tap yudaotor/lyrimuse
brew trust --cask yudaotor/lyrimuse/lyrimuse   # one-time: Homebrew asks you to trust non-official taps
brew install --cask lyrimuse
```

L’installazione toglie in automatico la quarantena di Gatekeeper (serve una volta sola), quindi non c’è altro da fare dopo. Apri Lyrimuse da `/Applications` (o da Spotlight) appena `brew install` ha finito. `brew upgrade --cask lyrimuse` installa le nuove versioni allo stesso modo.

### Opzione B: scarica a mano una versione già compilata

1. Scaricala dalla [pagina Releases](https://github.com/Yudaotor/lyrimuse/releases). **Prima controlla quale Mac hai** ( → Informazioni su questo Mac → “Chip”: `Apple M…` è Apple Silicon, `Intel Core…` è Intel):

   | Il tuo Mac | Download |
   | --- | --- |
   | Apple Silicon (M1 e successivi) | `Lyrimuse-*-macos.dmg` o `.zip` |
   | Intel | `Lyrimuse-*-macos-intel.dmg` o `.zip` |

   Con il dmg, fai doppio clic per montarlo e trascina `Lyrimuse.app` sull’alias `Applications` lì accanto; con lo zip, decomprimilo e trascina `Lyrimuse.app` in `/Applications`. I due formati installano esattamente la stessa app, e lo zip è accompagnato da un `.sha256` se vuoi verificare il download (`shasum -c Lyrimuse-*.zip.sha256` dalla stessa cartella).

   L’unica differenza tra i due download è l’architettura: quello senza suffisso è solo per Apple Silicon, mentre `-intel` contiene codice sia Intel sia Apple Silicon. `-intel` funziona anche su Apple Silicon, ma lì non c’è motivo di usarlo: pesa il doppio, e macOS 27 e successivi avvisano che l’app “deve essere aggiornata” perché contiene codice Intel (Apple rimuoverà Rosetta in macOS 28; l’app in realtà non ha nessun problema).

   **Entrambe le architetture ricevono gli aggiornamenti automatici dall’app.** Il feed elenca due voci per la stessa versione, una per architettura: ai Mac Apple Silicon arriva la build senza suffisso, ai Mac Intel quella `-intel`, e Sparkle sceglie da solo per ogni computer. (Fino alla v1.4.0 compresa veniva servito solo Apple Silicon; chi aveva un Mac Intel doveva tornare qui a mano.)
2. Al primo avvio macOS si rifiuterà di aprirla, con “Apple non è in grado di verificare che Lyrimuse non contenga malware che potrebbero danneggiare il Mac o compromettere la tua privacy” o “proviene da un’azienda di sviluppo non identificata”. Sbloccala una volta, nel modo che ti è più comodo tra questi:

   - **Terminale (consigliato, funziona sempre):**
     ```bash
     xattr -dr com.apple.quarantine /Applications/Lyrimuse.app
     ```
     Poi apri l’app come al solito. Basta farlo una volta per ogni download.
   - **Clic destro → Apri:** nel Finder, fai clic con il tasto destro (o fai clic tenendo premuto Ctrl) su `Lyrimuse.app` e scegli **Apri**, poi conferma di nuovo **Apri** nella finestra di dialogo. Non funziona su tutte le versioni di macOS per ogni tipo di avviso, quindi se l’avviso resta usa il comando del Terminale qui sopra.
   - **Impostazioni di Sistema → Privacy e sicurezza:** prova ad aprire l’app una volta (verrà bloccata), poi apri **Impostazioni di Sistema → Privacy e sicurezza**, scorri fino in fondo e fai clic su **Apri comunque** accanto all’avviso su Lyrimuse. Se ti viene chiesto, conferma ancora una volta.

   Fallo solo per una build di cui ti fidi davvero: quella della pagina Releases di questo repository o una che hai compilato tu.

### Opzione C: compila dal codice sorgente

**Prerequisiti, da installare una volta sola** (salta quelli che hai già):

```bash
xcode-select --install   # Xcode Command Line Tools, for Swift — skip if `swift --version` already works
brew install go          # any Go ≥ 1.21 — build.sh switches to 1.24.4 automatically via GOTOOLCHAIN
```

Poi `build.sh` compila in un colpo solo sia l’app sia il suo motore dei testi (il processo in background chiamato `lyrimuse-engine`):

```bash
git clone https://github.com/Yudaotor/lyrimuse.git
cd lyrimuse/lyrimuse
./build.sh              # this machine's architecture
./build.sh --universal  # arm64 + x86_64 (the compatibility build shipped for Intel)
```

`build.sh` termina elencando le architetture di ogni binario nel bundle e segnala tutto quello che non corrisponde alla destinazione, che manchi una slice o ce ne sia una in più. Non assemblare a mano gli asset di una release: `./package.sh` compila ogni architettura una volta e produce zip + sha256 + dmg per ciascuna, e si rifiuta di creare i pacchetti se le architetture sono sbagliate.

Il supporto per QQ Music / NetEase Cloud Music / Kugou Music / Soda Music / KKBOX / Amazon Music / LX Music / Spotify / Kaset / rilevamento automatico richiede inoltre [ungive/media-control](https://github.com/ungive/media-control). Se manca, `build.sh` lo installa da solo tramite Homebrew, quindi neanche questo è un passaggio che devi fare tu.

### Dopo qualsiasi opzione

Apri Lyrimuse da `/Applications`. La configurazione guidata del primo avvio ti accompagna nella scelta di un player (Apple Music, QQ Music, NetEase Cloud Music, Kugou Music, Soda Music, KKBOX, Amazon Music, Spotify, Kaset, reAMP, VOX, Pine Player, foobar2000, LX Music o rilevamento automatico), nella concessione del permesso di Automazione se hai scelto Apple Music, Spotify, Kaset o VOX (gli altri non richiedono alcun permesso per leggere le informazioni di base del brano) e nell’attivazione del motore dei testi (così testi e illustrazioni continuano a essere trovati anche a finestra chiusa). Completa la procedura e il testo comparirà subito (vedi [lyrimuse/README.md](lyrimuse/README.md) per altre opzioni di compilazione).

Per il testo non serve altro. Gli extra facoltativi si possono configurare più tardi dalle Impostazioni, quando vuoi.

## Domande frequenti

### Come faccio ad avere il testo di Apple Music fluttuante sulla scrivania del Mac, sempre in primo piano?
Attiva il testo fluttuante nelle Impostazioni. Resta sopra tutte le finestre, in ogni Spazio. Trascinalo dove vuoi, oppure fissalo in alto al centro o appena sopra il Dock. Se il testo ha i tempi parola per parola, ogni parola si riempie mentre viene cantata. Puoi nasconderlo da screenshot, registrazioni e condivisioni dello schermo, e farlo sparire mentre la musica è in pausa. Funziona allo stesso modo con QQ Music, NetEase Cloud Music, Kugou Music, Soda Music, KKBOX, Amazon Music, LX Music, Spotify, Kaset e i player web.

### Posso mostrare il testo di Spotify nella barra dei menu del Mac?
Sì. Attiva la modalità testo della barra dei menu e la riga corrente compare nella barra dei menu, per Spotify o per qualsiasi altro player supportato. Le righe lunghe scorrono invece di essere troncate, e una seconda riga può mostrare la riga successiva, la traduzione o la romanizzazione. Non serve collegare un account Spotify. Lyrimuse chiede una volta il permesso di Automazione per Spotify, che fornisce la posizione di riproduzione esatta e fa funzionare i pulsanti di riproduzione. Se rifiuti, il testo compare lo stesso, ma i tempi arrivano da MediaRemote di macOS e possono essere sfasati di circa un secondo.

### Mostra il testo parola per parola per QQ Music, NetEase Cloud Music, Kugou o Soda Music?
Sì, purché il testo abbia i tempi parola per parola. NetEase Cloud Music, QQ Music, Kugou, Soda Music, Musixmatch, AMLL e Apple Music spesso li hanno, e quelle righe si riempiono parola per parola. Un testo con i soli tempi per riga illumina un’intera riga alla volta. E il player non limita da dove arriva il testo: un brano in riproduzione in Soda Music può ritrovarsi con il testo parola per parola di QQ Music, se è quello con il punteggio migliore.

### Serve un account Apple Developer per installarla?
No. Le versioni sono firmate con il certificato del progetto invece che con un Apple Developer ID, quindi l’account non serve né a te né al progetto. È anche il motivo del passaggio di Gatekeeper da fare una volta, descritto in “Per iniziare” qui sopra.

### Lyrimuse è sul Mac App Store?
No. Installala con Homebrew (opzione A qui sopra) o scaricala dalla [pagina Releases](https://github.com/Yudaotor/lyrimuse/releases) (opzione B). In entrambi i casi, da lì in poi gli aggiornamenti arrivano dall’app.

### Lyrimuse è gratuita?
Sì. È open source con licenza GPL-3.0. Non ci sono versioni a pagamento, acquisti in-app o account da creare. Last.fm e gli altri servizi sono a tua scelta. Se ti è utile e vuoi sostenerla, puoi [sponsorizzarla su GitHub](https://github.com/sponsors/Yudaotor) o [offrire un caffè all’autore](https://yudaotor.github.io/donate/) con Alipay o WeChat Pay.

### Posso controllare QQ Music, NetEase Cloud Music o Soda Music quando un’altra app ha il controllo dei media di sistema?
Sì. Quando qualcosa, per esempio un video nel browser, occupa “In riproduzione” di macOS, i tasti multimediali del sistema vanno a quell’app; allora Lyrimuse preme riproduci/pausa, precedente e successivo nella barra dei menu di QQ Music o di NetEase Cloud Music, o nella barra di riproduzione di Soda Music, lasciando il player in background. Serve il permesso Accessibilità (Impostazioni → Player); senza, quei pulsanti aprono quella pagina. In questa situazione non puoi spostarti nel brano. Su macOS 27 il permesso si trova in **Impostazioni di Sistema → Privacy e sicurezza → Controllo del dispositivo e accesso ai dati**; le versioni precedenti lo chiamano **Accessibilità**.

### Funziona con Spotify, QQ Music o NetEase Cloud Music, o solo con Apple Music?
Con tutti questi, più Kugou Music, Soda Music, KKBOX, Amazon Music, Kaset (un’app per YouTube Music), reAMP, il player in stile Winamp, VOX, il player locale lossless e hi-res, Pine Player, il player locale gratuito che riproduce quasi ogni formato, foobar2000, il classico player locale arrivato da Windows, e LX Music, open source: 14 player in tutto. Oppure lascia che rilevi in automatico quello che macOS mostra in “In riproduzione”. Apple Music, Spotify, Kaset e VOX chiedono il permesso di Automazione (Spotify, Kaset e VOX lo usano per i tempi esatti e i pulsanti di riproduzione). Gli altri 10 non richiedono alcun permesso per leggere le informazioni di base del brano tramite MediaRemote di macOS; i pulsanti casuale, ripeti e Preferito di QQ Music, NetEase Cloud Music, Kugou Music, Soda Music e Amazon Music, e casuale, ripeti e volume di reAMP e foobar2000, richiedono il permesso Accessibilità; Pine Player lo usa per leggere la sua barra di avanzamento, perché riporta la posizione solo al secondo. Con KKBOX, Amazon Music o LX Music viene considerato anche il testo che l’app ha già salvato per il brano, e nessuna delle tre viene mai contattata.

### Posso mostrare il testo di KKBOX o Amazon Music sul Mac?
Sì. Entrambi vengono letti tramite MediaRemote di macOS, quindi non c’è niente da autorizzare, e il loro testo compare fluttuante sulla scrivania, nella barra dei menu, nella capsula e nella Finestra testo come per qualsiasi altro player. Se KKBOX o Amazon Music hanno già salvato un testo per il brano, viene considerato anche quello, con un peso maggiore. Lyrimuse non accede mai a nessuno dei due servizi e non invia loro niente. Le altre fonti vengono interrogate comunque, quindi se una di loro ha qualcosa di meglio, come i tempi parola per parola, vince quella.


### Funziona con LX Music (洛雪音乐)?
Sì. LX Music viene letto tramite MediaRemote di macOS, quindi non c’è niente da autorizzare. Quando ascolti un brano in LX Music, viene considerato anche il testo che ha salvato per quel brano (parola per parola quando la piattaforma ce l’ha), con un peso maggiore, e i brani successivi della lista che stai ascoltando hanno il testo pronto in anticipo. Lyrimuse legge solo i dati di LX Music sul tuo Mac e non gli invia mai niente.

### Funziona con un’app desktop per YouTube Music?
Sì, con [Kaset](https://github.com/sozercan/kaset), un’app nativa e open source per YouTube Music su Mac. Kaset viene letto con il permesso di Automazione, che dà tempi esatti e pulsanti di riproduzione funzionanti, e il testo di YouTube Music stesso è tra i risultati. Funziona anche YouTube Music nel browser, vedi più sotto.

### Che aspetto ha il testo sulla scrivania?
Come un karaoke sulla scrivania. La riga corrente fluttua sopra le finestre, ogni parola si riempie mentre viene cantata quando il testo ha i tempi parola per parola, e la traduzione o la romanizzazione possono stare accanto. Puoi cambiare font, dimensione, colori di testo, sfondo e ombra e la larghezza, e far sì che il colore del testo segua l’illustrazione dell’album. Lo stesso testo può anche stare nella barra dei menu, in una capsula in stile Dynamic Island sotto il notch o in una finestra completa in stile Apple Music, in qualsiasi combinazione.

### La capsula Dynamic Island funziona su un Mac senza notch?
Sì. Su uno schermo senza notch, come un MacBook meno recente o un monitor esterno, la capsula sta in alto al centro, alta quanto la barra dei menu. Nelle Impostazioni scegli su quale schermo metterla.

### Il testo funziona senza connessione a Internet?
Sì, per ogni brano di cui ha già trovato il testo, perché è nella cache sul tuo Mac. La prima ricerca di un brano richiede una connessione, e lo stesso vale per la traduzione online.

### Qualcuno dei miei dati lascia il Mac?
Per trovare il testo deve interrogare le fonti dei testi sul brano in riproduzione: NetEase, QQ, Kugou, Kuwo, Migu, Musixmatch, LRCLIB, LyricFind, Deezer, AMLL, Soda Music, VIBE, Genie, PetitLyrics e Apple Music, se l’hai collegato. Le copertine arrivano dall’iTunes Search API. Per impostazione predefinita la traduzione avviene sul tuo Mac, e il testo va a un traduttore online (la traduzione web di Google, poi MyMemory) solo come riserva. La cronologia degli ascolti, i testi in cache e le impostazioni restano in file sul tuo Mac, a meno che tu non colleghi Last.fm, ListenBrainz o il relay web facoltativo. I dati di utilizzo anonimi (versioni, quali funzioni sono attive, riepiloghi dei crash; mai titoli di brani o account) vengono inviati una volta al giorno per impostazione predefinita, e puoi disattivarli in Impostazioni › Info. L’elenco completo è più sotto, in [Licenza e diritti d’autore](#licenza-e-diritti-dautore).

### Posso avere la romanizzazione del giapponese o del coreano, o la traduzione in cinese del testo?
Sì. La romanizzazione si decide riga per riga, quindi un brano che mescola più lingue ha la pronuncia solo dove serve. Per il giapponese si può mostrare il romaji o il furigana (hiragana sopra i kanji). La traduzione è quella della community della fonte del testo, quando c’è; altrimenti, una volta attivata “Traduzione di riserva del sistema” (disattivata per impostazione predefinita), arriva dalla traduzione automatica sul dispositivo o online, in una qualsiasi delle 17 lingue.

### Quali versioni di macOS supporta?
macOS 14 Sonoma o successivi (Sequoia, Tahoe e più recenti), su Apple Silicon o Intel. La traduzione sul Mac richiede macOS 15 Sequoia o successivi; su macOS 14 sono disponibili solo i traduttori online.

### Supporta i Mac Intel?
Sì, con una build universale separata (vedi l’opzione B qui sopra). Dalla v1.5.0 gli aggiornamenti automatici funzionano anche su Intel, quindi le nuove versioni arrivano proprio come su Apple Silicon.

### Può mostrare il testo di YouTube Music o Spotify in riproduzione nel browser?
Sì. Abbina il browser una volta nelle Impostazioni e YouTube Music o Spotify Web funziona come qualsiasi altro player. Il testo segue la barra di avanzamento della pagina invece di andare a intuito, e una prova con un clic ti dice, prima di impegnarti, se il browser si può controllare.

### Può fare lo scrobble di Apple Music su Last.fm da Mac?
Sì, è l’altra metà dell’app. Collega Last.fm con un clic dalle Impostazioni e ogni ascolto da Apple Music (o da qualsiasi altro player supportato) viene scrobblato, con lo stato “in riproduzione” in tempo reale. Gli ascolti vengono salvati prima sul tuo Mac, quindi quelli di prima del collegamento non vanno persi: una volta collegato, fai clic su “Recupera” per inviare quelli delle ultime due settimane circa. Scegli tu quando un ascolto conta (50%, 75%, 90% o l’intero brano), puoi escludere alcuni player e puoi inviare allo stesso tempo anche a ListenBrainz.

### Come fa Lyrimuse a non scegliere il testo sbagliato?
Non prende semplicemente la prima fonte che risponde. Ogni risultato di ogni fonte riceve un punteggio con lo stesso metodo: quanto corrispondono titolo, artista, album e durata, più aspetti come la presenza dei tempi parola per parola. Vince il punteggio più alto. Puoi vedere questa decisione per qualsiasi brano, con il punteggio di ogni risultato e il motivo per cui ha vinto il vincitore. Se più tardi salta fuori una corrispondenza migliore, Lyrimuse può passarci in automatico, ma il testo che hai scelto a mano è bloccato e non viene mai sostituito. La ricerca manuale mostra gli stessi punteggi e le stesse etichette, così una versione sbagliata si riconosce facilmente prima di sceglierla.

### E se il testo è fuori sincrono o sbagliato?
Se i tempi sono sfasati, spostali per quel brano; l’offset viene ricordato. Se è il testo sbagliato o la versione sbagliata, apri la ricerca manuale. Vedrai ogni risultato di ogni fonte con il suo punteggio, e quello che scegli viene bloccato, così l’abbinamento automatico non lo sostituisce. Puoi anche modificare a mano il testo di qualsiasi brano in Gestione testi.

### Posso salvare il testo come file .lrc?
Succede già. Ogni brano con un testo ha un file `.lrc` con i tempi per riga, più `.tr.lrc` per la traduzione e `.roma.lrc` per la romanizzazione, quando ci sono. I tempi parola per parola vengono salvati a parte, in TTML per impostazione predefinita. Nelle Impostazioni puoi passare a `.yrc` (il formato YRC di NetEase), Enhanced LRC, QRC o KRC perché altri player possano leggerli, e tenerne più di uno. I file sono in `~/Library/Application Support/me.yudaotor.lyrimuse/lyrics/`, e puoi spostare la cartella nelle Impostazioni.

### LyricsX è ancora mantenuto, e in cosa Lyrimuse è diversa da LyricsX o Lyric Fever?
L’ultima versione di LyricsX è la v1.6.3, di aprile 2022. Funziona su macOS 10.11 e successivi e supporta Apple Music, Spotify e alcuni player più vecchi. Lyric Fever si concentra su Spotify e Apple Music e richiede macOS 15. Lyrimuse richiede macOS 14 e aggiunge QQ Music, NetEase Cloud Music, Kugou, Soda Music, KKBOX, Amazon Music, Kaset, reAMP, VOX, Pine Player, foobar2000 e LX Music, i player nel browser, il pinyin / il Jyutping cantonese / la romanizzazione di giapponese e coreano riga per riga, più la pronuncia per altre 18 lingue come russo e thailandese, e lo scrobble su Last.fm / ListenBrainz con le tue statistiche d’ascolto. Il confronto fianco a fianco è nella [pagina di confronto](docs/lyrics-apps-comparison.md).
## Licenza e diritti d’autore

- **Lyrimuse in sé è [GPL-3.0](LICENSE).** I componenti open source e i dati dei dizionari inclusi nell’app (media-control, Sparkle, KeyboardShortcuts e i dizionari di OpenCC e rime-cantonese) mantengono le loro licenze; i testi completi sono in [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES), incluso anche nell’app e consultabile da **Impostazioni → Info → Licenze di terze parti**.
- **Testi, illustrazioni e metadati dei brani appartengono ai rispettivi titolari dei diritti.** Lyrimuse si limita a cercarli, metterli in cache e mostrarli: quello che restituiscono le API pubbliche dei testi viene salvato sul tuo Mac (`~/Library/Application Support/me.yudaotor.lyrimuse/`) solo perché tu lo veda. Lyrimuse non ospita, inoltra né ridistribuisce testi o illustrazioni, e la cache si può eliminare in qualsiasi momento da Gestione testi o rimuovendo quella cartella.
- **Lyrimuse è un progetto open source indipendente.** Non è affiliato, approvato né collegato in alcun modo ad Apple, Tencent (QQ Music), NetEase (NetEase Cloud Music), Kugou, Kuwo, Douyin (Soda Music), KKBOX, Amazon (Amazon Music), China Mobile (Migu Music), Spotify, Kaset, LX Music, Google (YouTube Music, Google Traduttore), Last.fm, ListenBrainz, MusicBrainz, Musixmatch, LRCLIB, LyricFind, Deezer, Naver (VIBE), KT (Genie), SyncPower (PetitLyrics), AMLL o SponsorBlock. I loro nomi e marchi appartengono ai rispettivi proprietari e compaiono qui solo per indicare quali player, fonti dei testi e servizi sono coinvolti.
- **Questo è tutto ciò che lascia il tuo Mac.** La ricerca del testo invia artista, titolo e album del brano (più la durata, alle fonti che la accettano) alle 15 fonti dei testi elencate sopra; quando nessuna trova una corrispondenza, il nome dell’artista viene inviato anche a MusicBrainz per cercarne gli alias (l’“Associazione intelligente” di Last.fm fa lo stesso per gli artisti che non ha mai visto prima), e le classifiche cercano lì i loro artisti tramite l’ID MusicBrainz per ottenere paese/regione e link. Le copertine e la pagina a riposo inviano artista + titolo all’iTunes Search API; con Kaset, la copertina che riporta viene scaricata dal server di immagini di YouTube Music (googleusercontent.com), e ogni nuovo ID video che riproduce viene inviato una volta a YouTube Music per verificare se è un episodio di podcast (gli episodi non vengono trattati come brani). Con l’Open API di LX Music attiva, Lyrimuse comunica solo con la porta di LX Music su questo Mac, e quando il sistema non ha una copertina per il brano scarica, una volta, quella indicata da LX Music. Le note sull’album e le biografie degli artisti richiedono le pagine pubbliche di Apple Music dell’album e dell’artista tramite i loro ID Apple Music, senza alcun account Apple; quando l’interfaccia è in cinese e Apple Music non ha biografia dell’artista né note sull’album, l’ID NetEase Cloud Music del brano viene usato per trovare gli artisti accreditati e l’album, poi la presentazione di quell’artista o di quell’album su NetEase viene scaricata tramite il suo ID, anche qui senza effettuare l’accesso. Con l’interfaccia in cinese, le note sul brano richiedono anche i dettagli del brano a QQ Music tramite il suo ID brano QQ Music, sempre senza effettuare l’accesso. Mentre QQ Music è in riproduzione, gli stessi dettagli vengono richiesti una volta per brano con qualsiasi lingua dell’interfaccia, per distinguere audiolibri e altri programmi parlati dai brani (i loro sottotitoli compaiono comunque, ma non vengono scrobblati né mostrati come brani). Quando Apple Music non ha un’illustrazione animata per l’album, l’ID album QQ Music viene inviato a QQ Music per cercare una copertina animata; se c’è, l’indirizzo del video viene richiesto tramite il suo ID video QQ Music mentre la Finestra testo è aperta, e il video viene scaricato dal server video di QQ Music (tencentmusic.com), senza effettuare l’accesso. Se non ce l’ha neanche QQ Music, l’ID NetEase Cloud Music del brano viene inviato a NetEase per cercarla lì, con l’identità ospite anonima che NetEase assegna ai visitatori senza account; il video arriva dal server video di NetEase (126.net). Mentre Kugou è in riproduzione, artista e titolo vanno una volta alla ricerca web di Kugou per trovare la pagina web del brano, senza effettuare l’accesso. Lo sfondo Spotify Canvas della Finestra testo legge solo la cache che Spotify tiene sul tuo Mac e non chiede niente a Spotify; un video trovato lì viene scaricato una volta dalla CDN di Spotify (canvaz.scdn.co), inviando solo l’indirizzo del video. Le note sull’album e le biografie degli artisti possono anche cercare l’album su YouTube Music per artista e nome dell’album (i brani ascoltati in Kaset o in YouTube Music sul web usano gli ID di album e artista riportati dal player) e scaricare la descrizione di Wikipedia dalle pagine dell’album e dell’artista su YouTube Music; per i brani ascoltati in Soda Music, le pagine di condivisione pubbliche dell’album e dell’artista vengono richieste tramite gli ID riportati da Soda Music. Nessuno dei due richiede un account. Con l’interfaccia in cinese, per i brani che LX Music riproduce da Kuwo, l’ID Kuwo del brano viene inviato a Kuwo per trovare gli ID dell’album e dell’artista, e le presentazioni dell’album e dell’artista vengono poi richieste tramite quegli ID, anche qui senza effettuare l’accesso. Per i brani ascoltati in Kugou Music, il motore chiede una volta a Kugou a quale album appartiene il file in riproduzione; con l’interfaccia in cinese, la presentazione dell’album su Kugou viene poi richiesta tramite quell’ID album e quella dell’artista tramite l’ID dell’artista dell’album, sempre senza effettuare l’accesso. La traduzione automatica di riserva (disattivata per impostazione predefinita, e usata solo quando la traduzione Apple sul dispositivo non è disponibile) invia il **testo stesso del brano**, a blocchi, prima all’endpoint della traduzione web di Google e quello che resta non tradotto a MyMemory; la richiesta a MyMemory contiene un parametro e-mail generato a caso, mai il tuo. Mentre in YouTube Music è in riproduzione un video musicale, i primi quattro caratteri dell’hash SHA-256 dell’ID video vanno a SponsorBlock per trovare i segmenti non musicali del video, così che il testo resti allineato alle immagini; da questo SponsorBlock non può capire di quale video si tratti. Il dominio di Musixmatch viene risolto con DNS-over-HTTPS tramite Cloudflare (1.1.1.1) e Google (8.8.8.8). La pagina Info chiede all’API di GitHub il numero di stelle al massimo una volta ogni sei ore e, se scegli di ricevere gli aggiornamenti beta, l’elenco delle versioni al massimo una volta all’ora; i controlli degli aggiornamenti scaricano l’appcast da GitHub Releases e non inviano alcun profilo di sistema. “Condividi dati di utilizzo anonimi” è attivo per impostazione predefinita (Impostazioni › Info › Diagnosi e dati; la schermata di benvenuto al primo avvio ha lo stesso interruttore). Al massimo una volta al giorno invia al server dell’autore (telemetry.yudaotor.me, un Cloudflare Worker) un ID di installazione casuale generato sul tuo Mac, se Lyrimuse è stato installato da zero o aggiornato da una versione precedente, le versioni di Lyrimuse e di macOS, il chip, la lingua dell’interfaccia e quelle di sistema, quali funzioni sono attive (superfici di visualizzazione, player selezionati, quante fonti dei testi sono abilitate, gli interruttori di traduzione e pronuncia, se sono collegati account come Last.fm, di quali player e browser di terze parti ti fidi (solo i bundle ID), quali player web hai abbinato), quali player hanno riprodotto musica nei giorni precedenti e quante volte l’app si è bloccata; quando Lyrimuse o il motore dei testi va in crash, invia anche un riepilogo del crash (il tipo di eccezione e i nomi delle funzioni nello stack, senza percorsi). Non invia mai titoli di brani, artisti, album, percorsi locali, nomi di account o credenziali; il server non conserva gli indirizzi IP, solo il paese o la regione che Cloudflare ne ricava. Se lo disattivi, non viene inviato niente. Oltre a questo, solo i servizi che colleghi tu: Last.fm, ListenBrainz, le piattaforme di notifiche push, il relay web facoltativo (la cui pagina dei 10 artisti più ascoltati cerca gli avatar degli artisti su Deezer). Con “Mostra su Discord” attivo nelle impostazioni di Discord, titolo, artista, album, nome del player, avanzamento della riproduzione, URL della copertina e link al brano e all’artista (più la riga cantata e i link dei tuoi pulsanti, se li attivi) vengono passati all’app Discord sul tuo Mac, che li mostra sul tuo profilo; quando possibile, la copertina è quella fornita dal tuo player, quella già presente sul tuo relay web o la stessa immagine su NetEase Cloud Music, QQ Music o Apple Music (quando il motore passa alla copertina del tuo player, ne scarica una volta una miniatura per verificare che corrispondano); altrimenti viene cercata su iTunes tramite l’ID brano o album di Apple Music (o per artista + titolo), e per un video senza nient’altro si usa l’URL della miniatura YouTube del video. Con Apple Music, la ricerca per ID brano avviene anche quando il relay ha già la copertina, per ottenere la pagina dell’artista. Una volta collegato, l’avatar Discord mostrato nelle Impostazioni (e, se ne usi una, la decorazione dell’avatar per l’anteprima) viene scaricato dal server di immagini di Discord (cdn.discordapp.com), e mentre la pagina Discord delle Impostazioni è aperta, la sua anteprima scarica la copertina dall’URL presente nel tuo stato per disegnarla. Quando la copertina del player è piccola, il motore scarica le miniature della copertina corrispondente su NetEase Cloud Music, QQ Music o Apple Music, della copertina che conserva il player stesso (compresi i server di immagini di KKBOX e Amazon Music, e quelli di Kuwo e Migu dietro le copertine di LX Music) e delle copertine che arrivano con i risultati delle fonti dei testi (come i server di immagini di Kugou, Soda Music, Deezer e Musixmatch), per verificare se si tratta della stessa immagine; quando l’URL di una copertina non ne indica le dimensioni, scarica anche l’inizio dell’immagine per leggerle. Viene inviato solo l’URL dell’immagine. Con “Testo web” o “Uscita OBS” attivi (entrambi disattivati per impostazione predefinita), Lyrimuse serve una pagina su questo Mac (porte 3939 e 3940, se non le cambi); solo questo Mac può aprirla finché non attivi “Consenti accesso dalla rete locale”, dopodiché i dispositivi della tua rete che hanno il link (contiene una chiave casuale) possono vedere il testo corrente, la copertina e l’avanzamento e, con “Consenti controllo remoto” attivo, controllare la riproduzione. Di sua iniziativa non invia niente a nessuno. Ogni richiesta in uscita viene scritta in un registro di controllo locale (solo host e operazione, mai parametri o credenziali), incluso in “Esporta diagnosi”.

## Risoluzione dei problemi

Se il testo non compare, apri **Fonti dei testi** nelle Impostazioni e fai clic su **Prova** per vedere quale fonte non è raggiungibile. Se non basta, usa **Esporta diagnosi** e allega il file a una [issue](https://github.com/Yudaotor/lyrimuse/issues); contiene già l’autodiagnosi completa del servizio in background.

<details>
<summary>Autodiagnosi da riga di comando</summary>

Lo stesso controllo, eseguito dal Terminale:

```sh
/Applications/Lyrimuse.app/Contents/Resources/lyrimuse-engine healthcheck
/Applications/Lyrimuse.app/Contents/Resources/lyrimuse-engine healthcheck -local-only  # no network
/Applications/Lyrimuse.app/Contents/Resources/lyrimuse-engine healthcheck -json
```

</details>

## Feedback

- **Problemi e idee**: nell’app, apri Impostazioni › Info › **Segnala un problema**, oppure fai clic con il tasto destro sull’icona nella barra dei menu e scegli **Aiuto › Segnala un problema…**. Si apre una nuova issue su GitHub con la tua versione, macOS e il player attuale già compilati; scegli il tipo di segnalazione: bug, testo mancante o sbagliato, richiesta di un player o richiesta di funzionalità.
- **Testo sbagliato per un brano**: apri **Cerca testi** per quel brano in **Gestione testi** e fai clic su **Non trovi il testo giusto? Segnalalo su GitHub** in basso a sinistra. I dettagli del brano, la fonte del testo in uso e le fonti che hanno restituito risultati vengono allegati.
- **Domande**: chiedi nella [categoria Q&A](https://github.com/Yudaotor/lyrimuse/discussions/categories/q-a) delle Discussions.
- **Parla con altri utenti**: entra nel [server Discord](https://discord.gg/N7gVy66Gp3), nel [gruppo Telegram](https://t.me/lyrimuse) o nel [gruppo QQ](https://qm.qq.com/q/Nb4TlwfnQy) (791558369, in cinese). Anche lì puoi fare domande, segnalare problemi o proporre funzionalità; su Discord il cinese ha un suo canale di chat e un suo forum di feedback.
- **Senza account GitHub**: scrivi a yudaotor@qq.com. Il pulsante con la busta sulla riga **Segnala un problema** in Impostazioni › Info inserisce la tua versione e macOS; fai clic con il tasto destro per copiare l’indirizzo.
- **Problemi di sicurezza**: segnalali in privato come descritto in [SECURITY.md](SECURITY.md), non in una issue pubblica.

## Disinstallazione

Trascinare `Lyrimuse.app` nel Cestino **non** basta. Il motore dei testi (nome del processo `lyrimuse-engine`) è
registrato in launchd come job `KeepAlive`, quindi il suo LaunchAgent rimane e
launchd continua a provare ad avviare un binario che non esiste più.

```sh
lyrimuse/scripts/uninstall.sh              # report only — shows what is installed
lyrimuse/scripts/uninstall.sh --services   # unregister both launchd jobs, keep your data
lyrimuse/scripts/uninstall.sh --purge      # also delete config, caches, logs and settings
```

Eseguito senza argomenti non cambia nulla; ti dice solo cosa c’è sul tuo
sistema. `--purge` elenca tutto quello che sta per eliminare, ti avvisa di quanti file di testo
esportati ci sono tra questi e ti chiede di digitare `yes`.

`--services` non tocca le impostazioni. `--purge` rimuove anche quelle
(`defaults delete me.yudaotor.lyrimuse`), perché lasciarle porta la
reinstallazione in un vicolo cieco: il LaunchAgent non c’è più, quindi il motore dei testi non è
installato, ma l’app crede ancora che la configurazione iniziale sia stata completata, così la procedura guidata che
lo installerebbe non compare mai e la scrivania resta ferma su “Cerco il testo…”.

## Struttura del progetto

Questo repository contiene l’app:

- [`lyrimuse/`](lyrimuse) — l’app vera e propria (Swift, SwiftUI + AppKit)
- [`lyrimuse-engine/`](lyrimuse-engine) — il motore in background che trova testi e illustrazioni e li passa all’app (Go); viene compilato e incluso nell’app in automatico

<details>
<summary>La pagina web facoltativa: due repository affiancati</summary>

L’esperienza web facoltativa vive in due repository affiancati, così puoi fare il fork di uno dei due senza toccare l’app:

| Repository | Ruolo |
|---|---|
| [`Yudaotor/nowplaying`](https://github.com/Yudaotor/nowplaying) | La pagina web “in riproduzione” da condividere, più un modello pronto per il fork |
| [`Yudaotor/nowplaying-workers`](https://github.com/Yudaotor/nowplaying-workers) | Il relay su Cloudflare Worker e il badge live per il README che ci stanno dietro, con una guida completa per configurare tutto da zero |

```
this repo (app + engine)  ──push──▶  nowplaying-workers (relay)  ◀──read──  nowplaying (web page)
```

</details>

## Ringraziamenti

Grazie a [LyricsX](https://github.com/ddddxxx/LyricsX), che ha mostrato cosa poteva essere il testo sulla scrivania del Mac.

<details>
<summary>I progetti open source e i dati della community su cui si basa Lyrimuse</summary>

- [media-control](https://github.com/ungive/media-control) e [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter): leggere cosa è in riproduzione su macOS
- [Sparkle](https://github.com/sparkle-project/Sparkle): aggiornamenti dall’app
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts): scorciatoie globali
- [OpenCC](https://github.com/BYVoid/OpenCC): conversione tra cinese semplificato e tradizionale
- [rime-cantonese](https://github.com/rime/rime-cantonese): Jyutping cantonese
- [AMLL TTML DB](https://github.com/amll-dev/amll-ttml-db): testi parola per parola creati dalla community
- [LRCLIB](https://lrclib.net): database aperto di testi sincronizzati
- [SponsorBlock](https://sponsor.ajay.app): segmenti non musicali nei video musicali

</details>

I testi delle licenze sono in [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES).
