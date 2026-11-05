# Lyrimuse URL 스킴

*[English](url-scheme.md) · [简体中文](url-scheme.zh-CN.md) · [日本語](url-scheme.ja.md) · **한국어** · [Español](url-scheme.es.md) · [Français](url-scheme.fr.md) · [Deutsch](url-scheme.de.md) · [Italiano](url-scheme.it.md) · [Português (Brasil)](url-scheme.pt-BR.md) · [Tiếng Việt](url-scheme.vi.md) · [Русский](url-scheme.ru.md) · [Українська](url-scheme.uk.md)*

`lyrimuse://`로 시작하는 링크를 사용하면 단축어, Raycast, Alfred, Stream Deck, 터미널(`open 'lyrimuse://…'`) 등에서 Lyrimuse를 제어할 수 있습니다. 윈도우와 설정 페이지 열기, 가사 표시 및 가리기, 재생 제어, 타이밍 미세 조정, 지금 재생 중인 곡 정보 가져오기를 할 수 있습니다.

자주 쓰는 링크는 설정 › 키보드 단축키 맨 아래의 **딥 링크**에서 복사할 수 있습니다. 그곳의 단축키 위에 포인터를 올리면 해당 동작의 링크를 복사할 수 있습니다.

## 일반 규칙

- 링크는 대소문자를 구분하지 않습니다.
- Lyrimuse가 인식하지 못하는 링크는 아무 동작도 하지 않고 ‘인식할 수 없는 링크’를 표시합니다.
- 윈도우를 여는 링크는 모두 `background=1`을 받습니다. 윈도우는 나타나지만 Lyrimuse가 앞으로 나오거나 키보드 포커스를 가져가지 않습니다. 예: `lyrimuse://lyrics-window?background=1`
- 켜고 끄는 동작은 `on=1` 또는 `on=0`으로 목표 상태를 지정할 수 있으므로(`true` / `false`, `on` / `off`도 사용 가능) 두 번 실행해도 결과가 같습니다. 지정하지 않으면 상태를 전환합니다.
- 웹 페이지에서도 `lyrimuse://` 링크를 열 수 있으므로(브라우저가 먼저 확인을 요청합니다) 되돌리기 쉬운 동작만 제공합니다. 켜고 끄기, 윈도우 열기, 재생 제어, 타이밍 미세 조정입니다. 가사를 삭제하거나 편집하는 동작, 계정에 영향을 주는 동작은 없습니다.

## 윈도우 열기

| 링크 | 동작 |
|---|---|
| `lyrimuse://lyrics-window` | 가사 윈도우를 엽니다 |
| `lyrimuse://lyrics-window/search` | 가사 윈도우와 가사 검색 윈도우(`lyrics-search`와 같은 윈도우)를 엽니다 |
| `lyrimuse://lyrics-manager` | 가사 관리자를 엽니다 |
| `lyrimuse://lyrics-search` | 현재 노래의 가사 검색 윈도우를 엽니다 |
| `lyrimuse://menubar-panel` | 메뉴 막대 패널을 열거나 닫습니다 |
| `lyrimuse://menubar-panel?quick=overlay` | 메뉴 막대 패널을 특정 타일의 빠른 설정 화면으로 엽니다(열기만 하고 닫지 않음). `quick`은 `overlay`, `notch`, `menubar`, `touchbar`, `lyrics-window`, `lyrics-manager` 중 하나입니다 |
| `lyrimuse://menubar-menu` | 메뉴 막대 아이콘의 메뉴를 띄웁니다 |
| `lyrimuse://onboarding` | 시작 가이드를 엽니다 |
| `lyrimuse://whats-new` | 설치된 버전의 새로운 기능을 보여 줍니다 |

## 설정 열기

`lyrimuse://settings`는 설정을 엽니다. 경로를 붙이면 해당 페이지로 바로 이동하고, 한 단계 더 붙이면 그 페이지의 특정 섹션으로 이동합니다.

| 경로 | 페이지 | 섹션 |
|---|---|---|
| `/lyrics` | 가사 | `/fetch` 또는 `/sources` 출처, `/translation` 또는 `/language` 언어, `/display` 또는 `/timing` 타이밍, `/manage` 또는 `/library` 가사 보관함 |
| `/player` | 플레이어 | `/players` 플레이어, `/linkage` 실행 및 종료, `/permissions` 권한 및 서비스 |
| `/appearance` | 가사 표시 | `/overlay` 플로팅 가사, `/notch` 노치, `/menu-bar` 메뉴 막대, `/touch-bar` Touch Bar, `/lyrics-window` 가사 윈도우 |
| `/shortcuts` | 키보드 단축키 | — |
| `/general` | 일반 | — |
| `/about` | 정보 | — |
| `/account/lastfm` | Last.fm | `/stats` 통계, `/chart` 차트, `/on-this-day` 발자취, `/settings` 규칙 |
| `/account/listenbrainz` | ListenBrainz | — |
| `/account/discord` | Discord | `/display` 표시 내용, `/buttons` 버튼, `/privacy` 개인정보 보호 |
| `/account/relay` | 웹 푸시 | — |
| `/account/bark` | 푸시 알림 | — |
| `/software-update` | 소프트웨어 업데이트 | `?check=1`을 붙이면 업데이트도 확인합니다 |
| `/lastfm-suggestions` | Last.fm 계정 제안 | — |
| `/labs` | 실험실 | — |

예: `lyrimuse://settings/appearance/overlay` 또는 `lyrimuse://settings/software-update?check=1`. 알 수 없는 경로는 설정만 열고, 알 수 없는 섹션은 마지막으로 본 섹션에서 페이지를 엽니다.

## 동작: `lyrimuse://action/<name>`

설정 › 키보드 단축키에 있는 키보드 단축키와 같은 동작입니다. 같은 코드를 실행하고 같은 피드백을 표시합니다.

### 표시

| 이름 | 동작 | 매개변수 |
|---|---|---|
| `toggle-overlay` | 플로팅 가사를 표시하거나 가립니다 | `on` |
| `toggle-notch` | 노치 가사를 표시하거나 가립니다 | `on` |
| `peek-notch` | 노치 가사를 몇 초 동안 펼칩니다. 다시 실행하면 일찍 닫힙니다 | — |
| `toggle-menubar-lyrics` | 메뉴 막대 가사를 표시하거나 가립니다 | `on` |
| `toggle-touchbar` | Touch Bar 가사를 펼치거나 접습니다(Touch Bar가 있는 Mac만 해당) | — |
| `toggle-all-lyrics` | 모든 가사를 가립니다. 플로팅 가사, 노치 가사, 메뉴 막대 가사 중 켜져 있던 것을 가리고, 다시 실행하면 바로 그것들을 되돌립니다 | `on`(`0`은 가리기, `1`은 복원) |
| `toggle-lock-position` | 플로팅 가사의 위치를 잠그거나 잠금 해제합니다 | `on` |
| `toggle-translation` | 번역을 표시하거나 가립니다 | `on` |
| `toggle-romanization` | 로마자 표기를 표시하거나 가립니다 | `on` |
| `overlay-font-larger` | 플로팅 가사를 크게 합니다 | — |
| `overlay-font-smaller` | 플로팅 가사를 작게 합니다 | — |

### 윈도우

| 이름 | 동작 | 매개변수 |
|---|---|---|
| `open-lyrics-manager` | 가사 관리자를 엽니다 | — |
| `open-lyrics-window` | 가사 윈도우를 엽니다 | — |
| `toggle-lyrics-window-mini` | 가사 윈도우를 미니 크기와 전체 크기 사이에서 전환합니다. 닫혀 있으면 미니 크기로 엽니다 | `on`(`1`은 미니, `0`은 전체) |
| `search-lyrics` | 가사 검색 윈도우를 엽니다 | — |
| `open-settings` | 설정을 엽니다 | — |
| `open-player` | 사용 중인 플레이어를 앞으로 가져옵니다 | — |
| `toggle-menubar-panel` | 메뉴 막대 패널을 열거나 닫습니다(메뉴 막대 아이콘을 클릭한 것과 같음) | — |

### 가사 타이밍

| 이름 | 동작 | 매개변수 |
|---|---|---|
| `lyrics-advance` | 이 노래의 가사를 한 단계 앞당깁니다 | `step`: 이번 조정에 쓸 초 단위 값(0~5). 생략하면 설정의 단계 값 |
| `lyrics-delay` | 이 노래의 가사를 한 단계 늦춥니다 | `step`, 위와 같음 |
| `lyrics-offset-reset` | 이 노래의 가사 오프셋을 0으로 재설정합니다 | — |

### 재생

| 이름 | 동작 | 매개변수 |
|---|---|---|
| `play-pause` | 재생 / 일시 정지 | — |
| `next-track` | 다음 트랙 | — |
| `previous-track` | 이전 트랙 | — |
| `toggle-favorite` | 현재 노래를 즐겨찾기에 추가하거나 해제합니다(플레이어가 지원하는 경우) | `on`(`1`은 추가, `0`은 해제) |

예: `lyrimuse://action/toggle-overlay?on=0` 또는 `lyrimuse://action/lyrics-advance?step=0.5`.

### 기타 동작

| 링크 | 동작 |
|---|---|
| `lyrimuse://action/copy-lyric` | 현재 가사 줄을 클립보드에 복사합니다. `?translation=1`을 붙이면 번역도 포함합니다 |
| `lyrimuse://action/surfaces?overlay=1&notch=0&menubar=1` | 표시할 가사를 한 번에 설정합니다. `overlay`(플로팅 가사), `notch`, `menubar`를 각각 `1`이면 표시, `0`이면 가리기로 지정합니다. 바꾸려는 것만 넣으면 됩니다 |
| `lyrimuse://action/lyrics-offset?ms=-300` | 이 노래의 가사 오프셋을 밀리초 단위의 정확한 값으로 설정합니다. 양수는 앞당기고 음수는 늦추며, 범위는 ±10000입니다 |
| `lyrimuse://action/play-mode?mode=shuffle` | 재생 모드를 설정합니다. `mode`는 `list`, `shuffle`, `repeat-all`, `repeat-one` 중 하나입니다. 플레이어가 지원하지 않는 모드는 `list`로 대체됩니다 |

## 지금 재생 중인 곡 가져오기(x-callback-url)

```
lyrimuse://x-callback-url/now-playing?x-success=<callback URL>
```

Lyrimuse는 지금 재생 중인 곡 정보를 매개변수로 덧붙여 `x-success` URL을 엽니다(`x-success`에 이미 있는 매개변수는 유지됩니다).

| 매개변수 | 값 |
|---|---|
| `title` | 노래 제목 |
| `artist` | 아티스트 |
| `album` | 앨범 |
| `lyric` | 현재 가사 줄 |
| `player` | 플레이어 이름 |
| `playing` | 재생 중이면 `1`, 일시 정지했거나 불러온 곡이 없으면 `0`(불러온 곡이 없으면 위 필드는 비어 있음) |

단축어에서는 **X-Callback URL 열기** 동작을 사용하고 URL에 `lyrimuse://x-callback-url/now-playing`을 넣습니다. `x-success`는 단축어가 직접 추가하며, 돌려받은 매개변수가 그 동작의 출력이 됩니다.

웹 페이지가 이 링크로 사용자가 듣는 곡을 알아내지 못하도록 콜백 URL에는 두 가지 제한이 있습니다. 웹, 파일, 스크립트 URL(`http`, `https`, `file`, `ftp`, `javascript`, `data`, `about`, `blob`, 또는 `lyrimuse` 자체)일 수 없고, Mac에서 브라우저가 아닌 앱이 열어야 합니다. 그렇지 않으면 아무것도 돌려보내지 않습니다.
