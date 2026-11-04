# Cómo hace Lyrimuse scrobble en Last.fm

*[English](scrobbling.md) · [简体中文](scrobbling.zh-CN.md) · [日本語](scrobbling.ja.md) · [한국어](scrobbling.ko.md) · **Español** · [Français](scrobbling.fr.md) · [Deutsch](scrobbling.de.md) · [Italiano](scrobbling.it.md) · [Português (Brasil)](scrobbling.pt-BR.md) · [Tiếng Việt](scrobbling.vi.md) · [Русский](scrobbling.ru.md)*

## 1. Cuándo cuenta una reproducción

Una reproducción se envía cuando se cumplen **todas** estas condiciones:

| Regla | Valor |
|---|---|
| Se ha reproducido lo suficiente | la mitad de la canción, con un máximo de 240 s, o 240 s si no se conoce la duración. Hay puntos más estrictos solo para Last.fm: consulta §1b |
| La canción dura lo suficiente | `≥ 30s` (se aceptan las canciones de duración desconocida). Se puede desactivar: consulta §1a |
| No es un anuncio | Las pausas publicitarias de Spotify se detectan y se omiten |

La reproducción se muestrea cada 5 segundos y el tiempo transcurrido se cuenta con el reloj real, así que al pausar se detiene el recuento y saltar hacia delante no lo infla. Si entre dos muestras pasan más de 60 segundos (el Mac entró en reposo o el motor se reinició), ese intervalo se descarta en lugar de contarse.

Estos umbrales coinciden con las [pautas de scrobbling de Last.fm](https://www.last.fm/api/scrobbling).

### 1a. Canciones de menos de 30 segundos

Ajustes → Plataformas vinculadas → Last.fm → *Reglas* → **Hacer scrobble de canciones de menos de 30 s** (`scrobble_short_tracks`,
**desactivado** por omisión). La regla de Last.fm *"The track must be longer than 30 seconds"* (la canción debe durar más de 30 segundos) es una regla del lado del cliente:
el servidor no rechaza las canciones cortas ni tiene un código de descarte por «demasiado corta». Aun así, todos los clientes de scrobble
habituales la respetan, así que Lyrimuse también lo hace por omisión. Al activarlo, las canciones cortas cuentan en cuanto
cumplen la regla de la mitad (una canción de 20 segundos necesita 10). Es un ajuste **solo de Last.fm**:
las canciones cortas se envían a Last.fm (y se anotan en el registro local del que sale el envío diferido a Last.fm), pero
nunca se envían a ListenBrainz, cuyo comportamiento no cambia en ningún caso.

### 1b. Momento del scrobble

Ajustes → Plataformas vinculadas → Last.fm → *Reglas* → **Momento del scrobble** (`lastfm_scrobble_point`,
**50%** por omisión). Hasta dónde debe reproducirse una canción para que se haga scrobble en Last.fm:

| Ajuste | Valor | Se hace scrobble cuando |
|---|---|---|
| **50%** (por omisión) | `50` | se cumple la regla de Last.fm de arriba: la mitad de la canción, con un máximo de 4 minutos |
| 75% / 90% | `75` / `90` | se ha reproducido el 75% / 90% de la duración de la canción: solo cuenta el tiempo reproducido, sin el límite de 4 minutos |
| Al final | `end` | la canción se reproduce hasta el final; saltar hacia delante no cuenta |

La regla de Last.fm es un mínimo, así que no hay ningún ajuste por debajo del 50%. Es **solo de Last.fm**: ListenBrainz y
el relé web siguen enviando al llegar al 50%; solo el scrobble de Last.fm (y el registro local del que sale
el envío diferido a Last.fm) espera al punto elegido. Si una canción se salta antes de ese punto, no se envía nada a
Last.fm: es el ajuste haciendo su trabajo, no un scrobble perdido. Las canciones de duración desconocida siguen la
regla por omisión.

*Al final* se decide según la última posición de reproducción observada cuando cambia la canción: quedar a 12
segundos o menos del final (el 10% de la duración en canciones cortas) cuenta como reproducida entera, así que el fundido cruzado
de un reproductor o una transición sin pausas no impide el scrobble.

## 2. Qué se envía

`track.scrobble` escribe la entrada permanente en tu historial; `track.updateNowPlaying` activa el indicador
de «escuchando ahora» y no guarda nada.

| Campo | `track.scrobble` | `track.updateNowPlaying` |
|---|---|---|
| `artist` | ✅ | ✅ |
| `track` | ✅ | ✅ |
| `timestamp` | ✅ | — |
| `album` | si no está vacío | si no está vacío |
| `duration` | si se conoce | si se conoce |

No llega nada más a Last.fm. Su API también acepta `mbid`, `albumArtist`, `trackNumber`,
`chosenByUser`, `streamId` y `context` en un scrobble; Lyrimuse no envía ninguno.

## 3. Qué no se reescribe

En la vía de ListenBrainz, y en los modos *Todo* y *Solo el primero* de Last.fm, los nombres de artista, canción y álbum
se envían exactamente como los informó el reproductor. (El modo *Inteligente* de Last.fm reescribe el
artista y la canción para que coincidan con la entrada del catálogo: consulta la sección siguiente.)

El único procesamiento que se aplica es la limpieza de caracteres invisibles: los espacios de no separación y los de ancho completo
pasan a ser espacios normales, se eliminan los caracteres de ancho cero y los BOM, las secuencias de espacios se reducen
a uno y se recortan los espacios del principio y del final. Sin esto, un espacio de no separación invisible
crea una entidad de artista aparte en Last.fm.

No se cambia nada visible: ni las mayúsculas, ni el chino tradicional frente al simplificado, ni los
subtítulos entre paréntesis, ni los créditos de varios artistas. `PRINCE` sigue siendo `PRINCE`, `無所謂` sigue siendo
`無所謂`, y `一口 (The Day You Left Me)` conserva su subtítulo.

Por qué no hay, por omisión, una búsqueda externa para «normalizar» los nombres:

- Lyrimuse hacía justo eso. Una auditoría de una biblioteca real de unas 2500 canciones encontró unos 200
  nombres de artista reescritos, entre ellos `USA for Africa` → `Xtc Planet` y `LBI利比` → `Safehse`.
  Los scrobbles ya escritos en una página pública de artista de Last.fm no se pueden corregir después: la
  base de datos de correcciones está congelada.
- La guía de scrobbling de Last.fm lo dice dos veces: *"Do not use the corrections returned by the now
  playing service as input for the scrobble request, unless they have been explicitly approved by
  the user."* (no uses las correcciones que devuelve el servicio de «escuchando ahora» como entrada de la petición de scrobble, salvo que el usuario las haya aprobado explícitamente). Su indicador `autocorrect` está
  [documentado como heredado](https://support.last.fm/t/scrobbles-of-japanese-artists-getting-separated-by-romanization-of-their-name/119906).
- De nueve clientes de scrobble de código abierto analizados (Web Scrobbler, Pano Scrobbler, Navidrome, Maloja,
  rescrobbled, mpdscribble, mpdas, Koito, multi-scrobbler), ninguno reescribe por omisión los nombres de artista a partir de una
  búsqueda externa.

## 4. Modo de coincidencia

Ajustes → Plataformas vinculadas → Last.fm → *Reglas* → **Modo de coincidencia**
(`lastfm_match_mode` en `~/Library/Application Support/me.yudaotor.lyrimuse/lyrimuse-features.json`):

| Modo | Valor | Efecto |
|---|---|---|
| **Inteligente** (por omisión en instalaciones nuevas) | `smart` | Busca la entrada de esta canción en el catálogo de Last.fm y envía el artista y el título de esa entrada (ver abajo) |
| Personalizado | `custom` | Elige qué partes pueden cambiar: ver abajo |
| **Sin procesar** (por omisión en instalaciones existentes) | `raw` | Exactamente lo que informa el reproductor, sin conectarse a la red |

*Personalizado* añade dos filas, una para el título y otra para el artista:

| Fila | Opción | Efecto |
|---|---|---|
| **Título** | Coincidencia | El título puede sustituirse por la grafía de la entrada del catálogo, y se quita « - Single» / « - EP» del álbum (`lastfm_match_track`) |
| | Sin procesar | El título se envía tal cual |
| **Artista** | Coincidencia | El artista puede sustituirse por la grafía de la entrada del catálogo (`lastfm_match_artist`) |
| | Solo el primero | Recorta un crédito conjunto a su primer artista (`Khalil Fong & Fiona Sit` → `Khalil Fong`): solo manipula texto, sin conectarse a la red (`lastfm_match_first_artist_only`) |
| | Sin procesar | El artista se envía tal cual |

Si solo una de las dos filas está en «Coincidencia», **un candidato solo se acepta si el otro campo ya
coincide**; si no, el resultado sería una combinación que no existe en el catálogo, que acaba de nuevo
en una entrada fantasma con un solo oyente: tú.

«Solo el primero» es distinto de «Coincidencia»: se aplica **solo cuando no se ha encontrado ninguna coincidencia**. Una
grafía encontrada ya es la entrada que Last.fm reconoce, y recortarla la convertiría en una
entrada que no existe: `Hall & Oates / Maneater` (800 000 oyentes) se quedaría en `Hall`. Así que
título «Sin procesar» con artista «Solo el primero» es, byte a byte, el antiguo modo *Solo el primero*, todavía sin conectarse a la red.

*Sin procesar* sigue siendo el predeterminado allí donde ya existe un `lyrimuse-features.json`, porque recortar un
crédito es irreversible: borra a Fiona Sit de tu historial. La opción homónima de Navidrome
(`Lastfm.ScrobbleFirstArtistOnly`) también está desactivada por omisión.

La separación es conservadora: `/` se trata aparte de `,` y `&`, así que `K/DA` y `AC/DC` no
se dividen en `K` y `AC`.

### Modo inteligente

Lo que informa el reproductor y el nombre que el catálogo de Last.fm da a la misma grabación a menudo no tienen los
mismos caracteres, y enviarlo tal cual hace que la reproducción caiga en una entrada «fantasma»: sin MBID, sin álbum, con
duración cero y un solo oyente: tú. Medido con 《那个女孩》 de David Tao: el reproductor informa
`陶喆, 卢广仲 / 那个女孩`, que Last.fm no tiene en absoluto; la versión simplificada `陶喆 / 那个女孩` tiene
126 oyentes; y la entrada real de la canción es la tradicional **`陶喆 / 那個女孩`: 889 oyentes,
4580 reproducciones y duración en el catálogo**. El propio `autocorrect` de Last.fm no ayuda: no relaciona
el chino tradicional con el simplificado.

Por eso *Inteligente* busca la canción antes de enviarla:

1. `track.getInfo` tal como se informó. **Si tiene MBID**, no se toca nada, nunca. Un MBID es la
   señal más fuerte de una identidad real en el catálogo, y es lo que evita que una colaboración bien acreditada
   (Hall & Oates) se mueva a una página en solitario por tener «más oyentes».
2. Si no, los candidatos se reúnen de **exactamente tres sitios**: tal como se informó, el primer artista
   acreditado y las entradas de ese artista cuyo título normalizado da la misma clave
   (`artist.getTopTracks`, que ya viene ordenado por oyentes).
3. Entre los candidatos que Last.fm tiene realmente en su catálogo (con MBID, o con ≥ 500 oyentes, o con una duración
   en el catálogo; una entrada fantasma no tiene ninguna de las tres), gana el más escuchado, se
   verifica su duración y se envían su artista y su canción: se decide una vez y se mantiene para siempre. Si ningún
   candidato cumple los requisitos, se envía tal como se informó y se vuelve a comprobar a los 90 días.

A propósito, **no** usa `track.search`: busca la cadena literal, así que ni
encuentra la entrada tradicional ni descarta resultados con el mismo título pero de otra canción, como
`张泽熙 / 那个女孩`. La normalización de títulos solo unifica diferencias de grafía de una misma grabación: chino tradicional
frente a simplificado, variantes de caracteres, diacríticos, créditos de artistas invitados (`(feat. X)`) y etiquetas de reedición
(`(Remastered 2014)`, `(Bonus Track)`). **Las marcas de Live, Remix, acústico e instrumental se conservan
siempre**: son grabaciones distintas. El candidato ganador también tiene que superar una comprobación de duración
(se rechaza si ambos lados conocen una duración y difieren en más de 8 segundos).

Medido sobre 240 canciones reales: 33 reescritas, 162 enviadas tal cual y 45 sin decidir. Ejemplos:

| Informado | Enviado | Oyentes |
|---|---|---|
| `周杰倫 / 手写的从前` | `周杰倫 / 手寫的從前` | 100 → 4515 |
| `Wang Leehom / 奇遇的起点` | `王力宏 / 奇遇的起點` | 1 → 144 |
| `SZA & Phoebe Bridgers / Ghost in the Machine` | `SZA / Ghost in the Machine (feat. Phoebe Bridgers)` | 175 → 856 376 |
| `PRINCE / Walk Don't Walk (2023 Remaster)` | `Prince / Walk Don't Walk` | 231 → 16 178 |

Cualquier fallo en la búsqueda (red, límite de peticiones, respuesta mal formada, lista de canciones inaccesible) envía las etiquetas
tal como se informaron y no guarda nada en caché, así que un tropiezo nunca se convierte en una decisión permanente. Las decisiones se guardan en
`~/Library/Application Support/me.yudaotor.lyrimuse/lyrimuse-lastfm-catalog.json` junto con las pruebas que las motivaron; borra el
archivo para que todo se vuelva a decidir.

Las claves antiguas se siguen leyendo pero ya no se escriben, y se migran sin cambiar el comportamiento:
`lastfm_scrobble_artist_mode` pasa `smart` → Inteligente, `all` → Sin procesar y `first` → Personalizado con título
«Sin procesar» y artista «Solo el primero»; el booleano anterior `lastfm_scrobble_first_artist_only=true` es
equivalente a `first`.

## 5. Si falla un scrobble

Los fallos se clasifican, porque la respuesta correcta es distinta en cada caso. Abajo, «anotarlo» significa que la reproducción se
escribe en un registro local, que un **envío diferido** (que se inicia a mano con «Enviar pendientes», junto al recuento
«N reproducciones por enviar» bajo tus reproducciones recientes) puede enviar más tarde.

| Qué ocurrió | Qué hacemos |
|---|---|
| Consta que la petición nunca salió de tu Mac (DNS, fallo de conexión) | Anotarlo; el envío diferido puede enviarlo |
| El servidor la rechazó por un motivo que garantiza que no se guardó (credenciales incorrectas, límite de peticiones) | Anotarlo; el envío diferido puede enviarlo |
| Se envió, pero no se sabe el resultado (tiempo de espera agotado, conexión cortada, error ambiguo del servidor) | Anotarlo, pero el envío diferido **nunca** lo reintentará automáticamente |
| El servidor recibió la canción y rechazó el contenido en sí | No anotarlo; mostrar el motivo real que da el servidor |

La tercera fila existe porque un tiempo de espera agotado puede significar que Last.fm guardó la reproducción y solo se perdió la confirmación.
Reintentarlo crearía un duplicado que habría que borrar a mano, así que un fallo ambiguo
nunca se reintenta automáticamente.

El envío diferido solo llega a **13 días** atrás. Una vez que se ha intentado enviar una reproducción, la vía en tiempo real nunca
vuelve a enviarla: la reproducción se marca como intentada *antes* de que salga la petición, no después de que
tenga éxito, así que un cierre inesperado a mitad de la petición no puede producir un segundo envío.

## 6. Dónde se fusionan los nombres

Last.fm recibe lo que informó el reproductor, así que una biblioteca que informa de la misma persona como
`Khalil Fong` y como `方大同` mostrará allí dos artistas.

Dentro de Lyrimuse, los recuentos de reproducciones, las listas y los números de «Reproducción n.º N» los fusionan, mediante
la unificación de chino tradicional y simplificado, alias de nombres romanizados, la eliminación del ruido del catálogo
(`(Remastered 2014)`, `(feat. …)`, `(Explicit)`) y una tabla de alias por artista. La fusión se hace
en local y no antes del envío porque una fusión local errónea se deshace al actualizar, mientras que un
scrobble erróneo es una edición permanente de una página pública.

## 7. Preguntas frecuentes

**¿Puedo usar Lyrimuse sin hacer scrobble?**
Sí, es lo predeterminado: no se hace scrobble de nada hasta que conectas una cuenta de Last.fm en
Ajustes → Plataformas vinculadas. Obtener letras e ilustraciones es aparte: envía el artista y el nombre
de la canción a los proveedores públicos de letras (Netease, QQ, Kugou, LRCLIB, Musixmatch, AMLL) tanto si hay
una cuenta conectada como si no. Esas fuentes se pueden limitar o desactivar en Ajustes.

**¿Por qué aparece el mismo artista dos veces en mi perfil de Last.fm?**
Tu reproductor informó dos nombres distintos y ambos se enviaron tal cual. Lyrimuse los fusiona
en sus propias estadísticas; para fusionarlos en Last.fm hay que editar allí los scrobbles.

**¿Se pueden limpiar los nombres antes de enviarlos?**
No. Si quieres eso, lo viable es una tabla de reglas que edite el usuario, no una búsqueda
automática: mira cómo lo hace [Maloja](https://github.com/krateng/maloja).

**¿Y las reproducciones de mi iPhone?**
Lyrimuse nunca las envía a Last.fm; llegan allí mediante el propio scrobbling de Apple. Lyrimuse
las lee de vuelta para que aparezcan en sus estadísticas junto a las reproducciones del Mac.

**¿Se pueden fusionar artistas en Last.fm sin reescribir los nombres?**
No a través de la API. El parámetro `mbid` de Last.fm identifica una *canción*, no un artista, así que no hay
ningún campo para decir «estos dos nombres son la misma persona» manteniendo intactos ambos nombres.

**¿El registro local de escuchas duplica mis scrobbles?**
No. Solo registra una reproducción cuando no hay ninguna cuenta de Last.fm conectada o cuando un envío ha fallado. Con
Last.fm conectado y funcionando, se queda vacío.

---

*Implementación: [`lyrimuse-engine/lastfm.go`](../lyrimuse-engine/lastfm.go)
(`resolveScrobbleArtist`, `scrobble`, `updateNowPlaying`),
[`lyrimuse-engine/poller.go`](../lyrimuse-engine/poller.go)
(`listenThreshold`, `recordFailedMirror`).*
