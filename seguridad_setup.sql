-- =========================================================
--  SureTrack · Seguridad y fiabilidad (Fase A)
--  Pegar entero en Supabase → SQL Editor → New query → Run.
--  No toca tus tablas de antes (user_data, profiles). Se puede ejecutar más de una vez.
--  Al terminar, abajo (Results) sale tu código de invitación para amigos.
-- =========================================================

-- 1) Cada surebet, suscripción y ajuste en su propia fila: solo suben los cambios
create table if not exists public.sync_items (
  user_id    uuid        not null default auth.uid() references auth.users (id) on delete cascade,
  kind       text        not null check (kind in ('record', 'sub', 'settings', 'meta')),
  id         text        not null check (char_length(id) between 1 and 100),
  data       jsonb,
  deleted    boolean     not null default false,      -- borrado: se marca para que los demás dispositivos también lo borren
  updated_at timestamptz not null default now(),       -- la pone el servidor
  primary key (user_id, kind, id),
  constraint sync_items_tamano check (pg_column_size(data) <= 512 * 1024)
);
create index if not exists sync_items_cambios on public.sync_items (user_id, updated_at);

alter table public.sync_items enable row level security;
alter table public.sync_items force row level security;
revoke all on table public.sync_items from anon, authenticated;
grant select, insert, update on table public.sync_items to authenticated;

drop policy if exists "sync_items: leer los propios"      on public.sync_items;
drop policy if exists "sync_items: crear los propios"     on public.sync_items;
drop policy if exists "sync_items: modificar los propios" on public.sync_items;

create policy "sync_items: leer los propios" on public.sync_items
  for select to authenticated
  using ((select auth.uid()) = user_id);

create policy "sync_items: crear los propios" on public.sync_items
  for insert to authenticated
  with check ((select auth.uid()) = user_id);

create policy "sync_items: modificar los propios" on public.sync_items
  for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create or replace function public.sync_items_touch()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := clock_timestamp();
  return new;
end;
$$;

drop trigger if exists sync_items_touch on public.sync_items;
create trigger sync_items_touch
  before insert or update on public.sync_items
  for each row execute function public.sync_items_touch();

-- 2) Copias de seguridad en la nube: una automática al día, se guardan 30 días
create table if not exists public.sync_backups (
  id         bigint generated always as identity primary key,
  user_id    uuid        not null default auth.uid() references auth.users (id) on delete cascade,
  day        date        not null default ((now() at time zone 'Europe/Madrid')::date),
  kind       text        not null default 'auto' check (kind in ('auto', 'manual', 'antes_de_restaurar')),
  n_records  integer     not null default 0,
  n_subs     integer     not null default 0,
  data       jsonb       not null,
  created_at timestamptz not null default now(),
  constraint sync_backups_tamano check (pg_column_size(data) <= 10 * 1024 * 1024)
);
create unique index if not exists sync_backups_una_auto_al_dia on public.sync_backups (user_id, day) where kind = 'auto';
create index if not exists sync_backups_por_usuario on public.sync_backups (user_id, created_at desc);

alter table public.sync_backups enable row level security;
alter table public.sync_backups force row level security;
revoke all on table public.sync_backups from anon, authenticated;
grant select, delete on table public.sync_backups to authenticated;

drop policy if exists "sync_backups: leer las propias"  on public.sync_backups;
drop policy if exists "sync_backups: borrar las propias" on public.sync_backups;

create policy "sync_backups: leer las propias" on public.sync_backups
  for select to authenticated
  using ((select auth.uid()) = user_id);

create policy "sync_backups: borrar las propias" on public.sync_backups
  for delete to authenticated
  using ((select auth.uid()) = user_id);

-- La copia la monta el servidor con lo que hay en tu cuenta (nadie puede colar una copia falsa)
create or replace function public.st_backup(p_kind text default 'auto')
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid  uuid := auth.uid();
  snap jsonb;
  nid  bigint;
begin
  if uid is null then raise exception 'not_authenticated'; end if;
  if p_kind not in ('auto', 'manual', 'antes_de_restaurar') then raise exception 'bad_kind'; end if;
  select jsonb_build_object(
    'records',  coalesce((select jsonb_agg(data order by data ->> 'createdAt') from public.sync_items where user_id = uid and kind = 'record' and not deleted), '[]'::jsonb),
    'subs',     coalesce((select jsonb_agg(data order by data ->> 'start')     from public.sync_items where user_id = uid and kind = 'sub'    and not deleted), '[]'::jsonb),
    'settings', coalesce((select data from public.sync_items where user_id = uid and kind = 'settings' and id = 'main' and not deleted), '{}'::jsonb)
  ) into snap;
  if jsonb_array_length(snap -> 'records') = 0 and jsonb_array_length(snap -> 'subs') = 0 then return null; end if;
  insert into public.sync_backups (user_id, kind, n_records, n_subs, data)
  values (uid, p_kind, jsonb_array_length(snap -> 'records'), jsonb_array_length(snap -> 'subs'), snap)
  on conflict (user_id, day) where kind = 'auto' do nothing
  returning id into nid;
  delete from public.sync_backups where user_id = uid and created_at < now() - interval '30 days';
  return nid;
end;
$$;
revoke execute on function public.st_backup(text) from public, anon;
grant execute on function public.st_backup(text) to authenticated;

-- 3) Registro solo con código de invitación (si no hay ningún código creado, el registro es libre)
create table if not exists public.invite_codes (
  code         text primary key check (char_length(code) between 4 and 40),
  uses_left    integer not null default 1 check (uses_left >= 0),
  note         text,
  created_at   timestamptz not null default now(),
  last_used_at timestamptz
);
alter table public.invite_codes enable row level security;     -- sin políticas: nadie puede leerla desde la app
alter table public.invite_codes force row level security;
revoke all on table public.invite_codes from anon, authenticated;

create or replace function public.st_check_invite()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare c text;
begin
  if not exists (select 1 from public.invite_codes) then return new; end if;
  c := upper(btrim(coalesce(new.raw_user_meta_data ->> 'invite', '')));
  update public.invite_codes set uses_left = uses_left - 1, last_used_at = now()
   where upper(code) = c and uses_left > 0;
  if not found then raise exception 'invite_code_invalid' using errcode = 'P0001'; end if;
  return new;
end;
$$;
revoke execute on function public.st_check_invite() from public, anon, authenticated;

drop trigger if exists st_check_invite on auth.users;
create trigger st_check_invite
  before insert on auth.users
  for each row execute function public.st_check_invite();

-- 4) «Borrar mi cuenta»: borra al usuario y, en cascada, todos sus datos
create or replace function public.st_delete_my_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not_authenticated'; end if;
  delete from auth.users where id = uid;
end;
$$;
revoke execute on function public.st_delete_my_account() from public, anon;
grant execute on function public.st_delete_my_account() to authenticated;

-- 5) Un código de invitación para tus amigos (10 usos). Solo se crea la primera vez.
insert into public.invite_codes (code, uses_left, note)
select 'SURE-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6)), 10, 'Amigos'
where not exists (select 1 from public.invite_codes);

select code as "Tu código de invitación", uses_left as "Usos que quedan"
from public.invite_codes order by created_at desc limit 1;
