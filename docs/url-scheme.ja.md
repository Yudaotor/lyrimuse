# Lyrimuse URLスキーム

*[English](url-scheme.md) · [简体中文](url-scheme.zh-CN.md) · **日本語** · [한국어](url-scheme.ko.md) · [Español](url-scheme.es.md) · [Français](url-scheme.fr.md) · [Deutsch](url-scheme.de.md) · [Italiano](url-scheme.it.md) · [Português (Brasil)](url-scheme.pt-BR.md) · [Tiếng Việt](url-scheme.vi.md) · [Русский](url-scheme.ru.md) · [Українська](url-scheme.uk.md) · [ไทย](url-scheme.th.md)*

`lyrimuse://` で始まるリンクを使うと、ショートカット、Raycast、Alfred、Stream Deck、ターミナル（`open 'lyrimuse://…'`）などのツールからLyrimuseを操作できます。ウインドウや設定ページを開く、歌詞の表示・非表示を切り替える、再生を操作する、タイミングを微調整する、再生中の曲の情報を取得する、といったことができます。

よく使うリンクは、設定 › キーボードショートカットの一番下にある**ディープリンク**からコピーできます。そこにある各ショートカットにポインタを合わせると、その操作のリンクをコピーできます。

## 共通のルール

- リンクは大文字と小文字を区別しません。
- Lyrimuseが認識できないリンクは何もせず、「認識できないリンク」と表示します。
- ウインドウを開くリンクはどれも `background=1` を受け付けます。ウインドウは表示されますが、Lyrimuseは前面に出ず、キーボードフォーカスも奪いません。例：`lyrimuse://lyrics-window?background=1`。
- 切り替え操作は、`on=1` または `on=0` で目的の状態を指定できます（`true` / `false`、`on` / `off` も使えます）。そのため、2回実行しても結果は同じです。指定しない場合は切り替えになります。
- Webページからも `lyrimuse://` リンクを開けるため（ブラウザが事前に確認します）、公開しているのは簡単に元に戻せる操作だけです。切り替え、ウインドウを開く、再生の操作、タイミングの微調整がそれにあたります。歌詞を削除・編集したり、アカウントに触れたりする操作はありません。

## ウインドウを開く

| リンク | 動作 |
|---|---|
| `lyrimuse://lyrics-window` | 歌詞ウインドウを開きます |
| `lyrimuse://lyrics-window/search` | 歌詞ウインドウと「歌詞を検索」ウインドウ（`lyrics-search` と同じもの）を開きます |
| `lyrimuse://lyrics-manager` | 歌詞マネージャを開きます |
| `lyrimuse://lyrics-search` | 再生中の曲の「歌詞を検索」ウインドウを開きます |
| `lyrimuse://menubar-panel` | メニューバーパネルを開閉します |
| `lyrimuse://menubar-panel?quick=overlay` | メニューバーパネルを、いずれかのタイルのクイック設定を表示した状態で開きます（開くだけで、閉じることはありません）。`quick` には `overlay`、`notch`、`menubar`、`touchbar`、`lyrics-window`、`lyrics-manager`、`translation`、`romanization`、`overlay-font`、`lyrics-offset`、`lock-position`、`mini-window`、`volume` のいずれかを指定します |
| `lyrimuse://menubar-menu` | メニューバーアイコンのメニューを表示します |
| `lyrimuse://onboarding` | ようこそガイドを開きます |
| `lyrimuse://whats-new` | インストール中のバージョンの新機能を表示します |

## 設定を開く

`lyrimuse://settings` は設定を開きます。パスを付け足すとそのページに直接移動し、さらに1段付け足すとそのページ内のセクションに移動します。

| パス | ページ | セクション |
|---|---|---|
| `/lyrics` | 歌詞 | `/fetch` または `/sources` ソース、`/translation` または `/language` 言語、`/display` または `/timing` タイミング、`/manage` または `/library` 歌詞ライブラリ |
| `/player` | プレーヤー | `/players` プレーヤー、`/linkage` 起動と終了、`/permissions` 権限とサービス |
| `/appearance` | 歌詞の表示 | `/overlay` フローティング歌詞、`/notch` ノッチ、`/menu-bar` メニューバー、`/touch-bar` Touch Bar、`/lyrics-window` 歌詞ウインドウ |
| `/shortcuts` | キーボードショートカット | — |
| `/general` | 一般 | — |
| `/about` | 情報 | — |
| `/account/lastfm` | Last.fm | `/stats` 統計、`/chart` ランキング、`/on-this-day` 足跡、`/settings` ルール |
| `/account/listenbrainz` | ListenBrainz | — |
| `/account/discord` | Discord | `/display` 表示内容、`/buttons` ボタン、`/privacy` プライバシー |
| `/account/relay` | Webプッシュ | — |
| `/account/bark` | プッシュ通知 | — |
| `/software-update` | ソフトウェアアップデート | `?check=1` を付けると、アップデートの確認も行います |
| `/lastfm-suggestions` | Last.fmアカウントの提案 | — |
| `/labs` | ラボ | — |

例：`lyrimuse://settings/appearance/overlay`、`lyrimuse://settings/software-update?check=1`。不明なパスの場合は設定を開くだけです。不明なセクションの場合は、そのページを最後に表示していたセクションで開きます。

## 操作：`lyrimuse://action/<name>`

これらは、設定 › キーボードショートカットにあるキーボードショートカットと同じ操作です。同じコードを実行し、同じフィードバックを表示します。

### 表示

| 名前 | 動作 | パラメータ |
|---|---|---|
| `toggle-overlay` | フローティング歌詞を表示・非表示にします | `on` |
| `toggle-notch` | ノッチの歌詞を表示・非表示にします | `on` |
| `peek-notch` | ノッチの歌詞を数秒間展開します。もう一度実行すると早めに閉じます | — |
| `toggle-menubar-lyrics` | メニューバーの歌詞を表示・非表示にします | `on` |
| `toggle-touchbar` | Touch Barの歌詞を展開・折りたたみます（Touch Bar搭載のMacのみ） | — |
| `toggle-all-lyrics` | すべての歌詞を隠します。フローティング歌詞、ノッチの歌詞、メニューバーの歌詞のうち、オンになっているものを非表示にし、もう一度実行するとそれらだけを元に戻します | `on`（`0` で非表示、`1` で復元） |
| `toggle-lock-position` | フローティング歌詞の位置をロック・ロック解除します | `on` |
| `toggle-translation` | 翻訳を表示・非表示にします | `on` |
| `toggle-romanization` | ローマ字を表示・非表示にします | `on` |
| `overlay-font-larger` | フローティング歌詞を大きくします | — |
| `overlay-font-smaller` | フローティング歌詞を小さくします | — |

### ウインドウ

| 名前 | 動作 | パラメータ |
|---|---|---|
| `open-lyrics-manager` | 歌詞マネージャを開きます | — |
| `open-lyrics-window` | 歌詞ウインドウを開きます | — |
| `toggle-lyrics-window-mini` | 歌詞ウインドウをミニサイズとフルサイズで切り替えます。閉じている場合はミニサイズで開きます | `on`（`1` でミニ、`0` でフル） |
| `search-lyrics` | 「歌詞を検索」ウインドウを開きます | — |
| `open-settings` | 設定を開きます | — |
| `open-player` | 使用中のプレーヤーを前面に出します | — |
| `toggle-menubar-panel` | メニューバーのパネルを開閉します（メニューバーのアイコンをクリックするのと同じ） | — |

### 歌詞のタイミング

| 名前 | 動作 | パラメータ |
|---|---|---|
| `lyrics-advance` | この曲の歌詞を1ステップ早めます | `step`：今回の調整幅（秒、0～5）。省略すると設定のステップを使います |
| `lyrics-delay` | この曲の歌詞を1ステップ遅らせます | `step`（上と同じ） |
| `lyrics-offset-reset` | この曲の歌詞のオフセットをゼロに戻します | — |

### 再生

| 名前 | 動作 | パラメータ |
|---|---|---|
| `play-pause` | 再生/一時停止 | — |
| `next-track` | 次のトラック | — |
| `previous-track` | 前のトラック | — |
| `toggle-favorite` | 再生中の曲をお気に入りに追加・削除します（プレーヤーが対応している場合） | `on`（`1` で追加、`0` で削除） |

例：`lyrimuse://action/toggle-overlay?on=0`、`lyrimuse://action/lyrics-advance?step=0.5`。

### その他の操作

| リンク | 動作 |
|---|---|
| `lyrimuse://action/copy-lyric` | 現在の歌詞の行をクリップボードにコピーします。`?translation=1` を付けると翻訳も含めます |
| `lyrimuse://action/surfaces?overlay=1&notch=0&menubar=1` | どの歌詞を表示するかを一度に設定します。`overlay`（フローティング歌詞）、`notch`、`menubar` をそれぞれ `1` で表示、`0` で非表示にします。変更したいものだけ指定してください |
| `lyrimuse://action/lyrics-offset?ms=-300` | この曲の歌詞のオフセットをミリ秒単位で正確に設定します。正の値で早め、負の値で遅らせます。範囲は±10000以内です |
| `lyrimuse://action/play-mode?mode=shuffle` | 再生モードを設定します。`mode` には `list`、`shuffle`、`repeat-all`、`repeat-one` のいずれかを指定します。プレーヤーが対応していないモードは `list` になります |

## 再生中の曲の情報を取得する（x-callback-url）

```
lyrimuse://x-callback-url/now-playing?x-success=<callback URL>
```

Lyrimuseは、再生中の曲の情報をパラメータとして付け加えたうえで `x-success` のURLを開きます（`x-success` にもともと付いているパラメータは残します）。

| パラメータ | 値 |
|---|---|
| `title` | 曲名 |
| `artist` | アーティスト |
| `album` | アルバム |
| `lyric` | 現在の歌詞の行 |
| `player` | プレーヤー名 |
| `playing` | 再生中は `1`、一時停止中または何も読み込まれていないときは `0`（何も読み込まれていない場合、上のフィールドは空になります） |

ショートカットでは、**X-Callback URLを開く**アクションを使い、URLに `lyrimuse://x-callback-url/now-playing` を指定します。`x-success` はショートカットが自動で付け加え、返されたパラメータがアクションの出力になります。

Webページがこのリンクを使って再生中の曲を知ることができないよう、コールバックURLには2つの制限があります。Web、ファイル、スクリプトのURL（`http`、`https`、`file`、`ftp`、`javascript`、`data`、`about`、`blob`、および `lyrimuse` 自身）は使えません。また、Mac上でブラウザ以外のアプリから開かれる必要があります。条件を満たさない場合は何も返しません。
