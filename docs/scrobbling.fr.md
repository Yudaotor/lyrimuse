# Comment Lyrimuse scrobble vers Last.fm

*[English](scrobbling.md) · [简体中文](scrobbling.zh-CN.md) · [日本語](scrobbling.ja.md) · [한국어](scrobbling.ko.md) · [Español](scrobbling.es.md) · **Français** · [Deutsch](scrobbling.de.md) · [Italiano](scrobbling.it.md) · [Português (Brasil)](scrobbling.pt-BR.md) · [Tiếng Việt](scrobbling.vi.md) · [Русский](scrobbling.ru.md)*

## 1. Quand une écoute compte

Une écoute est envoyée dès que **toutes** ces conditions sont réunies :

| Règle | Valeur |
|---|---|
| Écoutée assez longtemps | la moitié du morceau, plafonnée à 240 s, ou 240 s si la durée est inconnue. Seuils plus stricts pour Last.fm uniquement : voir §1b |
| Morceau assez long | `≥ 30s` (les morceaux de durée inconnue sont acceptés). Désactivable : voir §1a |
| Pas une publicité | Les coupures publicitaires de Spotify sont détectées et ignorées |

La lecture est échantillonnée toutes les 5 secondes et le temps écoulé est mesuré sur l’horloge réelle : mettre en pause arrête le décompte, et avancer dans le morceau ne le gonfle pas. Si deux échantillons sont espacés de plus de 60 secondes (le Mac s’est mis en veille ou le moteur a redémarré), cet intervalle est écarté au lieu d’être compté.

Ces seuils suivent les [règles de scrobbling de Last.fm](https://www.last.fm/api/scrobbling).

### 1a. Morceaux de moins de 30 secondes

Réglages → Plateformes liées → Last.fm → *Règles* → **Scrobbler les morceaux de moins de 30 s** (`scrobble_short_tracks`, **désactivé** par défaut). La règle de Last.fm *« The track must be longer than 30 seconds »* (le morceau doit durer plus de 30 secondes) est une règle côté client : le serveur ne rejette pas les morceaux courts et n’a aucun code de refus « trop court ». Tous les scrobblers courants la respectent, et Lyrimuse aussi par défaut. Une fois l’option activée, les morceaux courts comptent dès qu’ils remplissent la règle de la moitié (un morceau de 20 secondes en demande 10). C’est un réglage **propre à Last.fm** : les morceaux courts sont scrobblés vers Last.fm (et notés dans le journal local qui alimente le rattrapage Last.fm), mais jamais envoyés à ListenBrainz, dont le comportement ne change pas dans un cas comme dans l’autre.

### 1b. Moment du scrobble

Réglages → Plateformes liées → Last.fm → *Règles* → **Moment du scrobble** (`lastfm_scrobble_point`, **50 %** par défaut). La part d’un morceau qui doit être écoutée avant qu’il soit scrobblé vers Last.fm :

| Réglage | Valeur | Scrobblé quand |
|---|---|---|
| **50 %** (par défaut) | `50` | la règle de Last.fm ci-dessus est remplie : la moitié du morceau, plafonnée à 4 minutes |
| 75 % / 90 % | `75` / `90` | 75 % / 90 % de la durée du morceau ont été écoutés : seul le temps écouté compte, sans plafond de 4 minutes |
| Fin du morceau | `end` | le morceau est lu jusqu’au bout ; avancer dans le morceau ne compte pas |

La règle de Last.fm est un minimum, il n’existe donc aucun réglage sous 50 %. C’est un réglage **propre à Last.fm** : ListenBrainz et le relais web envoient toujours au point des 50 % ; seul le scrobble Last.fm (et le journal local qui alimente le rattrapage Last.fm) attend le point choisi. Un morceau passé avant ce point n’envoie rien à Last.fm : c’est le réglage qui fait son travail, pas un scrobble perdu. Les morceaux de durée inconnue suivent la règle par défaut.

*Fin du morceau* se juge sur la dernière position de lecture observée au changement de morceau : à moins de 12 secondes de la fin (10 % de la durée pour les morceaux courts), le morceau compte comme lu jusqu’au bout, si bien qu’un fondu enchaîné du lecteur ou une transition sans blanc ne bloque pas le scrobble.

## 2. Ce qui est envoyé

`track.scrobble` écrit l’entrée permanente dans votre historique ; `track.updateNowPlaying` affiche l’indicateur « en cours d’écoute » et n’enregistre rien.

| Champ | `track.scrobble` | `track.updateNowPlaying` |
|---|---|---|
| `artist` | ✅ | ✅ |
| `track` | ✅ | ✅ |
| `timestamp` | ✅ | — |
| `album` | s’il n’est pas vide | s’il n’est pas vide |
| `duration` | si elle est connue | si elle est connue |

Rien d’autre n’arrive à Last.fm. Son API accepte aussi `mbid`, `albumArtist`, `trackNumber`, `chosenByUser`, `streamId` et `context` sur un scrobble ; Lyrimuse n’en envoie aucun.

## 3. Ce qui n’est pas réécrit

Par la voie ListenBrainz, et avec les modes *Tout* et *Premier seulement* de Last.fm, les noms d’artiste, de morceau et d’album sont envoyés exactement comme le lecteur les a indiqués. (Le mode *Intelligent* de Last.fm réécrit l’artiste et le morceau pour correspondre à l’entrée du catalogue : voir la section suivante.)

Le seul traitement appliqué est le nettoyage des caractères invisibles : les espaces insécables et pleine chasse deviennent des espaces ordinaires, les caractères de largeur nulle et les BOM sont supprimés, les suites d’espaces sont réduites à une seule, et les espaces en début et en fin sont retirés. Sans cela, une espace insécable invisible crée une entité d’artiste distincte sur Last.fm.

Rien de visible n’est modifié : ni la casse, ni le chinois traditionnel ou simplifié, ni les sous-titres entre parenthèses, ni les crédits à plusieurs artistes. `PRINCE` reste `PRINCE`, `無所謂` reste `無所謂`, et `一口 (The Day You Left Me)` garde son sous-titre.

Pourquoi il n’y a pas, par défaut, de recherche externe pour « normaliser » les noms :

- Lyrimuse le faisait autrefois. L’audit d’une vraie bibliothèque d’environ 2 500 morceaux a relevé près de 200 noms d’artiste réécrits, dont `USA for Africa` → `Xtc Planet` et `LBI利比` → `Safehse`. Les scrobbles déjà écrits sur une page d’artiste publique de Last.fm ne peuvent plus être corrigés ensuite : la base de corrections est figée.
- Le guide de scrobbling de Last.fm le dit à deux reprises : *« Do not use the corrections returned by the now playing service as input for the scrobble request, unless they have been explicitly approved by the user. »* (n’utilisez pas les corrections renvoyées par le service « now playing » dans la requête de scrobble, sauf si l’utilisateur les a explicitement approuvées). Son option `autocorrect` est [documentée comme obsolète](https://support.last.fm/t/scrobbles-of-japanese-artists-getting-separated-by-romanization-of-their-name/119906).
- Sur neuf scrobblers open source étudiés (Web Scrobbler, Pano Scrobbler, Navidrome, Maloja, rescrobbled, mpdscribble, mpdas, Koito, multi-scrobbler), aucun ne réécrit par défaut les noms d’artiste à partir d’une recherche externe.

## 4. Mode de correspondance

Réglages → Plateformes liées → Last.fm → *Règles* → **Mode de correspondance** (`lastfm_match_mode` dans `~/Library/Application Support/me.yudaotor.lyrimuse/lyrimuse-features.json`) :

| Mode | Valeur | Effet |
|---|---|---|
| **Intelligent** (par défaut sur une nouvelle installation) | `smart` | Trouve l’entrée de ce morceau dans le catalogue de Last.fm et envoie l’artiste et le titre de cette entrée (voir plus bas) |
| Personnalisé | `custom` | Vous choisissez ce qui peut changer : voir plus bas |
| **Brut** (par défaut sur une installation existante) | `raw` | Exactement ce que le lecteur indique, sans appel réseau |

*Personnalisé* ajoute deux lignes, une par champ :

| Ligne | Option | Effet |
|---|---|---|
| **Titre** | Correspondance | Le titre peut être remplacé par la graphie de l’entrée du catalogue, et ` - Single` / ` - EP` est retiré de l’album (`lastfm_match_track`) |
| | Brut | Le titre est envoyé tel qu’indiqué |
| **Artiste** | Correspondance | L’artiste peut être remplacé par la graphie de l’entrée du catalogue (`lastfm_match_artist`) |
| | Premier seulement | Réduit un crédit commun à son premier artiste (`Khalil Fong & Fiona Sit` → `Khalil Fong`) : simple traitement de chaîne, sans appel réseau (`lastfm_match_first_artist_only`) |
| | Brut | L’artiste est envoyé tel qu’indiqué |

Si *Correspondance* n’est choisi que sur une des deux lignes, **un candidat n’est retenu que si l’autre champ correspond déjà** : sinon on obtiendrait une combinaison qui n’existe pas dans le catalogue, et l’écoute retomberait sur une entrée fantôme avec un seul auditeur : vous.

*Premier seulement* diffère de *Correspondance* : il ne s’applique **que si rien n’a été trouvé**. Une graphie trouvée est déjà l’entrée que Last.fm reconnaît, et la tronquer en ferait une entrée qui n’existe pas : `Hall & Oates / Maneater` (800 000 auditeurs) deviendrait `Hall`. Ainsi, Titre *Brut* avec Artiste *Premier seulement* reproduit octet pour octet l’ancien mode *Premier seulement*, toujours sans appel réseau.

*Brut* reste la valeur par défaut partout où un `lyrimuse-features.json` existe déjà, car tronquer un crédit est irréversible : Fiona Sit disparaît de votre historique. L’option du même nom dans Navidrome (`Lastfm.ScrobbleFirstArtistOnly`) est elle aussi désactivée par défaut.

Le découpage est prudent : `/` est traité à part de `,` et `&`, si bien que `K/DA` et `AC/DC` ne sont pas coupés en `K` et `AC`.

### Mode Intelligent

Ce que le lecteur indique et la façon dont le catalogue de Last.fm nomme le même enregistrement ne sont souvent pas les mêmes caractères, et envoyer tel quel fait atterrir l’écoute sur une entrée « fantôme » : pas de MBID, pas d’album, durée nulle, un seul auditeur : vous. Mesuré sur 《那个女孩》 de David Tao : le lecteur indique `陶喆, 卢广仲 / 那个女孩`, que Last.fm n’a pas du tout ; la version simplifiée `陶喆 / 那个女孩` a 126 auditeurs ; et la vraie entrée du morceau est la version traditionnelle **`陶喆 / 那個女孩`, avec 889 auditeurs, 4 580 écoutes et une durée au catalogue**. L’`autocorrect` de Last.fm n’y change rien : il ne fait pas le lien entre chinois traditionnel et simplifié.

Le mode *Intelligent* recherche donc le morceau avant de l’envoyer :

1. `track.getInfo` tel qu’indiqué. **S’il a un MBID**, rien n’est touché, définitivement. Un MBID est le signe le plus sûr d’une identité réelle au catalogue, et c’est ce qui empêche une collaboration correctement créditée (Hall & Oates) d’être déplacée vers une page solo parce qu’elle a « plus d’auditeurs ».
2. Sinon, les candidats viennent **exactement de trois endroits** : tel qu’indiqué, le premier artiste crédité, et les entrées de cet artiste dont le titre se ramène à la même clé (`artist.getTopTracks`, déjà trié par nombre d’auditeurs).
3. Parmi les candidats que Last.fm a réellement catalogués (un MBID, ou au moins 500 auditeurs, ou une durée au catalogue ; une entrée fantôme n’a aucun des trois), le plus écouté l’emporte, sa durée est vérifiée, et ce sont son artiste et son morceau qui sont envoyés : décidé une fois, gardé pour toujours. Si aucun candidat ne convient, le morceau est envoyé tel qu’indiqué et revérifié au bout de 90 jours.

Il n’utilise volontairement **pas** `track.search` : cette méthode cherche la chaîne littérale, ce qui ne trouve pas l’entrée en chinois traditionnel et n’exclut pas les morceaux homonymes, comme `张泽熙 / 那个女孩`. La normalisation du titre ne gomme que les différences de graphie d’un même enregistrement : traditionnel ou simplifié, variantes de caractères, diacritiques, artistes invités (`(feat. X)`) et mentions de réédition (`(Remastered 2014)`, `(Bonus Track)`). **Les mentions Live, Remix, acoustique et instrumental sont toujours conservées** : ce sont d’autres enregistrements. Le candidat retenu doit aussi passer une vérification de durée (refusé si les deux côtés connaissent une durée et qu’elles diffèrent de plus de 8 secondes).

Mesuré sur 240 morceaux réels : 33 réécrits, 162 envoyés tels quels, 45 indécidables. Exemples :

| Indiqué | Envoyé | Auditeurs |
|---|---|---|
| `周杰倫 / 手写的从前` | `周杰倫 / 手寫的從前` | 100 → 4 515 |
| `Wang Leehom / 奇遇的起点` | `王力宏 / 奇遇的起點` | 1 → 144 |
| `SZA & Phoebe Bridgers / Ghost in the Machine` | `SZA / Ghost in the Machine (feat. Phoebe Bridgers)` | 175 → 856 376 |
| `PRINCE / Walk Don't Walk (2023 Remaster)` | `Prince / Walk Don't Walk` | 231 → 16 178 |

Tout échec de recherche (réseau, limite de débit, réponse mal formée, liste de morceaux injoignable) envoie les tags tels qu’indiqués et ne met rien en cache, pour qu’un simple raté ne devienne jamais une décision définitive. Les décisions sont stockées dans `~/Library/Application Support/me.yudaotor.lyrimuse/lyrimuse-lastfm-catalog.json` avec les éléments qui les ont motivées ; supprimez le fichier pour tout redécider.

Les anciennes clés sont toujours lues mais plus écrites, et migrent sans changer le comportement : `lastfm_scrobble_artist_mode` fait correspondre `smart` → Intelligent, `all` → Brut, et `first` → Personnalisé avec Titre sur Brut et Artiste sur Premier seulement ; l’ancien booléen `lastfm_scrobble_first_artist_only=true` équivaut à `first`.

## 5. Si un scrobble échoue

Les échecs sont classés, car la bonne réaction diffère. « L’enregistrer », ci-dessous, signifie que l’écoute est écrite dans un journal local, qu’un **rattrapage** (lancé à la main avec **Rattraper**, à côté du nombre d’« écoutes à envoyer » sous vos écoutes récentes) peut envoyer plus tard.

| Ce qui s’est passé | Ce que nous faisons |
|---|---|
| La requête n’a de façon certaine jamais quitté votre Mac (DNS, échec de connexion) | L’enregistrer ; le rattrapage peut l’envoyer |
| Le serveur l’a refusée pour une raison qui garantit qu’elle n’a pas été stockée (identifiants invalides, limite de débit) | L’enregistrer ; le rattrapage peut l’envoyer |
| Envoyée, mais avec un résultat inconnu (délai dépassé, connexion coupée, erreur serveur ambiguë) | L’enregistrer, mais le rattrapage ne la relancera **jamais** automatiquement |
| Le serveur a reçu le morceau et en a rejeté le contenu lui-même | Ne pas l’enregistrer ; afficher la raison réelle donnée par le serveur |

La troisième ligne existe parce qu’un délai dépassé peut vouloir dire que Last.fm a stocké l’écoute et que seul l’accusé de réception s’est perdu. Réessayer créerait un doublon à supprimer à la main, donc un échec ambigu n’est jamais relancé automatiquement.

Le rattrapage ne remonte que sur **13 jours**. Une fois qu’une écoute a été tentée, la voie en temps réel ne l’envoie plus jamais : l’écoute est marquée comme tentée *avant* le départ de la requête, et non après sa réussite, si bien qu’un plantage en pleine requête ne peut pas produire un second envoi.

## 6. Où se fait la fusion

Last.fm reçoit ce que le lecteur a indiqué, donc une bibliothèque qui désigne la même personne à la fois par `Khalil Fong` et `方大同` y affichera deux artistes.

Dans Lyrimuse, le nombre d’écoutes, les classements et les numéros de « Écoute n° N » les fusionnent, grâce au rapprochement traditionnel/simplifié, aux alias de noms romanisés, au retrait du bruit de catalogue (`(Remastered 2014)`, `(feat. …)`, `(Explicit)`) et à une table d’alias par artiste. La fusion se fait en local plutôt qu’avant l’envoi, car une mauvaise fusion locale s’annule par une actualisation, alors qu’un mauvais scrobble est une modification permanente d’une page publique.

## 7. Questions fréquentes

**Puis-je utiliser Lyrimuse sans scrobbler ?**
Oui, c’est le comportement par défaut : rien n’est scrobblé tant que vous n’avez pas connecté de compte Last.fm dans Réglages → Plateformes liées. La recherche des paroles et des illustrations est indépendante : elle envoie le nom de l’artiste et du morceau aux sources de paroles publiques (Netease, QQ, Kugou, LRCLIB, Musixmatch, AMLL), qu’un compte soit connecté ou non. Ces sources peuvent être restreintes ou désactivées dans les Réglages.

**Pourquoi le même artiste apparaît-il deux fois sur mon profil Last.fm ?**
Votre lecteur a indiqué deux noms différents, et les deux ont été envoyés tels quels. Lyrimuse les fusionne dans ses propres statistiques ; pour les fusionner sur Last.fm, il faut y modifier les scrobbles.

**Les noms peuvent-ils être nettoyés avant l’envoi ?**
Non. Si vous le souhaitez, la forme viable est une table de règles modifiable par l’utilisateur plutôt qu’une recherche automatique : voyez comment [Maloja](https://github.com/krateng/maloja) s’y prend.

**Et les écoutes de mon iPhone ?**
Lyrimuse ne les envoie jamais à Last.fm ; elles y arrivent par le scrobbling propre à Apple. Lyrimuse les relit pour qu’elles figurent dans ses statistiques à côté des écoutes sur Mac.

**Peut-on fusionner des artistes sur Last.fm sans réécrire les noms ?**
Pas via l’API. Le paramètre `mbid` de Last.fm identifie un *morceau*, pas un artiste : aucun champ ne permet de dire « ces deux noms sont la même personne » en gardant les deux noms intacts.

**Le journal d’écoute local fait-il doublon avec mes scrobbles ?**
Non. Il n’enregistre une écoute que si aucun compte Last.fm n’est connecté, ou si un envoi a échoué. Avec Last.fm connecté et fonctionnel, il reste vide.

---

*Implémentation : [`lyrimuse-engine/lastfm.go`](../lyrimuse-engine/lastfm.go)
(`resolveScrobbleArtist`, `scrobble`, `updateNowPlaying`),
[`lyrimuse-engine/poller.go`](../lyrimuse-engine/poller.go)
(`listenThreshold`, `recordFailedMirror`).*
