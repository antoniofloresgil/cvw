# Wally multicore sin cachés

El SoC admite `NCORES` harts homogéneos, con `NCORES=1` por defecto. La primera
implementación comparte RAM, ROM y periféricos, con un único reloj y reset.
La etapa 1 ejecuta bare metal con comunicación por memoria e interrupciones
entre harts. La etapa 2 añade AMO y LR/SC sobre esa memoria compartida. Cachés
coherentes, arranque OpenSBI y Linux SMP quedan para las etapas siguientes.

## Configuración y simulación

Desde la raíz, en Bash, con el toolchain de Wally y Verilator instalado:

```bash
source ./setup.sh
python3 tests/multicore/run.py
```

El script genera las configuraciones derivadas con `perl bin/derivgen.pl`,
compila un programa RV64I con CSR y ejecuta bancos de prueba con aserciones.
Invocar Perl explícitamente también funciona en checkouts antiguos con el
shebang de `derivgen.pl` en CRLF. No necesita Questa ni una placa. La generación de configuraciones borra y
recrea `config/deriv/`; no ejecutar simultáneamente otros procesos que lo lean.

Para una comprobación dual core:

```bash
python3 tests/multicore/run.py --cores 2 --latency 0 3
```

Por defecto comprueba 1, 2 y 3 harts con latencias de RAM de 0 y 3. El programa
de prueba reserva pilas para un máximo de cuatro harts. Los productos,
ejecutables y logs quedan en `sim/verilator/wkdir/multicore/`, ignorado por Git.

Para integrar el SoC en otro top, generar la configuración `multicore` de
`config/derivlist.txt` y usar:

```systemverilog
wallypipelinedsoc #(.P(P), .NCORES(2)) soc(/* puertos habituales */);
```

`NCORES` es un parámetro del SoC; `HART_ID` se propaga desde cada núcleo hasta
`mhartid`. No se necesita un campo nuevo en `cvw_t`. La configuración derivada
mantiene las extensiones de `rv64gc` salvo los atómicos y desactiva ambas cachés
y las ráfagas; reserva 64 KiB de RAM para este prototipo. Con más de un hart,
las aserciones rechazan cachés, memorias privadas DTIM/IROM, ráfagas o
una configuración sin bus. No se cambia automáticamente la ISA de una
configuración que no cumpla estos requisitos.

## Interconexión

Cada hart puede tener una petición pendiente. El puente registra su dirección,
tamaño, protección y sentido antes de bloquear su fase de datos. Esto evita
un bucle entre `HTRANS` y `HREADY`: el controlador sin caché de Wally genera
la petición inicial en función de `HREADY`.

El árbitro atiende por turnos las peticiones pendientes y solo mantiene una
transferencia en curso en el bus compartido. Conserva el propietario durante
las esperas, toma los datos y strobes de escritura de ese propietario y
registra la respuesta para el hart correspondiente. Una respuesta puede
coincidir con la aceptación de la siguiente dirección del mismo hart.
La planificación es justa si los esclavos terminan sus transferencias; un
esclavo que no responde puede bloquear el bus.

Se admiten transferencias `NONSEQ/SINGLE`; los AMO se identifican mediante
una señal interna `HATOMIC`, descrita más abajo. Hay ciclos adicionales
de registro y arbitraje: es una base funcional, sin pretensión de escalar en
ancho de banda con el número de núcleos. `HRESP` se devuelve al hart, aunque
el EBU actual de Wally continúa ignorándolo para generar excepciones.

Con `NCORES=1` se puentea el árbitro y se conserva la conexión directa y la
latencia anterior. Hart cero conserva la ruta jerárquica `dut.core`; los demás
se encuentran en `dut.harts[h].core`. Los bancos de prueba generales del
repositorio siguen siendo de un solo hart; el banco específico está aquí.

## Registros por hart

Direcciones relativas a las bases CLINT y PLIC de la configuración:

| Recurso | Desplazamiento |
|---|---|
| CLINT `msip[h]` | `0x0000 + 4*h` |
| CLINT `mtimecmp[h]` | `0x4000 + 8*h` |
| CLINT `mtime` compartido | `0xbff8` |
| PLIC contexto M de hart h | `c = 2*h` |
| PLIC contexto S de hart h | `c = 2*h + 1` |
| PLIC enables del contexto c | `0x2000 + 0x80*c` |
| PLIC threshold del contexto c | `0x200000 + 0x1000*c` |
| PLIC claim/complete del contexto c | `0x200004 + 0x1000*c` |

En RV64 dos registros MSIP de 32 bits ocupan una palabra de 64 bits; los
strobes deciden qué hart se modifica. RV32 permite acceder por separado a las
dos mitades de los registros de tiempo. `mtime` sigue contando ciclos del
reloj del SoC, como antes; `TIMECLK` no introduce un nuevo dominio de reloj.
El límite de direcciones es 4095 harts antes de solapar comparadores y `mtime`;
no implica que ese número sea realizable en una FPGA ni esté verificado.

## Qué verifican las pruebas

- Bus: tres maestros con peticiones consecutivas, esperas variables, datos y
  strobes de escritura, reparto por turnos y respuestas ERROR del esclavo.
- Periféricos RV32 y RV64: aislamiento de MSIP y comparadores, strobes de byte,
  lectura/escritura, y los seis contextos M/S de tres harts, incluyendo
  threshold, enrutado, claim y complete.
- SoC: todos los harts arrancan la misma imagen, leen su `mhartid`, usan pilas
  separadas, publican datos en memoria compartida, esperan una barrera,
  comprueban los datos de los demás, acceden a sus bancos PLIC y envían una IPI
  en anillo. Cada hart debe
  atender una interrupción software y otra de temporizador antes de terminar.
  Un fallo o un timeout hace fallar el proceso.

La barrera usa posiciones de memoria con un único escritor y `fence rw,rw`.
La prueba de la etapa 1 no constituye un mutex general. La etapa 2 incluye
pruebas de contadores concurrentes y exclusión mutua mediante atómicos. El arranque simultáneo tampoco
sustituye a OpenSBI HSM ni a un protocolo de arranque de Linux.

## Etapa 2: AMO y LR/SC compartidos

```bash
source ./setup.sh
python3 tests/multicore/run.py --suite atomic
# Solo dual core, con y sin esperas:
python3 tests/multicore/run.py --suite atomic --cores 2 --latency 0 3
```

Esta suite usa la configuración derivada `multicore_atomic`, que hereda
`multicore` y activa `ZAAMO_SUPPORTED` y `ZALRSC_SUPPORTED`. Para otro top,
seleccionar esa configuración y conservar `.NCORES(N)`. La suite `smoke`
continúa disponible y sigue siendo la predeterminada.

Cada núcleo etiqueta sus transacciones LSU como normal, LR, SC o AMO. El EBU
conserva esa etiqueta al arbitrar entre instrucciones y datos; los fetches IFU
se etiquetan como normales. El controlador sin caché utiliza `LSUAtomicM`,
que excluye los accesos del page-table walker, para iniciar las dos partes de
un AMO. El formato AHB externo no incorpora un nuevo puerto de operación;
`HATOMIC` solo conecta núcleos y árbitro dentro del SoC.

Con varios harts, `ahbmulticore` mantiene una reserva por hart. Un LR terminado
sin error registra dirección física y tamaño. La reserva abarca una palabra
XLEN: 8 bytes en RV64 y 4 en RV32. Una escritura completada a cualquier byte
de esa palabra invalida las reservas correspondientes, aunque escriba el
mismo valor. Una escritura en otra palabra no las invalida. Cada nuevo LR
reemplaza la reserva anterior y todo intento de SC la consume.

El SC se valida cuando el árbitro va a emitirlo en el bus compartido. Se exige
que coincidan dirección y tamaño con el último LR y que la reserva siga válida.
Un SC fallido devuelve 1 al núcleo y no accede al esclavo. Un SC válido emite
la escritura y devuelve 0 si termina sin error. La comprobación central evita
que una reserva comprobada al encolar el SC quede obsoleta antes de su turno.
El resultado permanece estable hasta el siguiente SC para sobrevivir a las
esperas por fetch de instrucciones antes de avanzar a writeback. La LSU
multinúcleo no autoriza ni descarta SC mediante el monitor local antiguo.

El cálculo de los nueve AMO permanece en la ALU del núcleo. El árbitro conserva
un bloqueo desde la lectura hasta terminar la escritura del AMO y activa
`HMASTLOCK` hacia el bus externo. Durante ese intervalo solo admite peticiones
del propietario, incluidos sus fetches IFU, para permitir que progrese el
controlador del núcleo. Después libera el bloqueo y vuelve al reparto por
turnos. Los errores en las transferencias AMO liberan el bloqueo; una escritura AMO sin una lectura
bloqueada previa se rechaza con ERROR. Reset borra bloqueos y reservas.

Con `NCORES=1` se conserva la ruta original, incluido el monitor LR/SC local;
no se inserta el árbitro central. La suite también verifica esa configuración.
En este prototipo sin cachés ni buffers de escritura, las operaciones de datos
de cada hart terminan antes de que se inicien las siguientes; esta ordenación
es más fuerte que la que necesitan los bits acquire/release. Las pruebas usan
`.aq`, `.rl`, `.aqrl` y `fence` en locks y barreras. La referencia normativa es
la [extensión A de RISC-V](https://docs.riscv.org/reference/isa/unpriv/a-st-ext.html).

### Verificación de la etapa 2

`atomic_bus_tb.sv` comprueba directamente el árbitro con tres maestros y
esperas de memoria. Incluye SC sin LR, consumo y reemplazo de reservas,
escritura del mismo valor, conflictos por bytes, tamaños distintos, escrituras
a otra palabra, un SC encolado antes de un AMO conflictivo, exclusión durante
AMO, fetches del propietario, errores de bus y reset. Comprueba que los SC
fallidos no llegan a memoria y que una reserva se revalida al emitir el SC.

`atomics.S`, ejecutado por los núcleos completos, comprueba:

- Los nueve AMO en `.W` y `.D`, valores previos devueltos, comparaciones con y
  sin signo, extensión de signo y la mitad superior de una palabra AHB RV64.
- Contadores incrementados por todos los harts mediante AMO y mediante LR/SC.
  Un registro de valores previos detecta duplicados u omisiones en los AMO.
- Un spinlock AMOSWAP que protege un contador con load/add/store separados.
- Una barrera reutilizable con contador AMO y fases alternas.
- Una escritura de hart 1 entre el LR y el SC de hart 0, que debe hacer fallar
  ese SC, y SC sin conflicto que deben tener éxito y consumir su reserva.

La suite también ejecuta `smoke.S` sobre cada SoC con atómicos activados,
para comprobar memoria compartida, IPI y temporizadores sin recompilar el RTL.

La suite ejecuta RV64 bare metal en modo M; no valida Linux ni memoria virtual
compartida, actualizaciones concurrentes de PTE o shootdowns de TLB. Las cachés
siguen desactivadas. Todos los escritores deben pasar por este árbitro: un DMA
externo necesitaría integrarse con el monitor. El EBU de Wally aún ignora
`HRESP` para generar excepciones; las pruebas de errores verifican la
recuperación del puente, no excepciones de acceso del procesador. La validación
física en FPGA sigue pendiente.

## Etapa 3: caché física compartida y plataforma Linux SMP

```bash
source ./setup.sh
python3 tests/multicore/run.py --suite atomic --shared-cache
```

El SoC añade los parámetros `SHARED_CACHE` (predeterminado 0) y
`SHARED_CACHE_WORDS` (predeterminado 256). Para activarla, usar la
configuración derivada `multicore_coherent` y `.SHARED_CACHE(1)` con
`.NCORES(N)`. Cada línea guarda una palabra AHB completa; el tamaño por
defecto es 2 KiB en RV64. `WORDS` debe ser una potencia de dos mayor o igual
que dos. RAM interna y memoria externa son las únicas regiones asignables;
ROM y MMIO conservan dirección, tamaño y ordenación originales.

La caché unificada se sitúa **después** del árbitro de reservas y AMO. Un hit
sigue pasando por la serialización común. Una escritura siempre llega a
memoria y, si encuentra una línea válida, la invalida antes de responder.
No hay líneas sucias ni buffers de escritura. Una lectura fallida no asigna
línea; una lectura parcial que falla en caché obtiene una palabra completa
alineada para no guardar bytes indefinidos. Los errores conservan la
respuesta AHB de dos ciclos. Reset invalida todas las líneas.

Existe una sola copia física: instrucciones y datos de todos los harts usan
la misma caché. Esta primera implementación evita un protocolo de snooping
entre cachés privadas; no implementa MESI. Los accesos externos que no pasan
por el árbitro no son coherentes. Se siguen rechazando configuraciones con
cachés privadas, memorias privadas o bursts. Con `SHARED_CACHE=0` se conserva
el comportamiento de las etapas anteriores, incluida la ruta directa de
un solo hart. Con caché y un hart se usa el árbitro central de atómicos.

`cache_tb.sv` comprueba hits mediante el número de transferencias externas,
conflictos de índice, lecturas parciales con llenado completo, escrituras
por bytes, write-around, MMIO sin asignación, lock AMO, errores y reset.
La suite de procesadores añade código escrito por hart 0, ejecutado por
todos, modificado por hart 1 y ejecutado de nuevo tras `fence.i`; comprueba
la visibilidad entre el camino de datos y el de instrucciones. AMO, LR/SC,
locks, barreras, IPI y temporizadores se ejecutan con y sin esperas de RAM.

La plataforma Linux, sus imágenes reproducibles y la prueba de procesos con
afinidad se describen en [linux/smp](../../linux/smp/README.md). La derivada
`multicore_linux` añade ROM de arranque, 128 MiB de RAM y Sv39. La derivada
`multicore_coherent` desactiva Svadu, Svpbmt y las extensiones de mantenimiento de
caché que no se implementan en este prototipo.

La suite `--suite uart --shared-cache --cores 2 --latency 3` verifica que
cuatro instrucciones de escritura a THR produzcan exactamente cuatro
accesos APB; la configuración del divisor no cuenta como transmisión. El
modelo UART ya imprime los caracteres y el observador de Linux se limita
a reconocer el resultado, evitando un segundo eco en C++.

## Cachés privadas de datos y MSI (primer paso)

El modo opcional MSI añade un banco privado de datos por hart, con estados
Invalid/Shared/Modified y escritura diferida (*write-back*). Se activa así:

```systemverilog
// Usar config/deriv/multicore_msi/config.vh para construir P.
wallypipelinedsoc #(
  .P(P), .NCORES(2),
  .PRIVATE_DCACHE(1), .PRIVATE_DCACHE_WORDS(256)
) soc(/* puertos habituales */);
```

`PRIVATE_DCACHE` vale 0 por defecto. `PRIVATE_DCACHE_WORDS` es el número de
palabras AHB por hart, potencia de dos >= 2: 256 palabras son 2 KiB/hart en
RV64 y 1 KiB/hart en RV32. Cada línea contiene una palabra completa.
`NCORES=1` elimina la lógica MSI y conserva el camino mononúcleo original,
aunque se deje `PRIVATE_DCACHE=1`. No combinar MSI efectivo y SHARED_CACHE.
No se activan las cachés antiguas mediante P.DCACHE_SUPPORTED: siguen
inhabilitadas porque no participan en el snooping.

Este primer diseño mantiene **una sola transacción de coherencia en curso**.
El árbitro central ordena todos los accesos, incluidos los aciertos, y entrega
HOWNER al controlador MSI. Los bancos son privados por hart, pero todavía
no permiten aciertos locales concurrentes. Las lecturas BusRd comparten la
línea; BusRdX/BusUpgr invalidan las otras copias antes de conceder M. Un dueño
M devuelve el dato actualizado a memoria antes de compartirlo; un reemplazo
M también debe completar su escritura. Las confirmaciones de snoop son
internas al controlador síncrono; no hay colas independientes.

Las instrucciones siguen sin caché privada, pero sus lecturas buscan copias
M en todos los bancos de datos, incluido el propio. Las reservas LR/SC y la
exclusión AMO siguen en el árbitro: incluso una escritura con acierto en M
pasa por él. ROM/MMIO no se almacenan en caché. No se admite coherencia con
DMA externo que evite este camino. Svadu, Svpbmt y las extensiones de
mantenimiento de caché están desactivadas en esta configuración.

Los errores de writeback conservan la línea M; los de relleno no asignan
línea. Se comprueba la respuesta ERROR del bus, pero el EBU existente no
convierte HRESP en una excepción precisa del núcleo. Reset invalida las
cachés; no preserva datos sucios a través del reinicio.

Después de `source ./setup.sh`:

```bash
python3 tests/multicore/run.py --private-dcache --unit-only --latency 0 3
python3 tests/multicore/run.py --private-dcache --suite atomic --cores 1 2 3 --latency 0 3 --cache-words 8
python3 tests/multicore/run.py --private-dcache --suite uart --cores 2 --latency 3
```

`--work-dir /tmp/wally-msi` permite construir en almacenamiento Linux nativo
cuando el workspace no distingue mayúsculas/minúsculas. `msi_tb.sv` integra
el árbitro y las cachés con una memoria que introduce esperas y errores;
comprueba transiciones dirigidas, exclusividad M y 2.000 operaciones con un
modelo de referencia. Las pruebas con núcleos reales observan el valor de
los bancos M además de la RAM para detectar PASS/FAIL: con write-back la
RAM sola puede estar desactualizada. Esa observación no vacía las cachés ni
participa en las transacciones.

La [decisión de diseño](../../docs/engineering/decisions/0003-private-msi-data-caches.md)
y el [registro de validación](../../docs/engineering/experiments/2026-10-19-private-msi.md)
distinguen estos resultados de la validación anterior con caché compartida.

## Etapa 5: instrucciones privadas y aciertos de lectura concurrentes

Sobre MSI se pueden activar dos mejoras independientes, ambas desactivadas
por defecto:

```systemverilog
wallypipelinedsoc #(
  .P(P), .NCORES(2), .PRIVATE_DCACHE(1), .PRIVATE_DCACHE_WORDS(256),
  .PRIVATE_ICACHE(1), .PRIVATE_ICACHE_WORDS(256), .LOCAL_DCACHE_READS(1)
) soc(/* puertos habituales */);
```

Cada I-cache es privada, física y de mapeo directo, con una palabra AHB por
línea. Un acierto de instrucciones o una lectura ordinaria con acierto en
la D-cache puede terminar sin usar el bus global. Varios harts pueden recibir
respuestas simultáneas, incluso mientras otro espera un fallo de caché.
Las escrituras, LR/SC, AMO y los fallos conservan un único punto de ordenación
y una sola transacción de coherencia en curso. No hay escrituras locales
que escapen al monitor de reservas.

Una escritura correcta invalida la palabra de instrucciones en todos los
harts. Durante las escrituras se retienen las lecturas locales de la misma palabra
física; los aciertos a otras palabras pueden completarse en paralelo, aunque
compartan índice de caché. Esto incluye el bloqueo ante escrituras por bytes
para evitar carreras con la invalidación. Las lecturas de datos también esperan
mientras hay un AMO bloqueado. Un fallo de I-cache consulta las copias M de
datos antes de rellenarse; ROM/MMIO no se guardan. `fence.i` sigue usando la
sincronización del pipeline. Las escrituras de DMA ajenas al bus siguen fuera
del contrato. Con `NCORES=1` desaparecen ambas mejoras y el protocolo MSI.

```bash
source ./setup.sh
python3 tests/multicore/run.py --private-dcache --private-icache --local-dcache-reads --unit-only --latency 0 3 --work-dir /tmp/wally-l1-unit
python3 tests/multicore/run.py --private-dcache --private-icache --local-dcache-reads --suite atomic --cores 1 2 3 --latency 0 3 --work-dir /tmp/wally-l1-soc
```

`--icache-words` configura el banco de instrucciones del SoC completo;
`--cache-words` configura el de datos. El banco unitario usa capacidades
pequeñas para forzar reemplazos. Para comparar cada mejora, omitir uno de
los dos indicadores nuevos. El SoC imprime ciclos y `TRAFFIC` (transferencias
hacia memoria y respuestas locales), además del criterio funcional PASS.

El [ADR 0004](../../docs/engineering/decisions/0004-private-instruction-caches.md)
detalla la ordenación. El [experimento de la etapa 5](../../docs/engineering/experiments/2026-10-19-private-l1.md)
recoge resultados y límites; el PASS Linux anterior con MSI no valida por sí
solo estos nuevos caminos.

La mejora de lecturas durante escrituras independientes queda descrita en el
[ADR 0005](../../docs/engineering/decisions/0005-independent-read-write-overlap.md)
y su [validación separada](../../docs/engineering/experiments/2026-10-19-independent-read-write.md).
El Linux que ya estaba ejecutándose usa la versión anterior y no valida este cambio.

## Escrituras locales en M

`LOCAL_DCACHE_WRITES=1` permite que una escritura ordinaria con acierto en M
actualice sus bytes sin emitir una transacción global. Se pueden activar estas
escrituras independientemente de las lecturas locales y de las I-caches:

```bash
source ./setup.sh
python3 tests/multicore/run.py --private-dcache --private-icache --local-dcache-reads --local-dcache-writes --suite atomic --cores 1 2 3 --latency 0 3 --work-dir /tmp/wally-m-stores
```

Los commits siguen notificándose al monitor central de reservas y a todas las
I-caches. Se bloquean durante AMO y ante cualquier transacción global a la misma
palabra, incluidas las lecturas que estén tomando datos modificados. Los
aciertos S, fallos y atómicos conservan el camino global. Con NCORES=1 desaparece
la mejora. El [ADR 0006](../../docs/engineering/decisions/0006-local-modified-stores.md)
y su [registro](../../docs/engineering/experiments/2026-10-19-local-modified-stores.md)
explican las prioridades para LR e I-fill simultáneos y las pruebas ejecutadas.

### Multiword private I/D lines

`PRIVATE_DCACHE_LINE_WORDS` and `PRIVATE_ICACHE_LINE_WORDS` independently
select power-of-two AHB words per line (default 1). Total capacity remains
`PRIVATE_DCACHE_WORDS` / `PRIVATE_ICACHE_WORDS`; each cache needs at least
two lines. Thus 256 RV64 words give 2 KiB with either 256 eight-byte lines
or 64 thirty-two-byte lines. RV64 uses four words per 32-byte line; RV32 uses
eight. The one-core path removes the extra private caches/coherence as before.

```bash
source ./setup.sh
python3 tests/multicore/run.py --private-dcache --private-icache --local-dcache-reads --local-dcache-writes --cache-words 256 --icache-words 256 --cache-line-words 4 --icache-line-words 4 --cores 1 2 3 --latency 0 3 --suite atomic --work-dir /tmp/wally-lines
```

The controller unit matrix uses the same geometry arguments, including
RV32/RV64 cases; `4/4` means 16-byte lines on RV32. Use `8/8` for a dedicated
32-byte RV32 comparison. Model paths include capacities and line sizes.
Multiword directed checks cover adjacent-word hits, full-line ownership and
dirty intervention/replacement, partial stores, LR/SC/AMO, instruction
invalidation, local concurrency, every fill/writeback error beat, MMIO bypass
and reset, followed by 2,000 deterministic random operations per case.

Fills and writebacks use serialized aligned SINGLE word transfers, without
requiring AHB bursts. MSI ownership is per D line and I validity is per I line;
failed partial fills do not allocate. Local hazards conservatively cover the
larger I/D line, including the gaps between I-fill transfers. Larger lines
can increase false sharing and transfer cost; compare identical total byte
capacities before choosing a non-default geometry. See
[ADR 0007](../../docs/engineering/decisions/0007-multiword-private-cache-lines.md)
and the [multiword results](../../docs/engineering/experiments/2026-10-19-multiword-lines.md).

### Optional supplier forwarding

Add `--cache-to-cache` with private MSI to enable complete-line ownership
transfer and read-intervention forwarding. Default off; local-hit options
remain independent. Tests check every line word, byte masks, no target RAM
traffic for M-to-M, exact mandatory writeback for M-to-S and old-owner
invalidation. See the engineering cache-to-cache experiment for the matrix.
