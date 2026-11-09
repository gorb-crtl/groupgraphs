-- GroupGraphs: group comments and "further constraints" (house rules) for each question.
-- Already ran setup.sql before? Paste just this file into Supabase > SQL Editor and press Run.
-- (setup.sql includes it too, so new installs don't need this step.)

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
