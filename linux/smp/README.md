# Linux SMP sobre Wally

Este banco arranca OpenSBI y Linux en los núcleos RTL de Wally con una caché
física compartida o cachés privadas de datos MSI. Es independiente de la imagen SD y del flujo FPGA de
Nexys Video: no cambia ni flashea ninguna tarjeta.

## Preparación

Se necesita una compilación existente de Buildroot 2026.02.3 con toolchain
RV64 Linux/glibc, el archivo descargado `dl/linux/linux-6.19.14.tar.xz` y las
fuentes de OpenSBI 1.7 en `output/build/opensbi-1.7`. También hacen falta
Verilator, un compilador C++ y `dtc`. QEMU es opcional.

```bash
source ./setup.sh
python3 linux/smp/build.py --buildroot /ruta/a/buildroot --cores 2 --jobs 4
python3 linux/smp/run.py --sim qemu
python3 linux/smp/run.py --sim verilator
```

El kernel de prueba usa la consola UART y omite las consolas virtuales,
los pseudoterminales antiguos y los dispositivos de entrada que no existen
en este SoC. El arranque RTL puede tardar horas; consultar `rtl.log` permite
seguir el progreso sin reiniciar la simulación.

Los productos se guardan por defecto en `~/wally-smp-work`, fuera del árbol
Git. `--work /otra/ruta` permite separar compilaciones para distintos números
de harts. Mantener un directorio por ejecución concurrente. El kernel se
extrae y compila allí; no se recompila ni sobrescribe el kernel original de
Buildroot. Cambiar `--cores N` regenera el DTB y el programa `/init`; admite
1 a 8 harts, con identificadores contiguos desde cero.

`manifest.json` registra versiones y hashes de los productos. `rtl-build.log`
contiene la compilación del modelo, `rtl.log` su consola y progreso;
`qemu.log` contiene la ejecución de referencia. Se puede consultar el log
mientras corre. El DTB usa `loglevel=4` para reducir el tiempo de transmisión
del UART en RTL; para depurar el arranque se puede cambiar a 7 en el generador
y regenerar las imágenes. `--reuse` evita recompilar un modelo RTL ya construido; usarlo
solo si no han cambiado RTL, configuración ni número de harts.

## Modo MSI y puntos de control

Para probar la integración con cachés privadas de datos:

```bash
python3 linux/smp/build.py --buildroot /ruta/a/buildroot --work ~/wally-smp-msi --cores 2 --cache-mode msi --cache-words 256
python3 linux/smp/run.py --work ~/wally-smp-msi --sim qemu
python3 linux/smp/run.py --work ~/wally-smp-msi --cache-mode msi
```

El manifiesto registra modo y capacidad, y el DTB describe una D-cache privada
por CPU, sin caché compartida ni I-cache. El modo original sigue siendo
`shared`. El runner exige que cualquier selección explícita coincida con el
manifiesto y verifica los hashes de las imágenes. `NCORES=1` con MSI solicitado
elimina la coherencia y no anuncia cachés en el DTB.

El modelo RTL permite guardar/restaurar su estado completo. Se guarda cada
5 millones de ciclos por defecto y al recibir SIGTERM/SIGINT. Para continuar:

```bash
python3 linux/smp/run.py --work ~/wally-smp-msi --cache-mode msi --reuse --resume
```

`--build-only` compila sin ejecutar; `--checkpoint` permite elegir la ruta y
`--checkpoint-interval` el intervalo. `--cycles` limita el total absoluto,
incluidos los ciclos anteriores a una restauración. Una interrupción o límite
devuelve 75 y registra INCOMPLETE; un fallo devuelve 1 y PASS devuelve 0.
`rtl-result.json` describe la última ejecución terminada. No confundir el
INCOMPLETE de una prueba limitada anterior con el proceso que sigue ejecutando.

La reutilización comprueba las fuentes, parámetros y hash del ejecutable.
La restauración también comprueba la identidad del modelo y las imágenes.
Un bloqueo impide dos ejecuciones RTL simultáneas en el mismo directorio.
No reutilizar un snapshot tras modificar el RTL, el harness o las imágenes;
conservarlo como evidencia y usar otro directorio/checkpoint para el nuevo
modelo. Los resultados MSI se registran por separado en el
[experimento Linux MSI](../../docs/engineering/experiments/2026-10-19-linux-msi.md).
La ejecución de dos harts con 256 palabras por caché privada terminó con PASS
en 629.148.416 ciclos: dos CPU online y ambos contadores compartidos a 128.

## Plataforma y arranque

| Dirección física | Contenido |
| --- | --- |
| `0x00001000` | ROM mínima: `a0=mhartid`, `a1=DTB`, salto a OpenSBI |
| `0x02000000` | CLINT con MSIP y MTIMECMP por hart |
| `0x0c000000` | PLIC, dos contextos M/S por hart |
| `0x10000000` | UART 16550, interrupción 10 |
| `0x80000000` | Firmware OpenSBI `fw_jump.bin` |
| `0x80200000` | Linux `Image`, con initramfs incorporado |
| `0x87000000` | DTB con los N harts y sus interrupciones |

Hay 128 MiB de RAM hasta `0x87ffffff`. Los `.memfile` de simulación son
precargas dispersas de ROM y RAM, no imágenes de disco ni un bootloader SD.

Todos los harts entran en OpenSBI en modo M. Su plataforma `generic` descubre
los harts, CLINT y PLIC desde el DTB y proporciona HSM, IPI, temporizadores y
RFENCE. Linux entra en modo S y usa HSM para arrancar los secundarios. La
configuración `multicore_linux` usa Sv39, atómicos y Svade: Linux actualiza
por software los bits A/D de las PTE. Se desactiva Svadu porque el walker
actual no realiza una actualización A/D atómica entre harts. También se
desactiva Svpbmt: esta caché selecciona RAM por dirección física y no recibe
los atributos de memoria de las PTE.

En el modo `shared`, el árbol anuncia una caché unificada compartida de 2 KiB, con líneas de
8 bytes. Las cachés privadas están desactivadas. Las escrituras atraviesan
la caché e invalidan su línea; las lecturas asignan una palabra completa.
El árbitro común conserva las reservas LR/SC y serializa las dos mitades de
cada AMO. Todos los escritores deben usar ese camino.

## Criterio de éxito

Los resultados de las pruebas terminadas están en [verification.md](verification.md).

El initramfs contiene un `/init` estático escrito en C, sin shell. Comprueba
que hay exactamente N CPU online, crea un proceso por CPU y fija su afinidad.
Los procesos incrementan un contador atómico compartido y otro protegido por
un spinlock. El padre comprueba resultados y estados de salida.

Para dos harts la consola debe terminar en:

```text
WALLY_SMP_ONLINE cpus=2 expected=2
WALLY_SMP_PASS cpus=2 counter=128 protected=128
```

El runner termina con éxito solo al observar `WALLY_SMP_PASS`. Un fallo o
un timeout devuelve código distinto de cero. El proceso invitado permanece
vivo; el runner detiene la simulación tras reconocer el resultado.

QEMU comprueba firmware, DTB, kernel y userspace en una máquina `virt`; no
valida el RTL de Wally. En Verilator se ejecutan los procesadores, MMU,
árbitro, caché y periféricos reales. La consola observa las escrituras THR
del UART sin eliminar sus esperas ni sus interrupciones. Esta prueba no
constituye validación en FPGA, cobertura completa de Linux ni soporte de
coherencia con DMA externo. El PASS anterior con caché compartida no valida
las cachés privadas MSI; consultar el registro de cada modo.

Referencias: [entrada de Linux RISC-V](https://docs.kernel.org/arch/riscv/boot.html),
[plataforma generic de OpenSBI](https://github.com/riscv-software-src/opensbi/blob/master/docs/platform/generic.md)
y [firmware FW_JUMP](https://github.com/riscv-software-src/opensbi/blob/master/docs/firmware/fw_jump.md).

## I-caches privadas y lecturas locales de datos

El modo MSI permite activar las mejoras de la etapa 5 al preparar la imagen:

```bash
source ./setup.sh
python3 linux/smp/build.py --buildroot /ruta/a/buildroot --work ~/wally-smp-l1 --cores 2 --cache-mode msi --private-icache --icache-words 256 --local-dcache-reads
python3 linux/smp/run.py --work ~/wally-smp-l1 --sim qemu
python3 linux/smp/run.py --work ~/wally-smp-l1
```

El manifiesto registra ambas opciones y la capacidad I; el DTB añade el banco
de instrucciones a cada CPU cuando hay más de un hart. El runner selecciona
los parámetros del manifiesto y comprueba también las opciones explícitas,
incluidos `--no-private-icache` y `--no-local-dcache-reads`. Usa modelos y
checkpoints separados de los del modo MSI anterior. No se puede restaurar un
snapshot antiguo para probar RTL modificado. La referencia QEMU valida
software y DTB; el resultado de RTL se registra por separado en el
[experimento de la etapa 5](../../docs/engineering/experiments/2026-10-19-private-l1.md).

Para incluir también las escrituras locales en M, añadir
`--local-dcache-writes` al comando de build.py. El manifiesto registra la
opción y run.py la selecciona automáticamente; `--no-local-dcache-writes`
solo es válido si coincide con el manifiesto. Los modelos y checkpoints con
esta opción tienen un sufijo `-w1`. Usar un directorio de trabajo nuevo para
validar conjuntamente las mejoras 2 y 3, conservando los modelos anteriores.

### Private cache line geometry

For MSI, `build.py`, `devicetree.py` and `run.py` accept independent
`--cache-line-words` and `--icache-line-words` options. They default to 1;
four words select 32-byte lines in this RV64 Linux configuration. Keep
`--cache-words 256 --icache-words 256` to retain 2 KiB per bank while changing
line sizes. Each capacity must contain at least two power-of-two lines.
For example, append these options to the existing private-cache build command:

```bash
--cache-mode msi --private-icache --local-dcache-reads --local-dcache-writes --cache-words 256 --icache-words 256 --cache-line-words 4 --icache-line-words 4
```

A geometry change requires regenerating the DTB and packed RAM image. DTS
cache block sizes and set counts reflect the selected geometry; the total
cache sizes stay fixed. Manifests, model/checkpoint identities and non-default
model-directory suffixes (`-dl4-il4`) distinguish line geometry. Old manifests
imply one-word lines. Explicit mismatches are rejected; a snapshot from a
different model cannot be reused. Existing one-word Linux runs do not validate
multiword RTL. See the [multiword record](../../docs/engineering/experiments/2026-10-19-multiword-lines.md)
for the actual verification scope.

### Optional cache-to-cache supply

Add `--cache-to-cache` when building MSI images; run.py infers it from the
manifest, or verifies an explicit `--cache-to-cache`/`--no-cache-to-cache`.
Model directories, fingerprints, result and checkpoint identities include
this option. Forwarding does not change DTB geometry. Default off, single-core
bypass unchanged. A preceding Linux PASS cannot validate a new RTL option.
