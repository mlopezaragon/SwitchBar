# SwitchBar

App nativa de barra de menús para macOS que muestra el uso de varias
cuentas de Claude Code y cambia la cuenta activa con un clic o mediante una
política automática.

> **Proyecto no oficial.** SwitchBar es independiente y no está afiliado,
> respaldado ni mantenido por Anthropic. «Claude» y «Claude Code» son
> marcas de Anthropic, PBC.

[English version](README.md)

## Funciones

- Barras de uso por cuenta: ventana de 5 horas, semana general y el cupo
  semanal independiente de Fable, con su hora de reinicio.
- Cambio de cuenta activa con un clic, con deshacer.
- Cambio automático con umbrales independientes y configurables.
- Cuentas compartidas: define un tope personal (por ejemplo 70 %) para que
  la app trate la cuenta como agotada antes y deje margen a la otra persona.
- Estado público de Anthropic (status.claude.com) durante incidencias, para
  no confundir una caída del servidor con un problema local.
- Tras un `/login` manual, el cambio automático se pausa 15 minutos: tu
  elección explícita manda.
- Localizada en 10 idiomas. Sin telemetría de ningún tipo.

## Requisitos

- macOS 26 (Tahoe), Apple Silicon o Intel (binario universal).
- [Claude Code](https://code.claude.com) con una o más cuentas de
  suscripción (Pro/Max).

## Instalación

Con [Homebrew](https://brew.sh):

```sh
brew install --cask mlopezaragon/tap/switchbar
```

O a mano: descarga `SwitchBar-<versión>.dmg` desde
[Releases](../../releases), verifica su SHA-256 publicado
(`shasum -a 256 SwitchBar-<versión>.dmg`) y arrastra SwitchBar a
Aplicaciones.

Las betas van firmadas con Developer ID pero aún sin notarizar: la primera
vez que abras la app, clic derecho sobre ella y «Abrir». La versión
estable irá notarizada y se abrirá sin ningún aviso.

Después pulsa «Añadir cuenta», haz el login oficial con
`claude auth login --claudeai` y repite una sola vez por cuenta. A partir
de ahí, los cambios no piden contraseña ni otro login mientras la sesión
siga vigente.

## Cómo funciona — léelo antes de depender de la app

SwitchBar usa los mismos endpoints privados que el propio Claude Code (la
consulta de uso y el flujo OAuth estándar de renovación, con el client id
público de Claude Code). **No son una API pública documentada y estable.**
Anthropic puede cambiarlos o restringirlos en cualquier momento. SwitchBar
está diseñada para fallar de forma segura: conserva los últimos datos,
nunca corrompe tu sesión de Claude Code y marca las cuentas que necesitan
un nuevo login; pero no puede prometerse compatibilidad permanente.

El inicio de sesión ocurre siempre mediante el flujo oficial de Claude Code
en tu terminal y navegador; SwitchBar nunca ve tu contraseña ni ejecuta una
autorización OAuth por su cuenta.

## Modelo de seguridad

- Claude Code conserva su sesión oficial en su propia entrada del Llavero y
  en `~/.claude.json`. Al cambiar, SwitchBar sustituye únicamente los
  bloques `claudeAiOauth` y `oauthAccount`; las credenciales MCP y las
  demás claves se preservan.
- Los perfiles guardados viven en una única entrada privada del Llavero
  propiedad de SwitchBar; `profiles.json` solo contiene metadatos no
  secretos (permisos 0600).
- El acceso al Llavero usa `/usr/bin/security` — el mismo mecanismo que
  Claude Code — y nunca amplía la ACL de una entrada.
- El ciclo de credenciales de la cuenta activa es propiedad de Claude Code:
  SwitchBar nunca rota su token, así que las terminales abiertas no quedan
  invalidadas. Solo los perfiles inactivos (sin ninguna terminal detrás) se
  renuevan, y el token rotado se guarda en el almacén privado.

## Privacidad

SwitchBar envía peticiones de red exclusivamente a:

- `api.anthropic.com` — consulta de uso de solo lectura por cuenta.
- `console.anthropic.com` — renovación OAuth estándar de perfiles inactivos.
- `status.claude.com` — página pública de estado (sin credenciales).

Nada más sale de tu Mac. No hay telemetría, analítica, informes de fallos
ni servidores de terceros. Consulta [PRIVACY.md](PRIVACY.md).

## Compilar desde el código

```sh
make test      # ejecutar la suite de pruebas
make app       # ensamblar y firmar SwitchBar.app (universal)
make install   # copiar a /Aplicaciones
make dmg       # DMG de distribución con SHA-256
```

La compilación exige una identidad de firma estable (Developer ID o un
certificado local autofirmado); consulta `scripts/build-app.sh`. El Llavero
asocia el almacén privado de perfiles a la firma del código, de modo que
una firma ad-hoc volvería a pedir autorización tras cada build.

## Contribuir

Consulta [CONTRIBUTING.md](CONTRIBUTING.md). Problemas de seguridad: sigue
[SECURITY.md](SECURITY.md) en lugar de abrir un issue público.

## Licencia

[Apache 2.0](LICENSE). Copyright 2026 Manuel Lopera.
