-- Golazo Infinito · ranking público
-- Pega este archivo entero en Supabase → SQL Editor → Run.
-- Se puede ejecutar varias veces: no borra datos.

create extension if not exists pgcrypto with schema extensions;

-- Jugadores ------------------------------------------------------------------
-- Cada nombre es único sin distinguir mayúsculas. El dispositivo guarda un
-- token secreto; aquí solo se guarda su hash, así nadie puede jugar con tu nombre.
create table if not exists public.players (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  token_hash  text not null,
  created_at  timestamptz not null default now(),
  constraint players_name_format check (name ~ '^[A-Za-z0-9ÁÉÍÓÚÜÑáéíóúüñ_.-]{3,16}$')
);
create unique index if not exists players_name_lower_idx on public.players (lower(name));

-- Partidas -------------------------------------------------------------------
create table if not exists public.scores (
  id           bigint generated always as identity primary key,
  player_id    uuid not null references public.players(id) on delete cascade,
  score        integer not null check (score >= 0),
  goals        integer not null check (goals >= 0),
  best_streak  integer not null check (best_streak >= 0),
  created_at   timestamptz not null default now()
);
create index if not exists scores_player_idx  on public.scores (player_id, score desc);
create index if not exists scores_created_idx on public.scores (created_at);

-- Las tablas no se pueden leer ni escribir directamente desde el navegador:
-- todo pasa por las funciones de abajo, que validan cada petición.
alter table public.players enable row level security;
alter table public.scores  enable row level security;
revoke all on public.players, public.scores from anon, authenticated;

-- ¿Está libre este nombre? ------------------------------------------------------
create or replace function public.name_available(p_name text)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select not exists (select 1 from players where lower(name) = lower(trim(p_name)));
$$;

-- Crear jugador: devuelve { id, name, token } ---------------------------------
create or replace function public.register_player(p_name text)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  v_name  text := trim(p_name);
  v_token text;
  v_id    uuid;
begin
  if v_name is null or v_name !~ '^[A-Za-z0-9ÁÉÍÓÚÜÑáéíóúüñ_.-]{3,16}$' then
    raise exception 'invalid_name' using errcode = 'P0001';
  end if;
  if exists (select 1 from players where lower(name) = lower(v_name)) then
    raise exception 'name_taken' using errcode = 'P0001';
  end if;
  v_token := encode(gen_random_bytes(24), 'hex');
  insert into players (name, token_hash)
  values (v_name, encode(digest(v_token, 'sha256'), 'hex'))
  returning id into v_id;
  return json_build_object('id', v_id, 'name', v_name, 'token', v_token);
exception
  when unique_violation then
    raise exception 'name_taken' using errcode = 'P0001';
end;
$$;

-- Guardar una partida: devuelve { best, rank, week_rank } ------------------------
create or replace function public.submit_score(p_player uuid, p_token text, p_score int, p_goals int, p_streak int)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  v_hash  text;
  v_last  timestamptz;
  v_best  int;
  v_wbest int;
begin
  select token_hash into v_hash from players where id = p_player;
  if v_hash is null or v_hash <> encode(digest(coalesce(p_token, ''), 'sha256'), 'hex') then
    raise exception 'bad_token' using errcode = 'P0001';
  end if;
  -- límites de lo que el juego puede dar: ~28.000 puntos por gol como máximo
  if p_score is null or p_goals is null or p_streak is null
     or p_score < 0 or p_goals < 0 or p_streak < 0
     or p_goals > 3000 or p_streak > p_goals or p_score > p_goals * 30000 then
    raise exception 'bad_score' using errcode = 'P0001';
  end if;
  select max(created_at) into v_last from scores where player_id = p_player;
  if v_last is not null and v_last > now() - interval '5 seconds' then
    raise exception 'too_fast' using errcode = 'P0001';
  end if;

  insert into scores (player_id, score, goals, best_streak)
  values (p_player, p_score, p_goals, p_streak);

  select max(score) into v_best  from scores where player_id = p_player;
  select max(score) into v_wbest from scores where player_id = p_player and created_at >= now() - interval '7 days';

  return json_build_object(
    'best', v_best,
    'rank', 1 + (select count(*) from (select max(score) s from scores group by player_id) t where t.s > v_best),
    'week_rank', 1 + (select count(*) from (select max(score) s from scores where created_at >= now() - interval '7 days' group by player_id) t where t.s > v_wbest)
  );
end;
$$;

-- Ranking: mejor partida de cada jugador ('week' = últimos 7 días, 'all' = siempre)
create or replace function public.get_leaderboard(p_period text default 'all', p_limit int default 50)
returns table (rank bigint, name text, score int, goals int, best_streak int, achieved_at timestamptz)
language sql stable security definer
set search_path = public
as $$
  with best as (
    select distinct on (sc.player_id) sc.player_id, sc.score, sc.goals, sc.best_streak, sc.created_at
    from scores sc
    where p_period is distinct from 'week' or sc.created_at >= now() - interval '7 days'
    order by sc.player_id, sc.score desc, sc.created_at asc
  )
  select rank() over (order by b.score desc), p.name, b.score, b.goals, b.best_streak, b.created_at
  from best b
  join players p on p.id = b.player_id
  order by b.score desc, b.created_at asc
  limit least(greatest(coalesce(p_limit, 50), 1), 100);
$$;

-- Posición de un jugador aunque no salga en el top: { rank, score } o null
create or replace function public.get_player_standing(p_player uuid, p_period text default 'all')
returns json
language sql stable security definer
set search_path = public
as $$
  with best as (
    select player_id, max(score) s
    from scores
    where p_period is distinct from 'week' or created_at >= now() - interval '7 days'
    group by player_id
  ), me as (
    select s from best where player_id = p_player
  )
  select json_build_object('rank', 1 + (select count(*) from best where best.s > me.s), 'score', me.s)
  from me;
$$;

-- Solo estas funciones son públicas ---------------------------------------------
revoke all on function public.name_available(text)                    from public;
revoke all on function public.register_player(text)                   from public;
revoke all on function public.submit_score(uuid, text, int, int, int) from public;
revoke all on function public.get_leaderboard(text, int)              from public;
revoke all on function public.get_player_standing(uuid, text)         from public;

grant execute on function public.name_available(text)                    to anon, authenticated;
grant execute on function public.register_player(text)                   to anon, authenticated;
grant execute on function public.submit_score(uuid, text, int, int, int) to anon, authenticated;
grant execute on function public.get_leaderboard(text, int)              to anon, authenticated;
grant execute on function public.get_player_standing(uuid, text)         to anon, authenticated;

-- =============================================================================
-- Modo torneo: ranking propio y reto diario
-- =============================================================================

-- Una fila por torneo jugado. kind = 'rogue' (torneo normal) o 'daily' (reto del día).
-- stage: 0-2 grupos, 3 cuartos, 4 semis, 5 final, 6 campeón.
create table if not exists public.rogue_runs (
  id            bigint generated always as identity primary key,
  player_id     uuid not null references public.players(id) on delete cascade,
  kind          text not null check (kind in ('rogue', 'daily')),
  day           date,
  seed_version  smallint not null default 1,
  status        text not null default 'started' check (status in ('started', 'finished')),
  score         integer not null default 0 check (score >= 0),
  goals         integer not null default 0 check (goals >= 0),
  best_streak   integer not null default 0 check (best_streak >= 0),
  stage         smallint not null default 0 check (stage between 0 and 6),
  started_at    timestamptz not null default now(),
  finished_at   timestamptz,
  constraint rogue_daily_has_day check ((kind = 'daily') = (day is not null))
);
-- un solo intento de reto diario por jugador y día
create unique index if not exists rogue_daily_once on public.rogue_runs (player_id, day) where kind = 'daily';
create index if not exists rogue_runs_kind_idx on public.rogue_runs (kind, score desc);
create index if not exists rogue_runs_day_idx  on public.rogue_runs (day, score desc) where kind = 'daily';

alter table public.rogue_runs enable row level security;
revoke all on public.rogue_runs from anon, authenticated;

-- El día del reto se cuenta en hora de Madrid
create or replace function public._golazo_today()
returns date
language sql stable
as $$ select (now() at time zone 'Europe/Madrid')::date; $$;

-- Comprueba el token del jugador (solo la usan las funciones de abajo)
create or replace function public._golazo_check(p_player uuid, p_token text)
returns void
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_hash text;
begin
  select token_hash into v_hash from players where id = p_player;
  if v_hash is null or v_hash <> encode(digest(coalesce(p_token, ''), 'sha256'), 'hex') then
    raise exception 'bad_token' using errcode = 'P0001';
  end if;
end;
$$;

-- Límites de lo que un torneo puede dar (goles, multiplicadores, premios y monedas)
create or replace function public._golazo_rogue_ok(p_score int, p_goals int, p_streak int, p_stage int)
returns boolean
language sql immutable
as $$
  select p_score is not null and p_goals is not null and p_streak is not null and p_stage is not null
     and p_score >= 0 and p_goals between 0 and 200 and p_streak between 0 and p_goals
     and p_stage between 0 and 6 and p_score <= p_goals * 60000 + 150000;
$$;

-- Estado del reto de hoy para un jugador: { day, played, score, stage }
create or replace function public.daily_status(p_player uuid)
returns json
language sql stable security definer
set search_path = public
as $$
  select json_build_object(
    'day', _golazo_today(),
    'played', r.id is not null,
    'score', r.score,
    'stage', r.stage
  )
  from (select 1) one
  left join rogue_runs r on r.player_id = p_player and r.kind = 'daily' and r.day = _golazo_today();
$$;

-- Empezar el reto de hoy: { run_id, day } o error already_played
create or replace function public.start_daily(p_player uuid, p_token text)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_id bigint; v_day date := _golazo_today();
begin
  perform _golazo_check(p_player, p_token);
  insert into rogue_runs (player_id, kind, day) values (p_player, 'daily', v_day) returning id into v_id;
  return json_build_object('run_id', v_id, 'day', v_day);
exception
  when unique_violation then raise exception 'already_played' using errcode = 'P0001';
end;
$$;

-- Guardar el progreso del reto. Se puede llamar varias veces mientras se juega
-- (por si se cierra la app); p_final = true lo cierra. Devuelve { rank, players }.
create or replace function public.save_daily(p_player uuid, p_token text, p_run bigint, p_score int, p_goals int, p_streak int, p_stage int, p_final boolean)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_run rogue_runs%rowtype;
begin
  perform _golazo_check(p_player, p_token);
  select * into v_run from rogue_runs where id = p_run and player_id = p_player and kind = 'daily';
  if v_run.id is null then raise exception 'no_run' using errcode = 'P0001'; end if;
  if v_run.status = 'finished' then raise exception 'finished' using errcode = 'P0001'; end if;
  if not _golazo_rogue_ok(p_score, p_goals, p_streak, p_stage) then raise exception 'bad_score' using errcode = 'P0001'; end if;
  -- como mínimo unos 2 segundos por gol desde que empezó
  if extract(epoch from now() - v_run.started_at) < p_goals * 2 then raise exception 'too_fast' using errcode = 'P0001'; end if;
  update rogue_runs set
    score = greatest(score, p_score), goals = greatest(goals, p_goals),
    best_streak = greatest(best_streak, p_streak), stage = greatest(stage, p_stage),
    status = case when p_final then 'finished' else 'started' end,
    finished_at = case when p_final then now() else finished_at end
  where id = p_run;
  return json_build_object(
    'rank', 1 + (select count(*) from rogue_runs where kind = 'daily' and day = v_run.day and score > greatest(v_run.score, p_score)),
    'players', (select count(*) from rogue_runs where kind = 'daily' and day = v_run.day)
  );
end;
$$;

-- Guardar un torneo normal ya terminado: { best, rank, week_rank }
create or replace function public.submit_rogue(p_player uuid, p_token text, p_score int, p_goals int, p_streak int, p_stage int)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_last timestamptz; v_best int; v_wbest int;
begin
  perform _golazo_check(p_player, p_token);
  if not _golazo_rogue_ok(p_score, p_goals, p_streak, p_stage) then raise exception 'bad_score' using errcode = 'P0001'; end if;
  select max(started_at) into v_last from rogue_runs where player_id = p_player and kind = 'rogue';
  if v_last is not null and v_last > now() - interval '5 seconds' then raise exception 'too_fast' using errcode = 'P0001'; end if;
  insert into rogue_runs (player_id, kind, status, score, goals, best_streak, stage, finished_at)
  values (p_player, 'rogue', 'finished', p_score, p_goals, p_streak, p_stage, now());
  select max(score) into v_best  from rogue_runs where player_id = p_player and kind = 'rogue';
  select max(score) into v_wbest from rogue_runs where player_id = p_player and kind = 'rogue' and started_at >= now() - interval '7 days';
  return json_build_object(
    'best', v_best,
    'rank', 1 + (select count(*) from (select max(score) s from rogue_runs where kind = 'rogue' group by player_id) t where t.s > v_best),
    'week_rank', 1 + (select count(*) from (select max(score) s from rogue_runs where kind = 'rogue' and started_at >= now() - interval '7 days' group by player_id) t where t.s > v_wbest)
  );
end;
$$;

-- Ranking del torneo ('week' | 'all') o del reto ('daily', el de hoy): mejor run de cada jugador
create or replace function public.get_rogue_leaderboard(p_mode text default 'all', p_limit int default 50)
returns table (rank bigint, name text, score int, goals int, stage smallint, achieved_at timestamptz)
language sql stable security definer
set search_path = public
as $$
  with best as (
    select distinct on (r.player_id) r.player_id, r.score, r.goals, r.stage, r.started_at
    from rogue_runs r
    where case p_mode
            when 'daily' then r.kind = 'daily' and r.day = _golazo_today() and r.score > 0
            when 'week'  then r.kind = 'rogue' and r.started_at >= now() - interval '7 days'
            else r.kind = 'rogue' end
    order by r.player_id, r.score desc, r.started_at asc
  )
  select rank() over (order by b.score desc), p.name, b.score, b.goals, b.stage, b.started_at
  from best b join players p on p.id = b.player_id
  order by b.score desc, b.started_at asc
  limit least(greatest(coalesce(p_limit, 50), 1), 100);
$$;

-- Posición de un jugador en esos rankings aunque no salga en el top: { rank, score } o null
create or replace function public.get_rogue_standing(p_player uuid, p_mode text default 'all')
returns json
language sql stable security definer
set search_path = public
as $$
  with best as (
    select r.player_id, max(r.score) s
    from rogue_runs r
    where case p_mode
            when 'daily' then r.kind = 'daily' and r.day = _golazo_today() and r.score > 0
            when 'week'  then r.kind = 'rogue' and r.started_at >= now() - interval '7 days'
            else r.kind = 'rogue' end
    group by r.player_id
  ), me as (select s from best where player_id = p_player)
  select json_build_object('rank', 1 + (select count(*) from best where best.s > me.s), 'score', me.s) from me;
$$;

revoke all on function public._golazo_today()                                                   from public;
revoke all on function public._golazo_check(uuid, text)                                         from public;
revoke all on function public._golazo_rogue_ok(int, int, int, int)                              from public;
revoke all on function public.daily_status(uuid)                                                from public;
revoke all on function public.start_daily(uuid, text)                                           from public;
revoke all on function public.save_daily(uuid, text, bigint, int, int, int, int, boolean)        from public;
revoke all on function public.submit_rogue(uuid, text, int, int, int, int)                       from public;
revoke all on function public.get_rogue_leaderboard(text, int)                                  from public;
revoke all on function public.get_rogue_standing(uuid, text)                                    from public;

grant execute on function public.daily_status(uuid)                                         to anon, authenticated;
grant execute on function public.start_daily(uuid, text)                                    to anon, authenticated;
grant execute on function public.save_daily(uuid, text, bigint, int, int, int, int, boolean) to anon, authenticated;
grant execute on function public.submit_rogue(uuid, text, int, int, int, int)                to anon, authenticated;
grant execute on function public.get_rogue_leaderboard(text, int)                           to anon, authenticated;
grant execute on function public.get_rogue_standing(uuid, text)                             to anon, authenticated;
