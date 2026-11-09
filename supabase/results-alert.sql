-- GroupGraphs: "Results are in" alerts.
-- Run once in Supabase > SQL Editor (setup.sql already includes it for new databases).
--
-- When the last member of a group answers today's question, everyone else in the group who turned
-- on notifications gets "Everyone answered. The results are in." The app calls check_group_done()
-- right after an answer is saved; the reminder GitHub Action sends the pushes.

create table if not exists group_alerts (
  id bigint generated always as identity primary key,
  group_id uuid not null references groups(id) on delete cascade,
  qid text not null check (char_length(qid) <= 64),
  by_id uuid references people(id) on delete set null,
  pushed boolean not null default false,
  created_at timestamptz not null default now(),
  unique (group_id, qid)
);
alter table group_alerts enable row level security;

-- Called after I answer: for each of my groups (2+ people) where everyone has now answered this question,
-- and my answer is from today (Central time), queue one alert. Returns how many groups just finished.
create or replace function check_group_done(p_secret uuid, p_qid text) returns int
language plpgsql security definer set search_path = public as $$
declare p people := gg_me(p_secret); n int;
begin
  if not exists (select 1 from answers where person_id = p.id and qid = p_qid
                 and created_at >= ((now() at time zone 'America/Chicago')::date::timestamp at time zone 'America/Chicago')) then return 0; end if;
  insert into group_alerts (group_id, qid, by_id)
  select gm.group_id, p_qid, p.id from group_members gm
  where gm.person_id = p.id
    and (select count(*) from group_members x where x.group_id = gm.group_id) >= 2
    and not exists (select 1 from group_members x where x.group_id = gm.group_id
                    and not exists (select 1 from answers a where a.person_id = x.person_id and a.qid = p_qid))
  on conflict (group_id, qid) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- For the notification sender: alerts from the last 6 hours not sent yet, with everyone's devices except the last answerer's.
create or replace function alerts_due(p_key text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not gg_sender_ok(p_key) then raise exception 'forbidden'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', al.id, 'group', g.name,
            'by', (select display_name from people where id = al.by_id),
            'subs', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'sub', s.sub)), '[]'::jsonb)
                     from push_subs s join group_members gm on gm.person_id = s.person_id and gm.group_id = al.group_id
                     where s.person_id is distinct from al.by_id))), '[]'::jsonb)
    from group_alerts al join groups g on g.id = al.group_id
    where not al.pushed and al.created_at > now() - interval '6 hours');
end $$;

create or replace function alerts_done(p_key text, p_ids jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not gg_sender_ok(p_key) then raise exception 'forbidden'; end if;
  update group_alerts set pushed = true where id in (select x::bigint from jsonb_array_elements_text(coalesce(p_ids, '[]'::jsonb)) x);
end $$;

revoke all on function check_group_done(uuid, text), alerts_due(text), alerts_done(text, jsonb) from public, anon, authenticated;
grant execute on function check_group_done(uuid, text), alerts_due(text), alerts_done(text, jsonb) to anon, authenticated;
