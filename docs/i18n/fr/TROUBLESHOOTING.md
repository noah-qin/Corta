# Dépannage

[Index de la documentation (anglais)](../../README.md) · [Présentation du projet](README.md)

🇺🇸 [English](../../TROUBLESHOOTING.md) · 🇨🇳 [简体中文](../zh-CN/TROUBLESHOOTING.md) · 🇭🇰 [繁體中文](../zh-Hant/TROUBLESHOOTING.md) · 🇯🇵 [日本語](../ja/TROUBLESHOOTING.md) · 🇰🇷 [한국어](../ko/TROUBLESHOOTING.md) · 🇩🇪 [Deutsch](../de/TROUBLESHOOTING.md) · 🇫🇷 [Français](TROUBLESHOOTING.md) · 🇪🇸 [Español](../es/TROUBLESHOOTING.md) · 🇧🇷 [Português](../pt-BR/TROUBLESHOOTING.md)

> Cette page est une traduction de [TROUBLESHOOTING.md](../../TROUBLESHOOTING.md), dans son état au commit
> [`68169b9`](https://github.com/noah-qin/Corta/blob/68169b98164d5780f2959377a810eaf1be55e524/docs/TROUBLESHOOTING.md).
> Si la version anglaise a changé depuis, ou si les deux diffèrent, la version anglaise fait foi.
> Les messages de macOS sont accompagnés de leur texte anglais d’origine.

Que faire quand Corta ne s’installe pas, ne démarre pas, ou fait quelque chose que votre terminal précédent ne faisait
pas. Chaque entrée dit ce que vous verrez, pourquoi, et la solution — et la dernière section explique comment revenir
proprement à votre ancien terminal si rien de tout cela n’aide, car un rapport qui dit « je suis revenu en arrière, et
voici pourquoi » est l’une des choses les plus utiles que vous puissiez envoyer.

Si une entrée ici est fausse ou manquante, ouvrez une issue avec le modèle **Installation blocker** ou
**Went back to my old terminal** : <https://github.com/noah-qin/Corta/issues/new/choose>.

---

<a id="installing"></a>

## Installation

### « Impossible d’ouvrir Corta, car Apple ne peut pas vérifier la présence de logiciels malveillants » ("Corta can't be opened because Apple cannot check it for malicious software")

Les versions officielles sont signées avec un Developer ID et notarisées. Une version compilée depuis les sources peut ne
pas l’être. Pour une version téléchargée, vérifiez sa somme de contrôle ainsi que les contrôles de l’image et de l’app
ci-dessous, puis signalez le message exact avec la version.

### « Corta est endommagé et ne peut pas être ouvert » ("Corta is damaged and can't be opened")

L’image disque est peut-être incomplète, modifiée ou rejetée par la validation de signature de macOS. Vérifiez-la d’abord
avec le fichier `.sha256` publié à côté. Gardez les deux fichiers dans le dossier de téléchargement et remplacez `x.y.z`
par la version téléchargée :

```sh
shasum -a 256 -c Corta-x.y.z.dmg.sha256
```

Une non-correspondance signifie qu’il faut télécharger à nouveau. Chaque paquet de version est vérifié avec son fichier
compagnon avant publication (`corta-release-check`), donc une non-correspondance est une raison de s’arrêter et de
retélécharger. Si la somme de contrôle correspond, vérifiez l’image et l’app copiée. Remplacez `x.y.z` par la version
téléchargée dans toutes les commandes, et lancez-les depuis le dossier de téléchargement :

```sh
spctl -a -t open --context context:primary-signature -v Corta-x.y.z.dmg
xcrun stapler validate Corta-x.y.z.dmg
spctl --assess --type exec /Applications/Corta.app
xcrun stapler validate /Applications/Corta.app
```

Joignez à votre rapport la version, l’erreur de macOS et ces résultats. Ne contournez pas Gatekeeper pour tester une
version. Les versions jusqu’à la 1.1.8 conservent leurs sommes de contrôle ZIP d’origine ; utilisez le nom de fichier de
cette version.

### Corta propose de se déplacer dans /Applications

Corta a été lancé depuis `~/Downloads` ou un autre dossier. Il fonctionne de n’importe où ; `/Applications` est l’endroit
où les mises à jour Sparkle et Spotlight s’attendent à le trouver. Répondez non et il ne demandera plus — ou mettez
`suggest-applications-folder = false` dans `~/.config/corta/config`.

Ouvert directement depuis l’image disque, macOS exécute Corta depuis un emplacement temporaire en lecture seule, donc il
ne peut pas se déplacer lui-même ; il vous demande plutôt de le faire glisser dans Applications. Si un Corta plus récent
s’y trouve déjà, il propose d’ouvrir celui-là plutôt que de le remplacer par la copie plus ancienne.

### Il y a deux icônes Corta dans le Dock

L’une d’elles est une version de développement. Le Finder l’appelle **Corta Dev**, la barre des menus **CortaDev**, son
icône a un fond orange plutôt que bleu, et son identifiant de bundle est `dev.noahqin.Corta.dev`. Elle garde sa
configuration et son état dans `~/Library/Application Support/Corta Dev/`, jamais dans `~/.config/corta/config` ni
`~/Library/Application Support/Corta/`, et elle n’a pas d’élément de menu « Rechercher les mises à jour… » — c’est donc
celle à l’icône bleue qui est le Corta installé, quel que soit leur ordre d’apparition. Quitter ou supprimer l’une laisse
l’autre intacte. Seules les personnes qui compilent Corta depuis les sources en ont une (`CONTRIBUTING.md`,
« Developing Corta in Corta »).

### « Cette version de Corta nécessite macOS 26.0 ou ultérieur » ("This version of Corta requires macOS 26.0 or later")

La cible de déploiement de Corta est macOS 26.0, et il utilise des API Metal 4 et Core Text de cette version. Il n’existe
pas de version pour les systèmes antérieurs, et le projet n’en prévoit pas (`DESIGN.md` §6).

### « Vous ne pouvez pas ouvrir l’application “Corta” car elle n’est pas prise en charge sur ce type de Mac » ("You can't open the application "Corta" because it is not supported on this type of Mac")

Depuis la 1.1.0, Corta est compilé uniquement pour les puces Apple — un Mac doté d’une puce M1 ou ultérieure
(`DECISIONS.md` D21). Un Mac Intel ne peut pas l’exécuter. La **1.0.1** est la dernière version pour les Mac Intel, et elle
reste disponible sur la [page de la version 1.0.1](https://github.com/noah-qin/Corta/releases/tag/v1.0.1) : téléchargez
`Corta-1.0.1.zip`, vérifiez-le et remplacez la copie dans `/Applications`. Un Mac Intel qui exécute déjà une 1.0.x ne se
voit pas proposer la 1.1.0 par **Rechercher les mises à jour…**, il continue donc de fonctionner tel quel ; ce message
n’apparaît que si une archive plus récente a été téléchargée et ouverte à la main.

Pour savoir quelle puce équipe un Mac, choisissez menu Pomme ▸ À propos de ce Mac : la ligne *Puce* nomme une puce Apple
(M1, M2, …) sur les Mac à puce Apple, et une ligne *Processeur* nomme un processeur Intel.

---

<a id="starting"></a>

## Démarrage

### La fenêtre s’ouvre vide, ou s’ouvre puis se ferme

Lancez depuis Terminal.app pour voir pourquoi :

```sh
/Applications/Corta.app/Contents/MacOS/Corta
```

Un volet qui ne peut pas lancer son shell affiche une vue d’échec avec un bouton **Réessayer** plutôt qu’une zone vide ;
si vous voyez une zone vide sans vue d’échec, c’est un bug de rendu qui mérite un rapport avec la sortie de la console.

### Le shell n’est pas celui que j’attendais, ou n’a pas de PATH

Corta lance `$SHELL` depuis l’environnement avec lequel il a été lancé (sinon `/bin/zsh`) en tant que shell de connexion
(`-l`), donc `~/.zprofile` et `~/.zshrc` s’exécutent tous les deux. Un `$SHELL` qui n’existe plus se rabat sur
`/bin/zsh`, puis sur `/bin/sh`, avec un avis dans le volet indiquant quel échelon a été utilisé. Si des commandes qui
fonctionnent dans Terminal.app sont « introuvables » dans Corta, vérifiez la valeur de `SHELL` dans l’environnement avec
lequel les *applications graphiques* sont lancées (`launchctl getenv SHELL`) : une valeur définie là s’applique à toutes
les apps et survit à la session qui l’a définie. Lancez `launchctl unsetenv SHELL` puis relancez.

Un **préréglage** (Shell ▸ Nouveau volet avec préréglage) ou `preset.<name>.shell` dans le fichier de configuration
remplace ce choix pour un volet.

### Corta a restauré les fenêtres d’hier et je n’en voulais pas

`restore-windows = false` dans `~/.config/corta/config`, ou décochez-le dans Réglages ▸ Général. Une restauration qui a
fait planter l’app n’est pas retentée : la disposition enregistrée est abandonnée et une seule nouvelle fenêtre s’ouvre.

### Les Réglages indiquent qu’ils ne peuvent pas lire le fichier de configuration

`~/.config/corta/config` existe mais n’est pas du texte UTF-8 — généralement un octet enregistré par un éditeur dans un
autre encodage — ou vous ne pouvez pas le lire. Corta conserve les réglages qu’il a et refuse d’écrire le fichier, car
l’écrire en remplacerait tout le contenu. Réenregistrez le fichier en UTF-8 (ou supprimez la ligne fautive) ; Corta le
prend en compte dès qu’il le relit. L’intégration du shell fait de même pour un fichier rc qu’elle ne peut pas lire : elle
le signale et n’y touche pas.

---

<a id="typing-and-rendering"></a>

## Saisie et rendu

### Effacer l’écran ne laisse qu’un curseur, sans invite

Mettez Corta à jour si ⌘K efface une invite en attente. Avec l’intégration du shell et un marqueur de fin d’invite prête,
Effacer l’écran conserve désormais l’invite affichée et la saisie non envoyée, y compris son curseur d’édition. Il n’envoie
ni Retour, ni Contrôle-L, ni aucune autre saisie. Activez l’intégration du shell pour un shell sans marqueurs d’invite ; les
sessions zsh locales standard la chargent automatiquement avec les suggestions fournies. Le réaffichage par Contrôle-L du
shell reste une alternative quand ce shell le configure. Un programme sur l’écran alternatif, ou un éditeur multiligne
dont l’invite est déjà dans l’historique, est volontairement laissé intact.

### Les suggestions de dossiers s’arrêtent après un dossier se terminant par `/`

Seuls les sous-dossiers sont des candidats ; un dossier ne contenant que des fichiers n’a pas de suggestion suivante. Tapez
une partie du nom d’un sous-dossier ou appuyez de nouveau sur Tab quand des candidats sont visibles. Tab insère le chemin sans
l’exécuter ; Retour lance `cd`. Les dossiers cachés demandent un point au début. S’il manque un sous-dossier connu, vérifiez
l’accès à ce dossier et comparez avec la complétion native du shell après avoir désactivé `directory-completion`. Si la
différence persiste, signalez la forme exacte du chemin et le shell.

### À propos ou l’historique des commandes s’ouvre loin du terminal

Fermez puis rouvrez la fenêtre dans la version actuelle de Corta. Les deux s’ouvrent centrées sur la fenêtre qui les appelle,
dans la zone utilisable de son écran ; elles ne sont pas placées au centre de l’écran entier. Une fenêtre déjà ouverte garde
la position que vous avez choisie.

### Tab ne fait rien dans le menu des commandes slash de Claude Code

Corrigé dans la 1.0.0 (B02) ; la v0.1.1 a le bug. S’il réapparaît sur une version plus récente, signalez-le avec la
version de Claude Code : la correction tient à la façon dont `insertTab(_:)` issu d’une fenêtre de candidats atteint le
programme enfant, et une nouvelle interface de candidats pourrait l’acheminer autrement.

### ⌥ tape `é`, `ø`, `–` au lieu d’agir comme Meta

C’est le comportement par défaut de macOS, et Corta le conserve. Mettez `option-as-meta = true` pour que ⌥ envoie `ESC` +
touche, comme la touche Alt d’un clavier de PC. Les touches spéciales (flèches, touches de fonction) transmettent ⌥ comme
modificateur xterm dans tous les cas.

### Les couleurs ou `TERM` semblent incorrects via ssh

Corta annonce volontairement `TERM=xterm-256color` (`docs/DECISIONS.md` D08). Partager cette valeur de TERM n’implique pas
une compatibilité xterm complète. Vérifiez l’environnement distant avec `printf '%s\n' "$TERM"` et comparez un cas
minimal de reproduction ; [Conformance](../../CONFORMANCE.md#42-external-suites) (en anglais) recense les séquences prises en
charge et les échecs restants.

### Un glyphe est dessiné plus petit que ses voisins

Un caractère absent de la police choisie vient de PingFang SC ou d’Apple Color Emoji. Un glyphe de secours peut être mis à
l’échelle pour rester dans ses cellules de terminal, si bien que sa taille visible peut différer de celle des glyphes
voisins. Ajustez la taille de police dans **Réglages ▸ Apparence** et comparez l’aperçu. Si un glyphe est rogné ou mal
aligné, signalez son texte, la police, la taille de police, l’échelle d’affichage et une capture d’écran.

### La police que j’ai choisie n’est pas celle qui est dessinée

`font-family` désigne une famille, pas un style (`JetBrains Mono`, pas `JetBrainsMono-Regular`). Corta ne l’utilise que si
elle est installée et que ses styles normal, gras et italique avancent de la même largeur sur tout l’ASCII imprimable ;
sinon, il dessine la police système à largeur fixe et **Réglages ▸ Apparence** affiche une ligne État de la police
indiquant quelle vérification a échoué. Une police installée pendant que Corta tourne apparaît aussitôt dans la liste ;
Réessayer revérifie celle qui est configurée.

Du chinois, du japonais ou du coréen dessiné dans une autre police que celle choisie sous **Police CJK**
(`font-family-cjk`) signifie que cette famille n’est pas installée ou n’a pas de caractères CJK ; la ligne sous le menu le
dit, et c’est la police de la langue du système qui dessine à la place. Un caractère absent de la police choisie vient
aussi de la police de la langue du système. La police CJK n’est pas utilisée tant que
**Utiliser d’autres polices pour les caractères manquants** est désactivé.

### Les images de `kitten icat` ne s’affichent pas, ou s’affichent au mauvais endroit

Corta implémente la transmission directe (dans le flux) du protocole graphique de Kitty en RGB, RGBA et PNG. La
transmission par fichier (`t=f`, `t=t`, `t=s`), les images d’animation et le placement par caractères de substitution
Unicode ne sont pas implémentés, et la transmission par fichier ne le sera pas : un flux distant désignant un fichier
local à lire est exactement ce que rejette le modèle de menaces (`SECURITY.md` §1). Essayez
`kitten icat --transfer-mode=stream picture.png` pour demander explicitement la transmission directe. Une image doit
respecter les limites de 8192 pixels par côté et de 16 millions de pixels ; les images invalides ou trop grandes sont refusées.

### Un Retour vide dessine une marque de commande verte ou rouge

Un Retour vide n’est pas une commande, et les hooks d’intégration actuels n’en enregistrent aucune. Un bloc de fichier de
démarrage installé par un Corta plus ancien peut encore en signaler une : ouvrez
**Réglages ▸ Terminal ▸ Intégration du shell**, choisissez **Mettre à jour**, puis ouvrez un nouveau shell. Les shells
existants gardent les anciennes fonctions jusqu’à leur redémarrage, et les marques déjà dessinées restent. Seul le bloc
Corta balisé du fichier de démarrage est mis à jour. Les sessions zsh locales standard utilisant les hooks automatiques
reçoivent la version fournie au démarrage d’un nouveau shell.

---

<a id="behaviour-that-differs-from-other-terminals"></a>

## Comportements différents des autres terminaux

### La copie se fait dès que je termine ma sélection

`copy-on-select` est activé par défaut et confirme par une étiquette dans le coin du volet. Mettez-le à `false` pour ⌘C uniquement.

### Un programme a dit avoir copié dans mon presse-papiers, et rien n’a été copié

L’*écriture* OSC 52 est désactivée par défaut : sinon n’importe quelle sortie de programme pourrait mettre dans le
presse-papiers un texte que vous colleriez ensuite. `allow-clipboard-write = true` l’active, et c’est ce dont ont besoin
`tmux` et une session `ssh` distante. Le sens *lecture* n’existe sous aucun réglage.

### Fermer une fenêtre me demande si je suis sûr

Quelque chose dans cette fenêtre a encore une tâche au premier plan. `confirm-close = false` désactive la question partout.

### Le raccourci du Terminal rapide ne fait rien

Trois possibilités, dans l’ordre. `quick-terminal` vaut `false` (par défaut) : aucune touche n’est réservée tant que vous
ne le mettez pas à `true`. Une autre application détient déjà la touche : Réglages ▸ Terminal rapide le signale, et
`quick-terminal-key` accepte toute autre combinaison comportant au moins une touche de modification. Ou bien la touche est
une que Corta ne peut pas associer à une position de touche (`é`, une écriture en deux caractères) : la ligne est
conservée telle quelle dans le fichier de configuration et la valeur par défaut s’applique. Présentation ▸ Terminal
rapide et l’action Raccourcis *Afficher/masquer le terminal rapide* ouvrent le panneau dans tous les cas.

### Le badge d’un volet distant indique « Distant : hôte inconnu », ou un `tmux` local « Distant ? »

Le badge tire le nom de l’hôte du rapport `OSC 7` du shell distant lui-même, ou — pour une connexion ouverte depuis la
feuille de connexion — de la destination que vous y avez saisie. Il ne le lit jamais dans une ligne de commande `ssh` tapée
à l’invite (alias, noms de `~/.ssh/config` et chaînes de rebond seraient tous mal lus) ni dans le texte de l’invite. Sans
l’un ou l’autre, un volet `ssh` indique *hôte inconnu*, ce qui est la vérité. Pour obtenir l’hôte, placez aussi le bloc
d’intégration du shell de Réglages ▸ Terminal dans le `~/.zshrc` de la machine distante ; il émet l’`OSC 7` que lit le
badge. Un `tmux` ou un `screen` au premier plan affiche *Distant ?* parce que la session à laquelle il est attaché peut
elle-même se trouver sur une autre machine, et rien ici ne permet de le savoir — c’est une incertitude, pas une accusation.

### Parcourir les fichiers distants… indique un échec d’authentification, mais `ssh` fonctionne dans le volet

La connexion SFTP demande un mot de passe ou une phrase secrète de clé dans une boîte de dialogue sur sa fenêtre ; une
boîte refusée ou annulée aboutit à cette erreur. Vérifiez l’utilisateur et le port dans le formulaire — les `User` et
`Port` propres à un alias ne s’appliquent que si ces champs sont vides — et la clé, si vous en avez choisi une : une clé
choisie est la seule proposée. Si aucune boîte de dialogue n’est apparue, le serveur a refusé toutes les méthodes que ssh
pouvait essayer ; `ssh -v` avec le même utilisateur, le même port et la même clé dans un terminal montre lesquelles.

### Parcourir les fichiers distants… indique qu’une clé d’hôte n’a pas pu être vérifiée

Un hôte vu pour la première fois vous demande de faire confiance à sa clé, dans une boîte de dialogue qui affiche
l’empreinte. Cette erreur signifie que la clé a *changé* depuis que vous lui avez fait confiance — un serveur réinstallé,
ou quelqu’un au milieu. ssh refuse tant que l’ancienne ligne n’est pas retirée de `~/.ssh/known_hosts`
(`ssh-keygen -R <host>`) ; demandez d’abord à l’administrateur du serveur.

### L’historique des commandes affiche « (texte de la commande plus dans l’historique) »

Le texte d’une commande est récupéré dans la grille, pas stocké : une fois sa ligne d’invite sortie au-delà de
`scrollback-lines`, l’entrée garde son heure, son statut et son dossier, mais le texte a disparu, et Remplir et Exécuter
ne sont pas proposés pour elle. Augmentez `scrollback-lines` si cela arrive souvent.

### Je ne peux pas remonter jusqu’au début d’une longue exécution

`scrollback-lines` (10 000 par défaut) est un plafond par session, et il compte les lignes *physiques* — une ligne de
200 colonnes repliée à 100 colonnes en compte deux. La sortie plus ancienne que le plafond est supprimée à mesure qu’elle
arrive ; la pastille en haut indique jusqu’où remonte la vue. Augmentez le plafond (jusqu’à 1 000 000 ; la mémoire
occupée par l’historique ancien compressé dépend du texte et de la charge). Une cellule stockée fait 16 octets avant
compression, ce qui n’est pas une estimation de la mémoire résidente. Une charge mesurée de 100 000 lignes de 120 colonnes
a ajouté environ 11 Mio de mémoire résidente ; voir
[Performance](../../PERFORMANCE.md#56-numbers-by-release) (en anglais). Exportez la sortie que vous devez conserver au-delà du
plafond configuré.

### La Saisie clavier sécurisée est activée mais mon outil de macros fonctionne encore

Le cadenas dans la barre de titre indique quand elle est *engagée*, ce qui n’est le cas que tant qu’une fenêtre de
terminal Corta est la fenêtre active et que Corta est l’application active. Dans toute autre application, et tant que les
Réglages sont la fenêtre active, les frappes sont transmises normalement — c’est le principe, et c’est pourquoi
l’indicateur suit l’état engagé plutôt que le réglage.

### Une icône de proxy de dossier manque sur un montage réseau

Corta vérifie en arrière-plan le dossier local signalé. Si le montage est lent ou si deux vérifications sont déjà en
attente, il laisse l’icône de proxy absente pour que la sortie et l’interaction au clavier puissent continuer. Vérifiez le
montage séparément ; changer de dossier après son rétablissement déclenche une nouvelle vérification.

### Un volet s’ouvre dans le dossier personnel au lieu d’un dossier réseau

Un nouveau volet, ou une fenêtre restaurée au lancement, ne démarre dans le dossier demandé que si celui-ci répond dans un
court délai. Un volume réseau qui ne répond plus est considéré comme absent, si bien que le volet s’ouvre dans le dossier
personnel plutôt que de figer Corta. Le même délai s’applique au ⌘-clic ou au survol d’une référence `path:line` à cet
endroit : elle n’est pas proposée comme lien. Reconnectez le volume, puis faites `cd` vers lui ou ouvrez-y un nouveau volet.

### L’édition à distance redemande après une demande d’envoi

Le fichier local a changé après la version montrée par la demande initiale. Approuvez explicitement la nouvelle
modification. Une ancienne entrée gérée sans empreinte du contenu distant demande aussi une décision de conflit une fois.
Une comparaison de contenu peut repérer des changements distants même quand la taille et l’horodatage sont inchangés.

### Un envoi d’édition à distance redemande après une longue attente

La connexion s’est bloquée. Une fois connecté, chaque opération d’édition à distance dispose de 120 secondes ; ensuite
Corta ferme la connexion et propose à nouveau l’envoi. Approuvez-le pour réessayer sur une nouvelle connexion. Un très gros
fichier sur un lien lent peut aussi atteindre la limite : copiez-le plutôt avec le navigateur SFTP.

---

<a id="appearance-and-the-status-bar"></a>

## Apparence et barre d’état

### Le curseur ne clignote pas

Le clignotement est désactivé par défaut : activez **Faire clignoter le curseur** dans Réglages ▸ Apparence ▸ Curseur.
Il s’interrompt quand le volet est inactif, masqué ou remonté dans l’historique. Un programme du terminal peut changer la
forme ou le clignotement pour lui-même avec DECSCUSR ; Réinitialiser le terminal revient au style configuré.

### La barre d’état n’affiche aucun débit réseau, ou le mauvais

Les débits nécessitent deux mesures, laissez donc quelques secondes après avoir activé la barre. `auto` mesure une
interface principale ; quand un VPN ou plusieurs adaptateurs en font la mauvaise, saisissez le nom de l’interface dans
Réglages ▸ Terminal. Une interface explicitement indiquée qui n’existe pas n’affiche aucun débit. La barre rend toujours
compte du Mac local, y compris dans un volet SSH, et les niveaux thermiques sont des classifications de macOS, pas des
températures. Une fenêtre étroite peut tronquer la barre ; cliquez dessus pour voir toutes les valeurs choisies.

### L’éditeur de thème refuse d’enregistrer

Une couleur HEX invalide désactive Enregistrer. Si le thème personnalisé a été modifié dans le fichier de configuration
pendant que l’éditeur était ouvert, fermez et rouvrez l’éditeur avant d’enregistrer, pour ne pas écraser cette modification.

### L’interface est dans la mauvaise langue

Corta suit la langue que macOS choisit pour lui (Réglages Système ▸ Général ▸ Langue et région ▸ Applications).
Redémarrez Corta après l’avoir changée. Le format des nombres suit la région et peut différer de la langue.

---

<a id="updating"></a>

## Mises à jour

### Rechercher les mises à jour… ne trouve rien

Corta compare des **numéros de build**, pas des chaînes de version, avec `appcast.xml` sur la branche `main`. Une version
étiquetée et en brouillon mais pas encore publiée n’est pas dans le flux ; une fois publiée, la chaîne de publication signe
et vérifie le flux, ouvre une pull request, attend la CI et la fusionne en squash ou active la fusion automatique. Une
vérification du flux en échec ou bloquée peut retarder la livraison, laissez donc un peu de temps après l’apparition de la
version sur GitHub. `update-auto-check = false` ne désactive que la vérification quotidienne en arrière-plan ; l’élément
de menu fonctionne toujours.

---

<a id="going-back-to-your-old-terminal"></a>

## Revenir à votre ancien terminal

Quittez Corta avant de supprimer ses fichiers. Examinez les copies gérées de l’édition à distance pour y repérer du travail
non enregistré avant de supprimer les données de l’app :

1. **Intégration du shell**, si vous l’avez installée depuis Réglages ▸ Terminal : supprimez-la là, ou effacez le bloc
   entre `# >>> Corta shell integration >>>` et `# <<< Corta shell integration <<<` dans le fichier de démarrage de votre
   shell — `~/.zshrc` ; pour bash dans `~/.bashrc` et `~/.bash_profile` (ou `~/.bash_login` / `~/.profile`) ; ou
   `~/.config/fish/config.fish`. Rien d’autre dans ce fichier n’appartient à Corta.
2. **La Saisie clavier sécurisée** se libère d’elle-même quand Corta quitte. Si Corta a été forcé à quitter alors qu’une
   fenêtre était active et que la saisie semble bloquée ailleurs, lancez et quittez Corta une fois ; le compteur est
   rééquilibré à la sortie.
3. **Réglages et état** : `~/.config/corta/` (le fichier de configuration) et `~/Library/Application Support/Corta/`
   (disposition des fenêtres, historique des dossiers et copies gérées de l’édition à distance). Ne les supprimez
   qu’après avoir conservé les modifications locales dont vous avez encore besoin. Le moteur de rendu garde aussi des
   fichiers de cache jetables dans `~/Library/Caches/dev.noahqin.Corta/` ; ils peuvent être supprimés.
4. Placez `Corta.app` dans la Corbeille.

Ensuite, si vous le voulez bien, ouvrez une issue avec le formulaire
[**Went back to my old terminal**](https://github.com/noah-qin/Corta/issues/new?template=went_back.yml) et dites ce qui
vous a fait revenir. Aucune reproduction n’est nécessaire. Une fonctionnalité manquante, un bug de rendu et « ça me
semblait simplement plus lent » sont autant de réponses sur lesquelles le projet peut agir.
