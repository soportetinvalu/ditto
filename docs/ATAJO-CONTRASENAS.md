# Abrir NexClip desde un campo de contraseña

Si el atajo no abre el historial, pulsa el icono de NexClip en la barra de menús. No hace falta salir del campo ni desactivar ninguna protección. El clic derecho también ofrece **Abrir historial**. Si estás concediendo un permiso de macOS, termina primero ese aviso.

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

Si sigue fallando, indica la versión de macOS, el nombre de la app donde ocurre, la combinación elegida, si funciona fuera del campo y si el icono abre el panel. No envíes contraseñas ni capturas con información privada.
