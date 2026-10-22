# Benutzerhandbuch

[Dokumentationsindex (Englisch)](../../README.md) · [Projektübersicht](README.md)

🇺🇸 [English](../../USER-GUIDE.md) · 🇨🇳 [简体中文](../zh-CN/USER-GUIDE.md) · 🇭🇰 [繁體中文](../zh-Hant/USER-GUIDE.md) · 🇯🇵 [日本語](../ja/USER-GUIDE.md) · 🇰🇷 [한국어](../ko/USER-GUIDE.md) · 🇩🇪 [Deutsch](USER-GUIDE.md) · 🇫🇷 [Français](../fr/USER-GUIDE.md) · 🇪🇸 [Español](../es/USER-GUIDE.md) · 🇧🇷 [Português](../pt-BR/USER-GUIDE.md)

> Diese Seite ist eine Übersetzung von [USER-GUIDE.md](../../USER-GUIDE.md) mit dem Stand von Commit
> [`6d71b21`](https://github.com/noah-qin/Corta/blob/6d71b211e36e977f9250f45df1ccf10dde8fde2f/docs/USER-GUIDE.md).
> Wurde die englische Fassung seitdem geändert oder weichen die beiden ab, gilt die englische.
> Namen in der Oberfläche folgen Cortas deutscher Oberfläche; Konfigurationsschlüssel, Befehle und Code bleiben im Original.

Alles, was Corta kann, und wie du es erreichst. Jeder Abschnitt sagt, wo die Funktion zu finden ist – ein Menü, ein
Kurzbefehl, eine Einstellung – und verweist auf die Referenz mit den Details. Die Kurzbefehle sind die Standardwerte,
und alle außer „Nächsten suchen“ und „Vorherigen suchen“ lassen sich ändern ([Tastaturkurzbefehle](#keyboard-shortcuts)).

- [Installieren und aktualisieren](#install-and-update)
- [Von einem anderen Terminal umsteigen](#coming-from-another-terminal)
- [Fenster, Tabs und Bereiche](#windows-tabs-and-panes)
- [Text, Schriften und Themen](#text-fonts-and-themes)
- [Das Terminal personalisieren](#personalizing-the-terminal)
- [Wenn eine Sitzung endet](#when-a-session-ends)
- [Verlauf, Suche und Auswahl](#scrollback-search-and-selection)
- [Links und Dateiverweise](#links-and-file-references)
- [Shell-Integration](#shell-integration)
- [Das Arbeitsverzeichnis](#the-working-directory)
- [Verzeichnisvorschläge (zsh)](#directory-suggestions-zsh)
- [Arbeiten aus der Ferne: SSH und SFTP](#remote-work-ssh-and-sftp)
- [Bilder im Terminal](#images-in-the-terminal)
- [Die Befehlspalette](#the-command-palette)
- [Das Schnellterminal](#the-quick-terminal)
- [macOS-Integration](#macos-integration)
- [Geschwindigkeit und Akku](#speed-and-battery)
- [Einstellungen und die Konfigurationsdatei](#settings-and-the-config-file)
- [Tastaturkurzbefehle](#keyboard-shortcuts)
- [Wenn etwas schiefgeht](#when-something-goes-wrong)

<a id="install-and-update"></a>

## Installieren und aktualisieren

Corta braucht **macOS 26.0 oder neuer**, **Apple Silicon** und eine **Metal-4-fähige GPU**. Eine virtuelle Maschine mit
paravirtualisierter GPU kann das Terminal nicht darstellen. Lade die `.dmg` und ihre `.sha256`-Datei von
[GitHub Releases](https://github.com/noah-qin/Corta/releases/latest) herunter, lege beide in denselben Ordner und prüfe
dort die Prüfsumme, bevor du das Image öffnest (ersetze `x.y.z` durch die heruntergeladene Version):

```sh
shasum -a 256 -c Corta-x.y.z.dmg.sha256
open Corta-x.y.z.dmg
```

Ziehe Corta in „Programme“ und wirf das Image dann aus. Releases ab 1.1.9 sind Disk-Images; 1.1.8 und älter behalten
ihre ursprünglichen ZIPs.

Offizielle Releases sind mit Developer ID signiert und notarisiert. Lehnt macOS einen Download ab, folge der
[Fehlerbehebung](TROUBLESHOOTING.md#installing). Von einem anderen Ort gestartet, bietet Corta an, sich nach
`/Applications` zu verschieben (`suggest-applications-folder`).

**Updates.** **Corta ▸ Nach Updates suchen…** prüft sofort; eine Hintergrundprüfung läuft einmal am Tag, sofern nicht
`update-auto-check = false` gesetzt ist. Ein Update wird nur installiert, wenn du zustimmst.

<a id="coming-from-another-terminal"></a>

## Von einem anderen Terminal umsteigen

Corta hat keinen Import: Es liest eine Textdatei, `~/.config/corta/config`, und das Einstellungsfenster bearbeitet
dieselbe Datei. Die meisten Gewohnheiten lassen sich mit einer Handvoll Schlüssel übernehmen. Die linke Spalte nennt,
wo die Gewohnheit anderswo zu Hause ist; die rechte den Corta-Schlüssel ([Configuration](../../CONFIGURATION.md), Englisch,
hat die Werte und wann sie gelten).

| Wenn du dich verlassen hast auf … | In Corta |
| :--- | :--- |
| ⌥ als Meta / Alt (iTerm2: *Left Option key: Esc+*, Ghostty: `macos-option-as-alt`) | `option-as-meta = true`. Standardmäßig aus, damit ⌥ wie unter macOS `é`, `ø` und `–` tippt. |
| Kopieren beim Auswählen | `copy-on-select`, standardmäßig **an**. Setze `false`, um nur mit ⌘C zu kopieren. |
| Ein Hotkey-Fenster oder Schnellterminal | `quick-terminal = true`; die Taste ist `quick-terminal-key` (Standard ⌥Leertaste). Standardmäßig aus: Ein globaler Hotkey wird in jeder App belegt. [Das Schnellterminal](#the-quick-terminal). |
| Programme, die über `ssh` oder aus `tmux` in die Zwischenablage kopieren (OSC 52) | `allow-clipboard-write = true`. Standardmäßig aus; Lesen der Zwischenablage ist mit keiner Einstellung möglich. |
| Nachfrage vor dem Schließen eines beschäftigten Fensters | `confirm-close`, standardmäßig an. |
| Fenster, die dort wieder aufgehen, wo du sie verlassen hast | `restore-windows`, standardmäßig an. Layouts, Tabs und Arbeitsverzeichnisse kommen zurück; Prozesse und Terminaltext nicht. |
| Dein eigenes Farbschema | Ein in der Datei definiertes Thema (`theme.<name>.*`) oder **Darstellung ▸ Themeneditor…**. [Themen erstellen und bearbeiten](#creating-and-editing-themes). |
| Deine eigenen Tastenbelegungen | `bind.<command> = <shortcut>`. Die Befehlsnamen stehen unter [Tastaturkurzbefehle](#keyboard-shortcuts). |
| Eine Schrift deiner Wahl | **Einstellungen ▸ Erscheinungsbild ▸ Schrift** oder `font-family`. Angeboten werden nur Festbreitenschriften, die Corta in sein Raster setzen kann. |
| Ligaturen, Transparenz oder profilbezogene Einstellungen | Nicht verfügbar; sie werden [nicht ausgeliefert](../../CONFIGURATION.md#6-what-is-deliberately-not-configurable), und jede braucht zuerst eine Entscheidung. Voreinstellungen decken Shell, Verzeichnis und Umgebung ab ([Presets](../../CONFIGURATION.md#4a-presets)). |
| `tmux -CC`-Steuermodus | Nicht unterstützt (D09). Gewöhnliches `tmux` läuft in Corta wie jedes andere Programm. |

**Shell-Integration.** Standardmäßige lokale zsh-Sitzungen laden Cortas Hooks, ohne deine Startdateien anzufassen.
Wenn deine `~/.zshrc`, `~/.bashrc` oder `config.fish` noch die Integration eines anderen Terminals lädt – die von iTerm2,
WezTerm oder Visual Studio Code –, meldet **Einstellungen ▸ Terminal ▸ Shell-Integration** einen möglichen Konflikt;
beide können Prompt-Markierungen ausgeben. Siehe [Shell-Integration](#shell-integration).

**`TERM`.** Corta meldet sich als `xterm-256color` (D08). Ein entfernter Host, der schon mit iTerm2 oder Terminal.app
funktioniert, braucht nichts Neues; einer, der für `xterm-ghostty` oder `xterm-kitty` eingerichtet ist, bekommt
stattdessen den gängigen Wert.

Kleinere Unterschiede im Verhalten – Kopieren, Schließen, der Hotkey des Schnellterminals, Remote-Kennzeichen – sind unter
[Fehlerbehebung → Verhalten, das sich von anderen Terminals unterscheidet](TROUBLESHOOTING.md#behaviour-that-differs-from-other-terminals)
gesammelt.

<a id="windows-tabs-and-panes"></a>

## Fenster, Tabs und Bereiche

| Um … | Verwende |
| --- | --- |
| Ein Fenster / einen Tab öffnen | ⌘N / ⌘T |
| Vorheriger / nächster Tab | ⇧⌘[ / ⇧⌘] |
| Den aktuellen Tab umbenennen | Doppelklick auf den Tabtitel oder Rechtsklick ▸ Tab umbenennen… |
| Den Bereich nach rechts / unten teilen | ⌘D / ⇧⌘D |
| Den Fokus zwischen Bereichen bewegen | ⌥⌘ + Pfeiltaste |
| Die Größe des fokussierten Bereichs ändern | ⌃⌘ + Pfeiltaste |
| Das Fenster mit einem Bereich füllen und zurück | ⇧⌘↩ (Bereich vergrößern) |
| Alle Bereiche gleich groß machen | Bereiche gleichmäßig aufteilen (Befehlspalette) |
| Bereich, Tab oder Fenster schließen | ⌘W |
| Den gerade geschlossenen Bereich zurückholen | ⇧⌘T |

- Benenne einen Tab direkt in seinem Titel um: per Doppelklick oder mit „Tab umbenennen…“ aus seinem Kontextmenü.
  Return speichert, Esc bricht ab, und ein leerer Name stellt den automatischen Titel wieder her. Eigene Namen
  überstehen Shell-Ausgaben und das Wiederherstellen von Sitzungen. Die Kontextmenüs von Tab und Terminal bieten auch
  „Neuer Tab“, und die Taste **+** in der Symbolleiste öffnet einen Tab, ob die Tableiste sichtbar ist oder nicht;
  die Tableiste hat kein eigenes **+**.
- **Bereich vergrößern** ist vorübergehend: Nichts wird geschlossen, kein Prozess gestört.
- **Geschlossenen Bereich wieder öffnen** stellt Position, Größe und Arbeitsverzeichnis des Bereichs wieder her – nicht
  das Programm, das darin lief.
- Das Schließen eines Bereichs, in dem noch ein Befehl läuft, fragt zuerst nach (`confirm-close`).
- **Fenster wiederherstellen.** Beende Corta und starte es neu, und jedes Fenster kommt mit seinen Tabs, Teilungen,
  Trennlinienpositionen und dem Arbeitsverzeichnis jedes Bereichs zurück (`restore-windows`, standardmäßig an).
  Jeder Bereich startet einen neuen Prozess; Terminaltext und laufende Jobs werden nicht wiederhergestellt.
  Das Schnellterminal ist ausgenommen.
- **Voreinstellungen.** Eine Voreinstellung ist eine benannte Kombination aus Shell, Verzeichnis und Umgebung, definiert
  in der Konfigurationsdatei. **Shell ▸ Neuer Bereich mit Voreinstellung** öffnet eine; halte ⌥ gedrückt, um sie in
  einem eigenen Fenster zu öffnen ([Presets](../../CONFIGURATION.md#4a-presets)).
- Neue Fenster öffnen sich mit `columns` × `rows` Zellen (standardmäßig 120 × 30).

<a id="text-fonts-and-themes"></a>

## Text, Schriften und Themen

- **Schrift.** Einstellungen ▸ Erscheinungsbild ▸ Schrift listet System (monospaced) (Standard) und jede installierte
  Festbreitenschrift, die Corta in sein Raster setzen kann, in zwei Gruppen: Apple-Schriften (mit macOS ausgeliefert
  oder Apples bei Bedarf geladene Schriften, sobald sie in der Schriftsammlung heruntergeladen sind) und Von dir
  installiert. Die Zeile unter dem Menü sagt, woher die gewählte Schrift stammt und ob sie eigene CJK-Zeichen mitbringt –
  eine solche Schrift zeichnet auch Buchstaben und Symbole in ihrem CJK-Design, etwa eine erhöhte `~`. `font-family` in
  der Konfigurationsdatei ist dieselbe Einstellung. `font-size` ist standardmäßig 13 pt, 10–24 pt in ganzen Punkten.
  Die Seite zeigt eine Vorschau von Schrift, Farben und Cursor.
- **Schriftstärke und Zeilenabstand.** Die Schriftstärke ist Leicht, Normal (Standard) oder Mittel; eine Schrift ohne
  diese Stärke verwendet ihre normale, und fetter Text ist immer der eigene Fettschnitt der Schrift. Der Zeilenabstand
  beträgt das 1,0- bis 1,4-Fache der Schriftgröße, standardmäßig 1,18; eine Schrift, die eine höhere Zeile braucht,
  behält sie, damit nichts abgeschnitten wird. Jedes Zeichen in jeder Sprache teilt eine Zellgröße und eine Grundlinie.
- **Zeichen, die der Schrift fehlen.** Chinesisch, Japanisch und Koreanisch kommen aus macOS’ eigenen Schriften: Han-Zeichen
  je nach Systemsprache aus PingFang SC, PingFang TC, Hiragino Sans oder Apple SD Gothic Neo, Kana aus Hiragino Sans und
  Hangul aus Apple SD Gothic Neo, unabhängig von der Sprache. Um sie in einer eigenen Schrift zu zeichnen – etwa Menlo für
  Buchstaben und Sarasa Gothic oder LXGW WenKai für Chinesisch –, wähle sie unter **CJK-Schrift** (`font-family-cjk`).
  Jede installierte Schrift mit chinesischen, japanischen oder koreanischen Zeichen wird aufgeführt, ob festbreit oder
  nicht: Sie zeichnet nur diese Zeichen, zentriert in ihren zwei Zellen, und die Hauptschrift behält die Zellgröße.
  Emoji kommen aus Apple Color Emoji – oder, wenn Emoji auf „Wenn möglich einfarbig“ steht, als Textglyphe, sofern
  Apple Symbols oder Menlo eine hat. Ein breites Zeichen wird in seinen zwei Zellen zentriert. Schalte
  **Fehlende Zeichen aus anderen Schriften** aus, um nur die gewählte Schrift zu sehen, mit einem Kästchen, wo ihr
  eine Glyphe fehlt.
- **Zeichen mit mehrdeutiger Breite.** Einstellungen ▸ Terminal ▸ Zeichen mit mehrdeutiger Breite macht `±`, `§`,
  Griechisch, Kyrillisch und die übrigen „East Asian Ambiguous“-Zeichen zwei Zellen breit, für Software, die für
  CJK-Terminals geschrieben wurde. Das gilt für danach geschriebene Ausgabe; eine Shell oder ein Editor, der Text selbst
  vermisst, zählt sie womöglich weiterhin als eine Zelle.
- **Unterstreichungen.** Programme können einfache, doppelte (`SGR 21` oder `4:2`) und gewellte (`SGR 4:3`, Neovims
  Diagnosen) Unterstreichungen zeichnen; gepunktete und gestrichelte werden einfach gezeichnet. Blinkender Text
  (`SGR 5`) bleibt erhalten, wird aber nicht animiert.
- **Zoom.** ⌘= / ⌘− / ⌘0 oder eine Zoomgeste machen den Text größer, kleiner oder wieder so groß wie konfiguriert –
  nur im aktuellen Fenster. Zoomen ändert nie die Konfigurationsdatei. Schriftänderungen verschieben das Fenster nie und
  ändern nie seine Größe: Die sichtbaren Zeilen und Spalten passen sich ihm an, und was von einer Zelle übrig bleibt,
  erscheint als Hintergrund unter der letzten Zeile.
- **Thema.** Drei eingebaute Themen, `corta`, `solarized` und `mono`, jeweils mit heller und dunkler Variante;
  `appearance = auto` folgt macOS beim Umschalten. Über **Darstellung ▸ Themeneditor…** oder in der
  Konfigurationsdatei kannst du ein eigenes Thema definieren oder von einem erben und ein paar Farben ändern
  ([Themes](../../CONFIGURATION.md#4-themes)).
- **Unicode.** Chinesischer, japanischer und koreanischer Text belegt zwei Spalten und richtet sich mit allem anderen aus;
  Emoji, kombinierende Zeichen, Flaggen und Emoji-Sequenzen sind jeweils ein Cluster. Zeichen, die der Schrift fehlen,
  kommen aus den Ersatzschriften des Systems. Standardisierte Emoji-Darstellungssequenzen (ein Textzeichen gefolgt von
  VS16, wie ⚠️ oder ✍️) belegen zwei Spalten; die Textdarstellung bleibt schmal.
- **Eingabemethoden.** Pinyin, Kana, Hangul und jede andere Eingabemethode von macOS setzen direkt an Ort und Stelle
  zusammen, mit dem Kandidatenfenster neben dem Cursor.
- **Echtfarben.** 24-Bit-Farbe, die 256-Farben-Palette, fett, kursiv, unterstrichen, durchgestrichen, gedimmt und invertiert.
- **⌥ als Meta.** Standardmäßig aus, damit ⌥ die Zeichen der Tastaturbelegung tippt. Setze `option-as-meta = true` für
  Meta-Tasten im Emacs-Stil.
- **Signalton.** Ein Aufblitzen des Bereichs (`bell = visual`) oder ein Ton (`bell = audible`).

<a id="personalizing-the-terminal"></a>

## Das Terminal personalisieren

<a id="cursor-appearance"></a>

### Aussehen des Cursors

Öffne Einstellungen (⌘,) → Erscheinungsbild → Cursor. Wähle Block, Strich oder Unterstrich und aktiviere bei Bedarf
„Cursor blinken lassen“. Standard ist **Block, Blinken aus**. Die drei Formen und der unabhängige Schalter ergeben sechs
Kombinationen. In der Konfigurationsdatei heißen sie `cursor-shape` und `cursor-blink`. Änderungen gelten für offene
Bereiche. Terminalprogramme können über DECSCUSR vorübergehend eine eigene Form und ein eigenes Blinken wählen;
Parameter 0 oder ein Terminal-Reset kehrt zu deinen konfigurierten Standardwerten zurück. Das Blinken pausiert, solange
ein Bereich inaktiv, verborgen ist oder den Verlauf zeigt.

<a id="input-source-indicator"></a>

### Eingabequellenanzeige

Das fokussierte Terminal zeigt ein kleines Kennzeichen in der Symbolleiste oben rechts im Fenster: `A` für bestätigte
direkte Eingabe, `中` für Chinesisch, `あ` für Japanisch und `한` für Koreanisch. Andere Quellen zeigen ihren Sprachcode.
Fahre mit dem Zeiger darüber, um den vollständigen Namen der Quelle zu sehen. Ein neutrales Kennzeichen steht für Quellen,
deren internen Eingabemodus macOS nicht meldet, darunter IMEs von Drittanbietern mit eigenem Englisch-Umschalter.
Corta errät diesen Modus nie aus getipptem Text und ändert nie die Eingabequelle.

Einstellungen ▸ Tastatur & Maus ▸ Eingabequellenanzeige wählt **Automatisch** (Standard), **Immer im aktiven Bereich**
oder **Aus**. Der Standard zeigt die Anzeige nur bei Nutzern mit einer aktivierten nicht-lateinischen Tastaturbelegung
oder einem IME; rein lateinische Setups bleiben aufgeräumt. Beim Zurückschalten auf eine lateinische Belegung bleibt ein
dezentes `A` auf blassem Hintergrund – grau in der Symbolleiste, in der eigenen Textfarbe des Themas neben dem Prompt.
Nicht-lateinische Belegungen und eingebaute IME-Modi verwenden einen sanften Indigoton; unbekannte IME-Modi grau. Neben
dem Prompt folgen die Farben der Helligkeit des Terminalthemas statt der von macOS. In der Symbolleiste bleibt das
Kennzeichen, während ein Programm läuft – Claude Code, ein Editor –, da es keine Ausgabe verdeckt. Am rechten Rand der
Befehlszeile blendet die Shell-Integration es im Modus **Automatisch** während der Befehlsausführung aus. **Immer** kann
es während der Befehlsausgabe behalten. Beide Prompt-Modi blenden es aus, während du im Verlauf liest oder ein Programm
mit alternativem Bildschirm verwendest.

Die Einstellung **Position** wählt **Fenster-Symbolleiste** (Standard) oder **Rechter Rand der Befehlszeile**. Das
Kennzeichen in der Symbolleiste steht unabhängig von den Tasten zum Verbinden und für einen neuen Tab und bleibt an seinem Platz, wenn
Befehle länger werden oder umbrechen. Ausschalten oder die Platzierung an der Befehlszeile entfernt seinen Platz und
seinen Abstand in der Symbolleiste. An der Befehlszeile verschieben lange Befehle das Kennzeichen nach unten in freien
Platz, am rechten Rand; es verschwindet, wenn keine sichere Zeile bleibt, und fügt nie eine Zeile ein oder lässt das
Kindprogramm scrollen. Farben für direkte Eingabe und IME akzeptieren Hex-Werte; leere ein Feld für die dezente Standardgestaltung.

[Kennzeichen für chinesische Eingabequelle](../../brand/input-source-indicator.png) ·
[Ausweichen bei langen Befehlen](../../brand/input-source-long-command.png)

<a id="optional-local-system-status"></a>

### Optionaler lokaler Systemstatus

Öffne Einstellungen (⌘,) → Terminal, aktiviere die untere Statusleiste und wähle die Messwerte, die du sehen willst:
CPU-Auslastung, Systemlast, Speichernutzung, Netzwerkraten, freier Speicherplatz und Wärmezustand. Sie ist standardmäßig
aus; jeder Messwert hat einen eigenen Schalter. Klicke auf die Leiste, um Namen, macOS-Version, Chip, Kernanzahl und
Gesamtspeicher des lokalen Hosts zu sehen. Die Leiste zeigt auch in einem SSH-Bereich „Lokal“; sie überwacht keinen
entfernten Server. In schmalen Fenstern klickst du für alle gewählten Messwerte.

Die Netzwerkschnittstelle ist standardmäßig automatisch. Gemessen wird eine primäre Schnittstelle, sodass VPN-Verkehr
nicht zum physischen Verkehr addiert wird. Gib in den Einstellungen einen bestimmten Schnittstellennamen ein, um
stattdessen diesen zu messen. Die Abtastung stoppt, solange jede aktivierte Leiste verborgen ist. Der Wärmezustand ist
eine vierstufige Meldung von macOS, keine Gradzahl.

Die Leiste verwendet kompakte Beschriftungen, ein einzelnes Leerzeichen als Trenner und kurze Byte-Einheiten; vollständige
Namen und Genauigkeit stehen im Tooltip, im Bedienungshilfen-Wert und im Popover mit den Hostdetails.

<a id="creating-and-editing-themes"></a>

### Themen erstellen und bearbeiten

Einstellungen → Erscheinungsbild → Thema erstellen öffnet einen grafischen Editor. Benenne deine Kopie, wechsle zwischen
dunkler und heller Variante und ändere Farben mit Farbwählern oder HEX-Werten. Die Vorschau aktualisiert sich, ohne die
Terminalfenster zu ändern. „Thema speichern“ aktiviert es und speichert es dauerhaft; „Abbrechen“ behält dein bisheriges
Thema. Eigene Themen bieten „Thema bearbeiten“. „Quellfarben wiederherstellen“ setzt die aktuelle Variante zurück. Du kannst
dieselbe Konfigurationsdatei weiterhin von Hand bearbeiten. Ändert sich dieses eigene Thema außerhalb des Editors, öffne
den Editor vor dem Speichern erneut.

Darstellung → Themeneditor öffnet die grafische Farbbearbeitung direkt. Darstellung → Lokale Hostdetails zeigt die
Hostkonfiguration, ohne die optionale Statusleiste zu brauchen. Dieselbe Taste für Hostdetails gibt es unter
Einstellungen → Terminal. Die Vorschauen im Erscheinungsbild folgen ausdrücklichen Moduswechseln sofort und zeigen die
gewählte Cursorform und den Blinkstatus. Terminalprogramme können den Cursorstil weiterhin vorübergehend überschreiben.

<a id="compact-tab-indentation-zsh"></a>

### Kompakte Tab-Einrückung (zsh)

Standardmäßige lokale zsh-Sitzungen laden die mitgelieferten Hooks automatisch, wenn die Verzeichnisvorschläge
aktiviert sind (Standard). Du musst deine Startdateien nicht ändern. Wenn du eigene zsh-Argumente verwendest oder diesen
automatischen Start abgeschaltet hast, installiere oder aktualisiere die Shell-Integration unter Einstellungen →
Terminal und öffne dann eine neue Shell. Mit geladenen Hooks fügt Tab in einer Befehlszeile, die nur Leerraum enthält,
vier Leerzeichen ein. Tab nach Befehlstext behält die bestehende Vervollständigung. Das ist ein ZLE-Widget; die
Tabstopps der Terminalausgabe bleiben bei acht Spalten, und Vollbildprogramme erhalten weiterhin die Tab-Taste.
Ohne die Integration behält die Shell ihr eigenes Tab-Verhalten.

<a id="language"></a>

### Sprache

Die App folgt der bevorzugten Sprache, die macOS für Corta festlegt: Englisch, vereinfachtes und traditionelles
Chinesisch, Japanisch, Koreanisch, Deutsch, Französisch, Spanisch und brasilianisches Portugiesisch. Starte Corta neu,
nachdem du seine App-Sprache in macOS geändert hast. Zahlenformate folgen der aktuellen Region.

<a id="when-a-session-ends"></a>

## Wenn eine Sitzung endet

Ein Bereich behält seine Ausgabe, nachdem die Shell beendet wurde: Die Ausgabe wird leicht abgedunkelt, und ein Feld
sagt in einem Satz, was wie geendet hat – mit dem Exit-Code oder dem Signal, das es beendet hat. Der Cursor verschwindet,
aber Scrollen, Auswählen, Kopieren und die Suche mit ⌘F funktionieren rund um das Feld weiter. **Neue Sitzung** startet
die Shell oder Vorgabe im Bereich neu; **Bereich schließen** schließt ihn. Eine direkt verbundene SSH-Sitzung nennt den
Host, mit dem sie verbunden war, und bietet **Neu verbinden** für eine neue Verbindung; den Exit-Code 255 von ssh erklärt
sie als abgerissenes Netzwerk oder einen Host, der nicht mehr antwortet. Beide Tasten löschen die Ausgabe darüber – das
Feld sagt es –, und die neue Sitzung beginnt in der Größe und Schriftgröße des Bereichs. Wer Python oder ein anderes
Programm verlässt und in eine laufende Shell zurückkehrt, beendet die Terminalsitzung nicht.

Scheitern Ein- oder Ausgabe einer Sitzung oder zeichnet ein Bereich nicht mehr, bietet dasselbe Feld **Erneut versuchen**
oder, bei einer Verbindung, **Neu verbinden**; der Fehlertext des Systems steht unter **Details**.

![Beendete Sitzung mit ihrer letzten Ausgabe und Aktionen zur Wiederherstellung](../../brand/session-ended.png)

<a id="scrollback-search-and-selection"></a>

## Verlauf, Suche und Auswahl

- **Scrollen.** Trackpad oder Mausrad, oder ⇧Bild↑ / ⇧Bild↓, ⇧Pos1 / ⇧Ende. Jede Sitzung behält `scrollback-lines`
  Zeilen Verlauf (10.000).
- **Suche.** ⌘F öffnet die Suchleiste über dem Verlauf; ⌘G und ⇧⌘G springen zum nächsten und vorherigen Treffer.
  **Groß-/Kleinschreibung** und **`*`** (regulärer Ausdruck) werden dort umgeschaltet und merken sich ihren Zustand in der
  Konfigurationsdatei (`search-case-sensitive`, `search-regex`). Die Leiste sitzt oben rechts im Bereich und wandert nach
  unten, solange der Cursor oder der aktuelle Treffer darunter läge; in einer schmalen Teilung wird sie schmaler, statt
  den Bereich zu verdecken. Jeder Bereich hat seine eigene Leiste.
- **Auswählen.** Ziehen zum Auswählen, Doppelklick für ein Wort, Dreifachklick für eine Zeile. Eine fertige Auswahl wird
  sofort kopiert (`copy-on-select`); ⌘C kopiert ebenfalls. In einem Programm, das die Maus verwendet – `vim`, `htop` –,
  halte ⌥ beim Beginn des Ziehens gedrückt, um trotzdem Text auszuwählen (`mouse-override-modifier`).
- **Einfügen.** ⌘V. Eingefügter Text wird als Einfügung markiert (Bracketed Paste), sodass eine Shell, die das unterstützt –
  zsh, fish, bash 5.1 oder neuer –, einen eingefügten Befehl einsetzt, ohne ihn auszuführen, bis du Return drückst. Hat
  das Programm Bracketed Paste nicht aktiviert (macOS’ eigenes `/bin/bash` 3.2 tut das nie), warnt Corta vor dem Einfügen
  von Text, der einen Zeilenumbruch enthält. Eine große Einfügung, die die Shell noch abarbeitet, lässt sich mit ⌃C
  abbrechen: Der noch nicht gesendete Teil wird verworfen, und der Interrupt geht direkt durch.
- **Text exportieren …** (⇧⌘S) sichert die Auswahl – oder, ohne Auswahl, den gesamten Verlauf und Bildschirm – in eine Datei.
- **Löschen.** Drei Befehle, weil sie Verschiedenes verwerfen:

  | Befehl | Bildschirm | Verlauf | Modi und Farben |
  | --- | --- | --- | --- |
  | Bildschirm löschen (⌘K) | gelöscht | behalten | behalten |
  | Verlauf löschen | behalten | verworfen | behalten |
  | Terminal zurücksetzen | gelöscht | verworfen | zurückgesetzt |

  Verlauf löschen und Terminal zurücksetzen fragen zuerst und sagen, wie viele Zeilen sie verwerfen würden – außer
  der Verlauf ist leer oder `confirm-close = false` schaltet die Frage ab.

<a id="links-and-file-references"></a>

## Links und Dateiverweise

- **URLs** zeigen beim Darüberfahren ihr Ziel und den Hinweis auf ⌘-Klick und öffnen sich mit ⌘-Klick; setze
  `link-activation = click`, um sie stattdessen mit einem einfachen Klick zu öffnen. Halte ⌘ über einem Link – auch einem,
  den ein Programm ausdrücklich markiert (OSC 8, wie es `ls --hyperlink` ausgibt) –, um ihn zu unterstreichen und sein
  echtes Ziel als Tooltip zu sehen, bevor du klickst; der Klick selbst öffnet ihn sofort.
- **Dateiverweise.** Ein `path:line:column` in der Programmausgabe – ein Compilerfehler, ein fehlgeschlagener Test –
  öffnet sich per ⌘-Klick in deinem Editor. Sag Corta mit `open-file-command`, welcher Editor, beginnend mit seinem
  vollständigen Pfad, zum Beispiel
  `open-file-command = /usr/local/bin/code --goto {file}:{line}:{column}`
  ([Following a file reference](../../CONFIGURATION.md#following-a-file-reference)).

Das Öffnen eines Dateiverweises setzt ein konfiguriertes `open-file-command` voraus. Corta öffnet aus der Ausgabe
abgeleitete Dateien nie in ihrer Standard-App des Systems: Manche Dateitypen führen beim Öffnen Code aus.

<a id="shell-integration"></a>

## Shell-Integration

Mit der Shell-Integration sieht Corta, wo jeder Befehl beginnt und endet. Installiere sie über
**Einstellungen ▸ Terminal ▸ Shell-Integration**: Sie fügt einen markierten Block in die Startdatei deiner Shell ein –
`~/.zshrc`; für bash sowohl `~/.bashrc` als auch `~/.bash_profile` (oder welche Login-Datei bash auch liest); oder
`~/.config/fish/config.fish` –, und **Entfernen** nimmt genau diesen Block wieder heraus. Der Block in der Startdatei
wird nur installiert, wenn du die Taste drückst. Standardmäßige lokale zsh-Sitzungen laden Cortas mitgelieferte Hooks
außerdem automatisch, ohne deine Startdateien zu bearbeiten, wenn **Verzeichnisvorschläge (zsh)** aktiviert ist
(Standard). Eigene zsh-Argumente, bash, fish und entfernte Shells nutzen diesen automatischen Start nicht. Installiere in
diesen Shells kompatible Hooks, um dort Befehlsgrenzen zu erhalten.

Meldet die Einstellung eine veraltete Integration, wähle **Aktualisieren** und öffne eine neue Shell. Nur die App zu
aktualisieren ersetzt einen früher installierten Block in der Startdatei nicht.

Mit geladenen Hooks, ob automatisch oder über die Startdatei:

- **Prompt-Markierungen.** Eine dünne Linie links neben jedem Prompt, grün bei Erfolg des Befehls und rot bei Fehlschlag.
  Ein leeres Return zeichnet keine Linie und erzeugt keinen abgeschlossenen Eintrag im Befehlsverlauf.
- **Springen.** ⌘↑ / ⌘↓ springen zwischen Befehlen; ⇧⌘↑ / ⇧⌘↓ zwischen den fehlgeschlagenen.
- **Die Ausgabe eines Befehls.** Aus der Befehlspalette: **Ausgabe des letzten Befehls kopieren**,
  **Schnappschuss der laufenden Befehlsausgabe** (was ein Build bisher ausgegeben hat), **Befehlsausgabe exportieren…**
  in eine Datei und **Dateiverweis in Befehlsausgabe öffnen**, der das letzte ausgegebene `path:line` öffnet.
- **Befehlsverlauf.** **Befehlsverlauf durchsuchen…** listet jeden Befehl mit Zeit, Exit-Status und Verzeichnis;
  **Einfügen** setzt einen zurück an den Prompt, und **Ausführen** führt ihn erneut aus (`command-history-limit`). Ein
  Befehl, den die Liste nicht vollständig zeigen kann – mehrzeilig, am Zeilenrand abgeschnitten oder mit einem
  Tabulator –, oder einer, dessen Text sich geändert hat, seit die Liste ihn zeigte, wird eingefügt statt ausgeführt,
  sodass er vollständig am Prompt steht und auf dein Return hin läuft.
- **Benachrichtigungen bei langen Aufgaben.** Mit `notify-on-long-task = true` meldet sich ein Befehl, der länger als
  `notification-threshold` Sekunden (30) lief, beim Abschluss mit einer Mitteilung, **wenn sein Fenster nicht das
  Hauptfenster ist** – vorausgesetzt, macOS hat Corta die Erlaubnis für Mitteilungen erteilt. Aktiviere das unter
  Einstellungen ▸ Allgemein und prüfe dort den Status der Erlaubnis. Klicke auf die Mitteilung, um zum Befehl zu springen.

Ohne Shell-Integration sind diese Befehle deaktiviert, statt stillschweigend nichts zu tun, und Mitteilungen greifen auf
eine Schätzung anhand von Eingabe und Ausgabe zurück.

<a id="the-working-directory"></a>

## Das Arbeitsverzeichnis

Corta kennt das Verzeichnis, in dem deine Shell ist, wenn die Shell es meldet (die Shell-Integration tut das).
Aus der Befehlspalette:

- **Arbeitsverzeichnis im Finder anzeigen** und **Pfad des Arbeitsverzeichnisses kopieren**.
- **In übergeordnetes Verzeichnis wechseln** und **In Projekt-Stammverzeichnis wechseln** (der nächste Ordner mit `.git`)
  tippen das `cd` für dich – nur, wenn kein Befehl läuft und der Prompt leer ist.
- **Übergeordnetes Verzeichnis in neuem Bereich öffnen** und **Projekt-Stammverzeichnis in neuem Bereich öffnen** teilen
  den Bereich mit einer dort gestarteten Shell.

Das Ordnersymbol in der Titelleiste steht ebenfalls für das Verzeichnis: Ziehe es oder ⌘-klicke darauf, um den Pfad zu
sehen. Ist `directory-history` an (Standard), merkt sich Corta die lokalen Verzeichnisse, in denen deine Befehle liefen.
Noch listet nichts in der App sie auf; **Einstellungen ▸ Datenschutz & Sicherheit ▸ Verlauf** zeigt, wie viele es sind,
und löscht sie.

<a id="directory-suggestions-zsh"></a>

## Verzeichnisvorschläge (zsh)

Corta bringt Verzeichnisvorschläge mit, die in standardmäßigen lokalen zsh-Sitzungen aktiviert sind. Tippe `cd `, um die
Ordner im aktuellen Verzeichnis als blassen Text unter deiner Eingabe zu sehen. Tippe weiter, um die Ordner zu filtern;
neben dem Cursor erscheint ein blasses Suffix. So kann `cd De` zum Beispiel `Developer/` vorschlagen. Vorschläge sind
Vorschauen: Sie gehören nicht zu deinem Befehl, bevor du sie übernimmst.

![Verzeichnisvorschläge unter cd, mit Markierungen für erfolgreiche, fehlgeschlagene und abgebrochene Befehle](../../brand/directory-suggestions.png)

Solange ein Vorschlag sichtbar ist:

| Taste | Aktion |
| --- | --- |
| Links / Rechts | Den vorherigen / nächsten Ordner wählen, statt den Eingabecursor zu bewegen. |
| Tab | Das gewählte Verzeichnis in die Eingabe übernehmen; nicht ausführen. Ersetzt die native Tab-Vervollständigung, solange Vorschläge sichtbar sind. |
| Esc | Die Vorschläge für die aktuelle Eingabe schließen. Drücke Esc, bevor du mit Links / Rechts den Befehl bearbeitest, oder noch einmal für die eigene Esc-Aktion der Shell. |
| Hoch / Runter | Die normale Navigation im Befehlsverlauf der Shell beibehalten. |
| Umschalt+Tab | An die in der Shell konfigurierte Belegung durchreichen. |
| Return | Nur die tatsächliche Eingabe ausführen; nie automatisch einen blassen Vorschlag übernehmen. |

Du kannst relative Pfade, Unterverzeichnisse und `~/`-Pfade filtern. Versteckte Ordner erscheinen, wenn du einen Punkt
voranstellst. Komplexe Shell-Ausdrücke behalten die native Vervollständigung. Bash und fish behalten ihre eigene
Vervollständigung; Vorschläge erscheinen nur in einer Shell, die Corta mit seinen automatischen zsh-Hooks gestartet hat,
nie auf entfernten Rechnern oder in eigenen Shell-Befehlen, selbst bei installierter Shell-Integration.

**Optional: ausschalten.** Schalte in **Einstellungen ▸ Terminal ▸ Shell** die Option **Verzeichnisvorschläge (zsh)**
aus oder setze in deiner Konfigurationsdatei:

```ini
directory-completion = false
```

Das deaktiviert Cortas Vorschläge und das Abfangen von Tasten sofort, und das native Bearbeiten und Vervollständigen der
Shell steht wieder zur Verfügung. Öffne die Shell neu, nachdem du es wieder aktiviert hast. Für die automatischen lokalen
Hooks gibt es keinen Block in einer Startdatei zu löschen. Hast du die Shell-Integration zusätzlich manuell installiert,
entfernt ihre Taste **Entfernen** diesen separaten Block; zum Abschalten der Verzeichnisvorschläge ist das nicht nötig.

<a id="remote-work-ssh-and-sftp"></a>

## Arbeiten aus der Ferne: SSH und SFTP

Corta verwendet das OpenSSH des Systems – deine `~/.ssh/config`, Schlüssel, Agent und `ProxyJump` gelten alle – und hat
keine eigene SSH-Implementierung.

- **Das Host-Kennzeichen.** Ein Bereich, der mit einem anderen Rechner verbunden ist, zeigt *Entfernt:* am Anfang des
  Fenstertitels. Es nennt Host und Ordner, wenn die entfernte Shell sie meldet (dort ist die Shell-Integration
  installiert), und das von dir eingegebene Ziel, wenn die Verbindung aus dem Verbindungsdialog kam; sonst sagt es, dass
  der Bereich entfernt ist, ohne zu wissen, welcher Host.
- **Neu verbinden.** Endet eine `ssh`- oder `mosh`-Sitzung, führt **Erneut mit Host verbinden** denselben Befehl als neue
  Verbindung noch einmal aus.
- **Verbinden.** Die Globustaste der Symbolleiste öffnet **Mit Host verbinden**, einen Dialog mit einem Umschalter
  **Terminal / Dateien (SFTP)**: ein Terminal über SSH oder der Datei-Browser. Tippe den Host – einen Namen, eine Adresse,
  `user@host` oder einen SSH-Alias. **Erweitert** enthält Benutzer, Port und privaten Schlüssel; leer entscheiden deine
  `~/.ssh/config` und die Standardwerte von OpenSSH. Ein gewählter Schlüssel wird zuerst angeboten, und andere Schlüssel
  im `ssh-agent` werden nicht versucht. Der Dialog listet deine jüngsten Verbindungen – mit Port, Schlüssel und wann du
  sie zuletzt genutzt hast – und die `Host`-Namen aus deiner `~/.ssh/config`. Hosts, die nur Git annehmen (`github.com`
  oder ein `Host` mit `User git`), fehlen, und die Liste sagt, welche. Tippe, um die Liste einzugrenzen, klicke auf einen
  Eintrag (oder nutze ↑ und ↓ im Host-Feld), um die Felder zu füllen, und doppelklicke oder drücke Return, um zu
  verbinden. Eine Terminalverbindung kommt erst in die Liste, wenn sie steht – ein Host, der dich abweist oder keine
  Shell hat, nicht. Fahre mit dem Zeiger über einen jüngsten Host und klicke ✕, oder rechtsklicke ihn, um ihn zu
  vergessen; Einstellungen ▸ Datenschutz & Sicherheit ▸ Zuletzt verbundene Hosts löscht alle.
- **Dateien dieses Bereichs.** Aus einem Bereich geöffnet, der mit einem anderen Rechner verbunden ist, bietet der Dialog
  zuerst die Dateien dieses Hosts an; drücke Return oder **Dateien durchsuchen**, um sie zu öffnen.
- **Entfernte Dateien durchsuchen …** öffnet einen SFTP-Browser für den Host des Bereichs: auflisten, hochladen,
  herunterladen, umbenennen und löschen. Die erste Verbindung zu einem Host bittet dich, den Hostnamen zu bestätigen.
  Übertragungen werden nach einer Unterbrechung fortgesetzt und überschreiben nie ohne Nachfrage eine Datei.
  Ein Ordner-Download stoppt, wenn ein Name mit einer `.corta-part`-Zwischendatei kollidiert, und bewahrt die vorhandene
  Datei. Wähle ein anderes Ziel oder kläre diese Datei einzeln; ein ordnerweites Überschreiben kann keine Teildatei verschlucken.
- **Im Browser**, wie im Finder: ⌘[ und ⌘] gehen zurück und vor, ⌘↑ zum übergeordneten Ordner, ⌘R aktualisiert,
  ⇧⌘G (oder ein Klick auf den Pfad) tippt einen Pfad, ⇧⌘N legt einen Ordner an und ⇧⌘. zeigt unsichtbare Dateien.
  Klicke auf einen Spaltentitel zum Sortieren. Rechtsklicke eine Zeile für ihre Aktionen; doppelklicke einen Ordner, um
  ihn zu öffnen. Lege Dateien aus dem Finder auf der Liste ab – oder auf einer Ordnerzeile –, um sie hochzuladen; beim Ziehen wird die Liste (oder die Zeile) umrandet und nennt das Ziel. Ziehe eine Datei in den Finder, um sie herunterzuladen. Übertragungen findest du unter der Pfeiltaste der
  Symbolleiste, mit Geschwindigkeit, Restzeit und „Im Finder zeigen“.
- **Eine entfernte Datei bearbeiten.** **Bearbeiten** im Browser – oder ein ⌘-Klick auf ein `path:line` in einem
  entfernten Bereich – lädt eine Kopie herunter und öffnet sie in deinem Editor. Lege zuerst
  **Einstellungen ▸ Terminal ▸ Datei öffnen mit** fest, mit einem absoluten Pfad zum Editor und den Platzhaltern
  `{file}`, `{line}`, `{column}` ([Beispiele](../../CONFIGURATION.md#following-a-file-reference)). Das Hochladen deiner
  Änderungen ist ein eigener, ausdrücklicher Schritt, und Corta prüft zuerst, ob sich die entfernte Datei inzwischen
  geändert hat. Dateien über 64 MiB werden nicht auf diese Weise kopiert; lade sie über den Browser herunter, der den
  Fortschritt zeigt und abbrechen kann. Eine Kopie, die 30 Tage lang niemand geöffnet oder geändert hat, wird bei der
  nächsten Nutzung der Remote-Bearbeitung entfernt; eine mit Änderungen, die du weder hochgeladen noch verworfen hast, bleibt.
- **Namen.** Ein entfernter Name mit Steuerzeichen, Rechts-nach-links- oder Nullbreitenzeichen zeigt diese als `�`, und
  ein Download speichert sie als `_`, damit ein Name nicht als ein anderer durchgehen kann.

Fragt der Server nach einem Passwort, einer Schlüssel-Passphrase oder einem Einmalcode, oder ist ein Host neu und sein
Schlüssel braucht deine Entscheidung, fragt der Browser in einem Dialog auf seinem Fenster und reicht deine Antwort an
OpenSSH weiter; nichts wird gespeichert, sodass ein erneutes Verbinden wieder fragt. **Verbindung abbrechen** im
Passwort-Dialog beendet diesen Verbindungsversuch und kehrt zum Host-Feld zurück – es wird nicht als leeres Passwort
gesendet. **Abbrechen** bei der Passphrase eines Schlüssels überspringt nur diesen Schlüssel, und ssh versucht die
nächste Anmeldeart. Der Hostschlüssel-Dialog zeigt den Fingerabdruck und hat „Abbrechen“ als Standard. Ein Schlüssel im
`ssh-agent` oder im Schlüsselbund, oder eine bestehende `ControlMaster`-Verbindung aus deinem Terminal, meldet sich ohne
Nachfrage an.

Scheitert eine Verbindung, sagt sie in einem Satz, warum – Passwort oder Schlüssel nicht angenommen, Host antwortet
nicht, Hostschlüssel unbekannt oder geändert, der Server bietet kein SFTP –, mit den Worten von ssh unter **Details**,
und bietet **Erneut versuchen** oder **Verbindung bearbeiten**.

Uploads aus der Remote-Bearbeitung vergleichen neben Größe und Änderungszeit auch den entfernten Inhalt und senden den
privaten Schnappschuss, den du bestätigt hast. Sicherst du nach der Bestätigung eine weitere lokale Änderung, fragt Corta
erneut nach einer Entscheidung; Sicherungen während eines Uploads bleiben ausstehend. Nach einem Verbindungsfehler
verbindet die nächste Bearbeitung oder der nächste Upload neu, und ein fehlgeschlagener Upload behält seine ausstehende
Entscheidung. Ist die Verbindung aufgebaut, wird ein Vorgang, der nach 120 Sekunden nicht fertig ist,
abgebrochen und der Upload erneut angeboten – eine hängende Verbindung hält eine Bearbeitung nicht ewig fest. Bewahre unentschiedene lokale Änderungen auf, bevor du App-Daten löschst. Siehe die
[Richtlinie zu gespeicherten Daten](../../SECURITY.md#5-data-at-rest) (Englisch).

<a id="images-in-the-terminal"></a>

## Bilder im Terminal

Programme, die das **Kitty-Grafikprotokoll** sprechen, können Bilder direkt im Text zeigen:

```sh
kitten icat --transfer-mode=stream picture.png
```

Bilder scrollen mit dem Text, bleiben im Verlauf und werden zusammen mit dem umgebenden Text durch „Bildschirm löschen“
oder „Verlauf löschen“ entfernt. Innerhalb des Scrollbereichs eines Programms – etwa im Bereich eines Vollbildprogramms –
bewegt sich ein Bild mit dem Text des Bereichs und wird abgeschnitten, wo es über dessen Rand hinausscrollt. Ein Bild darf
bis zu 8192 Pixel pro Seite und insgesamt 16 Millionen Pixel groß sein. Andere Werkzeuge, die das Protokoll unterstützen,
etwa `timg` oder `chafa`, funktionieren ebenfalls, solange sie das Bild selbst senden: Corta weigert sich bewusst, einen
von einem Programm genannten Dateipfad zu lesen, und Animation wird nicht unterstützt. Ein Bild, das größer als der
Bereich ist, wird passend skaliert.

<a id="the-command-palette"></a>

## Die Befehlspalette

⇧⌘P öffnet die Befehlspalette: jeden Befehl, den Corta hat, nach Namen durchsuchbar, mit seinem Kurzbefehl daneben.
Tippe ein paar Buchstaben und drücke Return. Buchstaben passen in ihrer Reihenfolge, nicht unbedingt zusammenhängend
(`spr` findet Split Pane Right); auch der Name einer Gruppe (`panes`) oder der Konfigurationsname eines Befehls
(`new-tab`) findet ihn. Kürzlich ausgeführte Befehle stehen oben. Ein Klick auf ein anderes Fenster schließt die Palette
und lässt dieses Fenster vorne. Sie ist der schnellste Weg zu den Befehlen ohne Standard-Kurzbefehl.

<a id="the-quick-terminal"></a>

## Das Schnellterminal

Ein Terminal, das über das herunterfährt, woran du gerade arbeitest. Öffne es über **Darstellung ▸ Schnellterminal**,
über die Befehlspalette oder mit einem systemweiten Hotkey, sobald du einen einschaltest:

```ini
quick-terminal = true
quick-terminal-key = alt+space
quick-terminal-position = top      # top, bottom oder center
```

Der Hotkey ist standardmäßig aus, weil eine systemweite Taste jeder anderen App weggenommen wird.

<a id="macos-integration"></a>

## macOS-Integration

- **Kurzbefehle.** Drei Aktionen: **Corta-Fenster öffnen** (optional in einem Ordner), **Corta-Fenster in den Vordergrund**
  und **Schnellterminal ein-/ausblenden**. Keine davon führt einen Befehl in einer Shell aus.
- **Dienste.** Ausgewählter Terminaltext wird dem Menü **Dienste** angeboten.
- **Sichere Tastatureingabe.** **Shell ▸ Sichere Tastatureingabe** hindert andere Apps daran, deine Tastenanschläge zu
  lesen, während Corta vorne ist – zum Eintippen von Passwörtern. Ein Schloss in der Titelleiste zeigt, wann sie
  tatsächlich aktiv ist.
- **VoiceOver** liest den Text des Terminals vor und folgt dem fokussierten Bereich.
- **Zwischenablage aus Programmen.** Standardmäßig aus. Mit `allow-clipboard-write = true` darf ein Programm – auch eines
  in `tmux` oder über `ssh` – Text in deine Zwischenablage legen (OSC 52). Nichts darf ihn zurücklesen.

<a id="speed-and-battery"></a>

## Geschwindigkeit und Akku

Corta tut von selbst das Schnelle; nichts hier braucht eine Einstellung. Das ist es, was es tut, damit du weißt, was du
erwarten kannst.

- **Beim Tippen gibt es die volle Bildwiederholrate des Displays.** Während du tippst, einfügst oder mit einer
  Eingabemethode zusammensetzt, fordert Corta die maximale Bildrate des Displays an – 120 Hz auf einem ProMotion-Display –
  und lässt sie eine Sekunde nach der letzten Taste wieder sinken. Stromsparmodus, ein inaktives Fenster und thermische
  Last senken die Obergrenze wieder, wenn du nicht tippst; kritische thermische Last tut das immer.
- **Vollbild mit einem Bereich kann die Latenz unter macOS 27 oder neuer senken.** Corta stellt seine Frames dann direkt
  auf dem Display dar und überspringt den Compositor des Fensterservers: etwa ein Frame weniger vom Tastendruck bis zum
  Bildschirm auf dem gemessenen Mac. Eine Teilung, die Suchleiste oder irgendetwas anderes, das über dem Text gezeichnet
  wird, holt den Compositor zurück, solange es sichtbar ist. Unter macOS 26 nutzt jedes Fenster den Kopierpfad über die
  klassische Queue als Kompatibilitätsmaßnahme gegen einen WindowServer-Absturz (#380); die obigen Latenzwerte wurden auf
  diesem System nicht gemessen. (`CORTA_DIRECT_FULLSCREEN=0` in der Startumgebung deaktiviert die Vollbild-Änderungen,
  aber nicht den Kompatibilitätspfad für macOS 26.)
- **Ausgabe lesen und anzeigen haben getrennte Takte.** Der PTY-Leser parst weiter, während der Bildschirm den neuesten
  Zustand im Takt des Displays darstellt. Ein gemessener Benchmark des Kerndurchsatzes erreichte 317,3 MiB/s; diese Zahl
  schließt PTY-I/O, Rendering und Anzeige aus und ist keine versprochene Geschwindigkeit für ein echtes Build-Log oder `yes`.
- **Scrollen und Vollbildprogramme zeichnen nur neu, was sich geändert hat.** vim, less, tmux und eine Statuszeile
  scrollen, indem sie bereits Gezeichnetes verschieben.
- **Langer Verlauf bleibt klein.** Der Verlauf wird im Speicher komprimiert, während er hinausscrollt – der gemessene
  Speicherzuwachs für 100.000 Zeilen mit 120 Spalten lag bei etwa 11 MiB –, und Suche, Kopieren und Größenänderung
  arbeiten direkt darauf.
- **Leerlauf heißt Leerlauf.** Ein blinkender Cursor wird von macOS animiert statt von Corta neu gezeichnet, eine Shell im
  Leerlauf verursacht keine periodischen Aufwachvorgänge, und ein verdecktes oder minimiertes Fenster hört ganz auf zu zeichnen.
- **Verborgene Bereiche treten zurück.** Zwei Sekunden, nachdem ein Bereich verborgen wurde – ein anderer Tab, ein
  minimiertes Fenster –, wird seine Ausgabe mit Hintergrundpriorität gelesen, damit sie nicht mit dem konkurriert, was du
  gerade ansiehst. Nichts geht verloren, und Tippen oder Einfügen darin stellt sofort die volle Priorität wieder her.

[Performance](../../PERFORMANCE.md) (Englisch) enthält die Messungen und wie sie entstanden sind.

<a id="settings-and-the-config-file"></a>

## Einstellungen und die Konfigurationsdatei

Alle Einstellungen stehen in einer Textdatei, `~/.config/corta/config`. **Corta ▸ Einstellungen …** (⌘,) bearbeitet
dieselbe Datei, und das Bearbeiten der Datei von Hand wird genauso unterstützt:

Die Einstellungen sind eine Seitenleiste mit Kategorien, aufgebaut wie die Systemeinstellungen:

- **Allgemein** – die Größe neuer Fenster, Fenster wiederherstellen, Schließen bestätigen, Benachrichtigungen bei langen
  Aufgaben und Updates.
- **Erscheinungsbild** – hell oder dunkel, die System-Festbreitenschrift, Größe und eine Live-Vorschau, Cursorform/-blinken
  und grafische Themenbearbeitung.
- **Terminal** – Verlauf, die Begrenzung des Befehlsverlaufs, der Signalton, Suchvorgaben, der Befehl zum Öffnen von Dateien,
  Shell-Integration, optionaler Systemstatus und lokale Hostdetails.
- **Tastatur & Maus** – Wahltaste als Meta, wie Links sich öffnen, die Sondertaste, die Text auswählt, während ein
  Programm die Maus belegt, Kopieren beim Auswählen sowie Modi und Farben der Eingabequellenanzeige.
- **Tastaturkurzbefehle** – die Taste jedes Befehls; neben einer geänderten erscheint ein Pfeil zum Zurücksetzen.
- **Schnellterminal** – der systemweite Hotkey, Position und Bildschirm.
- **Verbindungen** – Mit Host verbinden und gespeicherte Vorgaben.
- **Datenschutz & Sicherheit** – Schreiben in die Zwischenablage durch Programme (OSC 52), Sichere Tastatureingabe, der
  Verzeichnisverlauf und zuletzt verbundene Hosts.

Diese Bedienelemente bearbeiten dieselbe Konfigurationsdatei. Farben eigener Themen lassen sich grafisch oder über die
Datei bearbeiten.

Die Globustaste in der Symbolleiste des Fensters verbindet mit einem Host, für ein Terminal oder für seine Dateien: ein
Dialog auf dem Fenster mit dem Host – er darf ein Alias aus der Konfiguration sein – und Benutzer, Port und privatem
Schlüssel unter **Erweitert**; er schlägt zuletzt verwendete und konfigurierte Hosts vor, und ein leerer Benutzer, Port
oder Schlüssel folgt der OpenSSH-Konfiguration. Aus einem entfernten Bereich bietet er zuerst die Dateien dieses Hosts an
([Arbeiten aus der Ferne](#remote-work-ssh-and-sftp)).

```ini
theme = corta
appearance = auto
font-size = 14
scrollback-lines = 20000
notify-on-long-task = true
bind.equalize-panes = ctrl+cmd+e
```

Die meisten Einstellungen gelten sofort; einige wenige (Fenstergröße, Länge des Verlaufs) gelten für das nächste Fenster
oder die nächste Sitzung. [Configuration](../../CONFIGURATION.md) (Englisch) listet jeden Schlüssel, seinen Standardwert und
wann er wirksam wird.

<a id="keyboard-shortcuts"></a>

## Tastaturkurzbefehle

Ändere jeden Kurzbefehl mit `bind.<command>` in der Konfigurationsdatei; ein leerer Wert entfernt ihn, und der
Tastenanschlag erreicht dann das Programm im Terminal:

```ini
bind.equalize-panes = ctrl+cmd+e
bind.close =
```

**Hilfe ▸ Tastaturkürzel** zeigt die geltenden Kurzbefehle in ausgerichteten Spalten; Befehle ohne Belegung sind mit
**Nicht festgelegt** beschriftet. Das Kontextmenü des Terminals zeigt dieselben konfigurierten Kurzbefehle.

Das Menü **Shell** hält Teilen, Wiederöffnen und Bildschirm löschen direkt bereit. Andere Werkzeuge sind unter
**Fokus verschieben**, **Befehle und Ausgabe**, **Arbeitsverzeichnis**, **Bereichslayout** und
**Terminal und Verbindung** gruppiert.

Die Standardwerte, Stand dieser Version – [Keyboard shortcuts](../../CONFIGURATION.md#5-keyboard-shortcuts) (Englisch) ist die
maßgebliche Liste:

| Befehl | Kurzbefehl |
| --- | --- |
| Neues Fenster / Neuer Tab | ⌘N / ⌘T |
| Schließen | ⌘W |
| Bereich nach rechts / unten teilen | ⌘D / ⇧⌘D |
| Fokus verschieben | ⌥⌘ + Pfeil |
| Bereichsgröße ändern | ⌃⌘ + Pfeil |
| Bereich vergrößern | ⇧⌘↩ |
| Geschlossenen Bereich wieder öffnen | ⇧⌘T |
| Größer / Kleiner / Originalgröße | ⌘= / ⌘− / ⌘0 |
| Suchen … / Nächsten suchen / Vorherigen suchen | ⌘F / ⌘G / ⇧⌘G (Nächsten und Vorherigen suchen sind fest) |
| Kopieren / Einfügen / Alles auswählen | ⌘C / ⌘V / ⌘A |
| Eine Seite scrollen / ganz nach oben oder unten | ⇧Bild↑, ⇧Bild↓ / ⇧Pos1, ⇧Ende |
| Vorheriger / Nächster Befehl | ⌘↑ / ⌘↓ |
| Vorheriger / Nächster fehlgeschlagener Befehl | ⇧⌘↑ / ⇧⌘↓ |
| Text exportieren … | ⇧⌘S |
| Bildschirm löschen | ⌘K |
| Einstellungen … | ⌘, |
| Befehlspalette … | ⇧⌘P |

Jeder andere Befehl – Bereiche gleichmäßig aufteilen, Verlauf löschen, Terminal zurücksetzen, Entfernte Dateien
durchsuchen …, die Befehle zu Befehlsausgabe und Arbeitsverzeichnis – hat keine Standardtaste und ist in der
Befehlspalette nur eine Suche entfernt. [Keyboard shortcuts](../../CONFIGURATION.md#5-keyboard-shortcuts) (Englisch) hat die
vollständige Tabelle mit dem `bind.`-Namen jedes Befehls.

<a id="when-something-goes-wrong"></a>

## Wenn etwas schiefgeht

Die [Fehlerbehebung](TROUBLESHOOTING.md) behandelt, was du siehst, wenn etwas fehlschlägt, und wie du es behebst – ein
Download, den macOS nicht öffnet, eine abgelehnte Schrift, ein Kurzbefehl, der nichts tut.
[Features and limitations](../../FEATURES.md) (Englisch) listet, was Corta noch nicht kann. Melde alles andere über
[GitHub Issues](https://github.com/noah-qin/Corta/issues/new/choose). Für Fragen zur Nutzung geh zu
[Discussions → Q&A](https://github.com/noah-qin/Corta/discussions/categories/q-a) oder frag in `#help` im
[Discord](https://discord.gg/QNdWfdwr7j).
