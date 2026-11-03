<div align="center">

<img src="docs/images/app-icon.png" width="120" alt="Ícone do Lyrimuse">

# Lyrimuse

**Letras na área de trabalho, reinventadas para o Mac.**

**Language / 语言 / 語言 / 言語 / 언어 / Idioma / Langue / Sprache / Lingua:** [English](README.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Italiano](README.it.md) | **Português (Brasil)**

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Architecture](https://img.shields.io/badge/arch-Apple%20Silicon%20%2B%20Intel-blue)
[![Latest release](https://img.shields.io/github/v/release/Yudaotor/lyrimuse)](https://github.com/Yudaotor/lyrimuse/releases/latest)
[![Last commit](https://img.shields.io/github/last-commit/Yudaotor/lyrimuse/dev)](https://github.com/Yudaotor/lyrimuse/commits/dev)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-ea4aaa?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/Yudaotor)
[![Discord](https://img.shields.io/badge/Discord-Join-5865F2?logo=discord&logoColor=white)](https://discord.gg/N7gVy66Gp3)
[![Telegram](https://img.shields.io/badge/Telegram-Join-26A5E4?logo=telegram&logoColor=white)](https://t.me/lyrimuse)
[![QQ](https://img.shields.io/badge/QQ-Join-1EBAFC?logo=qq&logoColor=white)](https://qm.qq.com/q/Nb4TlwfnQy)

</div>

https://github.com/user-attachments/assets/88b951ee-4ecf-4985-b1cb-eee6afdd5510

O Lyrimuse é um app de código aberto de letras na área de trabalho para macOS. Ele fica na barra de menus e destaca a letra palavra por palavra enquanto a música toca: flutuando sempre por cima das suas janelas, na barra de menus, numa cápsula no estilo Dynamic Island abaixo do notch, na Touch Bar ou numa janela da letra completa. Funciona com 14 players, entre eles Apple Music, Spotify, Amazon Music e o Kaset, app do YouTube Music, além de players web no navegador, e escolhe a melhor correspondência entre 15 fontes de letras, com tradução e romanização quando você quiser. Ele também mantém um perfil de audição no Last.fm e faz scrobble do que você ouve.

**Vindo do LyricsX?** Ele não tem versão nova desde abril de 2022. O Lyrimuse cobre o que ele fazia, continua recebendo atualizações e adiciona suporte a players chineses, KKBOX, Amazon Music, Kaset, reAMP, VOX, Pine Player, foobar2000 e players web. Para os detalhes, veja a [comparação com o LyricsX e o Lyric Fever](docs/lyrics-apps-comparison.md), com os fatos verificados.

**Instale** com o Homebrew, em Apple Silicon ou Intel. Ele também resolve para você o aviso do Gatekeeper na primeira abertura. Prefere baixar por conta própria? Pegue a [versão mais recente](https://github.com/Yudaotor/lyrimuse/releases/latest) e veja [Primeiros passos](#primeiros-passos).

```bash
brew tap yudaotor/lyrimuse
brew trust --cask yudaotor/lyrimuse/lyrimuse   # one-time: Homebrew asks you to trust non-official taps
brew install --cask lyrimuse
```

<img src="docs/images/hero-surfaces.jpg" alt="Formas de exibir a letra no Lyrimuse: janela da letra no estilo Apple Music, cápsula no estilo Dynamic Island, letra flutuante com destaque palavra por palavra, letra na barra de menus">
<p align="center"><sub>Quatro formas de mostrar a letra: a janela da letra, a cápsula no estilo Dynamic Island, a letra flutuante com destaque palavra por palavra e a barra de menus</sub></p>

<img src="docs/images/hero-engine.jpg" alt="Motor de letras do Lyrimuse: gerenciador de letras e painel de decisão de cada música, com a pontuação de cada resultado">
<p align="center"><sub>O gerenciador de letras, a busca manual com pontuação em cada resultado e o painel que mostra por que uma música ficou com a letra que tem</sub></p>

<img src="docs/images/hero-profile.jpg" alt="Perfil de audição do Lyrimuse: estatísticas do Last.fm, rankings, visão geral quando nada está tocando, mapa de calor anual de audição">
<p align="center"><sub>Seus números e paradas do Last.fm, a visão geral que aparece quando nada está tocando e um mapa de calor do seu ano no estilo do GitHub</sub></p>

<img src="docs/images/hero-customize.jpg" alt="Ajustes do Lyrimuse: editores com pré-visualização ao vivo, seletor de vários players com players web, letra na Touch Bar">
<p align="center"><sub>Cada página de ajustes tem pré-visualização ao vivo, você pode escolher mais de um player (players web também) e o menu da barra de menus tem o resto</sub></p>

## Recursos

> Onde cada recurso fica em Ajustes e se ele vem ativado ou desativado depois da instalação: veja a **[lista de recursos](docs/feature-list.pt-BR.md)**.

### Letra sincronizada palavra por palavra, encontrada automaticamente
- **Destaque palavra por palavra** que acompanha a música enquanto ela toca.
- **15 fontes de letras, consultadas para você**: NetEase Cloud Music, QQ Music, Kugou, Kuwo, Migu, Musixmatch, LRCLIB, LyricFind (pelo YouTube Music), Deezer, AMLL (um banco de dados de letras palavra por palavra revisado à mão), Soda Music (com sincronização palavra por palavra própria), VIBE e Genie (ambas fortes em músicas coreanas), PetitLyrics (forte em músicas japonesas) e as letras do Apple Music, se você conectar sua conta em Ajustes. As letras do Apple Music exigem assinatura, e muitas das músicas dele têm sincronização por palavra. Você nunca precisa buscar nada.
- **Tradução e romanização** abaixo da letra original. Se a fonte tiver uma tradução da comunidade, é ela que você recebe. Se não, ative “Tradução alternativa do sistema” em Ajustes (vem desativada por padrão) e o seu Mac traduz a letra com o framework Translation da Apple, sem que ela saia do computador; quando isso não é possível, um tradutor online entra em ação. São 17 idiomas de destino. A romanização é decidida linha por linha: uma música chinesa com uma linha em japonês ganha a leitura só nessa linha, não pinyin em todo o resto. Músicas em cantonês ganham um Jyutping que entende palavras inteiras. Para o japonês, você pode escolher furigana: hiragana só sobre os kanji, útil se você aprende japonês com músicas. Outros 18 idiomas, entre eles russo, tailandês, grego e híndi, também ganham leitura, seguindo a romanização oficial de cada idioma ou uma norma ISO.
- **Duetos separados por cantor.** Quando a fonte (ou uma entrada do AMLL) indica quem canta cada linha, cada parte aparece separada, em vez de duas vozes misturadas num só bloco.
- **Os toques do Apple Music na janela da letra**: vocais de apoio numa linha própria abaixo da principal, linhas de dueto sobrepostas acesas juntas até as duas terminarem, e palavras longas e sustentadas em inglês que crescem e brilham como no Apple Music.
- **Chinês simplificado ou tradicional** para a letra, definido separadamente do idioma do próprio app.
- **Gerenciador de letras**, para quando você quiser pôr ordem. Navegue, edite, apague ou busque de novo a letra de qualquer música, apague várias de uma vez e limpe as entradas vazias que anúncios e podcasts deixam para trás. Se a sincronização de uma música estiver errada, desloque só essa música. Um botão tenta de novo todas as músicas que ainda estão sem letra, e uma nova varredura completa escolhe outra vez a letra de toda a sua biblioteca com as regras de correspondência atuais. O que você corrigiu à mão não é alterado. Você também pode importar arquivos .lrc ou uma pasta inteira, mesmo de músicas que ainda não tocou, ou fazer o app monitorar uma pasta.
- **Uma música, uma letra.** A mesma música tocada em players diferentes ou de lançamentos diferentes é reconhecida como uma só: as entradas compartilham a letra e suas edições manuais, e as reproduções delas são somadas. “Entradas desta música”, no gerenciador de letras, compara as entradas linha por linha e separa uma que foi associada por engano.
- **Corrija a letra direto na janela da letra.** Busque outras letras, refaça a correspondência da música ou edite a letra no seu próprio editor de texto. Editar uma letra palavra por palavra muda só as palavras, então cada palavra mantém sua sincronização.
- **Funciona offline** para qualquer música cuja letra já esteja em cache.

### Perfil de audição do Last.fm e scrobble
- **Um perfil de audição completo.** Conecte o Last.fm com um clique na seção de contas (sem token para copiar e colar) e você tem os totais de hoje, dos últimos 7 dias e de sempre, um indicador ao vivo de “fazendo scrobble agora” e suas reproduções recentes com capas, cada uma com um coração para amar (ou deixar de amar) a música no Last.fm. Por padrão, cada reprodução é enviada como a música correspondente no catálogo do Last.fm, para que créditos de dueto, grafias simplificada / tradicional e finais como “ - Single” ou “(Remastered)” caiam na página certa da música; mude para “Bruto” em Ajustes para enviar exatamente o que o player informou. O ListenBrainz sempre recebe as tags originais ([como funciona o scrobble](docs/scrobbling.pt-BR.md)).
- **Artistas, álbuns e músicas mais ouvidos** dos últimos 7 dias, 30 dias, do ano ou de sempre, cada um mostrando quanto subiu ou desceu desde o período anterior. Clique num artista para ver as músicas dele que você mais ouve.
- **“Pegada”**, numa aba própria. Ela abre com seus totais acumulados: quantos dias se passaram desde o seu primeiro scrobble, em quantos deles houve reproduções e a média diária, o seu maior dia, a sua sequência atual e a mais longa, este ano até agora comparado ao mesmo período de um ano anterior, e quanto falta para o próximo marco redondo. Abaixo vêm um mapa de calor do ano no estilo do GitHub (clique num dia para ver o que você mais ouviu), quando você ouve por hora e dia da semana, de onde são os seus artistas mais ouvidos e “Neste dia”, com o que você ouviu nesta data em anos anteriores.
- **Toda reprodução é salva primeiro no seu Mac**, mesmo antes de você conectar o Last.fm. Conecte depois e envie com um clique as das últimas duas semanas, mais ou menos (o Last.fm não aceita reproduções mais antigas).
- **Você decide quando uma reprodução conta**: aos 50%, como o padrão do Last.fm, aos 75% ou 90%, ou só quando a música termina de verdade. O ListenBrainz não é afetado. Você também pode deixar um player totalmente fora do Last.fm, para que as reproduções dele nunca apareçam no seu histórico.
- **O mesmo histórico aparece na janela da letra** quando nada está tocando, então você vê uma visão geral em vez de uma tela vazia (mais sobre isso abaixo).

### Letra flutuante, letra na barra de menus, Dynamic Island, Touch Bar ou uma janela da letra completa
- **Use vários players ou deixe que ele escolha.** Apple Music, Spotify e Kaset são lidos com acesso de Automação. QQ Music, NetEase Cloud Music, Kugou Music, Soda Music, KKBOX, Amazon Music e LX Music são lidos pelo MediaRemote do macOS e não precisam de permissão. Ative qualquer combinação em Ajustes, ou deixe na detecção automática para seguir o que o macOS mostra em Reproduzindo.
- **O rádio do Apple Music também funciona.** A letra acompanha cada música de uma estação. Enquanto o apresentador fala, você vê o nome e o logotipo da estação, não a música anterior. O rádio tem um deslocamento de sincronização próprio, então você ajusta uma estação uma vez e esquece.
- **Os players no navegador também.** Pareie o navegador uma vez e o YouTube Music ou o Spotify Web funcionam como qualquer outro player, com a letra sincronizada à própria barra de progresso da página. Um teste de um clique diz de antemão se o navegador pode mesmo ser controlado. Durante um anúncio, a cápsula fica preta e mostra quanto falta e qual anúncio é, de quantos. Os anúncios do YouTube Music ganham um botão para pular, ou podem ser pulados automaticamente.
- **Escolha como quer ver a letra**, em qualquer combinação ou em nenhuma:
  - uma letra flutuante na área de trabalho que você arrasta para onde quiser, ou fixa no centro superior ou logo acima do Dock;
  - uma cápsula no estilo Dynamic Island no topo da tela, que pode mostrar a capa do álbum e desfocá-la atrás da cápsula, esmaecer a linha da letra para que os cliques passem por ela e aparecer na Tela Bloqueada, se você ativar isso;
  - a Touch Bar de um MacBook Pro que tenha uma, com a linha rolando conforme é cantada, além da capa do álbum e dos controles de reprodução, se você quiser;
  - uma janela da letra redimensionável inspirada na página de letras do Apple Music, com duas colunas, uma capa desfocada ao fundo, a música inteira rolando até a linha atual, capa animada quando o Apple Music tem uma capa em movimento para o disco, e o vídeo em loop do Spotify Canvas da música como fundo, quando houver. As palavras se preenchem conforme são cantadas, com o peso, a cor da parte cantada e o alinhamento que você escolher, e o “Destaque HDR” pode deixar a parte cantada mais brilhante que o branco numa tela HDR.
- **Letra na barra de menus (modo texto).** A linha atual fica direto na barra de menus. Linhas longas rolam em vez de serem cortadas no meio (dá para voltar a cortá-las). Uma segunda linha pode mostrar a próxima linha, a tradução ou a romanização, e a cápsula pode fazer o mesmo.
- **Arraste a barra de progresso para avançar ou voltar**, na janela da letra e na cápsula.
- **Aleatório, repetir, Favoritar e volume** direto na janela da letra, onde o player permitir: Apple Music, Spotify, Kaset, QQ Music, Amazon Music e YouTube Music no navegador aceitam alguns ou todos, e NetEase Cloud Music, Kugou Music, Soda Music e LX Music têm Favoritar. Favoritar também está na cápsula expandida e pode ter um atalho.
- **Abra a música onde ela está** pelo menu “⋯” ou pelo painel de informações. O Apple Music abre no app, o Spotify vai para a música que está tocando e o KKBOX abre a música, o álbum ou o artista no próprio app. QQ Music, Soda Music, Spotify, Amazon Music e YouTube Music (quando você toca no Kaset) abrem a página da música, do álbum ou do artista na web, e o NetEase Cloud Music abre a página da música. O Lyrimuse encontrou o link ao buscar a letra ou o leu dos dados do próprio player no seu Mac, então não há nada para buscar.
- **Quando nada está tocando**, a janela da letra mostra os totais de hoje e desta semana, um cartão “Neste dia” e suas reproduções recentes com capas, cada uma com link para a página do álbum ou do artista no Apple Music.
- **Uma minijanela da letra**: um cartão pequeno que mostra uma linha, duas linhas ou a letra inteira rolando, com fundo, cor do texto, fonte, peso e cor da parte cantada próprios; o karaokê palavra por palavra pode ser desativado só nela.
- **Letra na web no seu celular, tablet ou transmissão.** Abra a janela da letra num navegador em outro dispositivo e use-a como segunda tela, com controles de reprodução e toque para pular, se você permitir. A “Saída para OBS” coloca a letra flutuante na sua transmissão como uma fonte de navegador transparente. As duas ficam só neste Mac até você permitir o acesso pela rede local, e outros dispositivos se conectam lendo um código QR.
- **Notas de música, notas de álbum e biografias de artistas.** Clique no título, no artista ou no nome do álbum na janela da letra ou na cápsula expandida para ler sobre eles. As notas de álbum e as biografias de artistas vêm do Apple Music ou, quando ele não tem nada, do Soda Music (músicas tocadas no Soda Music, só com a interface em chinês), do Kugou Music (músicas tocadas no Kugou Music, só com a interface em chinês), do NetEase Cloud Music (só com a interface em chinês), dos artigos da Wikipédia que o YouTube Music mostra (no idioma da interface) ou do Last.fm; as notas de música vêm do QQ Music (só com a interface em chinês) ou do Last.fm.
- **Deixe do jeito que você gosta**: a fonte (a do sistema ou seus próprios arquivos .ttf / .otf), o tamanho, as cores do texto / fundo / sombra, temas salvos ou uma cor tirada da capa do álbum atual, e a largura da letra flutuante, além de uma cor de letra arco-íris em movimento.
- **Oculta em capturas de tela, gravações e compartilhamentos de tela.** Você continua vendo. Ninguém mais vê.
- **Some quando você pausa**, para não ficar na área de trabalho sem fazer nada. Também pode sair do caminho em trechos instrumentais, músicas sem letra e apps em tela cheia, e a letra flutuante pode acompanhar você até a tela da janela que você está usando.

### Detalhes do dia a dia
- **Inglês, chinês simplificado, chinês tradicional, japonês, coreano, espanhol, francês, alemão, italiano e português do Brasil**, e a troca vale na hora, sem reiniciar. Achou uma tradução desajeitada? Pull requests são bem-vindos; cada idioma tem um guia de estilo em `lyrimuse/Localization/`.
- **Liquid Glass no macOS 26.** Os ajustes, o painel da barra de menus, a janela da letra, o gerenciador de letras e o guia de configuração usam esse visual, e a maioria deles pode ficar sempre clara ou escura em vez de seguir o sistema.
- **Atalhos de teclado** para todas as ações, de ocultar todas as letras a curtir a música. Nenhum vem definido de fábrica, então você escolhe as teclas. Cada ação também tem um link `lyrimuse://` que você pode chamar no Atalhos, no Raycast ou no Alfred, e no Atalhos um link pode devolver a música que está tocando ([esquema de URL](docs/url-scheme.pt-BR.md)).
- **Busca nos ajustes.** Digite na barra lateral e ela rola até a linha correspondente e a destaca, abrindo um grupo recolhido se precisar.
- **Atualiza sozinho.** Ele verifica por conta própria ou quando você pede pela barra de menus. As atualizações são instaladas pela página “Atualização de software” em Ajustes, com as notas da versão e o progresso ali mesmo, e você pode optar por receber versões beta.
- **Abra junto com seus players**, definido por player e nos dois sentidos: abrir os players quando o Lyrimuse abre, abrir o Lyrimuse quando eles abrem e, se quiser, encerrar o Lyrimuse quando todos os players que ele acompanha forem encerrados.
- **Início silencioso**, se você preferir que ele abra sem nenhuma janela, só com o ícone na barra de menus.
- **Vai trocar de Mac?** Exporte toda a sua configuração e importe-a lá. Se algo der errado, também há uma exportação de diagnóstico com um clique.

### Extras opcionais

<details>
<summary>ListenBrainz, status no Discord, uma página “reproduzindo agora” para compartilhar e resumos diários / semanais / mensais / anuais</summary>

Tudo isso fica desativado até você ativar em Ajustes:

- **Faça scrobble também no [ListenBrainz](https://listenbrainz.org).** Cada reprodução vai para os dois serviços a partir da mesma leitura do seu player, então os dois históricos ficam em sincronia. As reproduções do seu iPhone (registradas pelo Last.fm) também são copiadas para o ListenBrainz, e você fica com um só histórico dos dois dispositivos em vez de dois.
- **Uma página pública “reproduzindo agora” para compartilhar**: reprodução ao vivo, histórico, livro de visitas, reações, contador de visitantes, um quadro com os 10 artistas mais ouvidos, um visual de disco de vinil, temas claro e escuro e prévias de link corretas em apps de mensagem. O **[guia dos recursos web](https://github.com/Yudaotor/nowplaying-workers#readme)** mostra tudo com capturas de tela.
- **Resumos de audição diários, semanais, mensais e anuais**, enviados para quantos canais você quiser: Bark, ntfy, ServerChan, Feishu, DingTalk, WeCom, Telegram, Discord, Slack ou um webhook genérico. Cada canal pode enviar um teste, e um histórico de entregas mostra o que chegou.
- **Mostre no Discord o que você está ouvindo.** Seu perfil e sua lista de amigos mostram o player que você está usando, a música, o artista, a capa do álbum e uma barra de progresso, e o título da música e o artista levam às páginas deles no site desse player. A linha do álbum pode mostrar a linha que está sendo cantada, e você pode adicionar até dois botões. Um pequeno selo do Lyrimuse ou do player fica no canto da capa (ou nenhum), e uma música pausada pode continuar visível com um ícone de pausa. Você escolhe quais players contam, pode mostrar só o player sem dizer qual é a música e pode ocultar o status por um tempo.

O ListenBrainz e o “Push web” ficam em **Labs** na barra lateral dos ajustes, os “Alertas push” ficam junto com as outras seções e o Discord tem uma entrada própria perto do topo. Cada cartão traz seus próprios passos de configuração: onde obter uma chave de API ou um token, como conectar uma conta, como obter uma URL de webhook para o seu serviço de push. A página web é a única com um guia separado, e você não precisa dele inteiro. Só com o ListenBrainz configurado, a página já mostra a reprodução ao vivo e o histórico, sem precisar de um Cloudflare Worker. Implante um se também quiser o livro de visitas, as reações, o contador de visitantes, o quadro dos 10 mais e atualizações mais rápidas; o guia explica como.

</details>

## Primeiros passos

As versões são assinadas com o certificado do próprio projeto, não com um Apple Developer ID, então nenhuma das opções abaixo envolve uma conta Apple Developer. O porém é que, na primeira vez que você abrir o app, o Gatekeeper avisa que ele “procede de um desenvolvedor não identificado”. O Homebrew (opção A) resolve isso para você. Nas outras opções isso é esperado, não é um bug, e a opção B mostra como passar por esse aviso uma única vez.
### Opção 0: Deixe uma IA fazer a instalação

Usa um agente de IA que consegue usar o Terminal no seu Mac (Claude Code, Codex CLI, Gemini CLI, …)? Cole nele o bloco abaixo do jeito que está, e ele faz tudo o que está nas opções A/B por você. As instruções só o deixam instalar este app. Ele não vai usar `sudo` nem mexer nos ajustes de segurança do sistema inteiro:

```text
Please install Lyrimuse — an open-source macOS menu-bar lyrics app
(https://github.com/Yudaotor/lyrimuse) — on this Mac, following these rules exactly:

1. Preferred path (if `brew` exists):
     brew tap yudaotor/lyrimuse
     brew trust --cask yudaotor/lyrimuse/lyrimuse
     brew install --cask lyrimuse
   If this Homebrew doesn't know the `trust` subcommand, skip that line — older
   versions don't need it.
2. If Homebrew is not installed, do NOT install Homebrew. Instead: check the CPU
   with `uname -m`, download the latest release asset from
   https://github.com/Yudaotor/lyrimuse/releases — `Lyrimuse-v<version>-macos.zip`
   for arm64, `Lyrimuse-v<version>-macos-intel.zip` for x86_64 — verify it against
   its `.sha256` file (`shasum -c`), unzip, move `Lyrimuse.app` into
   /Applications, then clear the Gatekeeper quarantine flag on that one app only:
     xattr -dr com.apple.quarantine /Applications/Lyrimuse.app
3. Safety rails: no `sudo` anywhere (nothing here needs it); never run
   `spctl --master-disable` or otherwise weaken Gatekeeper system-wide; never
   remove the quarantine flag from anything except /Applications/Lyrimuse.app.
4. Do not build from source unless I explicitly ask.
5. Launch it (`open -a Lyrimuse`) and verify it is running (`pgrep -x Lyrimuse`
   prints a PID).
6. A first-run wizard will appear — that part is mine to click through. Tell me
   it will ask me to pick a music player, to grant Automation access to
   Music.app and/or Spotify (only if I pick them), and to enable the background
   lyrics engine — then hand control back to me.
Finally, report what you did and anything that failed.
```

### Opção A: Instalar com o Homebrew (recomendado)

```bash
brew tap yudaotor/lyrimuse
brew trust --cask yudaotor/lyrimuse/lyrimuse   # one-time: Homebrew asks you to trust non-official taps
brew install --cask lyrimuse
```

A instalação já remove automaticamente a quarentena do Gatekeeper, que só existe na primeira vez, então não há passo seguinte. Abra o Lyrimuse em `/Applications` (ou pelo Spotlight) assim que o `brew install` terminar. `brew upgrade --cask lyrimuse` instala as novas versões do mesmo jeito.

### Opção B: Baixar manualmente uma versão pronta

1. Baixe na [página de Releases](https://github.com/Yudaotor/lyrimuse/releases). **Confira primeiro qual Mac você tem** ( → Sobre Este Mac → “Chip”: `Apple M…` é Apple Silicon, `Intel Core…` é Intel):

   | Seu Mac | Download |
   | --- | --- |
   | Apple Silicon (M1 ou posterior) | `Lyrimuse-*-macos.dmg` ou `.zip` |
   | Intel | `Lyrimuse-*-macos-intel.dmg` ou `.zip` |

   Com o dmg, clique duas vezes para montar e arraste `Lyrimuse.app` para o atalho `Applications` ao lado; com o zip, descompacte e arraste `Lyrimuse.app` para `/Applications`. Os dois formatos instalam exatamente o mesmo app, e o zip vem com um `.sha256`, se você quiser verificar o download (`shasum -c Lyrimuse-*.zip.sha256` na mesma pasta).

   A única diferença entre os dois downloads é a arquitetura: o sem sufixo é só para Apple Silicon, enquanto o `-intel` traz código para Intel e para Apple Silicon. O `-intel` roda em Apple Silicon, mas não há motivo para usá-lo nesses Macs: ele tem o dobro do tamanho, e o macOS 27 e posteriores vão avisar que o app “precisa ser atualizado” porque contém código Intel (a Apple vai remover o Rosetta no macOS 28; não há nada de errado com o app).

   **As duas arquiteturas recebem atualizações automáticas no app.** O feed lista duas entradas para a mesma versão, uma por arquitetura: o Apple Silicon recebe a versão sem sufixo, o Intel recebe a `-intel`, e o Sparkle escolhe sozinho em cada máquina. (A v1.4.0 e anteriores atendiam só Apple Silicon; quem usava Intel tinha que voltar aqui manualmente.)
2. Na primeira abertura, o macOS vai se recusar a abrir o app, com “A Apple não pôde verificar se o Lyrimuse está livre de malware” ou “procede de um desenvolvedor não identificado”. Libere uma vez, do jeito que preferir:

   - **Terminal (recomendado, sempre funciona):**
     ```bash
     xattr -dr com.apple.quarantine /Applications/Lyrimuse.app
     ```
     Depois abra o app normalmente. Você só precisa fazer isso uma vez por download.
   - **Clique com o botão direito → Abrir:** No Finder, clique com o botão direito (ou com a tecla Control pressionada) em `Lyrimuse.app` e escolha **Abrir**, depois confirme **Abrir** de novo na caixa de diálogo. Isso não funciona em todas as versões do macOS para todo tipo de aviso; então, se o aviso continuar, use o comando do Terminal acima.
   - **Ajustes do Sistema → Privacidade e Segurança:** Tente abrir o app uma vez (ele vai ser bloqueado), depois abra **Ajustes do Sistema → Privacidade e Segurança**, role até o fim e clique em **Abrir Mesmo Assim** ao lado do aviso do Lyrimuse. Confirme mais uma vez, se for pedido.

   Faça isso só com uma versão em que você realmente confia: a da página de Releases deste repositório ou uma que você mesmo compilou.

### Opção C: Compilar a partir do código-fonte

**Pré-requisitos, só uma vez** (pule o que você já tiver):

```bash
xcode-select --install   # Xcode Command Line Tools, for Swift — skip if `swift --version` already works
brew install go          # any Go ≥ 1.21 — build.sh switches to 1.24.4 automatically via GOTOOLCHAIN
```

Depois, o `build.sh` compila o app e o motor de letras dele (o processo em segundo plano chamado `lyrimuse-engine`) de uma vez só:

```bash
git clone https://github.com/Yudaotor/lyrimuse.git
cd lyrimuse/lyrimuse
./build.sh              # this machine's architecture
./build.sh --universal  # arm64 + x86_64 (the compatibility build shipped for Intel)
```

O `build.sh` termina listando as arquiteturas de cada binário do pacote e aponta tudo o que não bate com o alvo, seja uma fatia faltando ou uma a mais. Não monte os arquivos da versão à mão: `./package.sh` compila cada arquitetura uma vez e gera zip + sha256 + dmg para cada uma, recusando-se a empacotar se as arquiteturas estiverem erradas.

O suporte a QQ Music / NetEase Cloud Music / Kugou Music / Soda Music / KKBOX / Amazon Music / LX Music / Spotify / Kaset / detecção automática também precisa do [ungive/media-control](https://github.com/ungive/media-control). O `build.sh` o instala via Homebrew automaticamente se estiver faltando, então esse também não é um passo que você precise fazer.

### Depois de qualquer opção

Abra o Lyrimuse em `/Applications`. O assistente da primeira execução guia você para escolher um player (Apple Music, QQ Music, NetEase Cloud Music, Kugou Music, Soda Music, KKBOX, Amazon Music, Spotify, Kaset, reAMP, VOX, Pine Player, foobar2000, LX Music ou detecção automática), conceder acesso de Automação se você escolheu Apple Music, Spotify, Kaset ou VOX (os outros não precisam de permissão para ler as informações básicas da música) e ativar o motor de letras (para que letras e capas continuem sendo resolvidas mesmo com a janela fechada). Conclua o assistente e a letra aparece na hora (veja [lyrimuse/README.md](lyrimuse/README.md) para mais opções de compilação).

Isso é tudo de que você precisa para ter a letra. Os extras opcionais podem ser configurados depois em Ajustes, quando você quiser.

## Perguntas frequentes

### Como ter a letra do Apple Music flutuando na área de trabalho do Mac, sempre por cima?
Ative a letra flutuante em Ajustes. Ela fica acima de todas as janelas, em todos os Spaces. Arraste-a para onde quiser, ou fixe-a no centro superior ou logo acima do Dock. Se a letra tiver sincronização por palavra, cada palavra se preenche conforme é cantada. Você pode ocultá-la de capturas de tela, gravações e compartilhamentos de tela, e fazê-la sumir enquanto a música está pausada. Funciona do mesmo jeito com QQ Music, NetEase Cloud Music, Kugou Music, Soda Music, KKBOX, Amazon Music, LX Music, Spotify, Kaset e players web.

### Dá para mostrar a letra do Spotify na barra de menus do Mac?
Sim. Ative o modo texto da barra de menus e a linha atual aparece na barra de menus, com o Spotify ou qualquer outro player compatível. Linhas longas rolam em vez de serem cortadas, e uma segunda linha pode mostrar a próxima linha, a tradução ou a romanização. Você não precisa conectar uma conta do Spotify. O Lyrimuse pede uma vez acesso de Automação ao Spotify, o que lhe dá a posição exata da reprodução e faz os botões de reprodução funcionarem. Se você recusar, a letra continua aparecendo, mas a sincronização vem do MediaRemote do macOS e pode ficar cerca de um segundo defasada.

### Mostra letra palavra por palavra com QQ Music, NetEase Cloud Music, Kugou ou Soda Music?
Sim, desde que a letra tenha sincronização por palavra. NetEase Cloud Music, QQ Music, Kugou, Soda Music, Musixmatch, AMLL e Apple Music muitas vezes têm, e essas linhas se preenchem palavra por palavra. Letras só com sincronização por linha acendem a linha inteira de uma vez. O player também não limita de onde vem a letra: uma música tocando no Soda Music pode acabar com a letra palavra por palavra do QQ Music, se ela tiver a melhor pontuação.

### Preciso de uma conta Apple Developer para instalar?
Não. As versões são assinadas com o certificado do próprio projeto em vez de um Apple Developer ID, então nem você nem o projeto precisam de uma. É também por isso que existe um passo único do Gatekeeper, descrito em Primeiros passos, acima.

### O Lyrimuse está na Mac App Store?
Não. Instale com o Homebrew (opção A acima) ou baixe na [página de Releases](https://github.com/Yudaotor/lyrimuse/releases) (opção B). De um jeito ou de outro, depois disso as atualizações chegam pelo próprio app.

### O Lyrimuse é gratuito?
Sim. É código aberto, sob a GPL-3.0. Não há versão paga, compra dentro do app nem conta para criar. Usar o Last.fm e os outros serviços fica a seu critério. Se ele for útil para você e você quiser apoiar, pode [patrocinar no GitHub](https://github.com/sponsors/Yudaotor) ou [pagar um café para o autor](https://yudaotor.github.io/donate/) com Alipay ou WeChat Pay.

### Dá para controlar o QQ Music, o NetEase Cloud Music ou o Soda Music quando outro app está com o foco de mídia do sistema?
Sim. Quando algo como um vídeo no navegador ocupa o Reproduzindo do macOS, as teclas de mídia do sistema vão para ele; o Lyrimuse então aciona reproduzir/pausar, anterior e próxima na própria barra de menus do QQ Music ou do NetEase Cloud Music, ou na barra de reprodução do Soda Music, deixando o player em segundo plano. Isso precisa de acesso de Acessibilidade (Ajustes → Player); sem ele, esses botões abrem essa página. Não dá para avançar ou voltar na música nesse estado. No macOS 27, a permissão fica em **Ajustes do Sistema → Privacidade e Segurança → Controle do Dispositivo e Acesso a Dados**; versões anteriores a chamam de **Acessibilidade**.

### Funciona com Spotify, QQ Music ou NetEase Cloud Music, ou só com Apple Music?
Com todos esses, mais Kugou Music, Soda Music, KKBOX, Amazon Music, Kaset (um app de YouTube Music), o player reAMP no estilo Winamp, o player local VOX para áudio lossless e hi-res, o player local gratuito Pine Player, que toca quase qualquer formato, o clássico player local foobar2000, portado do Windows, e o LX Music, de código aberto: 14 players no total. Ou deixe que ele detecte automaticamente o que o macOS mostra em Reproduzindo. Apple Music, Spotify, Kaset e VOX pedem acesso de Automação (Spotify, Kaset e VOX o usam para a sincronização exata e para os botões de reprodução). Os outros 10 não precisam de permissão para ler as informações básicas da música pelo MediaRemote do macOS; os botões de aleatório, repetir e curtir do QQ Music, NetEase Cloud Music, Kugou Music, Soda Music e Amazon Music, e o aleatório, a repetição e o volume do reAMP e do foobar2000, precisam de acesso de Acessibilidade; o Pine Player o usa para ler a barra de progresso, já que informa a posição só em segundos inteiros. Com KKBOX, Amazon Music ou LX Music, a letra que o app já salvou para a música também é considerada, e nenhum deles é contatado.

### Dá para mostrar a letra do KKBOX ou do Amazon Music no Mac?
Sim. Os dois são lidos pelo MediaRemote do macOS, então não há nada para autorizar, e a letra deles aparece na letra flutuante, na barra de menus, na cápsula e na janela da letra como a de qualquer outro player. Se o KKBOX ou o Amazon Music já tiverem salvo a letra da música, ela também é considerada e ganha peso extra. O Lyrimuse nunca faz login em nenhum dos dois serviços nem envia nada a eles. As outras fontes continuam sendo consultadas, então, se uma delas tiver algo melhor, como sincronização palavra por palavra, ela vence.


### Funciona com o LX Music (洛雪音乐)?
Sim. O LX Music é lido pelo MediaRemote do macOS, então não há nada para autorizar. Quando você toca uma música no LX Music, a letra que ele salvou para ela (palavra por palavra, quando a plataforma tem) também é considerada e ganha peso extra, e as próximas músicas da lista que você está tocando têm a letra preparada com antecedência. O Lyrimuse só lê os dados do LX Music no seu Mac e nunca envia nada a ele.

### Funciona com um app de YouTube Music para desktop?
Sim, com o [Kaset](https://github.com/sozercan/kaset), um app de YouTube Music nativo e de código aberto para Mac. O Kaset é lido com acesso de Automação, o que dá sincronização exata e botões de reprodução que funcionam, e a própria letra do YouTube Music está entre os resultados. O YouTube Music no navegador também funciona; veja abaixo.

### Como é a letra na área de trabalho?
Como um karaokê na sua área de trabalho. A linha atual flutua sobre as janelas, cada palavra se preenche conforme é cantada quando a letra tem sincronização por palavra, e a tradução ou a romanização pode ficar junto. Você pode mudar a fonte, o tamanho, as cores do texto, do fundo e da sombra e a largura, e fazer a cor do texto seguir a capa do álbum. A mesma letra também pode ir para a barra de menus, para uma cápsula no estilo Dynamic Island abaixo do notch ou para uma janela da letra completa no estilo Apple Music, em qualquer combinação.

### A cápsula Dynamic Island funciona num Mac sem notch?
Sim. Numa tela sem notch, como um MacBook mais antigo ou um monitor externo, a cápsula fica no centro superior, com a altura da barra de menus. Você escolhe em qual tela ela aparece em Ajustes.

### A letra funciona sem conexão com a internet?
Sim, para qualquer música cuja letra ele já tenha encontrado, já que ela fica em cache no seu Mac. A primeira busca de uma música precisa de conexão, assim como a tradução online.

### Algum dado meu sai do Mac?
Para encontrar a letra, ele precisa perguntar às fontes de letras sobre a música que está tocando: NetEase, QQ, Kugou, Kuwo, Migu, Musixmatch, LRCLIB, LyricFind, Deezer, AMLL, Soda Music, VIBE, Genie, PetitLyrics e Apple Music, se você o conectou. As capas vêm da iTunes Search API. Por padrão, a tradução acontece no seu Mac, e o texto da letra só vai para um tradutor online (a tradução web do Google e depois o MyMemory) como alternativa. Seu histórico de reprodução, as letras em cache e os ajustes ficam em arquivos no seu Mac, a não ser que você conecte o Last.fm, o ListenBrainz ou o relay web opcional. Dados de uso anônimos (versões, quais recursos estão ativados, resumos de falhas; nunca títulos de músicas nem contas) são enviados uma vez por dia por padrão, e você pode desativá-los em Ajustes › Sobre. A lista completa está mais abaixo, em [Licença e direitos autorais](#licença-e-direitos-autorais).

### Dá para ter romanização de japonês/coreano ou tradução da letra para chinês?
Sim. A romanização é decidida linha por linha, então uma música que mistura idiomas só ganha leitura onde ela faz sentido. O japonês pode mostrar romaji ou furigana (hiragana sobre os kanji). A tradução vem da tradução da comunidade da fonte de letras, quando há uma; se não houver, vem da tradução automática no dispositivo ou online, depois que você ativa “Tradução alternativa do sistema” (desativada por padrão), para qualquer um de 17 idiomas.

### Quais versões do macOS são compatíveis?
macOS 14 Sonoma ou posterior (Sequoia, Tahoe e mais recentes), em Apple Silicon ou Intel. Traduzir no seu Mac exige o macOS 15 Sequoia ou posterior; no macOS 14, só os tradutores online estão disponíveis.

### Funciona em Macs com Intel?
Sim, com uma versão universal separada (veja a opção B acima). As atualizações automáticas também funcionam em Intel desde a v1.5.0, então as novas versões aparecem do mesmo jeito que em Apple Silicon.

### Dá para mostrar a letra do YouTube Music ou do Spotify tocando num navegador?
Sim. Pareie o navegador uma vez em Ajustes e o YouTube Music ou o Spotify Web funcionam como qualquer outro player. A letra segue a própria barra de progresso da página em vez de adivinhar, e um teste de um clique diz, antes de você se decidir, se o seu navegador pode ser controlado.

### Dá para fazer scrobble do Apple Music no Last.fm num Mac?
Sim, essa é a outra metade do app. Conecte o Last.fm com um clique em Ajustes e toda reprodução do Apple Music (ou de qualquer outro player compatível) recebe scrobble, com um status “reproduzindo agora” ao vivo. As reproduções são salvas primeiro no seu Mac, então as de antes da conexão não se perdem: depois de conectar, clique em “Enviar pendentes” para enviar as das últimas duas semanas, mais ou menos. Você escolhe quando uma reprodução conta (50%, 75%, 90% ou a música inteira), pode deixar alguns players de fora e pode enviar para o ListenBrainz ao mesmo tempo.

### Como o Lyrimuse evita escolher a letra errada?
Ele não pega simplesmente a primeira fonte que responde. Todos os resultados de todas as fontes recebem pontuação do mesmo jeito: o quanto título, artista, álbum e duração batem, mais coisas como ter ou não sincronização por palavra. A maior pontuação vence. Você pode ver essa decisão para qualquer música, com a pontuação de cada resultado e o motivo de o vencedor ter vencido. Se uma correspondência melhor aparecer depois, o Lyrimuse pode trocar sozinho, mas a letra que você escolheu à mão fica bloqueada e nunca é substituída. A busca manual mostra as mesmas pontuações e rótulos, então é fácil identificar uma versão errada antes de escolher.

### E se a letra estiver fora de sincronia ou errada?
Se a sincronização estiver errada, desloque-a para essa música; o deslocamento fica salvo. Se for a letra errada ou a versão errada, abra a busca manual. Você vai ver todos os resultados de todas as fontes com a pontuação de cada um, e o que você escolher fica bloqueado, então a correspondência automática não vai trocá-lo. Você também pode editar à mão a letra de qualquer música no gerenciador de letras.

### Dá para salvar a letra como arquivos .lrc?
Ela já é salva assim. Toda música com letra ganha um arquivo `.lrc` com sincronização por linha, mais `.tr.lrc` para a tradução e `.roma.lrc` para a romanização, quando existem. A sincronização palavra por palavra é salva à parte, em TTML por padrão. Em Ajustes, você pode trocar para `.yrc` (o formato YRC do NetEase), Enhanced LRC, QRC ou KRC, para que outros players consigam ler, e manter mais de um. Os arquivos ficam em `~/Library/Application Support/me.yudaotor.lyrimuse/lyrics/`, e você pode mover a pasta em Ajustes.

### O LyricsX ainda é mantido, e em que o Lyrimuse difere do LyricsX ou do Lyric Fever?
A última versão do LyricsX foi a v1.6.3, em abril de 2022. Ele roda no macOS 10.11 ou posterior e funciona com Apple Music, Spotify e alguns players mais antigos. O Lyric Fever se concentra no Spotify e no Apple Music e exige o macOS 15. O Lyrimuse exige o macOS 14 e adiciona QQ Music, NetEase Cloud Music, Kugou, Soda Music, KKBOX, Amazon Music, Kaset, reAMP, VOX, Pine Player, foobar2000 e LX Music, players no navegador, pinyin / Jyutping cantonês / romanização de japonês e coreano por linha, mais leitura para outros 18 idiomas, como russo e tailandês, e scrobble no Last.fm / ListenBrainz com suas próprias estatísticas de audição. A tabela lado a lado está na [página de comparação](docs/lyrics-apps-comparison.md).
## Licença e direitos autorais

- **O Lyrimuse em si é [GPL-3.0](LICENSE).** Os componentes de código aberto e os dados de dicionário incluídos no app (media-control, Sparkle, KeyboardShortcuts e os dicionários OpenCC e rime-cantonese) mantêm suas próprias licenças; os textos completos estão em [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES), que também vem dentro do app e pode ser aberto em **Ajustes → Sobre → Licenças de terceiros**.
- **Letras, capas e metadados das músicas pertencem aos respectivos titulares de direitos.** O Lyrimuse só os consulta, guarda em cache e exibe: o que as APIs públicas de letras retornam fica armazenado no seu próprio Mac (`~/Library/Application Support/me.yudaotor.lyrimuse/`) para você ver. Ele não hospeda, retransmite nem redistribui letras ou capas, e o cache pode ser apagado a qualquer momento pelo gerenciador de letras ou removendo essa pasta.
- **O Lyrimuse é um projeto de código aberto independente.** Não é afiliado, endossado nem ligado a Apple, Tencent (QQ Music), NetEase (NetEase Cloud Music), Kugou, Kuwo, Douyin (Soda Music), KKBOX, Amazon (Amazon Music), China Mobile (Migu Music), Spotify, Kaset, LX Music, Google (YouTube Music, Google Translate), Last.fm, ListenBrainz, MusicBrainz, Musixmatch, LRCLIB, LyricFind, Deezer, Naver (VIBE), KT (Genie), SyncPower (PetitLyrics), AMLL ou SponsorBlock. Os nomes e as marcas deles pertencem aos respectivos donos e aparecem aqui só para dizer quais players, fontes de letras e serviços estão envolvidos.
- **Isto é tudo o que sai do seu Mac.** A resolução de letras envia o artista, o título e o álbum da música (mais a duração, para as fontes que a aceitam) às 15 fontes de letras acima; quando nenhuma delas corresponde, o nome do artista também é enviado ao MusicBrainz para buscar nomes alternativos (a correspondência “Inteligente” do Last.fm faz o mesmo com artistas que ainda não viu), e as Paradas consultam ali os seus artistas pelo ID do MusicBrainz para obter país/região e links. A capa e a visão geral de quando nada está tocando enviam artista + título à iTunes Search API; com o Kaset, a capa que ele informa é baixada do servidor de imagens do YouTube Music (googleusercontent.com), e cada ID de vídeo novo que ele toca é enviado uma vez ao YouTube Music para verificar se é um episódio de podcast (esses não são tratados como músicas). Com a Open API do LX Music ativada, o Lyrimuse só se comunica com a porta do próprio LX Music neste Mac e, quando o sistema não tem capa para a música, baixa uma vez a que o LX Music indicar. As notas de álbum e as biografias de artistas solicitam as páginas públicas do álbum e do artista no Apple Music pelos IDs do Apple Music, sem envolver nenhuma conta Apple; quando a interface está em chinês e o Apple Music não tem biografia do artista nem notas do álbum, o ID da música no NetEase Cloud Music é usado para consultar os artistas creditados e o álbum dela, e então a apresentação desse artista ou álbum no NetEase é obtida pelo ID, também sem login. Com a interface em chinês, as notas de música também solicitam ao QQ Music os detalhes da música pelo ID dela no QQ Music, igualmente sem login. Enquanto o QQ Music está tocando, os mesmos detalhes são solicitados uma vez por música, em qualquer idioma da interface, para distinguir audiolivros e outros programas falados de músicas (as legendas deles continuam aparecendo, mas eles não recebem scrobble nem são mostrados como música). Quando o Apple Music não tem capa animada para o álbum, o ID do álbum no QQ Music é enviado ao QQ Music para verificar se há uma capa animada; se houver, o endereço do vídeo é solicitado pelo ID do vídeo no QQ Music enquanto a janela da letra está aberta, e o vídeo é baixado do servidor de vídeo do QQ Music (tencentmusic.com), sem login. Se o QQ Music também não tiver, o ID da música no NetEase Cloud Music é enviado ao NetEase para verificar se há uma, com a identidade anônima de convidado que o NetEase dá a visitantes sem conta; o vídeo vem do servidor de vídeo do NetEase (126.net). Enquanto o Kugou está tocando, o artista e o título vão uma vez para a busca web do Kugou para encontrar a página da música, sem login. O fundo Spotify Canvas da janela da letra só lê o cache que o Spotify mantém no seu Mac e não pede nada ao Spotify; um vídeo encontrado ali é baixado uma vez da CDN do Spotify (canvaz.scdn.co), enviando só o endereço do vídeo. As notas de álbum e as biografias de artistas também podem buscar o álbum no YouTube Music por artista e nome do álbum (músicas tocadas no Kaset ou no YouTube Music na web usam os IDs de álbum e de artista que o player informa) e obter a descrição da Wikipédia nas páginas do álbum e do artista; para músicas tocadas no Soda Music, as páginas públicas de compartilhamento do álbum e do artista são solicitadas pelos IDs que o Soda Music informa. Nenhum dos dois precisa de conta. Com a interface em chinês, para músicas que o LX Music toca a partir do Kuwo, o ID da música no Kuwo é enviado ao Kuwo para consultar os IDs do álbum e do artista, e as apresentações do álbum e do artista são então solicitadas por esses IDs, também sem login. Para músicas tocadas no Kugou Music, o motor pergunta uma vez ao Kugou a qual álbum pertence o arquivo em reprodução; com a interface em chinês, a apresentação do álbum no Kugou é então solicitada por esse ID de álbum, e a do artista pelo ID do artista do álbum, também sem login. A tradução automática alternativa (desativada por padrão e usada só quando a tradução da Apple no dispositivo não está disponível) envia o **próprio texto da letra**, em partes, primeiro ao endpoint de tradução web do Google, e o que ainda ficar sem tradução ao MyMemory; a solicitação ao MyMemory leva um parâmetro de e-mail gerado aleatoriamente, nunca o seu. Enquanto um videoclipe toca no YouTube Music, os quatro primeiros caracteres do hash SHA-256 do ID do vídeo vão para o SponsorBlock para encontrar os trechos sem música do vídeo, para que a letra fique alinhada com a imagem; com isso, o SponsorBlock não consegue saber qual é o vídeo. O domínio do Musixmatch é resolvido por DNS sobre HTTPS via Cloudflare (1.1.1.1) e Google (8.8.8.8). A página “Sobre” pede à API do GitHub o número de estrelas no máximo uma vez a cada seis horas e, se você optar por atualizações beta, a lista de versões no máximo uma vez por hora; as verificações de atualização baixam o appcast do GitHub Releases e não enviam nenhum perfil do sistema. “Compartilhar dados de uso anônimos” vem ativado por padrão (Ajustes › Sobre › Diagnóstico e dados; a tela de boas-vindas na primeira abertura tem a mesma opção). No máximo uma vez por dia, ele envia ao servidor do próprio autor (telemetry.yudaotor.me, um Cloudflare Worker) um ID de instalação aleatório gerado no seu Mac, as versões do Lyrimuse e do macOS, o chip, os idiomas da interface e do sistema, quais recursos estão ativados (superfícies de exibição, players selecionados, quantas fontes de letras estão ativadas, as opções de tradução e pronúncia, se contas como a do Last.fm estão conectadas, em quais players e navegadores de terceiros você confia (só os bundle IDs), quais players web você pareou), quais players tocaram música nos dias anteriores e quantas vezes o app travou; quando o Lyrimuse ou o motor de letras falha, ele também envia um resumo da falha (o tipo de exceção e os nomes das funções na pilha, sem os caminhos). Ele nunca envia títulos de músicas, artistas, álbuns, caminhos locais, nomes de contas nem credenciais; o servidor não guarda endereços IP, só o país ou região que a Cloudflare deduz deles. Desative a opção e nada é enviado. Fora isso, só os serviços que você mesmo conecta: Last.fm, ListenBrainz, plataformas de notificação push e o relay web opcional (cuja página dos 10 artistas mais ouvidos busca os avatares dos artistas no Deezer). Com “Mostrar no Discord” ativado nos ajustes do Discord, o título, o artista, o álbum, o nome do player, o progresso da reprodução, a URL da capa e os links para a música e o artista (mais a linha que está sendo cantada e os links dos seus botões, se você ativar isso) são passados ao app do Discord no seu Mac, que os mostra no seu perfil; a capa é, quando possível, a que o próprio player fornece, a que já está no seu relay web ou a mesma imagem no NetEase Cloud Music, no QQ Music ou no Apple Music (quando o motor troca para a capa do próprio player, ele baixa uma vez uma miniatura dessa imagem para verificar se correspondem); caso contrário, ela é buscada no iTunes pelo ID da música ou do álbum no Apple Music (ou por artista + título) e, para um vídeo sem mais nada, é usada a URL da miniatura do vídeo no YouTube. Com o Apple Music, a busca pelo ID da música também é feita quando o relay já tem a capa, para obter a página do artista. Depois de conectar, o avatar do Discord mostrado em Ajustes (e, se você usar uma, a decoração de avatar para a pré-visualização) é baixado do servidor de imagens do Discord (cdn.discordapp.com) e, enquanto a página do Discord em Ajustes está aberta, a pré-visualização baixa a capa da URL do seu status para desenhá-la. Quando a capa do próprio player é pequena, o motor baixa miniaturas da capa correspondente no NetEase Cloud Music, no QQ Music ou no Apple Music, da capa que o próprio player guarda (incluindo os servidores de imagens do KKBOX e do Amazon Music, e os servidores de imagens do Kuwo e do Migu por trás das capas do LX Music) e das capas que vêm com os resultados das fontes de letras (como os servidores de imagens do Kugou, do Soda Music, do Deezer e do Musixmatch), para verificar se são a mesma imagem; quando uma URL de capa não informa o tamanho, ele também baixa o início da imagem para ler as dimensões. Só a URL da imagem é enviada. Com “Letra na web” ou “Saída para OBS” ativados (ambos desativados por padrão), o Lyrimuse serve uma página neste Mac (portas 3939 e 3940, a menos que você as mude); só este Mac consegue abri-la até você ativar “Permitir acesso pela rede local”; depois disso, os dispositivos da sua rede que tiverem o link (ele leva uma chave aleatória) podem ver a letra, a capa e o progresso atuais e, com “Permitir controle remoto” ativado, controlar a reprodução. Ele não envia nada a lugar nenhum por conta própria. Toda solicitação de saída é gravada num log de auditoria local (só o host e a operação, nunca parâmetros ou credenciais), que “Exportar diagnóstico” inclui.

## Solução de problemas

Se a letra não aparecer, abra **Fontes de letras** em Ajustes e clique em **Testar** para ver qual fonte não pode ser acessada. Se isso não resolver, use **Exportar diagnóstico** e anexe o arquivo a uma [issue](https://github.com/Yudaotor/lyrimuse/issues); ele já inclui o autodiagnóstico completo do serviço em segundo plano.

<details>
<summary>Autodiagnóstico pela linha de comando</summary>

A mesma verificação, executada no Terminal:

```sh
/Applications/Lyrimuse.app/Contents/Resources/lyrimuse-engine healthcheck
/Applications/Lyrimuse.app/Contents/Resources/lyrimuse-engine healthcheck -local-only  # no network
/Applications/Lyrimuse.app/Contents/Resources/lyrimuse-engine healthcheck -json
```

</details>

## Feedback

- **Problemas e ideias**: no app, abra Ajustes › Sobre › **Comunicar problema** ou clique com o botão direito no ícone da barra de menus e escolha **Ajuda › Comunicar problema…**. Isso abre uma nova issue no GitHub com a sua versão, o macOS e o player atual já preenchidos; escolha o tipo de relato: bug, letra ausente ou errada, pedido de player ou pedido de recurso.
- **Letra errada para uma música**: abra **Buscar letras** para essa música no **Gerenciador de letras** e clique em **Não encontrou a letra certa? Avise no GitHub**, no canto inferior esquerdo. Os detalhes da música, a fonte de letras em uso e as fontes que retornaram resultados vão junto.
- **Dúvidas**: pergunte na [categoria Q&A](https://github.com/Yudaotor/lyrimuse/discussions/categories/q-a) das Discussions.
- **Converse com outros usuários**: entre no [servidor do Discord](https://discord.gg/N7gVy66Gp3), no [grupo do Telegram](https://t.me/lyrimuse) ou no [grupo do QQ](https://qm.qq.com/q/Nb4TlwfnQy) (791558369, em chinês). Lá você também pode tirar dúvidas, relatar problemas ou sugerir recursos; o chinês tem um canal de conversa e um fórum de feedback próprios no Discord.
- **Sem conta no GitHub**: envie um e-mail para yudaotor@qq.com. O botão de envelope na linha **Comunicar problema**, em Ajustes › Sobre, preenche a sua versão e o macOS; clique nele com o botão direito para copiar o endereço.
- **Problemas de segurança**: relate-os em particular, como descrito em [SECURITY.md](SECURITY.md), e não numa issue pública.

## Desinstalação

Arrastar `Lyrimuse.app` para o Lixo **não** basta. O motor de letras (processo `lyrimuse-engine`) está
registrado no launchd como um job `KeepAlive`, então o LaunchAgent dele fica para trás e
o launchd continua tentando iniciar um binário que já não existe.

```sh
lyrimuse/scripts/uninstall.sh              # report only — shows what is installed
lyrimuse/scripts/uninstall.sh --services   # unregister both launchd jobs, keep your data
lyrimuse/scripts/uninstall.sh --purge      # also delete config, caches, logs and settings
```

Executado sem argumentos, ele não muda nada; só informa o que está instalado no seu
sistema. `--purge` lista tudo o que vai apagar, avisa quantos arquivos de letra exportados
estão entre eles e exige que você digite `yes`.

`--services` não mexe nos seus ajustes. `--purge` também os remove
(`defaults delete me.yudaotor.lyrimuse`), porque deixá-los para trás leva uma
reinstalação a um beco sem saída: o LaunchAgent sumiu, então o motor de letras não está
instalado, mas o app ainda acha que a configuração inicial foi concluída; por isso, o assistente que
o instalaria nunca aparece, e a área de trabalho fica parada em “Buscando letra”.

## Estrutura do projeto

Este repositório é o app:

- [`lyrimuse/`](lyrimuse) — o app em si (Swift, SwiftUI + AppKit)
- [`lyrimuse-engine/`](lyrimuse-engine) — o motor em segundo plano que resolve letras/capas e as entrega ao app (Go); compilado e incluído no app automaticamente

<details>
<summary>A página web opcional: dois repositórios irmãos</summary>

A experiência web opcional fica em dois repositórios irmãos, então você pode fazer fork de qualquer um deles sem mexer no app:

| Repositório | Função |
|---|---|
| [`Yudaotor/nowplaying`](https://github.com/Yudaotor/nowplaying) | A própria página web “reproduzindo agora” para compartilhar, mais um modelo pronto para fork |
| [`Yudaotor/nowplaying-workers`](https://github.com/Yudaotor/nowplaying-workers) | O relay Cloudflare Worker + o selo ao vivo para README por trás dela, com um guia de configuração completo a partir do zero |

```
this repo (app + engine)  ──push──▶  nowplaying-workers (relay)  ◀──read──  nowplaying (web page)
```

</details>

## Créditos

Obrigado ao [LyricsX](https://github.com/ddddxxx/LyricsX), que mostrou o que a letra na área de trabalho do Mac podia ser.

<details>
<summary>Projetos de código aberto e dados da comunidade em que o Lyrimuse se baseia</summary>

- [media-control](https://github.com/ungive/media-control) e [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter): leitura do que está tocando no macOS
- [Sparkle](https://github.com/sparkle-project/Sparkle): atualizações no app
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts): atalhos globais
- [OpenCC](https://github.com/BYVoid/OpenCC): conversão entre chinês simplificado e tradicional
- [rime-cantonese](https://github.com/rime/rime-cantonese): Jyutping cantonês
- [AMLL TTML DB](https://github.com/amll-dev/amll-ttml-db): letras palavra por palavra feitas pela comunidade
- [LRCLIB](https://lrclib.net): banco de dados aberto de letras sincronizadas
- [SponsorBlock](https://sponsor.ajay.app): trechos sem música em videoclipes

</details>

Os textos das licenças estão em [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES).
