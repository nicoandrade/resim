# JPEG Máximo: refinamiento y medición — 23 de octubre de 2026

La búsqueda adaptativa implementada conserva el piso de **16 dB en cada canal
RGB** y el máximo de **10 intentos con pérdida**. En los 34 archivos medidos,
reduce los bytes de salida un **5,66 %** y la suma de medianas del tiempo del
procesador un **4,82 %** frente al código anterior.

## Cambio

JPEG Máximo mantiene los siete candidatos compartidos con Web: 98, 95, 92, 88,
84, 80 y 76. Usa los tres intentos restantes para probar enteros intermedios
entre un nivel prometedor y un rechazo de calidad inferior. Si todavía no hay
un rechazo inferior, extiende la búsqueda con 70, 64 y 58. Puede terminar antes
de diez intentos cuando no quedan enteros en el intervalo elegido.

Una salida demasiado grande puede orientar la búsqueda, pero su calidad se
considera desconocida: jamás se acepta sin pasar los controles de tamaño y
SSIM. Cada candidato se codifica desde el original; se mantiene el mejor
resultado validado, incluyendo el camino sin pérdida. No se modifican
submuestreo, metadatos, dimensiones, formato, cancelación ni publicación.

El presupuesto fijo evita agregar los 41 intentos del experimento exhaustivo.
La métrica y el tamaño no son necesariamente monótonos al variar la calidad;
esta búsqueda no garantiza el mínimo global ni resultados mejores que la
lista anterior para cualquier imagen posible. En los 34 archivos medidos hubo
24 salidas menores, 10 iguales y ninguna mayor.

Sin pérdida, Conservador, Web y los otros formatos conservan sus políticas.
Los hashes de las 60 combinaciones de los 20 JPEG originales con esos tres
modos coincidieron exactamente entre ambas compilaciones.

## Medición pareada

Se compilaron dos ejecutables con el mismo `NativeImageProcessor`, el mismo
Swift, recursos y bibliotecas nativas. Sólo difiere `ResimCodecs.c`: la copia
anterior corresponde a `cbeb48c` y la otra contiene el cambio implementado.
Ambos usan Swift `-O`, C `-Os`, arm64 y deployment target macOS 14, equivalentes
a los niveles de optimización Release del proyecto. Mac Apple M2, 24 GiB,
macOS 27.0.1.

Se alternó el orden anterior/nuevo por archivo y repetición, con orden de
archivos mezclado de forma determinista. Hubo un calentamiento por ejecutable,
cinco repeticiones por archivo y variante, y **340 mediciones de JPEG Máximo**.
No hubo otros builds o benchmarks durante esa parte cronometrada.

El tiempo incluye la optimización y validación normales del procesador. Excluye
arranque del ejecutable, copia adicional del resultado del benchmark y sus
diagnósticos independientes. La tabla suma las medianas de los cinco tiempos
por archivo; no mide un lote de la interfaz ni su publicación atómica final.

| Grupo | Archivos | Bytes anteriores → nuevos | Menos bytes de salida | Tiempo anterior → nuevo | Variación de tiempo |
| --- | ---: | ---: | ---: | ---: | ---: |
| Corpus de la comparación inicial | 20 | 1.520.150 → 1.430.331 | **5,91 %** | 17,537 → 15,907 s | **−9,29 %** |
| Escenas adicionales | 12 | 1.256.065 → 1.158.009 | **7,81 %** | 12,916 → 11,833 s | **−8,38 %** |
| Muestras ampliadas a 3,54 MP | 2 | 712.249 → 702.720 | **1,34 %** | 18,705 → 19,051 s | **+1,85 %** |
| Total | 34 | 3.488.464 → 3.291.060 | **5,66 %** | 49,158 → 46,791 s | **−4,82 %** |

En las cinco pasadas completas, las sumas de tiempo de todos los archivos
mejoraron entre 4,09 % y 8,63 %. La mayor subida de mediana en un archivo fue
5,53 % en un JPEG pequeño: aproximadamente 180 → 190 ms. En las dos muestras
grandes hubo un pequeño aumento de tiempo; no se afirma que todos los archivos
compriman más rápido.

Los 20 archivos iniciales son los JPEG del [informe ImageOptim](IMAGEOPTIM-COMPARISON.md).
Los 12 adicionales proceden de seis escenas Kodak que no se usaron para elegir
el algoritmo: 02, 04, 06, 09, 13 y 20, codificadas con Pillow 12.3.0 a calidad
85/95 y 4:2:0. Las dos muestras grandes son versiones ampliadas mediante Lanczos
de las escenas 06 y 13 a 2304×1536, JPEG 95/4:2:0; sirven para ejercer más píxeles,
no equivalen a fotografías nativas de alta resolución. Se conservaron las fuentes
y sus hashes, sin usar imágenes personales ni subir archivos.

En el corpus inicial, la reducción frente a los originales pasa de **26,97 % a
31,28 %**. La búsqueda exhaustiva anterior alcanzaba 32,07 %, con mucho más
trabajo. La implementación recupera aproximadamente el 84,5 % de esos bytes
adicionales potenciales manteniendo el presupuesto anterior de intentos.

## Calidad y verificación

- Las 340 operaciones cumplieron el piso por canal. El mínimo observado en la
  nueva variante fue **16,0125 dB**. Mantener el umbral no significa conservar
  exactamente la calidad de cada salida anterior: aprovecha margen que antes
  quedaba por encima de ese piso.
- Se comprobaron formato, dimensiones, ICC, orientación, tamaño no mayor que
  el original, determinismo de las cinco salidas y hashes intactos de las fuentes.
  `NativeImageProcessor` ejecuta además sus validaciones de producción antes
  de devolver cada candidato.
- Suite XCTest en Release: **114 casos, 111 aprobados, 3 optativos omitidos,
  0 fallos**. Incluye la nueva regresión de nivel intermedio y cancelación tardía,
  además de preservación, guardado, perfiles, colas y formatos existentes.
- La primera ejecución encontró un manifiesto antiguo de QA de siete formatos
  cuyo directorio ya no existía. Se archivó el manifiesto huérfano en
  `.build/jpeg-maximum-refinement/stale-release-qa-corpus.json`, sin modificar
  esa prueba ni sus criterios. La ejecución final omitió esa prueba optativa
  como está previsto cuando no existe el corpus. Las otras dos omisiones son
  el benchmark integrado y el QA intensivo de 140 archivos, ambos optativos.
- AddressSanitizer y UndefinedBehaviorSanitizer: se verificaron **1.024 patrones
  de resultados**, incluyendo no monotonía, sin niveles repetidos ni fuera de
  rango, conservando los siete candidatos Web y el presupuesto de hasta diez.

Son resultados locales en un solo Mac. No se midieron lotes concurrentes, Intel,
fotografías nativas de 12–48 MP ni memoria de la interfaz. No se publicó una nueva
versión ni se hicieron commits o pushes como parte de esta implementación.

## Evidencia y reproducción

Artefactos locales en `.build/jpeg-maximum-refinement/`:

- `paired/results.json`: filas, agregados y controles de otros perfiles.
- `paired/measurements.json`: las 340 mediciones y sus comprobaciones.
- `paired/provenance.json`: hashes de fuentes y del C anterior/nuevo.
- `paired/baseline/outputs/` y `paired/candidate/outputs/`: salidas reales.
- `ResimCodecs-before.c`: referencia anterior congelada.
- `prepare.py`: receta local de los archivos adicionales.
- `tests.log` y `tests-final.log`: ejecución inicial y ejecución final de XCTest.

El visor `.build/imageoptim-comparison/index.html` añade **JPEG · Máximo mejorado**
con los 20 resultados originales, sus previews y tiempos del benchmark pareado.
Conserva los resultados iniciales y la búsqueda exhaustiva como referencias.

Para repetir en un directorio nuevo, con los codecs locales compilados:

```sh
python3 scripts/benchmark-jpeg-maximum.py \
  --inputs .build/jpeg-maximum-refinement/inputs \
  --baseline-source .build/jpeg-maximum-refinement/ResimCodecs-before.c \
  --output .build/jpeg-maximum-repeat --repetitions 5
```

El script compila ambas variantes y ejecuta la comparación de forma secuencial.
Las etapas `--stage build` / `--stage run` verifican que las fuentes y ejecutables
coincidan antes de medir. No ejecutar otros builds o benchmarks en paralelo.
