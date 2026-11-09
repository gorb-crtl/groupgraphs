-- GroupGraphs: question ideas from the group, with voting.
-- Already ran setup.sql before? Paste just this file into Supabase > SQL Editor and press Run.
-- (setup.sql includes it too, so new installs don't need this step.)
--
-- Anyone in a group can suggest a question (curve, ranking, map or "most likely to") and vote on ideas.
-- At the start of each day, the idea with the most votes (at least one, suggested before that day)
-- becomes the group's question for the day, replacing the usual rotation for that group only.

create table if not exists ideas (
  id bigint generated always as identity primary key,
  group_id uuid not null references groups(id) on delete cascade,
  person_id uuid not null references people(id) on delete cascade,
  spec jsonb not null check (octet_length(spec::text) <= 4000),
  day date,
  created_at timestamptz not null default now()
);
create index if not exists ideas_group on ideas (group_id, day);
create unique index if not exists ideas_group_day on ideas (group_id, day) where day is not null;
alter table ideas enable row level security;

create table if not exists idea_votes (
  idea_id bigint not null references ideas(id) on delete cascade,
  person_id uuid not null references people(id) on delete cascade,
  primary key (idea_id, person_id)
);
alter table idea_votes enable row level security;

create or replace function gg_idea_ok(p_spec jsonb) returns boolean
language sql immutable as $$
  select jsonb_typeof(p_spec) = 'object'
    and p_spec->>'kind' in ('curve', 'rank', 'map', 'people')
    and char_length(coalesce(p_spec->>'title', '')) between 3 and 120
    and (p_spec->>'kind' <> 'rank' or (jsonb_typeof(p_spec->'items') = 'array'
         and jsonb_array_length(p_spec->'items') between 3 and 12))
    and (p_spec->>'kind' <> 'people' or char_length(coalesce(p_spec->>'likely', '')) between 2 and 80)
$$;

create or replace function suggest_question(p_secret uuid, p_group uuid, p_spec jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare p people := gg_me(p_secret); nid bigint;
begin
  if not gg_member_of(p.id, p_group) then raise exception 'not_in_group'; end if;
  if not gg_idea_ok(p_spec) then raise exception 'bad_question'; end if;
  if (select count(*) from ideas where group_id = p_group and person_id = p.id and day is null) >= 5 then raise exception 'too_many_ideas'; end if;
  insert into ideas (group_id, person_id, spec) values (p_group, p.id, p_spec) returning id into nid;
  insert into idea_votes (idea_id, person_id) values (nid, p.id);
  return nid;
end $$;

create or replace function vote_question(p_secret uuid, p_id bigint, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
declare p people := gg_me(p_secret); g uuid;
begin
  select group_id into g from ideas where id = p_id and day is null;
  if g is null or not gg_member_of(p.id, g) then raise exception 'not_found'; end if;
  if p_on then insert into idea_votes (idea_id, person_id) values (p_id, p.id) on conflict do nothing;
  else delete from idea_votes where idea_id = p_id and person_id = p.id; end if;
end $$;

create or replace function delete_question(p_secret uuid, p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare p people := gg_me(p_secret); i ideas;
begin
  select * into i from ideas where id = p_id and day is null;
  if i.id is null or not gg_member_of(p.id, i.group_id) then raise exception 'not_found'; end if;
  if i.person_id <> p.id and (select host_id from groups where id = i.group_id) <> p.id then raise exception 'forbidden'; end if;
  delete from ideas where id = p_id;
end $$;

-- p_today is the caller's local date; it is clamped to within a day of the server's date.
create or replace function get_ideas(p_secret uuid, p_group uuid, p_today date) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p people := gg_me(p_secret); d date; pick bigint;
begin
  if not gg_member_of(p.id, p_group) then raise exception 'not_in_group'; end if;
  d := least(greatest(coalesce(p_today, current_date), current_date - 1), current_date + 1);
  if not exists (select 1 from ideas where group_id = p_group and day = d) then
    select i.id into pick from ideas i
      where i.group_id = p_group and i.day is null and i.created_at < d::timestamp
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

revoke all on function gg_idea_ok(jsonb), suggest_question(uuid, uuid, jsonb), vote_question(uuid, bigint, boolean),
  delete_question(uuid, bigint), get_ideas(uuid, uuid, date) from public, anon, authenticated;
grant execute on function suggest_question(uuid, uuid, jsonb), vote_question(uuid, bigint, boolean),
  delete_question(uuid, bigint), get_ideas(uuid, uuid, date) to anon, authenticated;
