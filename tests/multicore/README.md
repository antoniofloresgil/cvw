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
