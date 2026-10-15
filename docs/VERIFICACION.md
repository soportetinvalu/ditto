# Verificación real y límites de la entrega

## Veredicto

**Implementación fuente real disponible; aplicación macOS y paridad completa NO verificadas.** El núcleo de producción C/SQLite pasa las pruebas ejecutadas en Linux. Swift/AppKit, hotkey, foco, permisos TCC y pegado entre aplicaciones permanecen bloqueados por falta de host/SDK/compiler macOS. No se creó una `.app` ficticia.

La matriz se contó por script: **20 filas exactas; 11 implementadas en código, 8 pendientes parciales, 1 no aplicable al alcance local**. El estado de código no reemplaza aceptación de ejecución. La revisión de esta entrega no es una auditoría independiente.

## Entorno observado

`environment-probe.json` registra lectura real acotada del ejecutor:

- Host `Linux`, arquitectura `x86_64`.
- `swift`: no encontrado; `clang`: no encontrado.
- Compilador C existente: `/usr/bin/cc`.
- Biblioteca SQLite real usada por los tests C: **3.45.1**, reportada por `sqlite3_libversion()` dentro del binario de prueba.
- Falta `sqlite3.h` de desarrollo en este host. No se instaló ningún paquete.

El Mac M4/macOS Tahoe 26.5.2 es el destino documentado en el cuaderno, **no el entorno de ejecución de esta prueba**. No hay acceso al Mac comprobado por esta implementación.

## Comandos realmente ejecutados

Rutas de logs relativas a `app-macos/.verification/`.

| Etapa | Resultado real | Código | Evidencia |
|---|---|---:|---|
| Compilar C con headers de sistema | BLOQUEADO: `fatal error: sqlite3.h: No such file or directory` | 1 | `core-build-sdk.log`; primer fallo preservado en `core-build.log` |
| Compilar el mismo `Sources/ClipCore/core.c` con declaraciones ABI auxiliares de tests y enlazar `libsqlite3.so.0` real | PASS, `-std=c11 -Wall -Wextra -Werror -pedantic -O2` | 0 | `core-build-runtime-abi.log` |
| Ejecutar núcleo C/SQLite de producción | **PASS 134 assertions**, fixtures sintéticos, SQLite 3.45.1 | 0 | `core-tests.log` |
| Compilar con `-fsanitize=address,undefined -fno-omit-frame-pointer` | PASS | 0 | `sanitizer-build.log` |
| Ejecutar el mismo núcleo con AddressSanitizer y UBSan | **PASS 134 assertions**, sin diagnóstico de sanitizadores | 0 | `sanitizer-tests.log` |
| Contraprueba: quitar exclusión `protected=0` solo en copia temporal | Falla la prueba de protección, como debe | 1 esperado | `retention-guard-sensitivity.log` |
| Contraprueba: deshabilitar guarda de pausa solo en copia temporal | Falla la prueba de pausa, como debe | 1 esperado | `pause-guard-sensitivity.log` |
| `python3 scripts/test_portable.py` completo | PASS del camino alternativo real; fallo inicial de header queda clasificado como bloqueo no fatal, no como compilación exitosa | 0 | `portable-results.json` con hashes de fuente C y test |
| `python3 scripts/check_source.py` | PASS de 10 comprobaciones estáticas (matriz, Python, Bash, plist, GPL, límites textuales de fuentes) | 0 | `source-checks.json` |
| `python3 scripts/macos_executor.py --output .verification/macos-preflight-final` | **BLOQUEADO**, `macOS SDK/AppKit required; no .app was produced.` | **77** | `macos-preflight-final/result.json`, `macos-executor.log` |

**Las contrapruebas no son errores de la versión entregada.** Cada una modifica una copia de `core.c` dentro de un temporal propio, compila esa copia y debe salir 1; luego se elimina el temporal. La fuente de producción no fue mutada. Los tests normales y sanitizados probaron la misma fuente cuyos hashes registra `portable-results.json`.

`Tests/Support/sqlite3.h` contiene declaraciones del ABI mínimo, no motor, fixtures de respuesta ni stubs. Los tests ejecutan código real contra la biblioteca SQLite instalada. El build macOS utiliza el header de su SDK; la compatibilidad de tipos/módulo Swift en ese SDK todavía requiere compilación.

## Conductas que sí cubre el test C

- Creación/versionado de esquema y claves foráneas.
- Persistencia después de cerrar/reabrir una base temporal.
- BLOB binario con bytes nulos, Unicode y múltiples representaciones/ítems.
- Deduplicación y actualización de contador, incluyendo rollback del savepoint dentro de una transacción externa.
- Error de representación duplicada revierte el clip completo; límites/tamaño e ID mal formado rechazados.
- Consulta literal con `%`, `_` y comillas frente a un caso negativo parecido a SQL.
- Jerarquía/consulta recursiva, grupo con hijos no borrable, eliminación de grupo sin pérdida de clips.
- Cantidad/edad/tamaño de retención y exclusión de favoritos/protegidos/fijados.
- Papelera no elimina formatos; restauración sintética conserva BLOB.
- Slots de buffer válidos y cascada al borrar explícitamente la copia referida.
- Backup real consistente; segundo backup al mismo nombre rechazado sin sobrescritura.
- Archivo no SQLite, metadatos con tipo corrupto y versión futura rechazados.
- Pausa, allow/deny exacto, prioridad de exclusión y tipos transitorios.

Estas pruebas **no** ejecutan SHA-256 Swift, consultas construidas por Swift, `NSPasteboard`, AppKit, Carbon, TCC ni `CGEvent`. Las comprobaciones estáticas de presencia/ausencia de APIs no acreditan comportamiento de privacidad o seguridad en ejecución.

## Pruebas macOS preparadas, NO ejecutadas

`Tests/MemoriaLocalTests/MemoriaLocalTests.swift` contiene **11 métodos XCTest** del código real: flujo sintético de store, hash y límites de ítems, búsqueda/regex, grupos/protección/papelera, JSON roundtrip/validaciones, backup/fusión, captura multiformato/pausa/exclusiones/autocopia en pasteboard nombrado, extracción HTML/transformaciones, fallback de copia sin AX/eventos, panel con filtros sobre store real y entradas inválidas. No hay test que use el pasteboard general de la persona usuaria.

El ejecutor macOS ejecutará automáticamente esos tests y `--self-check` antes de empaquetar. Si el compilador devuelve errores, conservará el log y detendrá el proceso; **no se presupone que el código Swift compile por tener archivos**. `docs/ACEPTACION-MACOS.md` define después la comprobación observable en aplicaciones destino y los casos TCC/visuales que no cubre XCTest.

Como comprobación puntual de API, se leyeron declaraciones oficiales Apple, no nuevas evidencias REA:

- `SMAppService.unregister`: `func unregister() throws` — <https://developer.apple.com/tutorials/data/documentation/servicemanagement/smappservice/unregister().json>
- `SMAppService.register`: `func register() throws` — <https://developer.apple.com/tutorials/data/documentation/servicemanagement/smappservice/register().json>
- `NSPasteboard.PasteboardType.rtfd`: `static let rtfd: NSPasteboard.PasteboardType` — <https://developer.apple.com/tutorials/data/documentation/appkit/nspasteboard/pasteboardtype/rtfd.json>

Consultar esas firmas no sustituye compilar ni probar el SDK objetivo.

## Brechas y barreras para distribución

1. **Bloqueante para afirmar app funcional:** no host macOS/SDK/Swift en este ejecutor; no `.app` compilada ni pegado observado. Entrada automatizada lista para ejecutor autorizado, sin pedir terminal a la persona usuaria y sin instalar toolchains.
2. **Paridad pendiente:** F06 regex/búsqueda Unicode completas; F09 hotkeys individuales; F10 secuencia de pegados; F11 preview visual HTML/RTF; F12 editor enriquecido; F14 importar TXT/imágenes; F15 restore de snapshot exacto; F19 temas/idiomas completos. El detalle y adaptaciones están en la matriz.
3. **Aceptación macOS pendiente:** teclado real, hotkey ocupada, TCC/Secure Input, retorno de foco, estilos/formatos destino, login item, VoiceOver/contraste/Retina y rendimiento con historial grande. Enviar `⌘V` no acredita que una app lo haya aceptado.
4. **Límites deliberados:** sondeo no lossless, 32 MiB/256 representaciones por copia, importación/fusión hasta 128 MiB, regex restringida y preview acotada. Sin cifrado de aplicación, sincronización ni importación Windows. Retención mueve a papelera y no impone un límite duro al disco.
5. **Distribución pendiente:** revisión independiente de código/seguridad/licencias, responsable/editor y bundle ID definitivos. El script hace firma ad hoc local, no Developer ID ni notarización; no se publicó nada.

## Entrega concreta

Proyecto fuente `app-macos/`, paquete SwiftPM, C/SQLite/AppKit, licencia/avisos, scripts de tests y empaquetado, matriz y criterios de aceptación. `scripts/source_archive.py` genera y valida un ZIP de fuente correspondiente con hashes; excluye `.env`, binarios, bases de datos, resultados temporales y symlinks. No hay dependencias SwiftPM remotas. La fase que sigue es **compilación y auditoría en un Mac autorizado**, no publicación ni declaración de paridad completa.
