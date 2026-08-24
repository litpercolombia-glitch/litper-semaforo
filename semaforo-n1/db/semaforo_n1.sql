-- ============================================================
-- ZYNEX SEMAFORO N1 — esquema + tools que ESCRIBEN
-- Proyecto Supabase: gtsivwbnhcawvmsfujby
-- Fuente de verdad UNICA: Dropi (tabla `guias`).
-- PROHIBIDO alimentar el semaforo con atribucion de Meta:
--   21-ago-2026 se confirmo que los 69 adsets devuelven omni_purchase = 0
--   a nivel adset (atribucion CTWA rota). Ver loop_rules.semaforo-fuente-verdad
-- Aplicado en produccion el 21-ago-2026.
-- ============================================================

-- ---------- 1. ESTADO ----------
create table if not exists semaforo_estado (
  id uuid primary key default gen_random_uuid(),
  ciudad text not null,
  transportadora text not null,
  color text not null check (color in ('verde','amarillo','rojo')),
  bloqueado boolean not null default false,
  tasa_entrega numeric, novedad_rate numeric,
  pedidos_ventana int, ventana_dias int,
  motivo text, tier int, decision_id uuid,
  set_by text default 'semaforo_n1', set_at timestamptz default now(),
  expires_at timestamptz,
  unique (ciudad, transportadora)
);
create index if not exists idx_semaforo_estado_color on semaforo_estado(color);

create table if not exists semaforo_notificaciones (
  id uuid primary key default gen_random_uuid(),
  canal text not null default 'inapp', destino text,
  titulo text not null, mensaje text not null,
  severidad text default 'info', decision_id uuid,
  status text not null default 'queued',
  created_at timestamptz default now(), sent_at timestamptz
);
create index if not exists idx_semaforo_notif_status on semaforo_notificaciones(status);

create table if not exists semaforo_runs (
  id uuid primary key default gen_random_uuid(),
  started_at timestamptz default now(), finished_at timestamptz,
  ventana_dias int, candidatos int default 0,
  t1_ejecutadas int default 0, t2_pendientes int default 0, t3_pendientes int default 0,
  outcomes_medidos int default 0, reglas_ajustadas int default 0,
  detalle jsonb default '{}'::jsonb
);

alter table semaforo_estado enable row level security;
alter table semaforo_notificaciones enable row level security;
alter table semaforo_runs enable row level security;

comment on table semaforo_estado is 'ZYNEX Semaforo N1. Fuente de verdad UNICA: guias (Dropi). Prohibido alimentarse de atribucion Meta (omni_purchase adset = 0 confirmado 21-ago-2026).';

-- marcus_outcomes solo aceptaba 7d/14d/30d; el semaforo mide a 72h.
alter table marcus_outcomes drop constraint if exists marcus_outcomes_checkpoint_check;
alter table marcus_outcomes add constraint marcus_outcomes_checkpoint_check
  check (checkpoint = any(array['7d','14d','30d']) or checkpoint ~ '^[0-9]+h$');

-- ---------- 2. REGLAS (aprendibles, viven en loop_rules) ----------
insert into loop_rules (id, rule_type, current_value, reason, changed_by) values
 ('semaforo-rojo-tasa','threshold','{"unit":"ratio","value":0.50}','seed N1','semaforo_n1'),
 ('semaforo-amarillo-tasa','threshold','{"unit":"ratio","value":0.65}','seed N1','semaforo_n1'),
 ('semaforo-min-pedidos','threshold','{"unit":"count","value":10}','seed N1','semaforo_n1'),
 ('semaforo-ventana-dias','threshold','{"unit":"days","value":30}','seed N1','semaforo_n1'),
 ('semaforo-t3-pedidos','threshold','{"unit":"count","value":80}','seed N1: sobre este volumen el bloqueo lo decide el CEO','semaforo_n1'),
 ('semaforo-novedad-rate-alerta','threshold','{"unit":"ratio","value":0.25}','seed N1','semaforo_n1'),
 ('semaforo-fuente-verdad','filter','{"fuente":"dropi","tabla":"guias","prohibido":["meta_omni_purchase","meta_adset_attribution"]}','21 ago 2026: 69 adsets Meta con omni_purchase=0 a nivel adset. Fuente unica = Dropi.','ceo_jeferson')
on conflict (id) do nothing;

-- ---------- 3. LECTURA: evaluar (dry-run, no escribe) ----------
create or replace function semaforo_regla(p_id text, p_default numeric)
returns numeric language sql stable as $$
  select coalesce((select (case when jsonb_typeof(current_value)='object'
    then current_value->>'value' else current_value #>> '{}' end)::numeric
    from loop_rules where id=p_id), p_default);
$$;

create or replace function semaforo_evaluar(p_dias int default null)
returns table(ciudad text, transportadora text, pedidos int, entregados int, fallidos int,
  tasa_entrega numeric, novedad_rate numeric, color text, tier int, motivo text)
language plpgsql stable as $$
declare v_dias int; v_rojo numeric; v_ama numeric; v_min int; v_t3 int; v_nov numeric;
begin
  v_dias := coalesce(p_dias, semaforo_regla('semaforo-ventana-dias',30)::int);
  v_rojo := semaforo_regla('semaforo-rojo-tasa',0.50);
  v_ama  := semaforo_regla('semaforo-amarillo-tasa',0.65);
  v_min  := semaforo_regla('semaforo-min-pedidos',10)::int;
  v_t3   := semaforo_regla('semaforo-t3-pedidos',80)::int;
  v_nov  := semaforo_regla('semaforo-novedad-rate-alerta',0.25);
  return query
  with base as (
    select upper(trim(g.ciudad_destino)) as ciudad, upper(trim(g.transportadora)) as transportadora,
           count(*)::int as pedidos,
           count(*) filter (where g.estado='ENTREGADO')::int as entregados,
           count(*) filter (where g.estado in ('DEVOLUCION','RECHAZADO'))::int as fallidos,
           count(*) filter (where g.tiene_novedad)::int as novedades
    from guias g where g.fecha_creacion >= now() - (v_dias || ' days')::interval
    group by 1,2
  ), calc as (
    select b.*, case when (b.entregados+b.fallidos)>0
      then round(b.entregados::numeric/(b.entregados+b.fallidos),4) end as tasa,
      round(b.novedades::numeric/nullif(b.pedidos,0),4) as nov_rate from base b
  ), col as (
    select c.*, case when c.tasa < v_rojo then 'rojo'
                     when c.tasa < v_ama or c.nov_rate >= v_nov then 'amarillo'
                     else 'verde' end as color from calc c
  )
  select c.ciudad, c.transportadora, c.pedidos, c.entregados, c.fallidos, c.tasa, c.nov_rate, c.color,
    case when c.color='rojo' and c.pedidos >= v_t3 then 3 when c.color='rojo' then 2 else 1 end,
    format('ventana %sd | %s pedidos | tasa %s%% | novedades %s%%', v_dias, c.pedidos,
           round(coalesce(c.tasa,0)*100,1), round(coalesce(c.nov_rate,0)*100,1))
  from col c where c.pedidos >= v_min and c.tasa is not null
  order by (c.color='rojo') desc, c.tasa asc, c.pedidos desc;
end $$;

-- ---------- 4. TOOL QUE ESCRIBE: semaforo_marcar ----------
-- Escribe en: semaforo_estado, guias.metadata, llao_decisions, marcus_actions,
--             loop_events, semaforo_notificaciones, alertas
create or replace function semaforo_marcar(
  p_ciudad text, p_transportadora text, p_color text, p_tier int,
  p_motivo text, p_metrics jsonb, p_ejecutar boolean)
returns jsonb language plpgsql security definer as $$
declare v_dec uuid; v_act uuid; v_guias int := 0; v_sev text; v_prev text;
begin
  v_sev := case p_color when 'rojo' then 'critical' when 'amarillo' then 'warning' else 'info' end;
  select color into v_prev from semaforo_estado where ciudad=p_ciudad and transportadora=p_transportadora;

  insert into llao_decisions (tier, rule_id, context, action_proposed, ceo_approved, executed,
    target_entity_type, target_entity_id, target_entity_name)
  values (p_tier, 'semaforo-n1',
    jsonb_build_object('ciudad',p_ciudad,'transportadora',p_transportadora,'motivo',p_motivo,'color_previo',v_prev) || coalesce(p_metrics,'{}'::jsonb),
    jsonb_build_object('accion','set_semaforo','color',p_color,'bloquear',(p_color='rojo')),
    case when p_tier=1 then true else null end, p_ejecutar,
    'ciudad_carrier', p_ciudad||'|'||p_transportadora, p_ciudad||' / '||p_transportadora)
  returning id into v_dec;

  if p_ejecutar then
    insert into semaforo_estado (ciudad, transportadora, color, bloqueado, tasa_entrega, novedad_rate,
      pedidos_ventana, ventana_dias, motivo, tier, decision_id, set_at)
    values (p_ciudad, p_transportadora, p_color, (p_color='rojo'),
      (p_metrics->>'tasa_entrega')::numeric, (p_metrics->>'novedad_rate')::numeric,
      (p_metrics->>'pedidos')::int, (p_metrics->>'ventana_dias')::int, p_motivo, p_tier, v_dec, now())
    on conflict (ciudad, transportadora) do update set
      color=excluded.color, bloqueado=excluded.bloqueado, tasa_entrega=excluded.tasa_entrega,
      novedad_rate=excluded.novedad_rate, pedidos_ventana=excluded.pedidos_ventana,
      ventana_dias=excluded.ventana_dias, motivo=excluded.motivo, tier=excluded.tier,
      decision_id=excluded.decision_id, set_at=now();

    if p_color in ('rojo','amarillo') then
      update guias set metadata = coalesce(metadata,'{}'::jsonb) || jsonb_build_object(
          'semaforo', jsonb_build_object('color',p_color,'decision_id',v_dec,'marcado_at',now())),
        fecha_actualizacion = now()
      where upper(trim(ciudad_destino))=p_ciudad and upper(trim(transportadora))=p_transportadora
        and estado not in ('ENTREGADO','DEVOLUCION','RECHAZADO');
      get diagnostics v_guias = row_count;
    end if;

    insert into marcus_actions (vertical, tier, description, executor, reversible, status)
    values ('logistica', p_tier,
      format('Semaforo %s -> %s (%s). %s. Guias marcadas: %s', p_ciudad||'/'||p_transportadora, p_color, coalesce(v_prev,'nuevo'), p_motivo, v_guias),
      'semaforo_n1', true, 'executed') returning id into v_act;

    update llao_decisions set executed=true, executed_at=now(),
      execution_response=jsonb_build_object('guias_marcadas',v_guias,'marcus_action_id',v_act,'color_previo',v_prev)
    where id=v_dec;
  end if;

  insert into loop_events (loop_id, event_type, severity, payload)
  values ('semaforo_n1', case when p_ejecutar then 'semaforo_aplicado' else 'semaforo_propuesto' end, v_sev,
    jsonb_build_object('decision_id',v_dec,'ciudad',p_ciudad,'transportadora',p_transportadora,
      'color',p_color,'color_previo',v_prev,'tier',p_tier,'motivo',p_motivo,'guias_marcadas',v_guias) || coalesce(p_metrics,'{}'::jsonb));

  insert into semaforo_notificaciones (canal, destino, titulo, mensaje, severidad, decision_id, status)
  values ('inapp','ceo', format('%s %s / %s', upper(p_color), p_ciudad, p_transportadora),
    format('%s | tier %s | %s | %s', case when p_ejecutar then 'EJECUTADO' else 'REQUIERE APROBACION' end, p_tier, p_motivo,
           case when p_ejecutar then v_guias||' guias en transito marcadas' else 'sin cambios hasta aprobar' end),
    v_sev, v_dec, 'queued');

  if p_color='rojo' then
    insert into alertas (tipo, titulo, mensaje, fuente)
    values ('semaforo_rojo', format('ROJO: %s / %s', p_ciudad, p_transportadora),
      format('tier %s | %s | decision %s', p_tier, p_motivo, v_dec), 'semaforo_n1');
  end if;

  return jsonb_build_object('decision_id',v_dec,'ejecutado',p_ejecutar,'color',p_color,
    'color_previo',v_prev,'tier',p_tier,'guias_marcadas',v_guias);
end $$;

-- NOTA: en produccion `semaforo_marcar` incluye ademas, en la rama `else` (T2/T3),
-- un insert en `litper_decisiones_pendientes` (bandeja donde el CEO ya revisa decisiones)
-- con `accion_sugerida` = el SQL de aprobacion listo para copiar/pegar.

-- ---------- 5. TOOL QUE ESCRIBE: semaforo_ejecutar (el ciclo del agente) ----------
-- NOTA: en produccion arranca con una GUARDIA DE FRESCURA: si `max(guias.fecha_creacion)`
-- esta mas atrasada que `loop_rules.semaforo-max-atraso-datos` (3 dias), aborta el ciclo,
-- escribe un evento critical + una alerta, marca loop_state.last_status='blocked' y
-- devuelve {ok:false, motivo:'datos_desactualizados'}. El agente NO decide a ciegas.
create or replace function semaforo_ejecutar(p_dias int default null)
returns jsonb language plpgsql security definer as $$
declare r record; v_run uuid; v_dias int; v_c int:=0; v_t1 int:=0; v_t2 int:=0; v_t3 int:=0;
        v_prev text; v_res jsonb; v_det jsonb := '[]'::jsonb; v_dup int;
begin
  v_dias := coalesce(p_dias, semaforo_regla('semaforo-ventana-dias',30)::int);
  insert into semaforo_runs (ventana_dias) values (v_dias) returning id into v_run;

  for r in select * from semaforo_evaluar(v_dias) loop
    v_c := v_c + 1;
    select color into v_prev from semaforo_estado where ciudad=r.ciudad and transportadora=r.transportadora;
    -- idempotencia T1: si no cambio el color, no escribe
    if v_prev is not distinct from r.color and r.tier=1 then continue; end if;
    -- anti-spam T2/T3: no re-proponer si ya hay una pendiente de <7d
    if r.tier > 1 then
      select count(*) into v_dup from llao_decisions
        where rule_id='semaforo-n1' and target_entity_id=r.ciudad||'|'||r.transportadora
          and ceo_approved is null and executed=false and decision_at > now()-interval '7 days';
      if v_dup > 0 then continue; end if;
    end if;

    v_res := semaforo_marcar(r.ciudad, r.transportadora, r.color, r.tier, r.motivo,
      jsonb_build_object('tasa_entrega',r.tasa_entrega,'novedad_rate',r.novedad_rate,
        'pedidos',r.pedidos,'entregados',r.entregados,'fallidos',r.fallidos,'ventana_dias',v_dias),
      (r.tier = 1));   -- <<< SOLO TIER 1 SE EJECUTA SOLO
    if r.tier=1 then v_t1:=v_t1+1; elsif r.tier=2 then v_t2:=v_t2+1; else v_t3:=v_t3+1; end if;
    v_det := v_det || v_res;
  end loop;

  update semaforo_runs set finished_at=now(), candidatos=v_c, t1_ejecutadas=v_t1,
    t2_pendientes=v_t2, t3_pendientes=v_t3, detalle=jsonb_build_object('acciones',v_det) where id=v_run;

  update loop_state set last_run_at=now(), last_status='ok',
    last_output=jsonb_build_object('run_id',v_run,'candidatos',v_c,'t1',v_t1,'t2',v_t2,'t3',v_t3),
    updated_at=now() where id='semaforo_n1';
  if not found then
    insert into loop_state (id,last_run_at,last_status,last_output)
    values ('semaforo_n1',now(),'ok',jsonb_build_object('run_id',v_run,'candidatos',v_c,'t1',v_t1,'t2',v_t2,'t3',v_t3));
  end if;

  return jsonb_build_object('run_id',v_run,'ventana_dias',v_dias,'candidatos',v_c,
    't1_ejecutadas',v_t1,'t2_pendientes',v_t2,'t3_pendientes',v_t3,'acciones',v_det);
end $$;

-- ---------- 6. TOOL QUE ESCRIBE: semaforo_aprobar (T2/T3, un click) ----------
create or replace function semaforo_aprobar(p_decision_id uuid, p_aprobado boolean, p_motivo text default null)
returns jsonb language plpgsql security definer as $$
declare d record; v_res jsonb;
begin
  select * into d from llao_decisions where id=p_decision_id and rule_id='semaforo-n1';
  if not found then return jsonb_build_object('error','decision no encontrada'); end if;
  if d.executed then return jsonb_build_object('error','ya ejecutada','decision_id',p_decision_id); end if;

  update llao_decisions set ceo_approved=p_aprobado, ceo_approved_at=now(),
    ceo_rejection_reason=case when p_aprobado then null else p_motivo end where id=p_decision_id;

  insert into loop_events (loop_id,event_type,severity,payload)
  values ('semaforo_n1', case when p_aprobado then 'ceo_aprobo' else 'ceo_rechazo' end,
    case when p_aprobado then 'info' else 'warning' end,
    jsonb_build_object('decision_id',p_decision_id,'motivo',p_motivo,'target',d.target_entity_name));

  if not p_aprobado then
    insert into loop_learnings (category, lesson, evidence, source_loop)
    values ('semaforo', format('CEO rechazo %s -> %s', d.target_entity_name, d.action_proposed->>'color'),
      coalesce(p_motivo,'sin motivo'), 'semaforo_n1');
    return jsonb_build_object('decision_id',p_decision_id,'aprobado',false);
  end if;

  v_res := semaforo_marcar(d.context->>'ciudad', d.context->>'transportadora',
    d.action_proposed->>'color', d.tier, coalesce(p_motivo, d.context->>'motivo')||' [aprobado CEO]',
    d.context - 'ciudad' - 'transportadora' - 'motivo' - 'color_previo', true);
  update llao_decisions set executed=true, executed_at=now(),
    execution_response=jsonb_build_object('via','aprobacion_ceo','child_decision',v_res->>'decision_id')
  where id=p_decision_id;
  return jsonb_build_object('decision_id',p_decision_id,'aprobado',true,'resultado',v_res);
end $$;

-- ---------- 7. LOOP DE APRENDIZAJE: semaforo_medir ----------
-- Escribe en: marcus_outcomes, loop_learnings, loop_events, loop_rules (auto-calibracion)
create or replace function semaforo_medir(p_horas int default 72)
returns jsonb language plpgsql security definer as $$
declare d record; v_act uuid; v_pre numeric; v_post numeric; v_n int; v_ok boolean;
        v_medidos int:=0; v_reglas int:=0; v_det jsonb:='[]'::jsonb;
        v_tot int; v_exitos int; v_rate numeric; v_ama numeric; v_new numeric;
begin
  for d in
    select l.*, (l.execution_response->>'marcus_action_id')::uuid as act_id
    from llao_decisions l
    where l.rule_id='semaforo-n1' and l.executed=true
      and l.executed_at <= now() - (p_horas||' hours')::interval
      and l.execution_response ? 'marcus_action_id'
      and not exists (select 1 from marcus_outcomes o
                      where o.action_id=(l.execution_response->>'marcus_action_id')::uuid
                        and o.checkpoint = p_horas||'h')
  loop
    v_act := d.act_id;
    v_pre := (d.context->>'tasa_entrega')::numeric;
    select count(*) filter (where estado in ('ENTREGADO','DEVOLUCION','RECHAZADO')),
           round(count(*) filter (where estado='ENTREGADO')::numeric
             / nullif(count(*) filter (where estado in ('ENTREGADO','DEVOLUCION','RECHAZADO')),0),4)
      into v_n, v_post
    from guias
    where upper(trim(ciudad_destino))=d.context->>'ciudad'
      and upper(trim(transportadora))=d.context->>'transportadora'
      and fecha_creacion >= d.executed_at;

    if v_n is null or v_n < 3 then v_ok := null;                 -- muestra insuficiente: no inventa veredicto
    elsif (d.action_proposed->>'color') in ('rojo','amarillo') then v_ok := coalesce(v_post,0) > coalesce(v_pre,0);
    else v_ok := coalesce(v_post,0) >= semaforo_regla('semaforo-amarillo-tasa',0.65);
    end if;

    insert into marcus_outcomes (action_id, checkpoint, delta_metric, judged_success, notes)
    values (v_act, p_horas||'h',
      jsonb_build_object('tasa_pre',v_pre,'tasa_post',v_post,'delta',coalesce(v_post,0)-coalesce(v_pre,0),
        'muestra_post',v_n,'color',d.action_proposed->>'color','target',d.target_entity_name),
      v_ok, format('semaforo_n1 %s: %s guias terminales post-decision', d.target_entity_name, coalesce(v_n,0)));
    v_medidos := v_medidos + 1;

    insert into loop_learnings (category, lesson, evidence, source_loop)
    values ('semaforo',
      format('%s marcado %s: tasa %s -> %s (%s)', d.target_entity_name, d.action_proposed->>'color',
             coalesce(v_pre,0), coalesce(v_post,0),
             case when v_ok is null then 'sin muestra' when v_ok then 'mejoro' else 'no mejoro' end),
      format('decision %s | muestra %s', d.id, coalesce(v_n,0)), 'semaforo_n1');

    insert into loop_events (loop_id,event_type,severity,payload)
    values ('semaforo_n1','outcome_medido', case when v_ok is false then 'warning' else 'info' end,
      jsonb_build_object('decision_id',d.id,'action_id',v_act,'checkpoint',p_horas||'h',
        'tasa_pre',v_pre,'tasa_post',v_post,'judged_success',v_ok));
    v_det := v_det || jsonb_build_object('decision_id',d.id,'tasa_pre',v_pre,'tasa_post',v_post,'success',v_ok);
  end loop;

  -- AUTO-CALIBRACION: si el agente se equivoca, baja su propio umbral; si acierta mucho, lo sube.
  select count(*), count(*) filter (where judged_success) into v_tot, v_exitos
  from marcus_outcomes where notes like 'semaforo_n1%' and judged_success is not null;
  if v_tot >= 5 then
    v_rate := v_exitos::numeric / v_tot;
    v_ama := semaforo_regla('semaforo-amarillo-tasa',0.65);
    v_new := case when v_rate < 0.40 then greatest(v_ama-0.02,0.55)
                  when v_rate > 0.80 then least(v_ama+0.02,0.80) else v_ama end;
    if v_new <> v_ama then
      update loop_rules set previous_value=current_value,
        current_value=jsonb_build_object('unit','ratio','value',v_new),
        reason=format('auto-calibracion: %s/%s outcomes exitosos (%s%%)',v_exitos,v_tot,round(v_rate*100,1)),
        changed_by='semaforo_medir', changed_at=now()
      where id='semaforo-amarillo-tasa';
      v_reglas := 1;
      insert into loop_events (loop_id,event_type,severity,payload)
      values ('semaforo_n1','regla_ajustada','info',
        jsonb_build_object('regla','semaforo-amarillo-tasa','antes',v_ama,'ahora',v_new,'success_rate',v_rate));
    end if;
  end if;

  update semaforo_runs set outcomes_medidos=v_medidos, reglas_ajustadas=v_reglas
  where id=(select id from semaforo_runs order by started_at desc limit 1);

  return jsonb_build_object('outcomes_medidos',v_medidos,'reglas_ajustadas',v_reglas,
    'success_rate_hist', case when v_tot>0 then round(v_exitos::numeric/v_tot,3) end,
    'muestra_hist',v_tot,'detalle',v_det);
end $$;
