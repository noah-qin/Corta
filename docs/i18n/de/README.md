<div align="center">

<img src="../../brand/corta-pangolin-mascot.png" width="160" alt="Cortas Schuppentier-Maskottchen, zu einem C eingerollt, mit einem cyanfarbenen Cursor am Schwanz">

# Corta

**Ein schnelles, fokussiertes Terminal. Gemacht für den Mac. Gebaut in Swift.**

Metal-4-Rendering · Native CJK-Eingabe / IME · SSH, SFTP und Bearbeiten aus der Ferne

> Für alle, die im Terminal zu Hause sind: gestochen scharfer Text, native Eingabe, starke Remote-Workflows und ein Terminal-Kern in Swift **ohne** Abhängigkeiten von Drittanbietern. Schnell genug für anspruchsvolle Ausgaben. Durchdacht genug für die tägliche Arbeit.

[![CI](https://github.com/noah-qin/Corta/actions/workflows/ci.yml/badge.svg)](https://github.com/noah-qin/Corta/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/noah-qin/Corta?style=flat-square)](https://github.com/noah-qin/Corta/releases/latest)
![Platform](https://img.shields.io/badge/macOS_26.0%2B-Apple_silicon-4d4d4d?style=flat-square)
![Swift](https://img.shields.io/badge/Swift-6-f05138?style=flat-square)
[![License](https://img.shields.io/badge/license-Apache--2.0-2f81f7?style=flat-square)](../../../LICENSE)
[![Discord](https://img.shields.io/badge/Discord-join-5865f2?style=flat-square&logo=discord&logoColor=white)](https://discord.gg/QNdWfdwr7j)
[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-db61a2?style=flat-square&logo=githubsponsors&logoColor=white)](https://github.com/sponsors/noah-qin)

**[↓ Herunterladen](https://github.com/noah-qin/Corta/releases/latest)** ·
**[Benutzerhandbuch](USER-GUIDE.md)** ·
[Dokumentation (Englisch)](../../README.md) ·
[Mitwirken](../../../CONTRIBUTING.md) ·
[Discord](https://discord.gg/QNdWfdwr7j) ·
[Fehler melden](https://github.com/noah-qin/Corta/issues/new?template=bug_report.yml)

🇺🇸 [English](../../../README.md) · 🇨🇳 [简体中文](../zh-CN/README.md) · 🇭🇰 [繁體中文](../zh-Hant/README.md) · 🇯🇵 [日本語](../ja/README.md) · 🇰🇷 [한국어](../ko/README.md) · 🇩🇪 [Deutsch](README.md) · 🇫🇷 [Français](../fr/README.md) · 🇪🇸 [Español](../es/README.md) · 🇧🇷 [Português](../pt-BR/README.md)

<img src="../../brand/screenshot.png" width="960" alt="Corta mit drei geteilten Bereichen: ein git log und eine Ausrichtungstabelle mit Chinesisch, Japanisch, Koreanisch und Emoji; das Schuppentier-Maskottchen als Bild im Terminal; und 24-Bit-Farbverläufe">

</div>

> Diese Seite ist eine Übersetzung der englischen [README.md](../../../README.md) mit dem Stand von Commit
> [`04ad320`](https://github.com/noah-qin/Corta/blob/04ad320438030e3ba4a7c19761b0279e39c42afc/README.md).
> Wurde die englische Fassung seitdem geändert oder weichen die beiden ab, gilt die englische.

## Installation

Voraussetzung sind **macOS 26.0 oder neuer**, **Apple Silicon** (M1 oder neuer) und eine **Metal-4-fähige GPU**.
Virtuelle Maschinen mit paravirtualisierter GPU werden nicht unterstützt. Intel-Macs können das ältere
[Release 1.0.1](https://github.com/noah-qin/Corta/releases/tag/v1.0.1) verwenden.

Lade die `.dmg` und die passende `.dmg.sha256`-Datei von
[GitHub Releases](https://github.com/noah-qin/Corta/releases/latest) herunter.
Lege beide Dateien in denselben Ordner und prüfe dort die Prüfsumme:

```sh
# Ersetze x.y.z durch die heruntergeladene Version.
shasum -a 256 -c Corta-x.y.z.dmg.sha256
```

Öffne das Image, ziehe **Corta** in **Programme** und wirf das Image anschließend aus. Releases sind mit
Developer ID signiert und notarisiert. Spätere Updates erhältst du über **Corta ▸ Nach Updates suchen…** oder indem du
ein neueres Release herunterlädst. Hilfe zur Installation und Anleitungen zum Deinstallieren findest du unter
[Fehlerbehebung](TROUBLESHOOTING.md).

## Erste Schritte

| Um … | Verwende |
| :--- | :--- |
| Rechts / unten teilen | ⌘D / ⇧⌘D |
| Terminalausgabe durchsuchen | ⌘F |
| Befehlspalette öffnen | ⇧⌘P |
| Einstellungen öffnen | ⌘, |

Standardmäßige lokale zsh-Sitzungen laden die mitgelieferten Shell-Integrations-Hooks automatisch, wenn die
Verzeichnisvorschläge aktiviert sind (Standard). Zur Installation in die Startdateien von zsh, bash oder fish verwende
**Einstellungen ▸ Terminal ▸ Shell-Integration**; deine Startdateien werden nur geändert, wenn du „Installieren“ wählst.
Ist eine installierte Integration veraltet, wähle „Aktualisieren“ und öffne eine neue Shell. Details stehen im
[Leitfaden zur Shell-Integration](USER-GUIDE.md#shell-integration).

## Warum Corta

| | |
| :--- | :--- |
| **Native Mac-Eingabe** | CJK-Eingabe und IME-Komposition, Core-Text-Schriftersatz, VoiceOver, Sichere Tastatureingabe, Dienste, das Schnellterminal und Kurzbefehle-Aktionen – über AppKit, nicht an AppKit vorbei. |
| **Schnell, mit Belegen** | 2,3-facher Kerndurchsatz gegenüber 1.1, ein Frame weniger Eingabelatenz im Vollbild und 11 MiB statt 185 MiB für 100.000 Zeilen Verlauf. Jede Zahl wird mit ihrer Methode und ihren Lücken veröffentlicht (siehe unten). |
| **Remote-Arbeit eingebaut** | Das OpenSSH des Systems mit deiner `~/.ssh/config`, ein Finder-ähnlicher SFTP-Browser mit Drag-and-drop und entfernte Dateien, die in deinem lokalen Editor geöffnet werden – mit Konfliktprüfung vor dem Hochladen. |
| **Eine Einstellungsdatei** | Das native Einstellungsfenster und `~/.config/corta/config` bearbeiten denselben Speicher; automatische Prüfungen halten die dokumentierten Schlüssel und Kurzbefehle mit dem Code in Einklang. |
| **Kleiner Kern, ernsthafte Schutzmaßnahmen** | Ein Terminal-Kern in Swift ohne Abhängigkeiten von Drittanbietern, Ressourcengrenzen für nicht vertrauenswürdige Ausgaben und ein Bilddecoder in einer Sandbox; die App ergänzt nur [Sparkle](https://sparkle-project.org) für Updates. Lesen der Zwischenablage und Titelabfragen fehlen bewusst ([Sicherheitsmodell](../../SECURITY.md), Englisch). |

Geteilte Bereiche, Suche im Verlauf, Echtfarben, OSC-8-Links, die Kitty-Tastatur- und -Grafikprotokolle,
Shell-Integration und wiederhergestellte Layouts sind alle da; die [Funktionsreferenz](../../FEATURES.md) (Englisch)
listet alles mit Voraussetzungen und Einschränkungen auf und beschreibt `main` – ein veröffentlichtes Release enthält
womöglich noch nicht jeden Punkt. Wie sich Corta mit iTerm2 und Ghostty vergleicht und wann du besser eines von beiden
wählst, steht unter [Features → How Corta compares](../../FEATURES.md#how-corta-compares) (Englisch).
Dass Corta nur macOS unterstützt und keinen tmux-Steuermodus, keine eingebaute KI und keine Skript-Engine hat, sind
[getroffene Entscheidungen](../../DECISIONS.md) (Englisch); gewöhnliche tmux-Sitzungen laufen als Terminalprogramme in Corta.

## Mach es zu deinem

Einstellungen werden in `~/.config/corta/config` gespeichert. Das native Einstellungsfenster und die Textdatei
bearbeiten dieselbe Konfiguration.

```ini
theme = midnight
theme.midnight.inherit = solarized
theme.midnight.dark.background = #101018

bind.equalize-panes = ctrl+cmd+e
bind.command-palette = cmd+shift+p
```

**Darstellung ▸ Themeneditor…** öffnet Farbwähler und getrennte Vorschauen für Hell und Dunkel.
**Einstellungen ▸ Erscheinungsbild ▸ Cursor** wählt Block, Strich oder Unterstrich sowie einen unabhängigen Schalter
fürs Blinken; Standard ist ein nicht blinkender Block. System (monospaced) ist die einzige unterstützte Hauptschrift,
mit einstellbarer Größe und Systemersatz für fehlende Zeichen. **Einstellungen ▸ Terminal ▸ Untere Statusleiste**
aktiviert auswählbare lokale Messwerte (standardmäßig aus); klicke darauf für Hostdetails oder verwende
**Darstellung ▸ Lokale Hostdetails…**. Die Schritte, die Auswahl der Netzwerkschnittstelle und die Grenzen des
Wärmezustands beschreibt die [Anleitung zur Personalisierung](USER-GUIDE.md#personalizing-the-terminal).

Die [Konfigurationsreferenz](../../CONFIGURATION.md) (Englisch) listet jeden Schlüssel, jeden Standardwert und wann
Änderungen wirksam werden. Das [Benutzerhandbuch](USER-GUIDE.md) führt durch jede Funktion und zeigt, wo sie zu finden ist.

## Aus dem Quellcode bauen

```sh
git clone https://github.com/noah-qin/Corta.git && cd Corta
swift test --package-path CortaTerminal                     # nur der Terminal-Kern, ohne App
xcodebuild -project Corta.xcodeproj -scheme 'Corta (Dev)' build  # eine Entwicklungs-App neben deinem installierten Corta
```

Der [Leitfaden für Mitwirkende](../../../CONTRIBUTING.md) (Englisch) nennt die Voraussetzungen (macOS 26, Apple Silicon, das
Xcode aus [`.xcode-version`](../../../.xcode-version)), lokales Signieren und eine Übersicht über das Repository; der
[Testleitfaden](../../TESTING.md) (Englisch) sagt, welche Prüfung jede Änderung braucht.

## Qualität, mit Belegen

Corta wird aktiv entwickelt und hat bekannte Probleme. Diese Messungen sind Momentaufnahmen, keine Garantien für jede
Maschine oder Arbeitslast. Jede Zeile nennt das Release, auf dem gemessen wurde.

| Prüfung | Gemessenes Ergebnis | Gemessen auf | Beleg |
| :--- | :--- | :--- | :--- |
| Kerndurchsatz (Parser, Raster und Verlauf; ohne PTY oder Rendering) | **317,3 MiB/s**, vorher 137,2 | 1.2 vs. 1.1 | [Performance §5.14](../../PERFORMANCE.md#514-scrolling-without-per-line-screen-allocation-281-283) |
| Durchsatz Parser + Raster | **355,9 MiB/s**, vorher 158,0 | 1.2 vs. 1.1 | ebenda |
| Speicher für Verlauf, 100.000 × 120 Zeilen | **11,4 MiB**, vorher 185 | 1.2 vs. 1.1 | [Performance §5.6](../../PERFORMANCE.md#56-numbers-by-release) |
| Bereichsscrollen, CPU pro Frame, p50 | **0,026 ms**, vorher 0,130 | 1.2 vs. 1.1 | [Performance §5.14](../../PERFORMANCE.md#514-scrolling-without-per-line-screen-allocation-281-283) |
| Frame-CPU, 120 × 40 kompletter Neuaufbau, Release | **0,37–0,39 ms** | 1.2 | [Performance §5.17](../../PERFORMANCE.md#517-full-screen-without-the-compositor-285-2026-10-13) |
| Tastendruck bis Bildschirm, Vollbild, ein Bereich, 60 Hz, ein tippender Mensch | p50 **49,1–50,8 ms**, p99 82,9–84,2 ms (vorher p50 64–68 ms) | 1.2 | [Performance §5.17](../../PERFORMANCE.md#517-full-screen-without-the-compositor-285-2026-10-13) |
| CPU im Leerlauf, Release, 20 Sekunden | 0,05 % | **1.0.0** (2026-09-18); seit der Leerlauf-Optimierung in 1.2 nicht erneut gemessen | [Performance](../../PERFORMANCE.md) |
| esctest2 | 131 bestanden, 334 bekannte Fehler, 102 fehlgeschlagen; insgesamt 567 | **1.1.5** (2026-10-07) | [Rohdaten](https://github.com/noah-qin/Corta/blob/f632d5918653cc2feee28fe1baa0c0fd01e93c0e/docs/esctest/2026-10-07-results.txt) |

Gemessen auf einem Apple M5 MacBook Air (macOS 27.0.1); die Zeilen zu 1.2 zwischen 2026-10-09 und 2026-10-13, jedes
Vorher-Nachher-Paar auf derselben Maschine und mit derselben Toolchain. Die datierten Abschnitte von
[Performance](../../PERFORMANCE.md) (Englisch) enthalten die Bedingungen, jeden Lauf und das, was eine Zahl nicht belegt.
Die manchmal zitierten 82,0 % bei esctest2 zählen Bestandene **plus bekannte Fehler** und sind keine Bestehensquote; zur
Einordnung siehe [Conformance](../../CONFORMANCE.md) (Englisch).

Zu den bekannten Einschränkungen gehören eine Latenz vom Tastendruck bis zum Bildschirm über dem Ziel von einem Frame im
Fenster (Vollbild mit einem Bereich kommt am nächsten), unvollständige VT-Konformität, mitgelieferte Shell-Integration
nur für zsh, bash und fish sowie Kitty-Grafik nur per direkter Übertragung. Die
[Referenz der Einschränkungen](../../FEATURES.md#known-limits) (Englisch) hat die Details.

## Orientierung

| Ich möchte … | Hier beginnen |
| :--- | :--- |
| Jede Funktion kennenlernen und wissen, wo sie ist | [Benutzerhandbuch](USER-GUIDE.md) |
| Corta konfigurieren | [Configuration](../../CONFIGURATION.md) (Englisch) |
| Eine Funktion oder Einschränkung verstehen | [Features](../../FEATURES.md) (Englisch) |
| Ein Problem diagnostizieren | [Fehlerbehebung](TROUBLESHOOTING.md) |
| Von iTerm2, Ghostty oder Terminal.app umsteigen | [Von einem anderen Terminal umsteigen](USER-GUIDE.md#coming-from-another-terminal) |
| Sehen, was geplant ist, oder etwas vorschlagen | [Open issues](https://github.com/noah-qin/Corta/issues) · [Discussions → Ideas](https://github.com/noah-qin/Corta/discussions/categories/ideas) |
| Etwas zum Mitarbeiten finden | [Good first issues](https://github.com/noah-qin/Corta/labels/good%20first%20issue) · [Help wanted](https://github.com/noah-qin/Corta/labels/help%20wanted) |
| Einen ersten Beitrag leisten | [Contributing](../../../CONTRIBUTING.md) (Englisch) |
| Tests ausführen oder hinzufügen | [Testing](../../TESTING.md) (Englisch) |
| Den Code verstehen | [Architecture](../../DESIGN.md) · [Core API](../../../CortaTerminal/Sources/CortaTerminal/CortaTerminal.docc/CortaTerminal.md) (Englisch) |
| Die gesamte Dokumentation lesen | [Dokumentationsindex](../../README.md) (Englisch) |

## Mitwirken

Fehlerreproduktionen, Dokumentation, Übersetzungen, Barrierefreiheitstests und Code-Beiträge sind willkommen. Beginne
mit einem [good first issue](https://github.com/noah-qin/Corta/labels/good%20first%20issue) oder einem
[help wanted](https://github.com/noah-qin/Corta/labels/help%20wanted) und lies [CONTRIBUTING.md](../../../CONTRIBUTING.md) für
Einrichtung und Review-Erwartungen. Für die Teilnahme an der Community gilt der [Verhaltenskodex](../../../CODE_OF_CONDUCT.md).

Corta ausprobiert und zu deinem alten Terminal zurückgekehrt? Auch das ist hörenswert:
Das [Went-back-Formular](https://github.com/noah-qin/Corta/issues/new?template=went_back.yml)
braucht keine Reproduktion, und „es hat sich einfach nicht richtig angefühlt“ ist eine gültige Antwort.

Melde Sicherheitslücken über den [privaten Sicherheitskanal](../../../SECURITY.md).
Um mit anderen Nutzern und dem Maintainer zu chatten, tritt dem [Discord](https://discord.gg/QNdWfdwr7j) bei.
Für Fragen zur Nutzung, deren Antworten auch andere finden sollen, geh zu [Discussions → Q&A](https://github.com/noah-qin/Corta/discussions/categories/q-a);
um ein Thema oder ein Setup zu teilen, zu [Show and tell](https://github.com/noah-qin/Corta/discussions/categories/show-and-tell).
Für andere Probleme [öffne ein Issue](https://github.com/noah-qin/Corta/issues/new/choose).

### Sponsern

Corta wird von einer Person entwickelt und gepflegt, öffentlich. Wenn es Teil deines Alltags geworden ist, hält ein
Sponsoring es in Bewegung – jeder Betrag hilft.

<a href="https://github.com/sponsors/noah-qin"><img src="https://img.shields.io/badge/Sponsor_noah--qin_on_GitHub-%E2%9D%A4-db61a2?style=for-the-badge&logo=githubsponsors&logoColor=white" alt="noah-qin auf GitHub sponsern"></a>

### Mitwirkende

Danke an alle, die zu Corta beigetragen haben.

<a href="https://github.com/noah-qin"><img src="https://github.com/noah-qin.png?size=96" width="48" height="48" alt="noah-qin" title="noah-qin"></a>
<a href="https://github.com/FrankChen-CLC"><img src="https://github.com/FrankChen-CLC.png?size=96" width="48" height="48" alt="FrankChen-CLC" title="FrankChen-CLC"></a>

## Lizenz und Identität

Der Quellcode steht unter der [Apache-2.0-Lizenz](../../../LICENSE). Für den Namen Corta, das Schuppentier-Maskottchen und das
App-Symbol gelten gesonderte Bedingungen in [NOTICE](../../../NOTICE). Der eingerollte Körper des Schuppentiers bildet ein C;
sein cyanfarbener Schwanz ist ein Terminal-Cursor. Die [Markenmaterialien](../../brand/README.md) enthalten das
Maskottchen und die Social-Media-Vorschau.
