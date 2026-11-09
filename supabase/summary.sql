-- GroupGraphs: all-time group summary.
-- Already ran setup.sql before? Paste just this file into Supabase > SQL Editor and press Run.
-- (setup.sql includes it too, so new installs don't need this step.)

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
