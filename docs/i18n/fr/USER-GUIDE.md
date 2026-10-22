# Guide d’utilisation

[Index de la documentation (anglais)](../../README.md) · [Présentation du projet](README.md)

🇺🇸 [English](../../USER-GUIDE.md) · 🇨🇳 [简体中文](../zh-CN/USER-GUIDE.md) · 🇭🇰 [繁體中文](../zh-Hant/USER-GUIDE.md) · 🇯🇵 [日本語](../ja/USER-GUIDE.md) · 🇰🇷 [한국어](../ko/USER-GUIDE.md) · 🇩🇪 [Deutsch](../de/USER-GUIDE.md) · 🇫🇷 [Français](USER-GUIDE.md) · 🇪🇸 [Español](../es/USER-GUIDE.md) · 🇧🇷 [Português](../pt-BR/USER-GUIDE.md)

> Cette page est une traduction de [USER-GUIDE.md](../../USER-GUIDE.md), dans son état au commit
> [`04ad320`](https://github.com/noah-qin/Corta/blob/04ad320438030e3ba4a7c19761b0279e39c42afc/docs/USER-GUIDE.md).
> Si la version anglaise a changé depuis, ou si les deux diffèrent, la version anglaise fait foi.
> Les noms d’interface suivent l’interface française de Corta ; clés de configuration, commandes et code restent en version originale.

Tout ce que fait Corta, et comment y accéder. Chaque section indique où se trouve la fonctionnalité — un menu, un
raccourci, un réglage — et renvoie à la référence qui donne les détails. Les raccourcis sont ceux par défaut, et tous
sauf Rechercher le suivant et Rechercher le précédent peuvent être modifiés ([Raccourcis clavier](#keyboard-shortcuts)).

- [Installer et mettre à jour](#install-and-update)
- [Venir d’un autre terminal](#coming-from-another-terminal)
- [Fenêtres, onglets et volets](#windows-tabs-and-panes)
- [Texte, polices et thèmes](#text-fonts-and-themes)
- [Personnaliser le terminal](#personalizing-the-terminal)
- [Quand une session se termine](#when-a-session-ends)
- [Historique, recherche et sélection](#scrollback-search-and-selection)
- [Liens et références de fichiers](#links-and-file-references)
- [Intégration du shell](#shell-integration)
- [Le répertoire de travail](#the-working-directory)
- [Suggestions de dossiers (zsh)](#directory-suggestions-zsh)
- [Travail à distance : SSH et SFTP](#remote-work-ssh-and-sftp)
- [Images dans le terminal](#images-in-the-terminal)
- [La palette de commandes](#the-command-palette)
- [Le Terminal rapide](#the-quick-terminal)
- [Intégration à macOS](#macos-integration)
- [Vitesse et batterie](#speed-and-battery)
- [Réglages et fichier de configuration](#settings-and-the-config-file)
- [Raccourcis clavier](#keyboard-shortcuts)
- [Quand quelque chose ne va pas](#when-something-goes-wrong)

<a id="install-and-update"></a>

## Installer et mettre à jour

Corta nécessite **macOS 26.0 ou ultérieur**, une **puce Apple** et un **GPU compatible Metal 4**. Une machine virtuelle
avec un GPU paravirtualisé ne peut pas afficher le terminal. Téléchargez le `.dmg` et son fichier `.sha256` depuis
[GitHub Releases](https://github.com/noah-qin/Corta/releases/latest), gardez-les dans le même dossier et vérifiez la
somme de contrôle à cet endroit avant d’ouvrir l’image (remplacez `x.y.z` par la version téléchargée) :

```sh
shasum -a 256 -c Corta-x.y.z.dmg.sha256
open Corta-x.y.z.dmg
```

Faites glisser Corta dans Applications, puis éjectez l’image. Les versions depuis la 1.1.9 sont des images disque ;
la 1.1.8 et les précédentes gardent leurs ZIP d’origine.

Les versions officielles sont signées avec un Developer ID et notarisées. Si macOS refuse un téléchargement, suivez le
[Dépannage](TROUBLESHOOTING.md#installing). Lancé depuis un autre endroit, Corta propose de se déplacer dans
`/Applications` (`suggest-applications-folder`).

**Mises à jour.** **Corta ▸ Rechercher les mises à jour…** vérifie immédiatement ; une vérification en arrière-plan a lieu
une fois par jour sauf si `update-auto-check = false`. Une mise à jour n’est installée que si vous le décidez.

<a id="coming-from-another-terminal"></a>

## Venir d’un autre terminal

Corta n’a pas d’outil d’importation : il lit un seul fichier texte, `~/.config/corta/config`, et la fenêtre Réglages
modifie ce même fichier. La plupart des habitudes se transposent avec quelques clés. La colonne de gauche indique où
l’habitude se trouve ailleurs ; celle de droite donne la clé Corta ([Configuration](../../CONFIGURATION.md), en anglais,
donne les valeurs de chacune et quand elle s’applique).

| Si vous comptiez sur… | Dans Corta |
| :--- | :--- |
| ⌥ comme Meta / Alt (*Left Option key: Esc+* dans iTerm2, `macos-option-as-alt` dans Ghostty) | `option-as-meta = true`. Désactivé par défaut, pour que ⌥ tape `é`, `ø` et `–` comme le fait macOS. |
| Copier à la sélection | `copy-on-select`, **activé** par défaut. Mettez `false` pour ⌘C uniquement. |
| Une fenêtre à raccourci global ou un terminal rapide | `quick-terminal = true` ; la touche est `quick-terminal-key` (⌥Espace par défaut). Désactivé par défaut : un raccourci global est réservé dans toutes les applications. [Le Terminal rapide](#the-quick-terminal). |
| Des programmes qui copient dans le presse-papiers via `ssh` ou depuis `tmux` (OSC 52) | `allow-clipboard-write = true`. Désactivé par défaut ; lire le presse-papiers est impossible quel que soit le réglage. |
| Une confirmation avant de fermer une fenêtre occupée | `confirm-close`, activé par défaut. |
| Des fenêtres qui rouvrent là où vous les aviez laissées | `restore-windows`, activé par défaut. Dispositions, onglets et répertoires de travail reviennent ; les processus et le texte du terminal, non. |
| Votre propre jeu de couleurs | Un thème défini dans le fichier (`theme.<name>.*`), ou **Présentation ▸ Éditeur de thème…**. [Créer et modifier des thèmes](#creating-and-editing-themes). |
| Vos propres raccourcis | `bind.<command> = <shortcut>`. Les noms de commandes sont dans [Raccourcis clavier](#keyboard-shortcuts). |
| Une police de votre choix | **Réglages ▸ Apparence ▸ Police**, ou `font-family`. Seules les familles à chasse fixe que Corta peut placer sur sa grille sont proposées. |
| Ligatures, transparence ou réglages par profil | Non disponibles ; ils ne sont [pas proposés](../../CONFIGURATION.md#6-what-is-deliberately-not-configurable), et chacun exige d’abord une décision. Les préréglages couvrent un shell, un dossier et un environnement ([Presets](../../CONFIGURATION.md#4a-presets)). |
| Le mode de contrôle `tmux -CC` | Non pris en charge (D09). Un `tmux` ordinaire tourne dans Corta comme n’importe quel programme. |

**Intégration du shell.** Les sessions zsh locales standard chargent les hooks de Corta sans toucher à vos fichiers de
démarrage. Si votre `~/.zshrc`, `~/.bashrc` ou `config.fish` charge encore l’intégration d’un autre terminal — celle
d’iTerm2, de WezTerm, de Visual Studio Code —, **Réglages ▸ Terminal ▸ Intégration du shell** signale un conflit
possible ; les deux peuvent émettre des marques d’invite. Voir [Intégration du shell](#shell-integration).

**`TERM`.** Corta s’annonce comme `xterm-256color` (D08). Un hôte distant qui fonctionne déjà avec iTerm2 ou Terminal.app
n’a besoin de rien de nouveau ; un hôte configuré pour `xterm-ghostty` ou `xterm-kitty` reçoit à la place la valeur courante.

Les comportements qui diffèrent plus légèrement — copie, fermeture, raccourci du Terminal rapide, badges distants — sont
rassemblés dans
[Dépannage → Comportements différents des autres terminaux](TROUBLESHOOTING.md#behaviour-that-differs-from-other-terminals).

<a id="windows-tabs-and-panes"></a>

## Fenêtres, onglets et volets

| Pour… | Utilisez |
| --- | --- |
| Ouvrir une fenêtre / un onglet | ⌘N / ⌘T |
| Onglet précédent / suivant | ⇧⌘[ / ⇧⌘] |
| Renommer l’onglet courant | Double-clic sur le titre de l’onglet, ou clic droit ▸ Renommer l’onglet… |
| Diviser le volet à droite / vers le bas | ⌘D / ⇧⌘D |
| Déplacer le focus entre les volets | ⌥⌘ + touche fléchée |
| Redimensionner le volet actif | ⌃⌘ + touche fléchée |
| Remplir la fenêtre avec un volet, puis revenir | ⇧⌘↩ (Agrandir le volet) |
| Donner la même taille à tous les volets | Égaliser les volets (palette de commandes) |
| Fermer le volet, l’onglet ou la fenêtre | ⌘W |
| Rétablir le volet que vous venez de fermer | ⇧⌘T |

- Renommez un onglet directement dans son titre : double-cliquez, ou choisissez Renommer l’onglet… dans son menu
  contextuel. Retour enregistre, Échap annule, et un nom vide rétablit le titre automatique. Les noms personnalisés
  survivent à la sortie du shell et à la restauration des sessions. Les menus contextuels de l’onglet et du terminal
  proposent aussi Nouvel onglet, et le bouton **+** de la barre d’outils en ouvre un, que la barre d’onglets soit
  affichée ou non ; la barre d’onglets n’a pas de **+** à elle.
- **Agrandir le volet** est temporaire : rien n’est fermé et aucun processus n’est dérangé.
- **Rouvrir le volet fermé** rétablit la place, la taille et le répertoire de travail du volet — pas le programme qui y tournait.
- Fermer un volet où une commande tourne encore demande d’abord confirmation (`confirm-close`).
- **Restauration des fenêtres.** Quittez et relancez : chaque fenêtre revient avec ses onglets, ses divisions, la position
  de ses séparateurs et le répertoire de travail de chaque volet (`restore-windows`, activé par défaut). Chaque volet
  démarre un nouveau processus ; le texte du terminal et les tâches en cours ne sont pas restaurés. Le Terminal rapide
  est exclu.
- **Préréglages.** Un préréglage est un shell, un dossier et un environnement nommés, définis dans le fichier de
  configuration. **Shell ▸ Nouveau volet avec préréglage** en ouvre un ; maintenez ⌥ pour l’ouvrir dans une fenêtre à
  part ([Presets](../../CONFIGURATION.md#4a-presets)).
- Les nouvelles fenêtres s’ouvrent à `columns` × `rows` cellules (120 × 30 par défaut).

<a id="text-fonts-and-themes"></a>

## Texte, polices et thèmes

- **Police.** Réglages ▸ Apparence ▸ Police liste la police système à largeur fixe (par défaut) et chaque famille à
  chasse fixe installée que Corta peut placer sur sa grille, en deux groupes : Polices Apple (fournies avec macOS, ou les
  polices à la demande d’Apple une fois téléchargées dans Livre des polices) et Installées par vous. La ligne sous le menu
  indique d’où vient la police choisie et si elle apporte ses propres caractères CJK — une telle famille dessine aussi les
  lettres et symboles dans son style CJK, un `~` surélevé par exemple. `font-family` dans le fichier de configuration est le
  même réglage. `font-size` vaut 13 pt par défaut, de 10 à 24 pt en points entiers. La page offre un aperçu de la police,
  des couleurs et du curseur.
- **Graisse et interligne.** La graisse est Maigre, Normale (par défaut) ou Medium ; une police sans cette graisse utilise
  sa normale, et le texte en gras est toujours le gras propre de la police. L’interligne va de 1,0 à 1,4 fois la taille
  de police, 1,18 par défaut ; une police qui a besoin d’une ligne plus haute la conserve, donc rien n’est rogné.
  Chaque caractère de chaque langue partage une même taille de cellule et une même ligne de base.
- **Caractères absents de la police.** Le chinois, le japonais et le coréen viennent des polices de macOS : les
  idéogrammes Han de PingFang SC, PingFang TC, Hiragino Sans ou Apple SD Gothic Neo selon la langue du système, les kana
  de Hiragino Sans et le hangul d’Apple SD Gothic Neo quelle que soit la langue. Pour les dessiner dans une police de votre
  choix — Menlo pour les lettres et Sarasa Gothic ou LXGW WenKai pour le chinois, par exemple —, choisissez-la sous
  **Police CJK** (`font-family-cjk`). Toute police installée contenant des caractères chinois, japonais ou coréens est
  listée, à chasse fixe ou non : elle ne dessine que ces caractères, centrés dans leurs deux cellules, et la police
  principale garde la taille de cellule. Les emoji viennent d’Apple Color Emoji — ou, avec Emoji réglé sur
  Monochrome si possible, sous forme de glyphe texte quand Apple Symbols ou Menlo en a un. Un caractère large est centré
  dans ses deux cellules. Désactivez **Utiliser d’autres polices pour les caractères manquants** pour ne voir que la
  police choisie, avec un rectangle là où elle n’a pas de glyphe.
- **Caractères de largeur ambiguë.** Réglages ▸ Terminal ▸ Caractères de largeur ambiguë rend `±`, `§`, le grec, le
  cyrillique et les autres caractères « East Asian Ambiguous » larges de deux cellules, pour les logiciels écrits pour
  des terminaux CJK. Cela s’applique à la sortie écrite ensuite ; un shell ou un éditeur qui mesure lui-même le texte
  peut encore les compter comme une seule cellule.
- **Soulignements.** Les programmes peuvent dessiner des soulignements simples, doubles (`SGR 21` ou `4:2`) et ondulés
  (`SGR 4:3`, les diagnostics de Neovim) ; pointillés et tirets sont dessinés en simple. Le texte clignotant (`SGR 5`) est
  conservé mais pas animé.
- **Zoom.** ⌘= / ⌘− / ⌘0 ou un pincement agrandissent le texte, le réduisent ou reviennent à la taille configurée, dans la
  fenêtre courante uniquement. Le zoom ne modifie jamais le fichier de configuration. Les changements de police ne
  déplacent ni ne redimensionnent jamais la fenêtre : les lignes et colonnes visibles s’y réajustent, et ce qui reste
  d’une cellule apparaît en fond sous la dernière ligne.
- **Thème.** Trois thèmes intégrés, `corta`, `solarized` et `mono`, chacun en variante claire et sombre ;
  `appearance = auto` suit macOS quand il bascule. Vous pouvez définir votre propre thème via
  **Présentation ▸ Éditeur de thème…** ou dans le fichier de configuration, ou hériter d’un thème et changer quelques
  couleurs ([Themes](../../CONFIGURATION.md#4-themes)).
- **Unicode.** Le texte chinois, japonais et coréen occupe deux colonnes et s’aligne avec le reste ; emoji, signes
  combinants, drapeaux et séquences d’emoji forment chacun une grappe. Les caractères absents de la police viennent des
  polices de secours du système. Les séquences de présentation emoji standardisées (un caractère texte suivi de VS16,
  comme ⚠️ ou ✍️) occupent deux colonnes ; la présentation texte reste étroite.
- **Méthodes de saisie.** Pinyin, kana, hangul et toutes les autres méthodes de saisie de macOS composent sur place, avec
  la fenêtre de candidats à côté du curseur.
- **Couleurs vraies.** Couleur 24 bits, palette de 256 couleurs, gras, italique, souligné, barré, atténué et inversé.
- **⌥ comme Meta.** Désactivé par défaut, pour que ⌥ tape les caractères de la disposition. Mettez
  `option-as-meta = true` pour des touches Meta à la manière d’Emacs.
- **Bip.** Un éclair du volet (`bell = visual`), ou un son (`bell = audible`).

<a id="personalizing-the-terminal"></a>

## Personnaliser le terminal

<a id="cursor-appearance"></a>

### Apparence du curseur

Ouvrez Réglages (⌘,) → Apparence → Curseur. Choisissez Bloc, Barre ou Souligné, puis activez Faire clignoter le curseur
si vous le souhaitez. Par défaut : **Bloc, sans clignotement**. Les trois formes et l’interrupteur indépendant donnent six
combinaisons. Ce sont aussi `cursor-shape` et `cursor-blink` dans le fichier de configuration. Les changements
s’appliquent aux volets ouverts. Les programmes du terminal peuvent choisir temporairement leur propre forme et leur
propre clignotement via DECSCUSR ; le paramètre 0 ou une réinitialisation du terminal ramène à vos valeurs configurées.
Le clignotement s’interrompt lorsqu’un volet est inactif, masqué ou affiche l’historique.

<a id="input-source-indicator"></a>

### Indicateur de source de saisie

Le terminal actif affiche un petit badge dans la barre d’outils en haut à droite de la fenêtre : `A` pour une saisie
directe confirmée, `中` pour le chinois, `あ` pour le japonais et `한` pour le coréen. Les autres sources affichent leur
code de langue. Survolez-le pour le nom complet de la source. Un badge neutre identifie les sources dont macOS ne signale
pas le mode de saisie interne, y compris les IME tiers dotés de leur propre bascule vers l’anglais. Corta ne devine jamais
ce mode à partir du texte tapé et ne change jamais la source de saisie.

Réglages ▸ Clavier et souris ▸ Indicateur de source de saisie propose **Automatique** (par défaut),
**Toujours dans le volet actif** ou **Désactivé**. Par défaut, l’indicateur n’apparaît que chez les utilisateurs ayant
activé une disposition de clavier non latine ou un IME ; les configurations uniquement latines restent épurées. Revenir à
une disposition latine laisse un `A` discret sur un fond pâle — gris dans la barre d’outils, dans la couleur de texte du
thème à côté de l’invite. Les dispositions non latines et les modes d’IME intégrés utilisent une teinte indigo douce ; les
modes d’IME inconnus, du gris. À côté de l’invite, les couleurs suivent la luminosité du thème du terminal plutôt que
celle de macOS. Dans la barre d’outils, le badge reste pendant qu’un programme tourne — Claude Code, un éditeur —, car il
ne masque aucune sortie. Au bord droit de la ligne de commande, l’intégration du shell le masque pendant l’exécution des
commandes en mode **Automatique**. **Toujours** peut le garder pendant la sortie des commandes. Les deux modes d’invite le
masquent pendant la lecture de l’historique ou l’utilisation d’un programme en écran alternatif.

Le réglage **Position** propose **Barre d’outils de la fenêtre** (par défaut) ou **Bord droit de la ligne de commande**.
Le badge de la barre d’outils est indépendant des boutons Connexion et Nouvel onglet et reste fixe quand les commandes
s’allongent ou passent à la ligne. Le désactiver ou choisir la ligne de commande retire son emplacement et son espacement
de la barre d’outils. Sur la ligne de commande, les commandes longues déplacent le badge vers une ligne libre plus bas,
toujours au bord droit ; il se masque quand il ne reste aucune ligne sûre, et n’insère jamais de ligne ni ne fait défiler
le programme enfant. Les couleurs de saisie directe et d’IME acceptent des valeurs hexadécimales ; videz un champ pour le
style discret par défaut.

[Badge de source de saisie chinoise](../../brand/input-source-indicator.png) ·
[Évitement des commandes longues](../../brand/input-source-long-command.png)

<a id="optional-local-system-status"></a>

### État du système local (facultatif)

Ouvrez Réglages (⌘,) → Terminal, activez la barre d’état inférieure, puis choisissez les indicateurs à afficher :
utilisation du CPU, charge du système, utilisation de la mémoire, débits réseau, espace disque libre et état thermique.
Elle est désactivée par défaut ; chaque indicateur a son propre interrupteur. Cliquez sur la barre pour voir le nom de
l’hôte local, la version de macOS, la puce, le nombre de cœurs et la mémoire totale. La barre indique Local même dans un
volet SSH ; elle ne surveille pas un serveur distant. Dans une fenêtre étroite, cliquez pour voir tous les indicateurs choisis.

L’interface réseau est automatique par défaut. Une seule interface principale est mesurée, si bien que le trafic VPN ne
s’ajoute pas au trafic physique. Saisissez un nom d’interface précis dans les réglages pour mesurer celle-là. La mesure
s’arrête tant que toutes les barres activées sont masquées. L’état thermique est un rapport de macOS en quatre niveaux,
pas une température.

La barre utilise des libellés compacts, un seul espace comme séparateur et des unités d’octets courtes ; les noms complets
et la précision se trouvent dans son infobulle, sa valeur d’accessibilité et la fenêtre contextuelle des détails de l’hôte.

<a id="creating-and-editing-themes"></a>

### Créer et modifier des thèmes

Réglages → Apparence → Créer un thème ouvre un éditeur graphique. Nommez votre copie, basculez entre les variantes sombre
et claire, et changez les couleurs avec des sélecteurs ou des valeurs HEX. L’aperçu se met à jour sans modifier les
fenêtres du terminal. Enregistrer le thème l’active et le conserve ; Annuler garde votre thème précédent. Les thèmes
personnalisés proposent Modifier le thème. Restaurer les couleurs source réinitialise la variante courante. Vous pouvez
toujours modifier le même fichier de configuration à la main. Si ce thème personnalisé change en dehors de l’éditeur,
rouvrez l’éditeur avant d’enregistrer.

Présentation → Éditeur de thème ouvre directement l’édition graphique des couleurs. Présentation → Détails de l’hôte local
affiche la configuration de l’hôte sans nécessiter la barre d’état facultative. Le même bouton de détails de l’hôte se
trouve dans Réglages → Terminal. Les aperçus d’Apparence suivent immédiatement les changements de mode explicites et
montrent la forme et le clignotement du curseur choisis. Les programmes du terminal peuvent toujours remplacer
temporairement le style du curseur.

<a id="compact-tab-indentation-zsh"></a>

### Indentation compacte avec Tab (zsh)

Les sessions zsh locales standard chargent automatiquement les hooks fournis quand les suggestions de dossiers sont
activées (par défaut). Vous n’avez pas besoin de modifier vos fichiers de démarrage. Si vous utilisez des arguments zsh
personnalisés ou avez désactivé ce démarrage automatique, installez ou mettez à jour l’intégration du shell dans
Réglages → Terminal, puis ouvrez un nouveau shell. Avec ces hooks chargés, Tab sur une ligne de commande ne contenant que
des espaces insère quatre espaces. Tab après du texte de commande conserve la complétion existante. C’est un widget ZLE ;
les taquets de tabulation de la sortie du terminal restent à huit colonnes, et les programmes plein écran continuent de
recevoir la touche Tab. Sans l’intégration, le shell garde son propre comportement pour Tab.

<a id="language"></a>

### Langue

L’app suit la langue préférée que macOS choisit pour Corta : anglais, chinois simplifié et traditionnel, japonais,
coréen, allemand, français, espagnol et portugais du Brésil. Redémarrez Corta après avoir changé sa langue dans macOS.
Le format des nombres suit la région actuelle.

<a id="when-a-session-ends"></a>

## Quand une session se termine

Un volet conserve sa sortie après la fin du shell : la sortie est légèrement assombrie et un panneau dit en une phrase ce
qui s’est terminé et comment — le code de sortie, ou le signal qui l’a arrêté. Le curseur disparaît, mais le défilement,
la sélection, la copie et la recherche ⌘F fonctionnent toujours autour du panneau. **Nouvelle session** relance le shell
ou le préréglage dans le volet ; **Fermer le panneau** le ferme. Une session SSH connectée directement indique à quel hôte
elle était connectée et propose **Reconnecter** pour établir une nouvelle connexion ; le code de sortie 255 de ssh est
expliqué comme un réseau coupé ou un hôte qui ne répond plus. Les deux boutons effacent la sortie au-dessus — le panneau
le dit — et la nouvelle session démarre à la taille et à la taille de police du volet. Quitter Python ou un autre
programme pour revenir à un shell actif ne termine pas la session du terminal.

Quand l’entrée ou la sortie d’une session échoue, ou qu’un volet ne s’affiche plus, le même panneau propose **Réessayer**
ou, pour une connexion, **Reconnecter** ; le texte d’erreur du système est sous **Détails**.

![Session terminée conservant sa dernière sortie et les actions de reprise](../../brand/session-ended.png)

<a id="scrollback-search-and-selection"></a>

## Historique, recherche et sélection

- **Défilement.** Le trackpad ou la molette, ou ⇧PageUp / ⇧PageDown, ⇧Home / ⇧End. Chaque session conserve
  `scrollback-lines` lignes d’historique (10 000).
- **Recherche.** ⌘F ouvre la barre de recherche sur l’historique ; ⌘G et ⇧⌘G vont au résultat suivant et précédent.
  **Respecter la casse** et **`*`** (expression régulière) s’y activent, et leur état est mémorisé dans le fichier de
  configuration (`search-case-sensitive`, `search-regex`). La barre se place en haut à droite du volet et passe en bas
  tant que le curseur ou le résultat courant se trouverait dessous ; dans une division étroite, elle se rétrécit plutôt
  que de couvrir le volet. Chaque volet a sa propre barre.
- **Sélection.** Faites glisser pour sélectionner, double-cliquez pour un mot, triple-cliquez pour une ligne. Une
  sélection terminée est copiée aussitôt (`copy-on-select`) ; ⌘C copie aussi. Dans un programme qui utilise la souris —
  `vim`, `htop` —, maintenez ⌥ en commençant à faire glisser pour sélectionner du texte malgré tout
  (`mouse-override-modifier`).
- **Coller.** ⌘V. Le texte collé est marqué comme collage (bracketed paste), si bien qu’un shell qui le prend en charge —
  zsh, fish, bash 5.1 ou ultérieur — insère une commande collée sans l’exécuter avant que vous appuyiez sur Retour.
  Quand le programme n’a pas activé le bracketed paste (le `/bin/bash` 3.2 de macOS ne le fait jamais), Corta avertit
  avant de coller un texte contenant un saut de ligne. Un gros collage que le shell traite encore peut être annulé avec
  ⌃C : la partie pas encore envoyée est abandonnée et l’interruption passe directement.
- **Exporter le texte…** (⇧⌘S) enregistre la sélection — ou, sans sélection, tout l’historique et l’écran — dans un fichier.
- **Effacement.** Trois commandes, car elles ne suppriment pas la même chose :

  | Commande | Écran | Historique | Modes et couleurs |
  | --- | --- | --- | --- |
  | Effacer l’écran (⌘K) | effacé | conservé | conservés |
  | Effacer l’historique | conservé | supprimé | conservés |
  | Réinitialiser le terminal | effacé | supprimé | réinitialisés |

  Effacer l’historique et Réinitialiser le terminal demandent d’abord et indiquent combien de lignes seraient supprimées —
  sauf si l’historique est vide ou si `confirm-close = false` désactive la question.

<a id="links-and-file-references"></a>

## Liens et références de fichiers

- **Les URL** affichent leur cible et l’indication du ⌘-clic au survol, et s’ouvrent d’un ⌘-clic ; mettez
  `link-activation = click` pour les ouvrir d’un simple clic. Maintenez ⌘ au-dessus d’un lien — y compris un lien qu’un
  programme marque explicitement (OSC 8, comme l’affiche `ls --hyperlink`) — pour le souligner et voir sa vraie cible dans
  une infobulle avant de cliquer ; le clic lui-même l’ouvre aussitôt.
- **Références de fichiers.** Un `path:line:column` dans la sortie d’un programme — une erreur de compilation, un test
  en échec — s’ouvre dans votre éditeur d’un ⌘-clic. Indiquez à Corta quel éditeur avec `open-file-command`, en
  commençant par le chemin complet de l’éditeur, par exemple
  `open-file-command = /usr/local/bin/code --goto {file}:{line}:{column}`
  ([Following a file reference](../../CONFIGURATION.md#following-a-file-reference)).

Ouvrir une référence de fichier exige un `open-file-command` configuré. Corta n’ouvre jamais un fichier issu de la sortie
dans son application par défaut du système : certains types de fichiers exécutent du code à l’ouverture.

<a id="shell-integration"></a>

## Intégration du shell

L’intégration du shell permet à Corta de voir où chaque commande commence et se termine. Installez-la depuis
**Réglages ▸ Terminal ▸ Intégration du shell** : elle ajoute un bloc balisé au fichier de démarrage de votre shell —
`~/.zshrc` ; pour bash, à la fois `~/.bashrc` et `~/.bash_profile` (ou le fichier de connexion que bash lit) ; ou
`~/.config/fish/config.fish` — et **Supprimer** retire exactement ce bloc. Le bloc n’est installé dans le fichier de
démarrage que lorsque vous appuyez sur le bouton. Les sessions zsh locales standard chargent aussi automatiquement les
hooks fournis par Corta, sans modifier vos fichiers de démarrage, quand **Suggestions de dossiers (zsh)** est activé
(par défaut). Les arguments zsh personnalisés, bash, fish et les shells distants n’utilisent pas ce démarrage
automatique. Installez-y des hooks compatibles pour y obtenir les limites des commandes.

Lorsque les réglages signalent une intégration obsolète, choisissez **Mettre à jour** et ouvrez un nouveau shell. Mettre à
jour l’app seule ne remplace pas un bloc installé auparavant dans un fichier de démarrage.

Une fois les hooks chargés, automatiquement ou via le fichier de démarrage :

- **Marques d’invite.** Un filet fin à gauche de chaque invite, vert quand la commande a réussi et rouge quand elle a
  échoué. Un Retour vide ne dessine aucun filet et ne crée aucune entrée terminée dans l’historique des commandes.
- **Sauts.** ⌘↑ / ⌘↓ passent d’une commande à l’autre ; ⇧⌘↑ / ⇧⌘↓ d’une commande échouée à l’autre.
- **La sortie d’une commande.** Depuis la palette de commandes : **Copier la sortie de la dernière commande**,
  **Instantané de la sortie de la commande en cours** (ce qu’un build a affiché jusqu’ici),
  **Exporter la sortie de la commande…** vers un fichier, et
  **Ouvrir la référence de fichier dans la sortie de la commande**, qui ouvre le dernier `path:line` affiché.
- **Historique des commandes.** **Rechercher dans l’historique des commandes…** liste chaque commande avec son heure, son
  statut de sortie et son dossier ; **Remplir** la remet à l’invite et **Exécuter** la relance (`command-history-limit`).
  Une commande que la liste ne peut pas montrer entière — sur plusieurs lignes, coupée au bord de la ligne ou contenant
  une tabulation — ou dont le texte a changé depuis que la liste l’a affichée est remplie plutôt qu’exécutée, pour qu’elle
  soit entièrement à l’invite et ne s’exécute que sur votre Retour.
- **Notifications des tâches longues.** Avec `notify-on-long-task = true`, une commande ayant duré plus de
  `notification-threshold` secondes (30) envoie une notification à la fin **si sa fenêtre n’est pas la fenêtre active**,
  à condition que macOS ait accordé à Corta l’autorisation des notifications. Activez-la dans Réglages ▸ Général et
  vérifiez-y l’état de l’autorisation. Cliquez sur la notification pour aller à la commande.

Sans intégration du shell, ces commandes sont désactivées plutôt que de ne rien faire en silence, et les notifications se
rabattent sur une estimation fondée sur la saisie et la sortie.

<a id="the-working-directory"></a>

## Le répertoire de travail

Corta connaît le dossier où se trouve votre shell quand celui-ci le signale (l’intégration du shell le fait). Depuis la
palette de commandes :

- **Afficher le répertoire de travail dans le Finder** et **Copier le chemin du répertoire de travail**.
- **Passer au répertoire parent** et **Passer à la racine du projet** (le dossier le plus proche contenant `.git`) tapent
  le `cd` pour vous — seulement quand aucune commande ne tourne et que l’invite est vide.
- **Ouvrir le répertoire parent dans un nouveau panneau** et **Ouvrir la racine du projet dans un nouveau panneau**
  divisent le volet avec un shell démarré à cet endroit.

L’icône de dossier dans la barre de titre représente aussi ce dossier : faites-la glisser, ou ⌘-cliquez dessus pour voir
le chemin. Avec `directory-history` activé (par défaut), Corta enregistre les dossiers locaux dans lesquels vos commandes
ont été exécutées. Rien dans l’app ne les liste encore ; **Réglages ▸ Confidentialité et sécurité ▸ Historique** indique
leur nombre et les efface.

<a id="directory-suggestions-zsh"></a>

## Suggestions de dossiers (zsh)

Corta inclut des suggestions de dossiers, activées par défaut dans les sessions zsh locales standard. Tapez `cd ` pour
voir les dossiers du répertoire courant en texte pâle sous votre saisie. Continuez à taper pour filtrer ; un suffixe pâle
apparaît à côté du curseur. Par exemple, `cd De` peut suggérer `Developer/`. Les suggestions sont des aperçus : elles ne
font pas partie de votre commande tant qu’elles ne sont pas acceptées.

![Suggestions de dossiers sous cd, avec des marques de commandes réussies, échouées et interrompues](../../brand/directory-suggestions.png)

Tant qu’une suggestion est visible :

| Touche | Action |
| --- | --- |
| Gauche / Droite | Choisir le dossier précédent / suivant au lieu de déplacer le curseur de saisie. |
| Tab | Insérer le dossier choisi dans la saisie, sans l’exécuter. Remplace la complétion Tab native tant que les suggestions sont visibles. |
| Échap | Fermer les suggestions pour la saisie en cours. Appuyez sur Échap avant d’utiliser Gauche / Droite pour modifier la commande, ou une seconde fois pour l’action Échap du shell. |
| Haut / Bas | Conserver la navigation normale dans l’historique des commandes du shell. |
| Maj+Tab | Transmettre au raccourci configuré dans le shell. |
| Retour | N’exécuter que la saisie réelle ; ne jamais accepter automatiquement une suggestion pâle. |

Vous pouvez filtrer des chemins relatifs, des sous-dossiers et des chemins `~/`. Les dossiers cachés apparaissent quand
vous tapez un point en préfixe. Les expressions shell complexes gardent la complétion native. Bash et fish conservent leur
propre complétion ; les suggestions n’apparaissent que dans un shell que Corta a démarré avec ses hooks zsh automatiques,
jamais sur des machines distantes ni dans des commandes de shell personnalisées, même avec l’intégration du shell installée.

**Facultatif : les désactiver.** Dans **Réglages ▸ Terminal ▸ Shell**, désactivez **Suggestions de dossiers (zsh)**, ou
mettez ceci dans votre fichier de configuration :

```ini
directory-completion = false
```

Cela désactive immédiatement les suggestions de Corta et l’interception des touches, en laissant disponibles l’édition et
la complétion natives du shell. Rouvrez le shell après les avoir réactivées. Il n’y a aucun bloc de fichier de démarrage
à supprimer pour les hooks locaux automatiques. Si vous avez aussi installé l’intégration du shell manuellement, son
bouton **Supprimer** retire ce bloc distinct ; ce n’est pas nécessaire pour désactiver les suggestions de dossiers.

<a id="remote-work-ssh-and-sftp"></a>

## Travail à distance : SSH et SFTP

Corta utilise l’OpenSSH du système — votre `~/.ssh/config`, vos clés, votre agent et `ProxyJump` s’appliquent tous — et
n’a pas sa propre implémentation de SSH.

- **Le badge d’hôte.** Un volet connecté à une autre machine affiche *Distant :* au début du titre de la fenêtre. Il nomme
  l’hôte et le dossier quand le shell distant les signale (intégration du shell installée là-bas), et la destination que
  vous avez saisie quand la connexion vient de la feuille de connexion ; sinon, il indique que le volet est distant sans
  savoir quel hôte.
- **Reconnexion.** Quand une session `ssh` ou `mosh` se termine, **Se reconnecter à l’hôte** relance la même commande, comme
  une nouvelle connexion.
- **Connexion.** Le bouton globe de la barre d’outils ouvre **Se connecter à un hôte**, une feuille avec un sélecteur
  **Terminal / Fichiers (SFTP)** : un terminal par SSH, ou le navigateur de fichiers. Tapez l’hôte — un nom, une adresse,
  `user@host` ou un alias SSH. **Options avancées** contient l’utilisateur, le port et une clé privée ; laissés vides, ce
  sont votre `~/.ssh/config` et les valeurs par défaut d’OpenSSH qui décident. Une clé choisie est proposée en premier, et
  les autres clés de `ssh-agent` ne sont pas essayées. La feuille liste les connexions récentes — avec le port, la clé et
  leur dernière utilisation — et les noms `Host` de votre `~/.ssh/config`. Les hôtes qui n’acceptent que git
  (`github.com`, ou un `Host` avec `User git`) n’y figurent pas, et la liste dit lesquels. Tapez pour filtrer la liste,
  cliquez sur une entrée (ou utilisez ↑ et ↓ depuis le champ hôte) pour remplir les champs, double-cliquez ou appuyez sur
  Retour pour vous connecter. Une connexion de terminal rejoint la liste récente une fois établie — un hôte qui vous refuse
  ou n’a pas de shell, non. Survolez un hôte récent et cliquez sur ✕, ou faites un clic droit dessus, pour l’oublier ;
  Réglages ▸ Confidentialité et sécurité ▸ Hôtes récents les efface tous.
- **Les fichiers de ce volet.** Ouverte depuis un volet connecté à une autre machine, la feuille propose d’abord les
  fichiers de cet hôte ; appuyez sur Retour ou sur **Parcourir les fichiers** pour les ouvrir.
- **Parcourir les fichiers distants…** ouvre un navigateur SFTP pour l’hôte du volet : lister, envoyer, télécharger,
  renommer et supprimer. La première connexion à un hôte vous demande de confirmer son nom. Les transferts reprennent
  après une interruption et n’écrasent jamais un fichier sans demander. Un téléchargement de dossier s’arrête si un nom
  entre en conflit avec un fichier intermédiaire `.corta-part`, en préservant le fichier existant. Choisissez une autre
  destination ou réglez ce fichier individuellement ; un écrasement de tout le dossier ne peut pas absorber un fichier partiel.
- **Dans le navigateur**, comme dans le Finder : ⌘[ et ⌘] reculent et avancent, ⌘↑ remonte au dossier parent, ⌘R
  actualise, ⇧⌘G (ou un clic sur le chemin) permet de taper un chemin, ⇧⌘N crée un dossier et ⇧⌘. affiche les fichiers
  masqués. Cliquez sur un titre de colonne pour trier. Faites un clic droit sur une ligne pour ses actions ;
  double-cliquez sur un dossier pour l’ouvrir. Déposez des fichiers du Finder sur la liste — ou sur une ligne de dossier — pour les envoyer ; pendant le glissement, la liste (ou la ligne) est encadrée et indique la destination. Faites glisser un fichier vers le Finder pour le télécharger. Les transferts sont sous le bouton
  flèches de la barre d’outils, avec la vitesse, le temps restant et Afficher dans le Finder.
- **Modifier un fichier distant.** **Modifier** dans le navigateur — ou un ⌘-clic sur un `path:line` dans un volet
  distant — télécharge une copie et l’ouvre dans votre éditeur. Réglez d’abord
  **Réglages ▸ Terminal ▸ Ouvrir le fichier avec**, avec le chemin absolu d’un exécutable d’éditeur et les marqueurs
  `{file}`, `{line}`, `{column}` ([exemples](../../CONFIGURATION.md#following-a-file-reference)). Envoyer vos modifications est
  une étape séparée et explicite, et Corta vérifie d’abord si le fichier distant a changé entre-temps. Les fichiers de plus
  de 64 Mio ne sont pas copiés de cette façon ; téléchargez-les depuis le navigateur, qui affiche la progression et peut
  annuler. Une copie que personne n’a ouverte ni modifiée depuis 30 jours est supprimée lors de l’utilisation suivante de
  l’édition à distance ; une copie contenant des modifications ni envoyées ni abandonnées est conservée.
- **Noms.** Un nom distant contenant des caractères de contrôle, de droite à gauche ou de largeur nulle les affiche en `�`,
  et un téléchargement les enregistre en `_`, pour qu’un nom ne puisse pas se faire passer pour un autre.

Quand le serveur demande un mot de passe, une phrase secrète de clé ou un code à usage unique, ou quand un hôte est nouveau
et que sa clé requiert votre décision, le navigateur le demande dans une boîte de dialogue sur sa fenêtre et transmet
votre réponse à OpenSSH ; rien n’est enregistré, donc une reconnexion redemande. **Annuler la connexion** dans la boîte
du mot de passe met fin à cette tentative et revient au champ hôte — rien n’est envoyé comme mot de passe vide.
**Annuler** sur la phrase secrète d’une clé ne fait que sauter cette clé, et ssh passe au moyen de connexion suivant.
La boîte de dialogue de clé d’hôte affiche l’empreinte et a Annuler pour bouton par défaut. Une clé détenue par
`ssh-agent` ou le trousseau, ou une connexion `ControlMaster` existante depuis votre terminal, se connecte sans rien
demander.

Une connexion qui échoue dit pourquoi en une phrase — mot de passe ou clé refusé, hôte qui ne répond pas, clé d’hôte
inconnue ou modifiée, serveur sans SFTP — avec les mots de ssh sous **Détails**, et propose **Réessayer** ou
**Modifier la connexion**.

Les envois d’édition à distance comparent le contenu distant en plus de la taille et de la date de modification, et
envoient l’instantané privé que vous avez approuvé. Si vous enregistrez une autre modification locale après la demande
d’approbation, Corta demande une nouvelle décision ; les enregistrements pendant un envoi restent en attente. Après un
échec de connexion, la modification ou l’envoi suivant se reconnecte, et un envoi échoué garde sa décision en attente.
Préservez les modifications locales non décidées avant de supprimer les données de l’app. Voir la
[politique des données au repos](../../SECURITY.md#5-data-at-rest) (en anglais).

<a id="images-in-the-terminal"></a>

## Images dans le terminal

Les programmes qui parlent le **protocole graphique de kitty** peuvent afficher des images dans le texte :

```sh
kitten icat --transfer-mode=stream picture.png
```

Les images défilent avec le texte, restent dans l’historique et sont supprimées par Effacer l’écran ou Effacer
l’historique avec le texte qui les entoure. Dans la région de défilement d’un programme — le volet d’un programme plein
écran, par exemple —, une image se déplace avec le texte de la région et est rognée là où elle dépasse son bord. Une image
peut mesurer jusqu’à 8192 pixels de côté et 16 millions de pixels au total. D’autres outils qui prennent en charge le
protocole, comme `timg` ou `chafa`, peuvent aussi l’utiliser, tant qu’ils envoient l’image elle-même : Corta refuse par
principe de lire un chemin de fichier désigné par un programme, et l’animation n’est pas prise en charge. Une image plus
grande que le volet est réduite pour y tenir.

<a id="the-command-palette"></a>

## La palette de commandes

⇧⌘P ouvre la palette de commandes : toutes les commandes de Corta, consultables par leur nom, avec leur raccourci à côté.
Tapez quelques lettres et appuyez sur Retour. Les lettres correspondent dans l’ordre, pas forcément de manière contiguë
(`spr` trouve Split Pane Right) ; le nom d’un groupe (`panes`) ou le nom de configuration d’une commande (`new-tab`) la
trouve aussi. Les commandes récemment exécutées apparaissent en premier. Cliquer sur une autre fenêtre ferme la palette et
laisse cette fenêtre au premier plan. C’est le moyen le plus rapide d’atteindre les commandes sans raccourci par défaut.

<a id="the-quick-terminal"></a>

## Le Terminal rapide

Un terminal qui descend par-dessus ce que vous êtes en train de faire. Ouvrez-le depuis
**Présentation ▸ Terminal rapide**, depuis la palette de commandes, ou avec un raccourci global une fois activé :

```ini
quick-terminal = true
quick-terminal-key = alt+space
quick-terminal-position = top      # top, bottom ou center
```

Le raccourci est désactivé par défaut, car une touche globale est retirée à toutes les autres applications.

<a id="macos-integration"></a>

## Intégration à macOS

- **Raccourcis.** Trois actions : **Ouvrir une fenêtre Corta** (éventuellement dans un dossier),
  **Mettre une fenêtre Corta au premier plan** et **Afficher/masquer le terminal rapide**. Aucune n’exécute de commande
  dans un shell.
- **Services.** Le texte sélectionné dans le terminal est proposé au menu **Services**.
- **Saisie clavier sécurisée.** **Shell ▸ Saisie clavier sécurisée** empêche les autres applications de lire vos frappes
  tant que Corta est au premier plan — pour taper des mots de passe. Un cadenas dans la barre de titre indique quand elle
  est effectivement active.
- **VoiceOver** lit le texte du terminal et suit le volet actif.
- **Presse-papiers depuis les programmes.** Désactivé par défaut. Avec `allow-clipboard-write = true`, un programme — y
  compris dans `tmux` ou via `ssh` — peut mettre du texte dans votre presse-papiers (OSC 52). Rien ne peut le relire.

<a id="speed-and-battery"></a>

## Vitesse et batterie

Corta fait de lui-même ce qui est rapide ; rien ici ne demande de réglage. Voici ce qu’il fait, pour que vous sachiez à
quoi vous attendre.

- **La frappe obtient la fréquence maximale de l’écran.** Pendant que vous tapez, collez ou composez avec une méthode de
  saisie, Corta demande la fréquence d’images maximale de l’écran — 120 Hz sur un écran ProMotion — et la laisse
  redescendre une seconde après la dernière touche. Le mode économie d’énergie, une fenêtre inactive et la pression
  thermique abaissent de nouveau le plafond quand vous ne tapez pas ; une pression thermique critique le fait toujours.
- **Le plein écran avec un seul volet peut réduire la latence sous macOS 27 ou ultérieur.** Corta présente alors ses
  images directement à l’écran, en contournant le compositeur du serveur de fenêtres : environ une image de moins de la
  touche à l’écran sur le Mac mesuré. Une division, la barre de recherche ou tout autre élément dessiné par-dessus le
  texte fait revenir le compositeur tant qu’il est affiché. Sous macOS 26, chaque fenêtre utilise le chemin de copie par
  file classique, mesure de compatibilité face à un plantage de WindowServer (#380) ; les chiffres de latence ci-dessus
  n’ont pas été mesurés sur ce système. (`CORTA_DIRECT_FULLSCREEN=0` dans l’environnement de lancement désactive les
  changements liés au plein écran, mais pas le chemin de compatibilité de macOS 26.)
- **Lecture de la sortie et affichage ont des rythmes séparés.** Le lecteur PTY continue d’analyser pendant que l’écran
  présente le dernier état au rythme de l’affichage. Un banc d’essai mesuré du débit du cœur a atteint 317,3 Mio/s ; ce
  chiffre exclut les E/S du PTY, le rendu et l’affichage, et ne promet pas une vitesse pour un vrai journal de build ou
  pour `yes`.
- **Le défilement et les programmes plein écran ne redessinent que ce qui a changé.** vim, less, tmux et une ligne d’état
  défilent en décalant ce qui est déjà dessiné.
- **Un long historique reste léger.** L’historique est compressé en mémoire à mesure qu’il sort de l’écran — l’augmentation
  mesurée de la mémoire pour 100 000 lignes de 120 colonnes était d’environ 11 Mio — et la recherche, la copie et le
  redimensionnement travaillent directement dessus.
- **Au repos, c’est vraiment au repos.** Un curseur clignotant est animé par macOS au lieu d’être redessiné par Corta, un
  shell au repos ne provoque aucun réveil périodique, et une fenêtre couverte ou réduite cesse complètement de dessiner.
- **Les volets masqués cèdent la place.** Deux secondes après qu’un volet est masqué — un autre onglet, une fenêtre
  réduite —, sa sortie est lue en priorité d’arrière-plan, pour ne pas concurrencer ce que vous regardez. Rien n’est
  perdu, et taper ou coller dedans rétablit aussitôt la pleine priorité.

[Performance](../../PERFORMANCE.md) (en anglais) contient les mesures et la façon dont elles ont été faites.

<a id="settings-and-the-config-file"></a>

## Réglages et fichier de configuration

Tous les réglages se trouvent dans un seul fichier texte, `~/.config/corta/config`. **Corta ▸ Réglages…** (⌘,) modifie
ce même fichier, et le modifier à la main est tout aussi pris en charge :

Les Réglages se présentent comme une barre latérale de catégories, à la manière de Réglages Système :

- **Général** — la taille des nouvelles fenêtres, la restauration des fenêtres, la confirmation de fermeture, les
  notifications des tâches longues et les mises à jour.
- **Apparence** — clair ou sombre, la police système à largeur fixe, la taille et un aperçu en direct, la forme et le
  clignotement du curseur, et l’édition graphique des thèmes.
- **Terminal** — l’historique, la limite de l’historique des commandes, le bip, les valeurs par défaut de la recherche,
  la commande d’ouverture de fichier, l’intégration du shell, l’état du système facultatif et les détails de l’hôte local.
- **Clavier et souris** — Utiliser Option comme Meta, la façon d’ouvrir les liens, la touche de modification qui
  sélectionne du texte quand un programme a la souris, la copie à la sélection, et les modes et couleurs de l’indicateur
  de source de saisie.
- **Raccourcis** — la touche de chaque commande ; une flèche de réinitialisation apparaît à côté de celles que vous avez modifiées.
- **Terminal rapide** — le raccourci global, la position et l’écran.
- **Connexions** — Se connecter à un hôte et préréglages enregistrés.
- **Confidentialité et sécurité** — l’écriture dans le presse-papiers par les programmes (OSC 52), la Saisie clavier
  sécurisée, l’historique des dossiers et les hôtes récents.

Ces commandes modifient le même fichier de configuration. Les couleurs des thèmes personnalisés peuvent être modifiées
graphiquement ou via le fichier.

Le bouton globe de la barre d’outils de la fenêtre se connecte à un hôte, pour un terminal ou pour ses fichiers : une
feuille sur la fenêtre avec l’hôte — il peut être un alias de configuration — et l’utilisateur, le port et la clé privée
sous **Options avancées** ; elle suggère les hôtes récents et configurés, et un utilisateur, un port ou une clé laissés
vides respectent la configuration d’OpenSSH. Depuis un volet distant, elle propose d’abord les fichiers de cet hôte
([Travail à distance](#remote-work-ssh-and-sftp)).

```ini
theme = corta
appearance = auto
font-size = 14
scrollback-lines = 20000
notify-on-long-task = true
bind.equalize-panes = ctrl+cmd+e
```

La plupart des réglages s’appliquent immédiatement ; quelques-uns (taille de fenêtre, longueur de l’historique)
s’appliquent à la fenêtre ou session suivante. [Configuration](../../CONFIGURATION.md) (en anglais) liste chaque clé, sa valeur
par défaut et le moment où elle prend effet.

<a id="keyboard-shortcuts"></a>

## Raccourcis clavier

Changez n’importe quel raccourci avec `bind.<command>` dans le fichier de configuration ; une valeur vide le supprime, et
la frappe atteint alors le programme dans le terminal :

```ini
bind.equalize-panes = ctrl+cmd+e
bind.close =
```

**Aide ▸ Raccourcis clavier** affiche ceux qui sont en vigueur en colonnes alignées ; les commandes sans raccourci sont
marquées **Non défini**. Le menu contextuel du terminal affiche les mêmes raccourcis configurés.

Le menu **Shell** garde la division, la réouverture et Effacer l’écran directement accessibles. Les autres outils sont
regroupés sous **Déplacer le focus**, **Commandes et sortie**, **Répertoire de travail**, **Disposition des panneaux** et
**Terminal et connexion**.

Les valeurs par défaut, à cette version — [Keyboard shortcuts](../../CONFIGURATION.md#5-keyboard-shortcuts) (en anglais) est la
liste de référence :

| Commande | Raccourci |
| --- | --- |
| Nouvelle fenêtre / Nouvel onglet | ⌘N / ⌘T |
| Fermer | ⌘W |
| Diviser le volet à droite / vers le bas | ⌘D / ⇧⌘D |
| Déplacer le focus | ⌥⌘ + flèche |
| Redimensionner le volet | ⌃⌘ + flèche |
| Agrandir le volet | ⇧⌘↩ |
| Rouvrir le volet fermé | ⇧⌘T |
| Agrandir / Réduire / Taille réelle | ⌘= / ⌘− / ⌘0 |
| Rechercher… / Rechercher le suivant / Rechercher le précédent | ⌘F / ⌘G / ⇧⌘G (Rechercher le suivant et le précédent sont fixes) |
| Copier / Coller / Tout sélectionner | ⌘C / ⌘V / ⌘A |
| Défiler d’une page / jusqu’en haut ou en bas | ⇧PageUp, ⇧PageDown / ⇧Home, ⇧End |
| Commande précédente / suivante | ⌘↑ / ⌘↓ |
| Commande échouée précédente / suivante | ⇧⌘↑ / ⇧⌘↓ |
| Exporter le texte… | ⇧⌘S |
| Effacer l’écran | ⌘K |
| Réglages… | ⌘, |
| Palette de commandes… | ⇧⌘P |

Toutes les autres commandes — Égaliser les volets, Effacer l’historique, Réinitialiser le terminal, Parcourir les fichiers
distants…, les commandes de sortie et de répertoire de travail — n’ont pas de touche par défaut et sont à une recherche de
distance dans la palette de commandes. [Keyboard shortcuts](../../CONFIGURATION.md#5-keyboard-shortcuts) (en anglais) donne le
tableau complet avec le nom `bind.` de chaque commande.

<a id="when-something-goes-wrong"></a>

## Quand quelque chose ne va pas

Le [Dépannage](TROUBLESHOOTING.md) décrit ce que vous voyez quand quelque chose échoue et comment y remédier — un
téléchargement que macOS refuse d’ouvrir, une police refusée, un raccourci qui ne fait rien.
[Features and limitations](../../FEATURES.md) (en anglais) liste ce que Corta ne fait pas encore. Signalez tout le reste sur
[GitHub Issues](https://github.com/noah-qin/Corta/issues/new/choose). Pour les questions d’utilisation, allez dans
[Discussions → Q&A](https://github.com/noah-qin/Corta/discussions/categories/q-a), ou demandez dans `#help` sur le
[Discord](https://discord.gg/QNdWfdwr7j).
