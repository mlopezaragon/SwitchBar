# ClaudeSwitch — Diseño

Fecha: 2026-07-29. Estado: aprobado por el usuario (conversación con Claude Code).

## Propósito

App nativa de barra de menús para macOS que permite ver el uso de 3 cuentas de
Claude (ventana de 5 horas, semanal y semanal de Opus/Fable, con sus fechas de
reseteo) y cambiar la cuenta activa de Claude Code con un clic o de forma
automática e inteligente, sin volver a pasar por el inicio de sesión del
navegador.

## Alcance

- Solo afecta a Claude Code (terminal). No toca sesiones de claude.ai en el
  navegador ni la app de escritorio de Claude.
- 3 cuentas (el diseño admite N).
- Sin backend: todo local. Secretos solo en el Llavero de macOS.

## Datos técnicos verificados

- Credenciales activas de Claude Code: entrada del Llavero con servicio
  `Claude Code-credentials`. Es un JSON con la clave `claudeAiOauth`
  (`accessToken`, `refreshToken`, `expiresAt`, `refreshTokenExpiresAt`,
  `scopes`, `subscriptionType`, `rateLimitTier`) y, además, claves `mcpOAuth.*`
  con tokens de servidores MCP (utilia-crm, utilia-dev). **Al cambiar de cuenta
  solo se reemplaza `claudeAiOauth`; el resto del JSON se preserva.**
- Identidad de la cuenta activa: bloque `oauthAccount` de `~/.claude.json`
  (accountUuid, emailAddress, organizationUuid, displayName, etc.). Se
  intercambia junto con las credenciales.
- Uso: `GET https://api.anthropic.com/api/oauth/usage` con cabeceras
  `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`,
  `User-Agent: claude-code/<versión>`, `Content-Type: application/json`.
  Respuesta: `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet`
  (cada una `{utilization: 0-100, resets_at: ISO8601}`; las específicas de
  modelo pueden ser null) y `extra_usage`. Sondeo seguro cada ~180 s por token.
- Renovación de tokens: POST al endpoint OAuth de Anthropic
  (`https://console.anthropic.com/v1/oauth/token`, con
  `https://platform.claude.com/v1/oauth/token` como alternativa) con
  `grant_type=refresh_token` y el `client_id` público de Claude Code.
- Advertencia: el endpoint de uso no está documentado oficialmente; los
  términos reservan los tokens OAuth para Claude Code/claude.ai. Uso personal.

## Arquitectura

Swift Package Manager (patrón de la app Eco), macOS 26 (Tahoe):

- **ClaudeSwitchCore** (librería, testeable, sin UI):
  - `KeychainService`: lectura/escritura de entradas genéricas del Llavero.
  - `ClaudeCodeStore`: lee/escribe la entrada `Claude Code-credentials`
    (reemplazo quirúrgico de `claudeAiOauth`) y el bloque `oauthAccount` de
    `~/.claude.json`. Relee siempre antes de escribir (Claude Code puede
    escribir en paralelo).
  - `ProfileStore`: perfiles guardados. Metadatos (email, nombre, plan) en
    `~/Library/Application Support/ClaudeSwitch/profiles.json`; secretos en el
    Llavero, una entrada `ClaudeSwitch-profile-<accountUuid>` por cuenta.
  - `TokenRefresher`: renueva tokens caducados con el refresh token. Si el
    refresh token muere, marca el perfil como "requiere inicio de sesión".
  - `UsageClient`: consulta el endpoint de uso.
  - `UsagePoller`: cada 180 s consulta las 3 cuentas (no solo la activa) y
    publica instantáneas con `fetchedAt` (para mostrar "hace X min" sin red).
  - `SwitchEngine`: cambio de cuenta. Antes de cambiar, vuelca las credenciales
    activas (posiblemente renovadas por Claude Code) a su perfil; después
    escribe las del perfil elegido en el Llavero y en `~/.claude.json`.
    Registra el cambio anterior para poder deshacer.
  - `AutoSwitchPolicy`: lógica del modo automático (pura, testeable).
- **ClaudeSwitch** (ejecutable SwiftUI): MenuBarExtra estilo ventana + ventana
  de detalle/ajustes. `LSUIElement` (sin Dock).

## Alta de cuentas (onboarding)

El usuario inicia sesión en Claude Code con normalidad (una vez por cuenta).
La app detecta que la cuenta activa (email de `oauthAccount`) no tiene perfil
guardado y ofrece "Guardar este perfil". Con las 3 guardadas, no se vuelve a
pasar por el navegador. La app vigila cambios para mantener los perfiles
frescos (vuelca tokens renovados al perfil correspondiente).

## Cambio manual

Un clic en una cuenta del panel → `SwitchEngine.switch(to:)` → aviso claro de
que las sesiones de Claude Code ya abiertas siguen con la cuenta anterior
hasta reiniciarlas (Claude Code cachea el Llavero ~30 s).

## Cambio automático inteligente

Interruptor en ajustes. Reglas (umbral configurable, por defecto 90 %):

1. Disparo: la cuenta activa supera el umbral de la ventana de 5 h.
2. Candidatas: cuentas con `seven_day` < 95 % y `seven_day_opus` < 95 % (si
   aplica) y sin error de credenciales.
3. Elección: menor `five_hour`; desempate por mayor margen ponderado
   semanal + Opus (pesos 0,6 / 0,4).
4. Si no hay candidatas: no cambia; muestra el primer reseteo que llegue.
5. Notificación nativa al cambiar, y acción "Deshacer" (también en el panel).

## UI (Apple + Vercel; sencillez Apple, Liquid Glass de Tahoe)

- Icono de barra de menús: anillo de progreso con el uso de 5 h de la cuenta
  activa (plantilla monocromo, se adapta a claro/oscuro).
- Panel (MenuBarExtra .window, ~360 pt): 3 tarjetas limpias — punto de estado,
  email, tres barras finas (5 h / semanal / Fable-Opus) con porcentaje y hora
  de reseteo en texto secundario; insignia sutil en la activa. Clic = cambiar.
  Pie: modo automático (interruptor), deshacer, abrir detalle, salir.
- Ventana de detalle: anillos grandes por cuenta, fechas de reseteo completas,
  ajustes (umbral, modo automático, arranque al iniciar sesión, intervalo).
- Estética: tipografía SF, `glassEffect` de macOS 26, jerarquía tipográfica
  clara estilo Vercel (números grandes tabulares, etiquetas secundarias),
  modo claro/oscuro automático, sin emojis.
- Todos los textos en español correcto (tildes, eñes).

## Errores y casos límite

- Sin red / endpoint caído: se muestran los últimos datos con "hace X min";
  el cambio de cuenta sigue funcionando (funciones independientes).
- Refresh token caducado: cuenta marcada "requiere inicio de sesión"; el
  resto sigue.
- Escrituras concurrentes con Claude Code: releer antes de escribir; el
  volcado previo al cambio evita perder tokens renovados.
- Respuestas 429: retroceso exponencial; nunca martillear el endpoint.

## Pruebas

- Tests unitarios de `AutoSwitchPolicy` (todas las ramas de la política),
  parsing del JSON de uso, y del reemplazo quirúrgico de `claudeAiOauth`
  (preservación de `mcpOAuth`).
- Prueba manual guiada del cambio de cuenta real al final.

## Construcción

Patrón Eco: `swift build` + `scripts/build-app.sh` que ensambla
`ClaudeSwitch.app` con firma ad-hoc o identidad local estable, `Makefile` con
`build/app/install/run/stop/clean`.
