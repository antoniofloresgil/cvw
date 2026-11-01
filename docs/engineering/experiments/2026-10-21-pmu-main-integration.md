# Integración de main en adding-mpu-support

Estado: **PASS**. Rama `adding-mpu-support`, padre de la PMU
`8cb89bab9f71c7639eb43879dec31ba742ddc908`, main
`4ce065926c8096f34c77867c358f044ec1ea777e` (upstream oficial hasta
`89479dd09ce0ab37801505e61b277855eaeb8302`). El merge incorpora los 21
commits de main ausentes de la rama: 19 de upstream y dos del fork.

## Resolución

El único conflicto fue `docs/engineering/current-work.md`; el nuevo checkpoint
conserva el alcance de la PMU y registra el main integrado. `csrc.sv` se fusionó
automáticamente y sus tokens RTL sin comentarios coinciden con el padre de la
PMU; los cambios de upstream son de formato y comentarios. Se conserva la
implementación sintetizable de Zicntr/Zihpm, el mapa OpenSBI y el soporte de
Linux `perf stat`. Esta rama no incluye el RTL de `multicore-support`.

## Pruebas del árbol combinado

Tras `source ./setup.sh` y `make deriv`, se ejecutaron:

- `python3 tests/pmu/run.py --work /tmp/wally-pmu-upstream-20261021-unit`:
  **PASS** en seis combinaciones RV32/RV64 con 3/8/32 contadores; mapa PMU y
  ocho DTS de placa compilados con `dtc`.
- Diez lints: siete configuraciones normales, `pmu_linux`, `fpganexysvideo` y
  `fpgaqmtechk7`: **PASS**. El Verilator instalado no acepta `--quiet`; sólo se
  eliminó esa opción del comando de lint, sin cambiar la política de avisos.
  Resultados: `/tmp/wally-pmu-upstream-20261021-lint.json`.
- `hpmcounters.S`, preprocesado/ensamblado/enlazado en
  `/tmp/wally-pmu-upstream-20261021-coverage` para evitar la colisión `.S`/`.s`
  del sistema de archivos, ejecutado con `python3 bin/wsim rv64gc ... --sim
  verilator`: **PASS**, `SUCCESS! All tests ran without failures.` El
  Verilator de este host carece de `VL_SYSTEM_IN(std::string)` en el modelo de
  testbench generado; el helper compatible se añadió sólo a su cabecera PCH
  generada y se recompiló el modelo. No se modificó RTL ni testbench versionado.

La prueba de Linux utiliza las nueve entradas de software de la validación
anterior, copiadas y verificadas por SHA-256. Manifiesto de imágenes:
`a2d3318cf24f6baa006c5172e1aae248a5aeb729d34891dc1451dbe9529f1311`.
El modelo nuevo de `pmu_linux` se compiló sobre 229 fuentes del árbol combinado;
todas coinciden con su manifiesto. Modelo SHA-256:
`d02e5434c204db403d22d76a1b85cfd80e4e2f8776db5924235f8eba300ced00`.
Comando: `python3 linux/pmu/run.py --work
/tmp/wally-pmu-upstream-20261021-linux --reuse --cycles 1500000000 --jobs 2`
tras construirlo con `--build-only`. El Linux PMU combinado terminó **PASS** con código de salida 0 en
**121.617.639 ciclos**. El log muestra las siete lecturas de contadores, valores
idénticos tras detenerlos y la ejecución real de `perf stat` sobre `/workload`:
691.043 ciclos, 387.276 instrucciones, 65.102 ramas, 13.992 fallos de rama,
110.176 referencias de caché y 5.007 fallos de caché. Terminó con
`WALLY_PMU_PASS perf_event_open_and_perf_stat`. Log SHA-256:
`d70ce9f186bc940965305481bd2fa7a7916f2d9de7a7e8b5eae4a852b888edaf`.
El ciclo final coincide con el anterior Linux PMU PASS, que pertenecía sólo al
padre `8cb89bab9`; el modelo nuevo tiene identidad distinta y cubre el merge.

Los logs, binarios y checkpoints están en las rutas `/tmp` indicadas; los
resultados y manifiestos principales se copian también a
`sim/verilator/wkdir/pmu/verification-upstream-20261021/`. No se versionan. La síntesis, el timing y `perf` en placa no se han verificado en
esta rama. La PMU mantiene fuera de alcance el muestreo por interrupciones,
Sscofpmf y el filtrado por privilegio.
