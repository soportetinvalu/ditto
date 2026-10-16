# Accesibilidad: solicitud visible y diagnóstico sin Terminal

## Uso mínimo

1. Sal de la versión anterior desde la barra de menús. Sustituye `NexClip.app` en Aplicaciones y abre esa copia con Finder.
2. Clic derecho en su icono → **Ajustes…** → **Restablecer permiso de Accesibilidad** → **Restablecer**. Revoca solo Accesibilidad de esta app para tu usuario; no borra el historial. No se ejecuta automáticamente al arrancar.
3. La app oculta sus ventanas antes de solicitar el aviso oficial. En ese aviso abre Ajustes del Sistema y activa NexClip en **Privacidad y seguridad → Accesibilidad**. Si el aviso no aparece, abre esa sección directamente en Ajustes del Sistema. Apple también admite añadir apps manualmente con **+**; no hay una prohibición de ese método.
4. Espera hasta 60 s. El menú/tooltip indica **Esperando permiso de macOS…**. Solicitar/restablecer están deshabilitados durante la espera; ni Enter ni el atajo reconstruyen el aviso. Al concederse se comunica **Permiso concedido**, sin activar ventanas ni enviar un pegado pendiente. Para probar: vuelve a un documento, abre el historial y selecciona de nuevo la copia.
5. Si no se concede, **Ajustes de NexClip → Copiar diagnóstico**, pega el texto y comunica si apareció el aviso oficial y si el interruptor estaba activo. No repitas indefinidamente el restablecimiento. Puedes seguir copiando y pegar con ⌘V.

No se pide Terminal, contraseña de administrador, Acceso total al disco ni desactivar SIP. Si el restablecimiento falla, la app registra salida y código, no eleva privilegios ni inventa un resultado satisfactorio. El siguiente paso depende de ese error real; no se puede afirmar de antemano que sea imprescindible usar sudo.

## Qué cambió en las ventanas

Antes: historial `HistoryPanel: NSPanel`, nivel `.floating`, apto para key/main, sin nivel `.statusBar`, sin `collectionBehavior` personalizado. `open()` activaba la app. El aviso propio usaba `NSAlert.runModal()` y un bucle lo reconstruía tras cada solicitud. La grabación muestra el aviso oficial detrás del historial; esa superposición no prueba por qué TCC devuelve false.

Ahora: un solo aviso inicial, sin bucle. Al responder se ordena fuera; antes de la llamada oficial se baja el historial a `.normal`, se ocultan historial y Ajustes y se llama `NSApp.hide`. `hidesOnDeactivate=true`. No hay modal de espera, activación automática ni reapertura del historial durante la espera. El estado vive en el coordinador (no en la pila del modal); la petición duplicada no reinicia el plazo. El sondeo usa tiempo monotónico, cada segundo hasta 60 s; al volver a primer plano se vuelve a comprobar incluso tras el timeout. El nivel flotante solo vuelve cuando el usuario abre el historial después de la espera. Copiar diagnóstico desde Ajustes tampoco presenta otro modal.

## Qué incluye el diagnóstico

**Ajustes → Copiar diagnóstico**, o el botón equivalente del aviso inicial, copia un informe local y guarda `~/Library/Logs/NexClip/diagnostico-accesibilidad.txt` (0600, directorio 0700). No incluye historial ni contenido anterior del portapapeles; sí rutas locales que pueden contener el usuario. Reemplaza el portapapeles, sin capturar ese informe en el historial. Sin red.

Incluye versión/commit, macOS, rutas/PID/bundle ID, AX efectivo, retorno de `AXIsProcessTrustedWithOptions(prompt:false)`, contador/fecha/retorno inmediato del último prompt=true, resultado de tccutil, validación Security dinámica/estática normal/estricta, DR **del binario actual**, cdhash, flags/Team ID/entitlements, quarantine, instancias y Rosetta. El DR actual **no se presenta como el requisito registrado por TCC**.

Solo al copiar diagnóstico o confirmar el restablecimiento intenta abrir las dos rutas TCC conocidas **READONLY**, sin crear bases ni elevar privilegios. Es una inspección opcional de esquema interno, NO una API soportada de autorización. Solo consulta `kTCCServiceAccessibility` y clientes correspondientes al bundle ID propio (`client_type=0`) o las rutas actuales del bundle/ejecutable (`client_type=1`); no enumera otras apps. Timeout SQLite 100 ms, máximo 16 filas por base. Si macOS permite leer: muestra `client`, `client_type`, `auth_value` bruto y decodifica `csreq` con Security; evalúa ese requisito frente al proceso actual con `SecCodeCheckValidity`. Antes de resetear conserva una instantánea de esa lectura en memoria para incluirla en el siguiente informe del mismo proceso.

**Lo habitual es que macOS impida leer las bases protegidas sin privilegios adicionales.** Un error de apertura/consulta se informa como **TCC no legible**, nunca como “no hay entrada”. Si el esquema cambia se declara no disponible, no se modifica. Cero filas solo describe esa base y esos clientes en ese instante, no el estado global. `auth_value=2` y una coincidencia de requisito tampoco sustituyen AX efectivo. `csreq` NULL o no decodificable es “no evaluable”, no “permitido”. No se usa TCC.framework privado.

## Hallazgos y límites

### Demostrado

- El diagnóstico aportado del Mac devuelve AX false con firma válida. El usuario informa interruptor activo y quitar/añadir sin éxito. Sin acceso al Mac no se ha leído su csreq ni demostrado una entrada obsoleta.
- [AXIsProcessTrustedWithOptions](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions) solo devuelve confianza efectiva. Apple dice: “Prompting occurs asynchronously and does not affect the return value.” Ni true ni false detallan ausencia de fila, denegación o fallo de identidad. Prompt=true no es un segundo estado de autorización.
- [TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements), sección Designated requirement: macOS guarda el DR de la app y comprueba versiones posteriores contra el requisito original; ad hoc liga el DR a esa versión. El identificador lo elige el firmante, no acredita quién firmó.
- [Apple: Resetting access to protected resources](https://developer.apple.com/documentation/xcode/resetting-access-to-protected-resources-in-macos) documenta `tccutil reset <service> <bundle-id>`, incluye Accessibility y especifica usuario actual sin sudo; sudo es para todos los usuarios. La app ejecuta exclusivamente `/usr/bin/tccutil reset Accessibility com.nexclip.app` mediante Process, sin shell, espera su terminación y solo si exit=0 invoca el prompt. Resetear no concede permiso.
- No existe en las APIs AX consultadas una consulta pública del csreq almacenado ni una enumeración de decisiones TCC. Leer SQLite opcionalmente no convierte su esquema interno en contrato público.

### Probable con fuente, no diagnóstico confirmado de este Mac

- Una autorización ligada al cdhash de otro build ad hoc es compatible con estos síntomas. El DR ad hoc predeterminado observado en ejemplos y emitido por codesign es `cdhash H"…"`, **no debe afirmarse universalmente** `identifier "com.nexclip.app" and cdhash H"…"`. El job muestra el DR real de este build sin modificarlo. El csreq real del Mac puede ser distinto o inaccesible, tanto si el alta fue manual como por prompt.
- [Quinn/DTS, hilo 730043](https://developer.apple.com/forums/thread/730043) recomienda identidad estable para reducir “TCC thrash”. La consulta directa devolvió Security Verification: solo se obtuvo su extracto indexado. No se presenta un certificado estable como reparación demostrada del problema del usuario.
- [Alacritty #7334](https://github.com/alacritty/alacritty/issues/7334), Ventura 13.6.1: revocar/reconceder y reinstalar no bastaron; el autor documentó reset global, reinicio y reconcesión como remedio. Hay confirmación posterior en 2024, no especifica macOS 15/26 ni demuestra un csreq obsoleto. No se recomienda su reset global.
- [Hammerspoon FAQ](https://www.hammerspoon.org/faq/) recomienda reset específico de su app para un fallo de envío de teclas tras Catalina. [Rectangle #1355](https://github.com/rxhanson/Rectangle/issues/1355) documenta reset y reinicio en Sonoma, no builds ad hoc en Tahoe.
- [Chat-on-steroids #258](https://github.com/totec448-spec/chat-on-steroids/issues/258), reporte de septiembre de 2026: aporta cdhash/DR ad hoc y afirma csreq del build anterior hasta reset. No especifica en el cuerpo leído la versión macOS ni demuestra el fallo del botón −.
- [Vivora](https://github.com/vivoradesk/vivora/blob/main/docs/macos-codesign.md) menciona bucles ad hoc en macOS 15+/26; es documentación de proyecto, no medición del csreq ni confirmación de que quitar/añadir conserve el antiguo requisito.

### No demostrado / hipótesis

No se logró verificar un reporte primario que reúna **macOS 15 o 26 + ad hoc + quitar con −/añadir + csreq antiguo medido persistente** para Hammerspoon, Karabiner, Rectangle, Emacs o Alacritty. Las búsquedas específicas devolvieron también problemas diferentes (atajos Option en Hammerspoon, Driver Extensions en Karabiner), que se excluyen. No se transforma la premisa de “reportes conocidos” en un hecho. El bug concreto de que Tahoe conserve/reutilice csreq tras − sigue siendo hipótesis; `tccutil reset` es un mecanismo documentado de recuperación, no prueba de esa causa.

## Por qué NO se usa un DR solo con identifier

`codesign -s - -r='designated => identifier "com.nexclip.app"'` es sintácticamente plausible, pero **no es una identidad segura**: cualquier firmante puede elegir ese identificador. Si TCC aceptara ese requisito sin endurecerlo, otro binario con el mismo identificador satisfaría el requisito. Si TCC lo endurece con cdhash, no solucionaría la persistencia. No se encontró garantía Apple de que TCC acepte ese DR explícito ad hoc para persistir permisos. La alternativa pedida era “viable y segura”: no se cumple seguridad, por eso **no se cambia el DR**, no se crea certificado ni se altera la configuración de Actions. Ver [TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements), párrafos sobre identidad/suplantación y el identifier elegido por el firmante.

## Esquema TCC (evidencia secundaria, no contrato Apple)

[HackTricks: macOS TCC](https://hacktricks.wiki/en/macos-hardening/macos-security-and-privilege-escalation/macos-security-protections/macos-tcc/index.html) describe `client` (bundle ID o ruta), `client_type` (0 ID, 1 ruta), `auth_value` (0 denegado, 1 desconocido, 2 permitido, 3 limitado) y `csreq` binario de requisito. También advierte de protección de lectura de ambas bases. Esos valores son esquema interno y pueden cambiar: se imprimen brutos, no se usan para autorizar el pegado. La evaluación del requisito se hace con APIs Security públicas, como describe TN3127. No se editan bases ni se usa ninguna técnica de evasión de esa página.

## Verificación

XCTest usa un reloj inyectado, pasteboards con nombre, bases SQLite sintéticas y requisitos sintéticos. No lee el TCC real ni solicita/restablece permisos del runner desde XCTest. El empaquetado en Actions registra solamente el bundle recién construido y prueba el reset dirigido sin sudo, en el usuario efímero de CI, sin lanzar la app. Su salida no prueba el resultado en el Mac del usuario. Codesign estricto se repite antes y después del transporte con ditto; el DR se imprime en el log.
