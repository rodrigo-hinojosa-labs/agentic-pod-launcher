# Data Model — Feature 026

La feature no introduce entidades persistentes ni esquema. El único "dato" es un valor de configuración de runtime.

## Entidad: `CHANNEL_HEALTH_TIMEOUT` (valor de configuración)

| Atributo | Valor |
|----------|-------|
| Nombre | `CHANNEL_HEALTH_TIMEOUT` |
| Tipo | entero positivo, en **segundos** |
| Default | `60` (embebido en `docker/scripts/start_services.sh`, materializado al rebuild) |
| Origen del override | variable de entorno del workspace `.env` → `env_file` de `docker-compose.yml.tpl:67` → entorno del contenedor |
| Alcance | modo docker únicamente (el script es image-baked; el modo local no lo usa) |
| Persistencia | ninguna nueva; el `.env` es user-owned (`0600`, gitignored) y `--regenerate` no lo reescribe |
| Ownership | operador (edita el `.env` a mano); no está en `agent.yml` ni en el render |

## Reglas de validación (helper `channel_health_timeout()`)

| Entrada | Resultado |
|---------|-----------|
| ausente / vacía | `60` |
| no-numérica (`abc`, `1.5`, `-5`) | `60` |
| `0` | `60` (rechazado por `-le 0`) |
| entero positivo (`45`, `90`) | ese valor, tal cual |

La validación es `[[ "$t" =~ ^[0-9]+$ ]] && [ "$t" -gt 0 ]` (patrón sin comillas por bash 3.2). El valor solo alimenta comparaciones `[ -lt ]` (base-10), nunca aritmética `$(( ))` → sin riesgo octal.

## Estados / transiciones (resolución en tiempo de arranque)

```text
lee CHANNEL_HEALTH_TIMEOUT
      │
      ├─ inválido/ausente ──► timeout = 60 (default, silencioso)
      │
      └─ válido (>0) ──► timeout = valor
                              │
                              ├─ valor < UMBRAL_WARN (65) ──► sin aviso
                              │
                              └─ valor ≥ UMBRAL_WARN (65) ──► WARN una-vez al boot
                                    ("con N s el crash budget puede no escalar a restart de contenedor")
```

## Consumidores

- `verify_channel_healthy()` — usa el valor como tope del loop de espera de `bun server.ts`.
- Log de `start_session()` (`:760`) — nombra el valor efectivo cuando el channel no aparece (FR-005).
- `main()` (arranque) — evalúa el valor una vez y emite el WARN de crash budget si corresponde (FR-006/decisión D).

## Constantes relacionadas (NO modificadas por esta feature)

| Constante | Valor | Ubicación | Relación |
|-----------|-------|-----------|----------|
| `MAX_CRASHES` | 5 | `start_services.sh:245` | crash budget; define el umbral WARN |
| `WINDOW` | 300 | `start_services.sh:246` | crash budget; punto de ruptura `T<70` |
| poll interval | `sleep 2` | `start_services.sh:728` | granularidad; el techo efectivo redondea al par inferior |
