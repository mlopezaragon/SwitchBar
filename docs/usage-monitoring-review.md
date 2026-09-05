# Revisión del seguimiento de uso — 5 de septiembre de 2026

El problema combina la antigüedad de las consultas con una limitación del
cambio de cuenta: las terminales abiertas mantienen la sesión anterior.
Actualizar el uso permite decidir antes, pero no migra los subagentes vivos
a otra cuenta.

## Hallazgos y cambios

| Problema observado en el código | Cambio |
| --- | --- |
| El turno circular y las esperas dependen del número de cuentas; las cuentas nuevas aceleran el ciclo a cinco segundos. | Planificación por fecha: prioridad para la activa, sin dejar indefinidamente sin turno a las demás. |
| El botón, los eventos de la app y las consultas de rescate pueden encadenar peticiones. | Una única puerta de entrada, con al menos 30 segundos entre intentos y una sola consulta en curso. Los fallos también consumen turno. |
| Un 429 sin cabecera empieza con diez minutos de espera y el contador se comparte con las renovaciones. | Consultas de uso: 1, 2, 4, 8 y hasta 15 minutos de espera progresiva. Renovaciones: contador independiente y descansos largos. |
| La espera explícita del servidor se multiplica y se recorta. | `Retry-After` positivo se respeta sin multiplicarlo ni acortarlo, también al restaurar una pausa guardada. |
| Una consulta a la página pública de estado retrasa el refresco manual del consumo. | La comprobación del estado se ejecuta por separado. |
| Se consideran suficientemente recientes datos de la activa de hasta media hora. | La activa muestra una advertencia y deja de servir para decidir después de dos minutos sin datos. La evaluación automática se revisa también sin una respuesta nueva. |
| Un destino con un porcentaje antiguo parece disponible aunque otra terminal pueda estar consumiéndolo. | Se prefieren destinos comprobados durante el último minuto; los demás se verifican antes de cambiar. Se vuelve a validar la cuenta activa y la pausa tras login después de esperar a la red. |
| Una ventana cuyo reinicio ya pasó se elimina como si confirmara que hay margen. | El dato requiere una nueva consulta; no se convierte en evidencia de consumo cero. |
| Se puede renovar una cuenta inactiva que todavía usa una terminal antigua, o asumir que una sesión activa lleva seis horas abandonada. | La cuenta activa nunca se renueva desde el sondeo. En las demás, no se renuevan tokens si se detectan clientes que puedan usar Claude Code. Node/Bun se tratan de forma conservadora porque pueden alojar una instalación npm. |

La cuenta activa tiene un intervalo objetivo de 60 segundos, reducido a 30
al aproximarse a los umbrales configurados. Los topes personales de cuentas
compartidas también intervienen. Las otras cuentas conservan el ajuste de
3, 5 o 10 minutos, ahora identificado así en la interfaz. Una cuenta secundaria
pendiente puede ocupar un turno intermedio incluso cerca del límite, para
que sus fallos no dejen al cambio automático sin alternativas.

Estos intervalos son objetivos del planificador: las pausas de Anthropic,
la latencia de red, el reposo del equipo y una sesión caducada pueden
alargarlos. El aviso de pausa dice que se **reintentará**, sin prometer una
actualización exitosa.

## Qué falta para una lectura durante las pausas del servidor

La consulta OAuth sigue siendo la fuente de uso de esta implementación. Un
429 no demuestra que la suscripción esté agotada: limita la consulta y no
autoriza a inventar un 100 % ni a saltarse la espera del servidor.

Claude Code documenta `rate_limits.five_hour.used_percentage` y
`rate_limits.seven_day.used_percentage` en el JSON de su barra de estado.
Un siguiente desarrollo puede recoger esos valores localmente sin otra
consulta OAuth. La documentación advierte que los eventos pueden quedarse
en silencio cuando el coordinador espera a subagentes; ejecutar la barra con
un temporizador tampoco garantiza que el dato recibido sea nuevo.

Esa integración necesita asociar cada sesión a su cuenta verificada. No se
debe atribuir el dato a la cuenta que figure activa en ese momento: una
terminal anterior puede seguir consumiendo otra cuenta. También debe
preservar cualquier barra de estado existente y distinguir la fecha real del
dato de la fecha de ejecución del script. No se ha instalado esa integración
ni modificado la configuración de Claude.

Fuentes oficiales consultadas:

- [Datos y funcionamiento de la barra de estado de Claude Code](https://code.claude.com/docs/en/statusline).
- [Tratamiento de 429 y Retry-After en la API de Claude](https://platform.claude.com/docs/en/api/rate-limits). Esta documentación no establece una frecuencia garantizada para el endpoint privado OAuth de uso.

## Validación y alcance

`swift test`: 103 pruebas, incluidas nueve nuevas. Cubren una simulación de
21 cuentas con errores repetidos, prioridad y reparto de turnos, separación
entre intentos, restauración de datos, cambio de cuenta activa, pausas por
cuenta, reintentos y detección conservadora de runtimes. La compilación de
la aplicación forma parte de la ejecución de SwiftPM.

Las pruebas usan datos ficticios y respuestas simuladas. No prueban cuotas
reales de Anthropic ni la migración de sesiones vivas. La validación de desarrollo no reinicia Claude ni cambia cuentas reales.
La publicación e instalación de 1.0.1 se validan por separado. Los cambios previos del
repositorio se han conservado; el diff completo incluye trabajo anterior.
