# Solución de problemas

[Índice de la documentación (inglés)](../../README.md) · [Presentación del proyecto](README.md)

🇺🇸 [English](../../TROUBLESHOOTING.md) · 🇨🇳 [简体中文](../zh-CN/TROUBLESHOOTING.md) · 🇭🇰 [繁體中文](../zh-Hant/TROUBLESHOOTING.md) · 🇯🇵 [日本語](../ja/TROUBLESHOOTING.md) · 🇰🇷 [한국어](../ko/TROUBLESHOOTING.md) · 🇩🇪 [Deutsch](../de/TROUBLESHOOTING.md) · 🇫🇷 [Français](../fr/TROUBLESHOOTING.md) · 🇪🇸 [Español](TROUBLESHOOTING.md) · 🇧🇷 [Português](../pt-BR/TROUBLESHOOTING.md)

> Esta página es una traducción de [TROUBLESHOOTING.md](../../TROUBLESHOOTING.md), tal como estaba en el commit
> [`68169b9`](https://github.com/noah-qin/Corta/blob/68169b98164d5780f2959377a810eaf1be55e524/docs/TROUBLESHOOTING.md).
> Si la versión en inglés ha cambiado desde entonces, o si ambas difieren, prevalece la versión en inglés.
> Los mensajes de macOS van acompañados de su texto original en inglés.

Qué hacer cuando Corta no se instala, no arranca o hace algo que tu terminal anterior no hacía. Cada entrada dice qué
verás, por qué y cómo solucionarlo — y la última sección explica cómo volver limpiamente a tu terminal de antes si nada de
esto ayuda, porque un informe que dice «volví atrás, y este es el motivo» es una de las cosas más útiles que puedes enviar.

Si alguna entrada es incorrecta o falta, abre una issue con la plantilla **Installation blocker** o
**Went back to my old terminal**: <https://github.com/noah-qin/Corta/issues/new/choose>.

---

<a id="installing"></a>

## Instalación

### «No se puede abrir Corta porque Apple no puede comprobar si contiene software malicioso» ("Corta can't be opened because Apple cannot check it for malicious software")

Las versiones oficiales están firmadas con Developer ID y notarizadas. Una compilación desde el código fuente puede no
estarlo. Para una versión descargada, comprueba su suma de verificación y las comprobaciones de la imagen y de la app que
aparecen abajo, y luego informa del mensaje exacto junto con la versión.

### «Corta está dañado y no se puede abrir» ("Corta is damaged and can't be opened")

La imagen de disco puede estar incompleta, alterada o haber sido rechazada por la validación de firma de macOS. Primero
compruébala con el archivo `.sha256` publicado junto a ella. Guarda ambos archivos en la carpeta de descargas y sustituye
`x.y.z` por la versión que descargaste:

```sh
shasum -a 256 -c Corta-x.y.z.dmg.sha256
```

Si no coincide, descárgala de nuevo. Cada paquete de versión se comprueba con su archivo complementario antes de
publicarse (`corta-release-check`), así que una discrepancia es motivo para detenerse y volver a descargar. Si la suma de
verificación coincide, comprueba la imagen y la app copiada. Sustituye `x.y.z` por la versión descargada en todos los
comandos y ejecútalos desde la carpeta de descargas:

```sh
spctl -a -t open --context context:primary-signature -v Corta-x.y.z.dmg
xcrun stapler validate Corta-x.y.z.dmg
spctl --assess --type exec /Applications/Corta.app
xcrun stapler validate /Applications/Corta.app
```

Incluye en tu informe la versión, el error de macOS y estos resultados. No te saltes Gatekeeper para probar una versión.
Las versiones hasta la 1.1.8 conservan sus sumas de verificación ZIP originales; usa el nombre de archivo de esa versión.

### Corta ofrece moverse a /Applications

Corta se abrió desde `~/Downloads` u otra carpeta. Funciona desde cualquier sitio; `/Applications` es donde esperan
encontrarlo las actualizaciones de Sparkle y Spotlight. Di que no y dejará de preguntar — o pon
`suggest-applications-folder = false` en `~/.config/corta/config`.

Si se abre directamente desde la imagen de disco, macOS ejecuta Corta desde una ubicación temporal de solo lectura, así que
no puede moverse por sí mismo; en su lugar te pide que lo arrastres a Aplicaciones. Si ya hay allí un Corta más reciente,
ofrece abrir ese en lugar de sustituirlo por la copia más antigua.

### Hay dos iconos de Corta en el Dock

Uno de ellos es una compilación de desarrollo. El Finder lo llama **Corta Dev**, la barra de menús **CortaDev**, su icono
tiene un fondo naranja en lugar de azul, y su identificador de paquete es `dev.noahqin.Corta.dev`. Guarda su configuración
y su estado en `~/Library/Application Support/Corta Dev/`, nunca en `~/.config/corta/config` ni en
`~/Library/Application Support/Corta/`, y no tiene la opción de menú «Buscar actualizaciones…» — así que el del icono azul
es el Corta instalado, sea cual sea el orden en que aparezcan. Salir de uno o eliminarlo no afecta al otro. Solo tiene uno
quien compila Corta desde el código fuente (`CONTRIBUTING.md`, «Developing Corta in Corta»).

### «Esta versión de Corta requiere macOS 26.0 o posterior» ("This version of Corta requires macOS 26.0 or later")

El destino de despliegue de Corta es macOS 26.0, y usa API de Metal 4 y Core Text de esa versión. No hay compilación para
sistemas anteriores, y el proyecto no tiene previsto hacerla (`DESIGN.md` §6).

### «No puedes abrir la aplicación “Corta” porque no es compatible con este tipo de Mac» ("You can't open the application "Corta" because it is not supported on this type of Mac")

Desde la 1.1.0, Corta se compila solo para Apple silicon — un Mac con chip M1 o posterior (`DECISIONS.md` D21). Un Mac con
Intel no puede ejecutarlo. La **1.0.1** es la última versión para Mac con Intel, y sigue disponible en la
[página de la versión 1.0.1](https://github.com/noah-qin/Corta/releases/tag/v1.0.1): descarga `Corta-1.0.1.zip`,
compruébalo y sustituye la copia de `/Applications`. A un Mac con Intel que ya ejecuta la 1.0.x, **Buscar actualizaciones…**
no le ofrece la 1.1.0, así que sigue funcionando como está; este mensaje solo aparece cuando se descargó y abrió a mano un
archivo más reciente.

Para saber qué chip tiene un Mac, elige menú Apple ▸ Acerca de este Mac: la línea *Chip* nombra un chip de Apple (M1, M2,
…) en Apple silicon, y una línea *Procesador* nombra uno de Intel.

---

<a id="starting"></a>

## Arranque

### La ventana se abre en blanco, o se abre y se cierra

Ábrelo desde Terminal.app para ver por qué:

```sh
/Applications/Corta.app/Contents/MacOS/Corta
```

Un panel que no puede iniciar su shell muestra una vista de error con un botón **Reintentar** en lugar de un lienzo en
blanco; si ves un lienzo en blanco sin vista de error, es un error de renderizado que merece un informe con la salida de
la consola.

### El shell no es el que esperaba, o no tiene PATH

Corta inicia `$SHELL` desde el entorno con el que se abrió (si no, `/bin/zsh`) como shell de inicio de sesión (`-l`), así
que se ejecutan tanto `~/.zprofile` como `~/.zshrc`. Un `$SHELL` que ya no existe recurre a `/bin/zsh` y después a
`/bin/sh`, con un aviso en el panel que indica qué escalón se usó. Si comandos que funcionan en Terminal.app «no se
encuentran» en Corta, comprueba qué vale `SHELL` en el entorno con el que se abren las *aplicaciones gráficas*
(`launchctl getenv SHELL`): un valor fijado ahí se aplica a todas las apps y sobrevive a la sesión que lo fijó. Ejecuta
`launchctl unsetenv SHELL` y vuelve a abrir.

Un **preajuste** (Shell ▸ Panel nuevo con preajuste) o `preset.<name>.shell` en el archivo de configuración sustituye esto
para cada panel.

### Corta restauró las ventanas de ayer y no las quería

`restore-windows = false` en `~/.config/corta/config`, o desmárcalo en Ajustes ▸ General. Una restauración que hizo fallar
la app no se vuelve a intentar: la disposición guardada se descarta y se abre una sola ventana nueva.

### Ajustes dice que no puede leer el archivo de configuración

`~/.config/corta/config` existe pero no es texto UTF-8 — normalmente un byte guardado por un editor con otra codificación —
o no tienes permiso para leerlo. Corta mantiene los ajustes que tiene y se niega a escribir el archivo, porque escribirlo
sustituiría todo su contenido. Vuelve a guardar el archivo como UTF-8 (o elimina la línea defectuosa); Corta lo recoge en
cuanto vuelve a leerlo. La integración del shell hace lo mismo con un archivo rc que no puede leer: lo indica y no lo toca.

---

<a id="typing-and-rendering"></a>

## Escritura y renderizado

### Borrar pantalla deja solo un cursor, sin indicador

Actualiza Corta si ⌘K borra un indicador en espera. Con la integración del shell y una marca de final de indicador listo,
Borrar pantalla conserva ahora el indicador mostrado y la entrada sin enviar, incluido su cursor de edición. No envía
Retorno, Control-L ni ninguna otra entrada. Activa la integración del shell en un shell sin marcas de indicador; las sesiones
locales estándar de zsh la cargan automáticamente con las sugerencias incluidas. El redibujado con Control-L del propio
shell sigue siendo una alternativa cuando ese shell lo tiene configurado. Un programa en la pantalla alternativa, o un editor
de varias líneas cuyo indicador ya está en el historial, se deja intacto a propósito.

### Las sugerencias de carpetas se detienen tras una carpeta que termina en `/`

Solo los subdirectorios son candidatos; un directorio que solo contiene archivos no tiene más sugerencias de carpetas.
Escribe parte del nombre de una subcarpeta o vuelve a pulsar Tab cuando haya candidatos visibles. Tab rellena la ruta sin
ejecutarla; Retorno ejecuta `cd`. Las carpetas ocultas necesitan un punto al principio. Si falta una subcarpeta conocida,
comprueba el acceso a ese directorio y compara con la completación nativa del shell tras desactivar `directory-completion`.
Si la diferencia persiste, informa de la forma exacta de la ruta y del shell.

### Acerca de o el historial de comandos se abre lejos del terminal

Cierra y vuelve a abrir la ventana en la versión actual de Corta. Ambas se abren centradas sobre la ventana que las invoca,
dentro del área útil de su pantalla; no se colocan en el centro de toda la pantalla. Una ventana ya abierta conserva la
posición que elegiste.

### Tab no hace nada en el menú de comandos con barra de Claude Code

Corregido en la 1.0.0 (B02); la v0.1.1 tiene el error. Si vuelve a aparecer en una compilación más reciente, informa de
él con la versión de Claude Code: la corrección está en cómo `insertTab(_:)` procedente de una ventana de candidatos llega
al proceso hijo, y una nueva interfaz de candidatos podría encaminarlo de otra forma.

### ⌥ escribe `é`, `ø`, `–` en lugar de actuar como Meta

Ese es el comportamiento predeterminado de macOS, y Corta lo mantiene. Pon `option-as-meta = true` para que ⌥ envíe `ESC`
+ tecla, como hace la tecla Alt de un teclado de PC. Las teclas especiales (flechas, teclas de función) transmiten ⌥ como
modificador de xterm en cualquier caso.

### Los colores o `TERM` se ven mal a través de ssh

Corta anuncia `TERM=xterm-256color` a propósito (`docs/DECISIONS.md` D08). Compartir ese valor de TERM no implica una
compatibilidad total con xterm. Comprueba el entorno remoto con `printf '%s\n' "$TERM"` y compara un caso mínimo de
reproducción; [Conformance](../../CONFORMANCE.md#42-external-suites) (en inglés) recoge las secuencias admitidas y los fallos
pendientes.

### Un glifo se dibuja más pequeño que los de alrededor

Un carácter que falta en la fuente elegida sale de PingFang SC o de Apple Color Emoji. Un glifo de respaldo puede
escalarse para no salirse de sus celdas del terminal, así que su tamaño visible puede diferir del de los glifos vecinos.
Ajusta el tamaño de fuente en **Ajustes ▸ Apariencia** y compara la vista previa. Si un glifo se recorta o queda
desalineado, informa de su texto, la fuente, el tamaño de fuente, la escala de la pantalla y una captura.

### La fuente que elegí no es la que se dibuja

`font-family` nombra una familia, no un estilo (`JetBrains Mono`, no `JetBrainsMono-Regular`). Corta solo la usa si está
instalada y sus estilos normal, negrita y cursiva avanzan el mismo ancho en todo el ASCII imprimible; si no, dibuja la
monoespaciada del sistema y **Ajustes ▸ Apariencia** muestra una fila Estado de la fuente que indica qué comprobación
falló. Una fuente instalada mientras Corta está abierto aparece en la lista al momento; Reintentar vuelve a comprobar la
configurada.

Si el chino, el japonés o el coreano se dibujan con una fuente distinta de la elegida en **Fuente CJK**
(`font-family-cjk`), esa familia no está instalada o no tiene caracteres CJK; la línea bajo el menú lo indica, y en su
lugar dibuja la fuente del idioma del sistema. Un carácter que falta en la fuente elegida también sale de la fuente del
idioma del sistema. La fuente CJK no se usa mientras **Usar otras fuentes para los caracteres que faltan** está desactivado.

### Las imágenes de `kitten icat` no se ven, o se ven en el lugar equivocado

Corta implementa la transmisión directa (en banda) del protocolo de gráficos de Kitty en RGB, RGBA y PNG. La transmisión
basada en archivos (`t=f`, `t=t`, `t=s`), los fotogramas de animación y la colocación mediante marcadores Unicode no están
implementados, y la basada en archivos no lo estará: que un flujo remoto nombre un archivo local para leer es exactamente
lo que rechaza el modelo de amenazas (`SECURITY.md` §1). Prueba `kitten icat --transfer-mode=stream picture.png` para pedir
explícitamente la transmisión directa. Una imagen debe respetar los límites de 8192 píxeles por lado y 16 millones de
píxeles; las imágenes no válidas o demasiado grandes se rechazan.

### Un Retorno vacío dibuja una marca de comando verde o roja

Un Retorno vacío no es un comando, y los hooks de integración actuales no registran ninguno. Un bloque de archivo de
inicio instalado por un Corta anterior todavía puede comunicar uno: abre **Ajustes ▸ Terminal ▸ Integración del shell**,
elige **Actualizar** y luego abre un shell nuevo. Los shells ya abiertos mantienen las funciones antiguas hasta que se
reinician, y las marcas ya dibujadas se quedan. Solo se actualiza el bloque marcado de Corta en el archivo de inicio. Las
sesiones locales estándar de zsh que usan los hooks automáticos reciben la versión incluida al iniciarse un shell nuevo.

---

<a id="behaviour-that-differs-from-other-terminals"></a>

## Comportamientos distintos de otros terminales

### Se copia nada más terminar de seleccionar

`copy-on-select` está activado por defecto y lo confirma con una etiqueta en la esquina del panel. Ponlo en `false` para
copiar solo con ⌘C.

### Un programa dijo que había copiado al portapapeles, y no se copió nada

La *escritura* de OSC 52 está desactivada por defecto: de lo contrario, cualquier salida de un programa podría poner en el
portapapeles un texto que luego pegarías. `allow-clipboard-write = true` la activa, y es lo que necesitan `tmux` y una
sesión `ssh` remota. La dirección de *lectura* no existe con ningún ajuste.

### Al cerrar una ventana me pregunta si estoy seguro

Algo en esa ventana todavía tiene un trabajo en primer plano. `confirm-close = false` desactiva la pregunta en todas partes.

### El atajo del Terminal rápido no hace nada

Tres posibilidades, en este orden. `quick-terminal` está en `false` (por defecto): no se reserva ninguna tecla hasta que lo
pongas en `true`. Otra aplicación ya tiene la tecla: Ajustes ▸ Terminal rápido lo indica, y `quick-terminal-key` acepta
cualquier otra combinación con al menos un modificador. O la tecla es una que Corta no puede asociar a una posición de
tecla (`é`, una forma escrita de dos caracteres): la línea se conserva sin cambios en el archivo de configuración y se
aplica el valor predeterminado. Visualización ▸ Terminal rápido y la acción de Atajos *Mostrar u ocultar el terminal rápido*
abren el panel en cualquier caso.

### La insignia de un panel remoto dice «Remoto: host desconocido», o un `tmux` local dice «¿Remoto?»

La insignia toma el nombre del host del propio informe `OSC 7` del shell remoto o — en una conexión abierta desde la hoja
de conexión — del destino que escribiste allí. Nunca lo lee de una línea de comandos `ssh` escrita en el prompt (los
alias, los nombres de `~/.ssh/config` y las cadenas de hosts intermedios se leerían mal) ni del texto del prompt. Sin
ninguno de los dos, un panel `ssh` dice *host desconocido*, que es la verdad. Para que aparezca el host, pon también el
bloque de integración del shell de Ajustes ▸ Terminal en el `~/.zshrc` de la máquina remota; emite el `OSC 7` que lee la
insignia. Un `tmux` o un `screen` en primer plano muestra *¿Remoto?* porque la sesión a la que está conectado puede estar
a su vez en otra máquina y nada aquí puede saberlo — es incertidumbre, no una acusación.

### Explorar archivos remotos… dice que la autenticación falló, pero `ssh` funciona en el panel

La conexión SFTP pide una contraseña o una frase de contraseña de clave en un cuadro de diálogo sobre su ventana; un
cuadro rechazado o cancelado termina con este error. Comprueba el usuario y el puerto del formulario — el `User` y el
`Port` propios de un alias solo se aplican cuando esos campos están vacíos — y la clave, si elegiste una: una clave elegida
es la única que se ofrece. Si no apareció ningún cuadro de diálogo, el servidor rechazó todos los métodos que ssh podía
probar; `ssh -v` con el mismo usuario, puerto y clave en un terminal muestra cuáles.

### Explorar archivos remotos… dice que no se pudo verificar una clave de host

Un host visto por primera vez te pide que confíes en su clave, en un cuadro de diálogo que muestra la huella. Este error
significa que la clave *cambió* desde que confiaste en ella — un servidor reinstalado, o alguien en medio. ssh lo rechaza
hasta que se elimine la línea antigua de `~/.ssh/known_hosts` (`ssh-keygen -R <host>`); pregunta antes a quien administre
el servidor.

### El historial de comandos muestra «(el texto del comando ya no está en el historial)»

El texto de un comando se recupera de la cuadrícula, no se guarda: una vez que su línea de prompt sale más allá de
`scrollback-lines`, el registro conserva la hora, el estado y el directorio, pero el texto ya no está, y Rellenar y
Ejecutar no se ofrecen para él. Aumenta `scrollback-lines` si te pasa a menudo.

### No puedo volver al principio de una ejecución larga

`scrollback-lines` (10.000 por defecto) es un límite por sesión, y cuenta filas *físicas* — una línea de 200 columnas
partida a 100 columnas son dos. La salida más antigua que el límite se descarta a medida que llega; la pastilla de arriba
indica cuánto ha retrocedido la vista. Sube el límite (hasta 1.000.000; la memoria que ocupa el historial antiguo
comprimido depende del texto y de la carga). Una celda guardada ocupa 16 bytes antes de la compresión, lo cual no es una
estimación de la memoria residente. Una carga medida de 100.000 líneas de 120 columnas añadió unos 11 MiB de memoria
residente; consulta [Performance](../../PERFORMANCE.md#56-numbers-by-release) (en inglés). Exporta la salida que necesites
conservar más allá del límite configurado.

### La Entrada de teclado segura está activada pero mi herramienta de macros sigue funcionando

El candado de la barra de título indica cuándo está *en efecto*, y eso solo ocurre mientras una ventana de terminal de
Corta es la ventana activa y Corta es la aplicación activa. En cualquier otra aplicación, y mientras Ajustes es la ventana
activa, las pulsaciones se entregan con normalidad — esa es la idea, y por eso el indicador sigue el estado efectivo y no
el ajuste.

### Falta el icono de proxy del directorio en un montaje de red

Corta comprueba en segundo plano el directorio local comunicado. Si el montaje es lento o ya hay dos comprobaciones
esperando, deja el icono de proxy ausente para que la salida y la interacción con el teclado puedan continuar. Comprueba el
montaje por separado; cambiar de directorio cuando se recupere pide una nueva comprobación.

### Un panel se abre en la carpeta de inicio en lugar de en un directorio de red

Un panel nuevo, o una ventana restaurada al abrir, solo empieza en el directorio solicitado si este responde dentro de un
plazo breve. Un volumen de red que ha dejado de responder cuenta como ausente, así que el panel se abre en la carpeta de
inicio en lugar de congelar Corta. El mismo plazo se aplica al ⌘-clic o al pasar el puntero sobre una referencia
`path:line` allí: no se ofrece como enlace. Vuelve a conectar el volumen y luego haz `cd` a él o abre allí un panel nuevo.

### La edición remota vuelve a preguntar después de un aviso de subida

El archivo local cambió después de la versión que mostró el aviso original. Aprueba explícitamente la nueva edición. Una
entrada gestionada antigua sin resumen del contenido remoto también necesita una decisión de conflicto una vez. Una
comparación de contenido puede detectar cambios remotos aunque el tamaño y la marca de tiempo del archivo no hayan cambiado.

### Una subida de la edición remota vuelve a preguntar tras una larga espera

La conexión se atascó. Una vez conectada, cada operación de la edición remota tiene 120 segundos para terminar; después,
Corta cierra la conexión y vuelve a ofrecer la subida. Apruébala para reintentar con una conexión nueva. Un archivo muy
grande en un enlace lento también puede alcanzar el límite: cópialo con el navegador SFTP.

---

<a id="appearance-and-the-status-bar"></a>

## Apariencia y barra de estado

### El cursor no parpadea

El parpadeo está desactivado por defecto: activa **Parpadeo del cursor** en Ajustes ▸ Apariencia ▸ Cursor. Se detiene
mientras el panel está inactivo, oculto o desplazado hacia atrás. Un programa del terminal puede cambiar la forma o el
parpadeo para sí mismo con DECSCUSR; Restablecer terminal vuelve al estilo configurado.

### La barra de estado no muestra la velocidad de red, o muestra la que no es

Las velocidades necesitan dos muestras, así que espera unos segundos después de activar la barra. `auto` mide una interfaz
principal; cuando una VPN o varios adaptadores hacen que sea la equivocada, escribe el nombre de la interfaz en
Ajustes ▸ Terminal. Una interfaz indicada explícitamente que no existe no muestra velocidad. La barra siempre informa del
Mac local, también en un panel SSH, y los niveles térmicos son clasificaciones de macOS, no grados. Una ventana estrecha
puede recortar la barra; haz clic en ella para ver todos los valores elegidos.

### El editor de temas no guarda

Un color HEX no válido desactiva Guardar. Si el tema personalizado se cambió en el archivo de configuración mientras el
editor estaba abierto, cierra y vuelve a abrir el editor antes de guardar, para no sobrescribir ese cambio.

### La interfaz está en el idioma equivocado

Corta sigue el idioma que macOS elige para él (Ajustes del Sistema ▸ General ▸ Idioma y región ▸ Aplicaciones). Reinicia
Corta después de cambiarlo. El formato de los números sigue la región y puede ser distinto del idioma.

---

<a id="updating"></a>

## Actualizaciones

### Buscar actualizaciones… no encuentra nada

Corta compara **números de compilación**, no cadenas de versión, con `appcast.xml` en la rama `main`. Una versión
etiquetada y en borrador pero todavía no publicada no está en el canal; una vez publicada, el proceso de publicación firma
y verifica el canal, abre una pull request, espera a la CI y la fusiona con squash o activa la fusión automática. Una
comprobación del canal fallida o bloqueada puede retrasar la entrega, así que deja pasar un poco de tiempo después de que
la versión aparezca en GitHub. `update-auto-check = false` solo desactiva la comprobación diaria en segundo plano; la
opción de menú siempre funciona.

---

<a id="going-back-to-your-old-terminal"></a>

## Volver a tu terminal de antes

Sal de Corta antes de eliminar sus archivos. Revisa las copias gestionadas de la edición remota en busca de trabajo sin
guardar antes de eliminar los datos de la app:

1. **Integración del shell**, si la instalaste desde Ajustes ▸ Terminal: quítala allí, o borra el bloque entre
   `# >>> Corta shell integration >>>` y `# <<< Corta shell integration <<<` en el archivo de inicio de tu shell —
   `~/.zshrc`; para bash en `~/.bashrc` y `~/.bash_profile` (o `~/.bash_login` / `~/.profile`); o
   `~/.config/fish/config.fish`. Nada más en ese archivo es de Corta.
2. **La Entrada de teclado segura** se libera sola cuando Corta se cierra. Si se forzó la salida de Corta mientras una
   ventana estaba activa y la escritura en otros sitios parece bloqueada, abre Corta y ciérralo una vez; el contador se
   equilibra al salir.
3. **Ajustes y estado**: `~/.config/corta/` (el archivo de configuración) y `~/Library/Application Support/Corta/`
   (disposición de las ventanas, historial de directorios y copias gestionadas de la edición remota). Elimínalos solo
   después de conservar las ediciones locales que todavía necesites. El renderizador también guarda archivos de caché
   desechables en `~/Library/Caches/dev.noahqin.Corta/`; se pueden eliminar.
4. Mueve `Corta.app` a la Papelera.

Después, si te parece bien, abre una issue con el formulario
[**Went back to my old terminal**](https://github.com/noah-qin/Corta/issues/new?template=went_back.yml) y cuenta qué te
hizo volver. No necesita reproducción. Una función que falta, un error de renderizado y «simplemente lo notaba más lento»
son respuestas con las que el proyecto puede actuar.
