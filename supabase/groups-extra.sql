-- GroupGraphs: rename a group, hand off the host role, delete a group, and the shared midnight (Central time).
-- Already ran setup.sql before? Paste just this file into Supabase > SQL Editor and press Run.
-- (setup.sql includes it too, so new installs don't need this step.)

create or replace function rename_group(p_secret uuid, p_group uuid, p_name text) returns void
language plpgsql security definer set search_path = public as $$
declare p people := gg_me(p_secret); n text := trim(coalesce(p_name, ''));
begin
  if not exists (select 1 from groups where id = p_group and host_id = p.id) then raise exception 'host_only'; end if;
  if char_length(n) not between 1 and 40 then raise exception 'bad_group_name'; end if;
  update groups set name = n where id = p_group;
end $$;

create or replace function transfer_host(p_secret uuid, p_group uuid, p_username text) returns void
language plpgsql security definer set search_path = public as $$
declare p people := gg_me(p_secret); other people;
begin
  if not exists (select 1 from groups where id = p_group and host_id = p.id) then raise exception 'host_only'; end if;
  select * into other from people where username = lower(trim(both '@ ' from coalesce(p_username, '')));
  if other.id is null or not gg_member_of(other.id, p_group) then raise exception 'user_not_found'; end if;
  update groups set host_id = other.id where id = p_group;
end $$;

create or replace function delete_group(p_secret uuid, p_group uuid) returns void
language plpgsql security definer set search_path = public as $$
declare p people := gg_me(p_secret);
begin
  if not exists (select 1 from groups where id = p_group and host_id = p.id) then raise exception 'host_only'; end if;
  delete from groups where id = p_group;
end $$;

-- Question ideas switch over at midnight Central time, same as the app.
create or replace function get_ideas(p_secret uuid, p_group uuid, p_today date) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p people := gg_me(p_secret); d date; pick bigint; ct date := (now() at time zone 'America/Chicago')::date;
begin
  if not gg_member_of(p.id, p_group) then raise exception 'not_in_group'; end if;
  d := least(greatest(coalesce(p_today, ct), ct - 1), ct + 1);
  if not exists (select 1 from ideas where group_id = p_group and day = d) then
    select i.id into pick from ideas i
      where i.group_id = p_group and i.day is null and i.created_at < (d::timestamp at time zone 'America/Chicago')
        and exists (select 1 from idea_votes v where v.idea_id = i.id)
      order by (select count(*) from idea_votes v where v.idea_id = i.id) desc, i.created_at
      limit 1;
    if pick is not null then
      begin
        update ideas set day = d where id = pick;
      exception when unique_violation then null;
      end;
    end if;
  end if;
  return jsonb_build_object(
    'scheduled', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'day', i.day, 'spec', i.spec, 'author', pp.display_name) order by i.day), '[]'::jsonb)
                  from ideas i join people pp on pp.id = i.person_id where i.group_id = p_group and i.day is not null and i.day <= d),
    'pending', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'spec', i.spec, 'author', pp.display_name, 'mine_author', i.person_id = p.id,
                   'votes', (select count(*) from idea_votes v where v.idea_id = i.id),
                   'voted', exists (select 1 from idea_votes v where v.idea_id = i.id and v.person_id = p.id),
                   'created_at', i.created_at) order by i.created_at), '[]'::jsonb)
                from ideas i join people pp on pp.id = i.person_id where i.group_id = p_group and i.day is null)
  );
end $$;

-- Reminders: "already answered today" now means since midnight Central, when the new question appears.
create or replace function push_due(p_key text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not gg_sender_ok(p_key) then raise exception 'forbidden'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'sub', s.sub, 'name', pp.display_name)), '[]'::jsonb)
    from push_subs s join people pp on pp.id = s.person_id
    where extract(hour from now() at time zone s.tz) >= s.hour
      and (s.last_sent is null or s.last_sent < (now() at time zone s.tz)::date)
      and not exists (select 1 from answers a where a.person_id = s.person_id
                      and a.updated_at >= ((now() at time zone 'America/Chicago')::date::timestamp at time zone 'America/Chicago')));
end $$;

revoke all on function rename_group(uuid, uuid, text), transfer_host(uuid, uuid, text), delete_group(uuid, uuid) from public, anon, authenticated;
grant execute on function rename_group(uuid, uuid, text), transfer_host(uuid, uuid, text), delete_group(uuid, uuid),
  get_ideas(uuid, uuid, date) to anon, authenticated;
revoke all on function push_due(text) from public, anon, authenticated;
grant execute on function push_due(text) to anon, authenticated;
