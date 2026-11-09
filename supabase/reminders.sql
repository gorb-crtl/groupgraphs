-- GroupGraphs: daily reminder notifications.
-- Already ran setup.sql before? Paste just this file into Supabase > SQL Editor and press Run.
-- (setup.sql includes it too, so new installs don't need this step.)
--
-- Each device that turns on notifications stores its push subscription, time zone and the hour it wants
-- the reminder. A GitHub Action (.github/workflows/reminders.yml) runs every hour, asks push_due() who is
-- due, sends the pushes, then reports back with push_done(). Only the sender knows the key that unlocks
-- push_due(); its SHA-256 hash is checked below.

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

create or replace function gg_sender_ok(p_key text) returns boolean language sql immutable as $$
  select encode(sha256(convert_to(coalesce(p_key, ''), 'UTF8')), 'hex') = '68ab0582ad9d3d69d1764279c1a38753b3a7815a4a5d14d7e2d7efaf0d6fc219';
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
  push_due(text), push_done(text, jsonb, jsonb) from public, anon, authenticated;
grant execute on function save_push(uuid, jsonb, text, int), delete_push(uuid, text),
  push_due(text), push_done(text, jsonb, jsonb) to anon, authenticated;
