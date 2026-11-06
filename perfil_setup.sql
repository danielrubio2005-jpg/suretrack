-- =========================================================
--  SureTrack · Perfil (alias y foto) · Fase 3
--  Pegar entero en Supabase → SQL Editor → New query → Run.
--  No toca tus datos (tabla user_data). Se puede ejecutar más de una vez.
-- =========================================================

-- 1) Tabla de perfiles: una fila por usuario con su alias y la ruta de su foto
create table if not exists public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  alias       text,
  avatar_path text,
  updated_at  timestamptz not null default now(),
  constraint profiles_alias_largo check (alias is null or char_length(alias) between 1 and 30),
  constraint profiles_foto_propia check (avatar_path is null or avatar_path like id::text || '/%')
);

alter table public.profiles enable row level security;
alter table public.profiles force row level security;

revoke all on table public.profiles from anon, authenticated;
grant select, insert, update on table public.profiles to authenticated;

drop policy if exists "profiles: leer el propio"      on public.profiles;
drop policy if exists "profiles: crear el propio"     on public.profiles;
drop policy if exists "profiles: modificar el propio" on public.profiles;

create policy "profiles: leer el propio" on public.profiles
  for select to authenticated
  using ((select auth.uid()) = id);

create policy "profiles: crear el propio" on public.profiles
  for insert to authenticated
  with check ((select auth.uid()) = id);

create policy "profiles: modificar el propio" on public.profiles
  for update to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

-- La fecha la pone el servidor
create or replace function public.profiles_touch()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists profiles_touch on public.profiles;
create trigger profiles_touch
  before insert or update on public.profiles
  for each row execute function public.profiles_touch();

-- 2) Carpeta de fotos «avatars»: privada, máximo 100 KB, solo JPEG o WebP
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', false, 102400, array['image/jpeg', 'image/webp'])
on conflict (id) do update
  set public = false, file_size_limit = 102400, allowed_mime_types = array['image/jpeg', 'image/webp'];

-- 3) Cada usuario solo ve, sube, cambia y borra lo de su carpeta: avatars/<su id>/
drop policy if exists "avatars: ver la propia"     on storage.objects;
drop policy if exists "avatars: subir la propia"   on storage.objects;
drop policy if exists "avatars: cambiar la propia" on storage.objects;
drop policy if exists "avatars: borrar la propia"  on storage.objects;

create policy "avatars: ver la propia" on storage.objects
  for select to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid()::text));

create policy "avatars: subir la propia" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid()::text));

create policy "avatars: cambiar la propia" on storage.objects
  for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid()::text))
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid()::text));

create policy "avatars: borrar la propia" on storage.objects
  for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid()::text));
