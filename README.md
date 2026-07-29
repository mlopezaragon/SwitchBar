# ClaudeSwitch

App nativa de barra de menús para macOS (26 Tahoe) que muestra el uso de tus
cuentas de Claude Code — ventana de 5 horas, semanal y semanal de Fable/Opus,
con sus horas de reseteo — y cambia la cuenta activa con un clic o de forma
automática, sin volver a pasar por el inicio de sesión del navegador.

## Cómo funciona

- Claude Code guarda su sesión en la entrada del Llavero
  `Claude Code-credentials` y la identidad en `~/.claude.json`.
- ClaudeSwitch guarda un perfil por cuenta (metadatos en
  `~/Library/Application Support/ClaudeSwitch/profiles.json`; tokens en el
  Llavero) y cambia de cuenta reemplazando **solo** la clave `claudeAiOauth`
  (los tokens MCP y demás claves se preservan) y el bloque `oauthAccount`.
- El uso se consulta en el endpoint OAuth de Anthropic (el mismo que usa el
  comando `/usage` de Claude Code) cada 3 minutos para todas las cuentas.

## Primeros pasos

1. `make install` (compila, firma y copia a /Applications) y abre la app.
2. Con tu cuenta actual en Claude Code, pulsa «Guardar» en el aviso
   «Cuenta activa sin guardar» del panel.
3. En una terminal: `claude /logout` y `claude /login` con la segunda cuenta;
   vuelve al panel y guárdala. Repite con la tercera.
4. A partir de ahí, cambia con un clic o activa el «Cambio automático».

Notas:
- La primera vez, macOS pedirá permiso para leer la entrada del Llavero de
  Claude Code: elige «Permitir siempre».
- Las sesiones de Claude Code ya abiertas siguen con la cuenta anterior hasta
  que las reinicies.
- Aviso: el endpoint de uso no está documentado oficialmente y los términos de
  Anthropic reservan los tokens OAuth para Claude Code/claude.ai. Uso personal.

## Cambio automático

Cuando la cuenta activa supera el umbral de la ventana de 5 h (90 % por
defecto, ajustable), elige la mejor cuenta descartando las que tengan el
semanal o el semanal de Fable/Opus por encima del 95 %, ordenando por menor
uso de 5 h con desempate por margen semanal ponderado. Notifica cada cambio y
permite deshacerlo.

## Desarrollo

- `make build` / `make test` / `make app` / `make install` / `make run` / `make stop`
- Núcleo testeable en `Sources/ClaudeSwitchCore` (38 tests en
  `Tests/ClaudeSwitchCoreTests`), UI SwiftUI en `Sources/ClaudeSwitch`.
- Diseño: `docs/superpowers/specs/2026-07-29-claudeswitch-design.md`.
- Para que el permiso del Llavero persista entre recompilaciones, crea una
  identidad de firma local «ClaudeSwitch Self-Signed» (Acceso a Llaveros →
  Asistente para Certificados → Crear un certificado, tipo «Firma de código»)
  y reinstala con `make install`.
