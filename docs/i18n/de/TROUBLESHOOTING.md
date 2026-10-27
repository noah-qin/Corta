# Fehlerbehebung

[Dokumentationsindex (Englisch)](../../README.md) · [Projektübersicht](README.md)

🇺🇸 [English](../../TROUBLESHOOTING.md) · 🇨🇳 [简体中文](../zh-CN/TROUBLESHOOTING.md) · 🇭🇰 [繁體中文](../zh-Hant/TROUBLESHOOTING.md) · 🇯🇵 [日本語](../ja/TROUBLESHOOTING.md) · 🇰🇷 [한국어](../ko/TROUBLESHOOTING.md) · 🇩🇪 [Deutsch](TROUBLESHOOTING.md) · 🇫🇷 [Français](../fr/TROUBLESHOOTING.md) · 🇪🇸 [Español](../es/TROUBLESHOOTING.md) · 🇧🇷 [Português](../pt-BR/TROUBLESHOOTING.md)

> Diese Seite ist eine Übersetzung von [TROUBLESHOOTING.md](../../TROUBLESHOOTING.md) mit dem Stand von Commit
> [`68169b9`](https://github.com/noah-qin/Corta/blob/68169b98164d5780f2959377a810eaf1be55e524/docs/TROUBLESHOOTING.md).
> Wurde die englische Fassung seitdem geändert oder weichen die beiden ab, gilt die englische.
> Meldungen von macOS stehen zusätzlich im englischen Original.

Was zu tun ist, wenn Corta sich nicht installieren lässt, nicht startet oder etwas tut, das dein bisheriges Terminal
nicht getan hat. Jeder Eintrag sagt, was du siehst, warum, und wie es sich beheben lässt – und der letzte Abschnitt
erklärt, wie du sauber zu deinem alten Terminal zurückkehrst, falls nichts davon hilft. Denn ein Bericht, der sagt „Ich
bin zurückgewechselt, und zwar deshalb“, gehört zu dem Nützlichsten, was du einreichen kannst.

Ist ein Eintrag hier falsch oder fehlt einer, öffne ein Issue mit der Vorlage **Installation blocker** oder
**Went back to my old terminal**: <https://github.com/noah-qin/Corta/issues/new/choose>.

---

<a id="installing"></a>

## Installation

### „Corta“ kann nicht geöffnet werden, da Apple darin nicht nach Schadsoftware suchen kann („Corta can't be opened because Apple cannot check it for malicious software“)

Offizielle Releases sind mit Developer ID signiert und notarisiert. Ein Build aus dem Quellcode ist das womöglich nicht.
Prüfe bei einem heruntergeladenen Release seine Prüfsumme sowie die Prüfungen von Image und App unten und melde dann die
genaue Meldung zusammen mit der Version.

### „Corta“ ist beschädigt und kann nicht geöffnet werden („Corta is damaged and can't be opened“)

Das Disk-Image ist möglicherweise unvollständig, verändert oder wurde von der Signaturprüfung von macOS abgelehnt.
Prüfe es zuerst gegen die `.sha256`-Datei, die daneben veröffentlicht wird. Lege beide Dateien in den Download-Ordner und
ersetze `x.y.z` durch die heruntergeladene Version:

```sh
shasum -a 256 -c Corta-x.y.z.dmg.sha256
```

Stimmt sie nicht überein, lade erneut herunter. Jedes Release-Paket wird vor der Veröffentlichung gegen seine Begleitdatei
geprüft (`corta-release-check`), daher ist eine Abweichung ein Grund, innezuhalten und neu herunterzuladen. Stimmt die
Prüfsumme, prüfe das Image und die kopierte App. Ersetze in allen Befehlen `x.y.z` durch die heruntergeladene Version und
führe sie im Download-Ordner aus:

```sh
spctl -a -t open --context context:primary-signature -v Corta-x.y.z.dmg
xcrun stapler validate Corta-x.y.z.dmg
spctl --assess --type exec /Applications/Corta.app
xcrun stapler validate /Applications/Corta.app
```

Gib in deinem Bericht die Release-Version, den Fehler von macOS und diese Ergebnisse an. Umgehe Gatekeeper nicht, um ein
Release zu testen. Versionen bis 1.1.8 behalten ihre ursprünglichen ZIP-Prüfsummen; verwende den Dateinamen aus dem
jeweiligen Release.

### Corta bietet an, sich nach /Applications zu verschieben

Corta wurde aus `~/Downloads` oder einem anderen Ordner gestartet. Es funktioniert von überall; `/Applications` ist der
Ort, an dem Sparkle-Updates und Spotlight es erwarten. Sag nein, und es fragt nicht mehr – oder setze
`suggest-applications-folder = false` in `~/.config/corta/config`.

Direkt aus dem Disk-Image geöffnet, führt macOS Corta von einem temporären, schreibgeschützten Ort aus, sodass es sich
nicht selbst verschieben kann; stattdessen bittet es dich, es in „Programme“ zu ziehen. Liegt dort bereits ein neueres
Corta, bietet es an, dieses zu öffnen, statt es durch die ältere Kopie zu ersetzen.

### Im Dock sind zwei Corta-Symbole

Eines davon ist ein Entwicklungs-Build. Der Finder nennt es **Corta Dev**, die Menüleiste **CortaDev**, sein Symbol hat
einen orangefarbenen statt eines blauen Hintergrunds, und seine Bundle-ID ist `dev.noahqin.Corta.dev`. Es speichert seine
Konfiguration und seinen Zustand in `~/Library/Application Support/Corta Dev/`, nie in `~/.config/corta/config` oder
`~/Library/Application Support/Corta/`, und es hat keinen Menüpunkt „Nach Updates suchen…“ – das mit dem blauen Symbol
ist also das installierte Corta, in welcher Reihenfolge sie auch erscheinen. Beenden oder Löschen des einen lässt das
andere unberührt. Nur wer Corta aus dem Quellcode baut, hat einen solchen Build (`CONTRIBUTING.md`, „Developing Corta in Corta“).

### „Diese Version von Corta erfordert macOS 26.0 oder neuer“ („This version of Corta requires macOS 26.0 or later“)

Cortas Deployment-Ziel ist macOS 26.0, und es verwendet Metal-4- und Core-Text-APIs aus diesem Release. Es gibt keinen
Build für ältere Systeme, und das Projekt plant keinen (`DESIGN.md` §6).

### „Das Programm ‚Corta‘ kann nicht geöffnet werden, da es auf diesem Mac-Typ nicht unterstützt wird“ („You can't open the application "Corta" because it is not supported on this type of Mac“)

Seit 1.1.0 wird Corta nur für Apple Silicon gebaut – einen Mac mit M1-Chip oder neuer (`DECISIONS.md` D21). Ein
Intel-Mac kann es nicht ausführen. **1.0.1** ist die letzte Version für Intel-Macs und bleibt auf der
[Release-Seite zu 1.0.1](https://github.com/noah-qin/Corta/releases/tag/v1.0.1) verfügbar: Lade `Corta-1.0.1.zip`
herunter, prüfe es und ersetze die Kopie in `/Applications`. Einem Intel-Mac, auf dem bereits 1.0.x läuft, bietet
**Nach Updates suchen…** 1.1.0 nicht an, er funktioniert also weiter; diese Meldung erscheint nur, wenn ein neueres
Archiv von Hand heruntergeladen und geöffnet wurde.

Um zu prüfen, welchen Chip ein Mac hat, wähle Apple-Menü ▸ Über diesen Mac: Die Zeile *Chip* nennt auf Apple Silicon
einen Apple-Chip (M1, M2, …), eine Zeile *Prozessor* einen Intel-Prozessor.

---

<a id="starting"></a>

## Starten

### Das Fenster öffnet sich leer oder öffnet sich und schließt sich wieder

Starte aus Terminal.app, um zu sehen, warum:

```sh
/Applications/Corta.app/Contents/MacOS/Corta
```

Ein Bereich, der seine Shell nicht starten kann, zeigt statt einer leeren Fläche eine Fehleransicht mit einer Taste
**Wiederholen**; siehst du eine leere Fläche ohne Fehleransicht, ist das ein Darstellungsfehler, der einen Bericht mit
der Konsolenausgabe wert ist.

### Die Shell ist nicht die erwartete oder hat keinen PATH

Corta startet `$SHELL` aus der Umgebung, mit der es gestartet wurde (sonst `/bin/zsh`), als Login-Shell (`-l`), sodass
`~/.zprofile` und `~/.zshrc` beide laufen. Ein `$SHELL`, das nicht mehr existiert, fällt auf `/bin/zsh` und dann auf
`/bin/sh` zurück, mit einem Hinweis im Bereich, welche Stufe genommen wurde. Wenn Befehle, die in Terminal.app
funktionieren, in Corta „nicht gefunden“ werden, prüfe, was `SHELL` in der Umgebung ist, mit der *GUI-Apps* gestartet
werden (`launchctl getenv SHELL`): Ein dort gesetzter Wert gilt für jede App und überdauert die Sitzung, die ihn gesetzt
hat. Führe `launchctl unsetenv SHELL` aus und starte neu.

Eine **Voreinstellung** (Shell ▸ Neuer Bereich mit Voreinstellung) oder `preset.<name>.shell` in der Konfigurationsdatei
überschreibt das pro Bereich.

### Corta hat die Fenster von gestern wiederhergestellt, und ich wollte das nicht

`restore-windows = false` in `~/.config/corta/config`, oder deaktiviere es unter Einstellungen ▸ Allgemein. Eine
Wiederherstellung, die die App abstürzen ließ, wird nicht wiederholt: Die gespeicherte Anordnung wird verworfen, und ein
neues Fenster öffnet sich.

### Die Einstellungen melden, die Konfigurationsdatei sei nicht lesbar

`~/.config/corta/config` existiert, ist aber kein UTF-8-Text – meist ein Byte, das ein Editor in einer anderen Kodierung
gespeichert hat – oder du darfst sie nicht lesen. Corta behält die Einstellungen, die es hat, und weigert sich, die Datei
zu schreiben, weil Schreiben alles darin ersetzen würde. Speichere die Datei erneut als UTF-8 (oder entferne die
fehlerhafte Zeile); Corta übernimmt sie, sobald es sie wieder liest. Die Shell-Integration verfährt genauso mit einer
rc-Datei, die sie nicht lesen kann: Sie meldet es und lässt die Datei in Ruhe.

---

<a id="typing-and-rendering"></a>

## Tippen und Darstellung

### Bildschirm löschen lässt nur einen Cursor zurück, ohne Prompt

Aktualisiere Corta, wenn ⌘K einen wartenden Prompt löscht. Mit Shell-Integration und einer Markierung für das Ende eines
bereiten Prompts behält Bildschirm löschen jetzt den angezeigten Prompt und die noch nicht abgeschickte Eingabe samt
Bearbeitungscursor. Es sendet weder Return noch Control-L noch sonst eine Eingabe. Aktiviere die Shell-Integration für eine
Shell ohne Prompt-Markierungen; standardmäßige lokale zsh-Sitzungen laden sie mit den mitgelieferten Vorschlägen automatisch.
Das eigene Neuzeichnen der Shell mit Control-L bleibt eine Alternative, wenn die Shell es eingerichtet hat. Ein Programm auf
dem alternativen Bildschirm oder ein mehrzeiliger Editor, dessen Prompt schon im Verlauf liegt, bleibt bewusst unverändert.

### Die Verzeichnisvorschläge enden nach einem Ordner mit `/` am Ende

Kandidaten sind nur Unterverzeichnisse; ein Verzeichnis, das nur Dateien enthält, hat keinen weiteren Verzeichnisvorschlag.
Tippe einen Teil eines Unterordnernamens oder drücke noch einmal Tab, solange Kandidaten sichtbar sind. Tab füllt den Pfad
ein, ohne ihn auszuführen; Return führt `cd` aus. Versteckte Ordner brauchen einen Punkt am Anfang. Fehlt ein bekannter
Unterordner, prüfe den Zugriff auf dieses Verzeichnis und vergleiche mit der nativen Vervollständigung der Shell, nachdem du
`directory-completion` ausgeschaltet hast. Bleibt der Unterschied, melde die genaue Form des Pfads und die Shell.

### Der Befehlsverlauf öffnet sich abseits des Terminals

Schließe ihn und öffne ihn im aktuellen Corta erneut. Er öffnet zentriert über dem aufrufenden Fenster und bleibt im
nutzbaren Bereich dieses Bildschirms; er wird nicht in der Mitte des gesamten Bildschirms platziert. Über Corta ist
bewusst die Ausnahme: Es öffnet wie die Infofenster anderer Apps in der Mitte des Bildschirms. Ein bereits offenes
Fenster behält die Position, die du gewählt hast.

### Tab tut nichts im Slash-Befehlsmenü von Claude Code

Behoben in 1.0.0 (B02); v0.1.1 hat den Fehler. Tritt er in einem neueren Build wieder auf, melde ihn mit der Version von
Claude Code: Die Korrektur liegt darin, wie `insertTab(_:)` aus einem Kandidatenfenster das Kindprogramm erreicht, und
eine neue Kandidatenoberfläche könnte es anders weiterleiten.

### ⌥ tippt `é`, `ø`, `–`, statt als Meta zu wirken

Das ist der Standard von macOS, und Corta behält ihn bei. Setze `option-as-meta = true`, damit ⌥ `ESC` + Taste sendet, wie
die Alt-Taste einer PC-Tastatur. Sondertasten (Pfeile, Funktionstasten) tragen ⌥ so oder so als xterm-Modifikator.

### Farben oder `TERM` sehen über ssh falsch aus

Corta meldet bewusst `TERM=xterm-256color` (`docs/DECISIONS.md` D08). Denselben TERM-Wert zu teilen bedeutet keine
vollständige xterm-Kompatibilität. Prüfe die entfernte Umgebung mit `printf '%s\n' "$TERM"` und vergleiche einen
minimalen Reproduktionsfall; [Conformance](../../CONFORMANCE.md#42-external-suites) (Englisch) hält unterstützte Sequenzen und
die verbleibenden Fehlschläge fest.

### Eine Glyphe wird kleiner gezeichnet als ihre Nachbarn

Ein Zeichen, das der gewählten Schrift fehlt, kommt aus PingFang SC oder Apple Color Emoji. Eine Ersatzglyphe kann
skaliert werden, um in ihren Terminalzellen zu bleiben, sodass ihre sichtbare Größe von benachbarten Glyphen abweichen
kann. Passe die Schriftgröße unter **Einstellungen ▸ Erscheinungsbild** an und vergleiche die Vorschau. Wird eine Glyphe
abgeschnitten oder falsch ausgerichtet, melde Text, Schrift, Schriftgröße, Display-Skalierung und einen Screenshot.

### Die eingestellte Schrift wird nicht verwendet

`font-family` nennt eine Familie, keinen Schnitt (`JetBrains Mono`, nicht `JetBrainsMono-Regular`). Corta verwendet sie
nur, wenn sie installiert ist und ihre normalen, fetten und kursiven Schnitte über das druckbare ASCII hinweg gleich weit
vorrücken; sonst zeichnet es System (monospaced), und **Einstellungen ▸ Erscheinungsbild** zeigt eine Zeile
„Schriftstatus“, die sagt, welche Prüfung fehlschlug. Eine Schrift, die installiert wird, während Corta läuft, erscheint
sofort in der Liste; „Wiederholen“ prüft die konfigurierte erneut.

Werden Chinesisch, Japanisch oder Koreanisch in einer anderen Schrift gezeichnet als der unter **CJK-Schrift**
(`font-family-cjk`), ist diese Familie nicht installiert oder hat keine CJK-Zeichen; die Zeile unter dem Menü sagt das,
und stattdessen zeichnet die Schrift der Systemsprache. Ein Zeichen, das der gewählten Schrift fehlt, kommt ebenfalls aus
der Schrift der Systemsprache. Die CJK-Schrift wird nicht verwendet, solange **Fehlende Zeichen aus anderen Schriften**
ausgeschaltet ist.

### Bilder aus `kitten icat` werden nicht oder an der falschen Stelle angezeigt

Corta implementiert die direkte (In-Band-)Übertragung des Kitty-Grafikprotokolls in RGB, RGBA und PNG. Dateibasierte
Übertragung (`t=f`, `t=t`, `t=s`), Animationsframes und die Platzierung über Unicode-Platzhalter sind nicht
implementiert, und die dateibasierten werden es auch nicht: Ein entfernter Datenstrom, der eine zu lesende lokale Datei
benennt, ist genau das, was das Bedrohungsmodell ablehnt (`SECURITY.md` §1). Versuche
`kitten icat --transfer-mode=stream picture.png`, um ausdrücklich direkte Übertragung anzufordern. Ein Bild muss die
Grenzen von 8192 Pixeln pro Seite und 16 Millionen Pixeln einhalten; ungültige oder übergroße Bilder werden abgelehnt.

### Ein leeres Return zeichnet eine grüne oder rote Befehlsmarkierung

Ein leeres Return ist kein Befehl, und aktuelle Integrations-Hooks erfassen keinen. Ein Block in der Startdatei, den ein
älteres Corta installiert hat, kann noch einen melden: Öffne **Einstellungen ▸ Terminal ▸ Shell-Integration**, wähle
**Aktualisieren** und öffne dann eine neue Shell. Bereits laufende Shells behalten die alten Funktionen bis zum Neustart,
und schon gezeichnete Markierungen bleiben. Aktualisiert wird nur der markierte Corta-Block in der Startdatei.
Standardmäßige lokale zsh-Sitzungen mit den automatischen Hooks erhalten die mitgelieferte Version, wenn eine neue Shell startet.

---

<a id="behaviour-that-differs-from-other-terminals"></a>

## Verhalten, das sich von anderen Terminals unterscheidet

### Kopiert wird, sobald ich mit dem Auswählen fertig bin

`copy-on-select` ist standardmäßig an und bestätigt mit einer Beschriftung in der Ecke des Bereichs. Setze es auf `false`,
um nur mit ⌘C zu kopieren.

### Ein Programm sagte, es habe in meine Zwischenablage kopiert, und nichts wurde kopiert

OSC 52 *Schreiben* ist standardmäßig aus: Sonst könnte jede beliebige Programmausgabe Text in die Zwischenablage legen,
den du später einfügst. `allow-clipboard-write = true` schaltet es ein, und genau das brauchen `tmux` und eine entfernte
`ssh`-Sitzung. Die *Lese*richtung existiert unter keiner Einstellung.

### Beim Schließen eines Fensters werde ich gefragt, ob ich sicher bin

In diesem Fenster läuft noch ein Vordergrundjob. `confirm-close = false` schaltet die Frage überall ab.

### Der Hotkey des Schnellterminals tut nichts

Drei Möglichkeiten, in dieser Reihenfolge. `quick-terminal` ist `false` (Standard): Keine Taste wird belegt, bis du es auf
`true` setzt. Eine andere App hält die Taste bereits: Einstellungen ▸ Schnellterminal sagt das, und `quick-terminal-key`
nimmt jede andere Kombination mit mindestens einer Sondertaste an. Oder die Taste ist eine, die Corta keiner
Tastenposition zuordnen kann (`é`, eine Schreibweise aus zwei Zeichen): Die Zeile bleibt unverändert in der
Konfigurationsdatei, und der Standard gilt. Darstellung ▸ Schnellterminal und die Kurzbefehle-Aktion
*Schnellterminal ein-/ausblenden* öffnen das Panel in jedem Fall.

### Das Kennzeichen eines entfernten Bereichs zeigt „Entfernt: Host unbekannt“ oder ein lokales `tmux` „Entfernt?“

Das Kennzeichen nennt einen Host aus der eigenen `OSC 7`-Meldung der entfernten Shell oder – bei einer Verbindung, die
über den Verbindungsdialog geöffnet wurde – aus dem dort eingegebenen Ziel. Es liest nie einen aus einer am Prompt
getippten `ssh`-Befehlszeile (Aliase, Namen aus `~/.ssh/config` und Jump-Host-Ketten würden alle falsch gelesen) oder aus
dem Prompt-Text. Ohne beides sagt ein `ssh`-Bereich *Host unbekannt*, und das ist die Wahrheit. Um den Host zu erhalten,
füge den Block der Shell-Integration aus Einstellungen ▸ Terminal auch in die `~/.zshrc` des entfernten Rechners ein;
er sendet das `OSC 7`, das das Kennzeichen liest. Ein `tmux` oder `screen` im Vordergrund zeigt *Entfernt?*, weil die
Sitzung, an die es angehängt ist, selbst auf einem anderen Rechner liegen kann und hier nichts das feststellen kann – es
ist Unsicherheit, keine Unterstellung.

### Entfernte Dateien durchsuchen … meldet fehlgeschlagene Authentifizierung, aber `ssh` funktioniert im Bereich

Die SFTP-Verbindung fragt in einem Dialog auf ihrem Fenster nach einem Passwort oder einer Schlüssel-Passphrase; ein
abgelehnter oder abgebrochener Dialog endet mit diesem Fehler. Prüfe Benutzer und Port im Formular – `User` und `Port`
eines Alias gelten nur, wenn diese Felder leer sind – und den Schlüssel, falls du einen gewählt hast: Ein gewählter
Schlüssel ist der einzige, der angeboten wird. Erschien kein Dialog, hat der Server jede Methode abgelehnt, die ssh
versuchen konnte; `ssh -v` mit demselben Benutzer, Port und Schlüssel in einem Terminal zeigt, welche.

### Entfernte Dateien durchsuchen … meldet, ein Hostschlüssel könne nicht verifiziert werden

Ein zum ersten Mal gesehener Host bittet dich in einem Dialog, der den Fingerabdruck zeigt, seinem Schlüssel zu vertrauen.
Dieser Fehler bedeutet, dass sich der Schlüssel *geändert* hat, seit du ihm vertraut hast – ein neu installierter Server
oder jemand dazwischen. ssh verweigert das, bis die alte Zeile aus `~/.ssh/known_hosts` entfernt ist
(`ssh-keygen -R <host>`); frag zuerst die Administration des Servers.

### Der Befehlsverlauf zeigt „(Befehlstext nicht mehr im Verlauf)“

Der Text eines Befehls wird aus dem Raster wiederhergestellt, nicht gespeichert: Sobald seine Prompt-Zeile über
`scrollback-lines` hinausgescrollt ist, behält der Eintrag Zeit, Status und Verzeichnis, aber der Text ist weg, und
„Einfügen“ und „Ausführen“ werden dafür nicht angeboten. Erhöhe `scrollback-lines`, wenn das oft passiert.

### Ich kann nicht bis zum Anfang einer langen Ausgabe zurückscrollen

`scrollback-lines` (Standard 10.000) ist eine Obergrenze pro Sitzung und zählt *physische* Zeilen – eine Zeile mit 200
Spalten, bei 100 Spalten umbrochen, sind zwei. Ausgabe, die älter als die Grenze ist, wird beim Eintreffen verworfen;
die Pille oben zeigt, wie weit die Ansicht zurückliegt. Erhöhe die Grenze (bis 1.000.000; wie viel Speicher der
komprimierte ältere Verlauf belegt, hängt von Text und Arbeitslast ab). Eine gespeicherte Zelle hat vor der Kompression
16 Byte; das ist keine Schätzung des belegten Arbeitsspeichers. Eine gemessene Arbeitslast mit 100.000 Zeilen und 120
Spalten belegte etwa 11 MiB zusätzlichen Arbeitsspeicher; siehe
[Performance](../../PERFORMANCE.md#56-numbers-by-release) (Englisch). Exportiere Ausgabe, die du über die konfigurierte Grenze
hinaus behalten musst.

### Sichere Tastatureingabe ist an, aber mein Makrowerkzeug funktioniert trotzdem

Das Schloss in der Titelleiste zeigt, wann sie *greift*, und das ist nur so, solange ein Corta-Terminalfenster das
Hauptfenster und Corta die aktive App ist. In jeder anderen App, und solange die Einstellungen das Hauptfenster sind,
werden Tastenanschläge normal zugestellt – das ist der Zweck, und deshalb folgt die Anzeige dem tatsächlichen Zustand
statt der Einstellung.

### Auf einem Netzwerk-Mount fehlt das Proxy-Symbol des Verzeichnisses

Corta prüft das gemeldete lokale Verzeichnis im Hintergrund. Ist der Mount langsam oder warten bereits zwei Prüfungen,
lässt es das Proxy-Symbol weg, damit Ausgabe und Tastatureingabe weiterlaufen können. Prüfe den Mount separat; ein
Verzeichniswechsel nach seiner Erholung fordert eine neue Prüfung an.

### Ein Bereich öffnet sich im Benutzerordner statt in einem Netzwerkverzeichnis

Ein neuer Bereich oder ein beim Start wiederhergestelltes Fenster beginnt nur dann im gewünschten Verzeichnis, wenn dieses
innerhalb einer kurzen Frist antwortet. Ein Netzwerkvolume, das nicht mehr antwortet, gilt als fehlend, sodass sich der
Bereich im Benutzerordner öffnet, statt Corta einzufrieren. Dieselbe Frist gilt für ⌘-Klick oder Darüberfahren über einen
`path:line`-Verweis dort: Er wird nicht als Link angeboten. Verbinde das Volume neu und wechsle dann mit `cd` dorthin
oder öffne dort einen neuen Bereich.

### Die Remote-Bearbeitung fragt nach einer Upload-Nachfrage erneut

Die lokale Datei hat sich nach der Version geändert, die die ursprüngliche Nachfrage zeigte. Bestätige die neue Änderung
ausdrücklich. Ein älterer verwalteter Eintrag ohne Prüfsumme des entfernten Inhalts braucht ebenfalls einmal eine
Konfliktentscheidung. Ein Inhaltsvergleich kann entfernte Änderungen erkennen, auch wenn Dateigröße und Zeitstempel
unverändert sind.

### Ein Upload der Remote-Bearbeitung fragt nach langer Wartezeit erneut

Die Verbindung ist ins Stocken geraten. Ist sie aufgebaut, hat jeder Vorgang der Remote-Bearbeitung 120 Sekunden Zeit;
danach schließt Corta die Verbindung und bietet den Upload erneut an. Bestätige ihn, um es über eine neue Verbindung noch
einmal zu versuchen. Auch eine sehr große Datei über eine langsame Leitung kann die Grenze erreichen: Kopiere sie dann mit
dem SFTP-Browser.

---

<a id="appearance-and-the-status-bar"></a>

## Erscheinungsbild und Statusleiste

### Der Cursor blinkt nicht

Blinken ist standardmäßig aus: Schalte **Cursor blinken lassen** unter Einstellungen ▸ Erscheinungsbild ▸ Cursor ein. Es
pausiert, solange der Bereich inaktiv, verborgen oder zurückgescrollt ist. Ein Terminalprogramm kann Form oder Blinken
für sich selbst mit DECSCUSR ändern; Terminal zurücksetzen kehrt zum konfigurierten Stil zurück.

### Die Statusleiste zeigt keine Netzwerkrate oder die falsche

Raten brauchen zwei Messpunkte, warte also nach dem Aktivieren der Leiste ein paar Sekunden. `auto` misst eine primäre
Schnittstelle; wenn ein VPN oder mehrere Adapter dazu führen, dass es die falsche ist, gib den Schnittstellennamen unter
Einstellungen ▸ Terminal ein. Eine ausdrücklich genannte Schnittstelle, die nicht existiert, zeigt keine Rate. Die Leiste
meldet immer den lokalen Mac, auch in einem SSH-Bereich, und Wärmestufen sind Einstufungen von macOS, keine Gradzahlen.
Ein schmales Fenster kann die Leiste abschneiden; klicke darauf für jeden gewählten Wert.

### Der Themeneditor speichert nicht

Eine ungültige HEX-Farbe deaktiviert das Speichern. Wurde das eigene Thema in der Konfigurationsdatei geändert, während
der Editor offen war, schließe den Editor und öffne ihn erneut, bevor du speicherst, damit er diese Änderung nicht überschreibt.

### Die Oberfläche ist in der falschen Sprache

Corta folgt der Sprache, die macOS dafür wählt (Systemeinstellungen ▸ Allgemein ▸ Sprache & Region ▸ Programme).
Starte Corta nach einer Änderung neu. Zahlenformate folgen der Region und können von der Sprache abweichen.

---

<a id="updating"></a>

## Aktualisieren

### „Nach Updates suchen…“ findet nichts

Corta vergleicht **Build-Nummern**, nicht Versionszeichenketten, mit `appcast.xml` im Branch `main`. Ein Release, das
getaggt und als Entwurf angelegt, aber noch nicht veröffentlicht ist, steht nicht im Feed; sobald es veröffentlicht ist,
signiert und prüft die Release-Pipeline den Feed, öffnet einen Pull Request, wartet auf CI und führt ihn per Squash
zusammen oder aktiviert Auto-Merge. Eine fehlgeschlagene oder blockierte Feed-Prüfung kann die Auslieferung verzögern,
gib also nach dem Erscheinen des Releases auf GitHub ein wenig Zeit. `update-auto-check = false` deaktiviert nur die
tägliche Hintergrundprüfung; der Menüpunkt funktioniert immer.

---

<a id="going-back-to-your-old-terminal"></a>

## Zurück zu deinem alten Terminal

Beende Corta, bevor du seine Dateien entfernst. Prüfe verwaltete Kopien aus der Remote-Bearbeitung auf ungesicherte
Arbeit, bevor du App-Daten löschst:

1. **Shell-Integration**, falls du sie über Einstellungen ▸ Terminal installiert hast: Entferne sie dort, oder lösche den
   Block zwischen `# >>> Corta shell integration >>>` und `# <<< Corta shell integration <<<` in der Startdatei deiner
   Shell – `~/.zshrc`; für bash in `~/.bashrc` und `~/.bash_profile` (oder `~/.bash_login` / `~/.profile`); oder
   `~/.config/fish/config.fish`. Nichts anderes in dieser Datei gehört zu Corta.
2. **Sichere Tastatureingabe** gibt sich selbst frei, wenn Corta beendet wird. Wurde Corta zwangsweise beendet, während ein
   Fenster das Hauptfenster war, und scheint das Tippen anderswo blockiert, starte Corta einmal und beende es wieder;
   der Zähler wird beim Beenden ausgeglichen.
3. **Einstellungen und Zustand**: `~/.config/corta/` (die Konfigurationsdatei) und `~/Library/Application Support/Corta/`
   (Fensteranordnung, Verzeichnisverlauf und verwaltete Kopien aus der Remote-Bearbeitung). Lösche sie erst, nachdem du
   alle lokalen Änderungen gesichert hast, die du noch brauchst. Der Renderer legt außerdem entbehrliche Cache-Dateien
   unter `~/Library/Caches/dev.noahqin.Corta/` ab; diese können entfernt werden.
4. Bewege `Corta.app` in den Papierkorb.

Dann, wenn du magst, öffne ein Issue mit dem Formular
[**Went back to my old terminal**](https://github.com/noah-qin/Corta/issues/new?template=went_back.yml) und sag, was dich
zurückgebracht hat. Es braucht keine Reproduktion. Eine fehlende Funktion, ein Darstellungsfehler und „es fühlte sich
einfach langsamer an“ sind alles Antworten, mit denen das Projekt etwas anfangen kann.
