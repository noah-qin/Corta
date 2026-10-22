# Solução de problemas

[Índice da documentação (inglês)](../../README.md) · [Visão geral do projeto](README.md)

🇺🇸 [English](../../TROUBLESHOOTING.md) · 🇨🇳 [简体中文](../zh-CN/TROUBLESHOOTING.md) · 🇭🇰 [繁體中文](../zh-Hant/TROUBLESHOOTING.md) · 🇯🇵 [日本語](../ja/TROUBLESHOOTING.md) · 🇰🇷 [한국어](../ko/TROUBLESHOOTING.md) · 🇩🇪 [Deutsch](../de/TROUBLESHOOTING.md) · 🇫🇷 [Français](../fr/TROUBLESHOOTING.md) · 🇪🇸 [Español](../es/TROUBLESHOOTING.md) · 🇧🇷 [Português](TROUBLESHOOTING.md)

> Esta página é uma tradução de [TROUBLESHOOTING.md](../../TROUBLESHOOTING.md), no estado do commit
> [`04ad320`](https://github.com/noah-qin/Corta/blob/04ad320438030e3ba4a7c19761b0279e39c42afc/docs/TROUBLESHOOTING.md).
> Se a versão em inglês mudou desde então, ou se as duas divergirem, vale a versão em inglês.
> As mensagens do macOS vêm acompanhadas do texto original em inglês.

O que fazer quando o Corta não instala, não abre ou faz algo que o seu terminal anterior não fazia. Cada entrada diz o que
você vai ver, por quê, e como resolver — e a última seção explica como voltar de forma limpa para o seu terminal antigo se
nada disso ajudar, porque um relato que diz "voltei, e foi por isso" é uma das coisas mais úteis que você pode enviar.

Se uma entrada aqui estiver errada ou faltando, abra uma issue com o modelo **Installation blocker** ou
**Went back to my old terminal**: <https://github.com/noah-qin/Corta/issues/new/choose>.

---

<a id="installing"></a>

## Instalação

### "Não é possível abrir 'Corta' porque a Apple não pode verificar se ele contém software malicioso" ("Corta can't be opened because Apple cannot check it for malicious software")

As versões oficiais são assinadas com Developer ID e notarizadas. Uma compilação a partir do código-fonte pode não ser.
Para uma versão baixada, verifique a soma de verificação e as checagens da imagem e do app abaixo, e então relate a
mensagem exata junto com a versão.

### "'Corta' está danificado e não pode ser aberto" ("Corta is damaged and can't be opened")

A imagem de disco pode estar incompleta, alterada ou ter sido rejeitada pela validação de assinatura do macOS. Primeiro
confira-a com o arquivo `.sha256` publicado ao lado dela. Mantenha os dois arquivos na pasta de downloads e substitua
`x.y.z` pela versão que você baixou:

```sh
shasum -a 256 -c Corta-x.y.z.dmg.sha256
```

Se não bater, baixe de novo. Todo pacote de versão é conferido com o arquivo que o acompanha antes de ser publicado
(`corta-release-check`), então uma divergência é motivo para parar e baixar de novo. Se a soma de verificação bater,
confira a imagem e o app copiado. Substitua `x.y.z` pela versão baixada em todos os comandos e execute-os a partir da
pasta de downloads:

```sh
spctl -a -t open --context context:primary-signature -v Corta-x.y.z.dmg
xcrun stapler validate Corta-x.y.z.dmg
spctl --assess --type exec /Applications/Corta.app
xcrun stapler validate /Applications/Corta.app
```

Inclua no relato a versão, o erro do macOS e esses resultados. Não contorne o Gatekeeper para testar uma versão. As
versões até a 1.1.8 mantêm as somas de verificação originais dos ZIPs; use o nome de arquivo daquela versão.

### O Corta se oferece para se mover para /Applications

O Corta foi aberto a partir de `~/Downloads` ou de outra pasta. Ele funciona de qualquer lugar; `/Applications` é onde as
atualizações do Sparkle e o Spotlight esperam encontrá-lo. Diga não e ele para de perguntar — ou defina
`suggest-applications-folder = false` em `~/.config/corta/config`.

Aberto direto da imagem de disco, o macOS executa o Corta a partir de um local temporário somente leitura, então ele não
consegue se mover; em vez disso, pede que você o arraste para Aplicativos. Se já houver um Corta mais novo lá, ele se
oferece para abrir esse em vez de substituí-lo pela cópia mais antiga.

### Há dois ícones do Corta no Dock

Um deles é uma compilação de desenvolvimento. O Finder o chama de **Corta Dev**, a barra de menus de **CortaDev**, o ícone
dele tem fundo laranja em vez de azul, e o identificador do pacote é `dev.noahqin.Corta.dev`. Ele guarda a configuração e
o estado em `~/Library/Application Support/Corta Dev/`, nunca em `~/.config/corta/config` nem em
`~/Library/Application Support/Corta/`, e não tem o item de menu "Verificar atualizações…" — então o de ícone azul é o
Corta instalado, seja qual for a ordem em que aparecem. Encerrar ou apagar um deixa o outro intacto. Só quem compila o
Corta a partir do código-fonte tem um (`CONTRIBUTING.md`, "Developing Corta in Corta").

### "Esta versão do Corta requer o macOS 26.0 ou posterior" ("This version of Corta requires macOS 26.0 or later")

O alvo de implantação do Corta é o macOS 26.0, e ele usa APIs do Metal 4 e do Core Text dessa versão. Não há compilação
para sistemas anteriores, e o projeto não planeja uma (`DESIGN.md` §6).

### "Não é possível abrir o aplicativo 'Corta' porque ele não é compatível com este tipo de Mac" ("You can't open the application "Corta" because it is not supported on this type of Mac")

A partir da 1.1.0, o Corta é compilado só para Apple silicon — um Mac com chip M1 ou posterior (`DECISIONS.md` D21). Um Mac
com Intel não consegue executá-lo. A **1.0.1** é a última versão para Macs com Intel, e continua disponível na
[página da versão 1.0.1](https://github.com/noah-qin/Corta/releases/tag/v1.0.1): baixe `Corta-1.0.1.zip`, verifique-o e
substitua a cópia em `/Applications`. Um Mac com Intel que já roda a 1.0.x não recebe a 1.1.0 por
**Verificar atualizações…**, então continua funcionando como está; esta mensagem só aparece quando um arquivo mais novo
foi baixado e aberto à mão.

Para ver qual chip um Mac tem, escolha menu Apple ▸ Sobre Este Mac: a linha *Chip* nomeia um chip da Apple (M1, M2, …) no
Apple silicon, e uma linha *Processador* nomeia um da Intel.

---

<a id="starting"></a>

## Inicialização

### A janela abre em branco, ou abre e fecha

Abra pelo Terminal.app para ver por quê:

```sh
/Applications/Corta.app/Contents/MacOS/Corta
```

Um painel que não consegue iniciar o shell mostra uma tela de falha com um botão **Tentar de novo** em vez de uma área em
branco; se você vê uma área em branco sem tela de falha, é um bug de renderização que merece um relato com a saída do console.

### O shell não é o que eu esperava, ou não tem PATH

O Corta inicia o `$SHELL` do ambiente com que foi aberto (senão, `/bin/zsh`) como shell de login (`-l`), então tanto o
`~/.zprofile` quanto o `~/.zshrc` rodam. Um `$SHELL` que não existe mais recorre ao `/bin/zsh` e depois ao `/bin/sh`, com
um aviso no painel dizendo qual degrau foi usado. Se comandos que funcionam no Terminal.app "não são encontrados" no
Corta, confira o valor de `SHELL` no ambiente com que os *aplicativos gráficos* são abertos (`launchctl getenv SHELL`): um
valor definido ali vale para todos os apps e sobrevive à sessão que o definiu. Rode `launchctl unsetenv SHELL` e abra de novo.

Uma **predefinição** (Shell ▸ Novo painel com predefinição) ou `preset.<name>.shell` no arquivo de configuração substitui
isso por painel.

### O Corta restaurou as janelas de ontem e eu não queria

`restore-windows = false` em `~/.config/corta/config`, ou desmarque em Ajustes ▸ Geral. Uma restauração que fez o app
travar não é tentada de novo: o arranjo salvo é descartado e uma única janela nova abre.

### Os Ajustes dizem que não conseguem ler o arquivo de configuração

`~/.config/corta/config` existe, mas não é texto UTF-8 — geralmente um byte salvo por um editor em outra codificação — ou
você não tem permissão para lê-lo. O Corta mantém os ajustes que já tem e se recusa a gravar o arquivo, porque gravar
substituiria tudo o que há nele. Salve o arquivo de novo como UTF-8 (ou remova a linha problemática); o Corta o recarrega
assim que lê de novo. A integração com o shell faz o mesmo com um arquivo rc que não consegue ler: avisa e não mexe nele.

---

<a id="typing-and-rendering"></a>

## Digitação e renderização

### Tab não faz nada no menu de comandos com barra do Claude Code

Corrigido na 1.0.0 (B02); a v0.1.1 tem o bug. Se voltar a acontecer numa compilação mais nova, relate com a versão do
Claude Code: a correção está em como o `insertTab(_:)` vindo de uma janela de candidatos chega ao processo filho, e uma
nova interface de candidatos poderia encaminhá-lo de outro jeito.

### ⌥ digita `é`, `ø`, `–` em vez de agir como Meta

Esse é o padrão do macOS, e o Corta o mantém. Defina `option-as-meta = true` para que ⌥ envie `ESC` + tecla, como a tecla
Alt de um teclado de PC. Teclas especiais (setas, teclas de função) levam o ⌥ como modificador do xterm de qualquer forma.

### Cores ou `TERM` parecem errados via ssh

O Corta anuncia `TERM=xterm-256color` de propósito (`docs/DECISIONS.md` D08). Compartilhar esse valor de TERM não implica
compatibilidade total com o xterm. Confira o ambiente remoto com `printf '%s\n' "$TERM"` e compare um caso mínimo de
reprodução; [Conformance](../../CONFORMANCE.md#42-external-suites) (em inglês) registra as sequências compatíveis e as falhas
restantes.

### Um glifo é desenhado menor que os vizinhos

Um caractere que falta na fonte escolhida vem do PingFang SC ou do Apple Color Emoji. Um glifo de substituição pode ser
redimensionado para caber nas células do terminal, então o tamanho visível dele pode diferir dos glifos vizinhos. Ajuste o
tamanho da fonte em **Ajustes ▸ Aparência** e compare a pré-visualização. Se um glifo for cortado ou ficar desalinhado,
relate o texto, a fonte, o tamanho da fonte, a escala da tela e uma captura de tela.

### A fonte que defini não é a que aparece

`font-family` nomeia uma família, não um estilo (`JetBrains Mono`, não `JetBrainsMono-Regular`). O Corta só a usa se ela
estiver instalada e os estilos regular, negrito e itálico avançarem a mesma largura em todo o ASCII imprimível; caso
contrário, desenha a monoespaçada do sistema, e **Ajustes ▸ Aparência** mostra uma linha Status da fonte dizendo qual
verificação falhou. Uma fonte instalada com o Corta aberto aparece na lista na hora; Tentar de novo verifica de novo a
configurada.

Chinês, japonês ou coreano desenhados numa fonte diferente da escolhida em **Fonte CJK** (`font-family-cjk`) significam que
essa família não está instalada ou não tem caracteres CJK; a linha sob o menu diz isso, e a fonte do idioma do sistema
desenha no lugar. Um caractere que falta na fonte escolhida também vem da fonte do idioma do sistema. A fonte CJK não é
usada enquanto **Usar outras fontes para caracteres ausentes** estiver desativado.

### Imagens do `kitten icat` não aparecem, ou aparecem no lugar errado

O Corta implementa a transmissão direta (na mesma banda) do protocolo de gráficos do Kitty em RGB, RGBA e PNG. A
transmissão por arquivo (`t=f`, `t=t`, `t=s`), quadros de animação e o posicionamento por marcadores Unicode não estão
implementados, e a transmissão por arquivo não será: um fluxo remoto indicando um arquivo local para ler é exatamente o que
o modelo de ameaças rejeita (`SECURITY.md` §1). Experimente `kitten icat --transfer-mode=stream picture.png` para pedir
explicitamente a transmissão direta. Uma imagem precisa respeitar os limites de 8192 pixels por lado e 16 milhões de
pixels; imagens inválidas ou grandes demais são recusadas.

### Um Return vazio desenha uma marca de comando verde ou vermelha

Um Return vazio não é um comando, e os hooks de integração atuais não registram nenhum. Um bloco de arquivo de
inicialização instalado por um Corta mais antigo ainda pode informar um: abra
**Ajustes ▸ Terminal ▸ Integração com o shell**, escolha **Atualizar** e depois abra um novo shell. Shells já abertos
mantêm as funções antigas até serem reiniciados, e as marcas já desenhadas ficam. Só o bloco marcado do Corta no arquivo
de inicialização é atualizado. Sessões locais padrão do zsh que usam os hooks automáticos recebem a versão incluída quando
um novo shell é iniciado.

---

<a id="behaviour-that-differs-from-other-terminals"></a>

## Comportamentos diferentes de outros terminais

### A cópia acontece assim que termino de selecionar

`copy-on-select` vem ativado e confirma com um rótulo no canto do painel. Defina como `false` para copiar só com ⌘C.

### Um programa disse que copiou para a minha área de transferência, e nada foi copiado

A *gravação* via OSC 52 vem desativada: do contrário, qualquer saída de programa poderia colocar na área de transferência
um texto para você colar depois. `allow-clipboard-write = true` a ativa, e é disso que o `tmux` e uma sessão `ssh` remota
precisam. A direção de *leitura* não existe em nenhum ajuste.

### Fechar uma janela pergunta se tenho certeza

Algo naquela janela ainda tem uma tarefa em primeiro plano. `confirm-close = false` desliga a pergunta em todo lugar.

### O atalho do Terminal rápido não faz nada

Três possibilidades, nesta ordem. `quick-terminal` está `false` (o padrão): nenhuma tecla é reservada até você definir
`true`. Outro aplicativo já está com a tecla: Ajustes ▸ Terminal rápido diz isso, e `quick-terminal-key` aceita qualquer
outra combinação com pelo menos um modificador. Ou a tecla é uma que o Corta não consegue associar a uma posição de tecla
(`é`, uma grafia de dois caracteres): a linha é mantida sem alteração no arquivo de configuração e vale o padrão.
Visualização ▸ Terminal rápido e a ação do Atalhos *Mostrar ou ocultar o terminal rápido* abrem o painel de qualquer forma.

### A insígnia de um painel remoto diz "Remoto: host desconhecido", ou um `tmux` local diz "Remoto?"

A insígnia tira o nome do host do relatório `OSC 7` do próprio shell remoto ou — numa conexão aberta pela folha de conexão
— do destino que você digitou lá. Ela nunca o lê de uma linha de comando `ssh` digitada no prompt (aliases, nomes do
`~/.ssh/config` e cadeias de hosts intermediários seriam todos lidos errado) nem do texto do prompt. Sem nenhum dos dois,
um painel `ssh` diz *host desconhecido*, que é a verdade. Para mostrar o host, coloque o bloco de integração com o shell de
Ajustes ▸ Terminal também no `~/.zshrc` da máquina remota; ele emite o `OSC 7` que a insígnia lê. Um `tmux` ou `screen` em
primeiro plano mostra *Remoto?* porque a sessão a que está conectado pode estar ela mesma em outra máquina, e nada aqui
consegue saber — é incerteza, não acusação.

### Explorar arquivos remotos… diz que a autenticação falhou, mas o `ssh` funciona no painel

A conexão SFTP pede uma senha ou uma frase-senha de chave numa caixa de diálogo na janela dela; uma caixa recusada ou
cancelada termina com este erro. Confira o usuário e a porta no formulário — o `User` e o `Port` próprios de um alias só
valem quando esses campos estão vazios — e a chave, se você escolheu uma: uma chave escolhida é a única oferecida. Se
nenhuma caixa de diálogo apareceu, o servidor recusou todos os métodos que o ssh podia tentar; `ssh -v` com o mesmo
usuário, porta e chave num terminal mostra quais.

### Explorar arquivos remotos… diz que uma chave de host não pôde ser verificada

Um host visto pela primeira vez pede que você confie na chave dele, numa caixa de diálogo que mostra a impressão digital.
Este erro significa que a chave *mudou* desde que você confiou nela — um servidor reinstalado, ou alguém no meio do
caminho. O ssh recusa isso até que a linha antiga seja removida de `~/.ssh/known_hosts` (`ssh-keygen -R <host>`); pergunte
antes a quem administra o servidor.

### O histórico de comandos mostra "(texto do comando não está mais no histórico)"

O texto de um comando é recuperado da grade, não armazenado: quando a linha de prompt dele rola além de
`scrollback-lines`, o registro mantém horário, status e diretório, mas o texto se foi, e Preencher e Executar não são
oferecidos para ele. Aumente `scrollback-lines` se isso acontecer com frequência.

### Não consigo rolar de volta até o começo de uma execução longa

`scrollback-lines` (10.000 por padrão) é um limite por sessão, e conta linhas *físicas* — uma linha de 200 colunas quebrada
em 100 colunas conta como duas. A saída mais antiga que o limite é descartada conforme chega; a pílula no topo diz até onde
a visualização voltou. Aumente o limite (até 1.000.000; quanta memória o histórico antigo comprimido ocupa depende do texto
e da carga). Uma célula armazenada tem 16 bytes antes da compressão, o que não é uma estimativa de memória residente. Uma
carga medida de 100.000 linhas de 120 colunas acrescentou cerca de 11 MiB de memória residente; veja
[Performance](../../PERFORMANCE.md#56-numbers-by-release) (em inglês). Exporte a saída que você precisa guardar além do limite
configurado.

### A Entrada de teclado segura está ativada, mas minha ferramenta de macros ainda funciona

O cadeado na barra de título mostra quando ela está *em vigor*, o que só acontece enquanto uma janela de terminal do Corta
é a janela principal e o Corta é o aplicativo ativo. Em qualquer outro aplicativo, e enquanto os Ajustes são a janela
principal, as teclas são entregues normalmente — essa é a ideia, e é por isso que o indicador segue o estado em vigor, e
não o ajuste.

### Falta o ícone de proxy do diretório num volume de rede montado

O Corta verifica em segundo plano o diretório local informado. Se a montagem estiver lenta ou se duas verificações já
estiverem esperando, ele deixa o ícone de proxy ausente para que a saída e a interação pelo teclado possam continuar.
Confira a montagem separadamente; mudar de diretório depois que ela se recuperar pede uma nova verificação.

### Um painel abre na pasta pessoal em vez de num diretório de rede

Um painel novo, ou uma janela restaurada ao abrir, só começa no diretório pedido se ele responder dentro de um prazo curto.
Um volume de rede que parou de responder conta como ausente, então o painel abre na pasta pessoal em vez de congelar o
Corta. O mesmo prazo vale para o ⌘-clique ou para passar o ponteiro sobre uma referência `path:line` ali: ela não é
oferecida como link. Reconecte o volume e depois dê `cd` até ele ou abra um novo painel ali.

### A edição remota pergunta de novo depois de um pedido de envio

O arquivo local mudou depois da versão mostrada pelo pedido original. Aprove a nova edição explicitamente. Uma entrada
gerenciada antiga sem resumo do conteúdo remoto também precisa de uma decisão de conflito uma vez. Uma comparação de
conteúdo consegue identificar mudanças remotas mesmo quando o tamanho e a data do arquivo não mudaram.

### Um envio da edição remota pergunta de novo depois de uma longa espera

A conexão travou. Depois de conectado, cada operação da edição remota tem 120 segundos para terminar; depois disso o
Corta fecha a conexão e oferece o envio de novo. Aprove-o para tentar outra vez por uma conexão nova. Um arquivo muito
grande num link lento também pode atingir o limite: copie-o com o navegador SFTP.

---

<a id="appearance-and-the-status-bar"></a>

## Aparência e barra de status

### O cursor não pisca

Piscar vem desativado: ative **Piscar cursor** em Ajustes ▸ Aparência ▸ Cursor. Ele pausa enquanto o painel está inativo,
oculto ou rolado para trás. Um programa do terminal pode mudar a forma ou o piscar para si mesmo com DECSCUSR; Redefinir
terminal volta ao estilo configurado.

### A barra de status não mostra a taxa de rede, ou mostra a errada

As taxas precisam de duas amostras, então espere alguns segundos depois de ativar a barra. `auto` mede uma interface
principal; quando uma VPN ou vários adaptadores fazem dela a errada, digite o nome da interface em Ajustes ▸ Terminal. Uma
interface informada explicitamente que não existe não mostra taxa. A barra sempre informa sobre o Mac local, também num
painel SSH, e os níveis térmicos são classificações do macOS, não graus. Uma janela estreita pode cortar a barra; clique
nela para ver todos os valores escolhidos.

### O editor de temas não salva

Uma cor HEX inválida desativa o Salvar. Se o tema personalizado foi alterado no arquivo de configuração enquanto o editor
estava aberto, feche e reabra o editor antes de salvar, para não sobrescrever essa alteração.

### A interface está no idioma errado

O Corta segue o idioma que o macOS escolhe para ele (Ajustes do Sistema ▸ Geral ▸ Idioma e Região ▸ Aplicativos). Reinicie
o Corta depois de mudar. A formatação de números segue a região e pode ser diferente do idioma.

---

<a id="updating"></a>

## Atualização

### Verificar atualizações… não encontra nada

O Corta compara **números de compilação**, não textos de versão, com o `appcast.xml` no branch `main`. Uma versão marcada e
em rascunho, mas ainda não publicada, não está no feed; depois de publicada, o processo de lançamento assina e verifica o
feed, abre um pull request, espera a CI e faz o merge com squash ou ativa o merge automático. Uma verificação do feed que
falha ou fica bloqueada pode atrasar a entrega, então espere um pouco depois que a versão aparecer no GitHub.
`update-auto-check = false` só desativa a verificação diária em segundo plano; o item de menu sempre funciona.

---

<a id="going-back-to-your-old-terminal"></a>

## Voltar para o seu terminal antigo

Encerre o Corta antes de remover os arquivos dele. Revise as cópias gerenciadas da edição remota em busca de trabalho não
salvo antes de apagar os dados do app:

1. **Integração com o shell**, se você a instalou por Ajustes ▸ Terminal: remova-a ali, ou apague o bloco entre
   `# >>> Corta shell integration >>>` e `# <<< Corta shell integration <<<` no arquivo de inicialização do seu shell —
   `~/.zshrc`; no bash, em `~/.bashrc` e `~/.bash_profile` (ou `~/.bash_login` / `~/.profile`); ou
   `~/.config/fish/config.fish`. Nada mais nesse arquivo é do Corta.
2. **A Entrada de teclado segura** se libera sozinha quando o Corta é encerrado. Se o Corta foi forçado a encerrar com uma
   janela como principal e a digitação em outros lugares parecer bloqueada, abra e encerre o Corta uma vez; o contador é
   reequilibrado na saída.
3. **Ajustes e estado**: `~/.config/corta/` (o arquivo de configuração) e `~/Library/Application Support/Corta/` (arranjo
   das janelas, histórico de diretórios e cópias gerenciadas da edição remota). Apague-os só depois de guardar as edições
   locais de que ainda precisa. O renderizador também mantém arquivos de cache descartáveis em
   `~/Library/Caches/dev.noahqin.Corta/`; eles podem ser removidos.
4. Mova o `Corta.app` para o Lixo.

Depois, se puder, abra uma issue com o formulário
[**Went back to my old terminal**](https://github.com/noah-qin/Corta/issues/new?template=went_back.yml) e conte o que
fez você voltar. Não precisa de reprodução. Um recurso que falta, um bug de renderização e "simplesmente parecia mais lento"
são todas respostas com as quais o projeto pode agir.
