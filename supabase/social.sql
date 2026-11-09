-- GroupGraphs: profile colors, nudges and group streaks.
-- Run once in Supabase > SQL Editor (setup.sql already includes it for new databases).

-- ---------- profile color ----------
-- 1 to 8 picks one of the app's 8 chart colors; null means "pick one for me".
alter table people add column if not exists color int check (color between 1 and 8);

create or replace function gg_session(p people) returns jsonb language sql stable as $$
  select jsonb_build_object('secret', p.secret, 'id', p.id, 'username', p.username,
                            'display_name', p.display_name, 'personal_code', p.personal_code, 'color', p.color);
$$;

create or replace function set_color(p_secret uuid, p_color int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p people := gg_me(p_secret);
begin
  if p_color is not null and (p_color < 1 or p_color > 8) then raise exception 'bad_color'; end if;
  update people set color = p_color where id = p.id returning * into p;
  return gg_session(p);
end $$;

-- ---------- nudges ----------
-- A member pokes someone in the same group who hasn't answered yet, with an optional short message.
-- One nudge per person per friend per day. The friend sees it in the app, and as a phone
-- notification if they turned those on (sent by the same GitHub Action as the reminders).
create table if not exists nudges (
  id bigint generated always as identity primary key,
  group_id uuid not null references groups(id) on delete cascade,
  from_id uuid not null references people(id) on delete cascade,
  to_id uuid not null references people(id) on delete cascade,
  qid text not null check (char_length(qid) <= 64),
  msg text check (char_length(msg) <= 80),
  day date not null default ((now() at time zone 'America/Chicago')::date),
  pushed boolean not null default false,
  seen boolean not null default false,
  created_at timestamptz not null default now(),
  unique (from_id, to_id, day)
);
create index if not exists nudges_to on nudges (to_id, seen);
alter table nudges enable row level security;

create or replace function send_nudge(p_secret uuid, p_group uuid, p_username text, p_qid text, p_msg text) returns void
language plpgsql security definer set search_path = public as $$
declare p people := gg_me(p_secret); other uuid; m text := nullif(left(trim(coalesce(p_msg, '')), 80), '');
begin
  if not gg_member_of(p.id, p_group) then raise exception 'not_in_group'; end if;
  select id into other from people where username = lower(trim(both '@ ' from coalesce(p_username, '')));
  if other is null or not gg_member_of(other, p_group) then raise exception 'user_not_found'; end if;
  if other = p.id then raise exception 'cant_nudge_self'; end if;
  if exists (select 1 from answers where person_id = other and qid = p_qid) then raise exception 'already_answered'; end if;
  if (select count(*) from nudges where from_id = p.id and day = (now() at time zone 'America/Chicago')::date) >= 30 then raise exception 'too_many_nudges'; end if;
  insert into nudges (group_id, from_id, to_id, qid, msg) values (p_group, p.id, other, p_qid, m)
  on conflict (from_id, to_id, day) do nothing;
  if not found then raise exception 'already_nudged'; end if;
end $$;

-- Today's nudges to me that I haven't dismissed (newest first).
create or replace function my_nudges(p_secret uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare p people := gg_me(p_secret);
begin
  return (select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'from', pp.display_name, 'msg', n.msg,
            'group', g.name, 'group_id', g.id, 'qid', n.qid) order by n.created_at desc), '[]'::jsonb)
    from nudges n join people pp on pp.id = n.from_id join groups g on g.id = n.group_id
    where n.to_id = p.id and not n.seen and n.day = (now() at time zone 'America/Chicago')::date
      and not exists (select 1 from answers a where a.person_id = p.id and a.qid = n.qid));
end $$;

create or replace function seen_nudges(p_secret uuid) returns void
language plpgsql security definer set search_path = public as $$
declare p people := gg_me(p_secret);
begin
  update nudges set seen = true where to_id = p.id and not seen;
end $$;

-- For the notification sender: nudges from the last 6 hours not pushed yet, whose target still hasn't answered.
create or replace function nudges_due(p_key text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not gg_sender_ok(p_key) then raise exception 'forbidden'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'from', pp.display_name, 'msg', n.msg, 'group', g.name,
            'subs', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'sub', s.sub)), '[]'::jsonb) from push_subs s where s.person_id = n.to_id))), '[]'::jsonb)
    from nudges n join people pp on pp.id = n.from_id join groups g on g.id = n.group_id
    where not n.pushed and n.created_at > now() - interval '6 hours'
      and not exists (select 1 from answers a where a.person_id = n.to_id and a.qid = n.qid));
end $$;

create or replace function nudges_done(p_key text, p_ids jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not gg_sender_ok(p_key) then raise exception 'forbidden'; end if;
  update nudges set pushed = true where id in (select x::bigint from jsonb_array_elements_text(coalesce(p_ids, '[]'::jsonb)) x);
end $$;

-- ---------- who answered (for the streak and the nudge list) ----------
-- For a list of question ids: which members answered each one and on what day (Central time).
-- No answers are revealed, only who and when. Also: the people I've already nudged today.
create or replace function group_activity(p_secret uuid, p_group uuid, p_qids text[]) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare p people := gg_me(p_secret);
begin
  if not gg_member_of(p.id, p_group) then raise exception 'not_in_group'; end if;
  if coalesce(array_length(p_qids, 1), 0) > 120 then raise exception 'too_many'; end if;
  return jsonb_build_object(
    'created', (select (created_at at time zone 'America/Chicago')::date from groups where id = p_group),
    'members', (select coalesce(jsonb_agg(jsonb_build_object('username', pp.username,
                  'since', (gm.added_at at time zone 'America/Chicago')::date)), '[]'::jsonb)
                from group_members gm join people pp on pp.id = gm.person_id where gm.group_id = p_group),
    'answers', (select coalesce(jsonb_agg(jsonb_build_object('qid', a.qid, 'username', pp.username,
                  'day', (a.created_at at time zone 'America/Chicago')::date)), '[]'::jsonb)
                from answers a join group_members gm on gm.person_id = a.person_id and gm.group_id = p_group
                join people pp on pp.id = a.person_id where a.qid = any(p_qids)),
    'nudged', (select coalesce(jsonb_agg(pp.username), '[]'::jsonb) from nudges n join people pp on pp.id = n.to_id
               where n.from_id = p.id and n.group_id = p_group and n.day = (now() at time zone 'America/Chicago')::date)
  );
end $$;

-- my_groups now includes each member's color.
create or replace function my_groups(p_secret uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare p people := gg_me(p_secret);
begin
  return jsonb_build_object(
    'me', gg_session(p),
    'mine', (select coalesce(jsonb_object_agg(qid, payload), '{}'::jsonb) from answers where person_id = p.id),
    'groups', (select coalesce(jsonb_agg(g order by g->>'created_at'), '[]'::jsonb) from (
      select jsonb_build_object(
        'id', gr.id, 'name', gr.name, 'created_at', gr.created_at,
        'host', (select username from people where id = gr.host_id),
        'members', (select jsonb_agg(jsonb_build_object('username', pp.username, 'display_name', pp.display_name, 'color', pp.color) order by gm2.added_at)
                    from group_members gm2 join people pp on pp.id = gm2.person_id where gm2.group_id = gr.id),
        'counts', (select coalesce(jsonb_object_agg(qid, n), '{}'::jsonb) from (
                    select a.qid, count(*) n from answers a join group_members gm3 on gm3.person_id = a.person_id
                    where gm3.group_id = gr.id group by a.qid) s)
      ) g
      from groups gr join group_members gm on gm.group_id = gr.id and gm.person_id = p.id) x)
  );
end $$;

revoke all on function set_color(uuid, int), send_nudge(uuid, uuid, text, text, text), my_nudges(uuid), seen_nudges(uuid),
  nudges_due(text), nudges_done(text, jsonb), group_activity(uuid, uuid, text[]) from public, anon, authenticated;
grant execute on function set_color(uuid, int), send_nudge(uuid, uuid, text, text, text), my_nudges(uuid), seen_nudges(uuid),
  nudges_due(text), nudges_done(text, jsonb), group_activity(uuid, uuid, text[]) to anon, authenticated;
