# Como o Lyrimuse faz scrobble no Last.fm

*[English](scrobbling.md) · [简体中文](scrobbling.zh-CN.md) · [日本語](scrobbling.ja.md) · [한국어](scrobbling.ko.md) · [Español](scrobbling.es.md) · [Français](scrobbling.fr.md) · [Deutsch](scrobbling.de.md) · [Italiano](scrobbling.it.md) · **Português (Brasil)** · [Tiếng Việt](scrobbling.vi.md) · [Русский](scrobbling.ru.md) · [Українська](scrobbling.uk.md)*

## 1. Quando uma reprodução conta

Uma reprodução é enviada quando **todas** estas condições são atendidas:

| Regra | Valor |
|---|---|
| Tocou o suficiente | metade da música, até no máximo 240 s, ou 240 s se a duração for desconhecida. Há pontos mais rígidos só para o Last.fm: veja §1b |
| A música é longa o bastante | `≥ 30s` (músicas de duração desconhecida passam). Pode ser desativado: veja §1a |
| Não é anúncio | Os intervalos comerciais do Spotify são detectados e ignorados |

A reprodução é verificada a cada 5 segundos e o tempo decorrido é contado pelo relógio real, então pausar
interrompe a contagem e avançar na música não a aumenta. Se duas verificações ficarem a mais de 60 segundos uma da outra
(o Mac entrou em repouso ou o motor foi reiniciado), esse intervalo é descartado em vez de contado.

Esses limites seguem as [diretrizes de scrobbling do Last.fm](https://www.last.fm/api/scrobbling).

### 1a. Músicas com menos de 30 segundos

Ajustes → Serviços conectados → Last.fm → *Regras* → **Scrobble de músicas com menos de 30 segundos** (`scrobble_short_tracks`,
**desativado** por padrão). A regra do Last.fm *“The track must be longer than 30 seconds”* (a música precisa ter mais de 30 segundos) é uma regra do lado do cliente:
o servidor não rejeita músicas curtas nem tem um código de descarte por “curta demais”, e todos os clientes de
scrobble mais usados a respeitam, então o Lyrimuse também a respeita por padrão. Com a opção ativada, as músicas curtas contam assim
que cumprem a regra da metade (uma música de 20 segundos precisa de 10 segundos). É um ajuste **só do Last.fm**:
as músicas curtas recebem scrobble no Last.fm (e entram no registro local que alimenta o envio de pendentes ao Last.fm), mas
nunca são enviadas ao ListenBrainz, cujo comportamento não muda em nenhum dos casos.

### 1b. Momento do scrobble

Ajustes → Serviços conectados → Last.fm → *Regras* → **Momento do scrobble** (`lastfm_scrobble_point`, padrão
**50%**). Até que ponto uma música precisa tocar para fazer scrobble no Last.fm:

| Ajuste | Valor | Faz scrobble quando |
|---|---|---|
| **50%** (padrão) | `50` | vale a regra do Last.fm acima: metade da música, até no máximo 4 minutos |
| 75% / 90% | `75` / `90` | 75% / 90% da duração da música já tocou — só conta o tempo tocado, sem o limite de 4 minutos |
| No fim | `end` | a música toca até o fim; pular para a frente não conta |

A regra do Last.fm é um mínimo, então não há ajuste abaixo de 50%. É **só do Last.fm**: o ListenBrainz e
o relay web continuam enviando no ponto de 50%; só o scrobble do Last.fm (e o registro local que alimenta o
envio de pendentes ao Last.fm) espera o ponto escolhido. Uma música pulada antes desse ponto não envia nada ao
Last.fm: é o ajuste cumprindo o seu papel, não um scrobble perdido. Músicas de duração desconhecida seguem a
regra padrão.

*No fim* é avaliado pela última posição de reprodução observada quando a música muda: parar a até 12
segundos do fim (10% da duração em músicas curtas) já conta como ter tocado até o fim, então a fusão de um player
ou uma transição sem intervalos não impede o scrobble.

## 2. O que é enviado

`track.scrobble` grava a entrada permanente no seu histórico; `track.updateNowPlaying` ativa o indicador
“ouvindo agora” e não guarda nada.

| Campo | `track.scrobble` | `track.updateNowPlaying` |
|---|---|---|
| `artist` | ✅ | ✅ |
| `track` | ✅ | ✅ |
| `timestamp` | ✅ | — |
| `album` | quando não está vazio | quando não está vazio |
| `duration` | quando conhecida | quando conhecida |

Nada mais chega ao Last.fm. A API do Last.fm também aceita `mbid`, `albumArtist`, `trackNumber`,
`chosenByUser`, `streamId` e `context` em um scrobble; o Lyrimuse não envia nenhum deles.

## 3. O que não é reescrito

No caminho do ListenBrainz, e nos modos *Tudo* e *Só o primeiro* do Last.fm, os nomes de artista, música e álbum
são enviados exatamente como o player os informou. (O modo *Inteligente* do Last.fm reescreve o
artista e a música para corresponderem à entrada do catálogo: veja a próxima seção.)

O único processamento aplicado é a limpeza de caracteres invisíveis: espaços não separáveis e de largura total
viram espaços comuns, caracteres de largura zero e BOMs são removidos, sequências de espaços em branco viram
um só, e os espaços no início e no fim são cortados. Sem isso, um espaço não separável invisível
cria uma entidade de artista separada no Last.fm.

Nada visível é alterado — nem maiúsculas e minúsculas, nem chinês tradicional vs. simplificado, nem
subtítulos entre parênteses, nem créditos com vários artistas. `PRINCE` continua `PRINCE`, `無所謂` continua
`無所謂`, e `一口 (The Day You Left Me)` mantém o subtítulo.

Por que, por padrão, não há busca externa para “normalizar” os nomes:

- O Lyrimuse fazia exatamente isso. Uma auditoria de uma biblioteca real de ~2.500 músicas encontrou cerca de 200
  nomes de artista reescritos, entre eles `USA for Africa` → `Xtc Planet` e `LBI利比` → `Safehse`.
  Scrobbles já gravados em uma página pública de artista do Last.fm não podem ser corrigidos depois: o
  banco de dados de correções está congelado.
- O guia de scrobbling do Last.fm diz, duas vezes: *“Do not use the corrections returned by the now
  playing service as input for the scrobble request, unless they have been explicitly approved by
  the user.”* (não use as correções retornadas pelo serviço de “ouvindo agora” como entrada da solicitação de scrobble, a menos que o usuário as tenha aprovado explicitamente). O parâmetro `autocorrect` está
  [documentado como legado](https://support.last.fm/t/scrobbles-of-japanese-artists-getting-separated-by-romanization-of-their-name/119906).
- Dos nove clientes de scrobble de código aberto analisados (Web Scrobbler, Pano Scrobbler, Navidrome, Maloja,
  rescrobbled, mpdscribble, mpdas, Koito, multi-scrobbler), nenhum reescreve por padrão nomes de artista a partir de uma
  busca externa.

## 4. Modo de correspondência

Ajustes → Serviços conectados → Last.fm → *Regras* → **Modo de correspondência**
(`lastfm_match_mode` em `~/Library/Application Support/me.yudaotor.lyrimuse/lyrimuse-features.json`):

| Modo | Valor | Efeito |
|---|---|---|
| **Inteligente** (padrão em instalações novas) | `smart` | Procura a entrada desta música no catálogo do Last.fm e envia o artista e o título dessa entrada (veja abaixo) |
| Personalizado | `custom` | Escolha quais partes podem mudar: veja abaixo |
| **Bruto** (padrão em instalações existentes) | `raw` | Exatamente o que o player informa, sem acesso à rede |

*Personalizado* acrescenta duas linhas, uma para cada campo:

| Linha | Opção | Efeito |
|---|---|---|
| **Título** | Correspondência | O título pode ser trocado pela grafia da entrada do catálogo, e ` - Single` / ` - EP` é removido do álbum (`lastfm_match_track`) |
| | Bruto | O título é enviado como informado |
| **Artista** | Correspondência | O artista pode ser trocado pela grafia da entrada do catálogo (`lastfm_match_artist`) |
| | Só o primeiro | Reduz um crédito conjunto ao primeiro artista (`Khalil Fong & Fiona Sit` → `Khalil Fong`): só tratamento de texto, sem acesso à rede (`lastfm_match_first_artist_only`) |
| | Bruto | O artista é enviado como informado |

Com *Correspondência* escolhida em só uma das duas linhas, **um candidato só é aceito se o outro campo já
corresponder**; caso contrário, o resultado seria uma combinação que não existe no catálogo e acabaria
de novo em uma entrada fantasma com um único ouvinte: você.

*Só o primeiro* é diferente de *Correspondência*: só se aplica **quando não houve correspondência**. Uma
grafia correspondente já é a entrada que o Last.fm reconhece, e cortá-la a transformaria em uma
entrada que não existe: `Hall & Oates / Maneater` (800 mil ouvintes) viraria `Hall`. Então Título
*Bruto* com Artista *Só o primeiro* é, byte a byte, o antigo modo *Só o primeiro*, ainda sem acesso à rede.

*Bruto* continua sendo o padrão onde já existe um `lyrimuse-features.json`, porque cortar um
crédito é irreversível: tira Fiona Sit do seu histórico. A opção de mesmo nome do Navidrome
(`Lastfm.ScrobbleFirstArtistOnly`) também vem desativada por padrão.

A separação é conservadora: `/` é tratado à parte de `,` e `&`, então `K/DA` e `AC/DC` não
são divididos em `K` e `AC`.

### Modo inteligente

O que o player informa e o nome que o catálogo do Last.fm dá à mesma gravação muitas vezes não têm os
mesmos caracteres, e enviar como está faz a reprodução cair em uma entrada “fantasma” — sem MBID, sem álbum,
duração zero, um único ouvinte: você. Medido com 《那个女孩》, de David Tao: o player informa
`陶喆, 卢广仲 / 那个女孩`, que o Last.fm simplesmente não tem; a forma simplificada `陶喆 / 那个女孩` tem
126 ouvintes; e a entrada real da música é a tradicional **`陶喆 / 那個女孩` — 889 ouvintes,
4.580 reproduções, com duração no catálogo**. O próprio `autocorrect` do Last.fm não ajuda: ele não converte
entre chinês tradicional e simplificado.

Por isso, o modo *Inteligente* consulta a música antes de enviar:

1. `track.getInfo` como informado. **Se houver MBID**, nada é alterado, nunca. Um MBID é o
   sinal mais forte de uma identidade real no catálogo, e é o que impede que uma colaboração com crédito
   correto (Hall & Oates) seja levada para uma página solo por ter “mais ouvintes”.
2. Caso contrário, os candidatos vêm de **exatamente três lugares**: como informado, o primeiro artista
   creditado e as entradas desse artista cujo título normalizado dá a mesma chave
   (`artist.getTopTracks`, que já vem ordenado por ouvintes).
3. Entre os candidatos que o Last.fm de fato tem no catálogo (um MBID, ou ≥ 500 ouvintes, ou uma duração
   de catálogo — uma entrada fantasma não tem nenhum dos três), vence o mais ouvido, sua duração é
   verificada, e o artista e a música dele são o que se envia — decidido uma vez, mantido para sempre. Se nenhum
   candidato se qualificar, a música é enviada como informada e verificada de novo após 90 dias.

Ele de propósito **não** usa `track.search`: essa busca procura a string literal, que não encontra a
entrada tradicional nem exclui resultados de mesmo título e outra música, como
`张泽熙 / 那个女孩`. A normalização de títulos só unifica diferenças de grafia de uma mesma gravação — tradicional
vs. simplificado, variantes de caracteres, diacríticos, créditos de participação (`(feat. X)`) e marcas de relançamento
(`(Remastered 2014)`, `(Bonus Track)`). **Marcas de Live, Remix, acústico e instrumental são sempre
mantidas**: são gravações diferentes. O candidato vencedor também precisa passar por uma verificação de duração
(é rejeitado se os dois lados conhecem a duração e elas diferem em mais de 8 segundos).

Medido em 240 músicas reais: 33 reescritas, 162 enviadas como estavam, 45 sem decisão possível. Exemplos:

| Informado | Enviado | Ouvintes |
|---|---|---|
| `周杰倫 / 手写的从前` | `周杰倫 / 手寫的從前` | 100 → 4.515 |
| `Wang Leehom / 奇遇的起点` | `王力宏 / 奇遇的起點` | 1 → 144 |
| `SZA & Phoebe Bridgers / Ghost in the Machine` | `SZA / Ghost in the Machine (feat. Phoebe Bridgers)` | 175 → 856.376 |
| `PRINCE / Walk Don't Walk (2023 Remaster)` | `Prince / Walk Don't Walk` | 231 → 16.178 |

Qualquer falha na consulta (rede, limite de requisições, resposta malformada, lista de músicas inacessível) envia as tags como
informadas e não guarda nada em cache, então uma falha momentânea nunca vira uma decisão permanente. As decisões ficam em
`~/Library/Application Support/me.yudaotor.lyrimuse/lyrimuse-lastfm-catalog.json` junto com as evidências que as geraram; apague o
arquivo para decidir tudo de novo.

As chaves antigas ainda são lidas, mas não são mais gravadas, e migram sem mudar o comportamento:
`lastfm_scrobble_artist_mode` converte `smart` → Inteligente, `all` → Bruto e `first` → Personalizado com Título
em Bruto e Artista em Só o primeiro; o booleano mais antigo `lastfm_scrobble_first_artist_only=true`
equivale a `first`.

## 5. Se um scrobble falhar

As falhas são classificadas, porque a resposta certa muda de caso para caso. “Registrar” abaixo significa que a reprodução é
gravada em um registro local, que um **envio de pendentes** — iniciado manualmente com **Enviar pendentes**, ao lado da contagem “Reproduções a enviar”
nas suas reproduções recentes — pode enviar depois.

| O que aconteceu | O que fazemos |
|---|---|
| A solicitação comprovadamente nunca saiu do seu Mac (DNS, falha de conexão) | Registrar; o envio de pendentes pode enviá-la |
| O servidor recusou por um motivo que garante que ela não foi armazenada (credenciais inválidas, limite de requisições) | Registrar; o envio de pendentes pode enviá-la |
| Enviada, mas com resultado desconhecido (tempo esgotado, conexão interrompida, erro ambíguo do servidor) | Registrar, mas o envio de pendentes **nunca** tenta de novo automaticamente |
| O servidor recebeu a música e rejeitou o próprio conteúdo | Não registrar; mostrar o motivo real dado pelo servidor |

A terceira linha existe porque um tempo esgotado pode significar que o Last.fm guardou a reprodução e só a confirmação
se perdeu. Tentar de novo criaria uma duplicata que precisa ser apagada à mão, então uma falha ambígua
nunca é repetida automaticamente.

O envio de pendentes só volta **13 dias** no tempo. Depois que houve uma tentativa de enviar uma reprodução, o caminho em tempo real nunca
a envia de novo: a reprodução é marcada como tentada *antes* de a solicitação sair, não depois de ela dar
certo, então um travamento no meio da solicitação não pode gerar um segundo envio.

## 6. Onde a mesclagem acontece

O Last.fm recebe o que o player informou, então uma biblioteca que informa a mesma pessoa tanto como
`Khalil Fong` quanto como `方大同` vai mostrar dois artistas lá.

Dentro do Lyrimuse, as contagens de reprodução, as Paradas e os números de “Reprodução nº N” os mesclam — por meio da
normalização entre tradicional e simplificado, aliases de nomes romanizados, remoção do ruído de catálogo
(`(Remastered 2014)`, `(feat. …)`, `(Explicit)`) e uma tabela de aliases por artista. A mesclagem é feita
localmente, e não antes do envio, porque uma mesclagem errada no local se desfaz com uma atualização, enquanto um
scrobble errado é uma edição permanente em uma página pública.

## 7. Perguntas frequentes

**Posso usar o Lyrimuse sem fazer scrobble?**
Sim, é o padrão — nenhum scrobble é feito até você conectar uma conta do Last.fm em
Ajustes → Serviços conectados. Buscar letras e capas é outra coisa: envia o nome do artista e da música
aos provedores públicos de letras (Netease, QQ, Kugou, LRCLIB, Musixmatch, AMLL), com ou sem
conta conectada. Essas fontes de letras podem ser limitadas ou desativadas nos Ajustes.

**Por que o mesmo artista aparece duas vezes no meu perfil do Last.fm?**
O seu player informou dois nomes diferentes, e os dois foram enviados como informados. O Lyrimuse os mescla
nas próprias estatísticas; para mesclá-los no Last.fm, é preciso editar os scrobbles lá.

**Os nomes podem ser limpos antes do envio?**
Não. Se você quiser isso, a forma viável é uma tabela de regras editável pelo usuário, não uma consulta
automática — veja como o [Maloja](https://github.com/krateng/maloja) faz.

**E as reproduções do meu iPhone?**
O Lyrimuse nunca as envia ao Last.fm; elas chegam lá pelo scrobble da própria Apple. O Lyrimuse
as lê de volta para que apareçam nas estatísticas junto com as reproduções do Mac.

**Dá para mesclar artistas no Last.fm sem reescrever os nomes?**
Não pela API. O parâmetro `mbid` do Last.fm identifica uma *música*, não um artista, então não há
campo para dizer “estes dois nomes são a mesma pessoa” mantendo os dois nomes intactos.

**O registro local de reproduções duplica meus scrobbles?**
Não. Ele só registra uma reprodução quando não há conta do Last.fm conectada ou quando um envio falhou. Com o
Last.fm conectado e funcionando, ele fica vazio.

---

*Implementação: [`lyrimuse-engine/lastfm.go`](../lyrimuse-engine/lastfm.go)
(`resolveScrobbleArtist`, `scrobble`, `updateNowPlaying`),
[`lyrimuse-engine/poller.go`](../lyrimuse-engine/poller.go)
(`listenThreshold`, `recordFailedMirror`).*
