<!-- Generado por scripts/gen-feature-list.py a partir de shared/feature-list.json y shared/settings-catalog.json; para cambiar la lista, edita esos archivos. -->

# Lista de funciones de Lyrimuse

[English](feature-list.md) · [简体中文](feature-list.zh-CN.md) · [繁體中文](feature-list.zh-Hant.md) · [日本語](feature-list.ja.md) · [한국어](feature-list.ko.md) · Español · [Français](feature-list.fr.md) · [Deutsch](feature-list.de.md) · [Italiano](feature-list.it.md) · [Português (Brasil)](feature-list.pt-BR.md) · [Tiếng Việt](feature-list.vi.md) · [Русский](feature-list.ru.md) · [Українська](feature-list.uk.md) · [ไทย](feature-list.th.md)

Lyrimuse es una app de código abierto (GPL-3.0) para Mac con letra sincronizada palabra por palabra, para macOS 14 o posterior en Apple Silicon e Intel. Muestra la letra de Apple Music, Spotify, QQ Music, NetEase Cloud Music, Kugou, Soda Music, KKBOX, Amazon Music, LX Music, Kaset, Pear Desktop, reAMP, VOX, Pine Player, foobar2000, Swinsian, y de YouTube Music o Spotify Web en el navegador: como letra flotante en el escritorio, en el notch, en la barra de menús, en la Touch Bar o en la ventana de letra, con traducción y romanización (pinyin, jyutping cantonés, romaji japonés, romanización coreana). Hace scrobble en Last.fm y ListenBrainz, y puede mostrar en Discord lo que escuchas. La interfaz está en chino simplificado, chino tradicional, inglés, japonés, coreano, español, francés, alemán, italiano, portugués de Brasil, vietnamita, ruso, ucraniano y tailandés.

Esta lista recoge cada función de Lyrimuse: qué hace, dónde está en Ajustes y si viene activada o desactivada al instalarla; al final aparecen todos los ajustes de la ventana Ajustes. Se mantiene junto con el código y se actualiza cada vez que cambian las funciones.

## Contenido

- [Desactivadas hasta que las actives](#section-off-by-default)
- [Búsqueda de letras](#section-lyrics)
- [Traducción, romanización y procesado de la letra](#section-text)
- [Dónde aparece la letra y su aspecto](#section-display)
- [Reproductores y controles](#section-players)
- [Historial de escucha, Last.fm y compartir](#section-listening)
- [Uso diario](#section-general)
- [Todos los ajustes](#section-all-settings)

<a id="section-off-by-default"></a>

## Desactivadas hasta que las actives

Estas funciones siguen desactivadas después de instalar. Actívalas primero en Ajustes (algunas también necesitan una cuenta o un permiso):

| Función | Dónde activarla |
|---|---|
| [Letra oficial de Apple Music](#feature-apple-music-lyrics) | Ajustes › Letra › Fuente › Fuentes de letras |
| [Usar la letra que tu reproductor ya guardó](#feature-player-local-lyrics) | Ajustes › Reproductor › Permisos y servicios › Acceso total al disco |
| [Preferir la letra del archivo de la canción](#feature-prefer-local-file-lyrics) | Ajustes › Letra › Fuente › Preferir la letra del archivo de la canción |
| [Bloquear letra elegida a mano](#feature-lock-hand-picked) | Ajustes › Letra › Fuente › Bloquear letra elegida a mano |
| [Traducir si no hay traducción](#feature-machine-translation) | Ajustes › Letra › Idioma › Traducir si no hay traducción |
| [Dividir líneas largas, unir líneas cortas](#feature-split-join-lines) | Ajustes › Letra › Tiempos y cortes › Dividir líneas largas |
| [Letra del notch](#feature-notch-lyrics) | Ajustes › Mostrar letra › Notch › Letra en el notch |
| [Letra en la barra de menús](#feature-menu-bar-lyrics) | Ajustes › Mostrar letra › Barra de menús › Letra en la barra de menús |
| [Letra en la Touch Bar](#feature-touch-bar-lyrics) | Ajustes › Mostrar letra › Touch Bar › Letra en la Touch Bar |
| [La Touch Bar se aparta al escribir](#feature-touch-bar-collapse-while-typing) | Ajustes › Mostrar letra › Touch Bar › Comportamiento › Contraer al escribir |
| [Resaltado HDR en la ventana de letra](#feature-lyrics-window-hdr) | Ajustes › Mostrar letra › Ventana de letra › Color › Resaltado HDR |
| [Ocultar la ventana mini en pausa o pantalla completa](#feature-mini-window-auto-hide) | Ajustes › Mostrar letra › Ventana de letra › Comportamiento › Ocultar en pausa |
| [Fondo de Spotify Canvas](#feature-spotify-canvas) | Ajustes › Mostrar letra › Ventana de letra › Fondo › Spotify Canvas |
| [Transición de líneas](#feature-line-transition) | Ajustes › Mostrar letra › Letra flotante › Diseño › Transición de líneas |
| [Dos líneas alternas](#feature-alternate-next-line) | Ajustes › Mostrar letra › Letra flotante › Contenido › Disposición de la línea siguiente |
| [Atenuar al pasar el puntero](#feature-fade-on-hover) | Ajustes › Mostrar letra › Letra flotante › Comportamiento › Atenuar al pasar el puntero |
| [Bloquear posición, mantener pulsado para arrastrar](#feature-lock-position) | Ajustes › Mostrar letra › Letra flotante › Comportamiento › Bloquear posición |
| [Ocultar en capturas, grabaciones y pantalla compartida](#feature-hide-in-screenshots) | Ajustes › Mostrar letra › Letra flotante › Comportamiento › Ocultar en capturas |
| [Ocultar o contraer en pausa](#feature-hide-when-paused) | Ajustes › Mostrar letra › Letra flotante › Comportamiento › Ocultar en pausa |
| [Ocultar o contraer en instrumentales y sin letra](#feature-hide-when-no-lyrics) | Ajustes › Mostrar letra › Letra flotante › Comportamiento › Ocultar en instrumentales y sin letra |
| [Ocultar o contraer durante anuncios](#feature-hide-during-ads) | Ajustes › Mostrar letra › Letra flotante › Comportamiento › Ocultar durante anuncios |
| [Notch en la pantalla bloqueada](#feature-notch-show-on-lock-screen) | Ajustes › Mostrar letra › Notch › Comportamiento › Mostrar en pantalla bloqueada |
| [Ocultar la letra flotante en pantalla completa](#feature-overlay-hide-in-full-screen) | Ajustes › Mostrar letra › Letra flotante › Comportamiento › Ocultar en pantalla completa |
| [Atenuar la fila de letra del notch al pasar el puntero](#feature-notch-lyric-row-fade) | Ajustes › Mostrar letra › Notch › Fila de letra › Atenuar al pasar el puntero |
| [Letra web: teléfono o tableta como segunda pantalla, o fuente de navegador de OBS](#feature-web-lyrics) | Ajustes › Mostrar letra › Ventana de letra › Letra web |
| [YouTube Music y Spotify Web en el navegador](#feature-web-players) | Ajustes › Reproductor › Web |
| [Omitir anuncios de YouTube Music automáticamente](#feature-skip-youtube-ads) | Ajustes › Reproductor › Web › Omitir anuncios de YouTube Music |
| [Abrir y salir junto con el reproductor](#feature-player-linkage) | Ajustes › Reproductor › Abrir y salir › Abrir reproductores al iniciar |
| [Scrobble y perfil de escucha en Last.fm](#feature-lastfm) | Ajustes › Last.fm › Reglas › Reglas de scrobble |
| [Sincronizar con ListenBrainz](#feature-listenbrainz) | Ajustes › Laboratorio › ListenBrainz › Información de la cuenta |
| [Mostrar en Discord lo que escuchas](#feature-discord) | Ajustes › Discord › Mostrar en Discord |
| [Página web «Escuchando» para compartir](#feature-now-playing-page) | Ajustes › Laboratorio › Push web › Datos de conexión |
| [Resúmenes de escucha diarios, semanales, mensuales y anuales](#feature-digests) | Ajustes › Avisos push › Canales |
| [Inicio silencioso](#feature-silent-launch) | Ajustes › General › Inicio y notificaciones › Inicio silencioso |
| [Notificar al cambiar de canción](#feature-song-notifications) | Ajustes › General › Inicio y notificaciones › Notificar al cambiar de canción |
| [Actualizaciones automáticas y versiones beta](#feature-updates) | Ajustes › Actualización de software › Ajustes de actualización › Comprobar automáticamente |

<a id="section-lyrics"></a>

## Búsqueda de letras

<a id="feature-lyric-sources"></a>

### Quince fuentes de letras con búsqueda automática

NetEase Cloud Music, QQ Music, Kugou, Kuwo, Migu, Musixmatch, LRCLIB, LyricFind, Deezer, AMLL, Soda Music, VIBE, Genie, PetitLyrics y Apple Music. Cada fuente se puede desactivar, reordenar o probar para ver si está accesible ahora mismo.

- Activada por omisión
- Ajustes: Letra › Fuente › Fuentes de letras

<a id="feature-network-proxy"></a>

### Reintentar fuentes extranjeras a través de un proxy

Si una fuente de letras extranjera falla por conexión directa, Lyrimuse reintenta a través del proxy del sistema o de un proxy local como Clash. También puedes indicar un servidor proxy o no usar proxy. Las fuentes de letras de China continental siempre se conectan directamente.

- Activada por omisión
- Ajustes: General › Red › Proxy

<a id="feature-apple-music-lyrics"></a>

### Letra oficial de Apple Music

Conecta tu cuenta de Apple Music en «Fuentes de letras» para usar la letra oficial de Apple Music, en la mayoría de las canciones sincronizada palabra por palabra. Requiere una suscripción a Apple Music.

- Desactivada por omisión
- Ajustes: Letra › Fuente › Fuentes de letras

<a id="feature-matching"></a>

### Coincidencia inteligente

Por defecto, los resultados de cada fuente se puntúan por título, artista, duración y versión (en directo, instrumental, etc.) y se elige el que mejor encaja con la canción que suena. También puedes cambiar a «Orden de prioridad»: sin puntuar, se usa la primera fuente de tu orden que tenga letra.

- Ajustes: Letra › Fuente › Algoritmo de coincidencia

<a id="feature-auto-upgrade"></a>

### Volver a elegir la letra si mejora la coincidencia

Cuando una nueva versión mejora el algoritmo de coincidencia o las reglas de puntuación, la letra que ya tienes se vuelve a evaluar en segundo plano y se reemplaza si hay una versión más adecuada. Si lo desactivas, la letra elegida ya no cambia automáticamente.

- Activada por omisión
- Ajustes: Letra › Fuente › Volver a elegir tras actualizar el algoritmo

<a id="feature-prefetch"></a>

### Letra de las siguientes canciones por adelantado

Lee la cola de reproducción del reproductor y obtiene por adelantado la letra de las próximas canciones; si no puede leer la cola, prioriza el resto del álbum. QQ Music, NetEase Cloud Music, Kugou, Soda Music y VOX necesitan «Acceso total al disco» para leer la cola.

- Activada por omisión
- Ajustes: Letra › Fuente › Preparar próximas canciones
- Ajustes: Reproductor › Permisos y servicios › Acceso total al disco

<a id="feature-player-local-lyrics"></a>

### Usar la letra que tu reproductor ya guardó

La letra que Apple Music, Spotify, Kugou, KKBOX, Amazon Music y LX Music ya guardaron en este Mac se usa directamente: es la misma versión que muestra el reproductor, y llega antes (en Apple Music y Spotify, solo en canciones cuya letra ya mostró el reproductor). En QQ Music y NetEase Cloud Music, la canción se reconoce por la biblioteca local del reproductor, así que se toma esa misma versión sin buscar. Con reAMP, VOX, Pine Player, foobar2000 y Swinsian, y cuando Apple Music reproduce un archivo local de su biblioteca o LX Music una canción de su lista local, se usa la letra incrustada en el archivo o un .lrc del mismo nombre. QQ Music, NetEase Cloud Music y Kugou necesitan que actives «Acceso total al disco» para Lyrimuse en Ajustes del Sistema; sin él, la letra se sigue buscando en internet.

- Desactivada por omisión
- Ajustes: Reproductor › Permisos y servicios › Acceso total al disco

<a id="feature-prefer-local-file-lyrics"></a>

### Preferir la letra del archivo de la canción

Al reproducir un archivo de música de este Mac, se usa primero su .lrc del mismo nombre o la letra incrustada, sin compararla con la de internet. Funciona con cualquier reproductor, siempre que lo que suena sea un archivo local. Si esa letra no encaja con esta versión (por ejemplo, la duración no coincide), se busca en internet como siempre.

- Desactivada por omisión
- Ajustes: Letra › Fuente › Preferir la letra del archivo de la canción

<a id="feature-lock-hand-picked"></a>

### Bloquear letra elegida a mano

Si está activado, la letra que eliges a mano en los resultados de búsqueda queda bloqueada: ni la coincidencia automática ni una nueva búsqueda de coincidencias la reemplazan.

- Desactivada por omisión
- Ajustes: Letra › Fuente › Bloquear letra elegida a mano

<a id="feature-lyrics-manager"></a>

### Gestor de letras

Explora, edita, elimina o vuelve a buscar la letra de cualquier canción, elimina varias a la vez y borra de una vez las entradas vacías que dejan los anuncios y pódcasts. Ajusta el desfase de una sola canción si sus tiempos no cuadran. Reintenta de una vez todas las canciones sin letra o vuelve a buscar coincidencias para toda la biblioteca de letras con las reglas actuales (con pausa ajustable entre canciones); la letra editada a mano no se toca.

- Ajustes: Letra › Biblioteca de letras › Biblioteca de letras
- Ajustes: Letra › Biblioteca de letras › Buscar letras que faltan
- Ajustes: Letra › Biblioteca de letras › Volver a buscar en toda la biblioteca
- Ajustes: Atajos de teclado › Abrir gestor de letras
- Ajustes: Letra › Biblioteca de letras › Intervalo de escaneo

<a id="feature-song-entries"></a>

### Entradas de esta canción: una letra compartida

La misma canción en distintos reproductores o versiones de álbum se reconoce como una sola: sus entradas comparten una letra, las ediciones manuales y las calibraciones de tiempo se aplican a todas, y las reproducciones se suman. En el Gestor de letras, «Entradas de esta canción» compara línea por línea la letra de cada entrada; una entrada identificada por error se puede separar y volver a unir más tarde. Si desactivas la opción de compartir, cada entrada busca su letra por separado.

- Activada por omisión
- Ajustes: Letra › Fuente › Compartir letra entre entradas de una canción

<a id="feature-fix-lyrics"></a>

### Cambiar o corregir la letra al momento

Desde el menú «⋯» de la ventana de letra, busca otra letra, vuelve a buscar coincidencias automáticamente o edítala en un editor de texto externo. Al editar letra palabra por palabra solo cambia el texto; el tiempo de cada palabra se mantiene.

- Ajustes: Atajos de teclado › Buscar letra

<a id="feature-import-lyrics"></a>

### Importa tus propios archivos de letras

Importa letras en LRC, LRC mejorado, TTML, QRC, KRC, YRC o texto plano para una canción, o una carpeta entera de una vez: los archivos se asocian a las canciones de tu biblioteca y se muestran en una vista previa antes de escribir nada. Elige si las letras importadas sustituyen a las actuales, las sustituyen y las bloquean, o solo completan las canciones sin letra. Los archivos de canciones que aún no has reproducido se guardan y se usan la primera vez que suenen. Una carpeta vigilada importa los archivos nuevos automáticamente.

- Ajustes: Letra › Biblioteca de letras › Importar carpeta de letras
- Ajustes: Letra › Biblioteca de letras › Importación de carpetas
- Ajustes: Letra › Biblioteca de letras › Carpeta vigilada
- Ajustes: Letra › Biblioteca de letras › Biblioteca de importación

<a id="feature-offline"></a>

### Funciona sin conexión; la letra se guarda en .lrc

Toda la letra encontrada se guarda en caché en este Mac y se muestra sin conexión. Cada canción tiene un .lrc, más .tr.lrc y .roma.lrc si hay traducción o romanización. Los tiempos palabra por palabra se guardan en TTML por defecto, o en .yrc, LRC mejorado, QRC o KRC. Se guardan en ~/Library/Application Support/me.yudaotor.lyrimuse/lyrics/, y la ubicación se puede cambiar.

- Ajustes: Letra › Biblioteca de letras › Carpeta de letras
- Ajustes: Letra › Biblioteca de letras › Formato de letra palabra por palabra

<a id="section-text"></a>

## Traducción, romanización y procesado de la letra

<a id="feature-translation"></a>

### Traducción

La traducción que incluye la fuente aparece bajo la línea original. NetEase Cloud Music, QQ Music y Kugou traducen al chino; Musixmatch y la traducción automática siguen el idioma de traducción que elijas, entre 17. La letra flotante, la ventana de letra, el notch, la barra de menús y la Touch Bar deciden por separado si mostrarla. Se muestra por defecto si los idiomas del sistema incluyen el chino.

- Ajustes: Letra › Idioma › Idioma de traducción
- Ajustes: Mostrar letra › Letra flotante › Contenido › Traducción
- Ajustes: Atajos de teclado › Mostrar/ocultar traducción

<a id="feature-machine-translation"></a>

### Traducir si no hay traducción

Si la fuente no ofrece traducción, se usa traducción automática. En macOS 15 o posterior, con el idioma descargado, la traducción de Apple integrada en macOS se hace en este Mac y la letra no sale de él; si no se puede traducir en el Mac, las líneas se envían a Google Translate y, si tampoco está disponible, a MyMemory. Los idiomas de traducción se descargan desde la misma tarjeta.

- Desactivada por omisión
- Ajustes: Letra › Idioma › Traducir si no hay traducción
- Ajustes: Letra › Idioma › Idiomas de traducción

<a id="feature-romanization"></a>

### Romanización

Romaji japonés, romanización coreana, pinyin del mandarín y jyutping cantonés, palabra por palabra sobre la letra; otros dieciocho idiomas, como ruso, tailandés, griego o hindi, según el sistema oficial de cada idioma o una norma ISO. El idioma se detecta línea por línea: si una canción china tiene una línea en japonés, solo esa se marca. Elige aquí qué idiomas marcar; con la interfaz en chino, el pinyin está desactivado por defecto. Cada ubicación decide por separado si mostrarla.

- Activada por omisión
- Ajustes: Letra › Idioma › Idiomas de romanización
- Ajustes: Letra › Idioma › Romanización del japonés
- Ajustes: Mostrar letra › Letra flotante › Contenido › Romanización
- Ajustes: Atajos de teclado › Mostrar/ocultar romanización

<a id="feature-chinese-script"></a>

### Chino simplificado o tradicional

Muestra toda la letra china en caracteres simplificados o tradicionales, sea cual sea el idioma de la app.

- Ajustes: Letra › Idioma › Escritura china

<a id="feature-split-join-lines"></a>

### Dividir líneas largas, unir líneas cortas

La letra flotante, el notch, la barra de menús y la Touch Bar, según el ancho disponible de cada uno, dividen las líneas que no caben y unen las que pasan demasiado rápido. La ventana de letra sigue mostrando una línea por renglón. Cada opción tiene su propio interruptor.

- Desactivada por omisión
- Ajustes: Letra › Tiempos y cortes › Dividir líneas largas
- Ajustes: Letra › Tiempos y cortes › Unir líneas cortas

<a id="feature-timing-offset"></a>

### Desfase de tiempo

Adelanta o retrasa toda la letra, opcionalmente solo para un reproductor. Cada canción se puede ajustar por separado en el Gestor de letras, y los atajos de teclado la adelantan, retrasan o restablecen en cualquier momento.

- Ajustes: Letra › Tiempos y cortes › Desfase de tiempo
- Ajustes: Atajos de teclado › Adelantar letra
- Ajustes: Atajos de teclado › Retrasar letra
- Ajustes: Atajos de teclado › Restablecer desfase de la letra

<a id="section-display"></a>

## Dónde aparece la letra y su aspecto

<a id="feature-floating-lyrics"></a>

### Letra flotante en el escritorio

Letra sobre todas las ventanas, siempre visible, iluminada palabra por palabra. Arrástrala a cualquier sitio o fíjala centrada arriba en la pantalla o sobre el Dock. Con varias pantallas, puede quedarse en una o pasar a la pantalla de la ventana que estás usando. Puede mostrar a la vez romanización, traducción y la línea siguiente.

- Activada por omisión
- Ajustes: Mostrar letra › Letra flotante › Letra flotante
- Ajustes: Mostrar letra › Letra flotante › Posición
- Ajustes: Mostrar letra › Letra flotante › Contenido › Línea siguiente
- Ajustes: Atajos de teclado › Mostrar/ocultar letra flotante
- Ajustes: Mostrar letra › Letra flotante › Posición › Mostrar en

<a id="feature-notch-lyrics"></a>

### Letra del notch

Una cápsula pegada al notch, arriba en la pantalla; también funciona en Mac sin notch y en pantallas externas. Cada lado puede mostrar título, artista, álbum, ilustración, controles de reproducción, o tiempo transcurrido o restante, junto a una onda de audio que se mueve con la música. Al pasar el puntero se expande con controles, barra de progreso, calibración de la letra y botones rápidos como favorito o buscar letra. Durante los anuncios muestra el tiempo restante.

- Desactivada por omisión
- Ajustes: Mostrar letra › Notch › Letra en el notch
- Ajustes: Mostrar letra › Notch › Estilo
- Ajustes: Mostrar letra › Notch › Pantalla
- Ajustes: Mostrar letra › Notch › Izquierda
- Ajustes: Atajos de teclado › Mostrar/ocultar letra en el notch
- Ajustes: Atajos de teclado › Echar un vistazo al notch
- Ajustes: Mostrar letra › Notch › Expandido › Acciones rápidas

<a id="feature-menu-bar-lyrics"></a>

### Letra en la barra de menús

La línea actual aparece en la barra de menús y se desplaza si es demasiado larga, sin cortarse. Puedes añadir una segunda línea con la siguiente, la traducción o la romanización. También puede ir en el centro de la barra de menús, junto al notch si la pantalla lo tiene, o mostrar solo el título, con o sin el artista.

- Desactivada por omisión
- Ajustes: Mostrar letra › Barra de menús › Letra en la barra de menús
- Ajustes: Mostrar letra › Barra de menús › Diseño › Posición
- Ajustes: Mostrar letra › Barra de menús › Contenido › Qué se muestra
- Ajustes: Mostrar letra › Barra de menús › Contenido › Segunda línea
- Ajustes: Atajos de teclado › Alternar letra en la barra de menús

<a id="feature-touch-bar-lyrics"></a>

### Letra en la Touch Bar

En un MacBook Pro con Touch Bar, la línea actual se desplaza a medida que se canta, con ilustración y controles de reproducción opcionales. La letra puede ser blanca, seguir la ilustración, usar un color personalizado o fluir como un arcoíris, con brillo ajustable para la parte sin cantar. Puede expandirse al empezar a reproducir y contraerse en pausa; el botón «Más» ofrece calibración de la letra, favorito, aleatorio y repetición, volumen y progreso.

- Desactivada por omisión
- Ajustes: Mostrar letra › Touch Bar › Letra en la Touch Bar
- Ajustes: Atajos de teclado › Expandir/contraer letra de la Touch Bar
- Ajustes: Mostrar letra › Touch Bar › Color › Color del texto
- Ajustes: Mostrar letra › Touch Bar › Comportamiento › Expandir al empezar a reproducir
- Ajustes: Mostrar letra › Touch Bar › Diseño › Mostrar botón «Más»

<a id="feature-touch-bar-collapse-while-typing"></a>

### La Touch Bar se aparta al escribir

Mientras el cursor está en un campo de texto, la letra de la Touch Bar puede contraerse para mostrar los candidatos del método de entrada y las sugerencias de escritura, y volver a expandirse al salir. Requiere el permiso de «Accesibilidad».

- Desactivada por omisión
- Ajustes: Mostrar letra › Touch Bar › Comportamiento › Contraer al escribir

<a id="feature-lyrics-window"></a>

### Ventana de letra

Letra a página completa inspirada en la vista de letras de Apple Music: la ilustración difuminada de fondo y toda la canción desplazándose hasta la línea actual; los duetos se separan por cantante, los coros van en su propia línea y las notas sostenidas se agrandan y brillan. El fondo puede seguir la ilustración o ser un color sólido, un degradado o vidrio esmerilado, y se pueden ajustar el grosor del texto, el color de lo cantado y la alineación. Ábrela desde el icono de la barra de menús o con un atajo.

- Ajustes: Mostrar letra › Ventana de letra › Ventana de letra
- Ajustes: Mostrar letra › Ventana de letra › Fondo › Fondo
- Ajustes: Atajos de teclado › Abrir ventana de letra
- Ajustes: Mostrar letra › Ventana de letra › Diseño › Alineación

<a id="feature-lyrics-window-hdr"></a>

### Resaltado HDR en la ventana de letra

En pantallas HDR, la parte cantada de la línea actual en la ventana de letra brilla por encima del blanco normal. Desactivado por defecto; consume más energía al activarlo. Solo en tamaño completo.

- Desactivada por omisión
- Ajustes: Mostrar letra › Ventana de letra › Color › Resaltado HDR

<a id="feature-mini-lyrics-window"></a>

### Ventana de letra mini

La ventana de letra reducida a una pequeña tarjeta: solo la línea actual, la actual y la siguiente, o una página completa con desplazamiento. El fondo, el color del texto, la fuente, el grosor, el color de lo cantado, y el título, la ilustración y el tiempo de la parte superior se ajustan por separado.

- Ajustes: Mostrar letra › Ventana de letra › Diseño › Diseño de la letra
- Ajustes: Atajos de teclado › Cambiar a tamaño mini/completo

<a id="feature-mini-window-auto-hide"></a>

### Ocultar la ventana mini en pausa o pantalla completa

La ventana mini se oculta en pausa o sin reproducción y vuelve al empezar a reproducir; también puede ocultarse cuando una app está a pantalla completa en su pantalla (un vídeo, un juego). Cada opción tiene su propio interruptor.

- Desactivada por omisión
- Ajustes: Mostrar letra › Ventana de letra › Comportamiento › Ocultar en pausa
- Ajustes: Mostrar letra › Ventana de letra › Comportamiento › Ocultar en pantalla completa

<a id="feature-animated-artwork"></a>

### Ilustración animada

Los álbumes con ilustración animada en Apple Music, QQ Music o NetEase Cloud Music también se mueven en la ventana de letra a tamaño completo, igual que los álbumes cuya ilustración animada guardó Kugou Music al reproducirlos allí. Se detiene en modo de bajo consumo o con «Reducir movimiento» activado. Puedes ver cuánto espacio ocupan las ilustraciones animadas descargadas y borrarlas.

- Activada por omisión
- Ajustes: Mostrar letra › Ventana de letra › Ilustración › Ilustración animada
- Ajustes: Mostrar letra › Ventana de letra › Ilustración › Caché de ilustraciones animadas

<a id="feature-spotify-canvas"></a>

### Fondo de Spotify Canvas

Si una canción tiene un vídeo en bucle (Canvas) en Spotify, el fondo de la ventana de letra a tamaño completo pasa a ser ese vídeo. Solo se usan los vídeos que Spotify ya guardó en este Mac, así que solo lo tienen las canciones que hayas reproducido en Spotify, también al reproducirlas en otro reproductor. No se reproduce en modo de bajo consumo ni con «Reducir movimiento» activado.

- Desactivada por omisión
- Ajustes: Mostrar letra › Ventana de letra › Fondo › Spotify Canvas

<a id="feature-idle-overview"></a>

### Resumen de escucha sin reproducción

Cuando no suena nada, la ventana de letra muestra la última canción, una línea de su letra y un botón «Reanudar». Con Last.fm conectado, también muestra tus reproducciones de hoy, de los últimos 7 días y en total, la tendencia de 30 días, «Un día como hoy» y lo último que escuchaste, con ilustración.

<a id="feature-look"></a>

### Aspecto personalizable

Fuente (la del sistema, o una .ttf / .otf importada), tamaño, grosor, color del texto y del fondo, contorno y fondo esmerilado. La letra flotante incluye varios temas de color y puede guardar tus colores como tema; el color del texto puede seguir la ilustración del álbum, y la letra flotante, el notch, la barra de menús y la Touch Bar también pueden fluir como un arcoíris. El tamaño de la letra flotante también se cambia al momento con atajos, o manteniendo ⌘ y girando la rueda del ratón o deslizando dos dedos sobre la letra.

- Ajustes: Mostrar letra › Letra flotante › Tema
- Ajustes: Mostrar letra › Letra flotante › Tema › Mis temas
- Ajustes: Mostrar letra › Notch › Fila de letra › Color de la letra
- Ajustes: Mostrar letra › Barra de menús › Color › Arcoíris
- Ajustes: Mostrar letra › Letra flotante › Fuente › Fuente
- Ajustes: Mostrar letra › Letra flotante › Color › Fondo esmerilado
- Ajustes: Atajos de teclado › Aumentar tamaño de la letra flotante
- Ajustes: Atajos de teclado › Reducir tamaño de la letra flotante

<a id="feature-karaoke"></a>

### Efecto karaoke palabra por palabra

Cada palabra se ilumina a medida que se canta. La letra flotante, el notch, la barra de menús, la Touch Bar y los tamaños completo y mini de la ventana de letra tienen su propio interruptor; desactivado, toda la línea se ilumina a la vez.

- Activada por omisión
- Ajustes: Mostrar letra › Letra flotante › Color › Efecto karaoke
- Ajustes: Mostrar letra › Notch › Fila de letra › Efecto karaoke
- Ajustes: Mostrar letra › Barra de menús › Color › Efecto karaoke
- Ajustes: Mostrar letra › Touch Bar › Color › Efecto karaoke
- Ajustes: Mostrar letra › Ventana de letra › Color › Efecto karaoke

<a id="feature-line-transition"></a>

### Transición de líneas

Cuando la letra flotante pasa a la siguiente línea, la anterior sale hacia arriba y la nueva entra tras ella, en lugar de sustituirse sin más.

- Desactivada por omisión
- Ajustes: Mostrar letra › Letra flotante › Diseño › Transición de líneas

<a id="feature-alternate-next-line"></a>

### Dos líneas alternas

La letra flotante puede mostrar también la línea siguiente al mismo tamaño, una a la izquierda y otra a la derecha, por turnos como el karaoke de escritorio clásico: la línea ya cantada se sustituye por la que va después de la siguiente y la que se está cantando no se mueve.

- Desactivada por omisión
- Ajustes: Mostrar letra › Letra flotante › Contenido › Disposición de la línea siguiente

<a id="feature-fade-on-hover"></a>

### Atenuar al pasar el puntero

Con el puntero encima, la letra flotante se vuelve semitransparente y no tapa lo que hay debajo. La ventana de letra mini tiene su propio interruptor y, mientras está atenuada, puede dejar pasar los clics a la ventana de abajo; mantén pulsada ⌥ para usar la ventana mini.

- Desactivada por omisión
- Ajustes: Mostrar letra › Letra flotante › Comportamiento › Atenuar al pasar el puntero
- Ajustes: Mostrar letra › Ventana de letra › Comportamiento › Atenuar al pasar el puntero
- Ajustes: Mostrar letra › Ventana de letra › Comportamiento › Dejar pasar clics al atenuarse

<a id="feature-lock-position"></a>

### Bloquear posición, mantener pulsado para arrastrar

Bloqueada, la letra flotante no se puede arrastrar; o bien exige mantener pulsado antes de arrastrar, para evitar movimientos accidentales.

- Desactivada por omisión
- Ajustes: Mostrar letra › Letra flotante › Comportamiento › Bloquear posición
- Ajustes: Mostrar letra › Letra flotante › Comportamiento › Mantener pulsado para arrastrar
- Ajustes: Atajos de teclado › (Des)bloquear posición

<a id="feature-hover-controls"></a>

### Mostrar controles al pasar el puntero

Con el puntero sobre la letra flotante aparece una fila de botones rápidos. La letra de la barra de menús también puede mostrar controles de reproducción al pasar el puntero.

- Activada por omisión
- Ajustes: Mostrar letra › Letra flotante › Comportamiento › Mostrar controles al pasar el puntero
- Ajustes: Mostrar letra › Barra de menús › Comportamiento › Mostrar controles al pasar el puntero

<a id="feature-hide-in-screenshots"></a>

### Ocultar en capturas, grabaciones y pantalla compartida

Al hacer capturas, grabar la pantalla o compartirla en una reunión, los demás no ven la letra, pero tú sí. La letra flotante y el notch tienen cada uno su interruptor.

- Desactivada por omisión
- Ajustes: Mostrar letra › Letra flotante › Comportamiento › Ocultar en capturas
- Ajustes: Mostrar letra › Notch › Comportamiento › Ocultar en capturas

<a id="feature-hide-when-paused"></a>

### Ocultar o contraer en pausa

En pausa o sin reproducción, la letra flotante y el notch se ocultan; el notch también puede solo reducirse al tamaño del notch de la pantalla.

- Desactivada por omisión
- Ajustes: Mostrar letra › Letra flotante › Comportamiento › Ocultar en pausa
- Ajustes: Mostrar letra › Notch › Comportamiento › Ocultar en pausa
- Ajustes: Mostrar letra › Notch › Comportamiento › Contraer en pausa

<a id="feature-hide-when-no-lyrics"></a>

### Ocultar o contraer en instrumentales y sin letra

Si la canción es instrumental, o la búsqueda confirma que no hay letra, la letra flotante y la ventana de letra mini pueden ocultarse y el notch y la Touch Bar pueden contraer su fila de letra; mientras se busca, se muestra como siempre. Cada uno tiene su propio interruptor.

- Desactivada por omisión
- Ajustes: Mostrar letra › Letra flotante › Comportamiento › Ocultar en instrumentales y sin letra
- Ajustes: Mostrar letra › Ventana de letra › Comportamiento › Ocultar en instrumentales y sin letra
- Ajustes: Mostrar letra › Notch › Comportamiento › Contraer fila de letra en instrumentales y sin letra
- Ajustes: Mostrar letra › Touch Bar › Comportamiento › Contraer en instrumentales y sin letra

<a id="feature-hide-during-ads"></a>

### Ocultar o contraer durante anuncios

Mientras el reproductor reproduce un anuncio, la letra flotante puede ocultarse y el notch puede contraerse a una franja superior, que se sigue expandiendo al pasar el puntero. Cada uno tiene su propio interruptor.

- Desactivada por omisión
- Ajustes: Mostrar letra › Letra flotante › Comportamiento › Ocultar durante anuncios
- Ajustes: Mostrar letra › Notch › Comportamiento › Contraer durante anuncios

<a id="feature-hide-in-full-screen"></a>

### Ocultar el notch en pantalla completa

La letra del notch se contrae automáticamente en pantalla completa, como al ver un vídeo o jugar.

- Activada por omisión
- Ajustes: Mostrar letra › Notch › Comportamiento › Ocultar en pantalla completa

<a id="feature-notch-show-on-lock-screen"></a>

### Notch en la pantalla bloqueada

Con la pantalla bloqueada, el notch sigue mostrando la canción en reproducción y su letra.

- Desactivada por omisión
- Ajustes: Mostrar letra › Notch › Comportamiento › Mostrar en pantalla bloqueada

<a id="feature-overlay-hide-in-full-screen"></a>

### Ocultar la letra flotante en pantalla completa

Por defecto, la letra flotante queda siempre por encima de las apps a pantalla completa. Si lo activas, se oculta en pantalla completa, como al ver un vídeo o jugar, y vuelve al salir.

- Desactivada por omisión
- Ajustes: Mostrar letra › Letra flotante › Comportamiento › Ocultar en pantalla completa

<a id="feature-title-on-change"></a>

### Mostrar título al cambiar de canción

Con cada cambio de canción, el título y el artista de la nueva salen del notch, se quedan un momento y vuelven a recogerse.

- Activada por omisión
- Ajustes: Mostrar letra › Notch › Comportamiento › Mostrar título al cambiar de canción

<a id="feature-listening-milestones"></a>

### Hitos de escucha

Cuando una canción llega a su reproducción número 100, 1000 o 10 000, o tu total de Last.fm pasa una cifra redonda, el notch se expande una vez para avisarte. Requiere Last.fm conectado.

- Activada por omisión
- Ajustes: Mostrar letra › Notch › Comportamiento › Hitos de escucha

<a id="feature-notch-gestures"></a>

### Gestos del trackpad en el notch

Con el puntero sobre el notch, desliza dos dedos a izquierda o derecha para cambiar de canción, o arriba y abajo para ajustar el volumen del sistema.

- Activada por omisión
- Ajustes: Mostrar letra › Notch › Comportamiento › Gestos del trackpad
- Ajustes: Mostrar letra › Notch › Comportamiento › Mostrar con teclas de volumen

<a id="feature-notch-lyric-row-fade"></a>

### Atenuar la fila de letra del notch al pasar el puntero

Con el puntero sobre la fila de letra del notch, este no se expande: la fila se atenúa y los clics pasan a la ventana de abajo; solo se expande desde el propio notch o sus lados.

- Desactivada por omisión
- Ajustes: Mostrar letra › Notch › Fila de letra › Atenuar al pasar el puntero

<a id="feature-notch-multiline-lyrics"></a>

### Varias líneas de letra en el notch expandido

Al expandirse el notch bajo el puntero, la zona de la letra pasa a ser una lista de 3, 5 o 7 líneas: la línea actual se ilumina palabra por palabra, la lista sube con cada línea nueva y al hacer clic en una línea saltas a ella. Si la fila de letra está desactivada, el notch sigue siendo una franja de estado y solo muestra la letra al expandirse.

- Activada por omisión
- Ajustes: Mostrar letra › Notch › Expandido › Letra en varias líneas
- Ajustes: Mostrar letra › Notch › Expandido › Líneas

<a id="feature-web-lyrics"></a>

### Letra web: teléfono o tableta como segunda pantalla, o fuente de navegador de OBS

Muestra la letra en un navegador. «Letra web» muestra lo mismo que la ventana de letra; «Salida a OBS» tiene fondo transparente, las mismas fuentes y colores que la letra flotante y, arriba a la izquierda, una tarjeta de título (título, artista e ilustración) que puede mostrarse siempre, al cambiar de canción o nunca. Cada una tiene su propio puerto y acceso desde la red local; por defecto solo están disponibles en este Mac, y con «Permitir acceso desde la red local» activado, los dispositivos de la misma red pueden abrirlas escaneando un código QR, con un enlace que lleva una clave de acceso. Con «Permitir control remoto» activado, la página también puede controlar la reproducción y saltar a una línea.

- Desactivada por omisión
- Ajustes: Mostrar letra › Ventana de letra › Letra web
- Ajustes: Mostrar letra › Ventana de letra › Letra web › Permitir acceso desde la red local
- Ajustes: Mostrar letra › Letra flotante › OBS › Salida a OBS
- Ajustes: Mostrar letra › Letra flotante › OBS › Tarjeta de título
- Ajustes: Mostrar letra › Ventana de letra › Letra web › Permitir control remoto

<a id="section-players"></a>

## Reproductores y controles

<a id="feature-players"></a>

### Diecisiete reproductores, varios a la vez o detección automática

Apple Music, Spotify, QQ Music, NetEase Cloud Music, Kugou, Soda Music, LX Music, KKBOX, Amazon Music, reAMP (al estilo de Winamp), VOX (reproductor local centrado en audio sin pérdida y de alta resolución), Pine Player (reproductor local gratuito compatible con casi cualquier formato), foobar2000 (veterano reproductor local llegado de Windows), Swinsian (reproductor local pensado para bibliotecas grandes), Kaset, una app de YouTube Music, y Pear Desktop, una app de escritorio de código abierto para YouTube Music. Puedes elegir varios a la vez o dejar la detección automática, que sigue al reproductor que aparece en «Reproduciendo» de macOS. Admite la radio de Apple Music: cuando habla el locutor, muestra el nombre y el logotipo de la emisora.

- Ajustes: Reproductor › Apps de música

<a id="feature-web-players"></a>

### YouTube Music y Spotify Web en el navegador

Tras vincular tu navegador, la música que suena en una página web también tiene letra, y el progreso se toma directamente de la página. Una comprobación de un clic confirma antes si ese navegador se puede controlar. Durante los anuncios, el notch muestra el tiempo restante y qué número de anuncio es.

- Desactivada por omisión
- Ajustes: Reproductor › Web

<a id="feature-skip-youtube-ads"></a>

### Omitir anuncios de YouTube Music automáticamente

Cuando aparece el botón «Omitir» en YouTube Music en el navegador o en Pear Desktop, se pulsa automáticamente. Si está desactivado, puedes omitirlos tú desde el notch. Requiere el permiso de «Accesibilidad».

- Desactivada por omisión
- Ajustes: Reproductor › Web › Omitir anuncios de YouTube Music
- Ajustes: Reproductor › Permisos y servicios › Accesibilidad

<a id="feature-other-players"></a>

### Añadir otros reproductores

Los reproductores que no están en la lista se pueden elegir en «Aplicaciones» y añadir a los de confianza; si detecta un reproductor desconocido sonando, Lyrimuse también pregunta si quieres añadirlo.

- Ajustes: Reproductor › Otras apps
- Ajustes: Reproductor › Añadir app…
- Ajustes: Reproductor › Avisos de nuevos reproductores

<a id="feature-permissions"></a>

### Permisos solo cuando hacen falta

Apple Music, Spotify, Kaset, VOX y Swinsian necesitan el permiso de «Automatización» para leer el estado de reproducción; QQ Music, NetEase Cloud Music y Kugou necesitan «Acceso total al disco» para usar su letra local y su cola, y Soda Music y VOX lo necesitan para leer su cola. La calibración del progreso de Amazon Music y Pine Player, la lista de Pine Player, los botones de aleatorio, repetición y favorito de QQ Music, NetEase Cloud Music, Kugou Music, Soda Music, Amazon Music, reAMP, Pine Player y foobar2000, el volumen de foobar2000 y, cuando otra app ocupa «Reproduciendo», los botones de reproducción de QQ Music, NetEase Cloud Music, Soda Music, Pine Player y foobar2000 requieren el permiso de «Accesibilidad». Los reproductores web necesitan el permiso de «Automatización» para el navegador y activar en él «Permitir JavaScript de Apple Events». Los demás reproductores no necesitan permisos. Ajustes indica el estado actual de cada uno.

- Ajustes: Reproductor › Permisos y servicios › Permiso de automatización
- Ajustes: Reproductor › Permisos y servicios › Acceso total al disco
- Ajustes: Reproductor › Permisos y servicios › Accesibilidad

<a id="feature-controls"></a>

### Controles de reproducción y saltar a otro punto

Reproduce, pausa, cambia de canción y arrastra la barra de progreso desde la ventana de letra o el notch expandido. Aleatorio, repetición, favorito y volumen dependen del reproductor: Apple Music, Spotify, Kaset, QQ Music, Amazon Music, reAMP, VOX, Pine Player, foobar2000, Swinsian, Pear Desktop y YouTube Music en el navegador admiten algunos o todos; NetEase Cloud Music, Kugou Music, Soda Music y LX Music admiten favorito, y LX Music también el volumen si activas Open API en sus ajustes. Reproducir, pausar, cambiar de canción y favorito también admiten atajos globales. Cuando otra app, como un vídeo del navegador, ocupa «Reproduciendo» en el sistema, reproducir, pausar y cambiar de canción en QQ Music, NetEase Cloud Music, Soda Music, Pine Player y foobar2000 pasan por sus propios menús o barra de reproducción, y no se puede saltar a otro punto arrastrando el progreso.

- Ajustes: Mostrar letra › Notch › Expandido › Mostrar controles de reproducción
- Ajustes: Atajos de teclado › Reproducir/Pausa
- Ajustes: Atajos de teclado › Canción siguiente
- Ajustes: Atajos de teclado › Canción anterior
- Ajustes: Atajos de teclado › Añadir/quitar de favoritos
- Ajustes: Reproductor › Permisos y servicios › Open API de LX Music

<a id="feature-song-pages"></a>

### Abrir la página de la canción con un clic

Haz clic en el menú «⋯» para abrir la página de la canción, su álbum o su artista en esa plataforma. Apple Music y KKBOX se abren en sus apps, y las canciones de Spotify en su app; el resto se abre en la web: álbumes y artistas de Spotify, QQ Music, Soda Music, Amazon Music y YouTube Music. NetEase Cloud Music y Kugou solo ofrecen la página de la canción.

<a id="feature-about-panels"></a>

### Información de canción, álbum y artista

Haz clic en el título, el artista o el álbum en la ventana de letra o en el notch expandido para leer su descripción. Las de álbum y artista vienen primero de Apple Music; si no hay, con la interfaz en chino se buscan en Soda Music, Kugou Music y NetEase Cloud Music, luego en Wikipedia a través de YouTube Music y, por último, en Last.fm. Las de canción vienen, con la interfaz en chino, primero de QQ Music y después de Last.fm. Para usar Last.fm hay que conectar tu cuenta.

<a id="feature-player-linkage"></a>

### Abrir y salir junto con el reproductor

Se ajusta por reproductor: abrir el reproductor al abrir Lyrimuse, abrir Lyrimuse al abrir el reproductor, o salir automáticamente cuando se cierren todos los reproductores que sigue.

- Desactivada por omisión
- Ajustes: Reproductor › Abrir y salir › Abrir reproductores al iniciar
- Ajustes: Reproductor › Abrir y salir › Abrir con el reproductor
- Ajustes: Reproductor › Abrir y salir › Salir con el reproductor

<a id="section-listening"></a>

## Historial de escucha, Last.fm y compartir

<a id="feature-lastfm"></a>

### Scrobble y perfil de escucha en Last.fm

Conecta Last.fm con un clic, sin copiar ningún token. Consulta tus reproducciones de hoy, de los últimos 7 días y en total, y las listas de artistas, álbumes y canciones con sus cambios de puesto; «Huella» ofrece un mapa de calor del año (haz clic en un día para ver lo que más escuchaste), las horas de escucha, los países y regiones de tus artistas habituales y «Un día como hoy». Cualquier canción reciente se puede marcar como favorita con el corazón.

- Desactivada por omisión
- Ajustes: Last.fm › Reglas › Reglas de scrobble

<a id="feature-scrobble-rules"></a>

### Reglas de scrobble personalizadas

Cuenta una reproducción al llegar al 50 %, 75 % o 90 %, o solo al terminar; decide si cuentan las canciones de menos de 30 segundos; por defecto, los créditos compartidos, las variantes de escritura china y sufijos como “- Single” se ajustan a la entrada oficial de Last.fm, o puedes enviarlo todo tal cual; y puedes excluir por completo un reproductor de Last.fm.

- Ajustes: Last.fm › Reglas › Momento del scrobble
- Ajustes: Last.fm › Reglas › Hacer scrobble de canciones de menos de 30 s
- Ajustes: Last.fm › Reglas › Modo de coincidencia
- Ajustes: Last.fm › Reglas › Reproductores para scrobble

<a id="feature-local-log"></a>

### Cada reproducción se registra primero en el Mac

Sin Last.fm conectado, el historial de escucha se guarda primero en este Mac; tras conectarlo, haz clic en «Enviar pendientes» en «Scrobbles pendientes» de la página de Last.fm para subirlo. Los registros que quizá no llegaron mientras estaba conectado se comprueban con Last.fm y se reenvían automáticamente. Last.fm solo acepta reproducciones de las dos últimas semanas aproximadamente.

<a id="feature-listenbrainz"></a>

### Sincronizar con ListenBrainz

Cada reproducción se envía a Last.fm y a ListenBrainz a partir del mismo estado de reproducción, así que ambos registros coinciden. También puedes importar a ListenBrainz las reproducciones que tu iPhone registró en Last.fm. Está en «Laboratorio», en la barra lateral.

- Desactivada por omisión
- Ajustes: Laboratorio › ListenBrainz › Información de la cuenta

<a id="feature-discord"></a>

### Mostrar en Discord lo que escuchas

Tu perfil y tu lista de amigos muestran el reproductor, el título, el artista, la ilustración y una barra de progreso; al hacer clic en el título o el artista se abre su página en la web del reproductor. La línea del álbum puede mostrar la letra que se está cantando y bajo el perfil puedes añadir hasta dos botones. Puedes elegir cómo se distribuye el texto, qué reproductores cuentan, si se mantiene en pausa y qué icono lleva la ilustración; también mostrar solo el reproductor sin datos de la canción, u ocultarlo durante un tiempo.

- Desactivada por omisión
- Ajustes: Discord › Mostrar en Discord
- Ajustes: Discord › Reproductores mostrados
- Ajustes: Discord › Al pausar
- Ajustes: Discord › Ocultar temporalmente
- Ajustes: Discord › Qué se muestra
- Ajustes: Discord › Botones
- Ajustes: Discord › Ocultar detalles de la canción

<a id="feature-now-playing-page"></a>

### Página web «Escuchando» para compartir

Una página pública con lo que estás escuchando y tu historial, a la que puedes añadir muro de mensajes, reacciones, contador de visitas, top 10 de artistas y efecto vinilo. Basta con configurar ListenBrainz para mostrar la reproducción en directo y el historial; para lo demás, despliega un Cloudflare Worker siguiendo la guía. Está en «Laboratorio».

- Desactivada por omisión
- Ajustes: Laboratorio › Push web › Datos de conexión

<a id="feature-digests"></a>

### Resúmenes de escucha diarios, semanales, mensuales y anuales

Se envían a los canales que configures, varios a la vez si quieres: Bark, ntfy, ServerChan, Feishu, DingTalk, WeCom, Telegram, Discord, Slack o un webhook genérico. Cada canal permite previsualizar el envío y mandar una prueba; el historial de envíos muestra si cada uno llegó, y los que no llegaron se pueden reenviar. Los informes se comparan con el periodo anterior, indican qué artistas escuchaste por primera vez y cuánto tiempo escuchaste, y se adaptan al formato de cada plataforma, con la ilustración del álbum y un enlace a la lista completa. Los cuatro resúmenes tienen su propio interruptor y, con varios canales, cada uno elige a cuáles enviarse; puedes fijar la hora de envío (según la zona horaria actual de este Mac) y cuántos puestos muestra cada lista; cada canal puede usar el contenido completo, breve o de resumen, o tu propio título y cuerpo con marcadores.

- Desactivada por omisión
- Ajustes: Avisos push › Canales
- Ajustes: Avisos push › Hora de envío
- Ajustes: Avisos push › Informes de escucha
- Ajustes: Avisos push › Origen de datos
- Ajustes: Avisos push › Elementos por lista
- Ajustes: Avisos push › Informe diario de escucha
- Ajustes: Avisos push › Resumen semanal de escucha
- Ajustes: Avisos push › Resumen de escucha mensual
- Ajustes: Avisos push › Resumen de escucha anual
- Ajustes: Avisos push › Historial de envíos

<a id="section-general"></a>

## Uso diario

<a id="feature-onboarding"></a>

### Asistente del primer inicio

La primera vez que abres Lyrimuse, te guía paso a paso para elegir reproductores, vincular un navegador y decidir dónde aparece la letra, y revisa uno a uno los permisos necesarios para que concedas al momento los que falten.

<a id="feature-language"></a>

### Interfaz en chino simplificado, chino tradicional, inglés, japonés, coreano, español, francés, alemán, italiano, portugués de Brasil, vietnamita, ruso, ucraniano y tailandés

Por defecto sigue al sistema, y usa el inglés si el idioma del sistema no está entre ellos; el cambio se aplica al instante, sin reiniciar.

- Ajustes: General › Aspecto e idioma › Idioma

<a id="feature-appearance"></a>

### Claro, oscuro o según el sistema

Ajustes, la ventana de letra, el Gestor de letras y el panel de la barra de menús pueden usar siempre el aspecto claro u oscuro; por defecto siguen al sistema. La letra flotante sigue siempre al sistema y el notch es siempre oscuro.

- Ajustes: General › Aspecto e idioma › Aspecto

<a id="feature-shortcuts"></a>

### Atajos de teclado globales

Puedes asignar atajos para mostrar u ocultar cada tipo de letra (o toda a la vez, útil en reuniones y al compartir pantalla), abrir la ventana de letra y el Gestor de letras, buscar letra, ajustar los tiempos, controlar la reproducción, marcar como favorito, cambiar al reproductor, etc. Por defecto no se usa ninguna tecla.

- Ajustes: Atajos de teclado › Abrir ajustes
- Ajustes: Atajos de teclado › Ocultar/restaurar todas las letras
- Ajustes: Atajos de teclado › Cambiar al reproductor
- Ajustes: Atajos de teclado › Abrir/cerrar panel de la barra de menús

<a id="feature-deep-links"></a>

### Enlaces profundos (lyrimuse://)

Los enlaces lyrimuse:// abren cualquier página de Ajustes, la ventana de letra y el Gestor de letras, y ejecutan todas las acciones que admiten atajos (controles de reproducción, favorito, ocultar toda la letra, etc.) desde Atajos, Raycast, Alfred y herramientas similares. Si se abren con x-callback-url desde Atajos, también pueden devolver como parámetros el título, el artista, el álbum y la línea actual. La tarjeta «Enlaces profundos» de la página «Atajos de teclado» lista todos los enlaces, listos para copiar.

- Ajustes: Atajos de teclado › Enlaces profundos

<a id="feature-settings-search"></a>

### Buscar en Ajustes

Escribe en la parte superior de la barra lateral de Ajustes para saltar al ajuste correspondiente, resaltado, incluso dentro de secciones contraídas. Admite búsquedas en chino e inglés.

<a id="feature-menu-bar-icon"></a>

### Icono de la barra de menús

12 iconos que se mueven con la música mientras suena y quedan quietos en pausa; también puede ser la ilustración del álbum que suena, con tamaño ajustable. Las acciones habituales están en su menú.

- Activada por omisión
- Ajustes: General › Barra de menús y Dock › Icono de la barra de menús
- Ajustes: General › Barra de menús y Dock › Ilustración del álbum
- Ajustes: General › Barra de menús y Dock › Tamaño del icono
- Ajustes: General › Barra de menús y Dock › Animar icono

<a id="feature-dock-icon"></a>

### Mostrar en el Dock

Si lo desactivas, solo queda el icono de la barra de menús.

- Activada por omisión
- Ajustes: General › Barra de menús y Dock › Mostrar en el Dock

<a id="feature-launch-at-login"></a>

### Abrir al iniciar sesión

Abre Lyrimuse automáticamente al iniciar sesión en el Mac.

- Activada por omisión
- Ajustes: General › Inicio y notificaciones › Abrir al iniciar sesión

<a id="feature-silent-launch"></a>

### Inicio silencioso

Al abrirse no muestra ninguna ventana, solo el icono de la barra de menús.

- Desactivada por omisión
- Ajustes: General › Inicio y notificaciones › Inicio silencioso

<a id="feature-song-notifications"></a>

### Notificar al cambiar de canción

Envía una notificación del sistema con cada cambio de canción.

- Desactivada por omisión
- Ajustes: General › Inicio y notificaciones › Notificar al cambiar de canción

<a id="feature-backup"></a>

### Copia de seguridad de ajustes y paso a un Mac nuevo

Exporta todos los ajustes a un solo archivo, guardado por defecto en iCloud Drive o en la carpeta que elijas; la primera vez que abres Lyrimuse en un Mac nuevo, si encuentra una copia en iCloud, te pregunta si quieres importarla.

- Ajustes: General › Copia de seguridad y migración › Copia de seguridad de iCloud
- Ajustes: General › Copia de seguridad y migración › Archivo de ajustes

<a id="feature-updates"></a>

### Actualizaciones automáticas y versiones beta

Busca nuevas versiones automáticamente; en la página «Actualización de software» puedes leer las notas e instalarlas. Para probar antes las novedades, activa «Actualizaciones beta».

- Desactivada por omisión
- Ajustes: Actualización de software › Ajustes de actualización › Comprobar automáticamente
- Ajustes: Actualización de software › Ajustes de actualización › Descargar e instalar automáticamente
- Ajustes: Actualización de software › Ajustes de actualización › Actualizaciones beta

<a id="feature-diagnostics"></a>

### Exportar diagnóstico e informar de problemas con un clic

Empaqueta registros, informes de fallos y el estado de la app en un solo archivo, sin credenciales de cuentas ni tu nombre de usuario. «Informar de un problema» abre un issue en GitHub con la versión, el sistema y el reproductor ya incluidos.

- Ajustes: Acerca de › Diagnóstico y datos › Exportar diagnóstico
- Ajustes: Acerca de › Actualizaciones y ayuda › Informar de un problema

<a id="feature-telemetry"></a>

### Datos de uso anónimos, desactivables cuando quieras

Como máximo una vez al día, envía al servidor del propio autor la versión, el sistema, qué funciones están activadas y resúmenes de fallos, para decidir qué arreglar primero. No incluye títulos, artistas, rutas locales ni cuentas. Activado por defecto; se puede desactivar en Ajustes y en la pantalla de bienvenida del primer inicio.

- Ajustes: Acerca de › Diagnóstico y datos › Compartir datos de uso anónimos

<a id="section-all-settings"></a>

## Todos los ajustes

Todos los ajustes de la ventana Ajustes, según dónde están: 315 en total. Escribe un nombre en el campo de búsqueda de la parte superior de la barra lateral de Ajustes para ir directamente a él.

### Letra › Fuente

- **Fuentes de letras**
- **Algoritmo de coincidencia**
- **Preferir la letra del archivo de la canción**: Al reproducir un archivo local, usar primero su .lrc del mismo nombre o la letra incrustada
- **Volver a elegir tras actualizar el algoritmo**: Se reevalúa en segundo plano; puede cambiar a una versión mejor
- **Compartir letra entre entradas de una canción**: Una copia por grabación en todos los reproductores y versiones de álbum; las ediciones también se sincronizan
- **Bloquear letra elegida a mano**: La letra que eliges a mano nunca se sustituye automáticamente
- **Preparar próximas canciones**: Obtiene por adelantado la letra de las próximas canciones

### Letra › Idioma

- **Idioma de traducción**
- **Traducir si no hay traducción**: Traduce primero en este Mac y en línea cuando no es posible
- **Idiomas de traducción**: Idiomas del sistema usados para la traducción en el dispositivo
- **Escritura china**
- **Idiomas de romanización**
- **Romanización del japonés**: Romaji, o hiragana solo en los kanji

### Letra › Tiempos y cortes

- **Dividir líneas largas**: Las líneas demasiado largas se dividen y se muestran por partes
- **Unir líneas cortas**: Las líneas cortas contiguas se unen si caben en una línea
- **Desfase de tiempo**: Los valores positivos adelantan la letra y los negativos la retrasan

### Letra › Biblioteca de letras

- **Biblioteca de letras**
- **Buscar letras que faltan**: Solo canciones sin letra o con letra en texto sin formato
- **Volver a buscar en toda la biblioteca**: Incluye canciones que ya tienen letra, salvo las editadas, calibradas e instrumentales
- **Intervalo de escaneo**: Segundos entre canciones; se recomiendan al menos 2 segundos para evitar límites de solicitudes
- **Carpeta de letras**: Los archivos existentes no se mueven al cambiar la ubicación
- **Formato de letra palabra por palabra**
- **Importar carpeta de letras**: Empareja los archivos de letra de una carpeta con las canciones de tu biblioteca, con vista previa antes de importar
- **Importación de carpetas**
- **Carpeta vigilada**: Los archivos de letra nuevos o modificados de la carpeta se importan solos: las canciones sin letra la reciben de inmediato y las que ya tienen no cambian
- **Biblioteca de importación**: Ver y eliminar las letras importadas

### Reproductor

- **Apps de música**
- **Web**: La letra también funciona con música en un navegador. Haz clic en + para vincular el navegador que usas; la posición se lee directamente de la página, así que la letra se sincroniza al instante tras cambiar de canción
- **Otras apps**: Las apps que no aparecen arriba también pueden usarse como reproductores: una vez añadidas, sus canciones muestran letra y cuentan en tu historial de escucha
- **Añadir app…**: Elige una en Aplicaciones, sin esperar a que empiece a reproducir
- **Avisos de nuevos reproductores**

### Reproductor › Web

- **Omitir anuncios de YouTube Music**: Los anuncios que se pueden omitir se omiten en cuanto aparecen

### Reproductor › Permisos y servicios

- **Permiso de automatización**
- **Acceso total al disco**
- **Accesibilidad**
- **Open API de LX Music**: Lyrimuse lee la posición de reproducción de LX Music y ajusta su volumen mediante esta API
- **API de Pear Desktop**: Lyrimuse lee de Pear Desktop el ID y el tipo de la canción actual y la cola de reproducción a través de esta API
- **Motor de letras**: Lee el estado de reproducción y obtiene la letra y la ilustración

### Reproductor › Abrir y salir

- **Abrir y salir**: Solo aparecen los reproductores que seleccionaste. Con «Detección automática» activada, también aparecen los instalados en este Mac
- **Abrir reproductores al iniciar**
- **Abrir con el reproductor**
- **Salir con el reproductor**

### Mostrar letra › Letra flotante

- **Letra flotante**
- **OBS**
- **Tema**
- **Ancho**
- **Posición**
- **Restaurar valores predeterminados**: Solo restablece el tema, la fuente y los colores

### Mostrar letra › Letra flotante › OBS

- **Salida a OBS**: Superpón la letra en tu emisión como fuente de navegador. Ajusta su ancho y alto al tamaño del lienzo de OBS
- **URL de la fuente de navegador**
- **Tarjeta de título**: Muestra el título, el artista y la ilustración en la esquina superior izquierda
- **Permitir acceso desde la red local**: Los dispositivos de la misma red pueden conectarse con un enlace que incluye una clave de acceso
- **Enlace de acceso**
- **Enlace alternativo (dirección IP)**
- **Restablecer clave de acceso**: Los enlaces que ya compartiste dejarán de funcionar
- **Puerto**: Tras cambiarlo, actualiza la URL en OBS

### Mostrar letra › Letra flotante › Tema

- **Mis temas**

### Mostrar letra › Letra flotante › Fuente

- **Fuente**
- **Grosor**
- **Tamaño**
- **Tamaño romanización**
- **Tamaño traducción**
- **Tamaño sig. línea**

### Mostrar letra › Letra flotante › Color

- **Efecto karaoke**
- **Color del texto**
- **Contorno del texto**
- **Color del contorno**
- **Color sin cantar**
- **Color de fondo**
- **Fondo esmerilado**
- **Densidad del cristal**

### Mostrar letra › Letra flotante › Contenido

- **Romanización**
- **Traducción**
- **Línea siguiente**
- **Disposición de la línea siguiente**: Alternar: las dos líneas al mismo tamaño, una a la izquierda y otra a la derecha; la que se acaba de cantar pasa a la que va después de la siguiente. Se ocultan la traducción y la romanización de línea; los duetos se muestran como siempre

### Mostrar letra › Letra flotante › Diseño

- **Alineación**
- **Líneas largas**
- **Transición de líneas**: Al cambiar de línea, la siguiente sube a su sitio. Si está desactivado, las líneas cambian al instante
- **Espaciado de romanización**
- **Espaciado de traducción**
- **Espaciado de línea siguiente**

### Mostrar letra › Letra flotante › Comportamiento

- **Bloquear posición**
- **Mantener pulsado para arrastrar**
- **Atenuar al pasar el puntero**
- **Mostrar controles al pasar el puntero**
- **Ocultar en capturas**
- **Ocultar en pausa**
- **Ocultar en instrumentales y sin letra**
- **Ocultar durante anuncios**
- **Ocultar en pantalla completa**

### Mostrar letra › Letra flotante › Posición

- **Mostrar en**

### Mostrar letra › Notch

- **Letra en el notch**
- **Estilo**
- **Pantalla**
- **Izquierda**
- **Derecha**
- **Ancho**
- **Ancho expandido**
- **Restaurar valores predeterminados**: No cambia el ancho ni el interruptor «Letra en el notch»

### Mostrar letra › Notch › Estilo

- **Fondo expandido**
- **Esquinas**
- **Esquinas expandidas**
- **Línea de progreso**: Muestra el progreso de reproducción cuando no está expandido

### Mostrar letra › Notch › Izquierda

- **Onda de audio**: Se muestra en un solo lado a la vez

### Mostrar letra › Notch › Fila de letra

- **Mostrar letra al contraer**: Si se desactiva, solo queda la franja a la altura del notch hasta que pases el puntero para expandir
- **Alineación**
- **Color de la letra**
- **Segunda línea**
- **Ver línea siguiente al expandir**
- **Altura**
- **Efecto karaoke**
- **Mostrar ilustración**
- **Posición de la ilustración**
- **Atenuar al pasar el puntero**

### Mostrar letra › Notch › Fuente

- **Fuente**
- **Grosor**
- **Tamaño**

### Mostrar letra › Notch › Expandido

- **Letra en varias líneas**: Muestra varias líneas de letra al expandirse, con la línea actual iluminándose palabra por palabra
- **Líneas**
- **Mostrar controles de reproducción**
- **Mostrar desfase de letra**
- **Acciones rápidas**
- **Información de la canción**

### Mostrar letra › Notch › Comportamiento

- **Contraer en pausa**
- **Ocultar en capturas**
- **Ocultar en pausa**
- **Contraer fila de letra en instrumentales y sin letra**
- **Contraer durante anuncios**
- **Ocultar en pantalla completa**
- **Mostrar en pantalla bloqueada**
- **Hitos de escucha**
- **Mostrar título al cambiar de canción**
- **Mostrar con teclas de volumen**
- **Gestos del trackpad**

### Mostrar letra › Barra de menús

- **Letra en la barra de menús**
- **Restaurar valores predeterminados**: El ancho y el interruptor «Letra en la barra de menús» no cambian

### Mostrar letra › Barra de menús › Contenido

- **Qué se muestra**
- **Segunda línea**
- **Icono junto a la letra**: El icono se llena de abajo arriba para mostrar el progreso de reproducción, con los colores de «Color»

### Mostrar letra › Barra de menús › Diseño

- **Posición**: Centro: la letra aparece en medio de la barra de menús, sin tapar los menús de las apps, los iconos de la derecha ni el notch
- **Mostrar en**
- **Modo de ancho**: Fijo: todas las canciones usan el ancho definido Adaptable: cada canción toma su ancho de su letra, hasta el ancho definido
- **Alineación**

### Mostrar letra › Barra de menús › Color

- **Efecto karaoke**
- **Arcoíris**: La letra fluye de izquierda a derecha con los colores del arcoíris, más oscura en una barra de menús clara; los colores del sistema vuelven mientras el menú está abierto
- **Color del texto**
- **Color cantado**

### Mostrar letra › Barra de menús › Fuente

- **Fuente**
- **Grosor**
- **Tamaño**

### Mostrar letra › Barra de menús › Ancho

- **Ancho máximo**

### Mostrar letra › Barra de menús › Comportamiento

- **Mostrar controles al pasar el puntero**
- **Mostrar título si no hay letra**: Muestra el título de la canción en lugar de la letra si no hay o aún se está buscando

### Mostrar letra › Touch Bar

- **Letra en la Touch Bar**
- **Restaurar valores predeterminados**: El interruptor «Letra en la Touch Bar» no cambia

### Mostrar letra › Touch Bar › Contenido

- **Segunda línea**
- **Sin traducción**
- **Sin romanización**
- **Tamaño**

### Mostrar letra › Touch Bar › Diseño

- **Alineación**
- **Mostrar ilustración**
- **Posición de la ilustración**
- **Mostrar controles de reproducción**: Anterior, Reproducir/Pausa y Siguiente, más un botón de ajustes
- **Posición de los controles**
- **Mostrar botón «Más»**: Tócalo para cambiar a posición de reproducción, calibración de letra, favorito, aleatorio/repetir y volumen. Se ocultan los elementos que el reproductor actual no admite
- **Ocultar Control Strip al expandir**: La letra ocupa toda la Touch Bar. Para acceder al brillo, el volumen y otros botones del sistema, toca primero ✕ a la izquierda para contraer la letra
- **Control Strip**: Añade, quita o reordena los botones de brillo, volumen y otros del sistema a la derecha de la Touch Bar en Ajustes del Sistema › Teclado › Ajustes de la Touch Bar…

### Mostrar letra › Touch Bar › Color

- **Efecto karaoke**
- **Color del texto**: Blanco, color de la ilustración, color personalizado o arcoíris
- **Brillo del texto atenuado**: Brillo de las palabras sin cantar y de la segunda línea

### Mostrar letra › Touch Bar › Comportamiento

- **Expandir al empezar a reproducir**: Muestra la letra al reanudar tras una pausa. Cambiar de canción durante la reproducción no la expande, y la letra que contraigas sigue contraída
- **Contraer en pausa**: Se contrae al botón de la Control Strip tras 10 segundos en pausa y se expande de nuevo al reanudar
- **Contraer en instrumentales y sin letra**: Solo se contrae tras confirmar que no hay letra y se expande de nuevo al encontrarla. Se sigue mostrando durante la búsqueda
- **Contraer al escribir**: Se contrae mientras el cursor está en un campo de texto para mostrar los candidatos del método de entrada y las sugerencias de escritura, y se expande al salir. Requiere el permiso de «Accesibilidad»

### Mostrar letra › Ventana de letra

- **Ventana de letra**
- **Letra web**: Mostrar la ventana de letra en un navegador web
- **Restaurar valores predeterminados**

### Mostrar letra › Ventana de letra › Letra web

- **Dirección local**
- **Permitir acceso desde la red local**: Los dispositivos de la misma red pueden conectarse con un enlace que incluye una clave de acceso
- **Permitir control remoto**: Controla la reproducción y salta a la letra desde otros dispositivos
- **Enlace de acceso**
- **Enlace alternativo (dirección IP)**
- **Restablecer clave de acceso**: Los enlaces que ya compartiste dejarán de funcionar
- **Puerto**: Tras cambiarlo, vuelve a escanear el código QR para reconectar

### Mostrar letra › Ventana de letra › Fondo

- **Fondo**: Fondo de la ventana de letra: según la ilustración, color sólido, degradado o vidrio esmerilado
- **Dirección**
- **Spotify Canvas** (solo tamaño completo): Usa el vídeo en bucle de la canción en Spotify como fondo; solo para canciones que hayas reproducido en Spotify
- **Densidad del cristal**: Densidad del material de cristal esmerilado (cinco niveles)
- **Color inferior**

### Mostrar letra › Ventana de letra › Fuente

- **Tamaño** (solo tamaño mini): Tamaño máximo del texto de la letra en tamaño mini
- **Fuente**: Fuente de la ventana de letra (texto, traducción y romanización)
- **Grosor**

### Mostrar letra › Ventana de letra › Diseño

- **Líneas largas** (solo tamaño mini): Si las líneas largas se ajustan o se desplazan en el tamaño mini
- **Diseño de la letra** (solo tamaño mini): Una línea: solo la línea actual Dos líneas: la actual y la siguiente Varias líneas: una página de letra con desplazamiento, como en el tamaño completo
- **Alineación** (solo tamaño completo): Alineación de la letra en tamaño completo; «Auto» sigue las voces del dueto

### Mostrar letra › Ventana de letra › Comportamiento

- **Atenuar al pasar el puntero** (solo tamaño mini)
- **Dejar pasar clics al atenuarse** (solo tamaño mini): Al atenuarse, los clics pasan a la ventana de abajo. Mantén pulsada ⌥ para volverla opaca e interactuar
- **Ocultar en pausa** (solo tamaño mini)
- **Ocultar en instrumentales y sin letra** (solo tamaño mini)
- **Ocultar en pantalla completa** (solo tamaño mini)

### Mostrar letra › Ventana de letra › Color

- **Efecto karaoke**
- **Color del texto**: Color del texto de la ventana de letra. «Auto» alterna entre claro y oscuro según el brillo del fondo
- **Color personalizado**
- **Color cantado**
- **Resaltado HDR** (solo tamaño completo): Ilumina la parte cantada en pantallas HDR. Consume más energía al activarlo

### Mostrar letra › Ventana de letra › Contenido

- **Romanización**
- **Traducción**
- **Barra de progreso** (solo tamaño mini): Si se desactiva, solo aparece cuando se muestran los controles al pasar el puntero

### Mostrar letra › Ventana de letra › Encabezado

- **Título** (solo tamaño mini): Muestra el título, el artista y el álbum arriba en el tamaño mini
- **Artista** (solo tamaño mini)
- **Álbum** (solo tamaño mini)
- **Ilustración** (solo tamaño mini): La miniatura de la ilustración junto a la información superior del tamaño mini
- **Tiempo** (solo tamaño mini): Muestra el tiempo transcurrido y la duración arriba en el tamaño mini
- **Ancho** (solo tamaño mini): Cuánto ancho de la ventana ocupa el encabezado del tamaño mini
- **Altura** (solo tamaño mini): Cuánta altura de la ventana ocupa el encabezado del tamaño mini; el texto y la ilustración se escalan con él

### Mostrar letra › Ventana de letra › Ilustración

- **Ilustración animada** (solo tamaño completo): Solo en algunos álbumes; se pausa en modo de bajo consumo o con «Reducir movimiento» activado
- **Caché de ilustraciones animadas** (solo tamaño completo): Espacio en disco que ocupan las ilustraciones animadas descargadas; lo que borres se volverá a descargar la próxima vez que se muestre

### Atajos de teclado

- **Enlaces profundos**: Ábrelos desde Atajos, Raycast, Alfred y herramientas similares. Pasa el puntero sobre un atajo de arriba para copiar el enlace de esa acción
- **Mostrar/ocultar letra flotante**
- **Mostrar/ocultar letra en el notch**
- **Echar un vistazo al notch**
- **Alternar letra en la barra de menús**
- **Expandir/contraer letra de la Touch Bar**
- **Ocultar/restaurar todas las letras**
- **(Des)bloquear posición**
- **Mostrar/ocultar traducción**
- **Mostrar/ocultar romanización**
- **Aumentar tamaño de la letra flotante**
- **Reducir tamaño de la letra flotante**
- **Abrir gestor de letras**
- **Abrir ventana de letra**
- **Cambiar a tamaño mini/completo**
- **Buscar letra**
- **Abrir ajustes**
- **Cambiar al reproductor**
- **Abrir/cerrar panel de la barra de menús**
- **Adelantar letra**
- **Retrasar letra**
- **Restablecer desfase de la letra**
- **Incremento**: Cantidad por pulsación
- **Reproducir/Pausa**
- **Canción siguiente**
- **Canción anterior**
- **Añadir/quitar de favoritos**

### General › Barra de menús y Dock

- **Icono de la barra de menús**
- **Ilustración del álbum**
- **Tamaño del icono**
- **Animar icono**
- **Mostrar en el Dock**

### General › Aspecto e idioma

- **Aspecto**: Colores de Ajustes, la ventana de letra, el gestor de letras y el panel de la barra de menús
- **Idioma**

### General › Inicio y notificaciones

- **Abrir al iniciar sesión**
- **Inicio silencioso**
- **Notificar al cambiar de canción**

### General › Red

- **Proxy**

### General › Copia de seguridad y migración

- **Copia de seguridad de iCloud**
- **Archivo de ajustes**: Incluye credenciales en texto sin cifrar. Exporta los ajustes y la biblioteca de letras como dos archivos; al importar se sustituyen todos los ajustes
- **Borrar todos los ajustes**: Solo borra los ajustes de este Mac; las copias de seguridad y los archivos exportados se conservan. No se puede deshacer

### Actualización de software

- **Actualización de software**

### Actualización de software › Ajustes de actualización

- **Comprobar automáticamente**: Busca una nueva versión una vez al día
- **Descargar e instalar automáticamente**: Se descarga en segundo plano y se instala al salir de Lyrimuse
- **Actualizaciones beta**: Versiones preliminares; pueden ser inestables

### Acerca de › Actualizaciones y ayuda

- **Informar de un problema**: Abre una incidencia en GitHub con tu versión, macOS y reproductor ya incluidos
- **Obtener ayuda**: Pregunta en la categoría Q&A de GitHub Discussions
- **Lista de funciones**: Todas las funciones, dónde encontrarlas en Ajustes y su estado predeterminado

### Acerca de

- **Sitio web**
- **Comunidad de Discord**: Charla con otros usuarios, haz preguntas o sugiere funciones
- **Grupo de Telegram**: Charla con otros usuarios, haz preguntas o sugiere funciones
- **Grupo de QQ**: Charla con otros usuarios, haz preguntas o sugiere funciones
- **Aviso de copyright**
- **Licencias de terceros**: Componentes y diccionarios de código abierto
- **Licencia de código abierto**: GPL-3.0

### Acerca de › Diagnóstico y datos

- **Exportar diagnóstico**: Registros, informes de fallos y estado de la app en un solo archivo, sin credenciales de cuentas. Incluye nombres de pistas y rutas locales, así que revísalo antes de publicarlo
- **Registro de actividad**: El registro sin procesar del motor de letras, para resolver problemas por tu cuenta
- **Carpeta de datos**: Texto sin formato. No incluye credenciales de cuentas, aspecto ni atajos; para migrarlo todo, usa «Copia de seguridad y migración»
- **Compartir datos de uso anónimos**: Ayuda a mejorar Lyrimuse: versión, sistema, funciones usadas e informes de fallos. Nunca títulos de canciones ni cuentas
- **Caché**: Ilustraciones y consultas que se pueden volver a obtener

### Laboratorio › ListenBrainz

- **Información de la cuenta**

### Last.fm › Reglas

- **Reglas de scrobble**
- **Modo de coincidencia**: El artista y el título que se envían a Last.fm Inteligente: usa la grafía más escuchada en Last.fm o la envía tal cual si no hay coincidencia. En los álbumes se quita « - Single» / « - EP» Personalizado: define título y artista por separado Sin procesar: envía exactamente lo que indica el reproductor
- **Título**
- **Artista**
- **Momento del scrobble**
- **Hacer scrobble de canciones de menos de 30 s**: Si está activado, se hace scrobble de estas canciones al llegar a la mitad. Las reglas oficiales de Last.fm las omiten
- **Reproductores para scrobble**

### Laboratorio › Push web

- **Datos de conexión**

### Avisos push

- **Canales**: Los informes de escucha van a todos los canales activados. Si tienes varios, elige los canales de cada informe en «Informes de escucha», más abajo. Haz clic en una fila para editarla o enviar una prueba; clic secundario para eliminarla
- **Hora de envío**
- **Informes de escucha**
- **Origen de datos**
- **Elementos por lista**: Cuántos artistas, álbumes y canciones principales mostrar
- **Resumen semanal de escucha**
- **Informe diario de escucha**
- **Resumen de escucha mensual**
- **Resumen de escucha anual**
- **Historial de envíos**

### Discord

- **Mostrar en Discord**: Si está activado, la canción que escuchas se muestra en tu perfil de Discord y en la lista de amigos. Si tus amigos no la ven, ve a Ajustes de usuario › Privacidad de actividad en Discord y activa compartir la actividad
- **Qué se muestra**
- **Tras “Escuchando”**: El “××” de “Escuchando ××” en tu perfil. Discord en iOS y en la web lo ignora y sigue mostrando el reproductor Con «Título» o «Artista» aquí, «Debajo de tu nombre» no puede mostrar el reproductor
- **Debajo de tu nombre**: Discord solo puede mostrar bajo tu nombre la primera línea, la segunda o lo que sigue a “Escuchando”. Si ni el título ni el artista están en uno de esos sitios, esa opción no está disponible
- **Insignia en la ilustración**
- **Al pausar**
- **Datos de la canción**
- **Texto de estado**
- **Ilustración y progreso**
- **Etiquetar artista y álbum**: Añade “de” antes del artista y “en” antes del álbum. No se añade si el título y el artista comparten línea
- **Botones**
- **Botón personalizado**
- **«Escuchar en el reproductor»**: Abre la página de esta canción en la web del reproductor actual, igual que hacer clic en el título. Se oculta si no hay página
- **«Obtener Lyrimuse»**
- **Privacidad**
- **Ocultar temporalmente**
- **Ocultar detalles de la canción**: Solo muestra el reproductor que usas y el progreso. No se envían el título, el artista, el álbum, la letra, los enlaces ni el botón «Escuchar en el reproductor»
- **Mostrar barra de progreso**: Si se desactiva, no hay barra de progreso; Discord muestra el tiempo transcurrido, que no se puede desactivar
- **Reproductores mostrados**
