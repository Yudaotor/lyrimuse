<!-- Gerado por scripts/gen-feature-list.py a partir de shared/feature-list.json e shared/settings-catalog.json; para mudar a lista, edite esses arquivos. -->

# Lista de recursos do Lyrimuse

[English](feature-list.md) · [简体中文](feature-list.zh-CN.md) · [繁體中文](feature-list.zh-Hant.md) · [日本語](feature-list.ja.md) · [한국어](feature-list.ko.md) · [Español](feature-list.es.md) · [Français](feature-list.fr.md) · [Deutsch](feature-list.de.md) · [Italiano](feature-list.it.md) · Português (Brasil) · [Tiếng Việt](feature-list.vi.md) · [Русский](feature-list.ru.md)

O Lyrimuse é um app para Mac de código aberto (GPL-3.0) de letras sincronizadas palavra por palavra, para macOS 14 ou posterior em Apple Silicon e Intel. Ele mostra a letra do Apple Music, Spotify, QQ Music, NetEase Cloud Music, Kugou, Soda Music, KKBOX, Amazon Music, LX Music, Kaset, Pear Desktop, reAMP, VOX, Pine Player, foobar2000 e do YouTube Music ou Spotify Web tocando em um navegador: flutuando sobre a mesa, ao lado do notch, na barra de menus, na Touch Bar ou em uma janela da letra completa, com tradução e pronúncia (pinyin, jyutping do cantonês, romaji do japonês, romanização do coreano). Faz scrobble no Last.fm e no ListenBrainz e pode mostrar no Discord o que você está ouvindo. A interface está disponível em inglês, chinês simplificado, chinês tradicional, japonês, coreano, espanhol, francês, alemão, italiano, português do Brasil, vietnamita e russo.

Esta lista reúne todos os recursos do Lyrimuse: o que cada um faz, onde fica nos ajustes e se vem ativado ou não depois da instalação; no final estão todos os ajustes da janela Ajustes. Ela é mantida junto com o código e atualizada a cada mudança.

## Índice

- [Desativados até você ativar](#section-off-by-default)
- [Busca de letras](#section-lyrics)
- [Tradução, pronúncia e tratamento das linhas](#section-text)
- [Onde a letra aparece e como ela fica](#section-display)
- [Players e reprodução](#section-players)
- [Scrobble, Last.fm e compartilhamento](#section-listening)
- [No dia a dia](#section-general)
- [Todos os ajustes](#section-all-settings)

<a id="section-off-by-default"></a>

## Desativados até você ativar

Estes recursos vêm desativados depois da instalação. Ative-os antes nos ajustes (alguns também pedem uma conta ou uma autorização):

| Recurso | Onde ativar |
|---|---|
| [As letras do próprio Apple Music](#feature-apple-music-lyrics) | Ajustes › Letra › Origem › Fontes de letras |
| [Usar a letra que o seu player já salvou](#feature-player-local-lyrics) | Ajustes › Player › Permissões e serviços › Acesso Total ao Disco |
| [Preferir a letra do arquivo da música](#feature-prefer-local-file-lyrics) | Ajustes › Letra › Origem › Preferir a letra do arquivo da música |
| [Bloquear letra escolhida à mão](#feature-lock-hand-picked) | Ajustes › Letra › Origem › Bloquear letra escolhida à mão |
| [Traduzir quando não houver tradução](#feature-machine-translation) | Ajustes › Letra › Idioma › Traduzir quando não houver tradução |
| [Dividir linhas longas, juntar as curtas](#feature-split-join-lines) | Ajustes › Letra › Tempo e divisão › Dividir linhas longas |
| [Letra no notch](#feature-notch-lyrics) | Ajustes › Exibição da letra › Notch › Letra no notch |
| [Letra na barra de menus](#feature-menu-bar-lyrics) | Ajustes › Exibição da letra › Barra de menus › Letra na barra de menus |
| [Letra na Touch Bar](#feature-touch-bar-lyrics) | Ajustes › Exibição da letra › Touch Bar › Letra na Touch Bar |
| [Destaque HDR na janela da letra](#feature-lyrics-window-hdr) | Ajustes › Exibição da letra › Janela da letra › Cor › Destaque HDR |
| [Janela mini some na pausa ou em tela cheia](#feature-mini-window-auto-hide) | Ajustes › Exibição da letra › Janela da letra › Comportamento › Ocultar na pausa |
| [Fundo Spotify Canvas](#feature-spotify-canvas) | Ajustes › Exibição da letra › Janela da letra › Fundo › Spotify Canvas |
| [Transição de linha](#feature-line-transition) | Ajustes › Exibição da letra › Letra flutuante › Layout › Transição de linha |
| [Esmaecer ao passar o ponteiro](#feature-fade-on-hover) | Ajustes › Exibição da letra › Letra flutuante › Comportamento › Esmaecer ao passar o ponteiro |
| [Bloquear posição, pressionamento longo para arrastar](#feature-lock-position) | Ajustes › Exibição da letra › Letra flutuante › Comportamento › Bloquear posição |
| [Oculta em capturas e no compartilhamento de tela](#feature-hide-in-screenshots) | Ajustes › Exibição da letra › Letra flutuante › Comportamento › Ocultar em capturas de tela |
| [Ocultar ou encolher na pausa](#feature-hide-when-paused) | Ajustes › Exibição da letra › Letra flutuante › Comportamento › Ocultar na pausa |
| [Ocultar em instrumentais e músicas sem letra](#feature-hide-when-no-lyrics) | Ajustes › Exibição da letra › Letra flutuante › Comportamento › Ocultar se não houver letra |
| [Sair de cena durante anúncios](#feature-hide-during-ads) | Ajustes › Exibição da letra › Letra flutuante › Comportamento › Ocultar durante anúncios |
| [Notch na Tela Bloqueada](#feature-notch-show-on-lock-screen) | Ajustes › Exibição da letra › Notch › Comportamento › Mostrar na Tela Bloqueada |
| [Letra flutuante sai de cena em tela cheia](#feature-overlay-hide-in-full-screen) | Ajustes › Exibição da letra › Letra flutuante › Comportamento › Ocultar em tela cheia |
| [Esmaecer a linha da letra do notch ao passar o ponteiro](#feature-notch-lyric-row-fade) | Ajustes › Exibição da letra › Notch › Linha da letra › Esmaecer ao passar o ponteiro |
| [Letra na web: um celular ou tablet como segunda tela, ou uma fonte de navegador no OBS](#feature-web-lyrics) | Ajustes › Exibição da letra › Janela da letra › Letra na web |
| [YouTube Music e Spotify Web no navegador](#feature-web-players) | Ajustes › Player › Web |
| [Pular anúncios do YouTube Music automaticamente](#feature-skip-youtube-ads) | Ajustes › Player › Web › Pular anúncios do YouTube Music |
| [Abrir e encerrar junto com o player](#feature-player-linkage) | Ajustes › Player › Abrir e encerrar › Abrir players ao iniciar |
| [Scrobble no Last.fm e perfil de audição](#feature-lastfm) | Ajustes › Last.fm › Regras › Regras de scrobble |
| [Scrobble também no ListenBrainz](#feature-listenbrainz) | Ajustes › Labs › ListenBrainz › Dados da conta |
| [Mostrar no Discord o que você está ouvindo](#feature-discord) | Ajustes › Discord › Mostrar no Discord |
| [Uma página web do que está tocando, para compartilhar](#feature-now-playing-page) | Ajustes › Labs › Push web › Dados da conexão |
| [Resumos de audição diários, semanais, mensais e anuais](#feature-digests) | Ajustes › Alertas push › Canais |
| [Início silencioso](#feature-silent-launch) | Ajustes › Geral › Inicialização e notificações › Início silencioso |
| [Notificar ao trocar de música](#feature-song-notifications) | Ajustes › Geral › Inicialização e notificações › Notificar ao trocar de música |
| [Atualizações automáticas e versões beta](#feature-updates) | Ajustes › Atualização de software › Ajustes de atualização › Verificar automaticamente |

<a id="section-lyrics"></a>

## Busca de letras

<a id="feature-lyric-sources"></a>

### 15 fontes de letras, consultadas automaticamente

NetEase Cloud Music, QQ Music, Kugou, Kuwo, Migu, Musixmatch, LRCLIB, LyricFind, Deezer, AMLL, Soda Music, VIBE, Genie, PetitLyrics e Apple Music. Cada fonte pode ser desativada, reordenada ou testada para ver se está acessível agora.

- Ativado por padrão
- Ajustes: Letra › Origem › Fontes de letras

<a id="feature-network-proxy"></a>

### Fontes de letras do exterior tentam de novo por proxy

Quando uma fonte de letras do exterior não pode ser acessada diretamente, o Lyrimuse tenta de novo pelo proxy do sistema ou por um proxy local como o Clash. Você também pode informar um servidor proxy ou desativar a opção. As fontes de letras da China continental sempre se conectam diretamente.

- Ativado por padrão
- Ajustes: Geral › Rede › Proxy

<a id="feature-apple-music-lyrics"></a>

### As letras do próprio Apple Music

Conecte sua conta do Apple Music em “Fontes de letras” para usar as letras do próprio Apple Music, muitas delas sincronizadas palavra por palavra. Requer uma assinatura do Apple Music.

- Desativado por padrão
- Ajustes: Letra › Origem › Fontes de letras

<a id="feature-matching"></a>

### Busca inteligente

Por padrão, cada resultado recebe uma nota por título, artista, duração e versão (ao vivo, instrumental etc.), e vence o que melhor combina com a música que está tocando. Em vez disso, você pode usar a ordem das fontes: sem notas, é usada a primeira fonte da sua ordem que tiver a letra.

- Ajustes: Letra › Origem › Algoritmo de correspondência

<a id="feature-auto-upgrade"></a>

### Escolher a letra de novo quando a busca melhorar

Quando uma nova versão melhora a busca ou a pontuação, as letras que você já tem são verificadas de novo em segundo plano e substituídas se aparecer uma versão melhor. Desative para manter a letra depois de escolhida.

- Ativado por padrão
- Ajustes: Letra › Origem › Escolher de novo após atualizar o algoritmo

<a id="feature-prefetch"></a>

### Letra pronta antes da próxima música

Lê a fila do seu player e busca com antecedência a letra das próximas músicas; quando não há fila para ler, segue pelo resto do álbum. Para isso, QQ Music, NetEase Cloud Music, Kugou, Soda Music e VOX precisam de “Acesso Total ao Disco”.

- Ativado por padrão
- Ajustes: Letra › Origem › Pré-carregar próximas músicas
- Ajustes: Player › Permissões e serviços › Acesso Total ao Disco

<a id="feature-player-local-lyrics"></a>

### Usar a letra que o seu player já salvou

As letras que o Apple Music, o Spotify, o Kugou, o KKBOX, o Amazon Music e o LX Music já salvaram neste Mac podem ser usadas diretamente: a mesma versão que o player mostra, e mais rápido (no Apple Music e no Spotify, só as músicas cuja letra o player já mostrou). No QQ Music e no NetEase Cloud Music, a música é reconhecida pela biblioteca local do player, então exatamente essa versão é obtida sem busca. No reAMP, VOX, Pine Player e foobar2000, e no Apple Music ou no LX Music quando tocam um arquivo local da sua biblioteca ou lista local, é usada a letra dentro do arquivo em reprodução ou um arquivo .lrc com o mesmo nome. QQ Music, NetEase Cloud Music e Kugou precisam de “Acesso Total ao Disco” para o Lyrimuse nos Ajustes do Sistema; sem isso, a letra continua sendo buscada on-line.

- Desativado por padrão
- Ajustes: Player › Permissões e serviços › Acesso Total ao Disco

<a id="feature-prefer-local-file-lyrics"></a>

### Preferir a letra do arquivo da música

Quando a música que está tocando é um arquivo neste Mac, o .lrc com o mesmo nome ou a letra incorporada são usados primeiro, em vez de comparados com as letras encontradas on-line. Funciona com qualquer player que toque arquivos locais. Se essa letra não combinar com esta versão (por exemplo, se a duração não bater), a letra é buscada on-line normalmente.

- Desativado por padrão
- Ajustes: Letra › Origem › Preferir a letra do arquivo da música

<a id="feature-lock-hand-picked"></a>

### Bloquear letra escolhida à mão

Quando ativado, as letras que você escolhe à mão nos resultados da busca ficam bloqueadas, e nem a busca automática nem as novas buscas posteriores as substituem.

- Desativado por padrão
- Ajustes: Letra › Origem › Bloquear letra escolhida à mão

<a id="feature-lyrics-manager"></a>

### Gerenciador de letras

Navegue, edite, apague ou busque de novo a letra de qualquer música, apague em lote e limpe as entradas vazias que anúncios e podcasts deixam para trás. Dê a uma música o próprio deslocamento de tempo. Tente de novo, de uma vez, todas as músicas que ainda não têm letra, ou busque de novo a biblioteca inteira pelas regras atuais, com uma pausa ajustável entre as músicas; tudo o que você editou à mão fica intacto.

- Ajustes: Letra › Biblioteca de letras › Biblioteca de letras
- Ajustes: Letra › Biblioteca de letras › Buscar letras que faltam
- Ajustes: Letra › Biblioteca de letras › Buscar de novo em toda a biblioteca
- Ajustes: Atalhos de teclado › Abrir gerenciador de letras
- Ajustes: Letra › Biblioteca de letras › Intervalo de varredura

<a id="feature-song-entries"></a>

### Entradas da mesma música

A mesma música tocada em players diferentes ou de lançamentos diferentes é reconhecida como uma só: suas entradas compartilham a mesma letra, as edições à mão e os ajustes de tempo valem para todas, e as reproduções são somadas. No Gerenciador de letras, “Entradas desta música” compara linha por linha a letra de cada entrada, e uma entrada associada por engano pode ser separada e juntada de novo depois. Desative o compartilhamento para que cada entrada busque a letra por conta própria.

- Ativado por padrão
- Ajustes: Letra › Origem › Compartilhar letra entre entradas da música

<a id="feature-fix-lyrics"></a>

### Trocar ou corrigir a letra na hora

No menu ⋯ da janela da letra, busque outras letras, rode a busca de novo ou edite a letra no seu próprio editor de texto. Editar uma letra palavra por palavra muda só as palavras, nunca o tempo delas.

- Ajustes: Atalhos de teclado › Buscar letra

<a id="feature-import-lyrics"></a>

### Importar seus próprios arquivos de letra

Importe letras em LRC, LRC aprimorado, TTML, QRC, KRC, YRC ou texto simples para uma música, ou uma pasta inteira de uma vez: os arquivos são associados às músicas da sua biblioteca e mostrados em uma prévia antes de qualquer gravação. Escolha se as letras importadas substituem as atuais, substituem e ficam bloqueadas, ou só preenchem músicas sem letra. Os arquivos de músicas que você ainda não tocou são guardados e usados quando elas tocarem pela primeira vez. Uma pasta monitorada importa arquivos novos automaticamente.

- Ajustes: Letra › Biblioteca de letras › Importar pasta de letras
- Ajustes: Letra › Biblioteca de letras › Importação de pasta
- Ajustes: Letra › Biblioteca de letras › Pasta monitorada
- Ajustes: Letra › Biblioteca de letras › Biblioteca de importação

<a id="feature-offline"></a>

### Funciona off-line; as letras são arquivos .lrc comuns

Toda letra encontrada fica em cache no seu Mac e aparece sem conexão. Cada música tem um arquivo .lrc, mais .tr.lrc e .roma.lrc para tradução e pronúncia. O tempo por palavra é salvo como TTML por padrão, ou como .yrc, LRC aprimorado, QRC ou KRC. Os arquivos ficam em ~/Library/Application Support/me.yudaotor.lyrimuse/lyrics/ por padrão, e a pasta pode ser movida.

- Ajustes: Letra › Biblioteca de letras › Pasta de letras
- Ajustes: Letra › Biblioteca de letras › Formato de letra palavra por palavra

<a id="section-text"></a>

## Tradução, pronúncia e tratamento das linhas

<a id="feature-translation"></a>

### Tradução

As traduções que vêm com a letra aparecem abaixo de cada linha. NetEase Cloud Music, QQ Music e Kugou traduzem para o chinês; o Musixmatch e a tradução automática seguem o idioma da tradução que você escolher, entre 17. A letra flutuante, a janela da letra, o notch, a barra de menus e a Touch Bar decidem cada um se mostram a tradução. Aparece por padrão quando os idiomas do seu Mac incluem o chinês.

- Ajustes: Letra › Idioma › Idioma da tradução
- Ajustes: Exibição da letra › Letra flutuante › Conteúdo › Tradução
- Ajustes: Atalhos de teclado › Mostrar/ocultar tradução

<a id="feature-machine-translation"></a>

### Traduzir quando não houver tradução

Quando nenhuma fonte tem tradução, a letra é traduzida automaticamente. No macOS 15 ou posterior, com o idioma baixado, a tradução integrada da Apple faz isso no seu Mac e a letra não sai dele; caso contrário, as linhas a traduzir são enviadas ao Google Tradutor e depois ao MyMemory. Os idiomas de tradução são baixados no mesmo cartão.

- Desativado por padrão
- Ajustes: Letra › Idioma › Traduzir quando não houver tradução
- Ajustes: Letra › Idioma › Idiomas de tradução

<a id="feature-romanization"></a>

### Pronúncia

Romaji do japonês, romanização do coreano, pinyin do mandarim e jyutping do cantonês, palavra por palavra acima da letra, além de mais dezoito idiomas, como russo, tailandês, grego e hindi, pelo sistema oficial de cada idioma ou por uma norma ISO. O idioma é avaliado linha por linha, então numa música em chinês só a linha em japonês é marcada. Escolha aqui quais idiomas marcar; com a interface em chinês, o pinyin começa desativado. Cada exibição decide se mostra a pronúncia.

- Ativado por padrão
- Ajustes: Letra › Idioma › Idiomas de pronúncia
- Ajustes: Letra › Idioma › Pronúncia do japonês
- Ajustes: Exibição da letra › Letra flutuante › Conteúdo › Pronúncia
- Ajustes: Atalhos de teclado › Mostrar/ocultar pronúncia

<a id="feature-chinese-script"></a>

### Chinês simplificado ou tradicional

Mostra toda letra em chinês com caracteres simplificados ou tradicionais, seja qual for o idioma do próprio app.

- Ajustes: Letra › Idioma › Escrita chinesa

<a id="feature-split-join-lines"></a>

### Dividir linhas longas, juntar as curtas

A letra flutuante, o notch, a barra de menus e a Touch Bar dividem as linhas longas demais para a sua largura e juntam as que passam rápido demais, cada um conforme a própria largura. A janela da letra mantém uma linha por linha. São duas opções separadas.

- Desativado por padrão
- Ajustes: Letra › Tempo e divisão › Dividir linhas longas
- Ajustes: Letra › Tempo e divisão › Juntar linhas curtas

<a id="feature-timing-offset"></a>

### Deslocamento de tempo

Adiante ou atrase toda a letra, se quiser só para um player. Cada música pode ter o próprio deslocamento no Gerenciador de letras, e atalhos podem adiantar, atrasar ou redefinir o deslocamento na hora.

- Ajustes: Letra › Tempo e divisão › Deslocamento do tempo
- Ajustes: Atalhos de teclado › Adiantar letra
- Ajustes: Atalhos de teclado › Atrasar letra
- Ajustes: Atalhos de teclado › Zerar deslocamento

<a id="section-display"></a>

## Onde a letra aparece e como ela fica

<a id="feature-floating-lyrics"></a>

### Letra flutuante sobre a mesa

A letra flutua acima de todas as janelas, sempre na frente, acendendo palavra por palavra. Deixe-a onde você arrastar ou fixe-a no topo central da tela ou logo acima do Dock. Com várias telas, ela pode ficar em uma só ou acompanhar a tela da janela que você está usando. A pronúncia, a tradução e a próxima linha podem aparecer junto.

- Ativado por padrão
- Ajustes: Exibição da letra › Letra flutuante › Letra flutuante
- Ajustes: Exibição da letra › Letra flutuante › Posição
- Ajustes: Exibição da letra › Letra flutuante › Conteúdo › Próxima linha
- Ajustes: Atalhos de teclado › Mostrar/ocultar letra flutuante
- Ajustes: Exibição da letra › Letra flutuante › Posição › Mostrar em

<a id="feature-notch-lyrics"></a>

### Letra no notch

Uma cápsula no estilo Dynamic Island ao lado do notch, no topo da tela; Macs sem notch e telas externas também ganham uma. Cada lado pode mostrar o título, o artista, o álbum, a capa, os controles de reprodução ou o tempo decorrido ou restante, junto de uma onda de áudio animada. Passe o ponteiro sobre ela para expandi-la e ver controles, uma barra de progresso em que dá para mudar a posição, o ajuste de tempo da letra e botões rápidos como favoritar e buscar letra. Durante anúncios, mostra a contagem regressiva do tempo restante.

- Desativado por padrão
- Ajustes: Exibição da letra › Notch › Letra no notch
- Ajustes: Exibição da letra › Notch › Estilo
- Ajustes: Exibição da letra › Notch › Tela
- Ajustes: Exibição da letra › Notch › Ouvido esquerdo
- Ajustes: Atalhos de teclado › Mostrar/ocultar letra no notch
- Ajustes: Atalhos de teclado › Espiar a letra no notch
- Ajustes: Exibição da letra › Notch › Expandido › Ações rápidas

<a id="feature-menu-bar-lyrics"></a>

### Letra na barra de menus

A linha atual direto na barra de menus, rolando quando é longa demais em vez de ser cortada. Adicione uma segunda linha para a próxima linha, a tradução ou a pronúncia. Ela também pode ficar no meio da barra de menus, logo ao lado do notch nas telas que têm um, ou mostrar só o título, com ou sem o artista.

- Desativado por padrão
- Ajustes: Exibição da letra › Barra de menus › Letra na barra de menus
- Ajustes: Exibição da letra › Barra de menus › Layout › Posição
- Ajustes: Exibição da letra › Barra de menus › Conteúdo › O que é mostrado
- Ajustes: Exibição da letra › Barra de menus › Conteúdo › Segunda linha
- Ajustes: Atalhos de teclado › Alternar letra na barra de menus

<a id="feature-touch-bar-lyrics"></a>

### Letra na Touch Bar

Num MacBook Pro com Touch Bar, a linha atual rola enquanto é cantada, com capa e controles de reprodução opcionais. A letra pode ser branca, seguir a capa, usar uma cor sua ou fluir como um arco-íris, com brilho ajustável na parte ainda não cantada. Ela pode se expandir quando a reprodução começa e se recolher na pausa, e um botão “Mais” traz ajuste de tempo, favoritar, aleatório e repetir, volume e um controle deslizante de progresso.

- Desativado por padrão
- Ajustes: Exibição da letra › Touch Bar › Letra na Touch Bar
- Ajustes: Atalhos de teclado › Expandir/recolher letra da Touch Bar
- Ajustes: Exibição da letra › Touch Bar › Cor › Cor do texto
- Ajustes: Exibição da letra › Touch Bar › Comportamento › Expandir ao iniciar a reprodução
- Ajustes: Exibição da letra › Touch Bar › Layout › Mostrar botão “Mais”

<a id="feature-lyrics-window"></a>

### Janela da letra

Letra em página inteira inspirada na visualização de letras do Apple Music: capa desfocada ao fundo, a música inteira rolando até a linha atual, duetos separados por cantor, vocais de fundo em linha própria, notas longas que crescem e brilham. O fundo pode seguir a capa ou ser sólido, degradê ou vidro fosco, e o peso do texto, a cor da parte cantada e o alinhamento podem ser alterados. Abra-a pelo ícone da barra de menus ou por um atalho.

- Ajustes: Exibição da letra › Janela da letra › Janela da letra
- Ajustes: Exibição da letra › Janela da letra › Fundo › Fundo
- Ajustes: Atalhos de teclado › Abrir janela da letra
- Ajustes: Exibição da letra › Janela da letra › Layout › Alinhamento

<a id="feature-lyrics-window-hdr"></a>

### Destaque HDR na janela da letra

Numa tela HDR, a parte cantada da linha atual na janela da letra fica mais clara que o branco normal. Desativado por padrão; gasta mais energia quando ativado. Só no tamanho completo.

- Desativado por padrão
- Ajustes: Exibição da letra › Janela da letra › Cor › Destaque HDR

<a id="feature-mini-lyrics-window"></a>

### Janela da letra em tamanho mini

A janela da letra reduzida a um cartão pequeno: só a linha atual, a atual e a próxima, ou uma página inteira com rolagem. Fundo, cor do texto, fonte, peso, cor da parte cantada e o título, a capa e o tempo no topo são todos ajustados separadamente.

- Ajustes: Exibição da letra › Janela da letra › Layout › Layout da letra
- Ajustes: Atalhos de teclado › Alternar tamanho mini/completo

<a id="feature-mini-window-auto-hide"></a>

### Janela mini some na pausa ou em tela cheia

A janela mini pode sumir na pausa ou sem reprodução e voltar quando a reprodução começa, e sair de cena enquanto um app está em tela cheia na mesma tela (um vídeo, um jogo). Cada comportamento tem a própria opção.

- Desativado por padrão
- Ajustes: Exibição da letra › Janela da letra › Comportamento › Ocultar na pausa
- Ajustes: Exibição da letra › Janela da letra › Comportamento › Ocultar em tela cheia

<a id="feature-animated-artwork"></a>

### Capa animada

Álbuns com capa animada no Apple Music, QQ Music ou NetEase Cloud Music também se movem na janela da letra em tamanho completo, assim como álbuns cuja capa animada o Kugou Music salvou quando você os tocou nele. A animação pausa no Modo Pouca Energia ou com “Reduzir Movimento” ativado. Você pode ver quanto espaço as animações baixadas ocupam e limpá-las.

- Ativado por padrão
- Ajustes: Exibição da letra › Janela da letra › Capa › Capa animada
- Ajustes: Exibição da letra › Janela da letra › Capa › Cache de capas animadas

<a id="feature-spotify-canvas"></a>

### Fundo Spotify Canvas

Quando uma música tem um vídeo Canvas em loop no Spotify, a janela da letra em tamanho completo o reproduz como fundo em vez da capa desfocada. Só são usados vídeos que o Spotify já salvou neste Mac, então as músicas que você tocou no Spotify ganham um, inclusive quando você as toca em outro player. O vídeo pausa no Modo Pouca Energia ou com “Reduzir Movimento” ativado.

- Desativado por padrão
- Ajustes: Exibição da letra › Janela da letra › Fundo › Spotify Canvas

<a id="feature-idle-overview"></a>

### Panorama de audição entre músicas

Quando nada está tocando, a janela da letra mostra a última música com uma linha da letra e um botão “Retomar”. Com o Last.fm conectado, também mostra quanto você ouviu hoje, nos últimos 7 dias e no total, uma tendência de 30 dias, “Neste dia” e suas reproduções recentes com capa.

<a id="feature-look"></a>

### Aparência

Fonte (a do sistema ou uma sua em .ttf / .otf), tamanho, peso, cores do texto e do fundo, contorno e vidro fosco. A letra flutuante vem com temas de cores e pode salvar os seus; a cor do texto pode seguir a capa do álbum, e a letra flutuante, o notch, a barra de menus e a Touch Bar também podem fluir como um arco-íris. Atalhos, ou rolar sobre a letra com ⌘ pressionada (roda do mouse ou deslizar com dois dedos), também aumentam ou diminuem a letra flutuante na hora.

- Ajustes: Exibição da letra › Letra flutuante › Tema
- Ajustes: Exibição da letra › Letra flutuante › Tema › Meus temas
- Ajustes: Exibição da letra › Notch › Linha da letra › Cor da letra
- Ajustes: Exibição da letra › Barra de menus › Cor › Arco-íris
- Ajustes: Exibição da letra › Letra flutuante › Fonte › Fonte
- Ajustes: Exibição da letra › Letra flutuante › Cor › Fundo de vidro fosco
- Ajustes: Atalhos de teclado › Aumentar tamanho da letra flutuante
- Ajustes: Atalhos de teclado › Diminuir tamanho da letra flutuante

<a id="feature-karaoke"></a>

### Preenchimento karaokê palavra por palavra

Cada palavra acende ao ser cantada. A letra flutuante, o notch, a barra de menus, a Touch Bar e os dois tamanhos da janela da letra têm cada um a própria opção; desativado, a linha inteira acende de uma vez.

- Ativado por padrão
- Ajustes: Exibição da letra › Letra flutuante › Cor › Efeito karaokê
- Ajustes: Exibição da letra › Notch › Linha da letra › Efeito karaokê
- Ajustes: Exibição da letra › Barra de menus › Cor › Efeito karaokê
- Ajustes: Exibição da letra › Touch Bar › Cor › Efeito karaokê
- Ajustes: Exibição da letra › Janela da letra › Cor › Efeito karaokê

<a id="feature-line-transition"></a>

### Transição de linha

Quando a letra flutuante passa para a próxima linha, a linha antiga sobe e a nova vem atrás, em vez de trocar no mesmo lugar.

- Desativado por padrão
- Ajustes: Exibição da letra › Letra flutuante › Layout › Transição de linha

<a id="feature-fade-on-hover"></a>

### Esmaecer ao passar o ponteiro

A letra flutuante fica transparente enquanto o ponteiro está sobre ela, para nunca tapar o que está embaixo. A janela da letra mini tem a própria opção e também pode deixar os cliques passarem para a janela de baixo enquanto esmaecida; mantenha ⌥ pressionada para usar a janela mini.

- Desativado por padrão
- Ajustes: Exibição da letra › Letra flutuante › Comportamento › Esmaecer ao passar o ponteiro
- Ajustes: Exibição da letra › Janela da letra › Comportamento › Esmaecer ao passar o ponteiro
- Ajustes: Exibição da letra › Janela da letra › Comportamento › Cliques passam ao esmaecer

<a id="feature-lock-position"></a>

### Bloquear posição, pressionamento longo para arrastar

Bloqueie a letra flutuante no lugar ou exija um pressionamento longo antes de arrastar, para que ela nunca se mova sem querer.

- Desativado por padrão
- Ajustes: Exibição da letra › Letra flutuante › Comportamento › Bloquear posição
- Ajustes: Exibição da letra › Letra flutuante › Comportamento › Clique e segure para arrastar
- Ajustes: Atalhos de teclado › (Des)bloquear posição

<a id="feature-hover-controls"></a>

### Controles ao passar o ponteiro

Apontar para a letra flutuante mostra uma fileira de botões rápidos. A letra na barra de menus também pode mostrar controles de reprodução ao passar o ponteiro.

- Ativado por padrão
- Ajustes: Exibição da letra › Letra flutuante › Comportamento › Mostrar controles ao passar o ponteiro
- Ajustes: Exibição da letra › Barra de menus › Comportamento › Mostrar controles ao passar o ponteiro

<a id="feature-hide-in-screenshots"></a>

### Oculta em capturas e no compartilhamento de tela

Capturas de tela, gravações e telas compartilhadas deixam a letra de fora, mas você continua vendo. A letra flutuante e o notch têm cada um a própria opção.

- Desativado por padrão
- Ajustes: Exibição da letra › Letra flutuante › Comportamento › Ocultar em capturas de tela
- Ajustes: Exibição da letra › Notch › Comportamento › Ocultar em capturas de tela

<a id="feature-hide-when-paused"></a>

### Ocultar ou encolher na pausa

A letra flutuante e o notch somem na pausa ou sem reprodução; em vez disso, o notch pode encolher de volta ao tamanho do próprio notch.

- Desativado por padrão
- Ajustes: Exibição da letra › Letra flutuante › Comportamento › Ocultar na pausa
- Ajustes: Exibição da letra › Notch › Comportamento › Ocultar na pausa
- Ajustes: Exibição da letra › Notch › Comportamento › Recolher na pausa

<a id="feature-hide-when-no-lyrics"></a>

### Ocultar em instrumentais e músicas sem letra

Quando a música é instrumental, ou a busca terminou sem encontrar letra, a letra flutuante e a janela da letra mini podem sumir, e o notch e a Touch Bar podem recolher a linha da letra. Nada some enquanto a busca ainda está em andamento. Cada um tem a própria opção.

- Desativado por padrão
- Ajustes: Exibição da letra › Letra flutuante › Comportamento › Ocultar se não houver letra
- Ajustes: Exibição da letra › Janela da letra › Comportamento › Ocultar se não houver letra
- Ajustes: Exibição da letra › Notch › Comportamento › Recolher linha se não houver letra
- Ajustes: Exibição da letra › Touch Bar › Comportamento › Recolher em instrumentais e sem letra

<a id="feature-hide-during-ads"></a>

### Sair de cena durante anúncios

Enquanto o player toca um anúncio, a letra flutuante pode sumir e o notch pode encolher até a faixa superior; passar o ponteiro sobre o notch ainda o expande. Cada um tem a própria opção.

- Desativado por padrão
- Ajustes: Exibição da letra › Letra flutuante › Comportamento › Ocultar durante anúncios
- Ajustes: Exibição da letra › Notch › Comportamento › Recolher durante anúncios

<a id="feature-hide-in-full-screen"></a>

### Notch sai de cena em tela cheia

A letra no notch se recolhe enquanto um vídeo, um jogo ou qualquer app está em tela cheia.

- Ativado por padrão
- Ajustes: Exibição da letra › Notch › Comportamento › Ocultar em tela cheia

<a id="feature-notch-show-on-lock-screen"></a>

### Notch na Tela Bloqueada

O notch continua mostrando a música que está tocando e a letra na Tela Bloqueada.

- Desativado por padrão
- Ajustes: Exibição da letra › Notch › Comportamento › Mostrar na Tela Bloqueada

<a id="feature-overlay-hide-in-full-screen"></a>

### Letra flutuante sai de cena em tela cheia

Normalmente a letra flutuante fica na frente dos apps em tela cheia. Ative esta opção para que ela se oculte enquanto um vídeo, um jogo ou qualquer app está em tela cheia e volte quando você sair.

- Desativado por padrão
- Ajustes: Exibição da letra › Letra flutuante › Comportamento › Ocultar em tela cheia

<a id="feature-title-on-change"></a>

### Título aparece ao trocar de música

O título e o artista de cada nova música deslizam para fora do notch por um instante e depois voltam para dentro.

- Ativado por padrão
- Ajustes: Exibição da letra › Notch › Comportamento › Mostrar título ao trocar de música

<a id="feature-listening-milestones"></a>

### Marcos de audição

Quando uma música chega à 100ª, 1.000ª ou 10.000ª reprodução, ou o seu total no Last.fm passa de um marco, o notch se abre para comemorar. Requer o Last.fm conectado.

- Ativado por padrão
- Ajustes: Exibição da letra › Notch › Comportamento › Marcos de audição

<a id="feature-notch-gestures"></a>

### Gestos do trackpad no notch

Com o ponteiro sobre o notch, deslize dois dedos para a esquerda ou para a direita para trocar de música, ou para cima e para baixo para ajustar o volume do sistema.

- Ativado por padrão
- Ajustes: Exibição da letra › Notch › Comportamento › Gestos do trackpad
- Ajustes: Exibição da letra › Notch › Comportamento › Mostrar com teclas de volume

<a id="feature-notch-lyric-row-fade"></a>

### Esmaecer a linha da letra do notch ao passar o ponteiro

Com o ponteiro na linha da letra do notch, a linha esmaece em vez de expandir e os cliques passam para a janela de baixo; o notch só se expande pelo próprio notch ou pelas laterais.

- Desativado por padrão
- Ajustes: Exibição da letra › Notch › Linha da letra › Esmaecer ao passar o ponteiro

<a id="feature-notch-multiline-lyrics"></a>

### Letra em várias linhas no notch expandido

Quando o notch se expande sob o ponteiro, a área da letra vira uma lista de 3, 5 ou 7 linhas, com a linha atual acendendo palavra por palavra e a lista subindo a cada nova linha; clique em uma linha para ir até ela. Se a linha da letra estiver desativada, o notch fica como uma faixa de status fina e só mostra a letra quando expandido.

- Ativado por padrão
- Ajustes: Exibição da letra › Notch › Expandido › Letra em várias linhas
- Ajustes: Exibição da letra › Notch › Expandido › Linhas

<a id="feature-web-lyrics"></a>

### Letra na web: um celular ou tablet como segunda tela, ou uma fonte de navegador no OBS

A letra em um navegador. “Letra na web” mostra exatamente o que a janela da letra mostra; “Saída para OBS” tem fundo transparente e as mesmas fontes e cores da letra flutuante, mais um cartão de título (título, artista e capa) no canto superior esquerdo, que pode aparecer sempre, ao trocar de música ou nunca. Cada um tem a própria porta e o próprio ajuste de rede local. Os dois ficam disponíveis só neste Mac até você ativar “Permitir acesso pela rede local”; aí, dispositivos na mesma rede podem escanear um código QR para se conectar, usando um link com uma chave de acesso. Com “Permitir controle remoto” ativado, a página também pode controlar a reprodução e pular para uma linha.

- Desativado por padrão
- Ajustes: Exibição da letra › Janela da letra › Letra na web
- Ajustes: Exibição da letra › Janela da letra › Letra na web › Permitir acesso pela rede local
- Ajustes: Exibição da letra › Letra flutuante › OBS › Saída para OBS
- Ajustes: Exibição da letra › Letra flutuante › OBS › Cartão de título
- Ajustes: Exibição da letra › Janela da letra › Letra na web › Permitir controle remoto

<a id="section-players"></a>

## Players e reprodução

<a id="feature-players"></a>

### Quinze players: escolha vários ou detecte automaticamente

Apple Music, Spotify, QQ Music, NetEase Cloud Music, Kugou, Soda Music, LX Music, KKBOX, Amazon Music, o reAMP no estilo Winamp, o VOX, player local sem perdas e de alta resolução, o Pine Player, player local gratuito que toca quase todos os formatos, o clássico player local foobar2000, trazido do Windows,, o Kaset, app do YouTube Music, e o Pear Desktop, app de desktop de código aberto para o YouTube Music. Escolha vários de uma vez ou deixe no automático para seguir o que o macOS mostra em Reproduzindo. O rádio do Apple Music também funciona, mostrando o nome e o logotipo da estação enquanto o apresentador fala.

- Ajustes: Player › Apps de música

<a id="feature-web-players"></a>

### YouTube Music e Spotify Web no navegador

Pareie seu navegador uma vez e a música que toca nele também ganha letra, seguindo o progresso da própria página. Uma verificação com um clique informa antes se esse navegador pode ser controlado. Durante anúncios, o notch mostra o tempo restante e qual anúncio está tocando.

- Desativado por padrão
- Ajustes: Player › Web

<a id="feature-skip-youtube-ads"></a>

### Pular anúncios do YouTube Music automaticamente

No YouTube Music do navegador, os anúncios são pulados assim que o botão “Pular” aparece. Com a opção desativada, você ainda pode pular pelo notch. Requer a permissão de “Acessibilidade”.

- Desativado por padrão
- Ajustes: Player › Web › Pular anúncios do YouTube Music
- Ajustes: Player › Permissões e serviços › Acessibilidade

<a id="feature-other-players"></a>

### Adicionar outros players

Players que não estão na lista podem ser adicionados aos seus players confiáveis a partir da pasta Aplicativos, e o Lyrimuse pergunta quando nota um player desconhecido tocando música.

- Ajustes: Player › Outros apps
- Ajustes: Player › Adicionar app…
- Ajustes: Player › Alertas de novos players

<a id="feature-permissions"></a>

### Permissões, só onde necessário

Apple Music, Spotify, Kaset e VOX precisam da permissão de “Automação” para ler o que está tocando. QQ Music, NetEase Cloud Music e Kugou precisam de “Acesso Total ao Disco” para as letras salvas e as filas, e Soda Music e VOX, para as filas. A calibração do progresso no Amazon Music e no Pine Player, a playlist do Pine Player, os botões de aleatório, repetir e favoritar do QQ Music, NetEase Cloud Music, Kugou Music, Soda Music, Amazon Music, reAMP, Pine Player e foobar2000, o volume do foobar2000 e os botões de reprodução do QQ Music, NetEase Cloud Music, Soda Music, Pine Player e foobar2000 enquanto outro app ocupa o Reproduzindo precisam de “Acessibilidade”. Os players na web precisam de “Automação” para o navegador e da opção “Permitir JavaScript de Eventos Apple” dele. Os outros players não precisam de nada. Os Ajustes mostram o estado atual de cada um.

- Ajustes: Player › Permissões e serviços › Permissão de automação
- Ajustes: Player › Permissões e serviços › Acesso Total ao Disco
- Ajustes: Player › Permissões e serviços › Acessibilidade

<a id="feature-controls"></a>

### Controles de reprodução e posição

Reproduza, pause, pule e arraste a barra de progresso na janela da letra ou no notch expandido. Aleatório, repetir, favoritar e volume dependem do player: Apple Music, Spotify, Kaset, QQ Music, Amazon Music, reAMP, VOX, Pine Player, foobar2000, Pear Desktop e YouTube Music no navegador têm alguns ou todos eles, e NetEase Cloud Music, Kugou Music, Soda Music e LX Music têm favoritar, com volume também no LX Music depois que a Open API é ativada nos ajustes dele. Reproduzir, pausar, pular e favoritar podem ter atalhos globais. Enquanto algo como um vídeo no navegador ocupa o Reproduzindo, reproduzir, pausar e pular no QQ Music, NetEase Cloud Music, Soda Music, Pine Player e foobar2000 passam pelos próprios menus ou pela barra de reprodução deles, e não é possível mudar a posição.

- Ajustes: Exibição da letra › Notch › Expandido › Mostrar controles
- Ajustes: Atalhos de teclado › Reproduzir/Pausar
- Ajustes: Atalhos de teclado › Faixa seguinte
- Ajustes: Atalhos de teclado › Faixa anterior
- Ajustes: Atalhos de teclado › Adicionar/remover dos favoritos
- Ajustes: Player › Permissões e serviços › Open API do LX Music

<a id="feature-song-pages"></a>

### Abrir a página da música com um clique

Um clique no menu ⋯ abre a música, o álbum ou o artista na plataforma em que você está ouvindo. Apple Music e KKBOX abrem nos próprios apps, e o Spotify vai direto para a música no app; o resto abre na web: álbuns e artistas do Spotify, QQ Music, Soda Music, Amazon Music e YouTube Music. NetEase Cloud Music e Kugou têm só a página da música.

<a id="feature-about-panels"></a>

### Notas da música, do álbum e do artista

Clique no título, no artista ou no álbum na janela da letra ou no notch expandido para ler sobre eles. As notas do álbum e do artista vêm primeiro do Apple Music; se não houver, do Soda Music, Kugou Music e NetEase Cloud Music (só com a interface em chinês), depois da Wikipédia via YouTube Music e por fim do Last.fm. As notas da música vêm do QQ Music (só com a interface em chinês) ou do Last.fm. O Last.fm requer sua conta conectada.

<a id="feature-player-linkage"></a>

### Abrir e encerrar junto com o player

Por player: abrir o player quando o Lyrimuse abre, abrir o Lyrimuse quando o player abre, ou encerrar o Lyrimuse quando todos os players que ele acompanha forem encerrados.

- Desativado por padrão
- Ajustes: Player › Abrir e encerrar › Abrir players ao iniciar
- Ajustes: Player › Abrir e encerrar › Abrir com o player
- Ajustes: Player › Abrir e encerrar › Encerrar com o player

<a id="section-listening"></a>

## Scrobble, Last.fm e compartilhamento

<a id="feature-lastfm"></a>

### Scrobble no Last.fm e perfil de audição

Conecte o Last.fm com um clique, sem token para copiar. Veja as reproduções de hoje, desta semana e de sempre, as Paradas de artistas, álbuns e músicas com a variação de posição, e a “Pegada”: um mapa de calor do ano em que clicar em um dia lista as músicas mais tocadas, as horas de audição, de onde vêm seus artistas e “Neste dia”. Curta qualquer música recente com um clique.

- Desativado por padrão
- Ajustes: Last.fm › Regras › Regras de scrobble

<a id="feature-scrobble-rules"></a>

### Regras de scrobble personalizadas

Conte uma reprodução aos 50%, 75%, 90% ou só no fim; decida o que fazer com músicas de menos de 30 segundos; por padrão, artistas convidados, variantes de escrita do chinês e sufixos como “- Single” são associados ao registro do catálogo do Last.fm, ou envie tudo como está; deixe qualquer player totalmente fora do Last.fm.

- Ajustes: Last.fm › Regras › Momento do scrobble
- Ajustes: Last.fm › Regras › Scrobble de músicas com menos de 30 segundos
- Ajustes: Last.fm › Regras › Modo de correspondência
- Ajustes: Last.fm › Regras › Players com scrobble

<a id="feature-local-log"></a>

### Toda reprodução é registrada primeiro no Mac

As reproduções feitas enquanto o Last.fm não está conectado ficam registradas no seu Mac; depois de conectar, clique em “Enviar pendentes” em “Scrobbles pendentes” na página do Last.fm. Uma reprodução que talvez não tenha chegado ao Last.fm enquanto conectado é conferida com o Last.fm e reenviada automaticamente. O Last.fm só aceita reproduções das últimas duas semanas, aproximadamente.

<a id="feature-listenbrainz"></a>

### Scrobble também no ListenBrainz

Cada reprodução vai para o Last.fm e para o ListenBrainz a partir da mesma leitura, então os dois batem. As reproduções que seu iPhone envia ao Last.fm também podem ser copiadas para o ListenBrainz. Em “Labs”, na barra lateral.

- Desativado por padrão
- Ajustes: Labs › ListenBrainz › Dados da conta

<a id="feature-discord"></a>

### Mostrar no Discord o que você está ouvindo

Seu perfil e sua lista de amigos mostram o player, o título, o artista, a capa e uma barra de progresso; clicar no título ou no artista abre a página web do player. A linha do álbum pode mostrar a linha que está sendo cantada, e é possível adicionar até dois botões. Escolha como o texto é organizado, quais players contam, se continua aparecendo na pausa e qual selo fica sobre a capa, mostre só o player sem dizer a música ou oculte por um tempo.

- Desativado por padrão
- Ajustes: Discord › Mostrar no Discord
- Ajustes: Discord › Players mostrados
- Ajustes: Discord › Ao pausar
- Ajustes: Discord › Ocultar por um tempo
- Ajustes: Discord › O que é mostrado
- Ajustes: Discord › Botões
- Ajustes: Discord › Ocultar detalhes da música

<a id="feature-now-playing-page"></a>

### Uma página web do que está tocando, para compartilhar

Uma página pública com o que você está ouvindo e seu histórico, com livro de visitas, reações, contador de visitantes, os 10 artistas mais ouvidos e visual de vinil, todos opcionais. Só o ListenBrainz já dá a reprodução ao vivo e o histórico; para o resto, implante um Cloudflare Worker seguindo o guia. Em “Labs”.

- Desativado por padrão
- Ajustes: Labs › Push web › Dados da conexão

<a id="feature-digests"></a>

### Resumos de audição diários, semanais, mensais e anuais

Enviados para os canais que você configurar, quantos quiser: Bark, ntfy, ServerChan, Feishu, DingTalk, WeCom, Telegram, Discord, Slack ou um webhook genérico. Cada canal pode mostrar uma prévia de como o envio vai ficar e mandar um teste, e o histórico de entregas mostra se cada envio chegou, com a opção de reenviar os que não chegaram. Os relatórios comparam com o período anterior, citam os artistas que você ouviu pela primeira vez e estimam quanto tempo você ouviu, formatados para cada plataforma com a capa do álbum e um link para o ranking completo. Cada um dos quatro tem a própria opção e, com vários canais, a própria escolha de canais; você escolhe o horário do envio (no fuso horário atual do Mac) e quantos itens cada lista mostra, e cada canal pode usar o relatório completo, breve ou resumido, ou seu próprio título e corpo com marcadores.

- Desativado por padrão
- Ajustes: Alertas push › Canais
- Ajustes: Alertas push › Horário de envio
- Ajustes: Alertas push › Relatórios de audição
- Ajustes: Alertas push › Origem dos dados
- Ajustes: Alertas push › Itens por lista
- Ajustes: Alertas push › Relatório diário de audição
- Ajustes: Alertas push › Resumo semanal de audição
- Ajustes: Alertas push › Resumo de audição mensal
- Ajustes: Alertas push › Resumo de audição anual
- Ajustes: Alertas push › Histórico de envios

<a id="section-general"></a>

## No dia a dia

<a id="feature-onboarding"></a>

### Configuração na primeira abertura

Na primeira vez que você abre o Lyrimuse, ele guia você na escolha dos players, no pareamento de um navegador e na escolha de onde a letra aparece, e verifica cada permissão necessária para você resolver o que faltar na hora.

<a id="feature-language"></a>

### Inglês, chinês simplificado e tradicional, japonês, coreano, espanhol, francês, alemão, italiano, português do Brasil, vietnamita e russo

Segue o sistema por padrão, e usa o inglês quando o idioma do sistema não é um desses; a troca vale na hora, sem reiniciar.

- Ajustes: Geral › Aparência e idioma › Idioma

<a id="feature-appearance"></a>

### Claro, escuro ou automático

Os Ajustes, a janela da letra, o Gerenciador de letras e o painel da barra de menus podem ficar claros ou escuros; por padrão, seguem o sistema. A letra flutuante continua seguindo o sistema, e o notch é sempre escuro.

- Ajustes: Geral › Aparência e idioma › Aparência

<a id="feature-shortcuts"></a>

### Atalhos de teclado globais

Mostrar ou ocultar cada tipo de letra (ou todos de uma vez, para reuniões e compartilhamento de tela), abrir a janela da letra e o Gerenciador de letras, buscar, ajustar o tempo, reprodução, favoritar e alternar para o player podem ter atalhos. Nenhum vem definido por padrão.

- Ajustes: Atalhos de teclado › Abrir ajustes
- Ajustes: Atalhos de teclado › Ocultar/restaurar todas as letras
- Ajustes: Atalhos de teclado › Ir para o player
- Ajustes: Atalhos de teclado › Abrir/fechar painel da barra de menus

<a id="feature-deep-links"></a>

### Deep links (lyrimuse://)

Os links lyrimuse:// abrem qualquer página dos Ajustes, a janela da letra ou o Gerenciador de letras e executam toda ação que pode ter atalho, como reprodução, favoritar ou ocultar todas as letras, a partir do app Atalhos, do Raycast, do Alfred e de ferramentas parecidas. Aberto com x-callback-url pelo app Atalhos, um link também pode devolver o título, o artista, o álbum e a linha atual. O cartão “Deep links” na página “Atalhos de teclado” lista todos os links, prontos para copiar.

- Ajustes: Atalhos de teclado › Deep links

<a id="feature-settings-search"></a>

### Busca nos ajustes

Digite no topo da barra lateral dos Ajustes para ir direto a um ajuste, destacado, mesmo dentro de seções recolhidas. Busque em inglês ou em chinês.

<a id="feature-menu-bar-icon"></a>

### Ícone da barra de menus

Doze ícones em três tamanhos, que se movem com a música durante a reprodução, ou a capa do álbum do que está tocando. As ações do dia a dia ficam no menu dele.

- Ativado por padrão
- Ajustes: Geral › Barra de menus e Dock › Ícone da barra de menus
- Ajustes: Geral › Barra de menus e Dock › Capa do álbum
- Ajustes: Geral › Barra de menus e Dock › Tamanho do ícone
- Ajustes: Geral › Barra de menus e Dock › Animar ícone

<a id="feature-dock-icon"></a>

### Mostrar no Dock

Desative para manter só o ícone da barra de menus.

- Ativado por padrão
- Ajustes: Geral › Barra de menus e Dock › Mostrar no Dock

<a id="feature-launch-at-login"></a>

### Abrir ao iniciar sessão

Abre o Lyrimuse quando você inicia sessão no Mac.

- Ativado por padrão
- Ajustes: Geral › Inicialização e notificações › Abrir ao iniciar sessão

<a id="feature-silent-launch"></a>

### Início silencioso

Inicia sem abrir nenhuma janela, só com o ícone da barra de menus.

- Desativado por padrão
- Ajustes: Geral › Inicialização e notificações › Início silencioso

<a id="feature-song-notifications"></a>

### Notificar ao trocar de música

Uma notificação do sistema a cada nova música.

- Desativado por padrão
- Ajustes: Geral › Inicialização e notificações › Notificar ao trocar de música

<a id="feature-backup"></a>

### Backup dos ajustes, migração para um Mac novo

Exporte todos os seus ajustes para um único arquivo, salvo no iCloud Drive por padrão ou numa pasta que você escolher; quando um Mac novo abre o Lyrimuse pela primeira vez e o encontra no iCloud, ele oferece importá-lo.

- Ajustes: Geral › Backup e migração › Backup do iCloud
- Ajustes: Geral › Backup e migração › Arquivo de ajustes

<a id="feature-updates"></a>

### Atualizações automáticas e versões beta

Procura novas versões sozinho; leia as notas e instale pela página “Atualização de software”. Ative “Atualizações beta” para experimentar as novidades antes.

- Desativado por padrão
- Ajustes: Atualização de software › Ajustes de atualização › Verificar automaticamente
- Ajustes: Atualização de software › Ajustes de atualização › Baixar e instalar automaticamente
- Ajustes: Atualização de software › Ajustes de atualização › Atualizações beta

<a id="feature-diagnostics"></a>

### Diagnóstico e relato de bugs com um clique

Reúne logs, relatórios de falhas e o estado do app em um único arquivo, sem credenciais e sem seu nome de usuário. “Comunicar problema” abre uma issue no GitHub com sua versão, macOS e player já preenchidos.

- Ajustes: Sobre › Diagnóstico e dados › Exportar diagnóstico
- Ajustes: Sobre › Atualizações e ajuda › Comunicar problema

<a id="feature-telemetry"></a>

### Dados de uso anônimos, que você pode desativar

No máximo uma vez por dia, envia a versão, o macOS, quais recursos estão ativados e resumos de falhas para o servidor do próprio autor, para decidir o que corrigir primeiro. Nunca títulos de músicas, artistas, caminhos locais ou contas. Ativado por padrão; desative nos Ajustes ou na tela de boas-vindas.

- Ajustes: Sobre › Diagnóstico e dados › Compartilhar dados de uso anônimos

<a id="section-all-settings"></a>

## Todos os ajustes

Todos os ajustes da janela Ajustes, por local: 311 no total. Digite um nome no campo de busca no topo da barra lateral dos Ajustes para ir direto até ele.

### Letra › Origem

- **Fontes de letras**
- **Algoritmo de correspondência**
- **Preferir a letra do arquivo da música**: Ao tocar um arquivo local, usar primeiro o .lrc de mesmo nome ou a letra incorporada
- **Escolher de novo após atualizar o algoritmo**: Reavaliada em segundo plano; pode mudar para uma versão melhor
- **Compartilhar letra entre entradas da música**: Uma cópia por gravação em todos os players e versões de álbum; edições também são sincronizadas
- **Bloquear letra escolhida à mão**: A letra escolhida manualmente nunca é substituída pela busca automática
- **Pré-carregar próximas músicas**: Obtém com antecedência a letra das próximas músicas

### Letra › Idioma

- **Idioma da tradução**
- **Traduzir quando não houver tradução**: Traduz primeiro neste Mac e, quando não é possível, online
- **Idiomas de tradução**: Idiomas do sistema usados na tradução no dispositivo
- **Escrita chinesa**
- **Idiomas de pronúncia**
- **Pronúncia do japonês**: Romaji, ou hiragana só nos kanji

### Letra › Tempo e divisão

- **Dividir linhas longas**: Linhas longas demais são divididas e mostradas em partes
- **Juntar linhas curtas**: Linhas curtas vizinhas são unidas quando cabem em uma linha
- **Deslocamento do tempo**: Valores positivos adiantam a letra e negativos a atrasam

### Letra › Biblioteca de letras

- **Biblioteca de letras**
- **Buscar letras que faltam**: Só músicas sem letra ou com letra em texto simples
- **Buscar de novo em toda a biblioteca**: Inclui músicas que já têm letra, exceto as editadas, calibradas e instrumentais
- **Intervalo de varredura**: Segundos entre músicas; recomenda-se pelo menos 2 segundos para evitar limites de solicitações
- **Pasta de letras**: Os arquivos existentes não são movidos quando você muda o local
- **Formato de letra palavra por palavra**
- **Importar pasta de letras**: Associa os arquivos de letra de uma pasta às músicas da sua biblioteca, com prévia antes de importar
- **Importação de pasta**
- **Pasta monitorada**: Arquivos de letra novos ou alterados na pasta são importados automaticamente: músicas sem letra a recebem na hora e as que já têm não mudam
- **Biblioteca de importação**: Ver e apagar letras importadas

### Player

- **Apps de música**
- **Web**: A letra também funciona com música tocando no navegador. Clique em + para parear o navegador que você usa; a posição é lida direto da página, então a letra sincroniza logo após a troca de música
- **Outros apps**: Apps não listados acima também podem ser usados como players: depois de adicionados, as músicas deles mostram a letra e contam para o seu histórico de reprodução
- **Adicionar app…**: Escolha um em Aplicativos, sem esperar que comece a tocar
- **Alertas de novos players**

### Player › Web

- **Pular anúncios do YouTube Music**: Anúncios puláveis são pulados assim que aparecem

### Player › Permissões e serviços

- **Permissão de automação**
- **Acesso Total ao Disco**
- **Acessibilidade**
- **Open API do LX Music**: O Lyrimuse lê a posição de reprodução do LX Music e ajusta o volume dele por esta API
- **API do Pear Desktop**: O Lyrimuse lê do Pear Desktop o ID e o tipo da música atual e a fila de reprodução por esta API
- **Motor de letras**: Lê o status de reprodução e obtém a letra e a capa

### Player › Abrir e encerrar

- **Abrir e encerrar**: Só aparecem os players que você selecionou. Com “Detecção automática” ativada, os players instalados neste Mac também aparecem
- **Abrir players ao iniciar**
- **Abrir com o player**
- **Encerrar com o player**

### Exibição da letra › Letra flutuante

- **Letra flutuante**
- **OBS**
- **Tema**
- **Largura**
- **Posição**
- **Restaurar padrões**: Restaura só o tema, a fonte e as cores

### Exibição da letra › Letra flutuante › OBS

- **Saída para OBS**: Sobreponha a letra à sua transmissão como fonte de navegador. Defina a largura e a altura com o tamanho da tela do OBS
- **URL da fonte de navegador**
- **Cartão de título**: Mostra título, artista e capa no canto superior esquerdo
- **Permitir acesso pela rede local**: Dispositivos na mesma rede podem se conectar com um link que inclui uma chave de acesso
- **Link de acesso**
- **Link alternativo (endereço IP)**
- **Redefinir chave de acesso**: Os links que você já compartilhou vão parar de funcionar
- **Porta**: Depois de mudar, atualize a URL no OBS

### Exibição da letra › Letra flutuante › Tema

- **Meus temas**

### Exibição da letra › Letra flutuante › Fonte

- **Fonte**
- **Peso**
- **Tamanho**
- **Corpo da pronúncia**
- **Corpo da tradução**
- **Corpo da próxima**

### Exibição da letra › Letra flutuante › Cor

- **Efeito karaokê**
- **Cor do texto**
- **Contorno do texto**
- **Cor do contorno**
- **Cor não cantada**
- **Cor de fundo**
- **Fundo de vidro fosco**
- **Densidade do vidro**

### Exibição da letra › Letra flutuante › Conteúdo

- **Pronúncia**
- **Tradução**
- **Próxima linha**

### Exibição da letra › Letra flutuante › Layout

- **Alinhamento**
- **Linhas longas**
- **Transição de linha**: Ao mudar de linha, a próxima sobe para a posição atual. Quando desativado, as linhas mudam na hora
- **Pronúncia**
- **Tradução**
- **Próxima linha**

### Exibição da letra › Letra flutuante › Comportamento

- **Bloquear posição**
- **Clique e segure para arrastar**
- **Esmaecer ao passar o ponteiro**
- **Mostrar controles ao passar o ponteiro**
- **Ocultar em capturas de tela**
- **Ocultar na pausa**
- **Ocultar se não houver letra**
- **Ocultar durante anúncios**
- **Ocultar em tela cheia**

### Exibição da letra › Letra flutuante › Posição

- **Mostrar em**

### Exibição da letra › Notch

- **Letra no notch**
- **Estilo**
- **Tela**
- **Ouvido esquerdo**
- **Ouvido direito**
- **Largura**
- **Largura expandida**
- **Restaurar padrões**: A largura e a opção “Letra no notch” ficam como estão

### Exibição da letra › Notch › Estilo

- **Fundo expandido**
- **Cantos**
- **Cantos expandidos**
- **Linha de progresso**: Mostra o progresso da reprodução quando não está expandido

### Exibição da letra › Notch › Ouvido esquerdo

- **Onda sonora**: Aparece em um lado por vez

### Exibição da letra › Notch › Linha da letra

- **Letra no modo recolhido**: Quando desativado, só fica a faixa da altura do notch até você passar o ponteiro para expandir
- **Alinhamento**
- **Cor da letra**
- **Segunda linha**
- **Prévia da próxima linha ao expandir**
- **Altura**
- **Efeito karaokê**
- **Mostrar capa**
- **Posição da capa**
- **Esmaecer ao passar o ponteiro**

### Exibição da letra › Notch › Fonte

- **Fonte**
- **Peso**
- **Tamanho**

### Exibição da letra › Notch › Expandido

- **Letra em várias linhas**: Mostra várias linhas da letra quando expandido, com a linha atual acendendo palavra por palavra
- **Linhas**
- **Mostrar controles**
- **Mostrar deslocamento**
- **Ações rápidas**
- **Informações da música**

### Exibição da letra › Notch › Comportamento

- **Recolher na pausa**
- **Ocultar em capturas de tela**
- **Ocultar na pausa**
- **Recolher linha se não houver letra**
- **Recolher durante anúncios**
- **Ocultar em tela cheia**
- **Mostrar na Tela Bloqueada**
- **Marcos de audição**
- **Mostrar título ao trocar de música**
- **Mostrar com teclas de volume**
- **Gestos do trackpad**

### Exibição da letra › Barra de menus

- **Letra na barra de menus**
- **Restaurar padrões**: A largura e a opção “Letra na barra de menus” não mudam

### Exibição da letra › Barra de menus › Conteúdo

- **O que é mostrado**
- **Segunda linha**
- **Ícone ao lado da letra**: O ícone se preenche de baixo para cima para mostrar o progresso, com as cores definidas em “Cor”

### Exibição da letra › Barra de menus › Layout

- **Posição**: Centro: a letra aparece no meio da barra de menus, sem cobrir os menus de apps, os ícones à direita nem o notch
- **Mostrar em**
- **Modo de largura**: Fixo: todas as músicas usam a largura definida Adaptável: cada música recebe a largura da sua letra, até a largura definida
- **Alinhamento**

### Exibição da letra › Barra de menus › Cor

- **Efeito karaokê**
- **Arco-íris**: A letra flui da esquerda para a direita nas cores do arco-íris, mais escura em uma barra de menus clara; as cores do sistema voltam enquanto o menu está aberto
- **Cor do texto**
- **Cor cantada**

### Exibição da letra › Barra de menus › Fonte

- **Fonte**
- **Peso**
- **Tamanho**

### Exibição da letra › Barra de menus › Largura

- **Largura máxima**

### Exibição da letra › Barra de menus › Comportamento

- **Mostrar controles ao passar o ponteiro**
- **Mostrar título se não houver letra**: Mostra o título da música no lugar da letra quando não há letra ou ela ainda está sendo buscada

### Exibição da letra › Touch Bar

- **Letra na Touch Bar**
- **Restaurar padrões**: O ajuste “Letra na Touch Bar” não muda

### Exibição da letra › Touch Bar › Conteúdo

- **Segunda linha**
- **Tamanho**

### Exibição da letra › Touch Bar › Layout

- **Alinhamento**
- **Mostrar capa**
- **Posição da capa**
- **Mostrar controles**: Anterior, Reproduzir/Pausar e Seguinte, mais um botão de ajustes
- **Posição dos controles**
- **Mostrar botão “Mais”**: Toque nele para alternar para posição de reprodução, calibração da letra, favorito, aleatório/repetir e volume. Itens que o player atual não suporta ficam ocultos
- **Ocultar Control Strip ao expandir**: A letra ocupa a Touch Bar inteira. Para acessar brilho, volume e outros botões do sistema, toque primeiro em ✕ à esquerda para recolher a letra
- **Control Strip**: Adicione, remova ou reordene os botões de brilho, volume e outros do sistema à direita da Touch Bar em Ajustes do Sistema › Teclado › Ajustes da Touch Bar…

### Exibição da letra › Touch Bar › Cor

- **Efeito karaokê**
- **Cor do texto**: Branco, cor da capa, cor personalizada ou arco-íris
- **Brilho do texto esmaecido**: Brilho das palavras não cantadas e da segunda linha

### Exibição da letra › Touch Bar › Comportamento

- **Expandir ao iniciar a reprodução**: Mostra a letra quando a reprodução é retomada após uma pausa. Trocar de música durante a reprodução não a expande, e a letra que você recolheu continua recolhida
- **Recolher na pausa**: Recolhe-se no botão da Control Strip após 10 segundos em pausa e expande de novo quando a reprodução é retomada
- **Recolher em instrumentais e sem letra**: Só recolhe depois de confirmar que não há letra e expande de novo quando ela é encontrada. Continua visível durante a busca

### Exibição da letra › Janela da letra

- **Janela da letra**
- **Letra na web**: Mostrar a janela da letra em um navegador
- **Restaurar padrões**

### Exibição da letra › Janela da letra › Letra na web

- **Endereço local**
- **Permitir acesso pela rede local**: Dispositivos na mesma rede podem se conectar com um link que inclui uma chave de acesso
- **Permitir controle remoto**: Controle a reprodução e pule para a letra em outros dispositivos
- **Link de acesso**
- **Link alternativo (endereço IP)**
- **Redefinir chave de acesso**: Os links que você já compartilhou vão parar de funcionar
- **Porta**: Depois de mudar, escaneie o código QR de novo para reconectar

### Exibição da letra › Janela da letra › Fundo

- **Fundo**: O fundo da janela da letra: capa, sólido, degradê ou vidro fosco
- **Direção**
- **Spotify Canvas** (só Completo): Usa o vídeo em loop da música no Spotify como fundo; só para músicas que você tocou no Spotify
- **Densidade do vidro**: Densidade do material de vidro fosco (cinco níveis)
- **Cor inferior**

### Exibição da letra › Janela da letra › Fonte

- **Tamanho** (só Mini): Tamanho máximo da letra no Mini
- **Fonte**: Fonte da letra na janela da letra (texto, tradução e pronúncia)
- **Peso**

### Exibição da letra › Janela da letra › Layout

- **Linhas longas** (só Mini): Se as linhas longas quebram ou rolam no tamanho mini
- **Layout da letra** (só Mini): Uma linha: só a linha atual Duas linhas: a linha atual e a próxima Várias linhas: uma página de letra com rolagem, como no tamanho completo
- **Alinhamento** (só Completo): Alinhamento da letra no tamanho completo; “Auto” segue as vozes do dueto

### Exibição da letra › Janela da letra › Comportamento

- **Esmaecer ao passar o ponteiro** (só Mini)
- **Cliques passam ao esmaecer** (só Mini): Enquanto a janela está esmaecida, os cliques passam para a de baixo. Mantenha ⌥ pressionada para deixá-la opaca e interagir
- **Ocultar na pausa** (só Mini)
- **Ocultar se não houver letra** (só Mini)
- **Ocultar em tela cheia** (só Mini)

### Exibição da letra › Janela da letra › Cor

- **Efeito karaokê**
- **Cor do texto**: A cor do texto da janela da letra. “Auto” alterna entre claro e escuro conforme o brilho do fundo
- **Cor personalizada**
- **Cor cantada**
- **Destaque HDR** (só Completo): Ilumina a parte cantada em telas HDR. Gasta mais energia quando ativado

### Exibição da letra › Janela da letra › Conteúdo

- **Pronúncia**
- **Tradução**
- **Barra de progresso** (só Mini): Quando desativada, só aparece junto com os controles de reprodução ao passar o ponteiro

### Exibição da letra › Janela da letra › Cabeçalho

- **Título** (só Mini): Mostrar o título, o artista e o álbum no topo do tamanho mini
- **Artista** (só Mini)
- **Álbum** (só Mini)
- **Capa** (só Mini): A miniatura da capa ao lado das informações no topo do tamanho mini
- **Tempo** (só Mini): Mostra o tempo decorrido e a duração da música no topo do tamanho mini
- **Largura** (só Mini): Quanto da largura da janela o cabeçalho do tamanho mini ocupa
- **Altura** (só Mini): Quanto da altura da janela o cabeçalho do tamanho mini ocupa; o texto e a capa acompanham

### Exibição da letra › Janela da letra › Capa

- **Capa animada** (só Completo): Só em alguns álbuns; pausa no Modo Pouca Energia ou com “Reduzir movimento” ativado
- **Cache de capas animadas** (só Completo): Espaço em disco usado pelas capas animadas baixadas; o que for limpo será baixado de novo na próxima exibição

### Atalhos de teclado

- **Deep links**: Abra-os pelo app Atalhos, Raycast, Alfred e ferramentas parecidas. Passe o cursor sobre um atalho acima para copiar o link dessa ação
- **Mostrar/ocultar letra flutuante**
- **Mostrar/ocultar letra no notch**
- **Espiar a letra no notch**
- **Alternar letra na barra de menus**
- **Expandir/recolher letra da Touch Bar**
- **Ocultar/restaurar todas as letras**
- **(Des)bloquear posição**
- **Mostrar/ocultar tradução**
- **Mostrar/ocultar pronúncia**
- **Aumentar tamanho da letra flutuante**
- **Diminuir tamanho da letra flutuante**
- **Abrir gerenciador de letras**
- **Abrir janela da letra**
- **Alternar tamanho mini/completo**
- **Buscar letra**
- **Abrir ajustes**
- **Ir para o player**
- **Abrir/fechar painel da barra de menus**
- **Adiantar letra**
- **Atrasar letra**
- **Zerar deslocamento**
- **Incremento**: Quanto muda a cada vez que você pressiona o atalho
- **Reproduzir/Pausar**
- **Faixa seguinte**
- **Faixa anterior**
- **Adicionar/remover dos favoritos**

### Geral › Barra de menus e Dock

- **Ícone da barra de menus**
- **Capa do álbum**
- **Tamanho do ícone**
- **Animar ícone**
- **Mostrar no Dock**

### Geral › Aparência e idioma

- **Aparência**: Cores dos Ajustes, da Janela da letra, do Gerenciador de letras e do painel da barra de menus
- **Idioma**

### Geral › Inicialização e notificações

- **Abrir ao iniciar sessão**
- **Início silencioso**
- **Notificar ao trocar de música**

### Geral › Rede

- **Proxy**

### Geral › Backup e migração

- **Backup do iCloud**
- **Arquivo de ajustes**: Inclui credenciais em texto simples. Exporta os ajustes e a biblioteca de letras em dois arquivos; importar substitui todos os ajustes
- **Apagar todos os ajustes**: Apaga só os ajustes deste Mac; backups e arquivos exportados são mantidos. Não pode ser desfeito

### Atualização de software

- **Atualização de software**

### Atualização de software › Ajustes de atualização

- **Verificar automaticamente**: Busca uma nova versão uma vez por dia
- **Baixar e instalar automaticamente**: Baixa em segundo plano e instala quando você encerra o Lyrimuse
- **Atualizações beta**: Versões de pré-lançamento; podem ser instáveis

### Sobre › Atualizações e ajuda

- **Comunicar problema**: Abre uma nova issue no GitHub já com sua versão, macOS e player preenchidos
- **Obter ajuda**: Pergunte na categoria Q&A do GitHub Discussions
- **Lista de recursos**: Todos os recursos, onde encontrá-los nos Ajustes e o estado padrão de cada um

### Sobre

- **Site**
- **Comunidade no Discord**: Converse com outros usuários, tire dúvidas ou sugira recursos
- **Grupo no Telegram**: Converse com outros usuários, tire dúvidas ou sugira recursos
- **Grupo do QQ**: Converse com outros usuários, tire dúvidas ou sugira recursos
- **Aviso de direitos autorais**
- **Licenças de terceiros**: Componentes e dicionários de código aberto
- **Licença de código aberto**: GPL-3.0

### Sobre › Diagnóstico e dados

- **Exportar diagnóstico**: Registros, relatórios de falhas e estado do app em um só arquivo, sem credenciais de contas. Nomes de músicas e caminhos locais continuam nele, então revise antes de publicar
- **Registro de atividade**: O registro bruto do motor de letras, para você mesmo investigar problemas
- **Pasta de dados**: Texto simples. Credenciais de contas, aparência e atalhos não são incluídos; para migrar tudo, use “Backup e migração”
- **Compartilhar dados de uso anônimos**: Ajuda a melhorar o Lyrimuse: versão, sistema, recursos usados e relatórios de falhas. Nunca títulos de músicas ou contas
- **Cache**: Capas e consultas que podem ser obtidas de novo

### Labs › ListenBrainz

- **Dados da conta**

### Last.fm › Regras

- **Regras de scrobble**
- **Modo de correspondência**: O artista e o título enviados ao Last.fm Inteligente: usa a grafia mais ouvida no Last.fm, ou envia como está quando não há correspondência. Álbuns perdem “ - Single” / “ - EP” Personalizado: defina título e artista separadamente Bruto: envia exatamente o que o player informa
- **Título**
- **Artista**
- **Momento do scrobble**
- **Scrobble de músicas com menos de 30 segundos**: Quando ativado, essas músicas fazem scrobble ao chegar à metade. As regras oficiais do Last.fm as ignoram
- **Players com scrobble**

### Labs › Push web

- **Dados da conexão**

### Alertas push

- **Canais**: Os relatórios de audição vão para todos os canais ativados. Com vários canais, escolha os de cada relatório em “Relatórios de audição” abaixo. Clique em uma linha para editar ou enviar um teste; clique com o botão direito para apagar
- **Horário de envio**
- **Relatórios de audição**
- **Origem dos dados**
- **Itens por lista**: Quantos artistas, álbuns e músicas principais listar
- **Resumo semanal de audição**
- **Relatório diário de audição**
- **Resumo de audição mensal**
- **Resumo de audição anual**
- **Histórico de envios**

### Discord

- **Mostrar no Discord**: Quando ativado, a música que você está ouvindo aparece no seu perfil do Discord e na lista de amigos. Se seus amigos não a virem, vá em Configurações de usuário › Privacidade de atividade no Discord e ative o compartilhamento de atividade
- **O que é mostrado**
- **Depois de “Ouvindo”**: O “××” de “Ouvindo ××” no seu perfil. O Discord no iOS e na web ignora isso e continua mostrando o player Com “Título” ou “Artista” aqui, “Abaixo do seu nome” não pode mostrar o player
- **Abaixo do seu nome**: O Discord só pode mostrar abaixo do seu nome a primeira linha, a segunda ou o que vem depois de “Ouvindo”. Se nem o título nem o artista estiverem em um desses lugares, essa opção fica indisponível
- **Selo na capa**
- **Ao pausar**
- **Informações da música**
- **Texto de status**
- **Capa e progresso**
- **Rotular artista e álbum**: Adiciona “de” antes do artista e “em” antes do álbum. Não é adicionado quando o título e o artista estão na mesma linha
- **Botões**
- **Botão personalizado**
- **“Ouvir no player”**: Abre a página desta música no site do player atual, igual a clicar no título. Fica oculto quando não há página
- **“Obter Lyrimuse”**
- **Privacidade**
- **Ocultar por um tempo**
- **Ocultar detalhes da música**: Mostra só o player que você usa e o progresso. O título, o artista, o álbum, a letra, os links e o botão “Ouvir no player” não são enviados
- **Mostrar barra de progresso**: Quando desativado, não há barra de progresso; o Discord mostra o tempo decorrido, que não pode ser desativado
- **Players mostrados**
