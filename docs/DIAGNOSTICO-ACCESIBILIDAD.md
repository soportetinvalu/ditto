# Diagnóstico de Accesibilidad sin Terminal

En **Ajustes → Copiar diagnóstico**, o en el aviso de Accesibilidad → **Copiar diagnóstico**, la app copia un informe de texto y guarda la misma información en:

`~/Library/Logs/MemoriaLocal/diagnostico-accesibilidad.txt`

El informe incluye versión/commit, macOS, rutas, PID, identificador, confianza AX, comprobaciones de firma dinámica y estática (normal/estricta), errores de Security, cdhash, flags, Team ID, entitlements, presencia de quarantine, número de instancias y Rosetta. No solicita permisos: `kAXTrustedCheckOptionPrompt` **no se usa**. No modifica quarantine, TCC ni las preferencias de seguridad.

**Privacidad:** no lee ni incluye el historial ni el contenido anterior del portapapeles. Sí incluye rutas locales que pueden contener el nombre de usuario. Al copiar sustituye el portapapeles actual (también la copia seleccionada que provocó el aviso). Esa escritura se marca como propia para no capturar el diagnóstico en el historial, incluso si se copia durante la pausa y se reanuda después. El archivo se sobrescribe, con permisos 0600 y directorio 0700. No se envía por red.

## Interpretación

- Un error de `SecCodeCheckValidity` o de `SecStaticCodeCheckValidity` identifica un problema de firma en la copia que se está ejecutando; compartir el código exacto, no suponer que todos los errores significan lo mismo.
- `SecCodeCopySigningInformation` describe la firma, pero su éxito no prueba su validez. Se consulta después de intentar validar y se conserva cualquier error.
- Firma válida y `AXIsProcessTrusted(): false` **no** demuestran que Accesibilidad esté concedida al proceso, aunque el interruptor esté activo. La firma ad hoc no da una identidad estable entre builds. Apple recomienda una identidad de firma estable para reducir problemas de TCC.
- El artifact `12046474023` se inspeccionó sin macOS: recursos SHA-1/SHA-256, `Info.plist`, requirements, CodeResources y páginas del ejecutable coinciden. Es arm64, tiene LC_UUID, identificador `local.memorialocal.app`, flags ad hoc `0x2`, sin entitlements ni linker-signed. El ZIP interior creado con `ditto` conserva permisos. **No se encontró una firma rota por el empaquetado.** Esto no valida la copia instalada ni permite atribuir su fallo a un bug de Tahoe.
- El empaquetado incorpora el commit antes de firmar y ahora comprueba la integridad del ZIP, lo extrae con `ditto`, comprueba el ejecutable y repite `codesign --verify --deep --strict`. No añade `--deep` al firmado: no hay código anidado y no es necesario para sellar recursos.

No repetir indefinidamente quitar/añadir el permiso si ya se hizo sin éxito. Compartir el texto de este botón permite distinguir firma instalada inválida de un problema de autorización sin pedir comandos al usuario.

Referencias: [Apple TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements), [Quinn sobre TCC y firma estable](https://developer.apple.com/forums/thread/721745), [TCC y designated requirements](https://developer.apple.com/forums/thread/730043), [por qué no firmar con --deep](https://developer.apple.com/forums/thread/129980).
