# Esquema de URL do Lyrimuse

*[English](url-scheme.md) · [简体中文](url-scheme.zh-CN.md) · [日本語](url-scheme.ja.md) · [한국어](url-scheme.ko.md) · [Español](url-scheme.es.md) · [Français](url-scheme.fr.md) · [Deutsch](url-scheme.de.md) · [Italiano](url-scheme.it.md) · **Português (Brasil)** · [Tiếng Việt](url-scheme.vi.md)*

Links que começam com `lyrimuse://` permitem controlar o Lyrimuse pelo app Atalhos, pelo Raycast, pelo Alfred, pelo Stream Deck, pelo Terminal (`open 'lyrimuse://…'`) e por ferramentas parecidas: abrir janelas e páginas dos Ajustes, mostrar ou ocultar a letra, controlar a reprodução, ajustar a sincronia ou saber o que está tocando.

Os mais comuns podem ser copiados em **Deep links**, no fim de Ajustes › Atalhos de teclado. Passe o cursor sobre qualquer atalho ali para copiar o link dessa ação.

## Regras gerais

- Os links não diferenciam maiúsculas de minúsculas.
- Um link que o Lyrimuse não reconhece não faz nada e mostra “Link não reconhecido”.
- Qualquer link que abre uma janela aceita `background=1`: a janela aparece, mas o Lyrimuse não vem para a frente nem assume o foco do teclado. Por exemplo, `lyrimuse://lyrics-window?background=1`.
- As ações de ativar e desativar aceitam `on=1` ou `on=0` para definir um estado (`true` / `false` e `on` / `off` também funcionam), então executar uma delas duas vezes dá o mesmo resultado. Sem esse parâmetro, elas alternam o estado.
- Páginas da web também podem abrir links `lyrimuse://` (o navegador pergunta antes), por isso só ficam disponíveis ações fáceis de desfazer: ativar e desativar opções, abrir janelas, controlar a reprodução e ajustar a sincronia. Nada apaga nem edita letras, nem mexe nas suas contas.

## Abrir janelas

| Link | O que faz |
|---|---|
| `lyrimuse://lyrics-window` | Abre a Janela da letra |
| `lyrimuse://lyrics-window/search` | Abre a Janela da letra e a janela “Buscar letra” (a mesma de `lyrics-search`) |
| `lyrimuse://lyrics-manager` | Abre o Gerenciador de letras |
| `lyrimuse://lyrics-search` | Abre a janela “Buscar letra” para a música atual |
| `lyrimuse://menubar-panel` | Abre ou fecha o painel da barra de menus |
| `lyrimuse://menubar-panel?quick=overlay` | Abre o painel da barra de menus nos ajustes rápidos de um bloco (só abre, nunca fecha). `quick` é um destes: `overlay`, `notch`, `menubar`, `touchbar`, `lyrics-window`, `lyrics-manager` |
| `lyrimuse://menubar-menu` | Abre o menu do ícone na barra de menus |
| `lyrimuse://onboarding` | Abre o guia de boas-vindas |
| `lyrimuse://whats-new` | Mostra as novidades da versão instalada |

## Abrir os Ajustes

`lyrimuse://settings` abre os Ajustes. Adicione um caminho para ir direto a uma página e mais um segmento para ir a uma seção dessa página.

| Caminho | Página | Seções |
|---|---|---|
| `/lyrics` | Letra | `/fetch` ou `/sources` Origem, `/translation` ou `/language` Idioma, `/display` ou `/timing` Sincronia, `/manage` ou `/library` Biblioteca de letras |
| `/player` | Player | `/players` Player, `/linkage` Abrir e encerrar, `/permissions` Permissões e serviços |
| `/appearance` | Exibição da letra | `/overlay` Letra flutuante, `/notch` Notch, `/menu-bar` Barra de menus, `/touch-bar` Touch Bar, `/lyrics-window` Janela da letra |
| `/shortcuts` | Atalhos de teclado | — |
| `/general` | Geral | — |
| `/about` | Sobre | — |
| `/account/lastfm` | Last.fm | `/stats` Estatísticas, `/chart` Paradas, `/on-this-day` Pegada, `/settings` Regras |
| `/account/listenbrainz` | ListenBrainz | — |
| `/account/discord` | Discord | `/display` O que é mostrado, `/buttons` Botões, `/privacy` Privacidade |
| `/account/relay` | Push web | — |
| `/account/bark` | Alertas push | — |
| `/software-update` | Atualização de software | Adicione `?check=1` para também buscar atualizações |
| `/lastfm-suggestions` | Sugestões da conta Last.fm | — |
| `/labs` | Labs | — |

Por exemplo, `lyrimuse://settings/appearance/overlay` ou `lyrimuse://settings/software-update?check=1`. Um caminho desconhecido só abre os Ajustes; uma seção desconhecida abre a página na última seção que você viu.

## Ações: `lyrimuse://action/<name>`

São as mesmas ações dos atalhos de teclado em Ajustes › Atalhos de teclado. Elas executam o mesmo código e mostram o mesmo retorno.

### Exibição

| Nome | O que faz | Parâmetros |
|---|---|---|
| `toggle-overlay` | Mostra ou oculta a letra flutuante | `on` |
| `toggle-notch` | Mostra ou oculta a letra no notch | `on` |
| `peek-notch` | Expande a letra no notch por alguns segundos; execute de novo para fechar antes | — |
| `toggle-menubar-lyrics` | Mostra ou oculta a letra na barra de menus | `on` |
| `toggle-touchbar` | Expande ou recolhe a letra na Touch Bar (só em Macs com Touch Bar) | — |
| `toggle-all-lyrics` | Oculta toda a letra: o que estiver ativado entre a letra flutuante, a letra no notch e a letra na barra de menus é ocultado, e executar de novo traz de volta exatamente esses | `on` (`0` oculta, `1` restaura) |
| `toggle-lock-position` | Bloqueia ou desbloqueia a posição da letra flutuante | `on` |
| `toggle-translation` | Mostra ou oculta a tradução | `on` |
| `toggle-romanization` | Mostra ou oculta a pronúncia | `on` |
| `overlay-font-larger` | Aumenta a letra flutuante | — |
| `overlay-font-smaller` | Diminui a letra flutuante | — |

### Janelas

| Nome | O que faz | Parâmetros |
|---|---|---|
| `open-lyrics-manager` | Abre o Gerenciador de letras | — |
| `open-lyrics-window` | Abre a Janela da letra | — |
| `toggle-lyrics-window-mini` | Alterna a Janela da letra entre o tamanho mini e o completo; se estiver fechada, abre no tamanho mini | `on` (`1` mini, `0` completo) |
| `search-lyrics` | Abre a janela “Buscar letra” | — |
| `open-settings` | Abre os Ajustes | — |
| `open-player` | Traz para a frente o player que você está usando | — |
| `toggle-menubar-panel` | Abre ou fecha o painel da barra de menus, como clicar no ícone | — |

### Sincronia da letra

| Nome | O que faz | Parâmetros |
|---|---|---|
| `lyrics-advance` | Adianta a letra desta música em um passo | `step`: segundos deste ajuste (de 0 a 5); se omitido, usa o passo definido nos Ajustes |
| `lyrics-delay` | Atrasa a letra desta música em um passo | `step`, como acima |
| `lyrics-offset-reset` | Zera o deslocamento da letra desta música | — |

### Reprodução

| Nome | O que faz | Parâmetros |
|---|---|---|
| `play-pause` | Reproduzir/Pausar | — |
| `next-track` | Faixa seguinte | — |
| `previous-track` | Faixa anterior | — |
| `toggle-favorite` | Favorita ou desfavorita a música atual (se o player permitir) | `on` (`1` favoritar, `0` remover) |

Por exemplo, `lyrimuse://action/toggle-overlay?on=0` ou `lyrimuse://action/lyrics-advance?step=0.5`.

### Outras ações

| Link | O que faz |
|---|---|
| `lyrimuse://action/copy-lyric` | Copia a linha atual da letra para a área de transferência; adicione `?translation=1` para incluir a tradução |
| `lyrimuse://action/surfaces?overlay=1&notch=0&menubar=1` | Define de uma vez quais letras são exibidas: `overlay` (letra flutuante), `notch`, `menubar`, cada um com `1` para mostrar ou `0` para ocultar. Inclua só os que quiser mudar |
| `lyrimuse://action/lyrics-offset?ms=-300` | Define o deslocamento da letra desta música com um valor exato em milissegundos: positivo adianta, negativo atrasa, dentro de ±10000 |
| `lyrimuse://action/play-mode?mode=shuffle` | Define o modo de reprodução: `mode` é `list`, `shuffle`, `repeat-all` ou `repeat-one`. Modos que o player não oferece voltam para `list` |

## Saber o que está tocando (x-callback-url)

```
lyrimuse://x-callback-url/now-playing?x-success=<callback URL>
```

O Lyrimuse abre a URL de `x-success` com o que está tocando adicionado como parâmetros (os parâmetros que já estiverem em `x-success` são mantidos):

| Parâmetro | Valor |
|---|---|
| `title` | Título da música |
| `artist` | Artista |
| `album` | Álbum |
| `lyric` | A linha atual da letra |
| `player` | Nome do player |
| `playing` | `1` enquanto algo está tocando, `0` quando está pausado ou não há nada carregado (sem nada carregado, os campos acima ficam vazios) |

No app Atalhos, use a ação **Abrir URL X-Callback** com `lyrimuse://x-callback-url/now-playing` como URL. O Atalhos adiciona o `x-success` sozinho, e os parâmetros retornados viram a saída da ação.

Para que páginas da web não possam usar este link para ver o que você está ouvindo, a URL de retorno tem dois limites: não pode ser uma URL da web, de arquivo ou de script (`http`, `https`, `file`, `ftp`, `javascript`, `data`, `about`, `blob` nem o próprio `lyrimuse`), e no seu Mac ela precisa ser aberta por um app que não seja um navegador. Caso contrário, nada é enviado de volta.
