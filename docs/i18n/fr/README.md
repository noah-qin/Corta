<div align="center">

<img src="../../brand/corta-pangolin-mascot.png" width="160" alt="La mascotte pangolin de Corta, enroulée en forme de C, avec un curseur cyan au bout de la queue">

# Corta

**Un terminal rapide et sans distraction. Conçu pour le Mac. Écrit en Swift.**

Rendu Metal 4 · Saisie CJK / IME native · SSH, SFTP et édition à distance

> Pour celles et ceux qui vivent dans le terminal : un texte net, une saisie native, des flux de travail à distance puissants et un cœur de terminal en Swift **sans aucune** dépendance tierce. Assez rapide pour les sorties exigeantes. Assez soigné pour le travail de tous les jours.

[![CI](https://github.com/noah-qin/Corta/actions/workflows/ci.yml/badge.svg)](https://github.com/noah-qin/Corta/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/noah-qin/Corta?style=flat-square)](https://github.com/noah-qin/Corta/releases/latest)
![Platform](https://img.shields.io/badge/macOS_26.0%2B-Apple_silicon-4d4d4d?style=flat-square)
![Swift](https://img.shields.io/badge/Swift-6-f05138?style=flat-square)
[![License](https://img.shields.io/badge/license-Apache--2.0-2f81f7?style=flat-square)](../../../LICENSE)
[![Discord](https://img.shields.io/badge/Discord-join-5865f2?style=flat-square&logo=discord&logoColor=white)](https://discord.gg/QNdWfdwr7j)

**[↓ Télécharger](https://github.com/noah-qin/Corta/releases/latest)** ·
**[Guide d’utilisation](USER-GUIDE.md)** ·
[Documentation (anglais)](../../README.md) ·
[Contribuer](../../../CONTRIBUTING.md) ·
[Discord](https://discord.gg/QNdWfdwr7j) ·
[Signaler un bug](https://github.com/noah-qin/Corta/issues/new?template=bug_report.yml)

🇺🇸 [English](../../../README.md) · 🇨🇳 [简体中文](../zh-CN/README.md) · 🇭🇰 [繁體中文](../zh-Hant/README.md) · 🇯🇵 [日本語](../ja/README.md) · 🇰🇷 [한국어](../ko/README.md) · 🇩🇪 [Deutsch](../de/README.md) · 🇫🇷 [Français](README.md) · 🇪🇸 [Español](../es/README.md) · 🇧🇷 [Português](../pt-BR/README.md)

<img src="../../brand/screenshot.png" width="960" alt="Corta avec trois volets : un git log et un tableau d’alignement chinois, japonais, coréen et emoji ; la mascotte pangolin affichée en image dans le terminal ; et des dégradés en couleurs 24 bits">

</div>

> Cette page est une traduction du [README.md](../../../README.md) anglais, dans son état au commit
> [`04ad320`](https://github.com/noah-qin/Corta/blob/04ad320438030e3ba4a7c19761b0279e39c42afc/README.md).
> Si la version anglaise a changé depuis, ou si les deux diffèrent, la version anglaise fait foi.

## Installation

Nécessite **macOS 26.0 ou ultérieur**, une **puce Apple** (M1 ou ultérieure) et un **GPU compatible Metal 4**.
Les machines virtuelles avec un GPU paravirtualisé ne sont pas prises en charge. Les Mac Intel peuvent utiliser
l’ancienne [version 1.0.1](https://github.com/noah-qin/Corta/releases/tag/v1.0.1).

Téléchargez le `.dmg` et le fichier `.dmg.sha256` correspondant depuis
[GitHub Releases](https://github.com/noah-qin/Corta/releases/latest).
Gardez les deux fichiers dans le même dossier et vérifiez la somme de contrôle à cet endroit :

```sh
# Remplacez x.y.z par la version téléchargée.
shasum -a 256 -c Corta-x.y.z.dmg.sha256
```

Ouvrez l’image disque, faites glisser **Corta** dans **Applications**, puis éjectez l’image. Les versions sont
signées avec un Developer ID et notarisées. Pour les mises à jour suivantes, utilisez
**Corta ▸ Rechercher les mises à jour…** ou téléchargez une version plus récente. L’aide à l’installation et les
instructions de désinstallation se trouvent dans [Dépannage](TROUBLESHOOTING.md).

## Premiers pas

| Pour… | Utilisez |
| :--- | :--- |
| Diviser à droite / vers le bas | ⌘D / ⇧⌘D |
| Rechercher dans la sortie du terminal | ⌘F |
| Ouvrir la palette de commandes | ⇧⌘P |
| Ouvrir les réglages | ⌘, |

Les sessions zsh locales standard chargent automatiquement les hooks d’intégration du shell fournis, lorsque les
suggestions de dossiers sont activées (par défaut). Pour une installation dans les fichiers de démarrage de zsh, bash ou
fish, utilisez **Réglages ▸ Terminal ▸ Intégration du shell** ; vos fichiers de démarrage ne sont modifiés que lorsque
vous choisissez Installer. Si une intégration installée est obsolète, choisissez Mettre à jour et ouvrez un nouveau shell.
Consultez le [guide de l’intégration du shell](USER-GUIDE.md#shell-integration) pour les détails.

## Pourquoi Corta

| | |
| :--- | :--- |
| **Saisie native sur Mac** | Saisie CJK et composition IME, police de secours Core Text, VoiceOver, Saisie clavier sécurisée, Services, le Terminal rapide et des actions Raccourcis — en passant par AppKit, pas en le contournant. |
| **Rapide, preuves à l’appui** | 2,3 × le débit du cœur de la 1.1, une image de moins de latence de saisie en plein écran, et 11 Mio au lieu de 185 Mio pour 100 000 lignes d’historique. Chaque chiffre est publié avec sa méthode et ses limites (ci-dessous). |
| **Travail à distance intégré** | L’OpenSSH du système avec votre `~/.ssh/config`, un navigateur SFTP à la Finder avec glisser-déposer, et des fichiers distants ouverts dans votre éditeur local avec vérification des conflits avant l’envoi. |
| **Un seul fichier de réglages** | La fenêtre Réglages native et `~/.config/corta/config` modifient la même configuration ; des vérifications automatiques gardent les clés et raccourcis documentés alignés sur le code. |
| **Petit cœur, garde-fous sérieux** | Un cœur de terminal en Swift sans dépendance tierce, des limites de ressources pour les sorties non fiables et un décodeur d’images en bac à sable ; l’app n’ajoute que [Sparkle](https://sparkle-project.org) pour les mises à jour. La lecture du presse-papiers et les requêtes de titre sont volontairement absentes ([modèle de sécurité](../../SECURITY.md), en anglais). |

Volets partagés, recherche dans l’historique, couleurs vraies, liens OSC 8, protocoles clavier et graphique de Kitty,
intégration du shell et restauration des dispositions sont tous là ; la [référence des fonctionnalités](../../FEATURES.md)
(en anglais) liste tout, avec exigences et limites, et décrit `main` — une version publiée peut ne pas encore tout
contenir. La comparaison de Corta avec iTerm2 et Ghostty, et quand préférer l’un d’eux, se trouve dans
[Features → How Corta compares](../../FEATURES.md#how-corta-compares) (en anglais).
Le périmètre limité à macOS et l’absence de mode de contrôle tmux, d’IA intégrée et de moteur de scripts sont des
[décisions arrêtées](../../DECISIONS.md) (en anglais) ; les sessions tmux ordinaires tournent dans Corta comme des
programmes de terminal.

## À votre façon

Les réglages sont stockés dans `~/.config/corta/config`. La fenêtre Réglages native et le fichier texte modifient la
même configuration.

```ini
theme = midnight
theme.midnight.inherit = solarized
theme.midnight.dark.background = #101018

bind.equalize-panes = ctrl+cmd+e
bind.command-palette = cmd+shift+p
```

**Présentation ▸ Éditeur de thème…** ouvre des sélecteurs de couleurs et des aperçus clair/sombre séparés.
**Réglages ▸ Apparence ▸ Curseur** choisit bloc, barre ou souligné, avec un interrupteur de clignotement indépendant ;
par défaut, un bloc qui ne clignote pas. La police système à largeur fixe est la seule police principale prise en charge,
avec une taille réglable et la police de secours du système pour les caractères manquants.
**Réglages ▸ Terminal ▸ Barre d’état inférieure** active des indicateurs locaux au choix (désactivé par défaut) ;
cliquez dessus pour les détails de l’hôte, ou utilisez **Présentation ▸ Détails de l’hôte local…**. Voir le
[tutoriel de personnalisation](USER-GUIDE.md#personalizing-the-terminal) pour les étapes, le choix de
l’interface réseau et les limites de l’état thermique.

La [référence de configuration](../../CONFIGURATION.md) (en anglais) liste chaque clé, sa valeur par défaut et le moment
où une modification prend effet. Le [guide d’utilisation](USER-GUIDE.md) passe en revue chaque fonctionnalité et
indique où la trouver.

## Compiler depuis les sources

```sh
git clone https://github.com/noah-qin/Corta.git && cd Corta
swift test --package-path CortaTerminal                     # le cœur du terminal seul, sans l’app
xcodebuild -project Corta.xcodeproj -scheme 'Corta (Dev)' build  # une app de développement à côté de votre Corta installé
```

Le [guide des contributeurs](../../../CONTRIBUTING.md) (en anglais) donne les prérequis (macOS 26, puce Apple, le Xcode indiqué
dans [`.xcode-version`](../../../.xcode-version)), la signature locale et une carte du dépôt ; le
[guide des tests](../../TESTING.md) (en anglais) indique quelle vérification chaque modification nécessite.

## La qualité, preuves à l’appui

Corta est en développement actif et a des problèmes connus. Ces mesures sont des instantanés, pas des garanties pour
chaque machine ou charge de travail. Chaque ligne indique la version sur laquelle elle a été mesurée.

| Vérification | Résultat enregistré | Mesuré sur | Preuve |
| :--- | :--- | :--- | :--- |
| Débit du cœur (analyseur, grille et historique ; sans PTY ni rendu) | **317,3 Mio/s**, contre 137,2 | 1.2 vs 1.1 | [Performance §5.14](../../PERFORMANCE.md#514-scrolling-without-per-line-screen-allocation-281-283) |
| Débit analyseur + grille | **355,9 Mio/s**, contre 158,0 | 1.2 vs 1.1 | idem |
| Mémoire de l’historique, 100 000 × 120 lignes | **11,4 Mio**, contre 185 | 1.2 vs 1.1 | [Performance §5.6](../../PERFORMANCE.md#56-numbers-by-release) |
| Défilement de région, CPU par image, p50 | **0,026 ms**, contre 0,130 | 1.2 vs 1.1 | [Performance §5.14](../../PERFORMANCE.md#514-scrolling-without-per-line-screen-allocation-281-283) |
| CPU par image, reconstruction complète 120 × 40, Release | **0,37–0,39 ms** | 1.2 | [Performance §5.17](../../PERFORMANCE.md#517-full-screen-without-the-compositor-285-2026-10-13) |
| De la touche à l’écran, plein écran, un volet, 60 Hz, une personne qui tape | p50 **49,1–50,8 ms**, p99 82,9–84,2 ms (p50 auparavant 64–68 ms) | 1.2 | [Performance §5.17](../../PERFORMANCE.md#517-full-screen-without-the-compositor-285-2026-10-13) |
| CPU au repos, Release, 20 secondes | 0,05 % | **1.0.0** (2026-09-18) ; non remesuré depuis le travail sur les réveils au repos de la 1.2 | [Performance](../../PERFORMANCE.md) |
| esctest2 | 131 réussis, 334 bugs connus, 102 échoués ; 567 au total | **1.1.5** (2026-10-07) | [Résultats bruts](https://github.com/noah-qin/Corta/blob/f632d5918653cc2feee28fe1baa0c0fd01e93c0e/docs/esctest/2026-10-07-results.txt) |

Mesuré sur un MacBook Air Apple M5 (macOS 27.0.1) ; les lignes 1.2 entre le 2026-10-09 et le 2026-10-13, chaque paire
avant/après sur la même machine et la même chaîne d’outils. Les sections datées de [Performance](../../PERFORMANCE.md)
(en anglais) contiennent les conditions, chaque exécution et ce qu’un chiffre n’établit pas. Le chiffre de 82,0 % parfois
cité pour esctest2 compte les réussites **plus les bugs connus** et n’est pas un taux de réussite ; voir
[Conformance](../../CONFORMANCE.md) (en anglais) pour l’interprétation.

Parmi les limites connues : une latence de la touche à l’écran supérieure à l’objectif d’une image en mode fenêtré
(le plein écran avec un seul volet s’en approche le plus), une conformité VT incomplète, une intégration du shell fournie
uniquement pour zsh, bash et fish, et des graphiques Kitty en transmission directe uniquement. La
[référence des limites](../../FEATURES.md#known-limits) (en anglais) donne les détails.

## S’orienter

| Je veux… | Commencer ici |
| :--- | :--- |
| Découvrir chaque fonctionnalité et où elle se trouve | [Guide d’utilisation](USER-GUIDE.md) |
| Configurer Corta | [Configuration](../../CONFIGURATION.md) (en anglais) |
| Comprendre une fonctionnalité ou une limite | [Features](../../FEATURES.md) (en anglais) |
| Diagnostiquer un problème | [Dépannage](TROUBLESHOOTING.md) |
| Migrer depuis iTerm2, Ghostty ou Terminal.app | [Venir d’un autre terminal](USER-GUIDE.md#coming-from-another-terminal) |
| Voir ce qui est prévu ou proposer une idée | [Open issues](https://github.com/noah-qin/Corta/issues) · [Discussions → Ideas](https://github.com/noah-qin/Corta/discussions/categories/ideas) |
| Trouver quelque chose sur quoi travailler | [Good first issues](https://github.com/noah-qin/Corta/labels/good%20first%20issue) · [Help wanted](https://github.com/noah-qin/Corta/labels/help%20wanted) |
| Faire une première contribution | [Contributing](../../../CONTRIBUTING.md) (en anglais) |
| Lancer ou ajouter des tests | [Testing](../../TESTING.md) (en anglais) |
| Comprendre le code | [Architecture](../../DESIGN.md) · [Core API](../../../CortaTerminal/Sources/CortaTerminal/CortaTerminal.docc/CortaTerminal.md) (en anglais) |
| Lire toute la documentation | [Index de la documentation](../../README.md) (en anglais) |

## Contribuer

Les reproductions de bugs, la documentation, les traductions, les tests d’accessibilité et les contributions de code sont
les bienvenus. Commencez par un [good first issue](https://github.com/noah-qin/Corta/labels/good%20first%20issue) ou un
[help wanted](https://github.com/noah-qin/Corta/labels/help%20wanted), et lisez [CONTRIBUTING.md](../../../CONTRIBUTING.md) pour
l’installation et les attentes de relecture. La participation à la communauté suit le
[Code de conduite](../../../CODE_OF_CONDUCT.md).

Vous avez essayé Corta et êtes revenu à votre ancien terminal ? Cela nous intéresse aussi :
le [formulaire Went back](https://github.com/noah-qin/Corta/issues/new?template=went_back.yml)
ne demande aucune reproduction, et « ça ne me convenait pas, tout simplement » est une réponse acceptable.

Signalez les vulnérabilités via le [canal de sécurité privé](../../../SECURITY.md).
Pour discuter avec d’autres utilisateurs et le mainteneur, rejoignez le [Discord](https://discord.gg/QNdWfdwr7j).
Pour les questions d’utilisation dont la réponse doit pouvoir être retrouvée, allez dans [Discussions → Q&A](https://github.com/noah-qin/Corta/discussions/categories/q-a) ;
pour partager un thème ou une configuration, dans [Show and tell](https://github.com/noah-qin/Corta/discussions/categories/show-and-tell).
Pour d’autres problèmes, [ouvrez une issue](https://github.com/noah-qin/Corta/issues/new/choose).
Si vous souhaitez soutenir la maintenance, [parrainez le projet](https://github.com/sponsors/noah-qin).

### Contributeurs

Merci à toutes les personnes qui ont contribué à Corta.

<a href="https://github.com/noah-qin"><img src="https://github.com/noah-qin.png?size=96" width="48" height="48" alt="noah-qin" title="noah-qin"></a>
<a href="https://github.com/FrankChen-CLC"><img src="https://github.com/FrankChen-CLC.png?size=96" width="48" height="48" alt="FrankChen-CLC" title="FrankChen-CLC"></a>

## Licence et identité

Le code source est distribué sous licence [Apache 2.0](../../../LICENSE). Le nom Corta, la mascotte pangolin et l’icône de l’app
font l’objet de conditions séparées dans [NOTICE](../../../NOTICE). Le corps enroulé du pangolin forme un C ; sa queue cyan est un
curseur de terminal. Les [ressources de marque](../../brand/README.md) comprennent la mascotte et l’aperçu pour les réseaux sociaux.
