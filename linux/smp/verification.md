# Verificación de la etapa 3

Este informe conserva los resultados anteriores al merge de `main`. La
verificación de las fuentes combinadas está en el
[registro de integración del 19 de octubre](../../docs/engineering/experiments/2026-10-19-multicore-main-integration.md).

Verificación realizada el 17 y 18 de octubre de 2026 sobre la rama `multicore-support`, a
partir del commit `17fcce818`. Simulador Verilator 5.022 y compilador RISC-V
bare metal GCC 13.2.0. Linux 6.19.14, OpenSBI 1.7 y toolchain Linux GCC 15.2.0
de Buildroot 2026.02.3. No se utilizó una placa FPGA.

## Caché y procesadores

Pruebas directas aprobadas: CLINT RV32/RV64, seis contextos PLIC, arbitraje AHB,
reservas LR/SC, exclusión AMO y caché compartida. Una prueba UART con
dos harts y tres esperas comprueba exactamente cuatro escrituras THR para
ABCD (7310 ciclos), sin duplicación de accesos, además de lecturas y
escrituras por bytes y medias palabras en RAM con los procesadores completos.
La misma prueba con instrucciones comprimidas RV64IC pasó en 7435 ciclos.
El banco de la caché verifica hits mediante el recuento de transferencias, llenados completos desde lecturas
parciales, colisiones, escrituras por bytes, MMIO, locks, errores y reset.

Suite de procesadores con caché compartida de 256 palabras:

| Harts | Esperas RAM | Atómicos: ciclos | Memoria/IPI/timer: ciclos |
| --- | --- | --- | --- |
| 1 | 0 | 7092 | 1256 |
| 1 | 3 | 8481 | 1461 |
| 2 | 0 | 9707 | 1403 |
| 2 | 3 | 11933 | 1699 |
| 3 | 0 | 14041 | 1782 |
| 3 | 3 | 17344 | 2141 |

La suite de atómicos incluye el parche de instrucciones entre harts, seguido
de `fence.i`. También se repitieron las suites sin caché para 1 y 2 harts con
3 esperas: atómicos 7446/16516 ciclos; memoria/IPI/timer 1209/2082 ciclos.
La configuración final con Svadu y Svpbmt desactivados se volvió a comprobar
con dos harts y 3 esperas: 11933 y 1699 ciclos, respectivamente.

El lint estricto pasó para las configuraciones tradicionales `rv64gc`,
`rv32gc`, `rv32i`, la etapa 2 con tres harts y las configuraciones compartidas
`multicore_coherent` con tres y `multicore_linux` con dos. Las comprobaciones
pre-commit también pasaron sobre los archivos de esta etapa.

Los contadores de ciclos pertenecen a estas cargas pequeñas; no son una
medida general de escalabilidad ni de rendimiento de Linux. Las cachés
privadas permanecen desactivadas y no hay DMA externo.

## Linux SMP: QEMU y RTL

La imagen del perfil UART de `kernel.config`, con OpenSBI 1.7, arrancó dos
CPU y ejecutó el initramfs tanto en QEMU como en el RTL de Wally. Ambos
runners terminaron con código 0 y estos resultados:

```text
WALLY_SMP_ONLINE cpus=2 expected=2
WALLY_SMP_PASS cpus=2 counter=128 protected=128
```

La ejecución Verilator terminó con:

```text
PASS: Linux SMP on Wally RTL after 262311969 cycles
```

Se ejecutaron los dos núcleos Wally, sus MMU Sv39, el árbitro de reservas y
AMO, la caché compartida de 256 palabras y los periféricos reales del SoC.
Linux arrancó el segundo hart mediante OpenSBI; `/init` comprobó las dos
CPU online, la afinidad y el estado de salida de un proceso por CPU, un
contador atómico y otro protegido por spinlock. El arranque y la prueba
completa tardaron aproximadamente 1 h 45 min en este entorno; ese tiempo
depende del host y no mide el rendimiento de una FPGA.

El manifiesto de cada compilación registra los hashes de firmware, kernel,
DTB, init y precargas. Los productos de esta ejecución se conservan fuera de
Git en `~/wally-smp-headless`. Para reproducirla desde el repositorio:

```bash
source ./setup.sh
python3 linux/smp/build.py --buildroot /home/cad/wally-buildroot --work ~/wally-smp-headless --cores 2 --jobs 4
python3 linux/smp/run.py --work ~/wally-smp-headless --sim qemu
python3 linux/smp/run.py --work ~/wally-smp-headless --sim verilator
```

Una copia de los logs de las pruebas, el manifiesto, la configuración
efectiva del kernel y los hashes de fuentes está en el directorio ignorado
`sim/verilator/wkdir/multicore/verification-stage3/`. `linux-rtl.log` contiene
el arranque y el resultado completo; `linux-qemu.log` es la referencia de
software. QEMU no valida el RTL. No se ha realizado validación en FPGA ni
se ha modificado la imagen SD anterior.
