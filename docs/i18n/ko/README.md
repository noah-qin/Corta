<div align="center">

<img src="../../brand/corta-pangolin-mascot.png" width="160" alt="몸을 C 모양으로 말고 꼬리가 청록색 커서인 Corta의 천산갑 마스코트">

# Corta

**빠르고 집중하기 좋은 터미널. Mac을 위해, Swift로 만들었습니다.**

Metal 4 렌더링 · 네이티브 CJK / IME · SSH, SFTP, 원격 편집

> 터미널에서 사는 사람들을 위해: 선명한 글자, 네이티브 입력, 강력한 원격 워크플로, 그리고 서드파티 의존성이 **전혀 없는** Swift 터미널 코어. 까다로운 출력도 감당할 만큼 빠르고, 매일의 작업에 어울릴 만큼 세심합니다.

[![CI](https://github.com/noah-qin/Corta/actions/workflows/ci.yml/badge.svg)](https://github.com/noah-qin/Corta/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/noah-qin/Corta?style=flat-square)](https://github.com/noah-qin/Corta/releases/latest)
![Platform](https://img.shields.io/badge/macOS_26.0%2B-Apple_silicon-4d4d4d?style=flat-square)
![Swift](https://img.shields.io/badge/Swift-6-f05138?style=flat-square)
[![License](https://img.shields.io/badge/license-Apache--2.0-2f81f7?style=flat-square)](../../../LICENSE)
[![Discord](https://img.shields.io/badge/Discord-join-5865f2?style=flat-square&logo=discord&logoColor=white)](https://discord.gg/QNdWfdwr7j)
[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-db61a2?style=flat-square&logo=githubsponsors&logoColor=white)](https://github.com/sponsors/noah-qin)

**[↓ 다운로드](https://github.com/noah-qin/Corta/releases/latest)** ·
**[사용자 가이드](USER-GUIDE.md)** ·
[문서(영어)](../../README.md) ·
[기여하기](../../../CONTRIBUTING.md) ·
[Discord](https://discord.gg/QNdWfdwr7j) ·
[버그 신고](https://github.com/noah-qin/Corta/issues/new?template=bug_report.yml)

🇺🇸 [English](../../../README.md) · 🇨🇳 [简体中文](../zh-CN/README.md) · 🇭🇰 [繁體中文](../zh-Hant/README.md) · 🇯🇵 [日本語](../ja/README.md) · 🇰🇷 [한국어](README.md) · 🇩🇪 [Deutsch](../de/README.md) · 🇫🇷 [Français](../fr/README.md) · 🇪🇸 [Español](../es/README.md) · 🇧🇷 [Português](../pt-BR/README.md)

<img src="../../brand/screenshot.png" width="960" alt="세 개로 분할된 Corta 페인: git log와 한중일 및 이모지 정렬표, 터미널에 표시된 천산갑 이미지, 24비트 색상 그라데이션">

</div>

> 이 문서는 영어판 [README.md](../../../README.md)의 커밋
> [`04ad320`](https://github.com/noah-qin/Corta/blob/04ad320438030e3ba4a7c19761b0279e39c42afc/README.md)
> 시점을 번역한 것입니다. 이후 영어판이 바뀌었거나 내용이 다르면 영어판을 따릅니다.

## 설치

**macOS 26.0 이상**, **Apple 실리콘**(M1 이상), **Metal 4를 지원하는 GPU**가 필요합니다.
반가상화 GPU를 쓰는 가상 머신은 지원하지 않습니다. Intel Mac에서는 이전 버전인
[1.0.1](https://github.com/noah-qin/Corta/releases/tag/v1.0.1)을 쓸 수 있습니다.

[GitHub Releases](https://github.com/noah-qin/Corta/releases/latest)에서 `.dmg`와 짝이 되는
`.dmg.sha256` 파일을 내려받아 같은 폴더에 두고, 그 폴더에서 체크섬을 확인하세요:

```sh
# x.y.z를 내려받은 버전으로 바꾸세요.
shasum -a 256 -c Corta-x.y.z.dmg.sha256
```

디스크 이미지를 열고 **Corta**를 **응용 프로그램**으로 끌어 놓은 다음, 이미지를 추출하세요.
릴리스는 Developer ID로 서명되고 공증을 받았습니다. 이후 업데이트는 **Corta ▸ 업데이트 확인…**을 쓰거나
새 릴리스를 내려받으세요. 설치 도움말과 제거 방법은 [문제 해결](TROUBLESHOOTING.md)에 있습니다.

## 첫걸음

| 하고 싶은 일 | 방법 |
| :--- | :--- |
| 오른쪽 / 아래로 분할 | ⌘D / ⇧⌘D |
| 터미널 출력 검색 | ⌘F |
| 명령 팔레트 열기 | ⇧⌘P |
| 설정 열기 | ⌘, |

디렉터리 제안이 켜져 있으면(기본값) 표준 로컬 zsh 세션은 번들된 셸 통합 훅을 자동으로 불러옵니다.
zsh, bash, fish의 시작 파일에 설치하려면 **설정 ▸ 터미널 ▸ 셸 통합**을 쓰세요. 셸의 시작 파일은
설치를 선택했을 때만 수정됩니다. 설치된 통합이 오래되었다면 업데이트를 선택하고 새 셸을 여세요.
자세한 내용은 [셸 통합 가이드](USER-GUIDE.md#shell-integration)를 보세요.

## 왜 Corta인가

| | |
| :--- | :--- |
| **네이티브 Mac 입력** | CJK 입력과 IME 조합, Core Text 글꼴 대체, VoiceOver, 보안 키보드 입력, 서비스, 퀵 터미널, 단축어 동작 — AppKit을 우회하지 않고 AppKit을 통해서. |
| **빠름, 그리고 근거** | 코어 처리량은 1.1의 2.3배, 전체 화면 입력 지연은 한 프레임 감소, 10만 줄 기록은 185 MiB 대신 11 MiB. 모든 수치를 측정 방법과 한계와 함께 공개합니다(아래). |
| **원격 작업 내장** | 시스템 OpenSSH와 `~/.ssh/config`, 끌어서 놓기를 지원하는 Finder 같은 SFTP 브라우저, 업로드 전에 충돌을 확인하는 로컬 편집기에서의 원격 파일 편집. |
| **설정 파일 하나** | 네이티브 설정 윈도우와 `~/.config/corta/config`는 같은 설정을 편집합니다. 문서에 있는 키와 단축키가 코드와 일치하도록 자동 검사가 지켜 줍니다. |
| **작은 코어, 단단한 안전장치** | 서드파티 의존성이 없는 Swift 터미널 코어, 신뢰할 수 없는 출력에 대한 자원 한도, 샌드박스에서 동작하는 이미지 디코더. 앱이 추가하는 것은 업데이트용 [Sparkle](https://sparkle-project.org)뿐입니다. 클립보드 읽기와 제목 조회는 의도적으로 없습니다([보안 모델](../../SECURITY.md), 영어). |

페인 분할, 스크롤백 검색, 트루 컬러, OSC 8 링크, Kitty 키보드 및 그래픽 프로토콜, 셸 통합, 레이아웃 복원이 모두 있습니다.
[기능 참조](../../FEATURES.md)(영어)에 요구 사항과 제한과 함께 모든 기능이 나와 있으며, `main` 브랜치를 기준으로 합니다 —
공개된 릴리스에는 아직 없는 항목도 있을 수 있습니다. iTerm2, Ghostty와 비교해 어떤지, 그리고 언제 그쪽을 고르는 것이 나은지는
[Features → How Corta compares](../../FEATURES.md#how-corta-compares)(영어)에 있습니다.
macOS 전용이라는 점과 tmux 제어 모드, 내장 AI, 스크립팅 엔진을 두지 않는다는 점은
[확정된 결정](../../DECISIONS.md)(영어)입니다. 일반적인 tmux 세션은 터미널 프로그램으로서 Corta 안에서 동작합니다.

## 내 방식대로

설정은 `~/.config/corta/config`에 저장됩니다. 네이티브 설정 윈도우와 이 텍스트 파일은 같은 설정을 편집합니다.

```ini
theme = midnight
theme.midnight.inherit = solarized
theme.midnight.dark.background = #101018

bind.equalize-panes = ctrl+cmd+e
bind.command-palette = cmd+shift+p
```

**보기 ▸ 테마 편집기…**는 색상 선택기와 라이트/다크 미리보기를 따로 엽니다. **설정 ▸ 모양 ▸ 커서**에서는
블록, 세로선, 밑줄과 별도의 깜박임 스위치를 고를 수 있으며, 기본값은 깜박이지 않는 블록입니다. 기본 글꼴은
시스템 고정폭만 지원하며, 크기를 조절할 수 있고 없는 문자는 시스템 대체 글꼴로 채워집니다.
**설정 ▸ 터미널 ▸ 하단 상태 표시줄**에서 원하는 로컬 지표를 켤 수 있습니다(기본값은 꺼짐). 클릭하면 호스트 정보가 나오며,
**보기 ▸ 로컬 호스트 정보…**로도 볼 수 있습니다. 단계별 방법, 네트워크 인터페이스 선택, 열 상태의 한계는
[개인화 튜토리얼](USER-GUIDE.md#personalizing-the-terminal)을 보세요.

[설정 참조](../../CONFIGURATION.md)(영어)에는 모든 키, 기본값, 변경이 적용되는 시점이 나와 있습니다.
[사용자 가이드](USER-GUIDE.md)는 모든 기능과 그 위치를 차례로 안내합니다.

## 소스에서 빌드

```sh
git clone https://github.com/noah-qin/Corta.git && cd Corta
swift test --package-path CortaTerminal                     # 터미널 코어만, 앱 없이
xcodebuild -project Corta.xcodeproj -scheme 'Corta (Dev)' build  # 설치된 Corta와 나란히 쓰는 개발용 앱
```

[기여 가이드](../../../CONTRIBUTING.md)(영어)에는 필요한 환경(macOS 26, Apple 실리콘, [`.xcode-version`](../../../.xcode-version)에
적힌 Xcode), 로컬 서명, 저장소 지도가 있습니다. [테스트 가이드](../../TESTING.md)(영어)는 변경마다 어떤 검사가 필요한지 알려 줍니다.

## 품질, 근거와 함께

Corta는 활발히 개발 중이며 알려진 문제도 있습니다. 아래 측정값은 스냅숏일 뿐, 모든 기기와 작업에서 성립한다는 보장은 아닙니다.
각 행에 어느 릴리스에서 측정했는지 적었습니다.

| 검사 | 기록된 결과 | 측정 릴리스 | 근거 |
| :--- | :--- | :--- | :--- |
| 코어 입력 처리량(파서, 그리드, 스크롤백. PTY와 렌더링 제외) | **317.3 MiB/s**, 기존 137.2 | 1.2 대 1.1 | [Performance §5.14](../../PERFORMANCE.md#514-scrolling-without-per-line-screen-allocation-281-283) |
| 파서 + 그리드 처리량 | **355.9 MiB/s**, 기존 158.0 | 1.2 대 1.1 | 위와 같음 |
| 스크롤백 메모리, 10만 줄 × 120열 | **11.4 MiB**, 기존 185 | 1.2 대 1.1 | [Performance §5.6](../../PERFORMANCE.md#56-numbers-by-release) |
| 영역 스크롤, 프레임당 CPU, p50 | **0.026 ms**, 기존 0.130 | 1.2 대 1.1 | [Performance §5.14](../../PERFORMANCE.md#514-scrolling-without-per-line-screen-allocation-281-283) |
| 프레임 CPU, 120 × 40 전체 재구성, Release | **0.37–0.39 ms** | 1.2 | [Performance §5.17](../../PERFORMANCE.md#517-full-screen-without-the-compositor-285-2026-10-13) |
| 키 입력에서 화면 표시까지, 전체 화면, 페인 하나, 60 Hz, 사람이 입력 | p50 **49.1–50.8 ms**, p99 82.9–84.2 ms(기존 p50 64–68 ms) | 1.2 | [Performance §5.17](../../PERFORMANCE.md#517-full-screen-without-the-compositor-285-2026-10-13) |
| 유휴 CPU, Release, 20초 | 0.05% | **1.0.0**(2026-09-18). 1.2의 유휴 깨우기 개선 이후 재측정하지 않음 | [Performance](../../PERFORMANCE.md) |
| esctest2 | 통과 131, 알려진 버그 334, 실패 102. 총 567 | **1.1.5**(2026-10-07) | [원본 결과](https://github.com/noah-qin/Corta/blob/f632d5918653cc2feee28fe1baa0c0fd01e93c0e/docs/esctest/2026-10-07-results.txt) |

측정 기기는 Apple M5 MacBook Air(macOS 27.0.1)이며, 1.2 행은 2026-10-09부터 2026-10-13 사이에 측정했고 전후 비교는 각각
같은 기기와 같은 툴체인에서 했습니다. [Performance](../../PERFORMANCE.md)(영어)의 날짜가 붙은 절에 조건, 모든 실행,
그리고 그 수치가 말해 주지 않는 것이 있습니다. 가끔 인용되는 esctest2 82.0%라는 수치는 통과에 **알려진 버그를 더한** 것이라
통과율이 아닙니다. 해석은 [Conformance](../../CONFORMANCE.md)(영어)를 보세요.

알려진 한계로는 윈도우 모드에서 키 입력부터 화면 표시까지의 지연이 한 프레임 목표보다 크다는 점(전체 화면에 페인 하나일 때 가장 가깝습니다),
VT 적합성이 완전하지 않다는 점, 번들된 셸 통합이 zsh, bash, fish만 지원한다는 점, Kitty 그래픽이 직접 전송만 지원한다는 점이 있습니다.
자세한 내용은 [한계 참조](../../FEATURES.md#known-limits)(영어)에 있습니다.

## 길잡이

| 하고 싶은 일 | 여기서 시작 |
| :--- | :--- |
| 모든 기능과 그 위치 알아보기 | [사용자 가이드](USER-GUIDE.md) |
| Corta 설정하기 | [Configuration](../../CONFIGURATION.md)(영어) |
| 기능이나 한계 이해하기 | [Features](../../FEATURES.md)(영어) |
| 문제 진단하기 | [문제 해결](TROUBLESHOOTING.md) |
| iTerm2, Ghostty, Terminal.app에서 옮겨 오기 | [다른 터미널에서 옮겨 오기](USER-GUIDE.md#coming-from-another-terminal) |
| 계획 보기, 제안하기 | [Open issues](https://github.com/noah-qin/Corta/issues) · [Discussions → Ideas](https://github.com/noah-qin/Corta/discussions/categories/ideas) |
| 할 일 찾기 | [Good first issues](https://github.com/noah-qin/Corta/labels/good%20first%20issue) · [Help wanted](https://github.com/noah-qin/Corta/labels/help%20wanted) |
| 첫 기여하기 | [Contributing](../../../CONTRIBUTING.md)(영어) |
| 테스트 실행 또는 추가 | [Testing](../../TESTING.md)(영어) |
| 코드 이해하기 | [Architecture](../../DESIGN.md) · [Core API](../../../CortaTerminal/Sources/CortaTerminal/CortaTerminal.docc/CortaTerminal.md)(영어) |
| 전체 문서 읽기 | [문서 색인](../../README.md)(영어) |

## 기여하기

버그 재현, 문서, 번역, 접근성 테스트, 코드 기여를 환영합니다.
[good first issue](https://github.com/noah-qin/Corta/labels/good%20first%20issue)나
[help wanted](https://github.com/noah-qin/Corta/labels/help%20wanted)에서 시작하고, 환경 설정과 리뷰 기준은
[CONTRIBUTING.md](../../../CONTRIBUTING.md)를 읽어 주세요. 커뮤니티 참여는 [행동 강령](../../../CODE_OF_CONDUCT.md)을 따릅니다.

Corta를 써 보고 원래 터미널로 돌아갔나요? 그 이야기도 듣고 싶습니다:
[Went back 양식](https://github.com/noah-qin/Corta/issues/new?template=went_back.yml)은
재현 과정이 필요 없고, "그냥 느낌이 별로였다"도 괜찮은 답입니다.

취약점은 [비공개 보안 채널](../../../SECURITY.md)로 신고해 주세요.
다른 사용자나 메인테이너와 이야기하고 싶다면 [Discord](https://discord.gg/QNdWfdwr7j)에 참여하세요.
다른 사람도 답을 찾을 수 있어야 하는 사용법 질문은 [Discussions → Q&A](https://github.com/noah-qin/Corta/discussions/categories/q-a)로 (한국어 질문도 환영합니다),
테마나 환경을 공유하려면 [Show and tell](https://github.com/noah-qin/Corta/discussions/categories/show-and-tell)로 가세요.
그 밖의 문제는 [이슈를 열어](https://github.com/noah-qin/Corta/issues/new/choose) 주세요.

### 후원

Corta는 한 사람이 공개적으로 만들고 유지합니다. 매일 쓰는 도구가 되었다면, 후원이 개발을 이어 가게 합니다 — 금액에 상관없이 도움이 됩니다.

<a href="https://github.com/sponsors/noah-qin"><img src="https://img.shields.io/badge/Sponsor_noah--qin_on_GitHub-%E2%9D%A4-db61a2?style=for-the-badge&logo=githubsponsors&logoColor=white" alt="GitHub에서 noah-qin 후원하기"></a>

### 기여자

Corta에 기여해 주신 모든 분께 감사드립니다.

<a href="https://github.com/noah-qin"><img src="https://github.com/noah-qin.png?size=96" width="48" height="48" alt="noah-qin" title="noah-qin"></a>
<a href="https://github.com/FrankChen-CLC"><img src="https://github.com/FrankChen-CLC.png?size=96" width="48" height="48" alt="FrankChen-CLC" title="FrankChen-CLC"></a>

## 라이선스와 정체성

소스 코드는 [Apache 2.0](../../../LICENSE) 라이선스를 따릅니다. Corta 이름, 천산갑 마스코트, 앱 아이콘에는
[NOTICE](../../../NOTICE)에 별도의 조건이 있습니다. 천산갑의 말린 몸은 C를 이루고, 청록색 꼬리는 터미널 커서입니다.
[브랜드 자료](../../brand/README.md)에는 마스코트와 소셜 미리보기가 들어 있습니다.
