# Resim vs. ImageOptim — 23 de octubre de 2026

Resim resulta competitivo en compresión sin pérdida. La diferencia grande en
tamaño aparece al activar pérdida en ImageOptim, que permite mucha más alteración
de píxeles que nuestros perfiles actuales. La mejora más interesante para Resim
es refinar la búsqueda de calidad de **JPEG Máximo**, manteniendo su piso actual.

Este informe registra la comparación inicial, anterior al refinamiento de JPEG
Máximo. Durante esa comparación no se modificaron los ajustes ni el código de compresión de la aplicación.
Tampoco se publicaron versiones, commits o cambios en las preferencias de compresión del
ImageOptim del usuario. Las incorporaciones al repositorio son herramientas de
comparación y este informe. La implementación y su medición posterior se documentan
en [JPEG-MAXIMUM-REFINEMENT.md](JPEG-MAXIMUM-REFINEMENT.md).

## Muestra y método

- Resim: código de `cbeb48c6270cbf4c1b9531189cefd009049343f3` (0.2.1),
  `NativeImageProcessor` real compilado con `swiftc -O` y los codecs locales.
- ImageOptim: la aplicación 1.9.3 entregada por el usuario. SHA-256 del ejecutable
  original: `2a5b924393cea1235ce82f3b4d4e9fab0d256309494f2293a75a3658200a0044`.
  Se copiaron sus bundles para aislar las preferencias. Cambiaron el identificador,
  los defaults de cada variante y las firmas locales; se verificó que las
  instrucciones del ejecutable activo permanecieran idénticas.
- Mac Apple M2, arm64, 24 GiB de RAM; macOS 27.0.1.
- 37 archivos: 20 JPEG, 12 PNG, 3 GIF y 2 SVG. Incluyen seis escenas fotográficas
  Kodak, cada una en PNG y JPEG 95/85, siete JPEG de regresión, cinco PNG de
  regresión, dos gráficos de texto/degradados, tres GIF sintéticos y dos SVG.
  Son seis escenas fotográficas independientes, no 37 fotos independientes.
- Se ejecutaron siete configuraciones, tres veces por archivo: 259 combinaciones
  y 777 operaciones principales. Todas parten de los mismos bytes originales.
  Se comprobaron sus hashes y se conservaron los archivos de entrada.
- La ejecución de ImageOptim usa su interfaz síncrona oficial, sin servicios de
  compresión online. Sólo se descargó el corpus público de prueba.

La procedencia de las fotos está en el [corpus Kodak](https://r0k.us/graphics/kodak/)
y en `ResimTests/Fixtures/IJG-README.txt`. Los metadatos de prueba son ficticios.
Los JPEG Kodak se generaron con Pillow, calidad 95/85, submuestreo 4:2:0,
sin optimización previa. El gráfico JPEG de texto usa calidad 95 y 4:4:4.

### Configuraciones

| Variante | Política |
| --- | --- |
| Resim Sin pérdida | Configuración publicada; conserva metadatos |
| Resim Conservador / Web / Máximo | Perfiles publicados; conserva metadatos |
| ImageOptim predeterminado | `LossyEnabled=false`; eliminación de metadatos por defecto |
| ImageOptim sin eliminación opcional | Además, `JpegTranStripAll=false` y `PngOutRemoveChunks=false`; estos controles sólo aplican a PNG/JPEG |
| ImageOptim con pérdida 80 | `LossyEnabled=true`; JPEG 80, PNG 80–100, GIF 80; demás defaults de su bundle |

Se desactivaron las comprobaciones de actualizaciones en las copias de prueba.
Las preferencias de concurrencia/nivel de esfuerzo de ImageOptim se mantuvieron.

## Reducción acumulada de bytes

Cada porcentaje es `1 − suma(resultados) / suma(originales)` dentro del formato.
No es el promedio de porcentajes individuales. Los modos que permiten pérdida
no representan la misma calidad de salida.

| Formato | Archivos | Resim Sin pérdida | Resim Conservador | Resim Web | Resim Máximo | ImageOptim predeterminado | ImageOptim sin eliminación opcional | ImageOptim con pérdida 80 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| JPEG | 20 | 10,52 % | 10,52 % | 13,28 % | 26,97 % | 10,70 % | 10,52 % | 54,65 % |
| PNG | 12 | 14,06 % | 14,06 % | 14,06 % | 14,06 % | 14,81 % | 14,80 % | 69,96 % |
| GIF | 3 | 69,33 % | 69,33 % | 69,33 % | 69,33 % | 72,46 % | 72,46 % | 72,46 % |
| SVG | 2 | 11,28 % | 11,28 % | 11,28 % | 11,28 % | 50,38 % | 50,38 % | 50,38 % |

Conservando los metadatos opcionales, ImageOptim y Resim quedan separados por
apenas **24 bytes en los 20 JPEG sin pérdida**: 1.862.448 frente a 1.862.472.
En los 12 PNG, ImageOptim ahorra aproximadamente 34 KiB adicionales sobre
4,37 MiB de entradas. En esta muestra no hay una brecha importante de motor
JPEG sin pérdida.

## Calidad y diferencias de preservación

Los JPEG se decodificaron con el mismo MozJPEG usado por Resim y se midieron
con el SSIM de libwebp en cada canal RGB. La métrica en dB no es PSNR ni un
porcentaje de calidad visual conservada.

- Resim Web recomprimió 9/20 JPEG; todos cumplen su piso de 20 dB por canal.
  Resim Máximo recomprimió 16/20; todos cumplen su piso de 16 dB. Conservador
  no aceptó ninguna recomprensión con pérdida en estos archivos.
- ImageOptim 80 recomprimió 19/20 JPEG. Los 19 quedaron por debajo de 20 dB;
  16 también quedaron por debajo de 16 dB. Su ventaja de tamaño requiere
  aceptar una política de pérdida diferente. Esto no demuestra por sí solo
  que sus resultados sean visualmente inaceptables.
- La inspección visual de recortes de fotos y texto al 200 % permite apreciar
  diferencias en textura y bordes; en algunas fotos son sutiles. No se realizó
  una evaluación visual ciega con usuarios ni una calibración perceptual amplia.
- Todos los JPEG de los modos sin pérdida conservan sus coeficientes DCT.
- ImageOptim predeterminado elimina ICC en `icc-444.jpg` y EXIF/orientación en
  `orientation-gps.jpg`. La variante sin eliminación opcional los conserva.
  No corresponde atribuir esos bytes eliminados al rendimiento del compresor.
- ImageOptim sin pérdida modifica RGB bajo alfa cero en `rgba.png`: cambian
  3.072 píxeles invisibles; los píxeles visibles y el alfa permanecen idénticos.
  Su SSIM RGB bruto es bajo por esa diferencia invisible. Resim conserva
  también esos RGB ocultos. No debe interpretarse como deterioro visual de PNG.
- ImageOptim con pérdida reduce el PNG RGB16 de prueba; no conserva todas sus
  muestras de 16 bits. Esa variante cambia píxeles visibles en 11/12 PNG.
- En el GIF animado, ImageOptim fusiona el último cuadro redundante: seis
  cuadros pasan a cinco y los últimos 200/70 ms se unen en 270 ms. `gifdiff
  --ignore-redundancy` confirma equivalencia visual. También elimina comentarios.
  Resim mantiene los seis cuadros, cada duración y sus metadatos.
- El ahorro SVG se midió en bytes. El visor permite inspección visual, pero no
  se verificó de forma independiente equivalencia de geometría, accesibilidad,
  referencias o semántica. Dos fixtures no justifican activar un preset completo.

Resim no produjo errores ni cambios de dimensiones, alfa, ICC, orientación o
temporización en los controles aplicados. Las variantes experimentales JPEG
también se inspeccionan con los mismos diagnósticos del informe; aún no son
perfiles publicados ni una validación completa de un cambio de producto.

## Experimentos de configuración

### PNG: esfuerzo adicional con el mismo ejecutable

Tres repeticiones por archivo, un hilo, sin cambios opcionales de metadatos.
Los tiempos siguientes corresponden sólo al proceso Oxipng; permiten comparar
estos presets entre sí.

| Opción | Bytes resultantes totales | Menos bytes que preset 2 | Suma de medianas | Preservación comprobada |
| --- | ---: | ---: | ---: | --- |
| Preset 2, `--nx` actual | 3.940.401 | — | 1,653 s | 12/12 |
| Preset 4, `--nx` | 3.916.440 | 0,61 % | 5,230 s | 12/12 |
| Preset 6, `--nx` | 3.909.053 | 0,80 % | 12,076 s | 12/12 |
| Preset 4, transformaciones habilitadas | 3.916.181 | 0,61 % | 5,313 s | Sólo 10/12 conservan la representación/metadata exigida |

Se compararon muestras RGBA, muestras RGB16 nativas y chunks/perfiles PNG.
Quitar `--nx` cambia la representación de `fine-lines.png` y `palette.png`, aunque
sus RGBA decodificados coincidan. La validación publicada de Resim exige también
representación y metadatos iguales. No basta con quitar esa opción.

**Recomendación:** conservar preset 2 en el uso predeterminado. Preset 4 necesita
3,16 veces el tiempo del codificador por apenas 23.961 bytes adicionales en todo
el corpus PNG. Preset 6 necesita 7,31 veces el tiempo por 31.348 bytes. Podría
evaluarse mayor esfuerzo como opción explícita, con una muestra de mayor resolución.
La cuantización PNG de ImageOptim es una funcionalidad con pérdida diferente;
no conviene activarla silenciosamente en nuestros perfiles actualmente sin pérdida.

### JPEG: candidatos intermedios sin modificar los pisos

Se probaron **41 calidades, de 98 a 58**, desde cada JPEG original permitido por
la admisión de producción, reutilizando exactamente `jpeg_encode` y su medición
SSIM. Se retuvo el candidato más pequeño que cumple cada piso. Las entradas
con metadatos excluidos de recomprensión conservan su camino sin pérdida.

| Política | Bytes publicados actuales | Mejor resultado de la búsqueda exhaustiva | Diferencia frente a la salida actual |
| --- | ---: | ---: | ---: |
| Web, piso 20 dB | 1.804.973 | 1.791.446 | 0,75 % menos |
| Máximo, piso 16 dB | 1.520.150 | 1.413.880 | **6,99 % menos** |

La búsqueda refinada eleva el ahorro JPEG Máximo respecto de los originales de
26,97 % a **32,07 %**, sin modificar su umbral mínimo. No significa que las salidas
tengan calidad idéntica a las actuales: aprovecha margen entre la calidad actual
y el piso permitido. Por ejemplo, `kodim15-q95.jpg` pasa de 113.346 a 96.893 bytes,
con un mínimo RGB de 19,43 a 16,28 dB; ambos cumplen el piso de 16 dB.

Niveles intermedios como 93, 96, 97, 83, 81 y 72 encontraron candidatos que la
lista fija actual no prueba. No todos aportan en la misma imagen.

**Recomendación prioritaria:** diseñar una búsqueda de JPEG Máximo que refine
intervalos útiles, con un presupuesto explícito de intentos, cancelación y las
validaciones actuales. Validar ese algoritmo sobre un corpus independiente antes
de publicarlo. El 6,99 % es una oportunidad observada con búsqueda exhaustiva;
no es una promesa de ahorro de un algoritmo limitado ni de producción. No se
propone ejecutar 41 intentos por imagen en la aplicación.

En Web, el beneficio de buscar muchos más niveles fue sólo 0,75 %: no justifica
por sí solo encarecer el procesamiento predeterminado. Tampoco hay evidencia
suficiente para reducir globalmente sus pisos. La política compartida también
afectaría WebP, AVIF y HEIC, formatos que ImageOptim 1.9.3 no compara aquí.

Como referencia de calibración, permitiendo pisos JPEG de 14 o 12 dB la misma
búsqueda consigue 42,85 % o 54,82 % de ahorro total. Eso cambia la tolerancia a
pérdida y requiere aprobación visual específica; no es una mejora gratuita del
motor ni una propuesta para trasladar esos pisos a todos los formatos.

### GIF y SVG

Gifsicle 1.98 con nivel 3, conservando cuadros vacíos y metadatos como en Resim,
produjo **exactamente los mismos tamaños** que nivel 2 en los tres GIF. No se
justifica cambiar ese nivel con esta evidencia. Buena parte de la ventaja de
ImageOptim responde a otra política de metadatos/cuadros.

La diferencia SVG amerita una evaluación independiente si ese formato es una
prioridad del producto. Nuestra política actual limita las transformaciones
intencionalmente; no es un problema de ajustar la calidad JPEG/PNG.

## Tiempo y límites de interpretación

Los registros conservan las tres mediciones y su mediana. El tiempo principal
de Resim mide su procesador y validación en un ejecutable optimizado, sin lanzar
la interfaz ni publicar atómicamente sobre el original. ImageOptim se ejecutó
como un proceso nuevo por imagen e incluye arranque y guardado, con su prioridad
y concurrencia predeterminadas. **No son tiempos equivalentes para afirmar una
relación de velocidad entre las aplicaciones.** La comparación aislada de
presets PNG sí utiliza el mismo proceso de medición y ejecutable.

La muestra contiene fotos de 768×512 y un gráfico de 1440×900; no cubre fotos
de móviles de 12–48 MP, HDR, perfiles P3, grandes animaciones ni cargas paralelas.
No se extrapolan tiempos, memoria o calidad a esas condiciones. WebP, AVIF y
HEIC quedan fuera de la comparación con esta versión de ImageOptim.

Un GIF de ImageOptim tuvo bytes diferentes entre repeticiones pero idéntico
tamaño; los diagnósticos de imagen se hicieron sobre la salida conservada.
No se detectó variación de tamaños en las tres repeticiones principales.

## Evidencia local y reproducción

El visor local está en `.build/imageoptim-comparison/index.html`, con originales,
resultados, previews, inspección al 100 %, métricas por archivo y las dos variantes
JPEG refinadas. Los datos detallados están junto al visor:

- `results.json`: resultados y diagnósticos, versión, plataforma y hashes.
- `resim-results.json` / `imageoptim-results.json`: mediciones principales.
- `imageoptim-configs.json`: defaults usados en las copias de prueba.
- `inputs-sha256.json`: identidad del corpus.
- `effort-results.json`: experimento PNG/GIF.
- `jpeg-search-results.json`: cada nivel probado y sus pisos de aceptación.
- `visual-crops.png`: recortes del original, Web, Máximo e ImageOptim 80 al 200 %.

Las imágenes y los bundles de terceros permanecen fuera de Git. Para repetir
desde la raíz, usar un Python con Pillow y numpy, y los codecs ya compilados:

```sh
python3 scripts/prepare-comparison-corpus.py --output .build/io-new/inputs
python3 scripts/compare-imageoptim.py \
  --imageoptim /ruta/ImageOptim.app \
  --inputs .build/io-new/inputs --output .build/io-new --repetitions 3
python3 scripts/compare-lossless-effort.py --comparison .build/io-new
python3 scripts/compare-jpeg-search.py --comparison .build/io-new
python3 scripts/compare-imageoptim.py \
  --imageoptim /ruta/ImageOptim.app \
  --inputs .build/io-new/inputs --output .build/io-new --stage analyze
```

La [documentación oficial de la interfaz síncrona de ImageOptim](https://imageoptim.com/command-line.html)
describe el método utilizado. Las etapas deben ejecutarse secuencialmente para
evitar que sus cargas alteren las mediciones.
