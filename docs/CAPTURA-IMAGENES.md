# Captura de imágenes y apertura inmediata

Base: última entrega aceptada `49593ce02246f0e67efcd7048793836d28259454`.
No modifica el esquema, datos existentes, TCC, atajos, pegado ni firma.

## Defectos comprobables en la base

- `HistoryController.open` consultaba SQLite sin sondear la copia pendiente. Al
  abrir entre dos ticks (350 ms por defecto), elegía la copia anterior. El
  callback posterior conservaba esa selección. Se reproduce sin un navegador
  con un PNG nuevo en un pasteboard nombrado y apertura `.shortcut` inmediata.
- La lista fija solo admitía PNG/TIFF/JPEG: GIF, WebP y HEIC se omitían con
  `customTypes=false`, o quedaba únicamente la URL/HTML acompañante.
- `lastCount` se consumía antes de leer los datos. Si un proveedor de imagen
  no entregaba bytes, el mismo contador no se volvía a intentar, y podía
  guardarse un fragmento URL/texto sin la imagen anunciada.

Estos defectos explican rutas que producen el síntoma reportado. Sin un volcado
consentido del pasteboard o reproducción en el Mac afectado, no demuestran cuál
se produjo en la copia concreta de ChatGPT ni qué tipos publicó ese navegador.
No se asegura que ChatGPT siempre publique WebP ni que su proveedor sea diferido.

## Corrección acotada

1. Antes de elegir la fila inicial, sondear una vez con todas las guardas de
   consentimiento, pausa, origen, exclusiones, autocopia y tipos sensibles.
2. Admitir UTIs conformes a `UTType.image`, preservando tipo/bytes originales,
   orden de ítems y representaciones; no convertir ni descargar URLs.
3. Si una imagen anunciada no entrega datos, omitir el fragmento e intentar
   hasta tres lecturas del mismo contador. Revalidar privacidad cada vez;
   abandonar al cambiar origen/contador o ante escritura propia. No hay bucle
   de espera, reintento de pegado ni sondeo extra permanente.
4. Si la apertura quedó esperando esa imagen y la persona no cambió selección
   ni filtros, seleccionar el resultado al llegar. No robar foco ni sobreescribir
   una selección posterior. Los demás refrescos mantienen su conducta anterior.

La lista de formatos privados sigue desactivada por defecto. Se mantienen los
límites de 32 MiB/256 representaciones y las protecciones de captura.

## Verificación

`Tests/NexClipTests/ImageCaptureTests.swift`: diez XCTest con NSPasteboard real
**nombrado**, SQLite real en memoria y AppKit; fixtures locales de imágenes,
proveedores diferidos reales, apertura por la entrada `.shortcut`, round-trip de
bytes y casos negativos. No es un clic derecho físico ni un atajo Carbon desde
ChatGPT. PNG/TIFF/JPEG/GIF/WebP/HEIC, URL+imagen, ausencia inicial de bytes,
selección posterior, privacidad, cambio de origen/contador y tamaño excesivo.

`scripts/test_image_capture_sensitivity.py` ejecuta los diez tests y seis
mutantes aislados. Exige aserción XCTest fallida (no acepta errores de compilador
como contraprueba). Se conservan logs y JSON en el artifact de Actions.

El workflow también conserva las suites anteriores, la prueba de presentación
real en bundles LaunchServices y el empaquetado con firma estable. La ejecución
y SHA exactos se consignan en el informe de entrega del workspace: la mera
existencia de estas pruebas no demuestra que se hayan ejecutado.

Límites: sondeo no es una cola; una copia sobrescrita entre sondeos no puede
reconstruirse. Una imagen jamás entregada por la app, solo una URL sin bytes,
una copia excluida/sensible o por encima del límite no se captura. Origen al
frente es aproximación, no identidad certificada del dueño del pasteboard.
Sin acceso al Mac de Christian: no se acredita su reproducción de clic derecho,
aceptación de la corrección, pegado receptor, ni persistencia TCC. La firma
`NexClip Developer` es autofirmada, no Developer ID ni notarización.

## Comprobación manual de aceptación (sin borrar datos)

Salir de NexClip; sustituir únicamente la app por la compilación corregida.
Con captura habilitada y sin pausa, copiar con clic derecho una imagen nueva
(no «Copiar dirección de imagen») en ChatGPT y otra app. Abrir el atajo
inmediatamente y tras un segundo: debe aparecer/seleccionarse la nueva imagen,
no la anterior. Vista previa debe corresponder; «Copiar sin pegar» y pegado
manual en un receptor compatible deben conservarla. No restablecer permisos,
no borrar historial ni preferencias. Esta comprobación no se atribuye a Christian
hasta que la realice y reporte su resultado.
