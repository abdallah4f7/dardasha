-- دردشة / Chat — Supabase schema
-- Paste this whole file into Supabase Dashboard → SQL Editor → Run.
-- Safe to run again after updates.

-- ───────────── Profiles ─────────────
-- A profile is created by the app's "complete profile" screen right after sign-up
-- (email, Google, Apple). An auth user without a profile hasn't finished sign-up.
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null check (username ~ '^[a-z0-9_]{3,20}$'),
  display_name text not null,
  avatar_url text,
  created_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
drop policy if exists "profiles_read" on public.profiles;
create policy "profiles_read" on public.profiles for select to authenticated using (true);
drop policy if exists "profiles_insert_own" on public.profiles;
create policy "profiles_insert_own" on public.profiles for insert to authenticated with check (id = auth.uid());
drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own" on public.profiles for update to authenticated using (id = auth.uid());

-- Older versions created profiles from a trigger; the app does it now.
drop trigger if exists on_auth_user_created on auth.users;
drop function if exists public.handle_new_user();

create or replace function public.username_available(name text) returns boolean
language sql security definer stable set search_path = public as $$
  select not exists (select 1 from profiles where username = lower(name));
$$;
grant execute on function public.username_available(text) to anon, authenticated;

-- ───────────── Conversations ─────────────
create table if not exists public.conversations (
  id uuid primary key default gen_random_uuid(),
  is_group boolean not null default false,
  name text,
  avatar_url text,
  created_by uuid references public.profiles(id) on delete set null,
  dm_key text unique,
  last_message_text text,
  last_message_type text,
  last_message_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create table if not exists public.conversation_members (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role text not null default 'member',
  joined_at timestamptz not null default now(),
  primary key (conversation_id, user_id)
);

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  type text not null default 'text'
    check (type in ('text', 'image', 'video', 'voice', 'sticker', 'call', 'file')),
  content text,
  media_url text,
  meta jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists messages_conv_time on public.messages (conversation_id, created_at);

create table if not exists public.reactions (
  message_id uuid not null references public.messages(id) on delete cascade,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  emoji text not null,
  created_at timestamptz not null default now(),
  primary key (message_id, user_id)
);
create index if not exists reactions_conv on public.reactions (conversation_id);

create table if not exists public.saved_stickers (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  url text not null,
  created_at timestamptz not null default now(),
  unique (user_id, url)
);

-- ───────────── Friends ─────────────
create table if not exists public.friendships (
  requester uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  addressee uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted')),
  created_at timestamptz not null default now(),
  primary key (requester, addressee),
  check (requester <> addressee)
);

-- Membership check that bypasses RLS (avoids recursive policies)
create or replace function public.is_member(conv uuid) returns boolean
language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from conversation_members where conversation_id = conv and user_id = auth.uid()
  );
$$;

alter table public.conversations enable row level security;
alter table public.conversation_members enable row level security;
alter table public.messages enable row level security;
alter table public.reactions enable row level security;
alter table public.saved_stickers enable row level security;
alter table public.friendships enable row level security;

drop policy if exists "conv_read" on public.conversations;
create policy "conv_read" on public.conversations for select to authenticated using (public.is_member(id));
drop policy if exists "conv_update" on public.conversations;
create policy "conv_update" on public.conversations for update to authenticated using (public.is_member(id));

drop policy if exists "members_read" on public.conversation_members;
create policy "members_read" on public.conversation_members for select to authenticated
  using (public.is_member(conversation_id));
drop policy if exists "members_add" on public.conversation_members;
create policy "members_add" on public.conversation_members for insert to authenticated
  with check (
    public.is_member(conversation_id)
    and exists (select 1 from public.conversations c where c.id = conversation_id and c.is_group)
  );
drop policy if exists "members_leave" on public.conversation_members;
create policy "members_leave" on public.conversation_members for delete to authenticated
  using (user_id = auth.uid());

drop policy if exists "msg_read" on public.messages;
create policy "msg_read" on public.messages for select to authenticated using (public.is_member(conversation_id));
drop policy if exists "msg_send" on public.messages;
create policy "msg_send" on public.messages for insert to authenticated
  with check (sender_id = auth.uid() and public.is_member(conversation_id));
drop policy if exists "msg_update_own" on public.messages;
create policy "msg_update_own" on public.messages for update to authenticated using (sender_id = auth.uid());
drop policy if exists "msg_delete_own" on public.messages;
create policy "msg_delete_own" on public.messages for delete to authenticated using (sender_id = auth.uid());

drop policy if exists "reactions_read" on public.reactions;
create policy "reactions_read" on public.reactions for select to authenticated using (public.is_member(conversation_id));
drop policy if exists "reactions_write_own" on public.reactions;
create policy "reactions_write_own" on public.reactions for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid() and public.is_member(conversation_id));

drop policy if exists "stickers_own" on public.saved_stickers;
create policy "stickers_own" on public.saved_stickers for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "friends_read" on public.friendships;
create policy "friends_read" on public.friendships for select to authenticated
  using (auth.uid() in (requester, addressee));
drop policy if exists "friends_request" on public.friendships;
create policy "friends_request" on public.friendships for insert to authenticated
  with check (requester = auth.uid() and status = 'pending');
drop policy if exists "friends_accept" on public.friendships;
create policy "friends_accept" on public.friendships for update to authenticated
  using (addressee = auth.uid()) with check (status = 'accepted');
drop policy if exists "friends_remove" on public.friendships;
create policy "friends_remove" on public.friendships for delete to authenticated
  using (auth.uid() in (requester, addressee));

-- Open (or create) the one-to-one chat with another user
create or replace function public.get_or_create_dm(other uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  k text := least(auth.uid()::text, other::text) || ':' || greatest(auth.uid()::text, other::text);
  cid uuid;
begin
  select id into cid from conversations where dm_key = k;
  if cid is null then
    insert into conversations (is_group, dm_key, created_by) values (false, k, auth.uid()) returning id into cid;
    insert into conversation_members (conversation_id, user_id) values (cid, auth.uid());
    if other <> auth.uid() then
      insert into conversation_members (conversation_id, user_id) values (cid, other);
    end if;
  end if;
  return cid;
end $$;

create or replace function public.create_group(group_name text, member_ids uuid[]) returns uuid
language plpgsql security definer set search_path = public as $$
declare cid uuid;
begin
  insert into conversations (is_group, name, created_by) values (true, group_name, auth.uid()) returning id into cid;
  insert into conversation_members (conversation_id, user_id, role) values (cid, auth.uid(), 'admin');
  insert into conversation_members (conversation_id, user_id)
    select cid, m from unnest(member_ids) as m where m <> auth.uid()
    on conflict do nothing;
  return cid;
end $$;

-- Keep the chat list's "last message" up to date
create or replace function public.on_message_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update conversations set
    last_message_text = case when new.type in ('text', 'file') then left(new.content, 120) else null end,
    last_message_type = new.type,
    last_message_at = new.created_at
  where id = new.conversation_id;
  return new;
end $$;

drop trigger if exists messages_after_insert on public.messages;
create trigger messages_after_insert after insert on public.messages
  for each row execute function public.on_message_insert();


-- An edited message updates the chat list if it is the latest one
create or replace function public.on_message_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update conversations set last_message_text = left(new.content, 120)
  where id = new.conversation_id and new.type = 'text' and last_message_at = new.created_at;
  return new;
end $$;

drop trigger if exists messages_after_update on public.messages;
create trigger messages_after_update after update of content on public.messages
  for each row execute function public.on_message_update();

-- Files (documents, archives…) as a message type; their name doubles as the chat-list preview.
alter table public.messages drop constraint if exists messages_type_check;
alter table public.messages add constraint messages_type_check
  check (type in ('text', 'image', 'video', 'voice', 'sticker', 'call', 'file'));

-- ───────────── Group owner ─────────────
-- Whoever creates a group is its owner (role 'admin'): they can remove members,
-- delete anyone's message and delete the group. Name and photo stay editable by every member.
create or replace function public.is_admin(conv uuid) returns boolean
language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from conversation_members where conversation_id = conv and user_id = auth.uid() and role = 'admin'
  );
$$;

drop policy if exists "members_leave" on public.conversation_members;
create policy "members_leave" on public.conversation_members for delete to authenticated
  using (user_id = auth.uid() or public.is_admin(conversation_id));

drop policy if exists "msg_delete_own" on public.messages;
create policy "msg_delete_own" on public.messages for delete to authenticated
  using (sender_id = auth.uid() or public.is_admin(conversation_id));

drop policy if exists "conv_delete_owner" on public.conversations;
create policy "conv_delete_owner" on public.conversations for delete to authenticated
  using (is_group and public.is_admin(id));


-- Owners can make other members owners too, or take it back. The main owner
-- (whoever created the group, or was handed it) can't be demoted or removed by
-- them, and is the only one who can hand the group over.
create or replace function public.is_creator(conv uuid, member uuid) returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from conversations where id = conv and created_by = member);
$$;

drop policy if exists "members_role" on public.conversation_members;
create policy "members_role" on public.conversation_members for update to authenticated
  using (public.is_admin(conversation_id) and not public.is_creator(conversation_id, user_id))
  with check (role in ('admin', 'member'));

drop policy if exists "members_leave" on public.conversation_members;
create policy "members_leave" on public.conversation_members for delete to authenticated
  using (
    user_id = auth.uid()
    or (public.is_admin(conversation_id) and not public.is_creator(conversation_id, user_id))
  );

-- The main owner hands the group to [new_owner], who becomes its only owner.
create or replace function public.transfer_group(conv uuid, new_owner uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_creator(conv, auth.uid()) then
    raise exception 'only the group''s owner can hand it over';
  end if;
  if not exists (select 1 from conversation_members where conversation_id = conv and user_id = new_owner) then
    raise exception 'not a member';
  end if;
  update conversation_members set role = case when user_id = new_owner then 'admin' else 'member' end
  where conversation_id = conv;
  update conversations set created_by = new_owner where id = conv;
end $$;

-- An owner who leaves: if nobody else owns the group, whoever has been in it
-- longest gets it; if they were the main owner, the longest-standing owner
-- becomes the main owner.
create or replace function public.on_member_leave() returns trigger
language plpgsql security definer set search_path = public as $$
declare heir uuid;
begin
  if old.role <> 'admin' or not exists (select 1 from conversations where id = old.conversation_id) then
    return old; -- not an owner, or the whole group is being deleted
  end if;
  if not exists (select 1 from conversation_members where conversation_id = old.conversation_id and role = 'admin') then
    update conversation_members set role = 'admin'
    where conversation_id = old.conversation_id
      and user_id = (
        select user_id from conversation_members where conversation_id = old.conversation_id order by joined_at limit 1
      );
  end if;
  if public.is_creator(old.conversation_id, old.user_id) then
    select user_id into heir from conversation_members
    where conversation_id = old.conversation_id and role = 'admin' order by joined_at limit 1;
    update conversations set created_by = heir where id = old.conversation_id;
  end if;
  return old;
end $$;

drop trigger if exists members_after_delete on public.conversation_members;
create trigger members_after_delete after delete on public.conversation_members
  for each row execute function public.on_member_leave();

-- Only the main owner deletes the whole group.
drop policy if exists "conv_delete_owner" on public.conversations;
create policy "conv_delete_owner" on public.conversations for delete to authenticated
  using (is_group and public.is_creator(id, auth.uid()));

-- ───────────── Push notifications ─────────────
-- One row per phone. The `push` Edge Function reads these with the service role.
create table if not exists public.push_tokens (
  token text primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  lang text not null default 'ar',
  updated_at timestamptz not null default now()
);
create index if not exists push_tokens_user on public.push_tokens (user_id);
alter table public.push_tokens enable row level security;
drop policy if exists "push_tokens_own" on public.push_tokens;
create policy "push_tokens_own" on public.push_tokens for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- A phone that switches accounts moves its token to the new one.
create or replace function public.register_push_token(t text, l text) returns void
language sql security definer set search_path = public as $$
  insert into push_tokens (token, user_id, lang) values (t, auth.uid(), l)
  on conflict (token) do update set user_id = auth.uid(), lang = excluded.lang, updated_at = now();
$$;
revoke execute on function public.register_push_token(text, text) from anon, public;
grant execute on function public.register_push_token(text, text) to authenticated;

-- ───────────── Realtime ─────────────
do $$
declare t text;
begin
  foreach t in array array['messages', 'conversations', 'conversation_members', 'reactions', 'friendships'] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- ───────────── Storage (photos, videos, voice, stickers) ─────────────
insert into storage.buckets (id, name, public, file_size_limit)
values ('media', 'media', true, 52428800)
on conflict (id) do nothing;

drop policy if exists "media_upload_own_folder" on storage.objects;
create policy "media_upload_own_folder" on storage.objects for insert to authenticated
  with check (bucket_id = 'media' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "media_delete_own" on storage.objects;
create policy "media_delete_own" on storage.objects for delete to authenticated
  using (bucket_id = 'media' and owner = auth.uid());

-- ───────────── Reports and bans ─────────────
create table if not exists public.moderators (
  user_id uuid primary key references public.profiles(id) on delete cascade
);
alter table public.moderators enable row level security;
drop policy if exists "moderators_read_own" on public.moderators;
create policy "moderators_read_own" on public.moderators for select to authenticated using (user_id = auth.uid());
insert into public.moderators (user_id) select id from public.profiles where username = 'abdullah'
on conflict do nothing;

create or replace function public.is_moderator() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from moderators where user_id = auth.uid());
$$;

create table if not exists public.bans (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  until timestamptz, -- null: for good
  reason text,
  created_at timestamptz not null default now()
);
alter table public.bans enable row level security;
drop policy if exists "bans_read" on public.bans;
create policy "bans_read" on public.bans for select to authenticated
  using (user_id = auth.uid() or public.is_moderator());

create or replace function public.is_banned(member uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from bans where user_id = member and (until is null or until > now()));
$$;

-- The app shows a banned person a closed door; these are what really stop them.
drop policy if exists "banned_send" on public.messages;
create policy "banned_send" on public.messages as restrictive for insert to authenticated
  with check (not public.is_banned(auth.uid()));
drop policy if exists "banned_edit" on public.messages;
create policy "banned_edit" on public.messages as restrictive for update to authenticated
  using (not public.is_banned(auth.uid()));
drop policy if exists "banned_react" on public.reactions;
create policy "banned_react" on public.reactions as restrictive for insert to authenticated
  with check (not public.is_banned(auth.uid()));
drop policy if exists "banned_friend" on public.friendships;
create policy "banned_friend" on public.friendships as restrictive for insert to authenticated
  with check (not public.is_banned(auth.uid()));

-- Keeps its own copy of the message, so the case still reads after it is deleted.
create table if not exists public.reports (
  id uuid primary key default gen_random_uuid(),
  message_id uuid references public.messages(id) on delete set null,
  conversation_id uuid references public.conversations(id) on delete set null,
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  reported_id uuid references public.profiles(id) on delete set null,
  message_type text not null,
  message_content text,
  message_media_url text,
  message_at timestamptz not null,
  note text,
  status text not null default 'open' check (status in ('open', 'resolved')),
  action text check (action in ('none', 'delete', 'temp_ban', 'ban')),
  ban_until timestamptz,
  reason text,
  notice_seen boolean not null default false,
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  unique (message_id, reporter_id)
);
alter table public.reports enable row level security;
-- Written only through the functions below. The reported person never reads it,
-- so they can't learn who reported them.
drop policy if exists "reports_read" on public.reports;
create policy "reports_read" on public.reports for select to authenticated using (public.is_moderator());

create or replace function public.report_message(msg uuid, note text) returns uuid
language plpgsql security definer set search_path = public as $$
declare m messages; rep uuid;
begin
  select * into m from messages where id = msg;
  if not found or not public.is_member(m.conversation_id) then raise exception 'not allowed'; end if;
  if m.sender_id = auth.uid() then raise exception 'not allowed'; end if;
  insert into reports (message_id, conversation_id, reporter_id, reported_id, message_type, message_content,
                       message_media_url, message_at, note)
  values (m.id, m.conversation_id, auth.uid(), m.sender_id, m.type, m.content, m.media_url, m.created_at,
          nullif(left(trim(report_message.note), 1000), ''))
  on conflict (message_id, reporter_id) do update set note = coalesce(excluded.note, reports.note)
  returning id into rep;
  return rep;
end $$;

-- A moderator sees the messages around a reported one, and no other chats:
-- this goes through a function so no table policy opens conversations up.
create or replace function public.report_context(rep uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r reports; result jsonb;
begin
  if not public.is_moderator() then raise exception 'not allowed'; end if;
  select * into r from reports where id = rep;
  if not found then raise exception 'not found'; end if;
  select jsonb_build_object('name', c.name, 'is_group', c.is_group, 'messages', coalesce((
    select jsonb_agg(jsonb_build_object('id', x.id, 'sender', p.display_name, 'type', x.type,
             'content', x.content, 'media_url', x.media_url, 'created_at', x.created_at) order by x.created_at)
    from (
      (select * from messages where conversation_id = r.conversation_id and created_at <= r.message_at
        order by created_at desc limit 26)
      union all
      (select * from messages where conversation_id = r.conversation_id and created_at > r.message_at
        order by created_at limit 25)
    ) x left join profiles p on p.id = x.sender_id
  ), '[]'::jsonb))
  into result from conversations c where c.id = r.conversation_id;
  return coalesce(result, jsonb_build_object('messages', '[]'::jsonb));
end $$;

create or replace function public.resolve_report(rep uuid, act text, minutes int, why text) returns void
language plpgsql security definer set search_path = public as $$
declare r reports; ends timestamptz; said text := nullif(left(trim(why), 1000), '');
begin
  if not public.is_moderator() then raise exception 'not allowed'; end if;
  select * into r from reports where id = rep and status = 'open' for update;
  if not found then raise exception 'already handled'; end if;
  if act in ('temp_ban', 'ban') then
    if r.reported_id is null or exists (select 1 from moderators where user_id = r.reported_id) then
      raise exception 'cannot ban this account';
    end if;
    if act = 'temp_ban' then
      if coalesce(minutes, 0) <= 0 then raise exception 'how long?'; end if;
      ends := now() + make_interval(mins => minutes);
    end if;
    insert into bans (user_id, until, reason) values (r.reported_id, ends, said)
    on conflict (user_id) do update set until = excluded.until, reason = excluded.reason, created_at = now();
  elsif act = 'delete' then
    delete from messages where id = r.message_id;
  elsif act <> 'none' then
    raise exception 'unknown action';
  end if;
  update reports set status = 'resolved', action = act, ban_until = ends, reason = said, resolved_at = now()
  where id = rep;
  -- Anyone else's reports of a deleted message are settled with it.
  if act = 'delete' then
    update reports set status = 'resolved', action = act, reason = said, notice_seen = true, resolved_at = now()
    where message_id is null and status = 'open' and conversation_id = r.conversation_id
      and message_at = r.message_at and reported_id = r.reported_id;
  end if;
end $$;

create or replace function public.lift_ban(member uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_moderator() then raise exception 'not allowed'; end if;
  delete from bans where user_id = member;
end $$;

-- Once, the next time they open the app: which message of theirs was removed and why.
create or replace function public.take_moderation_notice() returns jsonb
language plpgsql security definer set search_path = public as $$
declare r reports;
begin
  select * into r from reports
  where reported_id = auth.uid() and action = 'delete' and not notice_seen
  order by resolved_at limit 1 for update;
  if not found then return null; end if;
  update reports set notice_seen = true where id = r.id;
  return jsonb_build_object('type', r.message_type, 'content', r.message_content, 'reason', r.reason);
end $$;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'bans'
  ) then
    alter publication supabase_realtime add table public.bans;
  end if;
end $$;

-- ───────────── Statuses ─────────────
-- Everyone's status is a hidden chat of their own, so it can send whatever a chat
-- can. Nobody else is a member: viewers only read it through status_feed().
alter table public.conversations add column if not exists is_status boolean not null default false;
create unique index if not exists conversations_one_status on public.conversations (created_by) where is_status;

-- Friends and anyone sharing a group, both ways.
create or replace function public.can_see_status(owner uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select owner = auth.uid()
    or exists (
      select 1 from friendships
      where status = 'accepted'
        and ((requester = auth.uid() and addressee = owner) or (requester = owner and addressee = auth.uid()))
    )
    or exists (
      select 1 from conversation_members a
      join conversation_members b on b.conversation_id = a.conversation_id
      join conversations c on c.id = a.conversation_id
      where c.is_group and a.user_id = auth.uid() and b.user_id = owner
    );
$$;

-- Opens my status chat, clearing out what has already expired.
create or replace function public.my_status() returns uuid
language plpgsql security definer set search_path = public as $$
declare cid uuid;
begin
  select id into cid from conversations where is_status and created_by = auth.uid();
  if cid is null then
    insert into conversations (is_group, is_status, created_by) values (false, true, auth.uid()) returning id into cid;
    insert into conversation_members (conversation_id, user_id) values (cid, auth.uid());
  else
    delete from messages where conversation_id = cid and created_at <= now() - interval '24 hours';
  end if;
  return cid;
end $$;

create or replace function public.status_feed() returns setof public.messages
language sql stable security definer set search_path = public as $$
  select m.* from messages m
  join conversations c on c.id = m.conversation_id
  where c.is_status
    and c.created_by <> auth.uid()
    and m.sender_id = c.created_by
    and m.created_at > now() - interval '24 hours'
    and public.can_see_status(c.created_by)
    and not public.is_banned(c.created_by)
  order by m.created_at;
$$;

-- Someone who can see a status can report it, like a message in their own chat.
create or replace function public.report_message(msg uuid, note text) returns uuid
language plpgsql security definer set search_path = public as $$
declare m messages; rep uuid;
begin
  select * into m from messages where id = msg;
  if not found then raise exception 'not allowed'; end if;
  if not public.is_member(m.conversation_id) and not exists (
    select 1 from conversations c
    where c.id = m.conversation_id and c.is_status
      and m.created_at > now() - interval '24 hours'
      and public.can_see_status(c.created_by)
  ) then raise exception 'not allowed'; end if;
  if m.sender_id = auth.uid() then raise exception 'not allowed'; end if;
  insert into reports (message_id, conversation_id, reporter_id, reported_id, message_type, message_content,
                       message_media_url, message_at, note)
  values (m.id, m.conversation_id, auth.uid(), m.sender_id, m.type, m.content, m.media_url, m.created_at,
          nullif(left(trim(report_message.note), 1000), ''))
  on conflict (message_id, reporter_id) do update set note = coalesce(excluded.note, reports.note)
  returning id into rep;
  return rep;
end $$;

revoke execute on function public.can_see_status(uuid) from anon, public;
revoke execute on function public.my_status() from anon, public;
revoke execute on function public.status_feed() from anon, public;
grant execute on function public.can_see_status(uuid) to authenticated;
grant execute on function public.my_status() to authenticated;
grant execute on function public.status_feed() to authenticated;

-- ───────────── Photo and video reviews ─────────────
-- The checks on the sender's phone (web/moderate.js) blur what they are sure
-- of. What they aren't sure of comes here as a small preview, and a moderator
-- has a few seconds to answer while the sender waits. A row lives only that
-- long: the sender deletes it, and anything left behind is swept up.
create table if not exists public.reviews (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  kind text not null check (kind in ('image', 'video')),
  reasons text[] not null default '{}',
  preview text not null check (length(preview) < 500000),
  marks jsonb not null default '[]',
  holding boolean not null default false, -- the moderator started answering: the sender waits longer
  decision jsonb,
  created_at timestamptz not null default now()
);
alter table public.reviews enable row level security;

drop policy if exists "reviews_insert" on public.reviews;
create policy "reviews_insert" on public.reviews for insert to authenticated
  with check (sender_id = auth.uid() and public.is_member(conversation_id) and not public.is_banned(auth.uid()));
drop policy if exists "reviews_read" on public.reviews;
create policy "reviews_read" on public.reviews for select to authenticated
  using (sender_id = auth.uid() or public.is_moderator());
drop policy if exists "reviews_answer" on public.reviews;
create policy "reviews_answer" on public.reviews for update to authenticated
  using (public.is_moderator()) with check (public.is_moderator());
drop policy if exists "reviews_delete" on public.reviews;
create policy "reviews_delete" on public.reviews for delete to authenticated
  using (sender_id = auth.uid() or public.is_moderator());
-- A moderator answers; nothing else about a review changes.
revoke update on public.reviews from anon, authenticated;
grant update (holding, decision) on public.reviews to authenticated;

-- What a sender who closed the app mid-wait left behind.
create or replace function public.sweep_reviews() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from reviews where created_at < now() - interval '10 minutes';
  return null;
end $$;
revoke execute on function public.sweep_reviews() from anon, authenticated, public;
drop trigger if exists sweep_reviews on public.reviews;
create trigger sweep_reviews after insert on public.reviews
  for each statement execute function public.sweep_reviews();

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'reviews'
  ) then
    alter publication supabase_realtime add table public.reviews;
  end if;
end $$;
