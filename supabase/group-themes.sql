-- GroupGraphs: Fun Friday themes.
-- Already ran setup.sql before? Paste just this file into Supabase > SQL Editor and press Run.
-- (setup.sql includes it too, so new installs don't need this step.)
--
-- Fun Friday: a group's host picks a theme (science, gaming, nature, business, media, sports, food, custom or random).
-- On Fridays the group gets one extra graph, This or that and Rate it on that theme. Today's questions stay the same for everyone.

create table if not exists group_themes (
  group_id uuid primary key references groups(id) on delete cascade,
  theme text not null check (theme in ('science', 'gaming', 'nature', 'business', 'media', 'sports', 'food', 'custom', 'random')),
  updated_at timestamptz not null default now()
);
alter table group_themes enable row level security;

create or replace function get_group_themes(p_secret uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare p people := gg_me(p_secret);
begin
  return (select coalesce(jsonb_object_agg(t.group_id, t.theme), '{}'::jsonb)
          from group_themes t join group_members gm on gm.group_id = t.group_id
          where gm.person_id = p.id);
end $$;

create or replace function set_group_theme(p_secret uuid, p_group uuid, p_theme text) returns void
language plpgsql security definer set search_path = public as $$
declare p people := gg_me(p_secret);
begin
  if not exists (select 1 from groups where id = p_group and host_id = p.id) then raise exception 'host_only'; end if;
  if p_theme is null or p_theme = '' then
    delete from group_themes where group_id = p_group;
  else
    insert into group_themes (group_id, theme) values (p_group, p_theme)
    on conflict (group_id) do update set theme = excluded.theme, updated_at = now();
  end if;
end $$;

revoke all on function get_group_themes(uuid), set_group_theme(uuid, uuid, text) from public, anon, authenticated;
grant execute on function get_group_themes(uuid), set_group_theme(uuid, uuid, text) to anon, authenticated;
