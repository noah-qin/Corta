<div align="center">

<img src="../../brand/corta-pangolin-mascot.png" width="160" alt="O mascote pangolim do Corta, enrolado em forma de C, com um cursor ciano na cauda">

# Corta

**Um terminal rápido e focado. Feito para o Mac. Escrito em Swift.**

Renderização com Metal 4 · Entrada CJK / IME nativa · SSH, SFTP e edição remota

> Para quem vive no terminal: texto nítido, entrada nativa, fluxos de trabalho remotos poderosos e um núcleo de terminal em Swift com **zero** dependências de terceiros. Rápido o bastante para saídas pesadas. Cuidadoso o bastante para o trabalho de todo dia.

[![CI](https://github.com/noah-qin/Corta/actions/workflows/ci.yml/badge.svg)](https://github.com/noah-qin/Corta/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/noah-qin/Corta?style=flat-square)](https://github.com/noah-qin/Corta/releases/latest)
![Platform](https://img.shields.io/badge/macOS_26.0%2B-Apple_silicon-4d4d4d?style=flat-square)
![Swift](https://img.shields.io/badge/Swift-6-f05138?style=flat-square)
[![License](https://img.shields.io/badge/license-Apache--2.0-2f81f7?style=flat-square)](../../../LICENSE)
[![Discord](https://img.shields.io/badge/Discord-join-5865f2?style=flat-square&logo=discord&logoColor=white)](https://discord.gg/QNdWfdwr7j)
[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-db61a2?style=flat-square&logo=githubsponsors&logoColor=white)](https://github.com/sponsors/noah-qin)

**[↓ Baixar](https://github.com/noah-qin/Corta/releases/latest)** ·
**[Guia do usuário](USER-GUIDE.md)** ·
[Documentação (inglês)](../../README.md) ·
[Contribuir](../../../CONTRIBUTING.md) ·
[Discord](https://discord.gg/QNdWfdwr7j) ·
[Relatar um bug](https://github.com/noah-qin/Corta/issues/new?template=bug_report.yml)

🇺🇸 [English](../../../README.md) · 🇨🇳 [简体中文](../zh-CN/README.md) · 🇭🇰 [繁體中文](../zh-Hant/README.md) · 🇯🇵 [日本語](../ja/README.md) · 🇰🇷 [한국어](../ko/README.md) · 🇩🇪 [Deutsch](../de/README.md) · 🇫🇷 [Français](../fr/README.md) · 🇪🇸 [Español](../es/README.md) · 🇧🇷 [Português](README.md)

<img src="../../brand/screenshot.png" width="960" alt="O Corta com três painéis: um git log e uma tabela de alinhamento com chinês, japonês, coreano e emoji; o mascote pangolim exibido como imagem no terminal; e degradês de cor de 24 bits">

</div>

> Esta página é uma tradução do [README.md](../../../README.md) em inglês, no estado do commit
> [`6269301`](https://github.com/noah-qin/Corta/blob/626930199a323d9f5ac053746dcd95ba0db73484/README.md).
> Se a versão em inglês mudou desde então, ou se as duas divergirem, vale a versão em inglês.

## Instalação

Requer **macOS 26.0 ou posterior**, **Apple silicon** (M1 ou posterior) e uma **GPU compatível com Metal 4**.
Máquinas virtuais com GPU paravirtualizada não são compatíveis. Macs com Intel podem usar a versão anterior
[1.0.1](https://github.com/noah-qin/Corta/releases/tag/v1.0.1).

Baixe o `.dmg` e o arquivo `.dmg.sha256` correspondente em
[GitHub Releases](https://github.com/noah-qin/Corta/releases/latest).
Mantenha os dois arquivos na mesma pasta e verifique a soma de verificação ali:

```sh
# Substitua x.y.z pela versão que você baixou.
shasum -a 256 -c Corta-x.y.z.dmg.sha256
```

Abra a imagem de disco, arraste o **Corta** para **Aplicativos** e depois ejete a imagem. As versões são assinadas com
Developer ID e notarizadas. Para atualizações futuras, use **Corta ▸ Verificar atualizações…** ou baixe uma versão mais
nova. Ajuda com a instalação e instruções de desinstalação estão em [Solução de problemas](TROUBLESHOOTING.md).

## Primeiros passos

| Para… | Use |
| :--- | :--- |
| Dividir à direita / para baixo | ⌘D / ⇧⌘D |
| Buscar na saída do terminal | ⌘F |
| Abrir a paleta de comandos | ⇧⌘P |
| Abrir os ajustes | ⌘, |

Sessões locais padrão do zsh carregam automaticamente os hooks de integração com o shell incluídos, com as sugestões de
pastas ativadas (o padrão). Para instalar nos arquivos de inicialização do zsh, bash ou fish, use
**Ajustes ▸ Terminal ▸ Integração com o shell**; seus arquivos de inicialização só são alterados quando você escolhe
Instalar. Se uma integração instalada estiver desatualizada, escolha Atualizar e abra um novo shell. Veja o
[guia de integração com o shell](USER-GUIDE.md#shell-integration) para mais detalhes.

## Por que o Corta

| | |
| :--- | :--- |
| **Entrada nativa do Mac** | Entrada CJK e composição com IME, fontes de substituição do Core Text, VoiceOver, Entrada de teclado segura, Serviços, o Terminal rápido e ações do Atalhos — por meio do AppKit, não contornando-o. |
| **Rápido, com provas** | 2,3 vezes a vazão do núcleo da 1.1, um quadro a menos de latência de entrada em tela cheia e 11 MiB em vez de 185 MiB para 100.000 linhas de histórico. Cada número é publicado com seu método e suas lacunas (abaixo). |
| **Trabalho remoto embutido** | O OpenSSH do sistema com o seu `~/.ssh/config`, um navegador SFTP no estilo do Finder com arrastar e soltar, e arquivos remotos abertos no seu editor local com verificação de conflito antes do envio. |
| **Um só arquivo de ajustes** | A janela de Ajustes nativa e `~/.config/corta/config` editam o mesmo armazenamento; verificações automáticas mantêm as chaves e atalhos documentados alinhados com o código. |
| **Núcleo pequeno, proteções sérias** | Um núcleo de terminal em Swift sem dependências de terceiros, limites de recursos para saídas não confiáveis e um decodificador de imagens isolado em sandbox; o app acrescenta apenas o [Sparkle](https://sparkle-project.org) para atualizações. Leitura da área de transferência e consultas de título estão ausentes de propósito ([modelo de segurança](../../SECURITY.md), em inglês). |

Painéis divididos, busca no histórico, cores reais, links OSC 8, os protocolos de teclado e de gráficos do Kitty,
integração com o shell e restauração de layouts estão todos lá; a [referência de recursos](../../FEATURES.md) (em inglês)
lista tudo, com requisitos e limitações, e descreve o `main` — uma versão publicada pode ainda não ter todos os itens.
Como o Corta se compara ao iTerm2 e ao Ghostty, e quando escolher um deles, está em
[Features → How Corta compares](../../FEATURES.md#how-corta-compares) (em inglês).
O escopo exclusivo para macOS e a ausência do modo de controle do tmux, de IA embutida e de um mecanismo de scripts são
[decisões tomadas](../../DECISIONS.md) (em inglês); sessões comuns do tmux rodam dentro do Corta como programas de terminal.

## Do seu jeito

Os ajustes ficam em `~/.config/corta/config`. A janela de Ajustes nativa e o arquivo de texto editam a mesma configuração.

```ini
theme = midnight
theme.midnight.inherit = solarized
theme.midnight.dark.background = #101018

bind.equalize-panes = ctrl+cmd+e
bind.command-palette = cmd+shift+p
```

**Visualização ▸ Editor de temas…** abre seletores de cor e pré-visualizações separadas para claro e escuro.
**Ajustes ▸ Aparência ▸ Cursor** escolhe bloco, barra ou sublinhado, com um botão independente para piscar; o padrão é um
bloco que não pisca. A monoespaçada do sistema é a única fonte principal compatível, com tamanho ajustável e substituição
pelo sistema para caracteres ausentes. **Ajustes ▸ Terminal ▸ Barra de status inferior** ativa métricas locais à escolha
(desativada por padrão); clique nela para ver os detalhes do host, ou use **Visualização ▸ Detalhes do host local…**. Veja o
[tutorial de personalização](USER-GUIDE.md#personalizing-the-terminal) para os passos, a escolha da interface
de rede e as limitações do estado térmico.

A [referência de configuração](../../CONFIGURATION.md) (em inglês) lista cada chave, seu padrão e quando as mudanças passam
a valer. O [guia do usuário](USER-GUIDE.md) percorre cada recurso e onde encontrá-lo.

## Compilar a partir do código-fonte

```sh
git clone https://github.com/noah-qin/Corta.git && cd Corta
swift test --package-path CortaTerminal                     # só o núcleo do terminal, sem o app
xcodebuild -project Corta.xcodeproj -scheme 'Corta (Dev)' build  # um app de desenvolvimento ao lado do seu Corta instalado
```

O [guia de contribuição](../../../CONTRIBUTING.md) (em inglês) traz os requisitos (macOS 26, Apple silicon, o Xcode indicado em
[`.xcode-version`](../../../.xcode-version)), a assinatura local e um mapa do repositório; o [guia de testes](../../TESTING.md)
(em inglês) diz qual verificação cada mudança precisa.

## Qualidade, com provas

O Corta está em desenvolvimento ativo e tem problemas conhecidos. Estas medições são retratos de um momento, não garantias
para toda máquina ou carga de trabalho. Cada linha diz em qual versão foi medida.

| Verificação | Resultado registrado | Medido em | Evidência |
| :--- | :--- | :--- | :--- |
| Vazão do núcleo (analisador, grade e histórico; sem PTY nem renderização) | **317,3 MiB/s**, antes 137,2 | 1.2 vs 1.1 | [Performance §5.14](../../PERFORMANCE.md#514-scrolling-without-per-line-screen-allocation-281-283) |
| Vazão de analisador + grade | **355,9 MiB/s**, antes 158,0 | 1.2 vs 1.1 | idem |
| Memória do histórico, 100 mil × 120 linhas | **11,4 MiB**, antes 185 | 1.2 vs 1.1 | [Performance §5.6](../../PERFORMANCE.md#56-numbers-by-release) |
| Rolagem de região, CPU por quadro, p50 | **0,026 ms**, antes 0,130 | 1.2 vs 1.1 | [Performance §5.14](../../PERFORMANCE.md#514-scrolling-without-per-line-screen-allocation-281-283) |
| CPU por quadro, reconstrução completa de 120 × 40, Release | **0,37–0,39 ms** | 1.2 | [Performance §5.17](../../PERFORMANCE.md#517-full-screen-without-the-compositor-285-2026-10-13) |
| Da tecla à tela, tela cheia, um painel, 60 Hz, uma pessoa digitando | p50 **49,1–50,8 ms**, p99 82,9–84,2 ms (antes p50 64–68 ms) | 1.2 | [Performance §5.17](../../PERFORMANCE.md#517-full-screen-without-the-compositor-285-2026-10-13) |
| CPU ociosa, Release, 20 segundos | 0,05% | **1.0.0** (2026-09-18); não medido de novo desde o trabalho sobre despertares ociosos da 1.2 | [Performance](../../PERFORMANCE.md) |
| esctest2 | 131 aprovados, 334 bugs conhecidos, 102 reprovados; 567 no total | **1.1.5** (2026-10-07) | [Resultados brutos](https://github.com/noah-qin/Corta/blob/f632d5918653cc2feee28fe1baa0c0fd01e93c0e/docs/esctest/2026-10-07-results.txt) |

Medido em um MacBook Air com Apple M5 (macOS 27.0.1); as linhas da 1.2 entre 2026-10-09 e 2026-10-13, cada par
antes/depois na mesma máquina e com a mesma cadeia de ferramentas. As seções datadas de [Performance](../../PERFORMANCE.md)
(em inglês) trazem as condições, cada execução e o que um número não estabelece. O número de 82,0% do esctest2 que às
vezes é citado conta os aprovados **mais os bugs conhecidos** e não é uma taxa de aprovação; veja
[Conformance](../../CONFORMANCE.md) (em inglês) para a interpretação.

Entre as limitações conhecidas estão uma latência da tecla à tela acima da meta de um quadro em janela (tela cheia com um
painel é o que mais se aproxima), conformidade VT incompleta, integração com o shell incluída apenas para zsh, bash e fish,
e gráficos do Kitty apenas por transmissão direta. A [referência de limitações](../../FEATURES.md#known-limits) (em inglês)
tem os detalhes.

## Para se orientar

| Quero… | Comece aqui |
| :--- | :--- |
| Conhecer cada recurso e onde ele fica | [Guia do usuário](USER-GUIDE.md) |
| Configurar o Corta | [Configuration](../../CONFIGURATION.md) (em inglês) |
| Entender um recurso ou uma limitação | [Features](../../FEATURES.md) (em inglês) |
| Diagnosticar um problema | [Solução de problemas](TROUBLESHOOTING.md) |
| Migrar do iTerm2, Ghostty ou Terminal.app | [Vindo de outro terminal](USER-GUIDE.md#coming-from-another-terminal) |
| Ver o que está planejado ou sugerir algo | [Open issues](https://github.com/noah-qin/Corta/issues) · [Discussions → Ideas](https://github.com/noah-qin/Corta/discussions/categories/ideas) |
| Encontrar algo em que trabalhar | [Good first issues](https://github.com/noah-qin/Corta/labels/good%20first%20issue) · [Help wanted](https://github.com/noah-qin/Corta/labels/help%20wanted) |
| Fazer uma primeira contribuição | [Contributing](../../../CONTRIBUTING.md) (em inglês) |
| Executar ou adicionar testes | [Testing](../../TESTING.md) (em inglês) |
| Entender o código | [Architecture](../../DESIGN.md) · [Core API](../../../CortaTerminal/Sources/CortaTerminal/CortaTerminal.docc/CortaTerminal.md) (em inglês) |
| Ler toda a documentação | [Índice da documentação](../../README.md) (em inglês) |

## Contribuir

Reproduções de bugs, documentação, traduções, testes de acessibilidade e contribuições de código são bem-vindos. Comece
por um [good first issue](https://github.com/noah-qin/Corta/labels/good%20first%20issue) ou um
[help wanted](https://github.com/noah-qin/Corta/labels/help%20wanted), e leia o [CONTRIBUTING.md](../../../CONTRIBUTING.md) para a
configuração e as expectativas de revisão. A participação na comunidade segue o [Código de Conduta](../../../CODE_OF_CONDUCT.md).

Experimentou o Corta e voltou para o seu terminal antigo? Isso também vale ouvir:
o [formulário Went back](https://github.com/noah-qin/Corta/issues/new?template=went_back.yml)
não precisa de reprodução, e "simplesmente não pareceu certo" é uma resposta aceitável.

Relate vulnerabilidades pelo [canal de segurança privado](../../../SECURITY.md).
Para conversar com outros usuários e com o mantenedor, entre no [Discord](https://discord.gg/QNdWfdwr7j).
Para perguntas de uso cujas respostas outras pessoas devam poder encontrar, vá a [Discussions → Q&A](https://github.com/noah-qin/Corta/discussions/categories/q-a);
para compartilhar um tema ou uma configuração, a [Show and tell](https://github.com/noah-qin/Corta/discussions/categories/show-and-tell).
Para outros problemas, [abra uma issue](https://github.com/noah-qin/Corta/issues/new/choose).

### Patrocinar

O Corta é construído e mantido por uma pessoa, em público. Se ele já faz parte do seu dia, um patrocínio o mantém em
movimento — qualquer valor ajuda.

<a href="https://github.com/sponsors/noah-qin"><img src="https://img.shields.io/badge/Sponsor_noah--qin_on_GitHub-%E2%9D%A4-db61a2?style=for-the-badge&logo=githubsponsors&logoColor=white" alt="Patrocine noah-qin no GitHub"></a>

### Colaboradores

Obrigado a todas as pessoas que contribuíram com o Corta.

<a href="https://github.com/noah-qin"><img src="https://github.com/noah-qin.png?size=96" width="48" height="48" alt="noah-qin" title="noah-qin"></a>
<a href="https://github.com/FrankChen-CLC"><img src="https://github.com/FrankChen-CLC.png?size=96" width="48" height="48" alt="FrankChen-CLC" title="FrankChen-CLC"></a>

## Licença e identidade

O código-fonte é licenciado sob a [Apache 2.0](../../../LICENSE). O nome Corta, o mascote pangolim e o ícone do app têm termos
separados no [NOTICE](../../../NOTICE). O corpo enrolado do pangolim forma um C; sua cauda ciano é um cursor de terminal. Os
[recursos da marca](../../brand/README.md) incluem o mascote e a pré-visualização para redes sociais.
