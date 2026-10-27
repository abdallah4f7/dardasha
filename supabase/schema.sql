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
    check (type in ('text', 'image', 'video', 'voice', 'sticker', 'call')),
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
    last_message_text = case when new.type = 'text' then left(new.content, 120) else null end,
    last_message_type = new.type,
    last_message_at = new.created_at
  where id = new.conversation_id;
  return new;
end $$;

drop trigger if exists messages_after_insert on public.messages;
create trigger messages_after_insert after insert on public.messages
  for each row execute function public.on_message_insert();

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
