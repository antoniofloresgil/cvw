# Linux SMP sobre Wally

Este banco arranca OpenSBI y Linux en los núcleos RTL de Wally con una caché
física compartida. Es independiente de la imagen SD y del flujo FPGA de
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

El árbol anuncia una caché unificada compartida de 2 KiB, con líneas de
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
coherencia con DMA externo o cachés privadas.

Referencias: [entrada de Linux RISC-V](https://docs.kernel.org/arch/riscv/boot.html),
[plataforma generic de OpenSBI](https://github.com/riscv-software-src/opensbi/blob/master/docs/platform/generic.md)
y [firmware FW_JUMP](https://github.com/riscv-software-src/opensbi/blob/master/docs/firmware/fw_jump.md).
