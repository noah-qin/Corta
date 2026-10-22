# Guia do usuário

[Índice da documentação (inglês)](../../README.md) · [Visão geral do projeto](README.md)

🇺🇸 [English](../../USER-GUIDE.md) · 🇨🇳 [简体中文](../zh-CN/USER-GUIDE.md) · 🇭🇰 [繁體中文](../zh-Hant/USER-GUIDE.md) · 🇯🇵 [日本語](../ja/USER-GUIDE.md) · 🇰🇷 [한국어](../ko/USER-GUIDE.md) · 🇩🇪 [Deutsch](../de/USER-GUIDE.md) · 🇫🇷 [Français](../fr/USER-GUIDE.md) · 🇪🇸 [Español](../es/USER-GUIDE.md) · 🇧🇷 [Português](USER-GUIDE.md)

> Esta página é uma tradução de [USER-GUIDE.md](../../USER-GUIDE.md), no estado do commit
> [`04ad320`](https://github.com/noah-qin/Corta/blob/04ad320438030e3ba4a7c19761b0279e39c42afc/docs/USER-GUIDE.md).
> Se a versão em inglês mudou desde então, ou se as duas divergirem, vale a versão em inglês.
> Os nomes da interface seguem a interface em português do Corta; chaves de configuração, comandos e código ficam no original.

Tudo o que o Corta faz e como chegar lá. Cada seção diz onde o recurso fica — um menu, um atalho, um ajuste — e aponta
para a referência com os detalhes. Os atalhos são os padrões, e todos, exceto Buscar próxima e Buscar anterior, podem ser
alterados ([Atalhos de teclado](#keyboard-shortcuts)).

- [Instalar e atualizar](#install-and-update)
- [Vindo de outro terminal](#coming-from-another-terminal)
- [Janelas, abas e painéis](#windows-tabs-and-panes)
- [Texto, fontes e temas](#text-fonts-and-themes)
- [Personalizar o terminal](#personalizing-the-terminal)
- [Quando uma sessão termina](#when-a-session-ends)
- [Histórico, busca e seleção](#scrollback-search-and-selection)
- [Links e referências a arquivos](#links-and-file-references)
- [Integração com o shell](#shell-integration)
- [O diretório de trabalho](#the-working-directory)
- [Sugestões de pastas (zsh)](#directory-suggestions-zsh)
- [Trabalho remoto: SSH e SFTP](#remote-work-ssh-and-sftp)
- [Imagens no terminal](#images-in-the-terminal)
- [A paleta de comandos](#the-command-palette)
- [O Terminal rápido](#the-quick-terminal)
- [Integração com o macOS](#macos-integration)
- [Velocidade e bateria](#speed-and-battery)
- [Ajustes e arquivo de configuração](#settings-and-the-config-file)
- [Atalhos de teclado](#keyboard-shortcuts)
- [Quando algo dá errado](#when-something-goes-wrong)

<a id="install-and-update"></a>

## Instalar e atualizar

O Corta precisa de **macOS 26.0 ou posterior**, **Apple silicon** e uma **GPU compatível com Metal 4**. Uma máquina virtual
com GPU paravirtualizada não consegue desenhar o terminal. Baixe o `.dmg` e o arquivo `.sha256` dele em
[GitHub Releases](https://github.com/noah-qin/Corta/releases/latest), mantenha os dois na mesma pasta e verifique ali a
soma de verificação antes de abrir a imagem (substitua `x.y.z` pela versão baixada):

```sh
shasum -a 256 -c Corta-x.y.z.dmg.sha256
open Corta-x.y.z.dmg
```

Arraste o Corta para Aplicativos e depois ejete a imagem. As versões a partir da 1.1.9 são imagens de disco; a 1.1.8 e
anteriores mantêm os ZIPs originais.

As versões oficiais são assinadas com Developer ID e notarizadas. Se o macOS rejeitar um download, siga a
[Solução de problemas](TROUBLESHOOTING.md#installing). Se for aberto de qualquer outro lugar, o Corta se oferece para
se mover para `/Applications` (`suggest-applications-folder`).

**Atualizações.** **Corta ▸ Verificar atualizações…** verifica na hora; uma verificação em segundo plano roda uma vez por
dia, a menos que `update-auto-check = false`. Uma atualização só é instalada quando você decide.

<a id="coming-from-another-terminal"></a>

## Vindo de outro terminal

O Corta não tem importador: ele lê um único arquivo de texto, `~/.config/corta/config`, e a janela de Ajustes edita esse
mesmo arquivo. A maioria dos hábitos se transfere com um punhado de chaves. A coluna da esquerda diz onde o hábito fica em
outros terminais; a da direita, a chave do Corta ([Configuration](../../CONFIGURATION.md), em inglês, tem os valores de cada uma
e quando se aplica).

| Se você dependia de… | No Corta |
| :--- | :--- |
| ⌥ como Meta / Alt (*Left Option key: Esc+* do iTerm2, `macos-option-as-alt` do Ghostty) | `option-as-meta = true`. Desativado por padrão, para que ⌥ digite `é`, `ø` e `–` como o macOS faz. |
| Copiar ao selecionar | `copy-on-select`, **ativado** por padrão. Use `false` para copiar só com ⌘C. |
| Uma janela com atalho global ou um terminal rápido | `quick-terminal = true`; a tecla é `quick-terminal-key` (⌥Espaço por padrão). Desativado por padrão: um atalho global é reservado em todos os aplicativos. [O Terminal rápido](#the-quick-terminal). |
| Programas que copiam para a área de transferência via `ssh` ou de dentro do `tmux` (OSC 52) | `allow-clipboard-write = true`. Desativado por padrão; ler a área de transferência não é possível em nenhum ajuste. |
| Ser perguntado antes de fechar uma janela ocupada | `confirm-close`, ativado por padrão. |
| Janelas que reabrem onde você as deixou | `restore-windows`, ativado por padrão. Layouts, abas e diretórios de trabalho voltam; processos e texto do terminal, não. |
| Seu próprio esquema de cores | Um tema definido no arquivo (`theme.<name>.*`), ou **Visualização ▸ Editor de temas…**. [Criar e editar temas](#creating-and-editing-themes). |
| Suas próprias teclas de atalho | `bind.<command> = <shortcut>`. Os nomes dos comandos estão em [Atalhos de teclado](#keyboard-shortcuts). |
| Uma fonte à sua escolha | **Ajustes ▸ Aparência ▸ Fonte**, ou `font-family`. Só são oferecidas famílias monoespaçadas que o Corta consegue posicionar na grade. |
| Ligaduras, transparência ou ajustes por perfil | Não disponíveis; [não são oferecidos](../../CONFIGURATION.md#6-what-is-deliberately-not-configurable), e cada um exige antes uma decisão. As predefinições cobrem um shell, um diretório e um ambiente ([Presets](../../CONFIGURATION.md#4a-presets)). |
| Modo de controle `tmux -CC` | Não compatível (D09). O `tmux` comum roda dentro do Corta como qualquer programa. |

**Integração com o shell.** Sessões locais padrão do zsh carregam os hooks do Corta sem mexer nos seus arquivos de
inicialização. Se o seu `~/.zshrc`, `~/.bashrc` ou `config.fish` ainda carrega a integração de outro terminal — a do
iTerm2, do WezTerm, do Visual Studio Code —, **Ajustes ▸ Terminal ▸ Integração com o shell** avisa que pode haver
conflito; as duas podem emitir marcas de prompt. Veja [Integração com o shell](#shell-integration).

**`TERM`.** O Corta se anuncia como `xterm-256color` (D08). Um host remoto que já funciona com o iTerm2 ou o Terminal.app
não precisa de nada novo; um configurado para `xterm-ghostty` ou `xterm-kitty` recebe o valor comum no lugar.

Comportamentos que diferem em detalhes menores — copiar, fechar, o atalho do Terminal rápido, insígnias remotas — estão
reunidos em
[Solução de problemas → Comportamentos diferentes de outros terminais](TROUBLESHOOTING.md#behaviour-that-differs-from-other-terminals).

<a id="windows-tabs-and-panes"></a>

## Janelas, abas e painéis

| Para… | Use |
| --- | --- |
| Abrir uma janela / uma aba | ⌘N / ⌘T |
| Aba anterior / próxima | ⇧⌘[ / ⇧⌘] |
| Renomear a aba atual | Clique duas vezes no título da aba, ou clique com o botão direito ▸ Renomear aba… |
| Dividir o painel à direita / para baixo | ⌘D / ⇧⌘D |
| Mover o foco entre painéis | ⌥⌘ + tecla de seta |
| Redimensionar o painel em foco | ⌃⌘ + tecla de seta |
| Encher a janela com um painel, e voltar | ⇧⌘↩ (Ampliar painel) |
| Deixar todos os painéis do mesmo tamanho | Equalizar painéis (paleta de comandos) |
| Fechar o painel, a aba ou a janela | ⌘W |
| Trazer de volta o painel que você acabou de fechar | ⇧⌘T |

- Renomeie uma aba direto no título: clique duas vezes, ou escolha Renomear aba… no menu de contexto dela. Return salva,
  Esc cancela, e um nome vazio restaura o título automático. Nomes personalizados sobrevivem à saída do shell e à
  restauração de sessões. Os menus de contexto da aba e do terminal também oferecem Nova aba, e o botão **+** da barra de
  ferramentas abre uma, com ou sem a barra de abas visível; a barra de abas não tem **+** próprio.
- **Ampliar painel** é temporário: nada é fechado e nenhum processo é perturbado.
- **Reabrir painel fechado** restaura o lugar, o tamanho e o diretório de trabalho do painel — não o programa que rodava nele.
- Fechar um painel com um comando ainda em execução pergunta antes (`confirm-close`).
- **Restaurar janelas.** Encerre e abra de novo, e cada janela volta com suas abas, divisões, posições dos divisores e o
  diretório de trabalho de cada painel (`restore-windows`, ativado por padrão). Cada painel inicia um processo novo; texto
  do terminal e tarefas em execução não são restaurados. O Terminal rápido fica de fora.
- **Predefinições.** Uma predefinição é um shell, um diretório e um ambiente com nome, definidos no arquivo de
  configuração. **Shell ▸ Novo painel com predefinição** abre uma; segure ⌥ para abri-la numa janela própria
  ([Presets](../../CONFIGURATION.md#4a-presets)).
- Janelas novas abrem com `columns` × `rows` células (120 × 30 por padrão).

<a id="text-fonts-and-themes"></a>

## Texto, fontes e temas

- **Fonte.** Ajustes ▸ Aparência ▸ Fonte lista a monoespaçada do sistema (padrão) e toda família monoespaçada instalada
  que o Corta consegue posicionar na grade, em dois grupos: Fontes da Apple (incluídas no macOS, ou as fontes sob demanda
  da Apple depois de baixadas no Catálogo de Fontes) e Instaladas por você. A linha sob o menu diz de onde vem a fonte
  escolhida e se ela traz caracteres CJK próprios — uma família assim desenha também letras e símbolos no seu desenho CJK,
  um `~` elevado, por exemplo. `font-family` no arquivo de configuração é o mesmo ajuste. `font-size` é 13 pt por padrão,
  de 10 a 24 pt em pontos inteiros. A página mostra uma pré-visualização da fonte, das cores e do cursor.
- **Peso e espaçamento entre linhas.** O peso é Leve, Regular (padrão) ou Média; uma fonte sem esse peso usa a regular, e o
  texto em negrito é sempre o negrito próprio da fonte. O espaçamento entre linhas vai de 1,0 a 1,4 vez o tamanho da fonte,
  1,18 por padrão; uma fonte que precisa de uma linha mais alta a mantém, então nada é cortado. Todo caractere de todo
  idioma compartilha um mesmo tamanho de célula e uma mesma linha de base.
- **Caracteres que faltam na fonte.** Chinês, japonês e coreano vêm das fontes do próprio macOS: os ideogramas han de
  PingFang SC, PingFang TC, Hiragino Sans ou Apple SD Gothic Neo conforme o idioma do sistema, o kana de Hiragino Sans e o
  hangul de Apple SD Gothic Neo, seja qual for o idioma. Para desenhá-los numa fonte sua — Menlo para as letras e
  Sarasa Gothic ou LXGW WenKai para o chinês, por exemplo —, escolha-a em **Fonte CJK** (`font-family-cjk`). Toda fonte
  instalada com caracteres chineses, japoneses ou coreanos aparece, monoespaçada ou não: ela só desenha esses caracteres,
  centralizados nas duas células, e a fonte principal mantém o tamanho da célula. Os emoji vêm do Apple Color Emoji — ou,
  com Emoji em Monocromático quando possível, como glifo de texto quando o Apple Symbols ou o Menlo têm um. Um caractere
  largo é centralizado nas duas células. Desative **Usar outras fontes para caracteres ausentes** para ver só a fonte
  escolhida, com um retângulo onde ela não tem glifo.
- **Caracteres de largura ambígua.** Ajustes ▸ Terminal ▸ Caracteres de largura ambígua faz `±`, `§`, grego, cirílico e os
  demais caracteres "East Asian Ambiguous" ocuparem duas células, para softwares escritos para terminais CJK. Vale para a
  saída escrita depois; um shell ou editor que mede o texto por conta própria pode continuar contando-os como uma célula.
- **Sublinhados.** Programas podem desenhar sublinhados simples, duplos (`SGR 21` ou `4:2`) e ondulados (`SGR 4:3`, os
  diagnósticos do Neovim); pontilhados e tracejados são desenhados como simples. Texto piscante (`SGR 5`) é mantido, mas
  não é animado.
- **Zoom.** ⌘= / ⌘− / ⌘0 ou um gesto de pinça deixam o texto maior, menor ou de volta ao tamanho configurado, só na janela
  atual. O zoom nunca altera o arquivo de configuração. Mudanças de fonte nunca movem nem redimensionam a janela: as linhas
  e colunas visíveis se reajustam a ela, e o que sobra de uma célula aparece como fundo abaixo da última linha.
- **Tema.** Três temas embutidos, `corta`, `solarized` e `mono`, cada um com variante clara e escura; `appearance = auto`
  acompanha o macOS quando ele muda. Você pode definir seu próprio tema por **Visualização ▸ Editor de temas…** ou no
  arquivo de configuração, ou herdar de um e mudar algumas cores ([Themes](../../CONFIGURATION.md#4-themes)).
- **Unicode.** Texto chinês, japonês e coreano ocupa duas colunas e se alinha com todo o resto; emoji, marcas combinantes,
  bandeiras e sequências de emoji são um agrupamento cada. Caracteres que faltam na fonte vêm das fontes de substituição do
  sistema. Sequências padronizadas de apresentação emoji (um caractere de texto seguido de VS16, como ⚠️ ou ✍️) ocupam duas
  colunas; a apresentação de texto continua estreita.
- **Métodos de entrada.** Pinyin, kana, hangul e todos os outros métodos de entrada do macOS compõem no lugar, com a janela
  de candidatos ao lado do cursor.
- **Cores reais.** Cor de 24 bits, a paleta de 256 cores, negrito, itálico, sublinhado, tachado, esmaecido e invertido.
- **⌥ como Meta.** Desativado por padrão, para que ⌥ digite os caracteres do layout do teclado. Use
  `option-as-meta = true` para teclas Meta no estilo do Emacs.
- **Sinal.** Um lampejo do painel (`bell = visual`) ou um som (`bell = audible`).

<a id="personalizing-the-terminal"></a>

## Personalizar o terminal

<a id="cursor-appearance"></a>

### Aparência do cursor

Abra Ajustes (⌘,) → Aparência → Cursor. Escolha Bloco, Barra ou Sublinhado e, se quiser, ative Piscar cursor. O padrão é
**Bloco, sem piscar**. As três formas e o botão independente dão seis combinações. No arquivo de configuração, são
`cursor-shape` e `cursor-blink`. As mudanças valem para os painéis abertos. Programas do terminal podem escolher
temporariamente a própria forma e o próprio piscar via DECSCUSR; o parâmetro 0 ou uma redefinição do terminal volta aos
seus padrões configurados. O piscar pausa quando um painel está inativo, oculto ou mostrando o histórico.

<a id="input-source-indicator"></a>

### Indicador de fonte de entrada

O terminal em foco mostra uma pequena insígnia na barra de ferramentas, no canto superior direito da janela: `A` para
entrada direta confirmada, `中` para chinês, `あ` para japonês e `한` para coreano. Outras fontes mostram o código do idioma.
Passe o ponteiro por cima para ver o nome completo da fonte. Uma insígnia neutra identifica fontes cujo modo de entrada
interno o macOS não informa, incluindo IMEs de terceiros com alternância própria para o inglês. O Corta nunca deduz esse
modo a partir do texto digitado e nunca muda a fonte de entrada.

Ajustes ▸ Teclado e mouse ▸ Indicador de fonte de entrada escolhe **Automático** (padrão), **Sempre no painel ativo** ou
**Desativado**. O padrão só ativa o indicador para quem tem um layout de teclado não latino ou um IME ativados;
configurações só latinas continuam limpas. Voltar para um layout latino deixa um `A` discreto num fundo esmaecido — cinza
na barra de ferramentas, na cor de texto do próprio tema ao lado do prompt. Layouts não latinos e modos de IME embutidos
usam um tom índigo suave; modos de IME desconhecidos, cinza. Ao lado do prompt, as cores seguem o claro ou escuro do tema
do terminal em vez do macOS. Na barra de ferramentas, a insígnia fica enquanto um programa roda — Claude Code, um editor —,
já que não cobre nenhuma saída. Na borda direita da linha de comando, a integração com o shell a esconde durante a execução
de comandos no modo **Automático**. **Sempre** pode mantê-la durante a saída dos comandos. Os dois modos de prompt a
escondem enquanto você lê o histórico ou usa um programa de tela alternativa.

O ajuste **Posição** escolhe **Barra de ferramentas da janela** (padrão) ou **Borda direita da linha de comando**. A
insígnia da barra de ferramentas fica independente dos botões de conexão e de nova aba e permanece fixa quando os comandos
crescem ou quebram de linha. Desativá-la ou escolher a linha de comando remove o espaço dela e o espaçamento de separação
na barra de ferramentas. Na linha de comando, comandos longos movem a insígnia para baixo, para um espaço livre,
mantendo-a na borda direita; ela some quando não resta nenhuma linha segura, e nunca insere uma linha nem faz o processo
filho rolar. As cores de entrada direta e de IME aceitam valores hexadecimais; esvazie um campo para o estilo discreto padrão.

[Insígnia de fonte de entrada chinesa](../../brand/input-source-indicator.png) ·
[Como ela evita comandos longos](../../brand/input-source-long-command.png)

<a id="optional-local-system-status"></a>

### Status do sistema local (opcional)

Abra Ajustes (⌘,) → Terminal, ative a barra de status inferior e escolha as métricas que quer ver: uso de CPU, carga do
sistema, uso de memória, taxas de rede, espaço livre em disco e estado térmico. Ela vem desativada; cada métrica tem seu
próprio botão. Clique na barra para ver o nome do host local, a versão do macOS, o chip, o número de núcleos e a memória
total. A barra diz Local mesmo num painel SSH; ela não monitora um servidor remoto. Em janelas estreitas, clique para ver
todas as métricas escolhidas.

A interface de rede é automática por padrão. Ela mede uma interface principal, então o tráfego da VPN não é somado ao
tráfego físico. Digite o nome de uma interface específica nos Ajustes para medir essa. A amostragem para enquanto todas as
barras ativadas estão ocultas. O estado térmico é um relatório do macOS em quatro níveis, não graus.

A barra usa rótulos compactos, um único espaço como separador e unidades de bytes curtas; nomes completos e precisão ficam
na dica, no valor de acessibilidade e no popover de detalhes do host.

<a id="creating-and-editing-themes"></a>

### Criar e editar temas

Ajustes → Aparência → Criar tema abre um editor gráfico. Dê um nome à sua cópia, alterne entre as variantes escura e clara
e mude as cores com seletores de cor ou valores HEX. A pré-visualização se atualiza sem mudar as janelas do terminal.
Salvar tema o ativa e o guarda; Cancelar mantém o tema anterior. Temas personalizados oferecem Editar tema. Restaurar cores
de origem redefine a variante atual. Você ainda pode editar o mesmo arquivo de configuração à mão. Se esse tema
personalizado mudar fora do editor, reabra o editor antes de salvar.

Visualização → Editor de temas abre direto a edição gráfica de cores. Visualização → Detalhes do host local mostra a
configuração do host sem precisar da barra de status opcional. O mesmo botão de detalhes do host está em
Ajustes → Terminal. As pré-visualizações de Aparência acompanham na hora as mudanças explícitas de modo e mostram a forma e
o estado de piscar do cursor escolhidos. Programas do terminal ainda podem substituir temporariamente o estilo do cursor.

<a id="compact-tab-indentation-zsh"></a>

### Indentação compacta com Tab (zsh)

Sessões locais padrão do zsh carregam automaticamente os hooks incluídos quando as sugestões de pastas estão ativadas
(o padrão). Você não precisa modificar seus arquivos de inicialização. Se usa argumentos personalizados do zsh ou desativou
essa inicialização automática, instale ou atualize a integração com o shell em Ajustes → Terminal e abra um novo shell.
Com esses hooks carregados, Tab numa linha de comando só com espaços insere quatro espaços. Tab depois de texto de comando
mantém a associação de completamento existente. É um widget do ZLE; as paradas de tabulação da saída do terminal continuam
em oito colunas, e programas em tela cheia continuam recebendo a tecla Tab. Sem a integração, o shell mantém o próprio
comportamento de Tab.

<a id="language"></a>

### Idioma

O app segue o idioma preferido que o macOS escolhe para o Corta: inglês, chinês simplificado e tradicional, japonês,
coreano, alemão, francês, espanhol e português do Brasil. Reinicie o Corta depois de mudar o idioma do app no macOS. A
formatação de números segue a região atual.

<a id="when-a-session-ends"></a>

## Quando uma sessão termina

Um painel mantém sua saída depois que o shell sai: a saída fica um pouco escurecida e um quadro diz numa frase o que
terminou e como — o código de saída, ou o sinal que o interrompeu. O cursor some, mas rolagem, seleção, cópia e a busca
com ⌘F continuam funcionando ao redor do quadro. **Nova sessão** inicia de novo o shell ou a predefinição no painel;
**Fechar painel** o fecha. Uma sessão SSH conectada diretamente diz a qual host estava conectada e oferece **Reconectar**
para iniciar uma nova conexão; o código de saída 255 do ssh é explicado como a rede caindo ou o host deixando de
responder. Os dois botões apagam a saída acima — o quadro avisa — e a nova sessão começa no tamanho e no tamanho de fonte
do painel. Sair do Python ou de outro programa de volta a um shell ativo não encerra a sessão do terminal.

Quando a entrada ou a saída de uma sessão falha, ou um painel para de desenhar, o mesmo quadro oferece **Tentar de novo**
ou, para uma conexão, **Reconectar**; o texto de erro do sistema fica em **Detalhes**.

![Sessão encerrada mantendo a última saída e as ações de recuperação](../../brand/session-ended.png)

<a id="scrollback-search-and-selection"></a>

## Histórico, busca e seleção

- **Rolagem.** O trackpad ou a roda, ou ⇧PageUp / ⇧PageDown, ⇧Home / ⇧End. Cada sessão guarda `scrollback-lines` linhas de
  histórico (10.000).
- **Busca.** ⌘F abre a barra de busca sobre o histórico; ⌘G e ⇧⌘G vão para a ocorrência seguinte e anterior.
  **Diferenciar maiúsculas** e **`*`** (expressão regular) são alternados ali, e lembram o estado no arquivo de
  configuração (`search-case-sensitive`, `search-regex`). A barra fica no canto superior direito do painel e desce enquanto
  o cursor ou a ocorrência atual ficariam embaixo dela; numa divisão estreita, ela se estreita em vez de cobrir o painel.
  Cada painel tem sua própria barra.
- **Seleção.** Arraste para selecionar, clique duas vezes para uma palavra, três vezes para uma linha. Uma seleção
  concluída é copiada na hora (`copy-on-select`); ⌘C também copia. Dentro de um programa que usa o mouse — `vim`, `htop` —,
  segure ⌥ ao começar a arrastar para selecionar texto mesmo assim (`mouse-override-modifier`).
- **Colar.** ⌘V. O texto colado é marcado como colagem (bracketed paste), então um shell que entende isso — zsh, fish,
  bash 5.1 ou posterior — insere um comando colado sem executá-lo até você pressionar Return. Quando o programa não ativou o
  bracketed paste (o `/bin/bash` 3.2 do próprio macOS nunca ativa), o Corta avisa antes de colar texto que contém uma
  quebra de linha. Uma colagem grande que o shell ainda está processando pode ser cancelada com ⌃C: a parte ainda não
  enviada é descartada e a interrupção passa direto.
- **Exportar texto…** (⇧⌘S) salva a seleção — ou, sem seleção, todo o histórico e a tela — num arquivo.
- **Limpar.** Três comandos, porque descartam coisas diferentes:

  | Comando | Tela | Histórico | Modos e cores |
  | --- | --- | --- | --- |
  | Limpar tela (⌘K) | apagada | mantido | mantidos |
  | Apagar histórico | mantida | descartado | mantidos |
  | Redefinir terminal | apagada | descartado | redefinidos |

  Apagar histórico e Redefinir terminal perguntam antes e dizem quantas linhas descartariam — a menos que o histórico
  esteja vazio, ou que `confirm-close = false` desligue a pergunta.

<a id="links-and-file-references"></a>

## Links e referências a arquivos

- **URLs** mostram o destino e a dica de ⌘-clique ao passar o ponteiro, e abrem com ⌘-clique; use
  `link-activation = click` para abri-las com um clique simples. Segure ⌘ sobre um link — inclusive um que um programa marca
  explicitamente (OSC 8, como o `ls --hyperlink` imprime) — para sublinhá-lo e ver o destino real numa dica antes de
  clicar; o clique em si o abre na hora.
- **Referências a arquivos.** Um `path:line:column` na saída de um programa — um erro de compilação, um teste que falhou —
  abre no seu editor com ⌘-clique. Diga ao Corta qual editor com `open-file-command`, começando pelo caminho completo do
  editor, por exemplo
  `open-file-command = /usr/local/bin/code --goto {file}:{line}:{column}`
  ([Following a file reference](../../CONFIGURATION.md#following-a-file-reference)).

Abrir qualquer referência a arquivo exige um `open-file-command` configurado. O Corta nunca abre arquivos vindos da saída
no aplicativo padrão do sistema: alguns tipos de arquivo executam código ao serem abertos.

<a id="shell-integration"></a>

## Integração com o shell

A integração com o shell permite que o Corta veja onde cada comando começa e termina. Instale-a em
**Ajustes ▸ Terminal ▸ Integração com o shell**: ela adiciona um bloco marcado ao arquivo de inicialização do seu shell —
`~/.zshrc`; no bash, tanto `~/.bashrc` quanto `~/.bash_profile` (ou o arquivo de login que o bash lê); ou
`~/.config/fish/config.fish` — e **Remover** tira exatamente esse bloco. O bloco do arquivo de inicialização só é instalado
quando você pressiona o botão. Sessões locais padrão do zsh também carregam automaticamente os hooks incluídos no Corta,
sem editar seus arquivos de inicialização, quando **Sugestões de pastas (zsh)** está ativado (o padrão). Argumentos
personalizados do zsh, bash, fish e shells remotos não usam essa inicialização automática. Instale hooks compatíveis
nesses shells para ter os limites dos comandos lá.

Quando os Ajustes indicarem uma integração desatualizada, escolha **Atualizar** e abra um novo shell. Atualizar só o app
não substitui um bloco instalado antes num arquivo de inicialização.

Com os hooks carregados, automaticamente ou pelo arquivo de inicialização:

- **Marcas de prompt.** Uma linha fina à esquerda de cada prompt, verde quando o comando deu certo e vermelha quando falhou.
  Um Return vazio não desenha linha nem cria uma entrada concluída no histórico de comandos.
- **Saltos.** ⌘↑ / ⌘↓ andam entre comandos; ⇧⌘↑ / ⇧⌘↓, entre os que falharam.
- **A saída de um comando.** Na paleta de comandos: **Copiar a saída do último comando**,
  **Snapshot da saída do comando em execução** (o que um build imprimiu até agora), **Exportar saída do comando…** para um
  arquivo, e **Abrir referência de arquivo na saída do comando**, que abre o último `path:line` impresso.
- **Histórico de comandos.** **Pesquisar histórico de comandos…** lista cada comando com horário, status de saída e
  diretório; **Preencher** o devolve ao prompt e **Executar** o executa de novo (`command-history-limit`). Um comando que a
  lista não consegue mostrar inteiro — com mais de uma linha, cortado na borda da linha ou com uma tabulação — ou cujo texto
  mudou desde que a lista o mostrou é preenchido em vez de executado, para que fique inteiro no prompt e rode quando você
  der Return.
- **Notificações de tarefas longas.** Com `notify-on-long-task = true`, um comando que rodou mais de
  `notification-threshold` segundos (30) envia uma notificação ao terminar **enquanto a janela dele não é a janela
  principal**, desde que o macOS tenha dado ao Corta permissão de notificações. Ative em Ajustes ▸ Geral e confira ali o
  status da permissão. Clique na notificação para ir até o comando.

Sem integração com o shell, esses comandos ficam desativados em vez de não fazer nada em silêncio, e as notificações
recorrem a uma estimativa baseada na digitação e na saída.

<a id="the-working-directory"></a>

## O diretório de trabalho

O Corta sabe em que diretório o seu shell está quando o shell informa (a integração com o shell informa). Na paleta de
comandos:

- **Mostrar diretório de trabalho no Finder** e **Copiar caminho do diretório de trabalho**.
- **Mudar para o diretório superior** e **Mudar para a raiz do projeto** (a pasta mais próxima com `.git`) digitam o `cd`
  por você — só quando nenhum comando está rodando e o prompt está vazio.
- **Abrir diretório superior em novo painel** e **Abrir raiz do projeto em novo painel** dividem o painel com um shell
  iniciado ali.

O ícone de pasta na barra de título também é o diretório: arraste-o, ou dê ⌘-clique nele para ver o caminho. Com
`directory-history` ativado (o padrão), o Corta registra os diretórios locais em que seus comandos rodaram. Nada no app os
lista ainda; **Ajustes ▸ Privacidade e Segurança ▸ Histórico** mostra quantos são e os apaga.

<a id="directory-suggestions-zsh"></a>

## Sugestões de pastas (zsh)

O Corta inclui sugestões de pastas, ativadas por padrão nas sessões locais padrão do zsh. Digite `cd ` para ver as pastas
do diretório atual como texto esmaecido abaixo da sua entrada. Continue digitando para filtrar as pastas; um sufixo
esmaecido aparece ao lado do cursor. Por exemplo, `cd De` pode sugerir `Developer/`. As sugestões são pré-visualizações:
não fazem parte do seu comando até serem aceitas.

![Sugestões de pastas abaixo do cd, com marcas de comandos bem-sucedidos, com falha e interrompidos](../../brand/directory-suggestions.png)

Enquanto uma sugestão está visível:

| Tecla | Ação |
| --- | --- |
| Esquerda / Direita | Selecionar a pasta anterior / seguinte em vez de mover o cursor de entrada. |
| Tab | Preencher a entrada com o diretório selecionado, sem executar. Substitui o completamento nativo com Tab enquanto as sugestões estão visíveis. |
| Esc | Fechar as sugestões da entrada atual. Pressione Esc antes de usar Esquerda / Direita para editar o comando, ou de novo para a ação de Esc do próprio shell. |
| Cima / Baixo | Manter a navegação normal pelo histórico de comandos do shell. |
| Shift+Tab | Repassar para a associação configurada no shell. |
| Return | Executar só a entrada real; nunca aceitar automaticamente uma sugestão esmaecida. |

Você pode filtrar caminhos relativos, subdiretórios e caminhos `~/`. Pastas ocultas aparecem quando você digita um ponto
como prefixo. Expressões de shell complexas mantêm o completamento nativo. Bash e fish mantêm o próprio completamento; as
sugestões só aparecem num shell que o Corta iniciou com seus hooks automáticos de zsh, nunca em máquinas remotas nem em
comandos de shell personalizados, mesmo com a integração com o shell instalada.

**Opcional: desativar.** Em **Ajustes ▸ Terminal ▸ Shell**, desative **Sugestões de pastas (zsh)**, ou coloque isto no
seu arquivo de configuração:

```ini
directory-completion = false
```

Isso desativa na hora as sugestões do Corta e a interceptação de teclas, deixando disponíveis a edição e o completamento
nativos do shell. Reabra o shell depois de ativá-las de novo. Não há bloco de arquivo de inicialização a apagar para os
hooks locais automáticos. Se você também instalou a integração com o shell manualmente, o botão **Remover** dela tira esse
bloco separado; não é preciso removê-lo para desativar as sugestões de pastas.

<a id="remote-work-ssh-and-sftp"></a>

## Trabalho remoto: SSH e SFTP

O Corta usa o OpenSSH do sistema — seu `~/.ssh/config`, suas chaves, seu agente e o `ProxyJump` valem todos — e não tem
implementação própria de SSH.

- **A insígnia do host.** Um painel conectado a outra máquina mostra *Remoto:* no começo do título da janela. Ela nomeia o
  host e a pasta quando o shell remoto os informa (com a integração com o shell instalada lá), e o destino que você digitou
  quando a conexão veio da folha de conexão; caso contrário, diz que o painel é remoto sem saber qual host.
- **Reconectar.** Quando uma sessão `ssh` ou `mosh` termina, **Reconectar ao host** executa o mesmo comando de novo, como
  uma nova conexão.
- **Conectar.** O botão de globo da barra de ferramentas abre **Conectar a um host**, uma folha com um seletor
  **Terminal / Arquivos (SFTP)**: um terminal via SSH ou o navegador de arquivos. Digite o host — um nome, um endereço,
  `user@host` ou um alias de SSH. **Avançado** guarda o usuário, a porta e uma chave privada; vazios, quem decide são o seu
  `~/.ssh/config` e os padrões do OpenSSH. Uma chave escolhida é oferecida primeiro, e outras chaves do `ssh-agent` não são
  tentadas. A folha lista as conexões recentes — com a porta, a chave e quando você as usou por último — e os nomes `Host`
  do seu `~/.ssh/config`. Hosts que só aceitam git (`github.com`, ou um `Host` com `User git`) ficam de fora, e a lista diz
  quais. Digite para filtrar a lista, clique em um (ou use ↑ e ↓ a partir do campo do host) para preencher os campos, e
  clique duas vezes ou pressione Return para conectar. Uma conexão de terminal entra na lista recente quando se estabelece
  — um host que recusa você ou não tem shell, não. Passe o ponteiro sobre um host recente e clique em ✕, ou clique com o
  botão direito nele, para esquecê-lo; Ajustes ▸ Privacidade e Segurança ▸ Hosts Recentes apaga todos.
- **Os arquivos deste painel.** Aberta a partir de um painel conectado a outra máquina, a folha oferece primeiro os
  arquivos desse host; pressione Return ou **Navegar nos arquivos** para abri-los.
- **Explorar arquivos remotos…** abre um navegador SFTP para o host do painel: listar, enviar, baixar, renomear e apagar.
  A primeira conexão a um host pede que você confirme o nome dele. As transferências continuam depois de uma interrupção e
  nunca sobrescrevem um arquivo sem perguntar. O download de uma pasta para se um nome entrar em conflito com um arquivo
  temporário `.corta-part`, preservando o arquivo existente. Escolha outro destino ou resolva esse arquivo individualmente;
  uma sobrescrita da pasta inteira não consegue engolir um arquivo parcial.
- **No navegador**, como no Finder: ⌘[ e ⌘] voltam e avançam, ⌘↑ vai para a pasta acima, ⌘R atualiza, ⇧⌘G (ou um clique
  no caminho) permite digitar um caminho, ⇧⌘N cria uma pasta e ⇧⌘. mostra os arquivos ocultos. Clique no título de uma
  coluna para ordenar. Clique com o botão direito numa linha para ver as ações dela; clique duas vezes numa pasta para
  abri-la. Solte arquivos do Finder na lista — ou numa linha de pasta — para enviá-los; enquanto você arrasta, a lista (ou a linha) ganha um contorno e diz para onde os arquivos vão. Arraste um arquivo para o Finder para baixá-lo. As transferências ficam sob o botão de setas da barra de ferramentas, com velocidade, tempo restante e
  Mostrar no Finder.
- **Editar um arquivo remoto.** **Editar** no navegador — ou um ⌘-clique num `path:line` de um painel remoto — baixa uma
  cópia e a abre no seu editor. Configure antes **Ajustes ▸ Terminal ▸ Abrir arquivo com**, com o caminho absoluto de um
  executável de editor e os marcadores `{file}`, `{line}`, `{column}`
  ([exemplos](../../CONFIGURATION.md#following-a-file-reference)). Enviar suas mudanças é um passo separado e explícito, e o
  Corta verifica antes se o arquivo remoto mudou nesse meio-tempo. Arquivos acima de 64 MiB não são copiados desse jeito;
  baixe-os pelo navegador, que mostra o progresso e permite cancelar. Uma cópia que ninguém abriu nem alterou por 30 dias é
  removida na próxima vez que a edição remota for usada; uma com mudanças que você não enviou nem descartou permanece.
- **Nomes.** Um nome remoto com caracteres de controle, da direita para a esquerda ou de largura zero os mostra como `�`, e
  um download os salva como `_`, para que um nome não possa se passar por outro.

Quando o servidor pede uma senha, uma frase-senha de chave ou um código de uso único, ou quando um host é novo e a chave
dele precisa da sua decisão, o navegador pergunta numa caixa de diálogo na janela dele e repassa sua resposta ao OpenSSH;
nada é salvo, então uma reconexão pergunta de novo. **Cancelar conexão** na caixa da senha encerra essa tentativa de
conexão e volta ao campo do host — nada é enviado como senha vazia. **Cancelar** na frase-senha de uma chave só pula essa
chave, e o ssh segue para a próxima forma de entrar. A caixa de diálogo da chave do host mostra a impressão digital e tem
Cancelar como padrão. Uma chave guardada pelo `ssh-agent` ou pelas Chaves, ou uma conexão `ControlMaster` existente do
seu terminal, entra sem perguntar.

Uma conexão que falha diz por que numa frase — senha ou chave não aceita, host que não responde, chave do host
desconhecida ou alterada, servidor sem SFTP —, com as palavras do ssh em **Detalhes**, e oferece **Tentar de novo** ou
**Editar conexão**.

Os envios da edição remota comparam o conteúdo remoto além do tamanho e da data de modificação, e enviam o snapshot
privado que você aprovou. Se você salvar outra edição local depois do pedido de aprovação, o Corta pede uma nova decisão;
os salvamentos durante um envio ficam pendentes. Depois de uma falha de conexão, a próxima edição ou envio reconecta, e um
envio que falhou mantém a decisão pendente. Preserve as edições locais não decididas antes de apagar os dados do app. Veja
a [política de dados em repouso](../../SECURITY.md#5-data-at-rest) (em inglês).

<a id="images-in-the-terminal"></a>

## Imagens no terminal

Programas que falam o **protocolo de gráficos do kitty** podem mostrar imagens no meio do texto:

```sh
kitten icat --transfer-mode=stream picture.png
```

As imagens rolam com o texto, ficam no histórico e são removidas por Limpar tela ou Apagar histórico junto com o texto ao
redor. Dentro da região de rolagem de um programa — o painel de um programa em tela cheia, por exemplo —, uma imagem se
move com o texto da região e é cortada onde passa da borda dela. Uma imagem pode ter até 8192 pixels de lado e 16 milhões
de pixels no total. Outras ferramentas compatíveis com o protocolo, como `timg` ou `chafa`, também podem usá-lo, desde que
enviem a própria imagem: o Corta se recusa, por projeto, a ler um caminho de arquivo indicado por um programa, e animação
não é compatível. Uma imagem maior que o painel é reduzida para caber nele.

<a id="the-command-palette"></a>

## A paleta de comandos

⇧⌘P abre a paleta de comandos: todos os comandos do Corta, pesquisáveis pelo nome, com o atalho ao lado. Digite algumas
letras e pressione Return. As letras correspondem em ordem, não necessariamente juntas (`spr` encontra Split Pane Right); o
nome de um grupo (`panes`) ou o nome de configuração de um comando (`new-tab`) também o encontram. Os comandos executados
recentemente aparecem primeiro. Clicar em outra janela fecha a paleta e deixa essa janela na frente. É o jeito mais rápido
de chegar aos comandos que não têm atalho padrão.

<a id="the-quick-terminal"></a>

## O Terminal rápido

Um terminal que desce por cima do que você estiver fazendo. Abra-o em **Visualização ▸ Terminal rápido**, pela paleta de
comandos ou com um atalho global depois de ativá-lo:

```ini
quick-terminal = true
quick-terminal-key = alt+space
quick-terminal-position = top      # top, bottom ou center
```

O atalho vem desativado, porque uma tecla global é tirada de todos os outros aplicativos.

<a id="macos-integration"></a>

## Integração com o macOS

- **Atalhos.** Três ações: **Abrir janela do Corta** (opcionalmente numa pasta), **Trazer janela do Corta para a frente** e
  **Mostrar ou ocultar o terminal rápido**. Nenhuma delas executa um comando num shell.
- **Serviços.** O texto selecionado no terminal é oferecido ao menu **Serviços**.
- **Entrada de teclado segura.** **Shell ▸ Entrada de teclado segura** impede que outros aplicativos leiam suas teclas
  enquanto o Corta está na frente — para digitar senhas. Um cadeado na barra de título mostra quando ela está realmente ativa.
- **VoiceOver** lê o texto do terminal e acompanha o painel em foco.
- **Área de transferência a partir de programas.** Desativada por padrão. Com `allow-clipboard-write = true`, um programa —
  inclusive dentro do `tmux` ou via `ssh` — pode colocar texto na sua área de transferência (OSC 52). Nada pode lê-lo de volta.

<a id="speed-and-battery"></a>

## Velocidade e bateria

O Corta faz sozinho o que é rápido; nada aqui precisa de ajuste. Isto é o que ele faz, para você saber o que esperar.

- **Ao digitar, a tela usa a taxa de atualização máxima.** Enquanto você digita, cola ou compõe com um método de entrada, o
  Corta pede a taxa de quadros máxima da tela — 120 Hz numa tela ProMotion — e a deixa baixar um segundo depois da última
  tecla. O Modo de Pouca Energia, uma janela inativa e a pressão térmica baixam o teto de novo quando você não está
  digitando; a pressão térmica crítica sempre baixa.
- **Tela cheia com um painel pode reduzir a latência no macOS 27 ou posterior.** O Corta então apresenta os quadros direto
  na tela, pulando o compositor do servidor de janelas: cerca de um quadro a menos da tecla à tela no Mac medido. Uma
  divisão, a barra de busca ou qualquer outra coisa desenhada por cima do texto traz o compositor de volta enquanto estiver
  visível. No macOS 26, todas as janelas usam o caminho de cópia pela fila clássica, como medida de compatibilidade contra
  uma falha do WindowServer (#380); os números de latência acima não foram medidos nesse sistema.
  (`CORTA_DIRECT_FULLSCREEN=0` no ambiente de inicialização desativa as mudanças de tela cheia, mas não o caminho de
  compatibilidade do macOS 26.)
- **Ler a saída e exibi-la têm ritmos separados.** O leitor do PTY continua analisando enquanto a tela apresenta o estado
  mais recente no ritmo da tela. Um benchmark medido da vazão do núcleo chegou a 317,3 MiB/s; esse número exclui E/S do
  PTY, renderização e exibição, e não é uma velocidade prometida para um log de build real ou para o `yes`.
- **Rolagem e programas em tela cheia só redesenham o que mudou.** vim, less, tmux e uma linha de status rolam deslocando o
  que já está desenhado.
- **Um histórico longo continua pequeno.** O histórico é comprimido na memória à medida que sai da tela — o aumento de
  memória medido para 100.000 linhas de 120 colunas foi de cerca de 11 MiB — e busca, cópia e redimensionamento trabalham
  direto sobre ele.
- **Ocioso é ocioso.** Um cursor piscando é animado pelo macOS em vez de redesenhado pelo Corta, um shell ocioso não causa
  despertares periódicos, e uma janela coberta ou minimizada para de desenhar por completo.
- **Painéis ocultos cedem a vez.** Dois segundos depois que um painel fica oculto — outra aba, uma janela minimizada —, a
  saída dele é lida com prioridade de segundo plano, para não competir com o que você está vendo. Nada se perde, e digitar
  ou colar nele restaura a prioridade total na hora.

[Performance](../../PERFORMANCE.md) (em inglês) tem as medições e como elas foram feitas.

<a id="settings-and-the-config-file"></a>

## Ajustes e arquivo de configuração

Todos os ajustes ficam num único arquivo de texto, `~/.config/corta/config`. **Corta ▸ Ajustes…** (⌘,) edita esse mesmo
arquivo, e editá-lo à mão tem o mesmo suporte:

Os Ajustes são uma barra lateral de categorias, no mesmo arranjo dos Ajustes do Sistema:

- **Geral** — o tamanho de novas janelas, restaurar janelas, confirmar o fechamento, notificações de tarefas longas e
  atualizações.
- **Aparência** — claro ou escuro, a fonte monoespaçada do sistema, o tamanho e uma pré-visualização ao vivo, a forma e o
  piscar do cursor e a edição gráfica de temas.
- **Terminal** — o histórico, o limite do histórico de comandos, o sinal, os padrões de busca, o comando para abrir
  arquivos, a integração com o shell, o status do sistema opcional e os detalhes do host local.
- **Teclado e mouse** — Usar Option como Meta, como os links abrem, o modificador que seleciona texto enquanto um programa
  controla o mouse, copiar ao selecionar e os modos e cores do indicador de fonte de entrada.
- **Atalhos** — a tecla de cada comando; uma seta de redefinição aparece ao lado dos que você mudou.
- **Terminal rápido** — o atalho global, a posição e a tela.
- **Conexões** — Conectar a um host e predefinições salvas.
- **Privacidade e Segurança** — gravação na área de transferência por programas (OSC 52), Entrada de teclado segura, o
  histórico de diretórios e os hosts recentes.

Esses controles editam o mesmo arquivo de configuração. As cores de temas personalizados podem ser editadas graficamente
ou pelo arquivo.

O botão de globo da barra de ferramentas da janela conecta a um host, para um terminal ou para os arquivos dele: uma folha
na janela com o host — pode ser um alias da configuração — e o usuário, a porta e a chave privada em **Avançado**; ela
sugere hosts recentes e configurados, e usuário, porta ou chave vazios respeitam a configuração do OpenSSH. A partir de
um painel remoto, oferece primeiro os arquivos desse host ([Trabalho remoto](#remote-work-ssh-and-sftp)).

```ini
theme = corta
appearance = auto
font-size = 14
scrollback-lines = 20000
notify-on-long-task = true
bind.equalize-panes = ctrl+cmd+e
```

A maioria dos ajustes vale na hora; alguns (tamanho da janela, tamanho do histórico) valem para a próxima janela ou sessão.
[Configuration](../../CONFIGURATION.md) (em inglês) lista cada chave, seu padrão e quando ela passa a valer.

<a id="keyboard-shortcuts"></a>

## Atalhos de teclado

Mude qualquer atalho com `bind.<command>` no arquivo de configuração; um valor vazio o remove, e a tecla passa a chegar ao
programa no terminal:

```ini
bind.equalize-panes = ctrl+cmd+e
bind.close =
```

**Ajuda ▸ Atalhos de teclado** mostra os que estão valendo em colunas alinhadas; comandos sem atalho aparecem como
**Não definido**. O menu de contexto do terminal mostra os mesmos atalhos configurados.

O menu **Shell** mantém à mão dividir, reabrir e Limpar tela. As outras ferramentas estão agrupadas em **Mover foco**,
**Comandos e saída**, **Diretório de trabalho**, **Layout dos painéis** e **Terminal e conexão**.

Os padrões, nesta versão — [Keyboard shortcuts](../../CONFIGURATION.md#5-keyboard-shortcuts) (em inglês) é a lista de referência:

| Comando | Atalho |
| --- | --- |
| Nova janela / Nova aba | ⌘N / ⌘T |
| Fechar | ⌘W |
| Dividir painel à direita / para baixo | ⌘D / ⇧⌘D |
| Mover foco | ⌥⌘ + seta |
| Redimensionar painel | ⌃⌘ + seta |
| Ampliar painel | ⇧⌘↩ |
| Reabrir painel fechado | ⇧⌘T |
| Aumentar / Reduzir / Tamanho real | ⌘= / ⌘− / ⌘0 |
| Buscar… / Buscar próxima / Buscar anterior | ⌘F / ⌘G / ⇧⌘G (Buscar próxima e anterior são fixos) |
| Copiar / Colar / Selecionar tudo | ⌘C / ⌘V / ⌘A |
| Rolar uma página / até o topo ou o final | ⇧PageUp, ⇧PageDown / ⇧Home, ⇧End |
| Comando anterior / próximo | ⌘↑ / ⌘↓ |
| Comando anterior / próximo com falha | ⇧⌘↑ / ⇧⌘↓ |
| Exportar texto… | ⇧⌘S |
| Limpar tela | ⌘K |
| Ajustes… | ⌘, |
| Paleta de comandos… | ⇧⌘P |

Todos os outros comandos — Equalizar painéis, Apagar histórico, Redefinir terminal, Explorar arquivos remotos…, os
comandos de saída e de diretório de trabalho — não têm tecla padrão e estão a uma busca de distância na paleta de
comandos. [Keyboard shortcuts](../../CONFIGURATION.md#5-keyboard-shortcuts) (em inglês) tem a tabela completa com o nome
`bind.` de cada comando.

<a id="when-something-goes-wrong"></a>

## Quando algo dá errado

A [Solução de problemas](TROUBLESHOOTING.md) cobre o que você vê quando algo falha e como resolver — um download que
o macOS não abre, uma fonte recusada, um atalho que não faz nada. [Features and limitations](../../FEATURES.md) (em inglês)
lista o que o Corta ainda não faz. Relate qualquer outra coisa em
[GitHub Issues](https://github.com/noah-qin/Corta/issues/new/choose). Para perguntas de uso, vá a
[Discussions → Q&A](https://github.com/noah-qin/Corta/discussions/categories/q-a), ou pergunte em `#help` no
[Discord](https://discord.gg/QNdWfdwr7j).
