<div align="center">

<img src="../../brand/corta-pangolin-mascot.png" width="160" alt="La mascota pangolín de Corta, enroscada en forma de C, con un cursor cian en la cola">

# Corta

**Un terminal rápido y centrado. Hecho para Mac. Escrito en Swift.**

Renderizado con Metal 4 · Entrada CJK / IME nativa · SSH, SFTP y edición remota

> Para quienes viven en el terminal: texto nítido, entrada nativa, flujos de trabajo remotos potentes y un núcleo de terminal en Swift con **cero** dependencias de terceros. Lo bastante rápido para salidas exigentes. Lo bastante cuidado para el trabajo de cada día.

[![CI](https://github.com/noah-qin/Corta/actions/workflows/ci.yml/badge.svg)](https://github.com/noah-qin/Corta/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/noah-qin/Corta?style=flat-square)](https://github.com/noah-qin/Corta/releases/latest)
![Platform](https://img.shields.io/badge/macOS_26.0%2B-Apple_silicon-4d4d4d?style=flat-square)
![Swift](https://img.shields.io/badge/Swift-6-f05138?style=flat-square)
[![License](https://img.shields.io/badge/license-Apache--2.0-2f81f7?style=flat-square)](../../../LICENSE)
[![Discord](https://img.shields.io/badge/Discord-join-5865f2?style=flat-square&logo=discord&logoColor=white)](https://discord.gg/QNdWfdwr7j)
[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-db61a2?style=flat-square&logo=githubsponsors&logoColor=white)](https://github.com/sponsors/noah-qin)

**[↓ Descargar](https://github.com/noah-qin/Corta/releases/latest)** ·
**[Guía de uso](USER-GUIDE.md)** ·
[Documentación (inglés)](../../README.md) ·
[Contribuir](../../../CONTRIBUTING.md) ·
[Discord](https://discord.gg/QNdWfdwr7j) ·
[Informar de un error](https://github.com/noah-qin/Corta/issues/new?template=bug_report.yml)

🇺🇸 [English](../../../README.md) · 🇨🇳 [简体中文](../zh-CN/README.md) · 🇭🇰 [繁體中文](../zh-Hant/README.md) · 🇯🇵 [日本語](../ja/README.md) · 🇰🇷 [한국어](../ko/README.md) · 🇩🇪 [Deutsch](../de/README.md) · 🇫🇷 [Français](../fr/README.md) · 🇪🇸 [Español](README.md) · 🇧🇷 [Português](../pt-BR/README.md)

<img src="../../brand/screenshot.png" width="960" alt="Corta con tres paneles: un git log y una tabla de alineación con chino, japonés, coreano y emoji; la mascota pangolín mostrada como imagen en el terminal; y degradados de color de 24 bits">

</div>

> Esta página es una traducción del [README.md](../../../README.md) en inglés, tal como estaba en el commit
> [`04ad320`](https://github.com/noah-qin/Corta/blob/04ad320438030e3ba4a7c19761b0279e39c42afc/README.md).
> Si la versión en inglés ha cambiado desde entonces, o si ambas difieren, prevalece la versión en inglés.

## Instalación

Requiere **macOS 26.0 o posterior**, **Apple silicon** (M1 o posterior) y una **GPU compatible con Metal 4**.
Las máquinas virtuales con GPU paravirtualizada no son compatibles. Los Mac con Intel pueden usar la versión anterior
[1.0.1](https://github.com/noah-qin/Corta/releases/tag/v1.0.1).

Descarga el `.dmg` y el archivo `.dmg.sha256` correspondiente desde
[GitHub Releases](https://github.com/noah-qin/Corta/releases/latest).
Guarda ambos archivos en la misma carpeta y comprueba allí la suma de verificación:

```sh
# Sustituye x.y.z por la versión que descargaste.
shasum -a 256 -c Corta-x.y.z.dmg.sha256
```

Abre la imagen de disco, arrastra **Corta** a **Aplicaciones** y después expulsa la imagen. Las versiones están firmadas
con Developer ID y notarizadas. Para actualizaciones posteriores, usa **Corta ▸ Buscar actualizaciones…** o descarga una
versión más reciente. La ayuda con la instalación y las instrucciones para desinstalar están en
[Solución de problemas](TROUBLESHOOTING.md).

## Primeros pasos

| Para… | Usa |
| :--- | :--- |
| Dividir a la derecha / hacia abajo | ⌘D / ⇧⌘D |
| Buscar en la salida del terminal | ⌘F |
| Abrir la paleta de comandos | ⇧⌘P |
| Abrir los ajustes | ⌘, |

Las sesiones locales estándar de zsh cargan automáticamente los hooks de integración del shell incluidos, con las
sugerencias de carpetas activadas (la opción predeterminada). Para instalarlos en los archivos de inicio de zsh, bash o
fish, usa **Ajustes ▸ Terminal ▸ Integración del shell**; tus archivos de inicio solo se modifican cuando eliges Instalar.
Si una integración instalada está desactualizada, elige Actualizar y abre un shell nuevo. Consulta la
[guía de integración del shell](USER-GUIDE.md#shell-integration) para más detalles.

## Por qué Corta

| | |
| :--- | :--- |
| **Entrada nativa de Mac** | Entrada CJK y composición con IME, fuentes de respaldo de Core Text, VoiceOver, Entrada de teclado segura, Servicios, el Terminal rápido y acciones de Atajos — a través de AppKit, no rodeándolo. |
| **Rápido, con pruebas** | 2,3 veces el rendimiento del núcleo de la 1.1, un fotograma menos de latencia de entrada a pantalla completa y 11 MiB en lugar de 185 MiB para 100.000 líneas de historial. Cada cifra se publica con su método y sus limitaciones (abajo). |
| **Trabajo remoto integrado** | El OpenSSH del sistema con tu `~/.ssh/config`, un explorador SFTP al estilo del Finder con arrastrar y soltar, y archivos remotos abiertos en tu editor local con una comprobación de conflictos antes de subirlos. |
| **Un solo archivo de ajustes** | La ventana de Ajustes nativa y `~/.config/corta/config` editan el mismo almacén; comprobaciones automáticas mantienen las claves y atajos documentados alineados con el código. |
| **Núcleo pequeño, salvaguardas serias** | Un núcleo de terminal en Swift sin dependencias de terceros, límites de recursos para salidas no fiables y un decodificador de imágenes en un entorno aislado; la app solo añade [Sparkle](https://sparkle-project.org) para las actualizaciones. La lectura del portapapeles y las consultas de título no existen a propósito ([modelo de seguridad](../../SECURITY.md), en inglés). |

Paneles divididos, búsqueda en el historial, color verdadero, enlaces OSC 8, los protocolos de teclado y de gráficos de
Kitty, integración del shell y disposiciones restauradas: todo está ahí; la
[referencia de funciones](../../FEATURES.md) (en inglés) lo enumera todo, con requisitos y limitaciones, y describe
`main` — una versión publicada puede no incluir todavía todos los elementos. Cómo se compara Corta con iTerm2 y Ghostty,
y cuándo elegir uno de ellos, está en [Features → How Corta compares](../../FEATURES.md#how-corta-compares) (en inglés).
Que Corta sea solo para macOS y no incluya el modo de control de tmux, IA integrada ni un motor de scripts son
[decisiones tomadas](../../DECISIONS.md) (en inglés); las sesiones normales de tmux se ejecutan dentro de Corta como
programas de terminal.

## Hazlo tuyo

Los ajustes se guardan en `~/.config/corta/config`. La ventana de Ajustes nativa y el archivo de texto editan la misma
configuración.

```ini
theme = midnight
theme.midnight.inherit = solarized
theme.midnight.dark.background = #101018

bind.equalize-panes = ctrl+cmd+e
bind.command-palette = cmd+shift+p
```

**Visualización ▸ Editor de temas…** abre selectores de color y vistas previas separadas para claro y oscuro.
**Ajustes ▸ Apariencia ▸ Cursor** elige bloque, barra o subrayado, con un interruptor de parpadeo independiente; el valor
predeterminado es un bloque que no parpadea. La monoespaciada del sistema es la única fuente principal compatible, con
tamaño ajustable y respaldo del sistema para los caracteres que faltan.
**Ajustes ▸ Terminal ▸ Barra de estado inferior** activa métricas locales a elegir (desactivada por defecto); haz clic en
ella para ver los detalles del equipo, o usa **Visualización ▸ Detalles del equipo local…**. Consulta el
[tutorial de personalización](USER-GUIDE.md#personalizing-the-terminal) para ver los pasos, la elección de la
interfaz de red y las limitaciones del estado térmico.

La [referencia de configuración](../../CONFIGURATION.md) (en inglés) enumera cada clave, su valor predeterminado y cuándo
surten efecto los cambios. La [guía de uso](USER-GUIDE.md) recorre cada función y dónde encontrarla.

## Compilar desde el código fuente

```sh
git clone https://github.com/noah-qin/Corta.git && cd Corta
swift test --package-path CortaTerminal                     # solo el núcleo del terminal, sin la app
xcodebuild -project Corta.xcodeproj -scheme 'Corta (Dev)' build  # una app de desarrollo junto a tu Corta instalado
```

La [guía para colaboradores](../../../CONTRIBUTING.md) (en inglés) indica los requisitos (macOS 26, Apple silicon, el Xcode de
[`.xcode-version`](../../../.xcode-version)), la firma local y un mapa del repositorio; la [guía de pruebas](../../TESTING.md)
(en inglés) dice qué comprobación necesita cada cambio.

## Calidad, con pruebas

Corta está en desarrollo activo y tiene problemas conocidos. Estas mediciones son instantáneas, no garantías para cada
máquina o carga de trabajo. Cada fila indica en qué versión se midió.

| Comprobación | Resultado registrado | Medido en | Prueba |
| :--- | :--- | :--- | :--- |
| Rendimiento del núcleo (analizador, cuadrícula e historial; sin PTY ni renderizado) | **317,3 MiB/s**, antes 137,2 | 1.2 frente a 1.1 | [Performance §5.14](../../PERFORMANCE.md#514-scrolling-without-per-line-screen-allocation-281-283) |
| Rendimiento de analizador + cuadrícula | **355,9 MiB/s**, antes 158,0 | 1.2 frente a 1.1 | ídem |
| Memoria del historial, 100.000 × 120 líneas | **11,4 MiB**, antes 185 | 1.2 frente a 1.1 | [Performance §5.6](../../PERFORMANCE.md#56-numbers-by-release) |
| Desplazamiento de región, CPU por fotograma, p50 | **0,026 ms**, antes 0,130 | 1.2 frente a 1.1 | [Performance §5.14](../../PERFORMANCE.md#514-scrolling-without-per-line-screen-allocation-281-283) |
| CPU por fotograma, reconstrucción completa de 120 × 40, Release | **0,37–0,39 ms** | 1.2 | [Performance §5.17](../../PERFORMANCE.md#517-full-screen-without-the-compositor-285-2026-10-13) |
| De la tecla a la pantalla, pantalla completa, un panel, 60 Hz, una persona escribiendo | p50 **49,1–50,8 ms**, p99 82,9–84,2 ms (antes p50 64–68 ms) | 1.2 | [Performance §5.17](../../PERFORMANCE.md#517-full-screen-without-the-compositor-285-2026-10-13) |
| CPU en reposo, Release, 20 segundos | 0,05 % | **1.0.0** (2026-09-18); no se ha vuelto a medir desde el trabajo sobre los despertares en reposo de la 1.2 | [Performance](../../PERFORMANCE.md) |
| esctest2 | 131 superadas, 334 errores conocidos, 102 fallidas; 567 en total | **1.1.5** (2026-10-07) | [Resultados en bruto](https://github.com/noah-qin/Corta/blob/f632d5918653cc2feee28fe1baa0c0fd01e93c0e/docs/esctest/2026-10-07-results.txt) |

Medido en un MacBook Air con Apple M5 (macOS 27.0.1); las filas de la 1.2, entre el 2026-10-09 y el 2026-10-13, cada par
antes/después en la misma máquina y con la misma cadena de herramientas. Las secciones fechadas de
[Performance](../../PERFORMANCE.md) (en inglés) recogen las condiciones, cada ejecución y lo que una cifra no demuestra.
La cifra del 82,0 % de esctest2 que a veces se cita cuenta las superadas **más los errores conocidos** y no es una tasa de
aprobados; consulta [Conformance](../../CONFORMANCE.md) (en inglés) para interpretarla.

Entre las limitaciones conocidas están una latencia de la tecla a la pantalla superior al objetivo de un fotograma en
ventana (la pantalla completa con un solo panel es lo que más se acerca), una conformidad VT incompleta, integración del
shell incluida solo para zsh, bash y fish, y gráficos de Kitty solo por transmisión directa. La
[referencia de limitaciones](../../FEATURES.md#known-limits) (en inglés) tiene los detalles.

## Orientarse

| Quiero… | Empieza aquí |
| :--- | :--- |
| Conocer cada función y dónde está | [Guía de uso](USER-GUIDE.md) |
| Configurar Corta | [Configuration](../../CONFIGURATION.md) (en inglés) |
| Entender una función o una limitación | [Features](../../FEATURES.md) (en inglés) |
| Diagnosticar un problema | [Solución de problemas](TROUBLESHOOTING.md) |
| Pasarme desde iTerm2, Ghostty o Terminal.app | [Si vienes de otro terminal](USER-GUIDE.md#coming-from-another-terminal) |
| Ver qué está planeado o sugerir algo | [Open issues](https://github.com/noah-qin/Corta/issues) · [Discussions → Ideas](https://github.com/noah-qin/Corta/discussions/categories/ideas) |
| Encontrar algo en lo que trabajar | [Good first issues](https://github.com/noah-qin/Corta/labels/good%20first%20issue) · [Help wanted](https://github.com/noah-qin/Corta/labels/help%20wanted) |
| Hacer una primera contribución | [Contributing](../../../CONTRIBUTING.md) (en inglés) |
| Ejecutar o añadir pruebas | [Testing](../../TESTING.md) (en inglés) |
| Entender el código | [Architecture](../../DESIGN.md) · [Core API](../../../CortaTerminal/Sources/CortaTerminal/CortaTerminal.docc/CortaTerminal.md) (en inglés) |
| Leer toda la documentación | [Índice de la documentación](../../README.md) (en inglés) |

## Contribuir

Se agradecen reproducciones de errores, documentación, traducciones, pruebas de accesibilidad y contribuciones de código.
Empieza por un [good first issue](https://github.com/noah-qin/Corta/labels/good%20first%20issue) o un
[help wanted](https://github.com/noah-qin/Corta/labels/help%20wanted), y lee [CONTRIBUTING.md](../../../CONTRIBUTING.md) para la
configuración y lo que se espera en la revisión. La participación en la comunidad sigue el
[Código de conducta](../../../CODE_OF_CONDUCT.md).

¿Probaste Corta y volviste a tu terminal de antes? Eso también merece la pena oírlo:
el [formulario Went back](https://github.com/noah-qin/Corta/issues/new?template=went_back.yml)
no necesita reproducción, y «simplemente no me convencía» es una respuesta válida.

Informa de vulnerabilidades a través del [canal de seguridad privado](../../../SECURITY.md).
Para charlar con otros usuarios y con el mantenedor, únete al [Discord](https://discord.gg/QNdWfdwr7j).
Para preguntas de uso cuyas respuestas deban poder encontrar otras personas, ve a [Discussions → Q&A](https://github.com/noah-qin/Corta/discussions/categories/q-a);
para compartir un tema o una configuración, a [Show and tell](https://github.com/noah-qin/Corta/discussions/categories/show-and-tell).
Para otros problemas, [abre una issue](https://github.com/noah-qin/Corta/issues/new/choose).

### Patrocinar

Corta lo construye y mantiene una sola persona, en abierto. Si se ha vuelto parte de tu día, un patrocinio lo mantiene
en marcha: cualquier cantidad ayuda.

<a href="https://github.com/sponsors/noah-qin"><img src="https://img.shields.io/badge/Sponsor_noah--qin_on_GitHub-%E2%9D%A4-db61a2?style=for-the-badge&logo=githubsponsors&logoColor=white" alt="Patrocina a noah-qin en GitHub"></a>

### Colaboradores

Gracias a todas las personas que han contribuido a Corta.

<a href="https://github.com/noah-qin"><img src="https://github.com/noah-qin.png?size=96" width="48" height="48" alt="noah-qin" title="noah-qin"></a>
<a href="https://github.com/FrankChen-CLC"><img src="https://github.com/FrankChen-CLC.png?size=96" width="48" height="48" alt="FrankChen-CLC" title="FrankChen-CLC"></a>

## Licencia e identidad

El código fuente se distribuye bajo la licencia [Apache 2.0](../../../LICENSE). El nombre Corta, la mascota pangolín y el icono de
la app tienen condiciones aparte en [NOTICE](../../../NOTICE). El cuerpo enroscado del pangolín forma una C; su cola cian es un
cursor de terminal. Los [recursos de marca](../../brand/README.md) incluyen la mascota y la vista previa para redes sociales.
