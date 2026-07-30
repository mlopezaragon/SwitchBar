# ClaudeSwitch

App nativa de barra de menús para macOS Tahoe que muestra el uso de varias
cuentas de Claude Code y cambia la cuenta activa con un clic o mediante una
política automática.

## Seguridad y convivencia con Claude Code

- Claude Code conserva su sesión oficial en `Claude Code-credentials` y su
  identidad en `~/.claude.json`.
- ClaudeSwitch guarda los perfiles en una única entrada privada del Llavero.
  `profiles.json` solo contiene metadatos y se escribe con permisos `0600`.
- Al cambiar, sustituye únicamente `claudeAiOauth` y `oauthAccount`. Las
  credenciales MCP y las demás claves se preservan.
- La app usa el mismo `/usr/bin/security` que Claude Code para su entrada y
  nunca emplea `-A` ni cambia la ACL a “cualquier aplicación”. Los valores
  normales viajan por la entrada estándar; si una sesión es demasiado grande,
  replica el mecanismo alternativo oficial de Claude Code para impedir que
  `security -i` la corte y corrompa el JSON.
- `claude auth login --claudeai` y `/login` siguen siendo los únicos dueños
  del alta de sesión. La sesión de la cuenta activa nunca se renueva desde
  ClaudeSwitch: se recoge del Llavero oficial cuando Claude Code la rota, de
  modo que ninguna terminal abierta queda invalidada. Las cuentas inactivas
  no tienen ninguna terminal detrás, así que su sesión del almacén privado sí
  se renueva con el flujo OAuth estándar (el mismo endpoint y client_id que
  usa Claude Code) para que su uso siga visible y el cambio automático nunca
  decida con datos viejos.
- Las operaciones privadas del Llavero desactivan la interfaz de
  autenticación: ante un Llavero bloqueado se muestra un error en la app, no
  una cadena de cuadros solicitando la contraseña.
- La app consulta cada minuto durante las incidencias el estado público oficial
  de `status.claude.com`. Muestra por separado la API y Claude Code, los
  incidentes activos y su fase, sin enviar credenciales.

## Primeros pasos

1. Ejecuta `make install` y abre `/Applications/ClaudeSwitch.app`.
2. Pulsa «Añadir cuenta».
3. Usa el botón para copiar `claude auth login --claudeai` y abrir Terminal,
   o ejecuta `/login` dentro de Claude Code.
4. Cuando el navegador confirme que Claude Code está listo, vuelve a la app y
   pulsa «Ya terminé: guardar cuenta».
5. Repite una sola vez por cada cuenta. A partir de ahí, los cambios no
   requieren contraseña ni otro login mientras la sesión siga vigente.

Cuando una cuenta pierde la sesión, su propia tarjeta ofrece «Iniciar sesión
de nuevo» y abre el mismo asistente, ya preparado para esa dirección de correo.
La app comprueba que hayas elegido la cuenta correcta antes de reemplazar sus
credenciales.

Un `/login` manual continúa funcionando. La app pausa el cambio automático
durante 15 minutos únicamente cuando detecta que realmente cambió la cuenta
activa; las escrituras ordinarias de `~/.claude.json` con la misma cuenta no
renuevan esa pausa. Si Claude Code rota el token de la misma cuenta, se recoge
en la siguiente consulta de uso. Las sesiones de terminal que ya estaban
abiertas conservan su cuenta hasta reiniciarlas.

Si actualizas desde una versión que guardaba `secrets.json`, la app lo importa
al Llavero y elimina el archivo únicamente después de verificar la copia. Si
una cuenta antigua no conserva su secreto, hay que enlazarla una última vez
con el flujo oficial anterior.

## Cambio automático

La ventana de 5 horas y la semana general tienen umbrales independientes y
configurables. Fable es opcional y está desactivado como criterio por defecto:
su consumo sigue visible, pero no provoca cambios, no descarta cuentas y no
influye en cuál se elige. Si se activa expresamente, usa su propio umbral y
recupera el comportamiento completo para ese cupo independiente.

Las consultas de uso se hacen de una en una y se reparten durante todo el
intervalo elegido; nunca se envían todas las cuentas juntas. La cuenta activa
tiene prioridad. Un dato con menos de 30 segundos no se vuelve a pedir aunque
coincidan varios disparadores (cambio de cuenta, apertura del panel y sondeo);
solo el botón de refresco fuerza la consulta. Si Anthropic limita temporalmente una cuenta, solo esa cuenta
descansa durante el tiempo indicado por el servidor (diez minutos si no lo
indica) y las demás continúan actualizándose. La espera se conserva aunque se
reinicie ClaudeSwitch. Los problemas de una cuenta inactiva se reflejan
únicamente en la antigüedad de sus datos; el aviso naranja aparece solo cuando
afecta a la cuenta activa. Los fallos temporales conservan los últimos datos y
nunca presentan la salida interna del Llavero ni credenciales. Tras un
`/login` manual, la automatización queda temporalmente en pausa.

Cerrar el panel no detiene la app: mientras el icono siga en la barra de menús,
el uso se consulta y el cambio automático continúa en segundo plano. Al
despertar el Mac o volver a activar ClaudeSwitch se hace una comprobación si
los datos están desactualizados. Si la app se ha cerrado por completo no puede
cambiar durante ese tiempo; al abrirla de nuevo comprueba el uso de inmediato
y cambia en cuanto recibe datos actuales que superan un umbral.

## Desarrollo

- `make build`, `make test`, `make app`, `make install`, `make run`.
- Núcleo en `Sources/ClaudeSwitchCore`; interfaz SwiftUI en
  `Sources/ClaudeSwitch`.
- El ensamblado exige una identidad estable. Prefiere automáticamente
  `Developer ID Application` y después `ClaudeSwitch Self-Signed`; una firma
  ad-hoc solo puede habilitarse expresamente para desarrollo efímero con
  `CLAUDESWITCH_ALLOW_ADHOC=1`.
- `scripts/reparar-llavero.sh` solo hace una prueba inocua de escritura y
  ejecuta los diagnósticos oficiales. Nunca exporta ni recrea la sesión.
