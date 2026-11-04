# Come Lyrimuse fa lo scrobble su Last.fm

*[English](scrobbling.md) · [简体中文](scrobbling.zh-CN.md) · [日本語](scrobbling.ja.md) · [한국어](scrobbling.ko.md) · [Español](scrobbling.es.md) · [Français](scrobbling.fr.md) · [Deutsch](scrobbling.de.md) · **Italiano** · [Português (Brasil)](scrobbling.pt-BR.md) · [Tiếng Việt](scrobbling.vi.md) · [Русский](scrobbling.ru.md)*

## 1. Quando un ascolto conta

Un ascolto viene inviato quando valgono **tutte** queste condizioni:

| Regola | Valore |
|---|---|
| Riprodotto abbastanza a lungo | metà del brano, con un massimo di 240 s, oppure 240 s se la durata non è nota. Soglie più rigide solo per Last.fm: vedi §1b |
| Brano abbastanza lungo | `≥ 30s` (i brani di durata sconosciuta passano). Si può disattivare: vedi §1a |
| Non è una pubblicità | Le pause pubblicitarie di Spotify vengono rilevate e saltate |

La riproduzione viene campionata ogni 5 secondi e il tempo trascorso si conta sull’orologio reale, quindi mettere in pausa ferma il conteggio e spostarsi avanti nel brano non lo gonfia. Se tra due campioni passano più di 60 secondi (il Mac è andato in stop o il motore è stato riavviato), quell’intervallo viene scartato invece che conteggiato.

Queste soglie corrispondono alle [linee guida di Last.fm sullo scrobbling](https://www.last.fm/api/scrobbling).

### 1a. Brani sotto i 30 secondi

Impostazioni → Servizi collegati → Last.fm → *Regole* → **Scrobble dei brani sotto i 30 secondi** (`scrobble_short_tracks`, **disattivato** per impostazione predefinita). La regola di Last.fm *“The track must be longer than 30 seconds”* (il brano deve durare più di 30 secondi) è una regola lato client: il server non rifiuta i brani brevi e non ha un codice di scarto per “troppo breve”. Tutti i principali client di scrobbling la rispettano, quindi anche Lyrimuse lo fa per impostazione predefinita. Attivando l’opzione, i brani brevi contano non appena superano la regola della metà (un brano di 20 secondi ne richiede 10). È un’impostazione **solo per Last.fm**: i brani brevi vengono scrobblati su Last.fm (e annotati nel registro locale da cui parte il recupero verso Last.fm), ma non vengono mai inviati a ListenBrainz, il cui comportamento resta invariato in ogni caso.

### 1b. Momento dello scrobble

Impostazioni → Servizi collegati → Last.fm → *Regole* → **Momento scrobble** (`lastfm_scrobble_point`, predefinito **50%**). Quanto di un brano deve essere riprodotto prima che venga scrobblato su Last.fm:

| Impostazione | Valore | Scrobble quando |
|---|---|---|
| **50%** (predefinito) | `50` | vale la regola di Last.fm vista sopra: metà del brano, con un massimo di 4 minuti |
| 75% / 90% | `75` / `90` | è stato riprodotto il 75% / 90% della durata del brano: conta solo il tempo riprodotto, senza il limite di 4 minuti |
| Fine brano | `end` | il brano viene riprodotto fino alla fine; saltare in avanti non conta |

La regola di Last.fm è una soglia minima, quindi non esiste un’impostazione sotto il 50%. È **solo per Last.fm**: ListenBrainz e il relay web inviano comunque al 50%; solo lo scrobble su Last.fm (e il registro locale da cui parte il recupero verso Last.fm) aspetta il punto scelto. Un brano saltato prima di quel punto non invia nulla a Last.fm: è l’impostazione che fa il suo lavoro, non uno scrobble perso. I brani di durata sconosciuta seguono la regola predefinita.

*Fine brano* si valuta in base all’ultima posizione di riproduzione osservata quando cambia il brano: trovarsi entro 12 secondi dalla fine (il 10% della durata per i brani brevi) conta come riprodotto fino in fondo, così la dissolvenza incrociata di un player o una transizione senza pause non blocca lo scrobble.

## 2. Cosa viene inviato

`track.scrobble` scrive la voce permanente nella tua cronologia; `track.updateNowPlaying` imposta l’indicatore “in ascolto ora” e non salva nulla.

| Campo | `track.scrobble` | `track.updateNowPlaying` |
|---|---|---|
| `artist` | ✅ | ✅ |
| `track` | ✅ | ✅ |
| `timestamp` | ✅ | — |
| `album` | se non è vuoto | se non è vuoto |
| `duration` | se è nota | se è nota |

Nient’altro arriva a Last.fm. La sua API accetta in uno scrobble anche `mbid`, `albumArtist`, `trackNumber`, `chosenByUser`, `streamId` e `context`; Lyrimuse non ne invia nessuno.

## 3. Cosa non viene riscritto

Nel percorso verso ListenBrainz, e nelle modalità *Tutti* e *Solo il primo* di Last.fm, i nomi di artista, brano e album vengono inviati esattamente come li ha riportati il player. (La modalità *Smart* di Last.fm riscrive artista e brano per farli corrispondere alla voce del catalogo: vedi la sezione successiva.)

L’unica elaborazione applicata è la pulizia dei caratteri invisibili: gli spazi unificatori e quelli a larghezza piena diventano spazi normali, i caratteri a larghezza zero e i BOM vengono rimossi, le sequenze di spazi si riducono a uno solo e gli spazi iniziali e finali vengono tolti. Senza questa pulizia, uno spazio unificatore invisibile crea un artista separato su Last.fm.

Non cambia niente di visibile: né le maiuscole, né il cinese tradizionale rispetto al semplificato, né i sottotitoli tra parentesi, né i crediti con più artisti. `PRINCE` resta `PRINCE`, `無所謂` resta `無所謂`, e `一口 (The Day You Left Me)` mantiene il suo sottotitolo.

Perché per impostazione predefinita non c’è una ricerca esterna che “normalizzi” i nomi:

- Lyrimuse faceva proprio questo. Un controllo su una libreria reale di circa 2.500 brani ha trovato circa 200 nomi di artista riscritti, tra cui `USA for Africa` → `Xtc Planet` e `LBI利比` → `Safehse`. Gli scrobble già scritti su una pagina artista pubblica di Last.fm non si possono correggere a posteriori: il database delle correzioni è congelato.
- La guida allo scrobbling di Last.fm lo dice due volte: *“Do not use the corrections returned by the now playing service as input for the scrobble request, unless they have been explicitly approved by the user.”* (non usare le correzioni restituite dal servizio “in ascolto ora” come input della richiesta di scrobble, a meno che l’utente non le abbia approvate esplicitamente). Il suo flag `autocorrect` è [documentato come legacy](https://support.last.fm/t/scrobbles-of-japanese-artists-getting-separated-by-romanization-of-their-name/119906).
- Tra nove client di scrobbling open source esaminati (Web Scrobbler, Pano Scrobbler, Navidrome, Maloja, rescrobbled, mpdscribble, mpdas, Koito, multi-scrobbler), nessuno riscrive per impostazione predefinita i nomi degli artisti in base a una ricerca esterna.

## 4. Modalità di associazione

Impostazioni → Servizi collegati → Last.fm → *Regole* → **Modalità di associazione** (`lastfm_match_mode` in `~/Library/Application Support/me.yudaotor.lyrimuse/lyrimuse-features.json`):

| Modalità | Valore | Effetto |
|---|---|---|
| **Smart** (predefinita nelle nuove installazioni) | `smart` | Trova la voce di questo brano nel catalogo di Last.fm e invia artista e titolo di quella voce (vedi sotto) |
| Personalizzato | `custom` | Scegli quali parti possono cambiare: vedi sotto |
| **Originale** (predefinita nelle installazioni esistenti) | `raw` | Esattamente ciò che riporta il player, senza chiamate di rete |

*Personalizzato* aggiunge due righe, una per campo:

| Riga | Opzione | Effetto |
|---|---|---|
| **Titolo** | Corrispondenza | Il titolo può essere sostituito con la grafia della voce del catalogo, e ` - Single` / ` - EP` viene tolto dall’album (`lastfm_match_track`) |
| | Originale | Il titolo viene inviato come riportato |
| **Artista** | Corrispondenza | L’artista può essere sostituito con la grafia della voce del catalogo (`lastfm_match_artist`) |
| | Solo il primo | Riduce un credito congiunto al primo artista (`Khalil Fong & Fiona Sit` → `Khalil Fong`): pura elaborazione del testo, senza chiamate di rete (`lastfm_match_first_artist_only`) |
| | Originale | L’artista viene inviato come riportato |

Se *Corrispondenza* è scelta in una sola delle due righe, **un candidato viene accettato solo se l’altro campo corrisponde già**: altrimenti il risultato sarebbe una combinazione che non esiste nel catalogo, e si finirebbe di nuovo su una voce fantasma con un solo ascoltatore: tu.

*Solo il primo* è diverso da *Corrispondenza*: si applica **solo quando non è stata trovata nessuna corrispondenza**. Una grafia trovata è già la voce che Last.fm riconosce, e troncarla la trasformerebbe in una voce che non esiste: `Hall & Oates / Maneater` (800.000 ascoltatori) diventerebbe `Hall`. Quindi Titolo *Originale* con Artista *Solo il primo* equivale byte per byte alla vecchia modalità *Solo il primo*, sempre senza chiamate di rete.

*Originale* resta la modalità predefinita dove esiste già un `lyrimuse-features.json`, perché troncare un credito è irreversibile: toglie Fiona Sit dalla tua cronologia. Anche l’opzione omonima di Navidrome (`Lastfm.ScrobbleFirstArtistOnly`) è disattivata per impostazione predefinita.

La separazione è prudente: `/` viene gestita separatamente da `,` e `&`, quindi `K/DA` e `AC/DC` non vengono divisi in `K` e `AC`.

### Modalità Smart

Ciò che riporta il player e il nome con cui il catalogo di Last.fm indica la stessa registrazione spesso non hanno gli stessi caratteri, e inviarlo così com’è fa finire l’ascolto su una voce “fantasma”: senza MBID, senza album, con durata zero e un solo ascoltatore: tu. Misurato su 《那个女孩》 di David Tao: il player riporta `陶喆, 卢广仲 / 那个女孩`, che Last.fm non ha affatto; la versione in cinese semplificato `陶喆 / 那个女孩` ha 126 ascoltatori; e la vera voce del brano è quella in cinese tradizionale **`陶喆 / 那個女孩`: 889 ascoltatori, 4.580 ascolti, con una durata in catalogo**. L’`autocorrect` di Last.fm non aiuta: non collega il cinese tradizionale e quello semplificato.

Per questo *Smart* cerca il brano prima di inviarlo:

1. `track.getInfo` così come riportato. **Se ha un MBID**, non si tocca nulla, per sempre. Un MBID è il segnale più forte di un’identità reale nel catalogo, ed è ciò che impedisce a una collaborazione accreditata correttamente (Hall & Oates) di essere spostata su una pagina solista perché ha “più ascoltatori”.
2. Altrimenti i candidati vengono raccolti da **esattamente tre fonti**: come riportato, il primo artista accreditato e le voci di quell’artista il cui titolo normalizzato dà la stessa chiave (`artist.getTopTracks`, già ordinato per ascoltatori).
3. Tra i candidati che Last.fm ha davvero in catalogo (un MBID, oppure ≥ 500 ascoltatori, oppure una durata in catalogo; una voce fantasma non ha nessuna delle tre cose), vince quello più ascoltato, se ne verifica la durata, e vengono inviati il suo artista e il suo brano: si decide una volta e si mantiene per sempre. Se nessun candidato è idoneo, il brano viene inviato come riportato e ricontrollato dopo 90 giorni.

Di proposito **non** usa `track.search`: cerca la stringa letterale, quindi non trova la voce in cinese tradizionale né esclude i risultati con lo stesso titolo ma di un altro brano, come `张泽熙 / 那个女孩`. La normalizzazione del titolo unifica solo le differenze di grafia di una stessa registrazione: cinese tradizionale e semplificato, varianti dei caratteri, segni diacritici, crediti degli ospiti (`(feat. X)`) e indicazioni di riedizione (`(Remastered 2014)`, `(Bonus Track)`). **Le indicazioni Live, Remix, acustico e strumentale vengono sempre mantenute**: sono registrazioni diverse. Il candidato vincente deve anche superare un controllo della durata (viene scartato se entrambe le parti conoscono una durata e le due durate differiscono di più di 8 secondi).

Misurato su 240 brani reali: 33 riscritti, 162 inviati così com’erano, 45 indecidibili. Esempi:

| Riportato | Inviato | Ascoltatori |
|---|---|---|
| `周杰倫 / 手写的从前` | `周杰倫 / 手寫的從前` | 100 → 4.515 |
| `Wang Leehom / 奇遇的起点` | `王力宏 / 奇遇的起點` | 1 → 144 |
| `SZA & Phoebe Bridgers / Ghost in the Machine` | `SZA / Ghost in the Machine (feat. Phoebe Bridgers)` | 175 → 856.376 |
| `PRINCE / Walk Don't Walk (2023 Remaster)` | `Prince / Walk Don't Walk` | 231 → 16.178 |

Qualsiasi errore nella ricerca (rete, limite di richieste, risposta malformata, elenco dei brani irraggiungibile) invia i tag come riportati e non salva nulla in cache, così un intoppo non diventa mai una decisione permanente. Le decisioni vengono salvate in `~/Library/Application Support/me.yudaotor.lyrimuse/lyrimuse-lastfm-catalog.json` insieme ai dati che le hanno prodotte; elimina il file per far ridecidere tutto.

Le chiavi legacy vengono ancora lette ma non più scritte, e migrano senza cambiare comportamento: `lastfm_scrobble_artist_mode` mappa `smart` → Smart, `all` → Originale e `first` → Personalizzato con Titolo su Originale e Artista su Solo il primo; il booleano più vecchio `lastfm_scrobble_first_artist_only=true` equivale a `first`.

## 5. Se uno scrobble non riesce

Gli errori vengono classificati, perché la risposta corretta cambia da caso a caso. Qui sotto “annotarlo” significa che l’ascolto viene scritto in un registro locale, che un **recupero** (avviato a mano con **Recupera** accanto al conteggio “ascolti da inviare” sotto i tuoi ascolti recenti) può inviare in seguito.

| Cosa è successo | Cosa facciamo |
|---|---|
| La richiesta di sicuro non è mai uscita dal tuo Mac (DNS, connessione non riuscita) | Lo annotiamo; il recupero può inviarlo |
| Il server l’ha rifiutata per un motivo che garantisce che non sia stata salvata (credenziali non valide, limite di richieste) | Lo annotiamo; il recupero può inviarlo |
| Inviata, ma l’esito è ignoto (timeout, connessione interrotta, errore del server ambiguo) | Lo annotiamo, ma il recupero **non** lo riproverà **mai** in automatico |
| Il server ha ricevuto il brano e ne ha rifiutato il contenuto | Non lo annotiamo; mostriamo il motivo effettivo indicato dal server |

La terza riga esiste perché un timeout può significare che Last.fm ha salvato l’ascolto e si è persa solo la ricevuta. Riprovare creerebbe un duplicato da eliminare a mano, quindi un errore ambiguo non viene mai riprovato in automatico.

Il recupero risale solo a **13 giorni** fa. Una volta tentato l’invio di un ascolto, il percorso in tempo reale non lo invia mai più: l’ascolto viene segnato come tentato *prima* che parta la richiesta, non dopo che è riuscita, così un crash a metà richiesta non può produrre un secondo invio.

## 6. Dove avviene l’unione

Last.fm riceve ciò che ha riportato il player, quindi una libreria che riporta la stessa persona sia come `Khalil Fong` sia come `方大同` mostrerà lì due artisti.

All’interno di Lyrimuse, i conteggi degli ascolti, le classifiche e i numeri “N° ascolto” li uniscono, tramite la normalizzazione tra cinese tradizionale e semplificato, gli alias dei nomi romanizzati, la rimozione del rumore del catalogo (`(Remastered 2014)`, `(feat. …)`, `(Explicit)`) e una tabella di alias per artista. L’unione avviene in locale anziché prima dell’invio perché un’unione locale sbagliata si annulla con un aggiornamento, mentre uno scrobble sbagliato è una modifica permanente a una pagina pubblica.

## 7. Domande frequenti

**Posso usare Lyrimuse senza fare scrobble?**
Sì, è l’impostazione predefinita: non viene scrobblato nulla finché non colleghi un account Last.fm in Impostazioni → Servizi collegati. La ricerca di testi e illustrazioni è una cosa separata: invia il nome dell’artista e del brano ai fornitori pubblici di testi (Netease, QQ, Kugou, LRCLIB, Musixmatch, AMLL) che un account sia collegato o no. Queste fonti si possono limitare o disattivare in Impostazioni.

**Perché lo stesso artista compare due volte nel mio profilo Last.fm?**
Il tuo player ha riportato due nomi diversi, ed entrambi sono stati inviati come riportati. Lyrimuse li unisce nelle sue statistiche; per unirli su Last.fm bisogna modificare lì gli scrobble.

**Si possono ripulire i nomi prima dell’invio?**
No. Se ti serve, la soluzione praticabile è una tabella di regole modificabile dall’utente invece di una ricerca automatica: guarda come fa [Maloja](https://github.com/krateng/maloja).

**E gli ascolti dal mio iPhone?**
Lyrimuse non li invia mai a Last.fm; ci arrivano tramite lo scrobbling di Apple. Lyrimuse li rilegge perché compaiano nelle sue statistiche insieme agli ascolti sul Mac.

**Si possono unire artisti su Last.fm senza riscrivere i nomi?**
Non tramite l’API. Il parametro `mbid` di Last.fm identifica un *brano*, non un artista, quindi non esiste un campo per dire “questi due nomi sono la stessa persona” lasciando intatti entrambi i nomi.

**Il registro locale degli ascolti duplica i miei scrobble?**
No. Registra un ascolto solo quando non è collegato nessun account Last.fm o quando un invio non è riuscito. Con Last.fm collegato e funzionante resta vuoto.

---

*Implementazione: [`lyrimuse-engine/lastfm.go`](../lyrimuse-engine/lastfm.go)
(`resolveScrobbleArtist`, `scrobble`, `updateNowPlaying`),
[`lyrimuse-engine/poller.go`](../lyrimuse-engine/poller.go)
(`listenThreshold`, `recordFailedMirror`).*
