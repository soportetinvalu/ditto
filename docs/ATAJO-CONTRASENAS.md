# Abrir NexClip desde un campo de contraseña

Si el atajo no abre el historial, puedes intentar el icono de NexClip o clic derecho → **Abrir historial**. **No es una alternativa garantizada:** hay un fallo comunicado que afecta también a esas entradas con foco externo en contraseña y se recupera al enfocar correo. No hace falta desactivar ninguna protección ni restablecer Accesibilidad para investigar la apertura. Si estás concediendo un permiso de macOS, termina primero ese aviso.

Cuando macOS informa que está protegiendo el teclado, NexClip muestra un aviso al abrir el panel. El aviso se conserva mientras buscas o se actualiza el historial, y se revisa en cada apertura. No significa que NexClip haya leído tu contraseña ni que todos los atajos estén bloqueados. El panel puede mostrarse en el escritorio actual y junto a apps a pantalla completa.

Para probar, usa un texto inventado, nunca una contraseña real. Abre un campo de contraseña, pulsa tu atajo y comprueba si aparece el historial. Repite con el icono. Elige el texto de prueba y pulsa Intro. Si no se pega, vuelve al campo y pulsa Comando + V. Algunas apps prohíben pegar: abrir NexClip y aceptar un pegado son cosas distintas. No cambies los permisos de Accesibilidad si el pegado ya funcionaba.

## Qué se sabe y qué falta confirmar

- Apple [TN2150](https://developer.apple.com/library/archive/technotes/tn2150/_index.html) describe el bloqueo de interceptores del teclado: capturas HID, event taps y `GetKeys`. No afirma que `RegisterEventHotKey` quede bloqueado.
- [BetterCmdTab, incidencia 7](https://github.com/rokartur/BetterCmdTab/issues/7) documenta que cambiar de event tap a `RegisterEventHotKey` permitió abrir su panel con Secure Input activo. Es evidencia de otra app, no una prueba en el Mac del usuario.
- [Ghostty, discusión 14232](https://github.com/ghostty-org/ghostty/discussions/14232) distingue igualmente ambos mecanismos. Es un informe comunitario, no una garantía de Apple.
- [Alfred](https://www.alfredapp.com/help/troubleshooting/snippets/) documenta problemas de expansión de texto con la entrada segura. No demuestra que todos los atajos Carbon fallen.
- NexClip **ya usa `RegisterEventHotKey`**; se conserva. No se incorporan monitores globales, lectura de contraseñas ni llamadas para desactivar la protección de otra app.
- Faltaba un aviso de protección y el panel no tenía configurada la aparición en todos los escritorios/pantalla completa. Se corrigen esos puntos. **No está demostrado que sean la causa del caso reportado.** No se promete que el aviso o esa configuración reparen la recepción del atajo en el Mac afectado.
- Las pruebas comprueban aviso, apertura sin bloquear por protección, configuración del panel y el recorrido Carbon con protección activada en el proceso de prueba. Un evento Carbon enviado por la prueba no sustituye pulsar físicamente las teclas desde una app ajena.
- El envío actual de Comando + V se conserva. La documentación citada trata la lectura/intercepción, no demuestra una prohibición universal de envío. Que un destino acepte el pegado debe comprobarse en ese destino; CI no prueba campos de contraseña de apps de terceros.

## Diagnóstico local de apertura (candidato, sin reparación acreditada)

El código candidato añade al menú **Copiar diagnóstico de apertura**. Tras un intento fallido, esa acción exporta las últimas 48 etapas del proceso a `~/Library/Logs/NexClip/diagnostico-apertura.txt` (archivo 0600, carpeta 0700) y sustituye el portapapeles usando la exclusión de copias propias ya existente. No llama a AX/TCC, no solicita permisos y no lee portapapeles, historial, títulos, URL, identidad de la app externa ni campos. No se envía nada por red. Antes de exportar, solo existe un buffer acotado en memoria; salir de NexClip lo elimina. El archivo exportado permanece hasta borrarlo o reemplazarlo con otra exportación.

Cada etapa lleva intento/origen, milisegundos relativos y banderas de activación/visibilidad/key/main/oclusión/espacio/pantalla/modal/espera de permiso. `visible=true` no prueba que el usuario vea el panel. Las muestras del siguiente turno y a 300 ms solo observan: nunca reactivan ni muestran ventanas. Si faltan etapas, conservar el informe tal cual; no inferir automáticamente bloqueo del hilo ni fallo de entrega.

Los nuevos XCTest incluyen buffer/privacidad, no reapertura tras ocultar y separación de intentos. La prueba `HistoryOpeningTests.testRealExternalFocusOpeningPersistenceAndDeactivation` es **opt-in** con `NEXCLIP_RUN_FOCUS_TESTS=1`, en un Mac interactivo desbloqueado. Compila y abre un proceso AppKit de prueba con campos vacíos text/secure, comprueba cambio real de app frontal, persistencia key/visible durante 600 ms y ocultación al volver al proceso externo. No inyecta notificaciones/eventos, no prueba el teclado físico ni el menú real ni reproduce el navegador del incidente. Sin opt-in se registra como omitida, no como éxito funcional.

**Pendiente:** compilación y ejecución AppKit; causa del fallo concreto. No repetir la entrevista ya resuelta ni presentar esta instrumentación como reparación.
