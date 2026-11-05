# Esquema de URL de Lyrimuse

*[English](url-scheme.md) · [简体中文](url-scheme.zh-CN.md) · [日本語](url-scheme.ja.md) · [한국어](url-scheme.ko.md) · **Español** · [Français](url-scheme.fr.md) · [Deutsch](url-scheme.de.md) · [Italiano](url-scheme.it.md) · [Português (Brasil)](url-scheme.pt-BR.md) · [Tiếng Việt](url-scheme.vi.md) · [Русский](url-scheme.ru.md) · [Українська](url-scheme.uk.md) · [ไทย](url-scheme.th.md)*

Los enlaces que empiezan por `lyrimuse://` te permiten controlar Lyrimuse desde Atajos, Raycast, Alfred, Stream Deck, el Terminal (`open 'lyrimuse://…'`) y herramientas similares: abrir ventanas y páginas de ajustes, mostrar u ocultar la letra, controlar la reproducción, ajustar la sincronización u obtener lo que se está reproduciendo.

Los más habituales se pueden copiar desde **Enlaces profundos**, al final de Ajustes › Atajos de teclado. Coloca el puntero sobre cualquier atajo de esa lista para copiar el enlace de esa acción.

## Reglas generales

- Los enlaces no distinguen entre mayúsculas y minúsculas.
- Un enlace que Lyrimuse no reconoce no hace nada y muestra «Enlace no reconocido».
- Cualquier enlace que abre una ventana acepta `background=1`: la ventana aparece, pero Lyrimuse no pasa a primer plano ni toma el foco del teclado. Por ejemplo, `lyrimuse://lyrics-window?background=1`.
- Las acciones que activan y desactivan algo aceptan `on=1` u `on=0` para fijar un estado concreto (también sirven `true` / `false` y `on` / `off`), así que ejecutar una dos veces da el mismo resultado. Sin él, alternan el estado.
- Las páginas web también pueden abrir enlaces `lyrimuse://` (el navegador te pregunta antes), así que solo se exponen acciones fáciles de deshacer: activar o desactivar opciones, abrir ventanas, controlar la reproducción y ajustar la sincronización. Nada borra ni edita letras ni toca tus cuentas.

## Abrir ventanas

| Enlace | Qué hace |
|---|---|
| `lyrimuse://lyrics-window` | Abre la ventana de letra |
| `lyrimuse://lyrics-window/search` | Abre la ventana de letra y la ventana «Buscar letra» (la misma que `lyrics-search`) |
| `lyrimuse://lyrics-manager` | Abre el gestor de letras |
| `lyrimuse://lyrics-search` | Abre la ventana «Buscar letra» para la canción actual |
| `lyrimuse://menubar-panel` | Abre o cierra el panel de la barra de menús |
| `lyrimuse://menubar-panel?quick=overlay` | Abre el panel de la barra de menús en los ajustes rápidos de un mosaico (solo abre, nunca cierra). `quick` es uno de `overlay`, `notch`, `menubar`, `touchbar`, `lyrics-window`, `lyrics-manager` |
| `lyrimuse://menubar-menu` | Despliega el menú del icono de la barra de menús |
| `lyrimuse://onboarding` | Abre la guía de bienvenida |
| `lyrimuse://whats-new` | Muestra las novedades de la versión instalada |

## Abrir ajustes

`lyrimuse://settings` abre Ajustes. Añade una ruta para ir directamente a una página, y un segmento más para ir a una sección de esa página.

| Ruta | Página | Secciones |
|---|---|---|
| `/lyrics` | Letra | `/fetch` o `/sources` Fuente, `/translation` o `/language` Idioma, `/display` o `/timing` Sincronización, `/manage` o `/library` Biblioteca de letras |
| `/player` | Reproductor | `/players` Reproductor, `/linkage` Abrir y salir, `/permissions` Permisos y servicios |
| `/appearance` | Mostrar letra | `/overlay` Letra flotante, `/notch` Notch, `/menu-bar` Barra de menús, `/touch-bar` Touch Bar, `/lyrics-window` Ventana de letra |
| `/shortcuts` | Atajos de teclado | — |
| `/general` | General | — |
| `/about` | Acerca de | — |
| `/account/lastfm` | Last.fm | `/stats` Estadísticas, `/chart` Listas, `/on-this-day` Huella, `/settings` Reglas |
| `/account/listenbrainz` | ListenBrainz | — |
| `/account/discord` | Discord | `/display` Qué se muestra, `/buttons` Botones, `/privacy` Privacidad |
| `/account/relay` | Push web | — |
| `/account/bark` | Avisos push | — |
| `/software-update` | Actualización de software | Añade `?check=1` para buscar también actualizaciones |
| `/lastfm-suggestions` | Sugerencias de la cuenta de Last.fm | — |
| `/labs` | Laboratorio | — |

Por ejemplo, `lyrimuse://settings/appearance/overlay` o `lyrimuse://settings/software-update?check=1`. Una ruta desconocida solo abre Ajustes; una sección desconocida abre la página en la última sección que viste.

## Acciones: `lyrimuse://action/<name>`

Son las mismas acciones que los atajos de teclado de Ajustes › Atajos de teclado. Ejecutan el mismo código y muestran la misma respuesta.

### Visualización

| Nombre | Qué hace | Parámetros |
|---|---|---|
| `toggle-overlay` | Muestra u oculta la letra flotante | `on` |
| `toggle-notch` | Muestra u oculta la letra en el notch | `on` |
| `peek-notch` | Expande la letra del notch durante unos segundos; ejecútala otra vez para cerrarla antes | — |
| `toggle-menubar-lyrics` | Muestra u oculta la letra en la barra de menús | `on` |
| `toggle-touchbar` | Expande o contrae la letra en la Touch Bar (solo en Mac con Touch Bar) | — |
| `toggle-all-lyrics` | Oculta toda la letra: se ocultan las que estén activadas entre la letra flotante, la del notch y la de la barra de menús, y al ejecutarla otra vez vuelven exactamente esas | `on` (`0` oculta, `1` restaura) |
| `toggle-lock-position` | Bloquea o desbloquea la posición de la letra flotante | `on` |
| `toggle-translation` | Muestra u oculta las traducciones | `on` |
| `toggle-romanization` | Muestra u oculta la romanización | `on` |
| `overlay-font-larger` | Agranda la letra flotante | — |
| `overlay-font-smaller` | Reduce la letra flotante | — |

### Ventanas

| Nombre | Qué hace | Parámetros |
|---|---|---|
| `open-lyrics-manager` | Abre el gestor de letras | — |
| `open-lyrics-window` | Abre la ventana de letra | — |
| `toggle-lyrics-window-mini` | Cambia la ventana de letra entre el tamaño mini y el completo; si está cerrada, la abre en tamaño mini | `on` (`1` mini, `0` completo) |
| `search-lyrics` | Abre la ventana «Buscar letra» | — |
| `open-settings` | Abre Ajustes | — |
| `open-player` | Pasa a primer plano el reproductor que estás usando | — |
| `toggle-menubar-panel` | Abre o cierra el panel de la barra de menús, igual que hacer clic en su icono | — |

### Sincronización de la letra

| Nombre | Qué hace | Parámetros |
|---|---|---|
| `lyrics-advance` | Adelanta un paso la letra de esta canción | `step`: segundos de este ajuste (de 0 a 5); si se omite, el paso definido en Ajustes |
| `lyrics-delay` | Retrasa un paso la letra de esta canción | `step`, como arriba |
| `lyrics-offset-reset` | Pone a cero el desfase de la letra de esta canción | — |

### Reproducción

| Nombre | Qué hace | Parámetros |
|---|---|---|
| `play-pause` | Reproducir / pausar | — |
| `next-track` | Canción siguiente | — |
| `previous-track` | Canción anterior | — |
| `toggle-favorite` | Marca o desmarca la canción actual como favorita (si el reproductor lo admite) | `on` (`1` marca como favorita, `0` la quita) |

Por ejemplo, `lyrimuse://action/toggle-overlay?on=0` o `lyrimuse://action/lyrics-advance?step=0.5`.

### Otras acciones

| Enlace | Qué hace |
|---|---|
| `lyrimuse://action/copy-lyric` | Copia la línea de letra actual al portapapeles; añade `?translation=1` para incluir la traducción |
| `lyrimuse://action/surfaces?overlay=1&notch=0&menubar=1` | Define de una vez qué letras se muestran: `overlay` (letra flotante), `notch` y `menubar`, cada una con `1` para mostrar o `0` para ocultar. Incluye solo las que quieras cambiar |
| `lyrimuse://action/lyrics-offset?ms=-300` | Fija el desfase de la letra de esta canción en un valor exacto en milisegundos: positivo adelanta, negativo retrasa, dentro de ±10000 |
| `lyrimuse://action/play-mode?mode=shuffle` | Define el modo de reproducción: `mode` es `list`, `shuffle`, `repeat-all` o `repeat-one`. Los modos que el reproductor no admite pasan a `list` |

## Obtener lo que se está reproduciendo (x-callback-url)

```
lyrimuse://x-callback-url/now-playing?x-success=<callback URL>
```

Lyrimuse abre la URL de `x-success` añadiendo como parámetros lo que se está reproduciendo (los parámetros que ya tenga `x-success` se conservan):

| Parámetro | Valor |
|---|---|
| `title` | Título de la canción |
| `artist` | Artista |
| `album` | Álbum |
| `lyric` | La línea de letra actual |
| `player` | Nombre del reproductor |
| `playing` | `1` mientras se reproduce algo, `0` en pausa o cuando no hay nada cargado (si no hay nada cargado, los campos anteriores están vacíos) |

En Atajos, usa la acción **Abrir URL de X-Callback** con `lyrimuse://x-callback-url/now-playing` como URL. Atajos añade `x-success` por sí mismo, y los parámetros devueltos pasan a ser la salida de la acción.

Para que las páginas web no puedan usar este enlace para ver lo que escuchas, la URL de retorno tiene dos límites: no puede ser una URL web, de archivo ni de script (`http`, `https`, `file`, `ftp`, `javascript`, `data`, `about`, `blob`, ni el propio `lyrimuse`), y en tu Mac tiene que abrirla una app que no sea un navegador. Si no, no se devuelve nada.
