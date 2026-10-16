# Firma estable autofirmada de NexClip

## Objetivo y límites

Se conserva **el mismo certificado, su clave privada y el identificador del bundle**
entre compilaciones. El requisito designado (DR) debe identificar al certificado y
al bundle, no al `cdhash` de cada binario. Esta es la base para que TCC reconozca la
app como la misma y conserve Accesibilidad entre builds.

**Aceptación en el Mac: pendiente.** No se ha accedido al Mac ni probado aún dos
builds consecutivos allí. TN3127 explica el mecanismo para recursos protegidos;
la experiencia de Barkeep lo describe específicamente para Accesibilidad. Esto no
constituye una garantía por versión de macOS: hay que hacer la prueba indicada
abajo. El cambio de firma ad hoc a certificado, un cambio de bundle id o una
rotación del certificado puede exigir conceder Accesibilidad de nuevo.

No es Developer ID, no hay Apple Developer ni notarización. No concede permisos,
no evita Gatekeeper. La app integrada es `NexClip.app`, ejecutable `NexClip`,
bundle id `com.nexclip.app`. El icono se copia a Resources antes de firmar.
La migración desde Memoria Local cambia el bundle id y requiere una entrada
nueva de Accesibilidad; véase [MIGRACION-NEXCLIP.md](MIGRACION-NEXCLIP.md).

## Certificado y custodia

Identidad `NexClip Developer`, organización `NexClip`, autofirmada X.509 v3 con
RSA 2048 y firma SHA-256. Validez de 3650 días (aproximadamente diez años):
2026-10-16 18:13:37 UTC a 2036-10-13 18:13:37 UTC.

Extensiones generadas con OpenSSL:

```ini
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = CA:FALSE
subjectKeyIdentifier = hash
```

`codeSigning` es el OID `1.3.6.1.5.5.7.3.3`. TN2206 incluye un certificado de
firma con KU DigitalSignature y EKU Code Signing críticos. No se incluyen EKU TLS,
uso CA, perfiles de aprovisionamiento ni extensiones privadas que pretendan ser
un Developer ID de Apple.

Huella **SHA-256 del certificado DER**, pública:

```text
00a7880746325caa7538c48a1b7a45af4a84f1bd56a13d9435b0d8fce7774d4d
```

Original en el VPS: `/root/.hermes/datos/rea-ditto/firma-nexclip/`.
Directorio `0700`; todos los archivos `0600`. Su `README.md` identifica cada
archivo y el procedimiento de rotación. La clave PEM también está cifrada.
No copiar identidad, contraseña ni Base64 al workspace, repositorio, logs,
artifacts o informes. El certificado público `.cer` no contiene la clave privada.

## Identidad, confianza e importación no son lo mismo

- Una identidad es **certificado + clave privada correspondiente**. Importar solo
  un `.cer` no permite firmar.
- El certificado debe ser vigente, utilizable para firma de código, tener el EKU
  apropiado y disponer de la clave privada en un llavero desbloqueado accesible.
- `security find-identity -p codesigning <llavero>` muestra coincidencias y una
  sección de identidades válidas. `-v` limita a las válidas según evaluación de
  confianza; una identidad autofirmada puede aparecer como
  `CSSMERR_TP_NOT_TRUSTED` sin aparecer en esa segunda sección. Un listado vacío
  con `-v` no demuestra por sí solo que falte la clave o que falló la importación.
- Para que una autofirmada sea **confiable** en esa política, el usuario puede
  aceptarla explícitamente para Code Signing en Acceso a Llaveros. No basta con
  elegir un CN o añadir el EKU. Esta aceptación no la convierte en Developer ID.
- La estabilidad de identidad y la confianza de Gatekeeper son políticas
  diferentes (TN2206). El runner no instala confianza global, no toca el llavero
  System ni requiere que el destinatario confíe en el certificado. Se usa el
  llavero explícito para firmar. La salida real de `codesign`, no solo el listado
  de identidades, será el criterio de aceptación de CI.

## PKCS#12: elección de compatibilidad

OpenSSL 3 usa por defecto PBES2/PBKDF2/AES-256-CBC y MAC SHA-256. Los importadores
Apple no han tenido siempre la misma compatibilidad; existen incidencias donde
un contenedor válido falla como «contraseña incorrecta». Que Mumble/OpenSSL en
macOS 14 lea AES no prueba que `security import` lo acepte. Tampoco hay base para
afirmar que **todo macOS 14+** exija RC2/3DES: depende de la versión y del importador.

Se eligió explícitamente `-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
-iter 2048`, compatible con importadores antiguos, sin el RC2-40 que podría elegir
`-legacy`. La contraseña es aleatoria fuerte, no una palabra de usuario. SHA-1 en
este contenedor no cambia la firma SHA-256 del certificado. Es una decisión de
interoperabilidad, no una recomendación de 3DES para formatos nuevos.

La exportación pasa la contraseña mediante archivo/entrada estándar, no como
valor en la línea de comandos. Si `-passin file:X` y `-passout file:X` usan el
mismo archivo, OpenSSL espera dos líneas: utilizar entrada estándar separada
evita ese error sin duplicar ni imprimir la contraseña.

**Importación macOS verificada:** `security import` devolvió `1 identity imported.`
en el run [38949906289](https://github.com/soportetinvalu/ditto/actions/runs/38949906289),
con `Authority=NexClip Developer`, verificación estricta correcta y limpieza del
llavero temporal. No fue necesario reexportar el PKCS#12 ni cambiar la identidad.

## GitHub Actions y firma

Únicamente estos dos secrets de repositorio:

- `MACOS_CODESIGN_P12_BASE64`: PKCS#12 codificado (Base64 **no cifra**).
- `MACOS_CODESIGN_P12_PASSWORD`: contraseña del contenedor.

Se cifran en el VPS con la clave pública del repositorio, mediante libsodium
sealed box/PyNaCl, y se envían a `PUT /repos/{owner}/{repo}/actions/secrets/{name}`.
El token se obtiene solo mediante el ejecutor del canal y nunca se imprime.
Después se comprueban únicamente nombres y fechas con `GET .../actions/secrets`.

El workflow sigue siendo **manual** (`workflow_dispatch`), con `contents: read`,
checkout sin credenciales persistentes y acciones fijadas por SHA. Solo el paso
que compila/empaca recibe los secrets. No añadir `pull_request_target` ni ejecutar
código de PR no confiable con ellos. Quien puede editar/ejecutar un workflow con
secrets podría extraerlos: revisar cambios y accesos de escritura sigue siendo
necesario aunque el repositorio sea público.

`scripts/package_macos.sh` pasa el bundle en `$APP` al firmador
`scripts/sign_macos.sh`; la lógica de firma no depende del nombre del `.app` ni
de su identificador. El firmador:

1. Deshabilita tracing y crea un directorio privado fuera del árbol de artifacts.
2. Genera una contraseña efímera, crea/desbloquea un llavero temporal y conserva
   y amplía la lista previa de llaveros del usuario.
3. Decodifica el PKCS#12, importa con `-T /usr/bin/codesign` (no `-A`) y configura
   `security set-key-partition-list -S apple-tool:,apple: -s -k ...` sin prompts.
4. Exporta **solo el certificado público** como `NexClip-Developer.cer`.
5. Firma con `codesign --force --timestamp=none --keychain ... --sign
   "NexClip Developer" "$APP"`. No se habilita hardened runtime: no se busca
   notarizar y añadir restricciones/entitlements no resuelve la identidad TCC.
6. Ejecuta `codesign --verify --strict --verbose=2`, imprime `codesign -d -r-` y
   `codesign -dvv`, exige DR con certificado/anchor y sin `cdhash`, y exige
   `Authority=NexClip Developer`. El empaquetador vuelve a verificar el ZIP
   extraído. El certificado público se incluye junto a app, fuente y checksums.
7. Con `trap EXIT/INT/TERM`, restaura la lista de llaveros, borra el llavero y
   todos los temporales aunque falle la importación o firma. Hay además un paso
   `if: always()` de limpieza. No se puede garantizar un trap frente a SIGKILL o
   pérdida completa del runner; el runner alojado es efímero.

Si falta cualquiera de los secrets (fork/PR/local), firma **ad hoc con advertencia
explícita** y no afirma continuidad TCC; no se distribuye un certificado ajeno a
la firma usada. Un secret presente pero malformado, una importación fallida o un
DR incorrecto falla el job: no se degrada silenciosamente a ad hoc.

## Estado de provisión

Los dos secrets se crearon el 2026-10-16 mediante sealed box y sus nombres/fechas
se comprobaron por API. El bloqueo previo HTTP 403 quedó resuelto con permiso
Secrets: Read and write del PAT del mismo canal. No se crearon otros secrets.

El primer run con identidad real importó y firmó, pero el validador omitía la
forma válida `certificate root`. Se corrigió esa comprobación sin alterar la
identidad y se añadió una prueba aislada. El run 38949906289 pasó con firma
estable, 40/40 XCTest y 9/9 pruebas aisladas de firma. La integración de NexClip
conserva esa misma identidad y adopta el nuevo bundle id `com.nexclip.app`.

## Primera apertura en el Mac

Gatekeeper puede indicar «no se puede verificar el desarrollador». Tras comprobar
la procedencia del artifact y la huella, abrir desde **Ajustes del Sistema →
Privacidad y seguridad → Abrir de todos modos** y confirmar. Se puede repetir
por cada versión descargada; no se promete aceptación permanente entre versiones.
No es necesario quitar `quarantine` ni ejecutar comandos `xattr`. No se debilita
Gatekeeper globalmente. Confiar opcionalmente en el `.cer` no aporta notarización
ni garantiza que Gatekeeper deje de avisar; no es requisito de instalación.

## Comprobación pendiente en el Mac: dos builds consecutivos

1. Compilar dos revisiones distintas con los mismos secrets y el mismo bundle id;
   comparar los DR registrados y confirmar que son idénticos, sin `cdhash`.
2. Instalar la primera en la ubicación definitiva, cerrar otras copias, abrir por
   el flujo de Gatekeeper y conceder Accesibilidad una vez.
3. Salir por completo, reemplazar por la segunda en la misma ubicación y abrirla.
   No usar `tccutil reset` en esta prueba: destruiría el permiso que se quiere medir.
4. Comprobar que la copia nueva tiene Accesibilidad efectiva, que funciona la
   acción protegida y que no hubo que reconcederla. Revisar duplicados de la app
   antes de atribuir fallos a la firma.

El reset de Accesibilidad que ya hace el empaquetador se limita al **usuario
 efímero de CI**, no demuestra ni modifica permisos del Mac del destinatario.

## Rotación

No regenerar por build. Ante vencimiento/pérdida/compromiso, autorizar la rotación,
generar nueva clave/certificado y contraseña en almacenamiento privado `0700` /
`0600`, exportar PKCS#12 compatible, actualizar únicamente ambos secrets mediante
sealed box, verificar nombres/fechas y correr la rama autorizada. Comparar la nueva
huella, Authority, certificado del artifact y DR. Actualizar esta documentación.
Una nueva identidad puede exigir reconceder Accesibilidad. No existe revocación
centralizada de Developer ID para esta autofirmada. Un cambio solo de contraseña
PKCS#12, conservando clave y certificado, no cambia la identidad de firma.

## Fuentes

- [Apple TN2206: macOS Code Signing In Depth](https://developer.apple.com/library/archive/technotes/tn2206/_index.html),
  confianza, autofirmados/OpenSSL, EKU y requisitos designados.
- [Apple TN3127: Inside Code Signing: Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements),
  seguimiento de permisos mediante DR y limitación de firma ad hoc.
- [Apple TN3161: Inside Code Signing: Certificates](https://developer.apple.com/documentation/technotes/tn3161-inside-code-signing-certificates),
  identidades, selección del llavero y representación `Authority`.
- `man codesign` y [copia web del manual](https://www.manpagez.com/man/1/codesign/):
  firma ad hoc `-`, búsqueda de identidades y evaluación de requisitos.
- [Barkeep: permisos perdidos tras recompilar](https://barkeepmac.com/macos-permissions-lost-after-rebuild.html),
  experiencia autofirmada para Accesibilidad; no sustituye la prueba en nuestro Mac.
- [CrowdStrike: autofirmados y find-identity](https://github.com/CrowdStrike/falcon_sandbox_submitter/blob/main/CODESIGN.md),
  distinción entre matching identities y valid identities / confianza explícita.
- [OpenSSL: openssl-pkcs12](https://docs.openssl.org/3.0/man1/openssl-pkcs12/),
  defaults AES/PBKDF2, opciones PBE y modo legacy.
- [Trustico: compatibilidad PKCS#12 con Keychain](https://shop.trustico.com/blogs/stories/repackaging-a-pkcs12-file-for-macos-keychain-compatibility),
  experiencia de importación con algoritmos compatibles.
- [GitHub: firma de aplicaciones Xcode](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications),
  llavero temporal, partition list y limpieza.
- [GitHub REST: Actions secrets](https://docs.github.com/en/rest/actions/secrets),
  clave pública, sealed box y permisos del token.
