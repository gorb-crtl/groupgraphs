-- GroupGraphs: feedback about the app.
-- Already ran setup.sql before? Paste just this file into Supabase > SQL Editor and press Run.
-- (setup.sql includes it too, so new installs don't need this step.)
--
-- Members send feedback from inside a group. It goes to the app's owner (the 'owner' username in gg_settings).
-- With no owner set, each group's host reads their own group's feedback.

create table if not exists feedback (
  id bigint generated always as identity primary key,
  person_id uuid not null references people(id) on delete cascade,
  group_id uuid not null references groups(id) on delete cascade,
  kind text not null default 'other' check (kind in ('bug', 'idea', 'other')),
  body text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now()
);
create index if not exists feedback_group on feedback (group_id, created_at);
alter table feedback enable row level security;

create or replace function send_feedback(p_secret uuid, p_group uuid, p_kind text, p_body text) returns void
language plpgsql security definer set search_path = public as $$
declare p people := gg_me(p_secret);
begin
  if not gg_member_of(p.id, p_group) then raise exception 'not_in_group'; end if;
  if (select count(*) from feedback where person_id = p.id and created_at > now() - interval '1 day') >= 20 then raise exception 'slow_down'; end if;
  insert into feedback (person_id, group_id, kind, body)
    values (p.id, p_group, case when p_kind in ('bug', 'idea') then p_kind else 'other' end, left(trim(p_body), 1000));
end $$;

-- The app owner reads everyone's feedback. Running this file makes the host of the oldest group the owner
-- (if no owner is set yet). To change it: update gg_settings set v = 'their_username' where k = 'owner';
insert into gg_settings (k, v)
  select 'owner', pp.username from groups g join people pp on pp.id = g.host_id order by g.created_at limit 1
on conflict (k) do nothing;

create or replace function gg_fb_reader(p people) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select v = p.username from gg_settings where k = 'owner'), exists (select 1 from groups where host_id = p.id));
$$;

create or replace function gg_fb_visible(p people, f_group uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select case when exists (select 1 from gg_settings where k = 'owner') then exists (select 1 from gg_settings where k = 'owner' and v = p.username)
              else exists (select 1 from groups g where g.id = f_group and g.host_id = p.id) end;
$$;

create or replace function get_feedback(p_secret uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare p people := gg_me(p_secret);
begin
  return jsonb_build_object(
    'inbox', (select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'name', pp.display_name, 'username', pp.username, 'group', g.name,
                'kind', f.kind, 'body', f.body, 'at', f.created_at) order by f.created_at desc), '[]'::jsonb)
              from feedback f join groups g on g.id = f.group_id join people pp on pp.id = f.person_id where gg_fb_visible(p, f.group_id)),
    'mine', (select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'kind', f.kind, 'body', f.body, 'at', f.created_at) order by f.created_at desc), '[]'::jsonb)
             from feedback f where f.person_id = p.id),
    'host', gg_fb_reader(p),
    'owner', exists (select 1 from gg_settings where k = 'owner')
  );
end $$;

create or replace function delete_feedback(p_secret uuid, p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare p people := gg_me(p_secret);
begin
  delete from feedback f where f.id = p_id and (f.person_id = p.id or gg_fb_visible(p, f.group_id));
end $$;

revoke all on function send_feedback(uuid, uuid, text, text), get_feedback(uuid), delete_feedback(uuid, bigint) from public, anon, authenticated;
grant execute on function send_feedback(uuid, uuid, text, text), get_feedback(uuid), delete_feedback(uuid, bigint) to anon, authenticated;
