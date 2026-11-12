-- GroupGraphs: GroupDraw, a drawing game for each group.
-- Already ran setup.sql before? Paste just this file into Supabase > SQL Editor and press Run.
-- It only adds two new tables and four functions, so the live app keeps working.
--
-- How it works
--   * Every day there's one scene to draw (picked in the app, the same for everyone). In each group,
--     every member gets a different thing in the scene to draw, dealt in a shuffled order that changes
--     daily. Until someone has drawn, the parts are re-dealt whenever the group's members change.
--   * You only see your own drawing. Everything is shown together once everyone has drawn, when the
--     host reveals it early, or at midnight Central time.
--   * (draw_parts.edges is unused for now and always empty.)

create table if not exists draw_rounds (
  group_id uuid not null references groups(id) on delete cascade,
  day date not null,
  slots uuid[] not null,
  revealed boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (group_id, day)
);

create table if not exists draw_parts (
  group_id uuid not null,
  day date not null,
  person_id uuid not null references people(id) on delete cascade,
  strokes jsonb not null,
  edges jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (group_id, day, person_id),
  foreign key (group_id, day) references draw_rounds(group_id, day) on delete cascade
);

alter table draw_rounds enable row level security;
alter table draw_parts enable row level security;
-- No policies on purpose: only the functions below can read or write these tables.

create or replace function gg_ct_today() returns date language sql stable as $$
  select (now() at time zone 'America/Chicago')::date;
$$;

-- The round for a group and day, made (or re-dealt while nobody has drawn) when needed.
create or replace function gg_draw_round(p_group uuid, p_day date) returns draw_rounds
language plpgsql security definer set search_path = public as $$
declare r draw_rounds; want uuid[]; ct date := gg_ct_today();
begin
  select * into r from draw_rounds where group_id = p_group and day = p_day;
  if p_day < ct or p_day > ct + 1 then return r; end if;   -- only today's round can be made or re-dealt
  if r.group_id is not null and exists (select 1 from draw_parts where group_id = p_group and day = p_day) then return r; end if;
  select array_agg(person_id order by md5(person_id::text || p_day::text)) into want
    from group_members where group_id = p_group;
  if r.group_id is null then
    insert into draw_rounds (group_id, day, slots) values (p_group, p_day, want)
      on conflict (group_id, day) do nothing;
    select * into r from draw_rounds where group_id = p_group and day = p_day;
  elsif not (r.slots @> want and want @> r.slots) then
    update draw_rounds set slots = want where group_id = p_group and day = p_day returning * into r;
  end if;
  return r;
end $$;

create or replace function get_draw(p_secret uuid, p_group uuid, p_day date) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p people := gg_me(p_secret); r draw_rounds; ct date := gg_ct_today(); open_slots int; done_slots int; shown boolean;
begin
  if not gg_member_of(p.id, p_group) then raise exception 'not_in_group'; end if;
  if p_day is null or p_day > ct + 1 then raise exception 'bad_day'; end if;
  r := gg_draw_round(p_group, p_day);
  if r.group_id is null then return jsonb_build_object('day', p_day, 'none', true); end if;
  -- people who left the group don't hold up the reveal
  select count(*), count(dp.person_id) into open_slots, done_slots
    from unnest(r.slots) s(pid)
    left join draw_parts dp on dp.group_id = r.group_id and dp.day = r.day and dp.person_id = s.pid
    where gg_member_of(s.pid, r.group_id) or dp.person_id is not null;
  shown := r.revealed or p_day < ct or done_slots >= open_slots;
  return jsonb_build_object(
    'day', r.day,
    'revealed', shown,
    'host', exists (select 1 from groups where id = r.group_id and host_id = p.id),
    'my_slot', array_position(r.slots, p.id) - 1,
    'slots', (select jsonb_agg(jsonb_build_object(
                'slot', s.i - 1, 'username', pp.username, 'display_name', pp.display_name,
                'drawn', dp.person_id is not null, 'gone', not gg_member_of(s.pid, r.group_id)) order by s.i)
              from unnest(r.slots) with ordinality s(pid, i)
              join people pp on pp.id = s.pid
              left join draw_parts dp on dp.group_id = r.group_id and dp.day = r.day and dp.person_id = s.pid),
    'mine', (select strokes from draw_parts where group_id = r.group_id and day = r.day and person_id = p.id),
    'parts', case when shown then (select coalesce(jsonb_agg(jsonb_build_object('slot', array_position(r.slots, dp.person_id) - 1, 'strokes', dp.strokes)), '[]'::jsonb)
                                   from draw_parts dp where dp.group_id = r.group_id and dp.day = r.day and dp.person_id = any(r.slots)) end,
    'edges', case when not shown then (select coalesce(jsonb_agg(jsonb_build_object('slot', array_position(r.slots, dp.person_id) - 1, 'edges', dp.edges)), '[]'::jsonb)
                                       from draw_parts dp where dp.group_id = r.group_id and dp.day = r.day and dp.person_id = any(r.slots) and dp.person_id <> p.id) end
  );
end $$;

create or replace function save_draw(p_secret uuid, p_group uuid, p_day date, p_strokes jsonb, p_edges jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare p people := gg_me(p_secret); r draw_rounds;
begin
  if not gg_member_of(p.id, p_group) then raise exception 'not_in_group'; end if;
  if jsonb_typeof(p_strokes) <> 'array' or jsonb_typeof(coalesce(p_edges, '[]'::jsonb)) <> 'array' then raise exception 'bad_drawing'; end if;
  if pg_column_size(p_strokes) > 150000 or pg_column_size(p_edges) > 40000 then raise exception 'drawing_too_big'; end if;
  select * into r from draw_rounds where group_id = p_group and day = p_day for update;
  if r.group_id is null or not (p.id = any(r.slots)) then raise exception 'not_your_turn'; end if;
  if r.revealed or p_day < gg_ct_today() then raise exception 'draw_revealed'; end if;
  insert into draw_parts (group_id, day, person_id, strokes, edges) values (p_group, p_day, p.id, p_strokes, coalesce(p_edges, '[]'::jsonb))
  on conflict (group_id, day, person_id) do update set strokes = excluded.strokes, edges = excluded.edges, updated_at = now();
end $$;

-- The host can show the picture before everyone has drawn.
create or replace function reveal_draw(p_secret uuid, p_group uuid, p_day date) returns void
language plpgsql security definer set search_path = public as $$
declare p people := gg_me(p_secret);
begin
  if not exists (select 1 from groups where id = p_group and host_id = p.id) then raise exception 'host_only'; end if;
  update draw_rounds set revealed = true where group_id = p_group and day = p_day;
end $$;

revoke all on function gg_ct_today(), gg_draw_round(uuid, date) from public, anon, authenticated;
revoke all on function get_draw(uuid, uuid, date), save_draw(uuid, uuid, date, jsonb, jsonb), reveal_draw(uuid, uuid, date) from public, anon, authenticated;
grant execute on function get_draw(uuid, uuid, date), save_draw(uuid, uuid, date, jsonb, jsonb), reveal_draw(uuid, uuid, date) to anon, authenticated;
