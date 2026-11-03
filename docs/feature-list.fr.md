<!-- Généré par scripts/gen-feature-list.py à partir de shared/feature-list.json et shared/settings-catalog.json ; pour modifier la liste, modifiez ces fichiers. -->

# Liste des fonctionnalités de Lyrimuse

[English](feature-list.md) · [简体中文](feature-list.zh-CN.md) · [繁體中文](feature-list.zh-Hant.md) · [日本語](feature-list.ja.md) · [한국어](feature-list.ko.md) · [Español](feature-list.es.md) · Français · [Deutsch](feature-list.de.md) · [Italiano](feature-list.it.md) · [Português (Brasil)](feature-list.pt-BR.md)

Lyrimuse est une app Mac open source (GPL-3.0) de paroles synchronisées mot à mot, pour macOS 14 ou ultérieur sur Apple Silicon et Intel. Elle affiche les paroles d’Apple Music, Spotify, QQ Music, NetEase Cloud Music, Kugou, Soda Music, KKBOX, Amazon Music, LX Music, Kaset, reAMP, VOX, Pine Player, foobar2000, ainsi que de YouTube Music ou Spotify Web dans un navigateur : en flottant sur le bureau, près de l’encoche, dans la barre des menus, sur la Touch Bar ou dans une fenêtre des paroles complète, avec traductions et romanisation (pinyin, jyutping cantonais, romaji japonais, romanisation du coréen). Elle scrobble vers Last.fm et ListenBrainz et peut afficher sur Discord ce que vous écoutez. L’interface est disponible en anglais, chinois simplifié, chinois traditionnel, japonais, coréen, espagnol, français, allemand, italien et portugais du Brésil.

Cette liste recense chaque fonctionnalité de Lyrimuse : ce qu’elle fait, où la trouver dans les Réglages et si elle est activée ou non après l’installation ; tous les réglages de la fenêtre Réglages figurent à la fin. Elle est tenue à jour avec le code à chaque changement de fonctionnalité.

## Sommaire

- [Désactivées tant que vous ne les activez pas](#section-off-by-default)
- [Recherche des paroles](#section-lyrics)
- [Traduction, romanisation et découpage des lignes](#section-text)
- [Où s’affichent les paroles, et leur apparence](#section-display)
- [Lecteurs et lecture](#section-players)
- [Scrobbles, Last.fm et partage](#section-listening)
- [Au quotidien](#section-general)
- [Tous les réglages](#section-all-settings)

<a id="section-off-by-default"></a>

## Désactivées tant que vous ne les activez pas

Ces fonctionnalités restent désactivées après l’installation. Activez-les d’abord dans les Réglages (certaines demandent aussi un compte ou une autorisation) :

| Fonctionnalité | Où l’activer |
|---|---|
| [Les paroles d’Apple Music](#feature-apple-music-lyrics) | Réglages › Paroles › Source › Sources de paroles |
| [Utiliser les paroles déjà enregistrées par le lecteur](#feature-player-local-lyrics) | Réglages › Lecteur › Autorisations et services › Accès complet au disque |
| [Privilégier les paroles du fichier](#feature-prefer-local-file-lyrics) | Réglages › Paroles › Source › Privilégier les paroles du fichier |
| [Verrouiller les paroles choisies](#feature-lock-hand-picked) | Réglages › Paroles › Source › Verrouiller les paroles choisies |
| [Traduire si aucune traduction](#feature-machine-translation) | Réglages › Paroles › Langue › Traduire si non fournie |
| [Couper les lignes longues, joindre les courtes](#feature-split-join-lines) | Réglages › Paroles › Minutage et coupures › Couper les lignes longues |
| [Paroles de l’encoche](#feature-notch-lyrics) | Réglages › Affichage des paroles › Encoche › Paroles de l’encoche |
| [Paroles de la barre des menus](#feature-menu-bar-lyrics) | Réglages › Affichage des paroles › Barre des menus › Paroles de la barre des menus |
| [Paroles Touch Bar](#feature-touch-bar-lyrics) | Réglages › Affichage des paroles › Touch Bar › Paroles Touch Bar |
| [Surbrillance HDR de la fenêtre des paroles](#feature-lyrics-window-hdr) | Réglages › Affichage des paroles › Fenêtre des paroles › Couleur › Surbrillance HDR |
| [Fenêtre mini masquée en pause ou en plein écran](#feature-mini-window-auto-hide) | Réglages › Affichage des paroles › Fenêtre des paroles › Comportement › Masquer en pause |
| [Fond Spotify Canvas](#feature-spotify-canvas) | Réglages › Affichage des paroles › Fenêtre des paroles › Fond › Spotify Canvas |
| [Transition des lignes](#feature-line-transition) | Réglages › Affichage des paroles › Paroles flottantes › Disposition › Transition des lignes |
| [Estomper au survol](#feature-fade-on-hover) | Réglages › Affichage des paroles › Paroles flottantes › Comportement › Estomper au survol |
| [Verrouiller la position, maintenir pour déplacer](#feature-lock-position) | Réglages › Affichage des paroles › Paroles flottantes › Comportement › Verrouiller la position |
| [Masquées dans les captures et le partage d’écran](#feature-hide-in-screenshots) | Réglages › Affichage des paroles › Paroles flottantes › Comportement › Masquer dans les captures |
| [Masquer ou réduire en pause](#feature-hide-when-paused) | Réglages › Affichage des paroles › Paroles flottantes › Comportement › Masquer en pause |
| [Masquer si instrumental ou sans paroles](#feature-hide-when-no-lyrics) | Réglages › Affichage des paroles › Paroles flottantes › Comportement › Masquer si instrumental ou sans paroles |
| [S’effacer pendant les pubs](#feature-hide-during-ads) | Réglages › Affichage des paroles › Paroles flottantes › Comportement › Masquer pendant les pubs |
| [Encoche sur l’écran verrouillé](#feature-notch-show-on-lock-screen) | Réglages › Affichage des paroles › Encoche › Comportement › Afficher sur l’écran verrouillé |
| [Paroles flottantes masquées en plein écran](#feature-overlay-hide-in-full-screen) | Réglages › Affichage des paroles › Paroles flottantes › Comportement › Masquer en plein écran |
| [Estomper la ligne de paroles de l’encoche au survol](#feature-notch-lyric-row-fade) | Réglages › Affichage des paroles › Encoche › Ligne de paroles › Estomper au survol |
| [Paroles web : un téléphone ou une tablette en second écran, ou une source navigateur OBS](#feature-web-lyrics) | Réglages › Affichage des paroles › Fenêtre des paroles › Paroles web |
| [YouTube Music et Spotify Web dans votre navigateur](#feature-web-players) | Réglages › Lecteur › Web |
| [Passer les pubs YouTube Music automatiquement](#feature-skip-youtube-ads) | Réglages › Lecteur › Web › Passer les pubs |
| [Ouvrir et quitter avec votre lecteur](#feature-player-linkage) | Réglages › Lecteur › Lancer et quitter › Ouvrir les lecteurs au lancement |
| [Scrobbles Last.fm et profil d’écoute](#feature-lastfm) | Réglages › Last.fm › Règles › Règles de scrobble |
| [Scrobbler aussi vers ListenBrainz](#feature-listenbrainz) | Réglages › Labo › ListenBrainz › Infos du compte |
| [Afficher sur Discord ce que vous écoutez](#feature-discord) | Réglages › Discord › Afficher sur Discord |
| [Une page web « À l’écoute » à partager](#feature-now-playing-page) | Réglages › Labo › Push web › Infos de connexion |
| [Bilans d’écoute quotidiens, hebdomadaires, mensuels et annuels](#feature-digests) | Réglages › Alertes push › Canaux |
| [Lancement silencieux](#feature-silent-launch) | Réglages › Général › Démarrage et notifications › Lancement silencieux |
| [Notifier au changement de morceau](#feature-song-notifications) | Réglages › Général › Démarrage et notifications › Notifier au changement de morceau |
| [Mises à jour automatiques et bêtas](#feature-updates) | Réglages › Mise à jour du logiciel › Réglages de mise à jour › Vérifier automatiquement |

<a id="section-lyrics"></a>

## Recherche des paroles

<a id="feature-lyric-sources"></a>

### 15 sources de paroles, interrogées automatiquement

NetEase Cloud Music, QQ Music, Kugou, Kuwo, Migu, Musixmatch, LRCLIB, LyricFind, Deezer, AMLL, Soda Music, VIBE, Genie, PetitLyrics et Apple Music. Chaque source peut être désactivée, déplacée dans l’ordre ou testée pour savoir si elle est joignable en ce moment.

- Activée par défaut
- Réglages : Paroles › Source › Sources de paroles

<a id="feature-network-proxy"></a>

### Passer par un proxy pour les sources étrangères

Quand une source de paroles étrangère n’est pas joignable directement, Lyrimuse réessaie via le proxy du système ou un proxy local comme Clash. Vous pouvez aussi saisir vous-même un serveur proxy, ou désactiver cette option. Les sources de paroles de Chine continentale se connectent toujours directement.

- Activée par défaut
- Réglages : Général › Réseau › Proxy

<a id="feature-apple-music-lyrics"></a>

### Les paroles d’Apple Music

Connectez votre compte Apple Music dans Sources de paroles pour utiliser les paroles d’Apple Music, dont beaucoup sont synchronisées mot à mot. Nécessite un abonnement Apple Music.

- Désactivée par défaut
- Réglages : Paroles › Source › Sources de paroles

<a id="feature-matching"></a>

### Association intelligente

Par défaut, chaque résultat est noté sur le titre, l’artiste, la durée et la version (live, instrumentale, etc.), et celui qui correspond le mieux au morceau en cours l’emporte. Vous pouvez plutôt suivre l’ordre des sources : pas de notation, la première source de votre liste qui a des paroles est utilisée.

- Réglages : Paroles › Source › Algorithme de correspondance

<a id="feature-auto-upgrade"></a>

### Rechoisir les paroles quand l’association s’améliore

Quand une nouvelle version améliore l’association ou la notation, les paroles que vous avez déjà sont revérifiées en arrière-plan et remplacées si une meilleure version apparaît. Désactivez l’option pour garder les paroles une fois choisies.

- Activée par défaut
- Réglages : Paroles › Source › Rechoisir après mise à jour de l’algorithme

<a id="feature-prefetch"></a>

### Paroles prêtes avant le morceau suivant

Lit la file d’attente de votre lecteur et cherche à l’avance les paroles des prochains morceaux ; sans file d’attente à lire, il parcourt la suite de l’album. QQ Music, NetEase Cloud Music, Kugou, Soda Music et VOX ont besoin pour cela de l’accès complet au disque.

- Activée par défaut
- Réglages : Paroles › Source › Préparer les morceaux suivants
- Réglages : Lecteur › Autorisations et services › Accès complet au disque

<a id="feature-player-local-lyrics"></a>

### Utiliser les paroles déjà enregistrées par le lecteur

Les paroles qu’Apple Music, Spotify, Kugou, KKBOX, Amazon Music et LX Music ont déjà enregistrées sur ce Mac peuvent être utilisées directement : la même version que celle du lecteur, et plus vite (pour Apple Music et Spotify, seulement les morceaux dont le lecteur a affiché les paroles). Pour QQ Music et NetEase Cloud Music, le morceau est reconnu dans la bibliothèque locale du lecteur, si bien que cette version exacte est récupérée sans recherche. Pour reAMP, VOX, Pine Player et foobar2000, ainsi qu’avec Apple Music ou LX Music quand ils lisent un fichier local de votre bibliothèque ou de votre liste locale, ce sont les paroles du fichier lu ou d’un fichier .lrc du même nom qui sont utilisées. QQ Music, NetEase Cloud Music et Kugou demandent l’accès complet au disque pour Lyrimuse dans Réglages Système ; sans lui, les paroles sont quand même trouvées en ligne.

- Désactivée par défaut
- Réglages : Lecteur › Autorisations et services › Accès complet au disque

<a id="feature-prefer-local-file-lyrics"></a>

### Privilégier les paroles du fichier

Quand le morceau lu est un fichier sur ce Mac, son .lrc du même nom ou ses paroles intégrées sont utilisés en priorité au lieu d’être comparés aux paroles trouvées en ligne. Cela fonctionne avec tout lecteur qui lit des fichiers locaux. Si ces paroles ne conviennent pas à cette version (par exemple si la durée ne correspond pas), les paroles sont cherchées en ligne comme d’habitude.

- Désactivée par défaut
- Réglages : Paroles › Source › Privilégier les paroles du fichier

<a id="feature-lock-hand-picked"></a>

### Verrouiller les paroles choisies

Si l’option est activée, les paroles que vous choisissez à la main dans les résultats de recherche sont verrouillées : l’association automatique et les réassociations ultérieures ne les remplacent jamais.

- Désactivée par défaut
- Réglages : Paroles › Source › Verrouiller les paroles choisies

<a id="feature-lyrics-manager"></a>

### Gestionnaire de paroles

Parcourez, modifiez, supprimez ou recherchez à nouveau les paroles de n’importe quel morceau, supprimez par lots et faites le ménage dans les entrées vides laissées par les pubs et les podcasts. Donnez à un morceau son propre décalage. Relancez d’un coup tous les morceaux encore sans paroles, ou réassociez toute la bibliothèque selon les règles actuelles, avec une pause réglable entre les morceaux ; tout ce que vous avez modifié à la main est laissé tel quel.

- Réglages : Paroles › Bibliothèque de paroles › Bibliothèque de paroles
- Réglages : Paroles › Bibliothèque de paroles › Associer les paroles manquantes
- Réglages : Paroles › Bibliothèque de paroles › Réassocier toute la bibliothèque
- Réglages : Raccourcis clavier › Ouvrir le gestionnaire de paroles
- Réglages : Paroles › Bibliothèque de paroles › Intervalle d’analyse

<a id="feature-song-entries"></a>

### Entrées d’un même morceau

Le même morceau lu dans différents lecteurs ou issu de différentes éditions est reconnu comme un seul morceau : ses entrées partagent les mêmes paroles, les modifications manuelles et les corrections de minutage sont reprises, et les écoutes s’additionnent. Dans le Gestionnaire de paroles, « Entrées de ce morceau » compare ligne par ligne les paroles de chaque entrée, et une entrée associée par erreur peut être séparée puis refusionnée plus tard. Désactivez le partage pour que chaque entrée soit associée séparément.

- Activée par défaut
- Réglages : Paroles › Source › Partager les paroles entre entrées d’un morceau

<a id="feature-fix-lyrics"></a>

### Changer ou corriger les paroles sur-le-champ

Depuis le menu ⋯ de la fenêtre des paroles, cherchez d’autres paroles, relancez l’association ou modifiez-les dans votre propre éditeur de texte. Modifier des paroles mot à mot ne change que les mots, jamais leur minutage.

- Réglages : Raccourcis clavier › Rechercher les paroles

<a id="feature-import-lyrics"></a>

### Importez vos propres fichiers de paroles

Importez des paroles LRC, LRC enrichi, TTML, QRC, KRC, YRC ou texte brut pour un morceau, ou tout un dossier d’un coup : les fichiers sont associés aux morceaux de votre bibliothèque et présentés dans un aperçu avant toute écriture. Choisissez si les paroles importées remplacent les actuelles, les remplacent en les verrouillant, ou ne complètent que les morceaux sans paroles. Les fichiers de morceaux pas encore écoutés sont conservés et utilisés à leur première lecture. Un dossier surveillé importe automatiquement les nouveaux fichiers.

- Réglages : Paroles › Bibliothèque de paroles › Importer un dossier de paroles
- Réglages : Paroles › Bibliothèque de paroles › Importation de dossiers
- Réglages : Paroles › Bibliothèque de paroles › Dossier surveillé
- Réglages : Paroles › Bibliothèque de paroles › Bibliothèque d’importation

<a id="feature-offline"></a>

### Hors ligne, en simples fichiers .lrc

Toutes les paroles trouvées sont mises en cache sur votre Mac et s’affichent sans connexion. Chaque morceau a un fichier .lrc, plus .tr.lrc et .roma.lrc pour la traduction et la romanisation. Le minutage mot à mot est enregistré en TTML par défaut, ou en .yrc, Enhanced LRC, QRC ou KRC. Les fichiers se trouvent par défaut dans ~/Library/Application Support/me.yudaotor.lyrimuse/lyrics/, et le dossier peut être déplacé.

- Réglages : Paroles › Bibliothèque de paroles › Dossier des paroles
- Réglages : Paroles › Bibliothèque de paroles › Format des paroles mot à mot

<a id="section-text"></a>

## Traduction, romanisation et découpage des lignes

<a id="feature-translation"></a>

### Traduction

Les traductions fournies avec les paroles apparaissent sous chaque ligne. NetEase Cloud Music, QQ Music et Kugou traduisent en chinois ; Musixmatch et la traduction automatique suivent la langue de traduction que vous choisissez parmi 17. Les paroles flottantes, la fenêtre des paroles, l’encoche, la barre des menus et la Touch Bar décident chacune de les afficher ou non. Affichées par défaut quand les langues de votre Mac incluent le chinois.

- Réglages : Paroles › Langue › Langue de traduction
- Réglages : Affichage des paroles › Paroles flottantes › Contenu › Traduction
- Réglages : Raccourcis clavier › Afficher/masquer la traduction

<a id="feature-machine-translation"></a>

### Traduire si aucune traduction

Quand aucune source n’a de traduction, les paroles sont traduites automatiquement. Sur macOS 15 ou ultérieur, avec la langue téléchargée, la traduction intégrée d’Apple s’en charge sur votre Mac et les paroles y restent ; sinon, les lignes à traduire sont envoyées à Google Traduction, puis à MyMemory. Les langues de traduction se téléchargent depuis la même carte.

- Désactivée par défaut
- Réglages : Paroles › Langue › Traduire si non fournie
- Réglages : Paroles › Langue › Langues de traduction

<a id="feature-romanization"></a>

### Romanisation

Romaji japonais, romanisation du coréen, pinyin du mandarin et jyutping cantonais, mot à mot au-dessus des paroles, plus 18 autres langues comme le russe, le thaï, le grec et le hindi, selon le système officiel de chaque langue ou une norme ISO. La langue est déterminée ligne par ligne : une ligne en japonais dans une chanson chinoise est la seule annotée. Choisissez ici les langues à annoter ; avec une interface en chinois, le pinyin est désactivé au départ. Chaque affichage décide s’il la montre.

- Activée par défaut
- Réglages : Paroles › Langue › Langues de romanisation
- Réglages : Paroles › Langue › Romanisation du japonais
- Réglages : Affichage des paroles › Paroles flottantes › Contenu › Romanisation
- Réglages : Raccourcis clavier › Afficher/masquer la romanisation

<a id="feature-chinese-script"></a>

### Chinois simplifié ou traditionnel

Affiche toutes les paroles chinoises en caractères simplifiés ou traditionnels, quelle que soit la langue de l’app.

- Réglages : Paroles › Langue › Écriture chinoise

<a id="feature-split-join-lines"></a>

### Couper les lignes longues, joindre les courtes

Les paroles flottantes, l’encoche, la barre des menus et la Touch Bar coupent les lignes trop longues pour leur largeur et joignent celles qui défilent trop vite, chacune selon sa propre largeur. La fenêtre des paroles garde une ligne par ligne. Deux options distinctes.

- Désactivée par défaut
- Réglages : Paroles › Minutage et coupures › Couper les lignes longues
- Réglages : Paroles › Minutage et coupures › Fusionner les lignes courtes

<a id="feature-timing-offset"></a>

### Décalage du minutage

Avancez ou retardez toutes les paroles, éventuellement pour un seul lecteur. Chaque morceau peut avoir son propre décalage dans le Gestionnaire de paroles, et des raccourcis permettent de l’avancer, le retarder ou le réinitialiser à la volée.

- Réglages : Paroles › Minutage et coupures › Décalage du minutage
- Réglages : Raccourcis clavier › Avancer les paroles
- Réglages : Raccourcis clavier › Retarder les paroles
- Réglages : Raccourcis clavier › Réinitialiser le décalage

<a id="section-display"></a>

## Où s’affichent les paroles, et leur apparence

<a id="feature-floating-lyrics"></a>

### Paroles flottantes

Des paroles qui flottent au-dessus de toutes les fenêtres, toujours au premier plan, et s’allument mot à mot. Laissez-les où vous les déposez, ou fixez-les en haut au centre de l’écran ou juste au-dessus du Dock. Avec plusieurs écrans, elles peuvent rester sur un seul écran ou suivre celui de la fenêtre que vous utilisez. La romanisation, la traduction et la ligne suivante peuvent s’afficher en même temps.

- Activée par défaut
- Réglages : Affichage des paroles › Paroles flottantes › Paroles flottantes
- Réglages : Affichage des paroles › Paroles flottantes › Position
- Réglages : Affichage des paroles › Paroles flottantes › Contenu › Ligne suivante
- Réglages : Raccourcis clavier › Afficher/masquer les paroles flottantes
- Réglages : Affichage des paroles › Paroles flottantes › Position › Afficher sur

<a id="feature-notch-lyrics"></a>

### Paroles de l’encoche

Une capsule façon Dynamic Island près de l’encoche, en haut de l’écran ; les Mac sans encoche et les écrans externes y ont droit aussi. Chaque côté peut afficher le titre, l’artiste, l’album, l’illustration, les commandes de lecture, ou le temps écoulé ou restant, à côté d’une onde audio animée. Survolez-la pour la développer et accéder aux commandes, à une barre de progression cliquable, au minutage des paroles et à des boutons rapides comme Favori ou Rechercher les paroles. Pendant les pubs, elle affiche un compte à rebours du temps restant.

- Désactivée par défaut
- Réglages : Affichage des paroles › Encoche › Paroles de l’encoche
- Réglages : Affichage des paroles › Encoche › Style
- Réglages : Affichage des paroles › Encoche › Écran
- Réglages : Affichage des paroles › Encoche › Gauche
- Réglages : Raccourcis clavier › Afficher/masquer les paroles de l’encoche
- Réglages : Raccourcis clavier › Développer l’encoche un instant
- Réglages : Affichage des paroles › Encoche › Développé › Actions rapides

<a id="feature-menu-bar-lyrics"></a>

### Paroles de la barre des menus

La ligne en cours directement dans la barre des menus, qui défile quand elle est trop longue au lieu d’être coupée. Ajoutez une deuxième ligne pour la ligne suivante, la traduction ou la romanisation. Elle peut aussi se placer au milieu de la barre des menus, juste à côté de l’encoche sur les écrans qui en ont une, ou n’afficher que le titre, avec ou sans l’artiste.

- Désactivée par défaut
- Réglages : Affichage des paroles › Barre des menus › Paroles de la barre des menus
- Réglages : Affichage des paroles › Barre des menus › Disposition › Position
- Réglages : Affichage des paroles › Barre des menus › Contenu › Contenu affiché
- Réglages : Affichage des paroles › Barre des menus › Contenu › Seconde ligne
- Réglages : Raccourcis clavier › Afficher/masquer les paroles de la barre des menus

<a id="feature-touch-bar-lyrics"></a>

### Paroles Touch Bar

Sur un MacBook Pro avec Touch Bar, la ligne en cours défile au fil du chant, avec l’illustration et les commandes de lecture en option. Les paroles peuvent être blanches, suivre l’illustration, prendre votre propre couleur ou défiler en arc-en-ciel, avec une luminosité réglable pour la partie pas encore chantée. Elles peuvent se déployer au début de la lecture et se replier en pause, et un bouton Plus donne accès au minutage, à Favori, à Aléatoire et Répéter, au volume et à un curseur de progression.

- Désactivée par défaut
- Réglages : Affichage des paroles › Touch Bar › Paroles Touch Bar
- Réglages : Raccourcis clavier › Développer/réduire les paroles de la Touch Bar
- Réglages : Affichage des paroles › Touch Bar › Couleur › Couleur du texte
- Réglages : Affichage des paroles › Touch Bar › Comportement › Développer au début de la lecture
- Réglages : Affichage des paroles › Touch Bar › Disposition › Afficher le bouton « Plus »

<a id="feature-lyrics-window"></a>

### Fenêtre des paroles

Des paroles en pleine page inspirées de la vue paroles d’Apple Music : illustration floutée en fond, toute la chanson qui défile jusqu’à la ligne en cours, duos séparés par chanteur, chœurs sur leur propre ligne, notes tenues qui gonflent et brillent. Le fond peut suivre l’illustration ou être uni, en dégradé ou en verre dépoli, et la graisse du texte, la couleur chantée et l’alignement sont réglables. Ouvrez-la depuis l’icône de la barre des menus ou avec un raccourci.

- Réglages : Affichage des paroles › Fenêtre des paroles › Fenêtre des paroles
- Réglages : Affichage des paroles › Fenêtre des paroles › Fond › Fond
- Réglages : Raccourcis clavier › Ouvrir la fenêtre des paroles
- Réglages : Affichage des paroles › Fenêtre des paroles › Disposition › Alignement

<a id="feature-lyrics-window-hdr"></a>

### Surbrillance HDR de la fenêtre des paroles

Sur un écran HDR, la partie chantée de la ligne en cours dans la fenêtre des paroles est éclaircie au-delà du blanc normal. Désactivée par défaut, elle consomme plus d’énergie une fois activée. En taille complète uniquement.

- Désactivée par défaut
- Réglages : Affichage des paroles › Fenêtre des paroles › Couleur › Surbrillance HDR

<a id="feature-mini-lyrics-window"></a>

### Fenêtre des paroles mini

La fenêtre des paroles réduite à une petite carte : seulement la ligne en cours, la ligne en cours et la suivante, ou une page complète qui défile. Le fond, la couleur du texte, la police, la graisse, la couleur chantée ainsi que le titre, l’illustration et le temps affichés en haut se règlent séparément.

- Réglages : Affichage des paroles › Fenêtre des paroles › Disposition › Disposition des paroles
- Réglages : Raccourcis clavier › Alterner taille Mini/complète

<a id="feature-mini-window-auto-hide"></a>

### Fenêtre mini masquée en pause ou en plein écran

La fenêtre mini peut disparaître en pause ou à l’arrêt et revenir au début de la lecture, et s’effacer quand une app est en plein écran sur son écran (une vidéo, un jeu). Deux options distinctes.

- Désactivée par défaut
- Réglages : Affichage des paroles › Fenêtre des paroles › Comportement › Masquer en pause
- Réglages : Affichage des paroles › Fenêtre des paroles › Comportement › Masquer en plein écran

<a id="feature-animated-artwork"></a>

### Illustration animée

Les albums avec une illustration animée sur Apple Music, QQ Music ou NetEase Cloud Music s’animent aussi dans la fenêtre des paroles en taille complète, tout comme les albums dont Kugou Music a enregistré l’illustration animée quand vous les y avez écoutés. L’animation se met en pause en mode Économie d’énergie ou avec « Réduire les animations ». Vous pouvez voir la place prise par les animations téléchargées et les effacer.

- Activée par défaut
- Réglages : Affichage des paroles › Fenêtre des paroles › Illustration › Illustration animée
- Réglages : Affichage des paroles › Fenêtre des paroles › Illustration › Cache des illustrations animées

<a id="feature-spotify-canvas"></a>

### Fond Spotify Canvas

Quand un morceau a une vidéo Canvas en boucle sur Spotify, la fenêtre des paroles en taille complète la lit en fond à la place de l’illustration floutée. Seules les vidéos déjà enregistrées par Spotify sur ce Mac sont utilisées : les morceaux que vous avez écoutés dans Spotify en ont une, même quand vous les écoutez dans un autre lecteur. La vidéo se met en pause en mode Économie d’énergie ou avec « Réduire les animations ».

- Désactivée par défaut
- Réglages : Affichage des paroles › Fenêtre des paroles › Fond › Spotify Canvas

<a id="feature-idle-overview"></a>

### Aperçu de vos écoutes entre deux morceaux

Quand rien n’est en lecture, la fenêtre des paroles affiche le dernier morceau avec une ligne de ses paroles et un bouton Reprendre. Avec Last.fm connecté, elle affiche aussi votre temps d’écoute du jour, des 7 derniers jours et au total, une tendance sur 30 jours, « Ce jour-là » et vos écoutes récentes avec leur illustration.

<a id="feature-look"></a>

### Apparence

Police (celle du système, ou votre propre .ttf / .otf), taille, graisse, couleurs du texte et du fond, contour et verre dépoli. Les paroles flottantes ont des thèmes de couleurs et peuvent enregistrer les vôtres ; la couleur du texte peut suivre l’illustration de l’album, et les paroles flottantes, l’encoche, la barre des menus et la Touch Bar peuvent aussi défiler en arc-en-ciel. Des raccourcis, ou le défilement sur les paroles en maintenant ⌘ (molette ou balayage à deux doigts), agrandissent ou réduisent aussi les paroles flottantes à la volée.

- Réglages : Affichage des paroles › Paroles flottantes › Thème
- Réglages : Affichage des paroles › Paroles flottantes › Thème › Mes thèmes
- Réglages : Affichage des paroles › Encoche › Ligne de paroles › Couleur des paroles
- Réglages : Affichage des paroles › Barre des menus › Couleur › Arc-en-ciel
- Réglages : Affichage des paroles › Paroles flottantes › Police › Police
- Réglages : Affichage des paroles › Paroles flottantes › Couleur › Fond dépoli
- Réglages : Raccourcis clavier › Agrandir les paroles flottantes
- Réglages : Raccourcis clavier › Réduire les paroles flottantes

<a id="feature-karaoke"></a>

### Remplissage karaoké mot à mot

Chaque mot s’allume au moment où il est chanté. Les paroles flottantes, l’encoche, la barre des menus, la Touch Bar et les deux tailles de la fenêtre des paroles ont chacune leur option ; désactivée, toute la ligne s’allume d’un coup.

- Activée par défaut
- Réglages : Affichage des paroles › Paroles flottantes › Couleur › Effet karaoké
- Réglages : Affichage des paroles › Encoche › Ligne de paroles › Effet karaoké
- Réglages : Affichage des paroles › Barre des menus › Couleur › Effet karaoké
- Réglages : Affichage des paroles › Touch Bar › Couleur › Effet karaoké
- Réglages : Affichage des paroles › Fenêtre des paroles › Couleur › Effet karaoké

<a id="feature-line-transition"></a>

### Transition des lignes

Quand les paroles flottantes passent à la ligne suivante, l’ancienne glisse vers le haut et la nouvelle suit, au lieu d’être remplacée sur place.

- Désactivée par défaut
- Réglages : Affichage des paroles › Paroles flottantes › Disposition › Transition des lignes

<a id="feature-fade-on-hover"></a>

### Estomper au survol

Les paroles flottantes deviennent transparentes quand le pointeur passe dessus, pour ne jamais masquer ce qui se trouve dessous. La fenêtre des paroles mini a sa propre option et peut aussi laisser passer les clics vers la fenêtre en dessous pendant qu’elle est estompée ; maintenez ⌥ pour utiliser la fenêtre mini.

- Désactivée par défaut
- Réglages : Affichage des paroles › Paroles flottantes › Comportement › Estomper au survol
- Réglages : Affichage des paroles › Fenêtre des paroles › Comportement › Estomper au survol
- Réglages : Affichage des paroles › Fenêtre des paroles › Comportement › Clics traversants si estompé

<a id="feature-lock-position"></a>

### Verrouiller la position, maintenir pour déplacer

Verrouillez les paroles flottantes en place, ou exigez un appui long avant de les déplacer pour qu’elles ne bougent jamais par accident.

- Désactivée par défaut
- Réglages : Affichage des paroles › Paroles flottantes › Comportement › Verrouiller la position
- Réglages : Affichage des paroles › Paroles flottantes › Comportement › Maintenir pour déplacer
- Réglages : Raccourcis clavier › Verrouiller/déverrouiller la position

<a id="feature-hover-controls"></a>

### Commandes au survol

Pointer les paroles flottantes fait apparaître une rangée de boutons rapides. Les paroles de la barre des menus peuvent aussi afficher les commandes de lecture au survol.

- Activée par défaut
- Réglages : Affichage des paroles › Paroles flottantes › Comportement › Commandes au survol
- Réglages : Affichage des paroles › Barre des menus › Comportement › Commandes au survol

<a id="feature-hide-in-screenshots"></a>

### Masquées dans les captures et le partage d’écran

Les captures d’écran, les enregistrements et les écrans partagés n’incluent pas les paroles, que vous continuez de voir. Les paroles flottantes et l’encoche ont chacune leur option.

- Désactivée par défaut
- Réglages : Affichage des paroles › Paroles flottantes › Comportement › Masquer dans les captures
- Réglages : Affichage des paroles › Encoche › Comportement › Masquer dans les captures

<a id="feature-hide-when-paused"></a>

### Masquer ou réduire en pause

Les paroles flottantes et l’encoche disparaissent en pause ou à l’arrêt ; l’encoche peut plutôt se réduire à la taille de l’encoche.

- Désactivée par défaut
- Réglages : Affichage des paroles › Paroles flottantes › Comportement › Masquer en pause
- Réglages : Affichage des paroles › Encoche › Comportement › Masquer en pause
- Réglages : Affichage des paroles › Encoche › Comportement › Réduire en pause

<a id="feature-hide-when-no-lyrics"></a>

### Masquer si instrumental ou sans paroles

Quand un morceau est instrumental, ou que la recherche est terminée sans trouver de paroles, les paroles flottantes et la fenêtre des paroles mini peuvent se masquer, et l’encoche et la Touch Bar peuvent replier leur ligne de paroles. Rien ne se masque tant que la recherche est en cours. Chacune a sa propre option.

- Désactivée par défaut
- Réglages : Affichage des paroles › Paroles flottantes › Comportement › Masquer si instrumental ou sans paroles
- Réglages : Affichage des paroles › Fenêtre des paroles › Comportement › Masquer si instrumental ou sans paroles
- Réglages : Affichage des paroles › Encoche › Comportement › Réduire si instrumental ou sans paroles
- Réglages : Affichage des paroles › Touch Bar › Comportement › Réduire si instrumental ou sans paroles

<a id="feature-hide-during-ads"></a>

### S’effacer pendant les pubs

Pendant que le lecteur diffuse une pub, les paroles flottantes peuvent se masquer et l’encoche se réduire à sa bande du haut ; le survol de l’encoche la développe toujours. Chacune a sa propre option.

- Désactivée par défaut
- Réglages : Affichage des paroles › Paroles flottantes › Comportement › Masquer pendant les pubs
- Réglages : Affichage des paroles › Encoche › Comportement › Réduire pendant les pubs

<a id="feature-hide-in-full-screen"></a>

### Encoche masquée en plein écran

Les paroles de l’encoche s’effacent quand une vidéo, un jeu ou n’importe quelle app est en plein écran.

- Activée par défaut
- Réglages : Affichage des paroles › Encoche › Comportement › Masquer en plein écran

<a id="feature-notch-show-on-lock-screen"></a>

### Encoche sur l’écran verrouillé

L’encoche continue d’afficher le morceau en cours et ses paroles sur l’écran verrouillé.

- Désactivée par défaut
- Réglages : Affichage des paroles › Encoche › Comportement › Afficher sur l’écran verrouillé

<a id="feature-overlay-hide-in-full-screen"></a>

### Paroles flottantes masquées en plein écran

Les paroles flottantes restent normalement au-dessus des apps en plein écran. Activez cette option pour qu’elles se masquent pendant qu’une vidéo, un jeu ou n’importe quelle app est en plein écran, puis reviennent quand vous en sortez.

- Désactivée par défaut
- Réglages : Affichage des paroles › Paroles flottantes › Comportement › Masquer en plein écran

<a id="feature-title-on-change"></a>

### Afficher le titre au changement

Le titre et l’artiste de chaque nouveau morceau sortent de l’encoche un instant, puis s’y replient.

- Activée par défaut
- Réglages : Affichage des paroles › Encoche › Comportement › Afficher le titre au changement

<a id="feature-listening-milestones"></a>

### Paliers d’écoute

Quand un morceau atteint sa 100ᵉ, 1 000ᵉ ou 10 000ᵉ écoute, ou que votre total Last.fm franchit un palier, l’encoche s’ouvre pour le fêter. Nécessite Last.fm connecté.

- Activée par défaut
- Réglages : Affichage des paroles › Encoche › Comportement › Paliers d’écoute

<a id="feature-notch-gestures"></a>

### Gestes du trackpad sur l’encoche

Le pointeur sur l’encoche, balayez à deux doigts vers la gauche ou la droite pour changer de morceau, ou vers le haut et le bas pour régler le volume du système.

- Activée par défaut
- Réglages : Affichage des paroles › Encoche › Comportement › Gestes du trackpad
- Réglages : Affichage des paroles › Encoche › Comportement › Afficher avec les touches de volume

<a id="feature-notch-lyric-row-fade"></a>

### Estomper la ligne de paroles de l’encoche au survol

Le pointeur sur la ligne de paroles de l’encoche, la ligne s’estompe au lieu de se développer et les clics passent à la fenêtre en dessous ; l’encoche ne se développe qu’à partir de l’encoche elle-même ou de ses côtés.

- Désactivée par défaut
- Réglages : Affichage des paroles › Encoche › Ligne de paroles › Estomper au survol

<a id="feature-notch-multiline-lyrics"></a>

### Paroles multilignes dans l’encoche développée

Quand l’encoche se développe sous le pointeur, la zone des paroles devient une liste de 3, 5 ou 7 lignes : la ligne en cours s’allume mot à mot et la liste remonte à chaque nouvelle ligne ; cliquez sur une ligne pour y aller. Si la ligne de paroles est désactivée, l’encoche reste une fine bande d’état et n’affiche les paroles qu’une fois développée.

- Activée par défaut
- Réglages : Affichage des paroles › Encoche › Développé › Paroles multilignes
- Réglages : Affichage des paroles › Encoche › Développé › Lignes

<a id="feature-web-lyrics"></a>

### Paroles web : un téléphone ou une tablette en second écran, ou une source navigateur OBS

Les paroles dans un navigateur web. « Paroles web » affiche exactement ce qu’affiche la fenêtre des paroles ; « Sortie OBS » a un fond transparent et les mêmes polices et couleurs que les paroles flottantes, plus une carte de titre (titre, artiste et pochette) dans le coin supérieur gauche, affichée en permanence, aux changements de morceau ou jamais. Chacune a son propre port et son propre réglage de réseau local. Les deux ne sont disponibles que sur ce Mac tant que vous n’activez pas « Autoriser l’accès du réseau local » ; les appareils du même réseau peuvent alors scanner un code QR pour se connecter, via un lien avec une clé d’accès. Avec « Autoriser le contrôle à distance », la page peut aussi contrôler la lecture et sauter à une ligne.

- Désactivée par défaut
- Réglages : Affichage des paroles › Fenêtre des paroles › Paroles web
- Réglages : Affichage des paroles › Fenêtre des paroles › Paroles web › Autoriser l’accès du réseau local
- Réglages : Affichage des paroles › Paroles flottantes › OBS › Sortie OBS
- Réglages : Affichage des paroles › Paroles flottantes › OBS › Carte titre
- Réglages : Affichage des paroles › Fenêtre des paroles › Paroles web › Autoriser le contrôle à distance

<a id="section-players"></a>

## Lecteurs et lecture

<a id="feature-players"></a>

### 14 lecteurs, au choix ou détectés automatiquement

Apple Music, Spotify, QQ Music, NetEase Cloud Music, Kugou, Soda Music, LX Music, KKBOX, Amazon Music, reAMP dans l’esprit de Winamp, VOX, lecteur local sans perte et haute résolution, Pine Player, lecteur local gratuit qui lit presque tous les formats, foobar2000, lecteur local classique venu de Windows, et Kaset, l’app YouTube Music. Choisissez-en plusieurs à la fois, ou laissez le mode automatique suivre ce que macOS affiche comme « À l’écoute ». La radio d’Apple Music fonctionne aussi : le nom et le logo de la station s’affichent pendant que l’animateur parle.

- Réglages : Lecteur › Apps de musique

<a id="feature-web-players"></a>

### YouTube Music et Spotify Web dans votre navigateur

Associez une fois votre navigateur, et la musique qu’il joue a aussi ses paroles, en suivant la progression de la page elle-même. Une vérification en un clic vous indique d’abord si ce navigateur peut être contrôlé. Pendant les pubs, l’encoche affiche le temps restant et de quelle pub il s’agit.

- Désactivée par défaut
- Réglages : Lecteur › Web

<a id="feature-skip-youtube-ads"></a>

### Passer les pubs YouTube Music automatiquement

Les pubs de YouTube Music dans votre navigateur sont passées dès que le bouton pour les passer apparaît. Option désactivée, vous pouvez toujours les passer vous-même depuis l’encoche. Nécessite l’autorisation Accessibilité.

- Désactivée par défaut
- Réglages : Lecteur › Web › Passer les pubs
- Réglages : Lecteur › Autorisations et services › Accessibilité

<a id="feature-other-players"></a>

### Ajouter d’autres lecteurs

Les lecteurs absents de la liste peuvent être ajoutés à vos lecteurs de confiance depuis Applications, et Lyrimuse vous demande quand il remarque un lecteur inconnu en train de jouer de la musique.

- Réglages : Lecteur › Autres apps
- Réglages : Lecteur › Ajouter…
- Réglages : Lecteur › Alertes de nouveaux lecteurs

<a id="feature-permissions"></a>

### Des autorisations, seulement si nécessaire

Apple Music, Spotify, Kaset et VOX ont besoin de l’autorisation d’automatisation pour lire ce qui est en cours. QQ Music, NetEase Cloud Music et Kugou ont besoin de l’accès complet au disque pour leurs paroles enregistrées et leurs files d’attente, et Soda Music et VOX pour leurs files d’attente. Le calibrage de la progression pour Amazon Music et Pine Player, la liste de lecture de Pine Player, les boutons Aléatoire, Répéter et Favori de QQ Music, NetEase Cloud Music, Kugou Music, Soda Music, Amazon Music, reAMP, Pine Player et foobar2000, le volume de foobar2000, et les boutons de lecture de QQ Music, NetEase Cloud Music, Soda Music, Pine Player et foobar2000 quand une autre app détient « À l’écoute » demandent l’autorisation Accessibilité. Les lecteurs web ont besoin de l’automatisation pour le navigateur et de son option « Autoriser JavaScript venant des événements Apple ». Les autres lecteurs n’ont besoin de rien. Les Réglages indiquent l’état actuel de chacune.

- Réglages : Lecteur › Autorisations et services › Autorisation d’automatisation
- Réglages : Lecteur › Autorisations et services › Accès complet au disque
- Réglages : Lecteur › Autorisations et services › Accessibilité

<a id="feature-controls"></a>

### Commandes de lecture et navigation dans le morceau

Lancez la lecture, mettez en pause, changez de morceau et faites glisser la barre de progression depuis la fenêtre des paroles ou l’encoche développée. Aléatoire, Répéter, Favori et le volume dépendent du lecteur : Apple Music, Spotify, Kaset, QQ Music, Amazon Music, reAMP, VOX, Pine Player, foobar2000 et YouTube Music dans un navigateur en prennent en charge une partie ou la totalité, et NetEase Cloud Music, Kugou Music, Soda Music et LX Music ont Favori, LX Music ayant aussi le volume une fois Open API activé dans ses réglages. Lecture, pause, morceau suivant ou précédent et Favori peuvent avoir des raccourcis globaux. Quand quelque chose comme une vidéo dans le navigateur détient « À l’écoute », la lecture, la pause et le changement de morceau pour QQ Music, NetEase Cloud Music, Soda Music, Pine Player et foobar2000 passent par leurs propres menus ou barre de lecture, et la navigation dans le morceau n’est pas disponible.

- Réglages : Affichage des paroles › Encoche › Développé › Commandes de lecture
- Réglages : Raccourcis clavier › Lecture/Pause
- Réglages : Raccourcis clavier › Morceau suivant
- Réglages : Raccourcis clavier › Morceau précédent
- Réglages : Raccourcis clavier › Ajouter/retirer des favoris
- Réglages : Lecteur › Autorisations et services › Open API de LX Music

<a id="feature-song-pages"></a>

### Ouvrir la page du morceau en un clic

Un clic dans le menu ⋯ ouvre le morceau, son album ou son artiste sur la plateforme d’où vous écoutez. Apple Music et KKBOX s’ouvrent dans leur propre app, et Spotify va au morceau dans son app ; le reste s’ouvre sur le web : albums et artistes Spotify, QQ Music, Soda Music, Amazon Music et YouTube Music. NetEase Cloud Music et Kugou n’ont que la page du morceau.

<a id="feature-about-panels"></a>

### Notes sur le morceau, l’album et l’artiste

Cliquez sur le titre, l’artiste ou l’album dans la fenêtre des paroles ou l’encoche développée pour en savoir plus. Les notes d’album et la bio de l’artiste viennent d’abord d’Apple Music ; à défaut, de Soda Music, Kugou Music et NetEase Cloud Music (interface en chinois uniquement), puis de Wikipédia via YouTube Music, puis de Last.fm. Les notes du morceau viennent de QQ Music (interface en chinois uniquement) ou de Last.fm. Last.fm nécessite votre compte connecté.

<a id="feature-player-linkage"></a>

### Ouvrir et quitter avec votre lecteur

Pour chaque lecteur : ouvrir le lecteur à l’ouverture de Lyrimuse, ouvrir Lyrimuse à l’ouverture du lecteur, ou quitter Lyrimuse une fois que tous les lecteurs qu’il suit ont été quittés.

- Désactivée par défaut
- Réglages : Lecteur › Lancer et quitter › Ouvrir les lecteurs au lancement
- Réglages : Lecteur › Lancer et quitter › Ouvrir avec le lecteur
- Réglages : Lecteur › Lancer et quitter › Quitter avec le lecteur

<a id="section-listening"></a>

## Scrobbles, Last.fm et partage

<a id="feature-lastfm"></a>

### Scrobbles Last.fm et profil d’écoute

Connectez Last.fm en un clic, sans jeton à copier. Consultez vos écoutes du jour, de la semaine et de tous les temps, des classements d’artistes, d’albums et de morceaux avec leur évolution, et l’Empreinte : une carte thermique de l’année où cliquer sur un jour liste ses morceaux les plus écoutés, vos heures d’écoute, l’origine de vos artistes, et « Ce jour-là ». Adorez n’importe quel morceau récent d’un clic.

- Désactivée par défaut
- Réglages : Last.fm › Règles › Règles de scrobble

<a id="feature-scrobble-rules"></a>

### Règles de scrobble personnalisées

Comptez une écoute à 50 %, 75 %, 90 % ou seulement à la fin ; décidez du sort des morceaux de moins de 30 secondes ; par défaut, les artistes invités, les variantes d’écriture chinoise et les suffixes comme « - Single » sont associés à l’entrée du catalogue de Last.fm, ou envoyez tout tel quel ; excluez entièrement n’importe quel lecteur de Last.fm.

- Réglages : Last.fm › Règles › Moment du scrobble
- Réglages : Last.fm › Règles › Scrobbler les morceaux de moins de 30 s
- Réglages : Last.fm › Règles › Mode de correspondance
- Réglages : Last.fm › Règles › Lecteurs à scrobbler

<a id="feature-local-log"></a>

### Chaque écoute d’abord enregistrée en local

Les écoutes faites quand Last.fm n’est pas connecté sont enregistrées sur votre Mac ; une fois connecté, cliquez sur Rattraper sous « Scrobbles en attente » dans la page Last.fm. Une écoute qui n’a peut-être pas atteint Last.fm alors que le compte était connecté est vérifiée auprès de Last.fm et renvoyée automatiquement. Last.fm n’accepte que les écoutes des deux dernières semaines environ.

<a id="feature-listenbrainz"></a>

### Scrobbler aussi vers ListenBrainz

Chaque écoute part vers Last.fm et ListenBrainz à partir de la même lecture, pour que les deux concordent. Les écoutes que votre iPhone envoie à Last.fm peuvent aussi être copiées dans ListenBrainz. Dans Labo, dans la barre latérale.

- Désactivée par défaut
- Réglages : Labo › ListenBrainz › Infos du compte

<a id="feature-discord"></a>

### Afficher sur Discord ce que vous écoutez

Votre profil et votre liste d’amis affichent le lecteur, le titre, l’artiste, l’illustration et une barre de progression ; cliquer sur le titre ou l’artiste ouvre la page web du lecteur. La ligne de l’album peut afficher la ligne en train d’être chantée, et jusqu’à deux boutons peuvent être ajoutés. Choisissez la disposition du texte, les lecteurs pris en compte, si l’affichage reste en pause et quel badge figure sur l’illustration, n’affichez que le lecteur sans nommer le morceau, ou masquez-le un moment.

- Désactivée par défaut
- Réglages : Discord › Afficher sur Discord
- Réglages : Discord › Lecteurs affichés
- Réglages : Discord › À la pause
- Réglages : Discord › Masquer temporairement
- Réglages : Discord › Contenu affiché
- Réglages : Discord › Boutons
- Réglages : Discord › Masquer les détails du morceau

<a id="feature-now-playing-page"></a>

### Une page web « À l’écoute » à partager

Une page publique avec ce que vous écoutez et votre historique, avec en option un livre d’or, des réactions, un compteur de visites, vos 10 artistes les plus écoutés et un style vinyle. ListenBrainz seul fournit la lecture en direct et l’historique ; déployez un Cloudflare Worker en suivant le guide pour le reste. Dans Labo.

- Désactivée par défaut
- Réglages : Labo › Push web › Infos de connexion

<a id="feature-digests"></a>

### Bilans d’écoute quotidiens, hebdomadaires, mensuels et annuels

Envoyés sur les canaux que vous configurez, autant que vous voulez : Bark, ntfy, ServerChan, Feishu, DingTalk, WeCom, Telegram, Discord, Slack ou un webhook générique. Chaque canal peut prévisualiser un envoi et envoyer un test, et l’historique d’envoi indique si chaque envoi est arrivé, avec un renvoi pour ceux qui ont échoué. Les bilans se comparent à la période précédente, nomment les artistes écoutés pour la première fois et estiment votre temps d’écoute, mis en forme pour chaque plateforme avec la pochette de l’album et un lien vers le classement complet. Chacun des quatre a sa propre option et, avec plusieurs canaux, son propre choix de canaux ; vous choisissez l’heure d’envoi (dans le fuseau horaire actuel du Mac) et le nombre d’éléments de chaque classement, et chaque canal peut utiliser le bilan complet, court ou résumé, ou votre propre titre et texte avec des variables.

- Désactivée par défaut
- Réglages : Alertes push › Canaux
- Réglages : Alertes push › Heure d’envoi
- Réglages : Alertes push › Bilans d’écoute
- Réglages : Alertes push › Source des données
- Réglages : Alertes push › Éléments
- Réglages : Alertes push › Bilan d’écoute quotidien
- Réglages : Alertes push › Récap d’écoute hebdomadaire
- Réglages : Alertes push › Récap d’écoute mensuel
- Réglages : Alertes push › Récap d’écoute annuel
- Réglages : Alertes push › Historique d’envoi

<a id="section-general"></a>

## Au quotidien

<a id="feature-onboarding"></a>

### Configuration au premier lancement

À la première ouverture, Lyrimuse vous guide pour choisir vos lecteurs, associer un navigateur et choisir où s’affichent les paroles, et vérifie chaque autorisation nécessaire pour que vous puissiez régler sur-le-champ ce qui manque.

<a id="feature-language"></a>

### Anglais, chinois simplifié et traditionnel, japonais, coréen, espagnol, français, allemand, italien et portugais du Brésil

Suit votre système par défaut, et passe en anglais quand la langue du système n’en fait pas partie ; le changement s’applique aussitôt, sans redémarrage.

- Réglages : Général › Apparence et langue › Langue

<a id="feature-appearance"></a>

### Clair, sombre ou automatique

Les Réglages, la fenêtre des paroles, le Gestionnaire de paroles et le panneau de la barre des menus peuvent rester en clair ou en sombre ; par défaut, ils suivent votre système. Les paroles flottantes suivent toujours le système, et l’encoche est toujours sombre.

- Réglages : Général › Apparence et langue › Apparence

<a id="feature-shortcuts"></a>

### Raccourcis clavier globaux

Afficher ou masquer chaque type de paroles (ou toutes à la fois, pour les réunions et le partage d’écran), ouvrir la fenêtre des paroles et le Gestionnaire de paroles, rechercher, le minutage, la lecture, Favori et le passage au lecteur peuvent tous avoir un raccourci. Aucun n’est attribué par défaut.

- Réglages : Raccourcis clavier › Ouvrir les réglages
- Réglages : Raccourcis clavier › Masquer/rétablir toutes les paroles
- Réglages : Raccourcis clavier › Basculer vers le lecteur

<a id="feature-deep-links"></a>

### Liens profonds (lyrimuse://)

Les liens lyrimuse:// ouvrent n’importe quelle page des Réglages, la fenêtre des paroles ou le Gestionnaire de paroles, et lancent toutes les actions qui peuvent avoir un raccourci, comme la lecture, Favori ou masquer toutes les paroles, depuis Raccourcis, Raycast, Alfred et des outils similaires. Ouvert avec x-callback-url depuis Raccourcis, un lien peut aussi renvoyer le titre, l’artiste, l’album et la ligne en cours. La carte « Liens profonds » de la page Raccourcis clavier liste tous les liens, prêts à copier.

- Réglages : Raccourcis clavier › Liens profonds

<a id="feature-settings-search"></a>

### Recherche dans les réglages

Tapez en haut de la barre latérale des réglages pour aller directement à un réglage, mis en évidence, même dans les sections repliées. Recherche en anglais ou en chinois.

<a id="feature-menu-bar-icon"></a>

### Icône de la barre des menus

Douze icônes en trois tailles, qui bougent avec la musique pendant la lecture, ou la pochette de ce qui est en cours. Les actions courantes se trouvent dans son menu.

- Activée par défaut
- Réglages : Général › Barre des menus et Dock › Icône de la barre des menus
- Réglages : Général › Barre des menus et Dock › Illustration d’album
- Réglages : Général › Barre des menus et Dock › Taille de l’icône
- Réglages : Général › Barre des menus et Dock › Animer l’icône

<a id="feature-dock-icon"></a>

### Afficher dans le Dock

Désactivez l’option pour ne garder que l’icône de la barre des menus.

- Activée par défaut
- Réglages : Général › Barre des menus et Dock › Afficher dans le Dock

<a id="feature-launch-at-login"></a>

### Ouvrir à la connexion

Ouvre Lyrimuse quand vous vous connectez à votre Mac.

- Activée par défaut
- Réglages : Général › Démarrage et notifications › Ouvrir à la connexion

<a id="feature-silent-launch"></a>

### Lancement silencieux

Démarre sans ouvrir de fenêtre, avec seulement l’icône de la barre des menus.

- Désactivée par défaut
- Réglages : Général › Démarrage et notifications › Lancement silencieux

<a id="feature-song-notifications"></a>

### Notifier au changement de morceau

Une notification système à chaque nouveau morceau.

- Désactivée par défaut
- Réglages : Général › Démarrage et notifications › Notifier au changement de morceau

<a id="feature-backup"></a>

### Sauvegarder les réglages, passer à un nouveau Mac

Exportez tous vos réglages dans un seul fichier, enregistré par défaut sur iCloud Drive ou dans un dossier de votre choix ; quand un nouveau Mac ouvre Lyrimuse pour la première fois et le trouve dans iCloud, il propose de l’importer.

- Réglages : Général › Sauvegarde et migration › Sauvegarde iCloud
- Réglages : Général › Sauvegarde et migration › Fichier de réglages

<a id="feature-updates"></a>

### Mises à jour automatiques et bêtas

Recherche les nouvelles versions de lui-même ; lisez les notes et installez depuis la page Mise à jour de logiciels. Activez « Mises à jour bêta » pour essayer les nouveautés en avance.

- Désactivée par défaut
- Réglages : Mise à jour du logiciel › Réglages de mise à jour › Vérifier automatiquement
- Réglages : Mise à jour du logiciel › Réglages de mise à jour › Télécharger et installer automatiquement
- Réglages : Mise à jour du logiciel › Réglages de mise à jour › Mises à jour bêta

<a id="feature-diagnostics"></a>

### Diagnostic et signalement de bugs en un clic

Regroupe journaux, rapports de plantage et état de l’app dans un seul fichier, sans identifiants ni nom d’utilisateur. « Signaler un problème » ouvre une issue GitHub avec votre version, macOS et votre lecteur déjà renseignés.

- Réglages : À propos › Diagnostic et données › Exporter le diagnostic
- Réglages : À propos › Mises à jour et aide › Signaler un problème

<a id="feature-telemetry"></a>

### Données d’utilisation anonymes, désactivables

Au plus une fois par jour, envoie la version, macOS, les fonctions activées et des résumés de plantage au propre serveur de l’auteur, pour savoir quoi corriger en priorité. Jamais de titres, d’artistes, de chemins locaux ni de comptes. Activé par défaut ; désactivez-le dans les Réglages ou sur l’écran d’accueil.

- Réglages : À propos › Diagnostic et données › Partager des données d’utilisation anonymes

<a id="section-all-settings"></a>

## Tous les réglages

Tous les réglages de la fenêtre Réglages, classés par emplacement : 309 au total. Tapez un nom dans le champ de recherche en haut de la barre latérale des Réglages pour y aller directement.

### Paroles › Source

- **Sources de paroles**
- **Algorithme de correspondance**
- **Privilégier les paroles du fichier** : Pour un fichier local, utiliser d’abord le .lrc du même nom ou les paroles intégrées
- **Rechoisir après mise à jour de l’algorithme** : Réévaluées en arrière-plan ; peuvent passer à une meilleure version
- **Partager les paroles entre entrées d’un morceau** : Une seule copie par enregistrement, quels que soient le lecteur et l’édition de l’album ; les modifications suivent
- **Verrouiller les paroles choisies** : Les paroles choisies manuellement ne sont jamais remplacées par l’association automatique
- **Préparer les morceaux suivants** : Récupère à l’avance les paroles des morceaux à venir

### Paroles › Langue

- **Langue de traduction**
- **Traduire si non fournie** : Traduit d’abord sur ce Mac, puis en ligne si ce n’est pas possible
- **Langues de traduction** : Langues système pour la traduction sur l’appareil
- **Écriture chinoise**
- **Langues de romanisation**
- **Romanisation du japonais** : Romaji, ou hiragana sur les kanji seulement

### Paroles › Minutage et coupures

- **Couper les lignes longues** : Les lignes trop longues sont coupées et affichées en plusieurs parties
- **Fusionner les lignes courtes** : Les lignes courtes voisines sont fusionnées si elles tiennent sur une ligne
- **Décalage du minutage** : Une valeur positive avance les paroles, une valeur négative les retarde

### Paroles › Bibliothèque de paroles

- **Bibliothèque de paroles**
- **Associer les paroles manquantes** : Seulement les morceaux sans paroles ou en texte brut
- **Réassocier toute la bibliothèque** : Inclut les morceaux qui ont déjà des paroles, sauf ceux modifiés, calibrés ou instrumentaux
- **Intervalle d’analyse** : Secondes entre deux morceaux ; au moins 2 secondes recommandées pour éviter les limitations de débit
- **Dossier des paroles** : Les fichiers existants restent en place si vous changez l’emplacement
- **Format des paroles mot à mot**
- **Importer un dossier de paroles** : Associe les fichiers de paroles d’un dossier aux morceaux de votre bibliothèque, avec un aperçu avant l’importation
- **Importation de dossiers**
- **Dossier surveillé** : Les fichiers de paroles ajoutés ou modifiés dans le dossier sont importés automatiquement : les morceaux sans paroles les reçoivent aussitôt, les autres restent inchangés
- **Bibliothèque d’importation** : Afficher et supprimer les paroles importées

### Lecteur

- **Apps de musique**
- **Web** : Les paroles fonctionnent aussi pour la musique lue dans un navigateur. Cliquez sur + pour jumeler votre navigateur ; la position est lue directement sur la page, les paroles se synchronisent donc dès le changement de morceau
- **Autres apps** : Les apps non listées ci-dessus peuvent aussi servir de lecteur : une fois ajoutées, leurs morceaux affichent les paroles et comptent dans votre historique d’écoute
- **Ajouter…** : Choisissez-en une dans Applications, sans attendre qu’elle joue
- **Alertes de nouveaux lecteurs**

### Lecteur › Web

- **Passer les pubs** : Les pubs pouvant être passées le sont dès leur apparition

### Lecteur › Autorisations et services

- **Autorisation d’automatisation**
- **Accès complet au disque**
- **Accessibilité**
- **Open API de LX Music** : Lyrimuse lit la position de lecture de LX Music et règle son volume via cette API
- **Moteur de paroles** : Lit l’état de lecture et récupère paroles et illustrations

### Lecteur › Lancer et quitter

- **Lancer et quitter** : Seuls les lecteurs cochés sont listés. Avec « Détection auto » activée, les lecteurs installés sur ce Mac le sont aussi
- **Ouvrir les lecteurs au lancement**
- **Ouvrir avec le lecteur**
- **Quitter avec le lecteur**

### Affichage des paroles › Paroles flottantes

- **Paroles flottantes**
- **OBS**
- **Thème**
- **Largeur**
- **Position**
- **Par défaut** : Réinitialise uniquement le thème, la police et les couleurs

### Affichage des paroles › Paroles flottantes › OBS

- **Sortie OBS** : Superposez les paroles à votre diffusion comme source navigateur. Réglez sa largeur et sa hauteur sur la taille du canevas OBS
- **URL de la source navigateur**
- **Carte titre** : Affiche le titre, l’artiste et l’illustration en haut à gauche
- **Autoriser l’accès du réseau local** : Les appareils du même réseau peuvent se connecter avec un lien incluant une clé d’accès
- **Lien d’accès**
- **Lien de secours (adresse IP)**
- **Réinitialiser la clé d’accès** : Les liens déjà partagés cesseront de fonctionner
- **Port** : Après modification, mettez à jour l’URL dans OBS

### Affichage des paroles › Paroles flottantes › Thème

- **Mes thèmes**

### Affichage des paroles › Paroles flottantes › Police

- **Police**
- **Graisse**
- **Taille**
- **Taille romanisation**
- **Taille traduction**
- **Taille ligne suivante**

### Affichage des paroles › Paroles flottantes › Couleur

- **Effet karaoké**
- **Couleur du texte**
- **Contour du texte**
- **Couleur du contour**
- **Couleur non chantée**
- **Couleur de fond**
- **Fond dépoli**
- **Densité du verre**

### Affichage des paroles › Paroles flottantes › Contenu

- **Romanisation**
- **Traduction**
- **Ligne suivante**

### Affichage des paroles › Paroles flottantes › Disposition

- **Alignement**
- **Lignes longues**
- **Transition des lignes** : Au changement de ligne, la suivante monte en place. Désactivé : les lignes changent instantanément
- **Romanisation**
- **Traduction**
- **Ligne suivante**

### Affichage des paroles › Paroles flottantes › Comportement

- **Verrouiller la position**
- **Maintenir pour déplacer**
- **Estomper au survol**
- **Commandes au survol**
- **Masquer dans les captures**
- **Masquer en pause**
- **Masquer si instrumental ou sans paroles**
- **Masquer pendant les pubs**
- **Masquer en plein écran**

### Affichage des paroles › Paroles flottantes › Position

- **Afficher sur**

### Affichage des paroles › Encoche

- **Paroles de l’encoche**
- **Style**
- **Écran**
- **Gauche**
- **Droite**
- **Largeur**
- **Largeur déployée**
- **Par défaut** : La largeur et l’option « Paroles de l’encoche » ne changent pas

### Affichage des paroles › Encoche › Style

- **Fond développé**
- **Coins**
- **Coins déployés**
- **Ligne de progression** : Affiche la progression de lecture quand l’encoche est réduite

### Affichage des paroles › Encoche › Gauche

- **Onde audio** : Un seul côté à la fois

### Affichage des paroles › Encoche › Ligne de paroles

- **Paroles en mode réduit** : Si désactivé, seule une bande à la hauteur de l’encoche reste visible jusqu’au survol
- **Alignement**
- **Couleur des paroles**
- **Seconde ligne**
- **Aperçu de la ligne suivante (développé)**
- **Hauteur**
- **Effet karaoké**
- **Afficher l’illustration**
- **Position de l’illustration**
- **Estomper au survol**

### Affichage des paroles › Encoche › Police

- **Police**
- **Graisse**
- **Taille**

### Affichage des paroles › Encoche › Développé

- **Paroles multilignes** : Affiche plusieurs lignes une fois développé, la ligne en cours s’éclairant mot à mot
- **Lignes**
- **Commandes de lecture**
- **Décalage des paroles**
- **Actions rapides**
- **Infos du morceau**

### Affichage des paroles › Encoche › Comportement

- **Réduire en pause**
- **Masquer dans les captures**
- **Masquer en pause**
- **Réduire si instrumental ou sans paroles**
- **Réduire pendant les pubs**
- **Masquer en plein écran**
- **Afficher sur l’écran verrouillé**
- **Paliers d’écoute**
- **Afficher le titre au changement**
- **Afficher avec les touches de volume**
- **Gestes du trackpad**

### Affichage des paroles › Barre des menus

- **Paroles de la barre des menus**
- **Par défaut** : La largeur et l’option « Paroles de la barre des menus » restent inchangées

### Affichage des paroles › Barre des menus › Contenu

- **Contenu affiché**
- **Seconde ligne**
- **Icône à côté des paroles** : L’icône se remplit de bas en haut pour indiquer la progression, avec les couleurs du groupe « Couleur »

### Affichage des paroles › Barre des menus › Disposition

- **Position** : Au centre : les paroles s’affichent au milieu de la barre des menus, à l’écart des menus des apps, des icônes de droite et de l’encoche
- **Afficher sur**
- **Mode de largeur** : Fixe : tous les morceaux utilisent la largeur définie Adaptative : chaque morceau prend une largeur selon ses paroles, sans dépasser la largeur définie
- **Alignement**

### Affichage des paroles › Barre des menus › Couleur

- **Effet karaoké**
- **Arc-en-ciel** : Les paroles défilent de gauche à droite aux couleurs de l’arc-en-ciel, assombries sur une barre des menus claire ; les couleurs du système reviennent quand le menu est ouvert
- **Couleur du texte**
- **Couleur chantée**

### Affichage des paroles › Barre des menus › Police

- **Police**
- **Graisse**
- **Taille**

### Affichage des paroles › Barre des menus › Largeur

- **Largeur limite**

### Affichage des paroles › Barre des menus › Comportement

- **Commandes au survol**
- **Afficher le titre sans paroles** : Affiche le titre du morceau à la place des paroles s’il n’y en a pas ou pendant leur recherche

### Affichage des paroles › Touch Bar

- **Paroles Touch Bar**
- **Par défaut** : L’interrupteur « Paroles Touch Bar » reste inchangé

### Affichage des paroles › Touch Bar › Contenu

- **Seconde ligne**
- **Taille**

### Affichage des paroles › Touch Bar › Disposition

- **Alignement**
- **Afficher l’illustration**
- **Position de l’illustration**
- **Commandes de lecture** : Précédent, Lecture/Pause et Suivant, plus un bouton de réglages
- **Position des commandes**
- **Afficher le bouton « Plus »** : Touchez-le pour passer à la position de lecture, au calibrage des paroles, Favori, Aléatoire/Répéter et Volume. Les éléments non pris en charge par le lecteur actuel sont masqués
- **Masquer la Control Strip une fois déployé** : Les paroles occupent toute la Touch Bar. Pour accéder à la luminosité, au volume et aux autres boutons système, touchez d’abord ✕ à gauche pour les replier
- **Control Strip** : Ajoutez, supprimez ou réorganisez les boutons de luminosité, de volume et autres à droite de la Touch Bar dans Réglages Système › Clavier › Réglages de la Touch Bar…

### Affichage des paroles › Touch Bar › Couleur

- **Effet karaoké**
- **Couleur du texte** : Blanc, couleur de l’illustration, couleur personnalisée ou arc-en-ciel
- **Luminosité du texte estompé** : Luminosité des mots non chantés et de la seconde ligne

### Affichage des paroles › Touch Bar › Comportement

- **Développer au début de la lecture** : Affiche les paroles à la reprise après une pause. Changer de morceau pendant la lecture ne les développe pas, et les paroles réduites manuellement le restent
- **Réduire en pause** : Se réduit au bouton de la Control Strip après 10 secondes de pause, et se développe à la reprise
- **Réduire si instrumental ou sans paroles** : Se réduit seulement une fois l’absence de paroles confirmée, et se développe dès que des paroles sont trouvées. Reste affiché pendant la recherche

### Affichage des paroles › Fenêtre des paroles

- **Fenêtre des paroles**
- **Paroles web** : Afficher la fenêtre des paroles dans un navigateur web
- **Par défaut**

### Affichage des paroles › Fenêtre des paroles › Paroles web

- **Adresse locale**
- **Autoriser l’accès du réseau local** : Les appareils du même réseau peuvent se connecter avec un lien incluant une clé d’accès
- **Autoriser le contrôle à distance** : Contrôlez la lecture et passez à une ligne des paroles depuis d’autres appareils
- **Lien d’accès**
- **Lien de secours (adresse IP)**
- **Réinitialiser la clé d’accès** : Les liens déjà partagés cesseront de fonctionner
- **Port** : Après modification, scannez à nouveau le code QR pour vous reconnecter

### Affichage des paroles › Fenêtre des paroles › Fond

- **Fond** : Fond de la fenêtre des paroles : illustration, uni, dégradé ou dépoli
- **Direction**
- **Spotify Canvas** (taille complète uniquement) : Utilise la vidéo en boucle du morceau sur Spotify comme fond ; uniquement pour les morceaux lus dans Spotify
- **Densité du verre** : Densité du verre dépoli (cinq niveaux)
- **Couleur du bas**

### Affichage des paroles › Fenêtre des paroles › Police

- **Taille** (taille mini uniquement) : Taille maximale des paroles en taille mini
- **Police** : Police des paroles de la fenêtre des paroles (texte, traduction, romanisation)
- **Graisse**

### Affichage des paroles › Fenêtre des paroles › Disposition

- **Lignes longues** (taille mini uniquement) : Retour à la ligne ou défilement des lignes longues en taille Mini
- **Disposition des paroles** (taille mini uniquement) : Une ligne : ligne actuelle uniquement Deux lignes : ligne actuelle et suivante Multiligne : page de paroles défilante, comme en taille complète
- **Alignement** (taille complète uniquement) : Alignement des paroles en taille complète ; « Auto » suit les voix du duo

### Affichage des paroles › Fenêtre des paroles › Comportement

- **Estomper au survol** (taille mini uniquement)
- **Clics traversants si estompé** (taille mini uniquement) : Une fois estompé, les clics passent à la fenêtre du dessous. Maintenez ⌥ pour le rendre opaque et interagir
- **Masquer en pause** (taille mini uniquement)
- **Masquer si instrumental ou sans paroles** (taille mini uniquement)
- **Masquer en plein écran** (taille mini uniquement)

### Affichage des paroles › Fenêtre des paroles › Couleur

- **Effet karaoké**
- **Couleur du texte** : Couleur du texte de la fenêtre des paroles. « Auto » alterne entre clair et sombre selon la luminosité du fond
- **Personnalisée**
- **Couleur chantée**
- **Surbrillance HDR** (taille complète uniquement) : Éclaircit la partie chantée sur les écrans HDR. Consomme plus d’énergie

### Affichage des paroles › Fenêtre des paroles › Contenu

- **Romanisation**
- **Traduction**
- **Barre de progression** (taille mini uniquement) : Si désactivée, n’apparaît qu’avec les commandes de lecture au survol

### Affichage des paroles › Fenêtre des paroles › En-tête

- **Titre** (taille mini uniquement) : Affiche le titre, l’artiste et l’album en haut, en taille Mini
- **Artiste** (taille mini uniquement)
- **Album** (taille mini uniquement)
- **Illustration** (taille mini uniquement) : Miniature de l’illustration à côté des infos du haut, en taille Mini
- **Temps** (taille mini uniquement) : Affiche le temps écoulé et la durée en haut, en taille Mini
- **Largeur** (taille mini uniquement) : Part de la largeur de la fenêtre occupée par l’en-tête en taille Mini
- **Hauteur** (taille mini uniquement) : Part de la hauteur de la fenêtre occupée par l’en-tête en taille Mini ; le texte et l’illustration suivent

### Affichage des paroles › Fenêtre des paroles › Illustration

- **Illustration animée** (taille complète uniquement) : Sur certains albums seulement ; en pause en mode Économie d’énergie ou avec « Réduire les animations »
- **Cache des illustrations animées** (taille complète uniquement) : Espace disque des illustrations animées téléchargées ; ce qui est effacé sera retéléchargé au prochain affichage

### Raccourcis clavier

- **Liens profonds** : Ouvrez-les depuis Raccourcis, Raycast, Alfred et d’autres outils similaires. Survolez un raccourci ci-dessus pour copier le lien de cette action
- **Afficher/masquer les paroles flottantes**
- **Afficher/masquer les paroles de l’encoche**
- **Développer l’encoche un instant**
- **Afficher/masquer les paroles de la barre des menus**
- **Développer/réduire les paroles de la Touch Bar**
- **Masquer/rétablir toutes les paroles**
- **Verrouiller/déverrouiller la position**
- **Afficher/masquer la traduction**
- **Afficher/masquer la romanisation**
- **Agrandir les paroles flottantes**
- **Réduire les paroles flottantes**
- **Ouvrir le gestionnaire de paroles**
- **Ouvrir la fenêtre des paroles**
- **Alterner taille Mini/complète**
- **Rechercher les paroles**
- **Ouvrir les réglages**
- **Basculer vers le lecteur**
- **Avancer les paroles**
- **Retarder les paroles**
- **Réinitialiser le décalage**
- **Pas** : Écart par appui
- **Lecture/Pause**
- **Morceau suivant**
- **Morceau précédent**
- **Ajouter/retirer des favoris**

### Général › Barre des menus et Dock

- **Icône de la barre des menus**
- **Illustration d’album**
- **Taille de l’icône**
- **Animer l’icône**
- **Afficher dans le Dock**

### Général › Apparence et langue

- **Apparence** : Couleurs des Réglages, de la fenêtre des paroles, du gestionnaire de paroles et du panneau de la barre des menus
- **Langue**

### Général › Démarrage et notifications

- **Ouvrir à la connexion**
- **Lancement silencieux**
- **Notifier au changement de morceau**

### Général › Réseau

- **Proxy**

### Général › Sauvegarde et migration

- **Sauvegarde iCloud**
- **Fichier de réglages** : Contient des identifiants en clair. Exporte les réglages et la bibliothèque de paroles en deux fichiers ; l’importation remplace tous les réglages
- **Effacer tous les réglages** : Efface seulement les réglages de ce Mac ; sauvegardes et fichiers exportés conservés. Action irréversible

### Mise à jour du logiciel

- **Mise à jour du logiciel**

### Mise à jour du logiciel › Réglages de mise à jour

- **Vérifier automatiquement** : Recherche une nouvelle version une fois par jour
- **Télécharger et installer automatiquement** : Téléchargement en arrière-plan, installation à la fermeture de Lyrimuse
- **Mises à jour bêta** : Préversions, parfois instables

### À propos › Mises à jour et aide

- **Signaler un problème** : Ouvre un ticket GitHub avec votre version, macOS et lecteur déjà renseignés
- **Obtenir de l’aide** : Posez votre question dans la catégorie Q&A de GitHub Discussions
- **Liste des fonctionnalités** : Toutes les fonctionnalités, où les trouver dans Réglages et leur état par défaut

### À propos

- **Site web**
- **Communauté Discord** : Discutez avec d’autres utilisateurs, posez vos questions ou proposez des idées
- **Groupe Telegram** : Discutez avec d’autres utilisateurs, posez vos questions ou proposez des idées
- **Groupe QQ** : Discutez avec d’autres utilisateurs, posez vos questions ou proposez des idées
- **Avis de copyright**
- **Licences de tiers** : Composants et dictionnaires open source
- **Licence open source** : GPL-3.0

### À propos › Diagnostic et données

- **Exporter le diagnostic** : Journaux, rapports de plantage et état de l’app en un fichier, sans identifiants de compte. Les noms de morceaux et chemins locaux restent : relisez-le avant de le publier
- **Journal d’activité** : Le journal brut du moteur de paroles, pour vos propres diagnostics
- **Dossier de données** : Texte brut. Sans identifiants de compte, apparence ni raccourcis ; pour tout migrer, utilisez « Sauvegarde et migration »
- **Partager des données d’utilisation anonymes** : Aide à améliorer Lyrimuse : version, système, fonctions utilisées et rapports de plantage. Jamais de titres ni de comptes
- **Cache** : Illustrations et recherches récupérables à nouveau

### Labo › ListenBrainz

- **Infos du compte**

### Last.fm › Règles

- **Règles de scrobble**
- **Mode de correspondance** : L’artiste et le titre envoyés à Last.fm Intelligent : utilise la graphie la plus écoutée sur Last.fm, ou l’envoie tel quel faute de correspondance. Pour les albums, « - Single » / « - EP » est retiré Personnalisé : titre et artiste réglés séparément Brut : envoie exactement ce que le lecteur indique
- **Titre**
- **Artiste**
- **Moment du scrobble**
- **Scrobbler les morceaux de moins de 30 s** : Si activé, ces morceaux sont scrobblés à mi-lecture. Les règles officielles de Last.fm les ignorent
- **Lecteurs à scrobbler**

### Labo › Push web

- **Infos de connexion**

### Alertes push

- **Canaux** : Les bilans d’écoute partent vers tous les canaux activés. Avec plusieurs canaux, choisissez-les pour chaque bilan sous « Bilans d’écoute » ci-dessous. Cliquez sur une ligne pour la modifier ou envoyer un test ; clic droit pour supprimer
- **Heure d’envoi**
- **Bilans d’écoute**
- **Source des données**
- **Éléments** : Nombre d’artistes, d’albums et de morceaux à afficher dans chaque classement
- **Récap d’écoute hebdomadaire**
- **Bilan d’écoute quotidien**
- **Récap d’écoute mensuel**
- **Récap d’écoute annuel**
- **Historique d’envoi**

### Discord

- **Afficher sur Discord** : Une fois activé, le morceau que vous écoutez apparaît sur votre profil Discord et dans la liste d’amis. Si vos amis ne le voient pas, activez le partage d’activité dans Discord, sous Paramètres utilisateur › Confidentialité des activités
- **Contenu affiché**
- **Après « Écoute »** : Le « ×× » de « Écoute ×× » sur votre profil. Discord sur iOS et le web l’ignore et affiche toujours le lecteur Avec « Titre » ou « Artiste » ici, « Sous votre nom » ne peut pas afficher le lecteur
- **Sous votre nom** : Discord ne peut afficher sous votre nom que la première ligne, la deuxième, ou ce qui suit « Écoute ». Si ni le titre ni l’artiste n’y figurent, cette option est indisponible
- **Badge d’illustration**
- **À la pause**
- **Infos du morceau**
- **Texte d’état**
- **Illustration et progression**
- **Préfixer artiste et album** : Ajoute « par » avant l’artiste et « sur » avant l’album. Pas ajouté quand le titre et l’artiste partagent une ligne
- **Boutons**
- **Bouton personnalisé**
- **« Écouter sur le lecteur »** : Ouvre la page de ce morceau sur le site du lecteur actuel, comme un clic sur le titre. Masqué si aucune page n’existe
- **« Obtenir Lyrimuse »**
- **Confidentialité**
- **Masquer temporairement**
- **Masquer les détails du morceau** : Affiche seulement le lecteur utilisé et la progression. Le titre, l’artiste, l’album, les paroles, les liens et le bouton « Écouter sur le lecteur » ne sont pas envoyés
- **Afficher la barre de progression** : Désactivé, pas de barre de progression ; Discord affiche alors le temps écoulé, qui ne peut pas être désactivé
- **Lecteurs affichés**
