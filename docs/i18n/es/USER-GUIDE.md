# Guía de uso

[Índice de la documentación (inglés)](../../README.md) · [Presentación del proyecto](README.md)

🇺🇸 [English](../../USER-GUIDE.md) · 🇨🇳 [简体中文](../zh-CN/USER-GUIDE.md) · 🇭🇰 [繁體中文](../zh-Hant/USER-GUIDE.md) · 🇯🇵 [日本語](../ja/USER-GUIDE.md) · 🇰🇷 [한국어](../ko/USER-GUIDE.md) · 🇩🇪 [Deutsch](../de/USER-GUIDE.md) · 🇫🇷 [Français](../fr/USER-GUIDE.md) · 🇪🇸 [Español](USER-GUIDE.md) · 🇧🇷 [Português](../pt-BR/USER-GUIDE.md)

> Esta página es una traducción de [USER-GUIDE.md](../../USER-GUIDE.md), tal como estaba en el commit
> [`04ad320`](https://github.com/noah-qin/Corta/blob/04ad320438030e3ba4a7c19761b0279e39c42afc/docs/USER-GUIDE.md).
> Si la versión en inglés ha cambiado desde entonces, o si ambas difieren, prevalece la versión en inglés.
> Los nombres de la interfaz siguen la interfaz en español de Corta; las claves de configuración, los comandos y el código se mantienen en el original.

Todo lo que hace Corta y cómo llegar a ello. Cada sección dice dónde está la función — un menú, un atajo, un ajuste — y
enlaza con la referencia que tiene los detalles. Los atajos son los predeterminados, y todos salvo Buscar siguiente y
Buscar anterior se pueden cambiar ([Atajos de teclado](#keyboard-shortcuts)).

- [Instalar y actualizar](#install-and-update)
- [Si vienes de otro terminal](#coming-from-another-terminal)
- [Ventanas, pestañas y paneles](#windows-tabs-and-panes)
- [Texto, fuentes y temas](#text-fonts-and-themes)
- [Personalizar el terminal](#personalizing-the-terminal)
- [Cuando termina una sesión](#when-a-session-ends)
- [Historial, búsqueda y selección](#scrollback-search-and-selection)
- [Enlaces y referencias a archivos](#links-and-file-references)
- [Integración del shell](#shell-integration)
- [El directorio de trabajo](#the-working-directory)
- [Sugerencias de carpetas (zsh)](#directory-suggestions-zsh)
- [Trabajo remoto: SSH y SFTP](#remote-work-ssh-and-sftp)
- [Imágenes en el terminal](#images-in-the-terminal)
- [La paleta de comandos](#the-command-palette)
- [El Terminal rápido](#the-quick-terminal)
- [Integración con macOS](#macos-integration)
- [Velocidad y batería](#speed-and-battery)
- [Ajustes y archivo de configuración](#settings-and-the-config-file)
- [Atajos de teclado](#keyboard-shortcuts)
- [Cuando algo va mal](#when-something-goes-wrong)

<a id="install-and-update"></a>

## Instalar y actualizar

Corta necesita **macOS 26.0 o posterior**, **Apple silicon** y una **GPU compatible con Metal 4**. Una máquina virtual con
GPU paravirtualizada no puede dibujar el terminal. Descarga el `.dmg` y su archivo `.sha256` desde
[GitHub Releases](https://github.com/noah-qin/Corta/releases/latest), guarda ambos en la misma carpeta y comprueba allí
la suma de verificación antes de abrir la imagen (sustituye `x.y.z` por la versión descargada):

```sh
shasum -a 256 -c Corta-x.y.z.dmg.sha256
open Corta-x.y.z.dmg
```

Arrastra Corta a Aplicaciones y después expulsa la imagen. Las versiones desde la 1.1.9 son imágenes de disco; la 1.1.8 y
anteriores conservan sus ZIP originales.

Las versiones oficiales están firmadas con Developer ID y notarizadas. Si macOS rechaza una descarga, sigue la
[Solución de problemas](TROUBLESHOOTING.md#installing). Si se abre desde cualquier otro lugar, Corta ofrece moverse a
`/Applications` (`suggest-applications-folder`).

**Actualizaciones.** **Corta ▸ Buscar actualizaciones…** comprueba al momento; una comprobación en segundo plano se
ejecuta una vez al día salvo que `update-auto-check = false`. Una actualización solo se instala cuando tú lo decides.

<a id="coming-from-another-terminal"></a>

## Si vienes de otro terminal

Corta no tiene importador: lee un único archivo de texto, `~/.config/corta/config`, y la ventana de Ajustes edita ese
mismo archivo. La mayoría de las costumbres se trasladan con unas pocas claves. La columna izquierda indica dónde vive la
costumbre en otros terminales; la derecha, la clave de Corta ([Configuration](../../CONFIGURATION.md), en inglés, tiene los
valores de cada una y cuándo se aplica).

| Si dependías de… | En Corta |
| :--- | :--- |
| ⌥ como Meta / Alt (*Left Option key: Esc+* de iTerm2, `macos-option-as-alt` de Ghostty) | `option-as-meta = true`. Desactivado por defecto, para que ⌥ escriba `é`, `ø` y `–` como hace macOS. |
| Copiar al seleccionar | `copy-on-select`, **activado** por defecto. Pon `false` para copiar solo con ⌘C. |
| Una ventana con atajo global o un terminal rápido | `quick-terminal = true`; la tecla es `quick-terminal-key` (⌥Espacio por defecto). Desactivado por defecto: un atajo global se reserva en todas las aplicaciones. [El Terminal rápido](#the-quick-terminal). |
| Programas que copian al portapapeles a través de `ssh` o desde `tmux` (OSC 52) | `allow-clipboard-write = true`. Desactivado por defecto; leer el portapapeles no es posible con ningún ajuste. |
| Que pregunte antes de cerrar una ventana ocupada | `confirm-close`, activado por defecto. |
| Ventanas que se reabren donde las dejaste | `restore-windows`, activado por defecto. Vuelven las disposiciones, las pestañas y los directorios de trabajo; los procesos y el texto del terminal, no. |
| Tu propio esquema de colores | Un tema definido en el archivo (`theme.<name>.*`), o **Visualización ▸ Editor de temas…**. [Crear y editar temas](#creating-and-editing-themes). |
| Tus propios atajos | `bind.<command> = <shortcut>`. Los nombres de los comandos están en [Atajos de teclado](#keyboard-shortcuts). |
| Una fuente a tu elección | **Ajustes ▸ Apariencia ▸ Fuente**, o `font-family`. Solo se ofrecen familias monoespaciadas que Corta puede colocar en su cuadrícula. |
| Ligaduras, transparencia o ajustes por perfil | No disponibles; [no se incluyen](../../CONFIGURATION.md#6-what-is-deliberately-not-configurable), y cada uno requiere antes una decisión. Los preajustes cubren un shell, un directorio y un entorno ([Presets](../../CONFIGURATION.md#4a-presets)). |
| El modo de control `tmux -CC` | No compatible (D09). Un `tmux` normal se ejecuta dentro de Corta como cualquier programa. |

**Integración del shell.** Las sesiones locales estándar de zsh cargan los hooks de Corta sin tocar tus archivos de inicio.
Si tu `~/.zshrc`, `~/.bashrc` o `config.fish` todavía carga la integración de otro terminal — la de iTerm2, WezTerm o
Visual Studio Code —, **Ajustes ▸ Terminal ▸ Integración del shell** avisa de que puede haber un conflicto; ambas pueden
emitir marcas de prompt. Consulta [Integración del shell](#shell-integration).

**`TERM`.** Corta se anuncia como `xterm-256color` (D08). Un host remoto que ya funciona con iTerm2 o Terminal.app no
necesita nada nuevo; uno configurado para `xterm-ghostty` o `xterm-kitty` recibe en su lugar el valor habitual.

Los comportamientos que difieren en cosas más pequeñas — copiar, cerrar, el atajo del Terminal rápido, las insignias
remotas — están reunidos en
[Solución de problemas → Comportamientos distintos de otros terminales](TROUBLESHOOTING.md#behaviour-that-differs-from-other-terminals).

<a id="windows-tabs-and-panes"></a>

## Ventanas, pestañas y paneles

| Para… | Usa |
| --- | --- |
| Abrir una ventana / una pestaña | ⌘N / ⌘T |
| Pestaña anterior / siguiente | ⇧⌘[ / ⇧⌘] |
| Renombrar la pestaña actual | Doble clic en el título de la pestaña, o clic derecho ▸ Renombrar pestaña… |
| Dividir el panel a la derecha / hacia abajo | ⌘D / ⇧⌘D |
| Mover el foco entre paneles | ⌥⌘ + tecla de flecha |
| Redimensionar el panel activo | ⌃⌘ + tecla de flecha |
| Llenar la ventana con un panel, y volver | ⇧⌘↩ (Ampliar panel) |
| Dar a todos los paneles el mismo tamaño | Igualar paneles (paleta de comandos) |
| Cerrar el panel, la pestaña o la ventana | ⌘W |
| Recuperar el panel que acabas de cerrar | ⇧⌘T |

- Renombra una pestaña directamente en su título: haz doble clic o elige Renombrar pestaña… en su menú contextual.
  Retorno guarda, Esc cancela y un nombre vacío restaura el título automático. Los nombres personalizados sobreviven a la
  salida del shell y a la restauración de sesiones. Los menús contextuales de la pestaña y del terminal también ofrecen
  Nueva pestaña, y el botón **+** de la barra de herramientas abre una tanto si se muestra la barra de pestañas como si
  no; la barra de pestañas no tiene **+** propio.
- **Ampliar panel** es temporal: no se cierra nada ni se molesta a ningún proceso.
- **Reabrir el panel cerrado** restaura el lugar, el tamaño y el directorio de trabajo del panel — no el programa que se
  ejecutaba en él.
- Cerrar un panel con un comando aún en ejecución pregunta primero (`confirm-close`).
- **Restaurar ventanas.** Sal y vuelve a abrir, y cada ventana regresa con sus pestañas, divisiones, posiciones de los
  separadores y el directorio de trabajo de cada panel (`restore-windows`, activado por defecto). Cada panel inicia un
  proceso nuevo; el texto del terminal y los trabajos en ejecución no se restauran. El Terminal rápido queda excluido.
- **Preajustes.** Un preajuste es un shell, un directorio y un entorno con nombre, definidos en el archivo de
  configuración. **Shell ▸ Panel nuevo con preajuste** abre uno; mantén ⌥ para abrirlo en una ventana aparte
  ([Presets](../../CONFIGURATION.md#4a-presets)).
- Las ventanas nuevas se abren con `columns` × `rows` celdas (120 × 30 por defecto).

<a id="text-fonts-and-themes"></a>

## Texto, fuentes y temas

- **Fuente.** Ajustes ▸ Apariencia ▸ Fuente muestra la monoespaciada del sistema (predeterminada) y cada familia
  monoespaciada instalada que Corta puede colocar en su cuadrícula, en dos grupos: Fuentes de Apple (incluidas con macOS,
  o las fuentes bajo demanda de Apple una vez descargadas en Catálogo Tipográfico) e Instaladas por ti. La línea bajo el
  menú dice de dónde viene la fuente elegida y si trae sus propios caracteres CJK — una familia así dibuja también letras
  y símbolos con su diseño CJK, por ejemplo una `~` elevada. `font-family` en el archivo de configuración es el mismo
  ajuste. `font-size` es 13 pt por defecto, de 10 a 24 pt en puntos enteros. La página muestra una vista previa de la
  fuente, los colores y el cursor.
- **Grosor e interlineado.** El grosor es Ligera, Normal (predeterminado) o Media; una fuente sin ese grosor usa la
  normal, y el texto en negrita es siempre la negrita propia de la fuente. El interlineado va de 1,0 a 1,4 veces el
  tamaño de fuente, 1,18 por defecto; una fuente que necesita una línea más alta la conserva, así que nada se recorta.
  Cada carácter de cada idioma comparte un mismo tamaño de celda y una misma línea base.
- **Caracteres que le faltan a la fuente.** El chino, el japonés y el coreano salen de las fuentes propias de macOS: los
  caracteres han de PingFang SC, PingFang TC, Hiragino Sans o Apple SD Gothic Neo según el idioma del sistema, el kana de
  Hiragino Sans y el hangul de Apple SD Gothic Neo sea cual sea el idioma. Para dibujarlos con una fuente tuya — Menlo para
  las letras y Sarasa Gothic o LXGW WenKai para el chino, por ejemplo —, elígela en **Fuente CJK** (`font-family-cjk`).
  Aparece cualquier fuente instalada con caracteres chinos, japoneses o coreanos, sea monoespaciada o no: solo dibuja esos
  caracteres, centrados en sus dos celdas, y la fuente principal mantiene el tamaño de celda. Los emoji salen de
  Apple Color Emoji — o, con Emoji en Monocromo si es posible, como glifo de texto cuando Apple Symbols o Menlo tienen uno.
  Un carácter ancho se centra en sus dos celdas. Desactiva **Usar otras fuentes para los caracteres que faltan** para ver
  solo la fuente elegida, con un recuadro donde no tenga glifo.
- **Caracteres de ancho ambiguo.** Ajustes ▸ Terminal ▸ Caracteres de ancho ambiguo hace que `±`, `§`, el griego, el
  cirílico y los demás caracteres «East Asian Ambiguous» ocupen dos celdas, para software escrito para terminales CJK.
  Se aplica a la salida escrita después; un shell o editor que mide el texto por su cuenta puede seguir contándolos como uno.
- **Subrayados.** Los programas pueden dibujar subrayados simples, dobles (`SGR 21` o `4:2`) y ondulados (`SGR 4:3`, los
  diagnósticos de Neovim); los punteados y discontinuos se dibujan simples. El texto parpadeante (`SGR 5`) se conserva
  pero no se anima.
- **Zoom.** ⌘= / ⌘− / ⌘0 o un pellizco hacen el texto más grande, más pequeño o vuelven al tamaño configurado, solo en la
  ventana actual. El zoom nunca cambia el archivo de configuración. Los cambios de fuente nunca mueven ni redimensionan la
  ventana: las filas y columnas visibles se reajustan a ella, y lo que sobra de una celda se ve como fondo bajo la última fila.
- **Tema.** Tres temas integrados, `corta`, `solarized` y `mono`, cada uno con variante clara y oscura;
  `appearance = auto` sigue a macOS cuando cambia. Puedes definir tu propio tema con
  **Visualización ▸ Editor de temas…** o en el archivo de configuración, o heredar de uno y cambiar unos pocos colores
  ([Themes](../../CONFIGURATION.md#4-themes)).
- **Unicode.** El texto chino, japonés y coreano ocupa dos columnas y se alinea con todo lo demás; los emoji, las marcas
  combinantes, las banderas y las secuencias de emoji son un grupo cada uno. Los caracteres que le faltan a la fuente
  salen de las fuentes de respaldo del sistema. Las secuencias estandarizadas de presentación emoji (un carácter de texto
  seguido de VS16, como ⚠️ o ✍️) ocupan dos columnas; la presentación de texto sigue siendo estrecha.
- **Métodos de entrada.** Pinyin, kana, hangul y todos los demás métodos de entrada de macOS componen en su sitio, con la
  ventana de candidatos junto al cursor.
- **Color verdadero.** Color de 24 bits, la paleta de 256 colores, negrita, cursiva, subrayado, tachado, atenuado e invertido.
- **⌥ como Meta.** Desactivado por defecto, para que ⌥ escriba los caracteres de la distribución de teclado. Pon
  `option-as-meta = true` para teclas Meta al estilo de Emacs.
- **Campana.** Un destello del panel (`bell = visual`) o un sonido (`bell = audible`).

<a id="personalizing-the-terminal"></a>

## Personalizar el terminal

<a id="cursor-appearance"></a>

### Aspecto del cursor

Abre Ajustes (⌘,) → Apariencia → Cursor. Elige Bloque, Barra o Subrayado y, si quieres, activa Parpadeo del cursor. El
valor predeterminado es **Bloque, sin parpadeo**. Las tres formas y el interruptor independiente dan seis combinaciones.
En el archivo de configuración son `cursor-shape` y `cursor-blink`. Los cambios se aplican a los paneles abiertos. Los
programas del terminal pueden elegir temporalmente su propia forma y parpadeo mediante DECSCUSR; el parámetro 0 o un
restablecimiento del terminal vuelven a tus valores configurados. El parpadeo se detiene cuando un panel está inactivo,
oculto o mostrando el historial.

<a id="input-source-indicator"></a>

### Indicador de fuente de entrada

El terminal activo muestra una pequeña insignia en la barra de herramientas, arriba a la derecha de la ventana: `A` para
entrada directa confirmada, `中` para chino, `あ` para japonés y `한` para coreano. Las demás fuentes muestran su código de
idioma. Pasa el puntero por encima para ver el nombre completo de la fuente. Una insignia neutra identifica las fuentes
cuyo modo de entrada interno macOS no comunica, incluidos los IME de terceros con su propio cambio a inglés. Corta nunca
adivina ese modo a partir del texto escrito y nunca cambia la fuente de entrada.

Ajustes ▸ Teclado y ratón ▸ Indicador de fuente de entrada permite elegir **Automático** (predeterminado),
**Siempre en el panel activo** o **Desactivado**. El valor predeterminado solo activa el indicador para quienes tienen una
distribución de teclado no latina o un IME activados; las configuraciones solo latinas quedan despejadas. Volver a una
distribución latina deja una `A` discreta sobre un fondo tenue — gris en la barra de herramientas, con el color de texto
del propio tema junto al prompt. Las distribuciones no latinas y los modos de IME integrados usan un tono índigo suave; los
modos de IME desconocidos, gris. Junto al prompt, los colores siguen lo oscuro o claro del tema del terminal en lugar de
macOS. En la barra de herramientas, la insignia permanece mientras se ejecuta un programa — Claude Code, un editor —, ya
que no tapa ninguna salida. En el borde derecho de la línea de comandos, la integración del shell la oculta durante la
ejecución de comandos en modo **Automático**. **Siempre** puede mantenerla durante la salida de los comandos. Ambos modos
de prompt la ocultan mientras lees el historial o usas un programa de pantalla alternativa.

El ajuste **Posición** permite elegir **Barra de herramientas de la ventana** (predeterminado) o
**Borde derecho de la línea de comandos**. La insignia de la barra de herramientas es independiente de los botones de red
y de archivos y se queda fija aunque los comandos crezcan o se partan en varias líneas. Desactivarla o elegir la línea de
comandos elimina su hueco y su espacio de separación en la barra de herramientas. En la línea de comandos, los comandos
largos mueven la insignia hacia abajo a un espacio libre, manteniéndola en el borde derecho; se oculta cuando no queda una
fila segura y nunca inserta una línea ni hace desplazarse al proceso hijo. Los colores de entrada directa y de IME aceptan
valores hexadecimales; vacía un campo para el estilo discreto predeterminado.

[Insignia de fuente de entrada china](../../brand/input-source-indicator.png) ·
[Cómo esquiva los comandos largos](../../brand/input-source-long-command.png)

<a id="optional-local-system-status"></a>

### Estado del sistema local (opcional)

Abre Ajustes (⌘,) → Terminal, activa la barra de estado inferior y elige las métricas que quieres ver: uso de CPU, carga
del sistema, uso de memoria, velocidades de red, espacio libre en disco y estado térmico. Está desactivada por defecto;
cada métrica tiene su propio interruptor. Haz clic en la barra para ver el nombre del equipo local, la versión de macOS,
el chip, el número de núcleos y la memoria total. La barra dice Local incluso en un panel SSH; no supervisa un servidor
remoto. En ventanas estrechas, haz clic para ver todas las métricas elegidas.

La interfaz de red es automática por defecto. Mide una interfaz principal, de modo que el tráfico de la VPN no se suma al
tráfico físico. Escribe en Ajustes el nombre de una interfaz concreta para medir esa. El muestreo se detiene mientras
todas las barras activadas están ocultas. El estado térmico es un informe de macOS de cuatro niveles, no grados.

La barra usa etiquetas compactas, un solo espacio como separador y unidades de bytes cortas; los nombres completos y la
precisión están en su descripción emergente, en su valor de accesibilidad y en la ventana emergente de detalles del equipo.

<a id="creating-and-editing-themes"></a>

### Crear y editar temas

Ajustes → Apariencia → Crear tema abre un editor gráfico. Ponle nombre a tu copia, cambia entre las variantes oscura y
clara, y modifica los colores con selectores de color o valores HEX. La vista previa se actualiza sin cambiar las ventanas
del terminal. Guardar tema lo activa y lo guarda; Cancelar mantiene tu tema anterior. Los temas personalizados ofrecen
Editar tema. Restaurar colores de origen restablece la variante actual. Puedes seguir editando el mismo archivo de
configuración a mano. Si ese tema personalizado cambia fuera del editor, vuelve a abrir el editor antes de guardar.

Visualización → Editor de temas abre directamente la edición gráfica de colores. Visualización → Detalles del equipo local
muestra la configuración del equipo sin necesitar la barra de estado opcional. El mismo botón de detalles del equipo está
en Ajustes → Terminal. Las vistas previas de Apariencia siguen al instante los cambios de modo explícitos y muestran la
forma y el estado de parpadeo del cursor elegidos. Los programas del terminal pueden seguir sustituyendo temporalmente el
estilo del cursor.

<a id="compact-tab-indentation-zsh"></a>

### Sangría compacta con Tab (zsh)

Las sesiones locales estándar de zsh cargan automáticamente los hooks incluidos cuando las sugerencias de carpetas están
activadas (la opción predeterminada). No necesitas modificar tus archivos de inicio. Si usas argumentos de zsh
personalizados o has desactivado ese arranque automático, instala o actualiza la integración del shell en
Ajustes → Terminal y abre un shell nuevo. Con esos hooks cargados, Tab en una línea de comandos que solo contiene espacios
inserta cuatro espacios. Tab después de texto de comando mantiene la asignación de autocompletado existente. Es un widget
de ZLE; las tabulaciones de la salida del terminal siguen siendo de ocho columnas, y los programas de pantalla completa
siguen recibiendo la tecla Tab. Sin la integración, el shell mantiene su propio comportamiento de Tab.

<a id="language"></a>

### Idioma

La app sigue el idioma preferido que macOS elige para Corta: inglés, chino simplificado y tradicional, japonés, coreano,
alemán, francés, español y portugués de Brasil. Reinicia Corta después de cambiar su idioma de la app en macOS. El formato
de los números sigue la región actual.

<a id="when-a-session-ends"></a>

## Cuando termina una sesión

Un panel conserva su salida cuando el shell termina y muestra una tarjeta **Sesión finalizada** con su código de salida o
la señal que la terminó. El cursor desaparece, pero el desplazamiento, la selección, la copia y la búsqueda con ⌘F siguen
funcionando. **Nueva sesión** pide confirmación antes de sustituir la salida conservada; **Cerrar panel** cierra ese panel.
Una sesión SSH conectada directamente ofrece **Reconectar** para iniciar una conexión nueva. Salir de Python u otro
programa de vuelta a un shell activo no termina la sesión del terminal.

![Sesión finalizada que conserva su última salida y las acciones de recuperación](../../brand/session-ended.png)

<a id="scrollback-search-and-selection"></a>

## Historial, búsqueda y selección

- **Desplazamiento.** El trackpad o la rueda, o ⇧RePág / ⇧AvPág, ⇧Inicio / ⇧Fin. Cada sesión conserva `scrollback-lines`
  líneas de historial (10.000).
- **Búsqueda.** ⌘F abre la barra de búsqueda sobre el historial; ⌘G y ⇧⌘G van a la coincidencia siguiente y anterior.
  **Coincidir mayúsculas** y **`*`** (expresión regular) se activan allí y recuerdan su estado en el archivo de
  configuración (`search-case-sensitive`, `search-regex`). La barra se sitúa arriba a la derecha del panel y se mueve abajo
  mientras el cursor o la coincidencia actual quedarían debajo; en una división estrecha se estrecha en lugar de cubrir el
  panel. Cada panel tiene su propia barra.
- **Selección.** Arrastra para seleccionar, doble clic para una palabra, triple clic para una línea. Una selección
  terminada se copia al instante (`copy-on-select`); ⌘C también copia. Dentro de un programa que usa el ratón — `vim`,
  `htop` —, mantén ⌥ al empezar a arrastrar para seleccionar texto de todos modos (`mouse-override-modifier`).
- **Pegar.** ⌘V. El texto pegado se marca como pegado (bracketed paste), así que un shell que lo admite — zsh, fish,
  bash 5.1 o posterior — inserta un comando pegado sin ejecutarlo hasta que pulses Retorno. Cuando el programa no ha
  activado el bracketed paste (el `/bin/bash` 3.2 de macOS nunca lo hace), Corta avisa antes de pegar un texto que
  contiene un salto de línea. Un pegado grande que el shell todavía está procesando se puede cancelar con ⌃C: la parte
  aún no enviada se descarta y la interrupción pasa directamente.
- **Exportar texto…** (⇧⌘S) guarda la selección — o, sin selección, todo el historial y la pantalla — en un archivo.
- **Borrar.** Tres comandos, porque descartan cosas distintas:

  | Comando | Pantalla | Historial | Modos y colores |
  | --- | --- | --- | --- |
  | Borrar pantalla (⌘K) | borrada | conservado | conservados |
  | Borrar historial | conservada | descartado | conservados |
  | Restablecer terminal | borrada | descartado | restablecidos |

  Borrar historial y Restablecer terminal preguntan primero e indican cuántas líneas descartarían — salvo que el
  historial esté vacío o que `confirm-close = false` desactive la pregunta.

<a id="links-and-file-references"></a>

## Enlaces y referencias a archivos

- **Las URL** muestran su destino y la indicación de ⌘-clic al pasar el puntero, y se abren con ⌘-clic; pon
  `link-activation = click` para abrirlas con un clic normal. Mantén ⌘ sobre un enlace — incluido uno que un programa marca
  explícitamente (OSC 8, como imprime `ls --hyperlink`) — para subrayarlo y ver su destino real en una descripción
  emergente antes de hacer clic; el clic en sí lo abre al momento.
- **Referencias a archivos.** Un `path:line:column` en la salida de un programa — un error de compilación, una prueba
  fallida — se abre en tu editor con ⌘-clic. Indica a Corta qué editor con `open-file-command`, empezando por la ruta
  completa del editor, por ejemplo
  `open-file-command = /usr/local/bin/code --goto {file}:{line}:{column}`
  ([Following a file reference](../../CONFIGURATION.md#following-a-file-reference)).

Abrir cualquier referencia a un archivo requiere un `open-file-command` configurado. Corta nunca abre archivos derivados
de la salida con su aplicación predeterminada del sistema: algunos tipos de archivo ejecutan código al abrirse.

<a id="shell-integration"></a>

## Integración del shell

La integración del shell permite a Corta ver dónde empieza y termina cada comando. Instálala desde
**Ajustes ▸ Terminal ▸ Integración del shell**: añade un bloque marcado al archivo de inicio de tu shell — `~/.zshrc`;
para bash, tanto `~/.bashrc` como `~/.bash_profile` (o el archivo de inicio de sesión que lea bash); o
`~/.config/fish/config.fish` — y **Quitar** elimina exactamente ese bloque. El bloque del archivo de inicio solo se instala
cuando pulsas el botón. Las sesiones locales estándar de zsh también cargan automáticamente los hooks incluidos con Corta,
sin editar tus archivos de inicio, cuando **Sugerencias de carpetas (zsh)** está activado (la opción predeterminada). Los
argumentos de zsh personalizados, bash, fish y los shells remotos no usan este arranque automático. Instala hooks
compatibles en esos shells para tener allí los límites de los comandos.

Cuando Ajustes indica que la integración está desactualizada, elige **Actualizar** y abre un shell nuevo. Actualizar solo
la app no sustituye un bloque instalado anteriormente en un archivo de inicio.

Con los hooks cargados, de forma automática o mediante el archivo de inicio:

- **Marcas de prompt.** Una línea fina a la izquierda de cada prompt, verde cuando el comando tuvo éxito y roja cuando
  falló. Un Retorno vacío no dibuja ninguna línea ni crea una entrada completada en el historial de comandos.
- **Saltos.** ⌘↑ / ⌘↓ se mueven entre comandos; ⇧⌘↑ / ⇧⌘↓, entre los que fallaron.
- **La salida de un comando.** Desde la paleta de comandos: **Copiar la salida del último comando**,
  **Instantánea de la salida del comando en ejecución** (lo que una compilación ha impreso hasta ahora),
  **Exportar salida del comando…** a un archivo, y **Abrir referencia de archivo en la salida del comando**, que abre el
  último `path:line` que imprimió.
- **Historial de comandos.** **Buscar en el historial de comandos…** muestra cada comando con su hora, su estado de salida
  y su directorio; **Rellenar** lo devuelve al prompt y **Ejecutar** lo vuelve a ejecutar (`command-history-limit`). Un
  comando que la lista no puede mostrar entero — de más de una línea, cortado en el borde de la fila o con una tabulación —
  o cuyo texto cambió desde que la lista lo mostró se rellena en lugar de ejecutarse, para que quede completo en el prompt
  y se ejecute cuando pulses Retorno.
- **Notificaciones de tareas largas.** Con `notify-on-long-task = true`, un comando que tardó más de
  `notification-threshold` segundos (30) envía una notificación al terminar **mientras su ventana no es la ventana activa**,
  siempre que macOS haya concedido a Corta permiso de notificaciones. Actívalo en Ajustes ▸ General y comprueba allí el
  estado del permiso. Haz clic en la notificación para saltar al comando.

Sin integración del shell, estos comandos se desactivan en lugar de no hacer nada en silencio, y las notificaciones
recurren a una estimación basada en la escritura y la salida.

<a id="the-working-directory"></a>

## El directorio de trabajo

Corta conoce el directorio en el que está tu shell cuando el shell lo comunica (la integración del shell lo hace). Desde la
paleta de comandos:

- **Mostrar el directorio de trabajo en el Finder** y **Copiar la ruta del directorio de trabajo**.
- **Cambiar al directorio superior** y **Cambiar a la raíz del proyecto** (la carpeta más cercana con `.git`) escriben el
  `cd` por ti — solo cuando no se está ejecutando ningún comando y el prompt está vacío.
- **Abrir el directorio superior en un nuevo panel** y **Abrir la raíz del proyecto en un nuevo panel** dividen el panel
  con un shell iniciado allí.

El icono de carpeta de la barra de título también es el directorio: arrástralo, o haz ⌘-clic en él para ver la ruta. Con
`directory-history` activado (por defecto), Corta registra los directorios locales en los que se ejecutaron tus comandos.
Nada en la app los muestra todavía; **Ajustes ▸ Privacidad y seguridad ▸ Historial** muestra cuántos hay y los borra.

<a id="directory-suggestions-zsh"></a>

## Sugerencias de carpetas (zsh)

Corta incluye sugerencias de carpetas, activadas por defecto en las sesiones locales estándar de zsh. Escribe `cd ` para
ver las carpetas del directorio actual como texto tenue bajo tu entrada. Sigue escribiendo para filtrar las carpetas;
junto al cursor aparece un sufijo tenue. Por ejemplo, `cd De` puede sugerir `Developer/`. Las sugerencias son vistas
previas: no forman parte de tu comando hasta que las aceptas.

![Sugerencias de carpetas bajo cd, con marcas de comandos correctos, fallidos e interrumpidos](../../brand/directory-suggestions.png)

Mientras hay una sugerencia visible:

| Tecla | Acción |
| --- | --- |
| Izquierda / Derecha | Seleccionar la carpeta anterior / siguiente en lugar de mover el cursor de entrada. |
| Tab | Completar la entrada con el directorio seleccionado, sin ejecutarlo. Sustituye al autocompletado nativo con Tab mientras las sugerencias están visibles. |
| Esc | Cerrar las sugerencias de la entrada actual. Pulsa Esc antes de usar Izquierda / Derecha para editar el comando, u otra vez para la acción de Esc del propio shell. |
| Arriba / Abajo | Mantener la navegación normal por el historial de comandos del shell. |
| Mayús+Tab | Pasar a la asignación configurada en el shell. |
| Retorno | Ejecutar solo la entrada real; nunca aceptar automáticamente una sugerencia tenue. |

Puedes filtrar rutas relativas, subdirectorios y rutas `~/`. Las carpetas ocultas aparecen cuando escribes un punto como
prefijo. Las expresiones de shell complejas mantienen el autocompletado nativo. Bash y fish conservan su propio
autocompletado; las sugerencias solo aparecen en un shell que Corta inició con sus hooks automáticos de zsh, nunca en
máquinas remotas ni en comandos de shell personalizados, aunque la integración del shell esté instalada.

**Opcional: desactivarlas.** En **Ajustes ▸ Terminal ▸ Shell**, desactiva **Sugerencias de carpetas (zsh)**, o pon esto en
tu archivo de configuración:

```ini
directory-completion = false
```

Esto desactiva de inmediato las sugerencias de Corta y la interceptación de teclas, y deja disponibles la edición y el
autocompletado nativos del shell. Vuelve a abrir el shell después de reactivarlas. No hay ningún bloque de archivo de
inicio que borrar para los hooks locales automáticos. Si además instalaste la integración del shell manualmente, su botón
**Quitar** elimina ese bloque aparte; no hace falta quitarlo para desactivar las sugerencias de carpetas.

<a id="remote-work-ssh-and-sftp"></a>

## Trabajo remoto: SSH y SFTP

Corta usa el OpenSSH del sistema — tu `~/.ssh/config`, tus claves, tu agente y `ProxyJump` se aplican todos — y no tiene
una implementación propia de SSH.

- **La insignia del host.** Un panel conectado a otra máquina muestra *Remoto:* al principio del título de la ventana.
  Nombra el host y la carpeta cuando el shell remoto los comunica (con la integración del shell instalada allí), y el
  destino que escribiste cuando la conexión vino de la hoja de conexión; si no, indica que el panel es remoto sin saber
  qué host.
- **Reconectar.** Cuando termina una sesión `ssh` o `mosh`, **Reconectar al host** vuelve a ejecutar el mismo comando como
  una conexión nueva.
- **Conectar.** Los botones de globo y de carpeta de la barra de herramientas abren una hoja para un terminal SSH o un
  explorador SFTP, con los mismos campos para ambos: el host (un nombre, una dirección o un alias de SSH), el usuario, el
  puerto y una clave privada. Deja vacío cualquiera de los tres últimos y lo deciden tu `~/.ssh/config` y los valores
  predeterminados de OpenSSH; una clave elegida se ofrece primero, y no se prueban otras claves de `ssh-agent`. La hoja
  muestra las conexiones recientes — con el usuario, el puerto y la clave que usaron — y los nombres `Host` de tu
  `~/.ssh/config`; escribe para acotar la lista, haz clic en uno (o usa ↑ y ↓ desde el campo del host) para rellenar los
  campos, y haz doble clic o pulsa Retorno para conectar. Ajustes ▸ Privacidad y seguridad ▸ Hosts recientes borra las recientes.
- **Explorar archivos remotos…** abre un explorador SFTP para el host del panel: listar, subir, descargar, renombrar y
  eliminar. La primera conexión a un host te pide confirmar su nombre. Las transferencias se reanudan tras una
  interrupción y nunca sobrescriben un archivo sin preguntar. La descarga de una carpeta se detiene si un nombre entra en
  conflicto con un archivo provisional `.corta-part`, conservando el archivo existente. Elige otro destino o resuelve ese
  archivo por separado; sobrescribir toda la carpeta no puede absorber un archivo parcial.
- **En el explorador**, como en el Finder: ⌘[ y ⌘] van atrás y adelante, ⌘↑ a la carpeta superior, ⌘R actualiza, ⇧⌘G (o
  un clic en la ruta) permite escribir una ruta, ⇧⌘N crea una carpeta y ⇧⌘. muestra los archivos ocultos. Haz clic en el
  título de una columna para ordenar. Haz clic derecho en una fila para ver sus acciones; doble clic en una carpeta para
  abrirla. Suelta archivos desde el Finder sobre la lista — o sobre una fila de carpeta — para subirlos, y arrastra un
  archivo al Finder para descargarlo. Las transferencias están bajo el botón de flechas de la barra de herramientas, con
  la velocidad, el tiempo restante y Mostrar en el Finder.
- **Editar un archivo remoto.** **Editar** en el explorador — o un ⌘-clic en un `path:line` de un panel remoto — descarga
  una copia y la abre en tu editor. Configura primero **Ajustes ▸ Terminal ▸ Abrir archivo con**, con la ruta absoluta de
  un ejecutable de editor y los marcadores `{file}`, `{line}`, `{column}`
  ([ejemplos](../../CONFIGURATION.md#following-a-file-reference)). Subir tus cambios es un paso aparte y explícito, y Corta
  comprueba antes si el archivo remoto cambió mientras tanto. Los archivos de más de 64 MiB no se copian de esta forma;
  descárgalos desde el explorador, que muestra el progreso y permite cancelar. Una copia que nadie ha abierto ni
  modificado en 30 días se elimina la siguiente vez que se usa la edición remota; una con cambios que no has subido ni
  descartado se conserva.
- **Nombres.** Un nombre remoto con caracteres de control, de derecha a izquierda o de ancho cero los muestra como `�`, y
  una descarga los guarda como `_`, para que un nombre no pueda hacerse pasar por otro.

Cuando el servidor pide una contraseña, una frase de contraseña de clave o un código de un solo uso, o cuando un host es
nuevo y su clave necesita tu decisión, el explorador pregunta en un cuadro de diálogo sobre su ventana y entrega tu
respuesta a OpenSSH; no se guarda nada, así que al reconectar vuelve a preguntar. El cuadro de diálogo de la clave del
host muestra la huella y tiene Cancelar como opción predeterminada. Una clave en `ssh-agent` o en el llavero, o una
conexión `ControlMaster` existente desde tu terminal, inicia sesión sin preguntar.

Las subidas de la edición remota comparan el contenido remoto además del tamaño y la fecha de modificación, y envían la
instantánea privada que aprobaste. Si guardas otra edición local después del aviso de aprobación, Corta pide una nueva
decisión; los guardados durante una subida quedan pendientes. Tras un fallo de conexión, la siguiente edición o subida
vuelve a conectar, y una subida fallida conserva su decisión pendiente. Conserva las ediciones locales sin decidir antes
de eliminar los datos de la app. Consulta la [política de datos en reposo](../../SECURITY.md#5-data-at-rest) (en inglés).

<a id="images-in-the-terminal"></a>

## Imágenes en el terminal

Los programas que hablan el **protocolo de gráficos de kitty** pueden mostrar imágenes en línea:

```sh
kitten icat --transfer-mode=stream picture.png
```

Las imágenes se desplazan con el texto, se quedan en el historial y se eliminan con Borrar pantalla o Borrar historial
junto con el texto que las rodea. Dentro de la región de desplazamiento de un programa — el panel de un programa de
pantalla completa, por ejemplo —, una imagen se mueve con el texto de la región y se recorta donde sale por su borde. Una
imagen puede medir hasta 8192 píxeles por lado y 16 millones de píxeles en total. Otras herramientas compatibles con el
protocolo, como `timg` o `chafa`, también pueden usarlo, siempre que envíen la imagen en sí: Corta se niega por diseño a
leer una ruta de archivo que nombre un programa, y la animación no es compatible. Una imagen mayor que el panel se escala
para que quepa.

<a id="the-command-palette"></a>

## La paleta de comandos

⇧⌘P abre la paleta de comandos: todos los comandos de Corta, buscables por nombre, con su atajo al lado. Escribe unas
letras y pulsa Retorno. Las letras coinciden en orden, no necesariamente juntas (`spr` encuentra Split Pane Right); el
nombre de un grupo (`panes`) o el nombre de configuración de un comando (`new-tab`) también lo encuentran. Los comandos
que ejecutaste hace poco aparecen primero. Hacer clic en otra ventana cierra la paleta y deja esa ventana delante. Es la
forma más rápida de llegar a los comandos que no tienen atajo predeterminado.

<a id="the-quick-terminal"></a>

## El Terminal rápido

Un terminal que se despliega sobre lo que estés haciendo. Ábrelo desde **Visualización ▸ Terminal rápido**, desde la
paleta de comandos o con un atajo global una vez que lo actives:

```ini
quick-terminal = true
quick-terminal-key = alt+space
quick-terminal-position = top      # top, bottom o center
```

El atajo está desactivado por defecto, porque una tecla global se le quita a todas las demás aplicaciones.

<a id="macos-integration"></a>

## Integración con macOS

- **Atajos.** Tres acciones: **Abrir ventana de Corta** (opcionalmente en una carpeta), **Traer ventana de Corta al frente**
  y **Mostrar u ocultar el terminal rápido**. Ninguna ejecuta un comando en un shell.
- **Servicios.** El texto seleccionado del terminal se ofrece al menú **Servicios**.
- **Entrada de teclado segura.** **Shell ▸ Entrada de teclado segura** impide que otras aplicaciones lean tus pulsaciones
  mientras Corta está delante — para escribir contraseñas. Un candado en la barra de título indica cuándo está realmente activa.
- **VoiceOver** lee el texto del terminal y sigue al panel activo.
- **Portapapeles desde programas.** Desactivado por defecto. Con `allow-clipboard-write = true`, un programa — incluido uno
  dentro de `tmux` o a través de `ssh` — puede poner texto en tu portapapeles (OSC 52). Nada puede leerlo de vuelta.

<a id="speed-and-battery"></a>

## Velocidad y batería

Corta hace por su cuenta lo que es rápido; nada aquí necesita un ajuste. Esto es lo que hace, para que sepas qué esperar.

- **Al escribir se usa la frecuencia de actualización máxima de la pantalla.** Mientras escribes, pegas o compones con un
  método de entrada, Corta pide la frecuencia de fotogramas máxima de la pantalla — 120 Hz en una pantalla ProMotion — y
  la deja bajar un segundo después de la última tecla. El modo de bajo consumo, una ventana inactiva y la presión térmica
  vuelven a bajar el techo cuando no escribes; la presión térmica crítica siempre lo hace.
- **La pantalla completa con un solo panel puede reducir la latencia en macOS 27 o posterior.** Corta presenta entonces
  sus fotogramas directamente en la pantalla, saltándose el compositor del servidor de ventanas: alrededor de un fotograma
  menos de la tecla a la pantalla en el Mac medido. Una división, la barra de búsqueda o cualquier otra cosa dibujada sobre
  el texto hace volver al compositor mientras se muestra. En macOS 26, todas las ventanas usan la ruta de copia por cola
  clásica como medida de compatibilidad ante un fallo de WindowServer (#380); las cifras de latencia anteriores no se
  midieron en ese sistema. (`CORTA_DIRECT_FULLSCREEN=0` en el entorno de arranque desactiva los cambios de pantalla
  completa, pero no la ruta de compatibilidad de macOS 26.)
- **Leer la salida y mostrarla llevan ritmos separados.** El lector del PTY sigue analizando mientras la pantalla presenta
  el estado más reciente al ritmo de la pantalla. Una prueba de rendimiento medida del núcleo alcanzó 317,3 MiB/s; esa
  cifra excluye la E/S del PTY, el renderizado y la visualización, y no es una velocidad prometida para un registro de
  compilación real o para `yes`.
- **El desplazamiento y los programas de pantalla completa solo redibujan lo que cambió.** vim, less, tmux y una línea de
  estado se desplazan moviendo lo ya dibujado.
- **Un historial largo sigue ocupando poco.** El historial se comprime en memoria a medida que sale de la pantalla — el
  aumento de memoria medido para 100.000 líneas de 120 columnas fue de unos 11 MiB — y la búsqueda, la copia y el cambio
  de tamaño trabajan directamente sobre él.
- **En reposo significa en reposo.** Un cursor parpadeante lo anima macOS en lugar de redibujarlo Corta, un shell en
  reposo no provoca despertares periódicos, y una ventana tapada o minimizada deja de dibujar por completo.
- **Los paneles ocultos ceden el paso.** Dos segundos después de que un panel quede oculto — otra pestaña, una ventana
  minimizada —, su salida se lee con prioridad de segundo plano, para que no compita con lo que estás mirando. No se
  pierde nada, y escribir o pegar en él restaura al momento la prioridad completa.

[Performance](../../PERFORMANCE.md) (en inglés) tiene las mediciones y cómo se hicieron.

<a id="settings-and-the-config-file"></a>

## Ajustes y archivo de configuración

Todos los ajustes están en un único archivo de texto, `~/.config/corta/config`. **Corta ▸ Ajustes…** (⌘,) edita ese mismo
archivo, y editarlo a mano está igual de soportado:

Los Ajustes son una barra lateral de categorías, con la misma disposición que Ajustes del Sistema:

- **General** — el tamaño de las ventanas nuevas, restaurar ventanas, confirmar el cierre, las notificaciones de tareas
  largas y las actualizaciones.
- **Apariencia** — claro u oscuro, la fuente monoespaciada del sistema, el tamaño y una vista previa en directo, la forma
  y el parpadeo del cursor, y la edición gráfica de temas.
- **Terminal** — el historial, el límite del historial de comandos, la campana, los valores de búsqueda, el comando para
  abrir archivos, la integración del shell, el estado del sistema opcional y los detalles del equipo local.
- **Teclado y ratón** — Usar Opción como Meta, cómo se abren los enlaces, el modificador que selecciona texto mientras un
  programa controla el ratón, copiar al seleccionar, y los modos y colores del indicador de fuente de entrada.
- **Atajos** — la tecla de cada comando; aparece una flecha de restablecer junto a los que has cambiado.
- **Terminal rápido** — el atajo global, la posición y la pantalla.
- **Conexiones** — Conectar por SSH y los preajustes guardados.
- **Privacidad y seguridad** — la escritura en el portapapeles desde programas (OSC 52), la Entrada de teclado segura, el
  historial de directorios y los hosts recientes.

Estos controles editan el mismo archivo de configuración. Los colores de los temas personalizados se pueden editar de
forma gráfica o mediante el archivo.

La barra de herramientas de la ventana añade SSH y SFTP. Ambos abren una hoja en la ventana con campos de host, usuario,
puerto y clave privada — el host puede ser un alias de la configuración — y sugieren hosts recientes y configurados; un
usuario, puerto o clave vacíos respetan la configuración de OpenSSH. SFTP abre el explorador del panel remoto, o pide un
host cuando el panel es local ([Trabajo remoto](#remote-work-ssh-and-sftp)).

```ini
theme = corta
appearance = auto
font-size = 14
scrollback-lines = 20000
notify-on-long-task = true
bind.equalize-panes = ctrl+cmd+e
```

La mayoría de los ajustes se aplican al instante; unos pocos (tamaño de ventana, longitud del historial) se aplican a la
siguiente ventana o sesión. [Configuration](../../CONFIGURATION.md) (en inglés) enumera cada clave, su valor predeterminado y
cuándo surte efecto.

<a id="keyboard-shortcuts"></a>

## Atajos de teclado

Cambia cualquier atajo con `bind.<command>` en el archivo de configuración; un valor vacío lo elimina, y entonces la
pulsación llega al programa del terminal:

```ini
bind.equalize-panes = ctrl+cmd+e
bind.close =
```

**Ayuda ▸ Atajos de teclado** muestra los que están en vigor en columnas alineadas; los comandos sin asignación aparecen
como **Sin configurar**. El menú contextual del terminal muestra los mismos atajos configurados.

El menú **Shell** mantiene a mano dividir, reabrir y Borrar pantalla. Las demás herramientas están agrupadas en
**Mover el foco**, **Comandos y salida**, **Directorio de trabajo**, **Distribución de paneles** y **Terminal y conexión**.

Los valores predeterminados, a fecha de esta versión — [Keyboard shortcuts](../../CONFIGURATION.md#5-keyboard-shortcuts)
(en inglés) es la lista de referencia:

| Comando | Atajo |
| --- | --- |
| Nueva ventana / Nueva pestaña | ⌘N / ⌘T |
| Cerrar | ⌘W |
| Dividir panel a la derecha / hacia abajo | ⌘D / ⇧⌘D |
| Mover el foco | ⌥⌘ + flecha |
| Redimensionar panel | ⌃⌘ + flecha |
| Ampliar panel | ⇧⌘↩ |
| Reabrir el panel cerrado | ⇧⌘T |
| Aumentar / Reducir / Tamaño real | ⌘= / ⌘− / ⌘0 |
| Buscar… / Buscar siguiente / Buscar anterior | ⌘F / ⌘G / ⇧⌘G (Buscar siguiente y anterior son fijos) |
| Copiar / Pegar / Seleccionar todo | ⌘C / ⌘V / ⌘A |
| Desplazar una página / al principio o al final | ⇧RePág, ⇧AvPág / ⇧Inicio, ⇧Fin |
| Comando anterior / siguiente | ⌘↑ / ⌘↓ |
| Comando fallido anterior / siguiente | ⇧⌘↑ / ⇧⌘↓ |
| Exportar texto… | ⇧⌘S |
| Borrar pantalla | ⌘K |
| Ajustes… | ⌘, |
| Paleta de comandos… | ⇧⌘P |

Todos los demás comandos — Igualar paneles, Borrar historial, Restablecer terminal, Explorar archivos remotos…, los
comandos de salida y de directorio de trabajo — no tienen tecla predeterminada y están a una búsqueda en la paleta de
comandos. [Keyboard shortcuts](../../CONFIGURATION.md#5-keyboard-shortcuts) (en inglés) tiene la tabla completa con el nombre
`bind.` de cada comando.

<a id="when-something-goes-wrong"></a>

## Cuando algo va mal

La [Solución de problemas](TROUBLESHOOTING.md) cubre lo que ves cuando algo falla y cómo arreglarlo — una descarga que
macOS no abre, una fuente rechazada, un atajo que no hace nada. [Features and limitations](../../FEATURES.md) (en inglés)
enumera lo que Corta todavía no hace. Informa de cualquier otra cosa en
[GitHub Issues](https://github.com/noah-qin/Corta/issues/new/choose). Para preguntas de uso, ve a
[Discussions → Q&A](https://github.com/noah-qin/Corta/discussions/categories/q-a) o pregunta en `#help` en el
[Discord](https://discord.gg/QNdWfdwr7j).
