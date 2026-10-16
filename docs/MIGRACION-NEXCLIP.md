# NexClip: identidad y migración local

- App, ejecutable y target SwiftPM: `NexClip`; tests: `NexClipTests`; bundle ID: `com.nexclip.app`.
- Licencia GNU GPL v3, sin cambios en `LICENSE`.
- Instala `NexClip.app` en Aplicaciones y sal de la versión anterior antes de abrirla. No se fuerza el cierre de otra app.
- Antes de abrir SQLite o arrancar la captura, si falta `~/Library/Application Support/NexClip/history.sqlite` y existe `~/Library/Application Support/MemoriaLocal/history.sqlite`, copia esa base y sus archivos `-wal`/`-shm` si existen. No abre, mueve, migra ni hace checkpoint sobre el origen.
- Preparación en directorio privado (0700), archivos 0600. Normalmente publica el directorio completo mediante rename atómico; con directorio NexClip preexistente sin base, publica la base al final y revierte sus copias si ocurre un error. No sobrescribe colisiones ni datos nuevos.
- Copia únicamente las preferencias relevantes del dominio `local.memorialocal.app` al dominio nuevo: consentimiento `captureEnabled`, pausa, intervalo de sondeo, exclusiones/lista permitida, retención, separador, reordenación, autoPaste, tecla/modificadores, apariencia y tipos personalizados. Conserva valores explícitos ya guardados en el dominio nuevo. Los valores registrados por defecto no impiden importar los antiguos.
- Un recibo privado `migration.plist` permite recuperar las preferencias tras una interrupción inmediatamente posterior a publicar la base. Al existir datos nuevos, no vuelve a copiar la base.
- Los respaldos reales de la app se crean mediante NSSavePanel donde el usuario elige, no en un directorio automático. Permanecen intactos y se pueden fusionar desde NexClip; no se buscan ni duplican archivos arbitrarios fuera de Application Support. El nombre sugerido nuevo es `NexClip-respaldo.sqlite`.
- No migra permisos TCC, certificados, ni el registro de inicio de sesión de macOS (`SMAppService`); son propios de la nueva identidad. «Restablecer permiso de Accesibilidad» solo ejecuta `tccutil reset Accessibility com.nexclip.app`.

## Texto visible y registro

Al migrar aparece un diálogo con título **NexClip — migración completada**, botón **Continuar** y texto exacto:

`migrado desde Memoria Local el <fecha>`

`<fecha>` es UTC en ISO 8601 (por ejemplo `2026-10-16T15:30:00Z`). La misma línea aparece en el diagnóstico de Accesibilidad y en `~/Library/Logs/NexClip/migracion.log`; no contiene copias del portapapeles. Si el log no puede escribirse se registra el error en NSLog sin impedir abrir el historial ya copiado.

Si la versión anterior sigue abierta, se detiene el arranque sin copiar y se muestra:

`Sal de Memoria Local desde su menú Salir y vuelve a abrir NexClip para copiar el historial y los ajustes sin modificar el origen.`

## Icono

`packaging/AppIcon.png` es el maestro RGBA 1024px. La silueta se detectó por el borde continuo cyan/morado, eliminando solo el negro exterior conectado; se suavizó la máscara para quitar artefactos de compresión. El gráfico ocupa 820/1024 (~80%) y el exterior es transparente. `AppIcon.iconset` incluye 16, 32, 64, 128, 256 y 512 pt a 1x/2x; `AppIcon.icns` incluye PNGs de 16 a 1024px en sus chunks correspondientes.

Regeneración reproducible desde el maestro (Pillow):

```sh
python3 scripts/build_icon.py packaging/AppIcon.png --master
```

No se ha cambiado la lógica de firma ni sus secretos. La integración de esta rama con cambios de firma paralelos debe conservar la copia de AppIcon antes de firmar.
