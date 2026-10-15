# Aceptación macOS para ejecutor autorizado

Objetivo registrado: Mac M4/arm64, macOS Tahoe 26.5.2. **No se accedió a ese equipo.** Esta lista es para el ejecutor/agente con acceso autorizado, no una solicitud para que la persona usuaria opere una terminal. No instalar SDK/toolchains ni usar cuentas o credenciales ajenas. Si faltan host o herramientas, registrar BLOQUEADO y detener esa fase.

## Entrada automática

`python3 scripts/macos_executor.py --output RUTA_AUTORIZADA_NUEVA`

El flujo registra entorno, versión Swift, SDK, resultados XCTest, compilación release arm64, `--self-check`, plutil/codesign, fuente correspondiente y hashes. Exige salida nueva y preserva logs de fallos. No abre la app ni lee `.general`; XCTest crea pasteboards nombrados de prueba. Un resultado 0 acredita esas etapas, no la aceptación visual/pegado.

## Fixtures y aislamiento

- Sesión macOS de pruebas sin datos personales; no usar portapapeles/historial reales de la persona usuaria.
- Primer lanzamiento de la app: captura desactivada y autopegado desactivado.
- Fixtures: texto `Hola ñ 👩🏽‍💻`, multilínea/tabulador, RTF con negrita, HTML con estilos y una URL remota de imagen, PNG/TIFF 1×1 y varias imágenes/ítems; archivo temporal de prueba para URL.
- Dos aplicaciones de prueba, con documentos nuevos sin guardar: editor enriquecido y editor de texto plano. Consentimiento Accesibilidad solo mediante la interfaz del sistema y acción explícita; nunca alterar TCC por comandos ni automatizar aprobación de permisos.
- Guardar capturas solo de contenido sintético y redactar identificadores personales. Los logs no deben contener payloads reales.

## Casos con aceptación observable

| Área | Positivo | Negativo / contraprueba | Evidencia que conservar |
|---|---|---|---|
| Captura/consentimiento | Activar captura y copiar fixture nuevo crea una fila | Al inicio no captura copia preexistente; desactivar/pausar no guarda las siguientes | Video/captura sintética + conteos antes/después |
| Persistencia/multiformato | Cerrar/reabrir conserva texto y bytes RTF/HTML/imagen/ítems | Cambiar un byte da identidad distinta; repetir mismos tipos/bytes no duplica | Conteo, hash de fixtures, propiedades por tipo |
| Ráfagas/sueño | Cambios espaciados mayores que sondeo se observan | Copias más rápidas pueden perderse: medir y documentar, no declarar lossless | Intervalos/cantidad copiada/capturada |
| Filtros | Origen permitido crea fila | ID excluido exacto, marcado oculto/transitorio y origen desconocido no; prefijo parecido no queda excluido | Conteos por fixture sin payload personal |
| Panel/teclado | Icono y hotkey abren panel; flechas/Enter/Shift-Enter/doble clic funcionan | Conflicto de hotkey informa y no inhabilita menú; Escape no pega | Video y combinación/teclado usados |
| Foco/pegado | Con AX concedido, selección devuelve foco al PID correcto y pega una vez | Sin AX: copiar manualmente; cambiar foco/pasteboard antes del evento cancela; destino cerrado no envía | Aplicación/PID sintético y documento antes/después |
| Permisos/TCC | Petición AX solo al intentar autopegar habilitado | Revocar permiso no deja pegados pendientes ni activa monitores de teclado; no se reintenta | Captura del estado y resultado funcional |
| Formatos | RTF/HTML mantienen estilos si la app destino los acepta; PNG/TIFF se pega como imagen | Shift-Enter no mantiene estilo; datos sin texto muestran aviso al pedir plano | Documento sintético destino/propiedades |
| Búsqueda | Literal título/contenido/alias reduce filas correctas | `%`, `_`, comillas no actúan como comodines/SQL; regex inválida rechazada; caso Unicode pendiente documentado | Filas exactas, no coincidencias globales de pantalla |
| Grupos/favoritos | Crear padre/hijo, mover varias copias, filtrar incluye descendientes | Borrar padre con hijos se rechaza; quitar grupo no borra BLOB; protección no equivale a favorito | IDs/conteos sintéticos |
| Retención/papelera | Expirar copias normales las mueve a papelera y permite restaurar | Protegidos/favoritos/fijados sobreviven; no hay purga física automática | Conteos activos/papelera/formatos |
| Edición/previews | Editor crea texto sin cambiar original; preview imagen/QR legible | HTML no hace requests ni ejecuta scripts; binario no se interpreta; imagen enorme no se decodifica | Hash original, captura sintética, observación de red local |
| Exportar/importar | JSON roundtrip conserva bytes/ítems/grupos; TXT/PNG se abren | Archivo inválido/cíclico/versión desconocida aborta transacción; sin sobrescritura por alias | Hashes y conteos antes/después |
| Backup/restore | Backup validado; merge agrega faltantes conservando actuales | Respaldo existente no se sobrescribe; DB dañada/futura rechazada; original suministrado no cambia | Hash archivo antes/después y log SQLite |
| Ajustes/arranque | Opt-in registra inicio de sesión y reiniciar sesión abre app | Desactivar revoca; denegación del sistema se informa sin fingir éxito | Estado `SMAppService` y prueba nueva sesión |
| Apariencia/accesibilidad | Panel compacto en español, claro/oscuro, teclado y VoiceOver | Sin texto cortado al redimensionar, sin contraste insuficiente ni foco atrapado | Capturas tamaños mínimo/normal/Retina y recorrido teclado |

## Criterios de salida

- Si Swift no compila, la siguiente fase corrige los errores reales del compilador y repite todas las pruebas afectadas. No se sustituye por validación textual de archivos.
- No aceptar «envío de ⌘V» como prueba de que el destino pegó el formato correcto: observar documento de destino.
- No afirmar paridad con el paquete Store: no hay versión/ejecución de ese paquete acreditada por el informe.
- Mantener pendientes F06/F09/F10/F11/F12/F14/F15/F19 hasta que se resuelvan sus brechas o se acuerde explícitamente una adaptación. No convertirlas silenciosamente en implementadas.
- No distribuir públicamente una firma ad hoc como si fuese notarizada. GPL/avisos/fuente deben ir juntos, nombre y bundle ID siguen provisionales.
