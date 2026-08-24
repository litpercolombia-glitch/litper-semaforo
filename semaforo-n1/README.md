# ZYNEX Semáforo N1

Agente autónomo de salud de entrega por **ciudad × transportadora** para Litper.

No es un dashboard: **escribe**. Marca estado, marca guías en tránsito, registra la decisión,
dispara notificación, mide el resultado a 72h y recalibra sus propias reglas.

## Fuente de verdad

**Dropi** (tabla `guias` en Supabase `gtsivwbnhcawvmsfujby`).

**Prohibido** alimentar el semáforo con atribución de Meta: el 21-ago-2026 se confirmó que los
69 adsets devuelven `omni_purchase = 0` a nivel adset (atribución CTWA rota). La regla está
fijada en `loop_rules.semaforo-fuente-verdad`.

## Contrato de tiers

| Tier | Quién decide | Qué hace |
|---|---|---|
| **T1** | El agente, solo | Fija color verde/amarillo, marca guías en tránsito, registra decisión + evento + notificación |
| **T2** | CEO, un click | Marcar ROJO y bloquear ciudad×carrier con < 80 pedidos en ventana |
| **T3** | CEO, obligatorio | Marcar ROJO con ≥ 80 pedidos (umbral `semaforo-t3-pedidos`) |

## Tools que escriben

| Función SQL | Escribe en |
|---|---|
| `semaforo_marcar()` | `semaforo_estado`, `guias.metadata`, `llao_decisions`, `marcus_actions`, `loop_events`, `semaforo_notificaciones`, `alertas` |
| `semaforo_ejecutar()` | ↑ todo lo anterior + `semaforo_runs`, `loop_state` |
| `semaforo_aprobar()` | `llao_decisions`, `loop_events`, `loop_learnings` + ejecuta `semaforo_marcar` |
| `semaforo_medir()` | `marcus_outcomes`, `loop_learnings`, `loop_events`, **`loop_rules`** (auto-calibración) |
| `semaforo_evaluar()` | nada — dry-run |

## Estructura

```
db/semaforo_n1.sql     esquema + tools (ya aplicado en producción)
api/semaforo.js        proxy serverless — las llaves viven acá, nunca en el cliente
public/index.html      consola de operación (dark, un solo acento)
```

## Env vars (Vercel)

```
SUPABASE_URL                 https://gtsivwbnhcawvmsfujby.supabase.co
SUPABASE_SERVICE_ROLE_KEY    (service role — NUNCA al cliente)
SEMAFORO_PASS                clave de acceso a la consola
```

## Correr el ciclo

```bash
curl -X POST https://<deploy>/api/semaforo \
  -H 'content-type: application/json' -H "x-pass: $SEMAFORO_PASS" \
  -d '{"action":"ejecutar","dias":30}'

curl -X POST https://<deploy>/api/semaforo \
  -H 'content-type: application/json' -H "x-pass: $SEMAFORO_PASS" \
  -d '{"action":"medir","horas":72}'
```

Recomendado: cron diario 7:00am `ejecutar`, y 7:15am `medir`.
