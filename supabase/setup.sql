-- GroupGraphs: Supabase database setup
-- Paste this whole file into Supabase > SQL Editor > New query, then press Run.
--
-- How it works
--   * Everyone makes a profile once: a unique username (like @garrett) and a display name.
--     They get a personal code (like K7PQ2M) to sign back in on another phone.
--     The app keeps a secret token on the device so people stay signed in.
--   * Groups are permanent rooms, like a group chat. The person who creates one is its host.
--     Friends send the host their username; the host searches for it and adds them.
--     People can be in more than one group.
--   * You answer each daily question once. Every group you're in sees that answer.
--   * Tables are locked (row level security, no policies). The app can only call the
--     functions below. get_results() refuses to show a group's answers to anyone who has
--     not answered that question themselves.

create extension if not exists pgcrypto;

create table if not exists people (
  id uuid primary key default gen_random_uuid(),
  username text not null check (username ~ '^[a-z0-9_.]{3,20}$'),
  display_name text not null check (char_length(display_name) between 1 and 24),
  personal_code text not null unique,
  secret uuid not null unique default gen_random_uuid(),
  created_at timestamptz not null default now()
);
create unique index if not exists people_username on people (username);

create table if not exists groups (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 40),
  host_id uuid not null references people(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists group_members (
  group_id uuid not null references groups(id) on delete cascade,
  person_id uuid not null references people(id) on delete cascade,
  added_at timestamptz not null default now(),
  primary key (group_id, person_id)
);
create index if not exists group_members_person on group_members (person_id);

create table if not exists answers (
  person_id uuid not null references people(id) on delete cascade,
  qid text not null check (char_length(qid) <= 64),
  payload jsonb not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (person_id, qid)
);

create table if not exists roasts (
  group_id uuid not null references groups(id) on delete cascade,
  qid text not null,
  lines jsonb not null,
  n int not null,
  created_at timestamptz not null default now(),
  primary key (group_id, qid)
);

alter table people enable row level security;
alter table groups enable row level security;
alter table group_members enable row level security;
alter table answers enable row level security;
alter table roasts enable row level security;
-- No policies on purpose: nobody reads or writes the tables directly.

-- ---------- helpers (not callable from the app) ----------
create or replace function gg_rand_code(n int) returns text language sql volatile as $$
  select string_agg(substr('ABCDEFGHJKMNPQRSTUVWXYZ23456789', 1 + floor(random() * 31)::int, 1), '')
  from generate_series(1, n);
$$;

create or replace function gg_me(p_secret uuid) returns people
language plpgsql stable security definer set search_path = public as $$
declare p people;
begin
  select * into p from people where secret = p_secret;
  if not found then raise exception 'not_signed_in'; end if;
  return p;
end $$;

create or replace function gg_session(p people) returns jsonb language sql stable as $$
  select jsonb_build_object('secret', p.secret, 'id', p.id, 'username', p.username,
                            'display_name', p.display_name, 'personal_code', p.personal_code);
$$;

create or replace function gg_member_of(p_person uuid, p_group uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from group_members where group_id = p_group and person_id = p_person);
$$;

-- ---------- profiles ----------
create or replace function sign_up(p_username text, p_display_name text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p people; u text := lower(trim(both '@ ' from coalesce(p_username, ''))); pc text;
begin
  if u !~ '^[a-z0-9_.]{3,20}$' then raise exception 'bad_username'; end if;
  if coalesce(trim(p_display_name), '') = '' then raise exception 'name_required'; end if;
  if exists (select 1 from people where username = u) then raise exception 'username_taken'; end if;
  loop pc := gg_rand_code(6); exit when not exists (select 1 from people where personal_code = pc); end loop;
  insert into people (username, display_name, personal_code) values (u, left(trim(p_display_name), 24), pc) returning * into p;
  return gg_session(p);
end $$;

create or replace function sign_in(p_username text, p_personal_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p people;
begin
  select * into p from people
  where username = lower(trim(both '@ ' from coalesce(p_username, ''))) and personal_code = upper(trim(p_personal_code));
  if not found then raise exception 'wrong_username_or_code'; end if;
  return gg_session(p);
end $$;

create or replace function rename_me(p_secret uuid, p_display_name text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p people := gg_me(p_secret);
begin
  if coalesce(trim(p_display_name), '') = '' then raise exception 'name_required'; end if;
  update people set display_name = left(trim(p_display_name), 24) where id = p.id returning * into p;
  return gg_session(p);
end $$;

-- ---------- groups ----------
create or replace function create_group(p_secret uuid, p_name text) returns uuid
language plpgsql security definer set search_path = public as $$
declare p people := gg_me(p_secret); gid uuid;
begin
  if coalesce(trim(p_name), '') = '' then raise exception 'name_required'; end if;
  insert into groups (name, host_id) values (left(trim(p_name), 40), p.id) returning id into gid;
  insert into group_members (group_id, person_id) values (gid, p.id);
  return gid;
end $$;

-- Search people by username so the host can add them (exact-prefix match, max 8 results).
create or replace function find_people(p_secret uuid, p_query text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare p people := gg_me(p_secret); q text := lower(trim(both '@ ' from coalesce(p_query, '')));
begin
  if length(q) < 2 then return '[]'::jsonb; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('username', username, 'display_name', display_name) order by username), '[]'::jsonb)
          from (select username, display_name from people where username like q || '%' order by username limit 8) s);
end $$;

create or replace function add_member(p_secret uuid, p_group uuid, p_username text) returns void
language plpgsql security definer set search_path = public as $$
declare p people := gg_me(p_secret); other uuid;
begin
  if not exists (select 1 from groups where id = p_group and host_id = p.id) then raise exception 'host_only'; end if;
  select id into other from people where username = lower(trim(both '@ ' from coalesce(p_username, '')));
  if other is null then raise exception 'user_not_found'; end if;
  if (select count(*) from group_members where group_id = p_group) >= 30 then raise exception 'group_full'; end if;
  insert into group_members (group_id, person_id) values (p_group, other) on conflict do nothing;
end $$;

create or replace function remove_member(p_secret uuid, p_group uuid, p_username text) returns void
language plpgsql security definer set search_path = public as $$
declare p people := gg_me(p_secret); other people;
begin
  select * into other from people where username = lower(trim(both '@ ' from coalesce(p_username, '')));
  if other.id is null then raise exception 'user_not_found'; end if;
  -- the host can remove anyone; anyone can remove themselves (leave)
  if other.id <> p.id and not exists (select 1 from groups where id = p_group and host_id = p.id) then raise exception 'host_only'; end if;
  if exists (select 1 from groups where id = p_group and host_id = other.id) then raise exception 'host_cannot_leave'; end if;
  delete from group_members where group_id = p_group and person_id = other.id;
end $$;

-- Your groups, with members and how many of them answered each question (no answers revealed).
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
        'members', (select jsonb_agg(jsonb_build_object('username', pp.username, 'display_name', pp.display_name) order by gm2.added_at)
                    from group_members gm2 join people pp on pp.id = gm2.person_id where gm2.group_id = gr.id),
        'counts', (select coalesce(jsonb_object_agg(qid, n), '{}'::jsonb) from (
                    select a.qid, count(*) n from answers a join group_members gm3 on gm3.person_id = a.person_id
                    where gm3.group_id = gr.id group by a.qid) s)
      ) g
      from groups gr join group_members gm on gm.group_id = gr.id and gm.person_id = p.id) x)
  );
end $$;

-- ---------- answers ----------
create or replace function submit_answer(p_secret uuid, p_qid text, p_payload jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare p people := gg_me(p_secret);
begin
  if pg_column_size(p_payload) > 8000 then raise exception 'answer_too_big'; end if;
  insert into answers (person_id, qid, payload) values (p.id, p_qid, p_payload)
  on conflict (person_id, qid) do update set payload = excluded.payload, updated_at = now();
end $$;

-- A group's answers for one question: only for members, and only once they've answered.
create or replace function get_results(p_secret uuid, p_group uuid, p_qid text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare p people := gg_me(p_secret); answered boolean; cnt int;
begin
  if not gg_member_of(p.id, p_group) then raise exception 'not_in_group'; end if;
  select exists (select 1 from answers where person_id = p.id and qid = p_qid) into answered;
  select count(*) into cnt from answers a join group_members gm on gm.person_id = a.person_id
    where gm.group_id = p_group and a.qid = p_qid;
  if not answered then return jsonb_build_object('answered', false, 'count', cnt); end if;
  return jsonb_build_object(
    'answered', true, 'count', cnt,
    'answers', (select coalesce(jsonb_agg(jsonb_build_object('username', pp.username, 'name', pp.display_name,
                 'payload', a.payload, 'joined', pp.created_at, 'updated_at', a.updated_at) order by pp.created_at), '[]'::jsonb)
                from answers a join group_members gm on gm.person_id = a.person_id join people pp on pp.id = a.person_id
                where gm.group_id = p_group and a.qid = p_qid),
    'roast', (select jsonb_build_object('lines', r.lines, 'n', r.n) from roasts r where r.group_id = p_group and r.qid = p_qid)
  );
end $$;

create or replace function save_roast(p_secret uuid, p_group uuid, p_qid text, p_lines jsonb, p_n int) returns void
language plpgsql security definer set search_path = public as $$
declare p people := gg_me(p_secret);
begin
  if not gg_member_of(p.id, p_group) then raise exception 'not_in_group'; end if;
  if not exists (select 1 from answers where person_id = p.id and qid = p_qid) then raise exception 'answer_first'; end if;
  insert into roasts (group_id, qid, lines, n) values (p_group, p_qid, p_lines, p_n)
  on conflict (group_id, qid) do update set lines = excluded.lines, n = excluded.n, created_at = now();
end $$;

-- ---------- comments and house rules ----------
create table if not exists comments (
  id bigint generated always as identity primary key,
  group_id uuid not null references groups(id) on delete cascade,
  qid text not null check (char_length(qid) <= 64),
  person_id uuid not null references people(id) on delete cascade,
  kind text not null default 'comment' check (kind in ('comment', 'rule')),
  body text not null check (char_length(body) between 1 and 500),
  created_at timestamptz not null default now()
);
create index if not exists comments_group_q on comments (group_id, qid, created_at);
alter table comments enable row level security;

-- Comments are visible to every member of the group, answered or not, so rules can be set before people answer.
create or replace function get_comments(p_secret uuid, p_group uuid, p_qid text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare p people := gg_me(p_secret); host uuid;
begin
  if not gg_member_of(p.id, p_group) then raise exception 'not_in_group'; end if;
  select host_id into host from groups where id = p_group;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'username', pp.username, 'name', pp.display_name,
            'kind', c.kind, 'body', c.body, 'at', c.created_at, 'can_delete', (c.person_id = p.id or host = p.id)) order by c.created_at), '[]'::jsonb)
          from comments c join people pp on pp.id = c.person_id where c.group_id = p_group and c.qid = p_qid);
end $$;

create or replace function post_comment(p_secret uuid, p_group uuid, p_qid text, p_body text, p_kind text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p people := gg_me(p_secret); b text := trim(coalesce(p_body, ''));
begin
  if not gg_member_of(p.id, p_group) then raise exception 'not_in_group'; end if;
  if b = '' then raise exception 'comment_empty'; end if;
  if char_length(b) > 500 then raise exception 'comment_too_long'; end if;
  if (select count(*) from comments where group_id = p_group and qid = p_qid) >= 300 then raise exception 'too_many_comments'; end if;
  insert into comments (group_id, qid, person_id, kind, body)
    values (p_group, p_qid, p.id, case when p_kind = 'rule' then 'rule' else 'comment' end, b);
  return get_comments(p_secret, p_group, p_qid);
end $$;

-- The author or the group's host can delete a comment.
create or replace function delete_comment(p_secret uuid, p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare p people := gg_me(p_secret);
begin
  delete from comments c using groups g
    where c.id = p_id and g.id = c.group_id and (c.person_id = p.id or g.host_id = p.id);
end $$;

revoke all on function get_comments(uuid, uuid, text), post_comment(uuid, uuid, text, text, text), delete_comment(uuid, bigint) from public, anon, authenticated;
grant execute on function get_comments(uuid, uuid, text), post_comment(uuid, uuid, text, text, text), delete_comment(uuid, bigint) to anon, authenticated;

-- ---------- daily reminders ----------
--
-- Each device that turns on notifications stores its push subscription, time zone and the hour it wants
-- the reminder. A GitHub Action (.github/workflows/reminders.yml) runs every hour, asks push_due() who is
-- due, sends the pushes, then reports back with push_done(). Only the sender knows the key that unlocks
-- push_due(); its SHA-256 hash is stored in gg_settings.

create table if not exists push_subs (
  id bigint generated always as identity primary key,
  person_id uuid not null references people(id) on delete cascade,
  endpoint text not null unique check (char_length(endpoint) <= 1000),
  sub jsonb not null,
  tz text not null,
  hour int not null check (hour between 0 and 23),
  last_sent date,
  created_at timestamptz not null default now()
);
create index if not exists push_subs_person on push_subs (person_id);
alter table push_subs enable row level security;

create or replace function save_push(p_secret uuid, p_sub jsonb, p_tz text, p_hour int) returns void
language plpgsql security definer set search_path = public as $$
declare p people := gg_me(p_secret); ep text := p_sub->>'endpoint';
begin
  if ep is null or ep !~ '^https://' or char_length(ep) > 1000 or pg_column_size(p_sub) > 4000 then raise exception 'bad_subscription'; end if;
  perform now() at time zone p_tz; -- raises on an unknown time zone
  if (select count(*) from push_subs where person_id = p.id and endpoint <> ep) >= 10 then raise exception 'too_many_devices'; end if;
  insert into push_subs (person_id, endpoint, sub, tz, hour) values (p.id, ep, p_sub, p_tz, p_hour)
  on conflict (endpoint) do update set person_id = excluded.person_id, sub = excluded.sub, tz = excluded.tz, hour = excluded.hour;
end $$;

create or replace function delete_push(p_secret uuid, p_endpoint text) returns void
language plpgsql security definer set search_path = public as $$
declare p people := gg_me(p_secret);
begin
  delete from push_subs where person_id = p.id and endpoint = p_endpoint;
end $$;

-- The notification keys. Fill these in by opening keys.html on the site and running the SQL it gives you.
create table if not exists gg_settings (k text primary key, v text not null);
alter table gg_settings enable row level security;

create or replace function gg_sender_ok(p_key text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from gg_settings where k = 'sender_hash'
                 and v = encode(sha256(convert_to(coalesce(p_key, ''), 'UTF8')), 'hex'));
$$;

-- The public half of the notification key pair (safe to share; browsers need it to subscribe).
create or replace function push_public_key() returns text
language sql stable security definer set search_path = public as $$
  select v from gg_settings where k = 'vapid_public';
$$;

-- Devices whose reminder hour is now (in their own time zone), not reminded yet today,
-- and whose owner hasn't already answered something today.
create or replace function push_due(p_key text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not gg_sender_ok(p_key) then raise exception 'forbidden'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'sub', s.sub, 'name', pp.display_name)), '[]'::jsonb)
    from push_subs s join people pp on pp.id = s.person_id
    where extract(hour from now() at time zone s.tz) >= s.hour
      and (s.last_sent is null or s.last_sent < (now() at time zone s.tz)::date)
      and not exists (select 1 from answers a where a.person_id = s.person_id
                      and (a.updated_at at time zone s.tz)::date = (now() at time zone s.tz)::date));
end $$;

create or replace function push_done(p_key text, p_sent jsonb, p_gone jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not gg_sender_ok(p_key) then raise exception 'forbidden'; end if;
  update push_subs set last_sent = (now() at time zone tz)::date where id in (select x::bigint from jsonb_array_elements_text(coalesce(p_sent, '[]'::jsonb)) x);
  delete from push_subs where id in (select x::bigint from jsonb_array_elements_text(coalesce(p_gone, '[]'::jsonb)) x);
end $$;

revoke all on function save_push(uuid, jsonb, text, int), delete_push(uuid, text), gg_sender_ok(text),
  push_due(text), push_done(text, jsonb, jsonb), push_public_key() from public, anon, authenticated;
grant execute on function save_push(uuid, jsonb, text, int), delete_push(uuid, text),
  push_due(text), push_done(text, jsonb, jsonb), push_public_key() to anon, authenticated;

-- ---------- all-time group summary ----------
-- Every answer from the group's members, but only for questions the caller has answered
-- themselves, so the summary can't be used to peek at a question you haven't done yet.
create or replace function get_summary(p_secret uuid, p_group uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare p people := gg_me(p_secret);
begin
  if not gg_member_of(p.id, p_group) then raise exception 'not_in_group'; end if;
  return jsonb_build_object(
    'members', (select coalesce(jsonb_agg(jsonb_build_object('username', pp.username, 'name', pp.display_name) order by gm.added_at), '[]'::jsonb)
                from group_members gm join people pp on pp.id = gm.person_id where gm.group_id = p_group),
    'answers', (select coalesce(jsonb_agg(jsonb_build_object('qid', a.qid, 'username', pp.username, 'payload', a.payload)), '[]'::jsonb)
                from answers a join group_members gm on gm.person_id = a.person_id join people pp on pp.id = a.person_id
                where gm.group_id = p_group
                  and a.qid in (select qid from answers where person_id = p.id))
  );
end $$;

revoke all on function get_summary(uuid, uuid) from public, anon, authenticated;
grant execute on function get_summary(uuid, uuid) to anon, authenticated;

-- Only the public functions are callable from the app.
revoke all on all functions in schema public from public, anon, authenticated;
grant execute on function sign_up(text, text), sign_in(text, text), rename_me(uuid, text),
  create_group(uuid, text), find_people(uuid, text), add_member(uuid, uuid, text), remove_member(uuid, uuid, text),
  my_groups(uuid), submit_answer(uuid, text, jsonb), get_results(uuid, uuid, text), save_roast(uuid, uuid, text, jsonb, int),
  get_comments(uuid, uuid, text), post_comment(uuid, uuid, text, text, text), delete_comment(uuid, bigint),
  save_push(uuid, jsonb, text, int), delete_push(uuid, text), push_due(text), push_done(text, jsonb, jsonb), push_public_key(), get_summary(uuid, uuid)
  to anon, authenticated;
