// ZYNEX SEMAFORO N1 — proxy server-side.
// Las llaves NUNCA llegan al cliente: viven en env vars de Vercel.
// Fuente de verdad UNICA: Dropi (tabla `guias`). Prohibido usar atribucion Meta.

const SUPABASE_URL = process.env.SUPABASE_URL;
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const PASS = process.env.SEMAFORO_PASS;

const RPC = {
  evaluar: 'semaforo_evaluar',
  ejecutar: 'semaforo_ejecutar',
  aprobar: 'semaforo_aprobar',
  marcar: 'semaforo_marcar',
  medir: 'semaforo_medir',
};

async function sb(path, opts = {}) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    ...opts,
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      'Content-Type': 'application/json',
      Prefer: 'return=representation',
      ...(opts.headers || {}),
    },
  });
  const text = await res.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch (_e) { data = text; }
  if (!res.ok) throw new Error(`supabase ${res.status}: ${text.slice(0, 400)}`);
  return data;
}

const rpc = (fn, args) => sb(`rpc/${fn}`, { method: 'POST', body: JSON.stringify(args || {}) });

module.exports = async (req, res) => {
  res.setHeader('Content-Type', 'application/json');
  if (req.method !== 'POST') return res.status(405).json({ error: 'solo POST' });
  if (!SUPABASE_URL || !SERVICE_KEY) return res.status(500).json({ error: 'faltan env vars SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY' });
  if (!PASS || req.headers['x-pass'] !== PASS) return res.status(401).json({ error: 'clave invalida' });

  const body = typeof req.body === 'string' ? JSON.parse(req.body || '{}') : (req.body || {});
  const action = body.action;

  try {
    // ---------- LECTURA ----------
    if (action === 'estado') {
      const [estado, pendientes, eventos, run, notifs] = await Promise.all([
        sb('semaforo_estado?select=*&order=color.asc,tasa_entrega.asc'),
        sb('llao_decisions?select=id,tier,decision_at,target_entity_name,context,action_proposed&rule_id=eq.semaforo-n1&ceo_approved=is.null&executed=is.false&order=decision_at.desc&limit=50'),
        sb('loop_events?select=id,event_type,severity,payload,created_at&loop_id=eq.semaforo_n1&order=created_at.desc&limit=40'),
        sb('semaforo_runs?select=*&order=started_at.desc&limit=1'),
        sb('semaforo_notificaciones?select=*&order=created_at.desc&limit=25'),
      ]);
      return res.status(200).json({ ok: true, fuente: 'dropi.guias', estado, pendientes, eventos, notificaciones: notifs, ultimo_run: run[0] || null });
    }

    // ---------- ESCRITURA ----------
    if (action === 'evaluar')  return res.status(200).json({ ok: true, dry_run: true, candidatos: await rpc(RPC.evaluar, { p_dias: body.dias ?? null }) });
    if (action === 'ejecutar') return res.status(200).json({ ok: true, resultado: await rpc(RPC.ejecutar, { p_dias: body.dias ?? null }) });
    if (action === 'medir')    return res.status(200).json({ ok: true, resultado: await rpc(RPC.medir, { p_horas: body.horas ?? 72 }) });

    if (action === 'aprobar') {
      if (!body.decision_id) return res.status(400).json({ error: 'falta decision_id' });
      return res.status(200).json({ ok: true, resultado: await rpc(RPC.aprobar, {
        p_decision_id: body.decision_id, p_aprobado: body.aprobado !== false, p_motivo: body.motivo || null }) });
    }

    if (action === 'marcar') {
      return res.status(200).json({ ok: true, resultado: await rpc(RPC.marcar, {
        p_ciudad: String(body.ciudad || '').toUpperCase().trim(),
        p_transportadora: String(body.transportadora || '').toUpperCase().trim(),
        p_color: body.color, p_tier: body.tier || 2,
        p_motivo: body.motivo || 'marcado manual desde UI',
        p_metrics: body.metrics || {}, p_ejecutar: body.ejecutar !== false }) });
    }

    if (action === 'notificar_enviadas') {
      const out = await sb('semaforo_notificaciones?status=eq.queued&select=id', {
        method: 'PATCH', body: JSON.stringify({ status: 'sent', sent_at: new Date().toISOString() }) });
      return res.status(200).json({ ok: true, marcadas: (out || []).length });
    }

    return res.status(400).json({ error: 'accion desconocida', acciones: Object.keys(RPC).concat(['estado', 'notificar_enviadas']) });
  } catch (e) {
    return res.status(500).json({ ok: false, error: String(e.message || e) });
  }
};
