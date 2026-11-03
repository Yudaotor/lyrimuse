# Schéma d’URL de Lyrimuse

*[English](url-scheme.md) · [简体中文](url-scheme.zh-CN.md) · [日本語](url-scheme.ja.md) · [한국어](url-scheme.ko.md) · [Español](url-scheme.es.md) · **Français** · [Deutsch](url-scheme.de.md) · [Italiano](url-scheme.it.md) · [Português (Brasil)](url-scheme.pt-BR.md)*

Les liens qui commencent par `lyrimuse://` vous permettent de piloter Lyrimuse depuis Raccourcis, Raycast, Alfred, Stream Deck, le Terminal (`open 'lyrimuse://…'`) et des outils similaires : ouvrir des fenêtres et des pages de réglages, afficher ou masquer les paroles, contrôler la lecture, décaler le minutage ou obtenir ce qui est en cours de lecture.

Les plus courants se copient depuis **Liens profonds**, en bas de Réglages › Raccourcis clavier. Survolez n’importe quel raccourci de cette page pour copier le lien de l’action correspondante.

## Règles générales

- Les liens ne tiennent pas compte de la casse.
- Un lien que Lyrimuse ne reconnaît pas ne fait rien et affiche « Lien non reconnu ».
- Tout lien qui ouvre une fenêtre accepte `background=1` : la fenêtre apparaît, mais Lyrimuse ne passe pas au premier plan et ne prend pas le focus clavier. Par exemple `lyrimuse://lyrics-window?background=1`.
- Les actions de type interrupteur acceptent `on=1` ou `on=0` pour fixer un état cible (`true` / `false` et `on` / `off` fonctionnent aussi), si bien que les lancer deux fois donne le même résultat. Sans ce paramètre, elles basculent l’état.
- Les pages web peuvent aussi ouvrir des liens `lyrimuse://` (votre navigateur demande d’abord), c’est pourquoi seules des actions faciles à annuler sont exposées : interrupteurs, ouverture de fenêtres, contrôle de la lecture et décalages du minutage. Rien ne supprime ni ne modifie de paroles, ni ne touche à vos comptes.

## Ouvrir des fenêtres

| Lien | Ce qu’il fait |
|---|---|
| `lyrimuse://lyrics-window` | Ouvre la fenêtre des paroles |
| `lyrimuse://lyrics-window/search` | Ouvre la fenêtre des paroles et la fenêtre « Rechercher les paroles » (la même que `lyrics-search`) |
| `lyrimuse://lyrics-manager` | Ouvre le Gestionnaire de paroles |
| `lyrimuse://lyrics-search` | Ouvre la fenêtre « Rechercher les paroles » pour le morceau en cours |
| `lyrimuse://menubar-panel` | Ouvre ou ferme le panneau de la barre des menus |
| `lyrimuse://menubar-panel?quick=overlay` | Ouvre le panneau de la barre des menus sur les réglages rapides d’une vignette (ouvre seulement, ne ferme jamais). `quick` vaut `overlay`, `notch`, `menubar`, `touchbar`, `lyrics-window` ou `lyrics-manager` |
| `lyrimuse://menubar-menu` | Affiche le menu de l’icône de la barre des menus |
| `lyrimuse://onboarding` | Ouvre le guide de bienvenue |
| `lyrimuse://whats-new` | Affiche les nouveautés de la version installée |

## Ouvrir les réglages

`lyrimuse://settings` ouvre les Réglages. Ajoutez un chemin pour aller directement à une page, et un segment de plus pour aller à une section de cette page.

| Chemin | Page | Sections |
|---|---|---|
| `/lyrics` | Paroles | `/fetch` ou `/sources` Source, `/translation` ou `/language` Langue, `/display` ou `/timing` Minutage, `/manage` ou `/library` Bibliothèque de paroles |
| `/player` | Lecteur | `/players` Lecteur, `/linkage` Lancer et quitter, `/permissions` Autorisations et services |
| `/appearance` | Affichage des paroles | `/overlay` Paroles flottantes, `/notch` Encoche, `/menu-bar` Barre des menus, `/touch-bar` Touch Bar, `/lyrics-window` Fenêtre des paroles |
| `/shortcuts` | Raccourcis clavier | — |
| `/general` | Général | — |
| `/about` | À propos | — |
| `/account/lastfm` | Last.fm | `/stats` Statistiques, `/chart` Classements, `/on-this-day` Empreinte, `/settings` Règles |
| `/account/listenbrainz` | ListenBrainz | — |
| `/account/discord` | Discord | `/display` Contenu affiché, `/buttons` Boutons, `/privacy` Confidentialité |
| `/account/relay` | Push web | — |
| `/account/bark` | Alertes push | — |
| `/software-update` | Mise à jour de logiciels | Ajoutez `?check=1` pour rechercher aussi les mises à jour |
| `/lastfm-suggestions` | Suggestions pour le compte Last.fm | — |
| `/labs` | Labo | — |

Par exemple `lyrimuse://settings/appearance/overlay` ou `lyrimuse://settings/software-update?check=1`. Un chemin inconnu ouvre simplement les Réglages ; une section inconnue ouvre la page sur la dernière section consultée.

## Actions : `lyrimuse://action/<name>`

Ce sont les mêmes actions que les raccourcis clavier de Réglages › Raccourcis clavier. Elles exécutent le même code et affichent le même retour.

### Affichage

| Nom | Ce qu’il fait | Paramètres |
|---|---|---|
| `toggle-overlay` | Affiche ou masque les paroles flottantes | `on` |
| `toggle-notch` | Affiche ou masque les paroles de l’encoche | `on` |
| `peek-notch` | Déploie les paroles de l’encoche quelques secondes ; relancez-le pour les refermer plus tôt | — |
| `toggle-menubar-lyrics` | Affiche ou masque les paroles de la barre des menus | `on` |
| `toggle-touchbar` | Déploie ou replie les paroles de la Touch Bar (Mac avec Touch Bar uniquement) | — |
| `toggle-all-lyrics` | Masque toutes les paroles : celles qui sont affichées parmi les paroles flottantes, de l’encoche et de la barre des menus sont masquées, et le relancer réaffiche exactement celles-là | `on` (`0` masque, `1` rétablit) |
| `toggle-lock-position` | Verrouille ou déverrouille la position des paroles flottantes | `on` |
| `toggle-translation` | Affiche ou masque les traductions | `on` |
| `toggle-romanization` | Affiche ou masque la romanisation | `on` |
| `overlay-font-larger` | Agrandit les paroles flottantes | — |
| `overlay-font-smaller` | Réduit les paroles flottantes | — |

### Fenêtres

| Nom | Ce qu’il fait | Paramètres |
|---|---|---|
| `open-lyrics-manager` | Ouvre le Gestionnaire de paroles | — |
| `open-lyrics-window` | Ouvre la fenêtre des paroles | — |
| `toggle-lyrics-window-mini` | Fait passer la fenêtre des paroles de la taille mini à la taille complète et inversement ; si elle est fermée, l’ouvre en taille mini | `on` (`1` mini, `0` complète) |
| `search-lyrics` | Ouvre la fenêtre « Rechercher les paroles » | — |
| `open-settings` | Ouvre les Réglages | — |
| `open-player` | Fait passer au premier plan le lecteur que vous utilisez | — |

### Minutage des paroles

| Nom | Ce qu’il fait | Paramètres |
|---|---|---|
| `lyrics-advance` | Avance les paroles de ce morceau d’un cran | `step` : secondes pour ce décalage (de 0 à 5) ; le pas défini dans les Réglages s’il est omis |
| `lyrics-delay` | Retarde les paroles de ce morceau d’un cran | `step`, comme ci-dessus |
| `lyrics-offset-reset` | Remet à zéro le décalage des paroles de ce morceau | — |

### Lecture

| Nom | Ce qu’il fait | Paramètres |
|---|---|---|
| `play-pause` | Lecture / pause | — |
| `next-track` | Morceau suivant | — |
| `previous-track` | Morceau précédent | — |
| `toggle-favorite` | Ajoute le morceau en cours aux favoris ou l’en retire (si le lecteur le permet) | `on` (`1` favori, `0` retirer) |

Par exemple `lyrimuse://action/toggle-overlay?on=0` ou `lyrimuse://action/lyrics-advance?step=0.5`.

### Autres actions

| Lien | Ce qu’il fait |
|---|---|
| `lyrimuse://action/copy-lyric` | Copie la ligne de paroles en cours dans le presse-papiers ; ajoutez `?translation=1` pour inclure la traduction |
| `lyrimuse://action/surfaces?overlay=1&notch=0&menubar=1` | Choisit en une fois les paroles affichées : `overlay` (paroles flottantes), `notch`, `menubar`, chacun à `1` pour afficher ou `0` pour masquer. N’indiquez que ceux que vous voulez changer |
| `lyrimuse://action/lyrics-offset?ms=-300` | Fixe le décalage des paroles de ce morceau à une valeur exacte en millisecondes : positive pour avancer, négative pour retarder, dans la limite de ±10000 |
| `lyrimuse://action/play-mode?mode=shuffle` | Définit le mode de lecture : `mode` vaut `list`, `shuffle`, `repeat-all` ou `repeat-one`. Les modes que le lecteur ne gère pas reviennent à `list` |

## Obtenir ce qui est en cours de lecture (x-callback-url)

```
lyrimuse://x-callback-url/now-playing?x-success=<callback URL>
```

Lyrimuse ouvre l’URL `x-success` en y ajoutant en paramètres ce qui est en cours de lecture (les paramètres déjà présents dans `x-success` sont conservés) :

| Paramètre | Valeur |
|---|---|
| `title` | Titre du morceau |
| `artist` | Artiste |
| `album` | Album |
| `lyric` | La ligne de paroles en cours |
| `player` | Nom du lecteur |
| `playing` | `1` pendant la lecture, `0` en pause ou si rien n’est chargé (dans ce dernier cas, les champs ci-dessus sont vides) |

Dans Raccourcis, utilisez l’action **Ouvrir l’URL X-Callback** avec `lyrimuse://x-callback-url/now-playing` comme URL. Raccourcis ajoute lui-même `x-success`, et les paramètres renvoyés deviennent la sortie de l’action.

Pour que les pages web ne puissent pas utiliser ce lien pour savoir ce que vous écoutez, l’URL de rappel a deux limites : ce ne peut pas être une URL web, de fichier ou de script (`http`, `https`, `file`, `ftp`, `javascript`, `data`, `about`, `blob`, ni `lyrimuse` lui-même), et sur votre Mac elle doit être ouverte par une app qui n’est pas un navigateur. Sinon, rien n’est renvoyé.
