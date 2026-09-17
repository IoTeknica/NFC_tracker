-- ============================================================
-- NFC Tracker — esquema completo de Supabase
-- IoTeknica
--
-- Refleja el estado actual en produccion, incluidas todas las
-- correcciones aplicadas sobre la marcha. Ejecutable de cero
-- en un proyecto nuevo.
-- ============================================================


-- ============================================================
-- 1. PROFILES
-- ============================================================

create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  email       text not null,
  nombre      text,
  rol         text not null default 'user'
              check (rol in ('admin', 'operador', 'user')),
  created_at  timestamptz default now()
);

-- Crea el perfil automaticamente al registrarse un usuario
create or replace function public.handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (id, email)
  values (new.id, new.email)
  on conflict (id) do nothing;
  return new;
end;
$$ language plpgsql security definer;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();


-- ============================================================
-- 2. TAGS
-- ============================================================
-- uid = identificador que viaja en la URL grabada en el chip
--       (ej: 'TAG001'), NO el serial number del chip NFC.

create table if not exists public.tags (
  id           uuid primary key default gen_random_uuid(),
  uid          text unique not null,
  nombre       text not null,
  lugar        text not null,
  descripcion  text,
  lat          float8,
  lng          float8,
  created_by   uuid references public.profiles(id),
  created_at   timestamptz default now(),
  updated_at   timestamptz default now()
);


-- ============================================================
-- 3. LECTURAS
-- ============================================================

create table if not exists public.lecturas (
  id          uuid primary key default gen_random_uuid(),
  tag_id      uuid references public.tags(id) on delete cascade,
  user_id     uuid references public.profiles(id),
  lat         float8,
  lng         float8,
  estado      text not null default 'pendiente'
              check (estado in ('pendiente','revisado','aprobado','rechazado')),
  leido_en    timestamptz not null default now(),
  created_at  timestamptz default now()
);


-- ============================================================
-- 4. AUDIT_LOG
-- ============================================================
-- Inmutable. Solo escribe el trigger, nadie lo edita ni borra.
--
-- OJO: el FK va con ON DELETE SET NULL. Con el default (RESTRICT)
-- borrar una lectura que tiene auditoria falla con
-- "violates foreign key constraint audit_log_lectura_id_fkey".

create table if not exists public.audit_log (
  id               uuid primary key default gen_random_uuid(),
  lectura_id       uuid references public.lecturas(id) on delete set null,
  changed_by       uuid references public.profiles(id),
  estado_anterior  text,
  estado_nuevo     text,
  created_at       timestamptz default now()
);

-- Registra cada cambio de estado sin intervencion de la app
create or replace function public.log_estado_change()
returns trigger as $$
begin
  if old.estado is distinct from new.estado then
    insert into public.audit_log (lectura_id, changed_by, estado_anterior, estado_nuevo)
    values (new.id, auth.uid(), old.estado, new.estado);
  end if;
  return new;
end;
$$ language plpgsql security definer;

drop trigger if exists on_lectura_estado_change on public.lecturas;
create trigger on_lectura_estado_change
  after update on public.lecturas
  for each row execute function public.log_estado_change();


-- ============================================================
-- 5. MANTENIMIENTOS
-- ============================================================
-- Los crea el operador en terreno; el admin los aprueba.

create table if not exists public.mantenimientos (
  id          uuid primary key default gen_random_uuid(),
  tag_id      uuid references public.tags(id) on delete cascade,
  user_id     uuid references public.profiles(id),
  texto       text not null,
  estado      text not null default 'borrador'
              check (estado in ('borrador','aprobado','rechazado')),
  created_at  timestamptz default now(),
  updated_at  timestamptz default now()
);


-- ============================================================
-- 6. TAG_WRITES  (auditoria de escritura de chips)
-- ============================================================

create table if not exists public.tag_writes (
  id          uuid primary key default gen_random_uuid(),
  tag_id      uuid references public.tags(id),
  written_by  uuid references public.profiles(id),
  payload     jsonb not null,
  created_at  timestamptz default now()
);


-- ============================================================
-- 6b. FOTOS  (fotografias del punto, tomadas en terreno)
-- ============================================================
-- Una foto pertenece a UNA visita (lectura_id) y se agrupa por punto
-- (tag_id). El tag_id esta denormalizado a proposito: el panel del
-- dashboard consulta por tag y asi evita el join con lecturas.
--
-- lectura_id va con ON DELETE SET NULL, igual que audit_log: borrar una
-- lectura no debe hacer desaparecer la evidencia fotografica del punto.
--
-- 'path' es la ruta dentro del bucket de Storage, con el formato
--   <tag_id>/<lectura_id>/<uuid>.jpg
-- El archivo en si NO vive en Postgres.

create table if not exists public.fotos (
  id          uuid primary key default gen_random_uuid(),
  lectura_id  uuid references public.lecturas(id) on delete set null,
  tag_id      uuid references public.tags(id) on delete cascade,
  user_id     uuid references public.profiles(id),
  path        text not null unique,
  created_at  timestamptz default now()
);

create index if not exists fotos_tag_idx     on public.fotos (tag_id, created_at desc);
create index if not exists fotos_lectura_idx on public.fotos (lectura_id);

-- El tope de 5 por visita se valida aca, no solo en la UI: el limite
-- de la app es cosmetico y se saltea desde la consola del navegador.
create or replace function public.check_max_fotos()
returns trigger as $$
begin
  if new.lectura_id is not null
     and (select count(*) from public.fotos where lectura_id = new.lectura_id) >= 5 then
    raise exception 'Maximo 5 fotos por lectura';
  end if;
  return new;
end;
$$ language plpgsql;

drop trigger if exists on_foto_insert on public.fotos;
create trigger on_foto_insert
  before insert on public.fotos
  for each row execute function public.check_max_fotos();


-- ============================================================
-- 7. HELPER DE ROL
-- ============================================================
-- security definer es obligatorio: sin el, una politica RLS sobre
-- profiles que consulte profiles entra en recursion infinita.

create or replace function public.get_my_rol()
returns text as $$
  select rol from public.profiles where id = auth.uid();
$$ language sql security definer stable;


-- ============================================================
-- 8. ROW LEVEL SECURITY
-- ============================================================

alter table public.profiles       enable row level security;
alter table public.tags           enable row level security;
alter table public.lecturas       enable row level security;
alter table public.audit_log      enable row level security;
alter table public.mantenimientos enable row level security;
alter table public.tag_writes     enable row level security;


-- ---------- PROFILES ----------
-- SELECT abierto a autenticados: lo necesitan los joins de
-- lecturas y mantenimientos para mostrar el nombre del autor.

drop policy if exists "Auth users leen perfiles" on public.profiles;
create policy "Auth users leen perfiles" on public.profiles
  for select to authenticated
  using (true);

drop policy if exists "Editar perfil propio" on public.profiles;
create policy "Editar perfil propio" on public.profiles
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- OJO: la politica de arriba NO alcanza para proteger el rol.
-- Solo restringe QUE fila se puede editar (la propia), no QUE columnas.
-- Sin el revoke siguiente, cualquier usuario se hace admin con:
--   sb.from('profiles').update({rol:'admin'}).eq('id', <su propio id>)
-- y a partir de ahi pasa todas las demas politicas, que se apoyan en
-- exists(... rol = 'admin').
--
-- El permiso a nivel de columna se evalua antes que RLS, asi que esto
-- lo cierra para todos los autenticados, admins incluidos: el rol se
-- asigna por SQL desde el panel, que es el diseno documentado.
-- Un usuario solo puede editar su propio 'nombre'.
--
-- El orden importa: Supabase otorga UPDATE sobre toda la tabla a
-- 'authenticated' por defecto, y un revoke por columna NO anula un
-- permiso de tabla — hay que quitar el de tabla y volver a otorgar
-- solo la columna que si se puede editar.

revoke update on public.profiles from authenticated;
grant  update (nombre) on public.profiles to authenticated;


-- ---------- TAGS ----------

drop policy if exists "Leer tags autenticados" on public.tags;
create policy "Leer tags autenticados" on public.tags
  for select to authenticated
  using (true);

-- El EXISTS explicito funciona mejor que get_my_rol() aqui:
-- con la funcion daba "new row violates row-level security policy".
drop policy if exists "Admin escribe tags" on public.tags;
create policy "Admin escribe tags" on public.tags
  for all to authenticated
  using (
    exists (select 1 from public.profiles
            where id = auth.uid() and rol = 'admin')
  )
  with check (
    exists (select 1 from public.profiles
            where id = auth.uid() and rol = 'admin')
  );


-- ---------- LECTURAS ----------

drop policy if exists "User ve sus lecturas" on public.lecturas;
create policy "User ve sus lecturas" on public.lecturas
  for select to authenticated
  using (
    user_id = auth.uid()
    or exists (select 1 from public.profiles
               where id = auth.uid() and rol = 'admin')
  );

drop policy if exists "Cualquier auth inserta lectura" on public.lecturas;
create policy "Cualquier auth inserta lectura" on public.lecturas
  for insert to authenticated
  with check (auth.uid() = user_id);

drop policy if exists "Solo admin cambia estado" on public.lecturas;
create policy "Solo admin cambia estado" on public.lecturas
  for update to authenticated
  using (
    exists (select 1 from public.profiles
            where id = auth.uid() and rol = 'admin')
  );

drop policy if exists "Admin puede borrar lecturas" on public.lecturas;
create policy "Admin puede borrar lecturas" on public.lecturas
  for delete to authenticated
  using (
    exists (select 1 from public.profiles
            where id = auth.uid() and rol = 'admin')
  );


-- ---------- AUDIT_LOG ----------
-- Sin politicas de INSERT/UPDATE/DELETE: el trigger escribe con
-- security definer y se salta RLS. Nadie mas toca esta tabla.

drop policy if exists "Admin lee audit" on public.audit_log;
create policy "Admin lee audit" on public.audit_log
  for select to authenticated
  using (
    exists (select 1 from public.profiles
            where id = auth.uid() and rol = 'admin')
  );


-- ---------- MANTENIMIENTOS ----------

drop policy if exists "Ver mantenimientos" on public.mantenimientos;
create policy "Ver mantenimientos" on public.mantenimientos
  for select to authenticated
  using (true);

-- Cualquier autenticado puede insertar los suyos; la UI solo
-- muestra el boton a operador y admin.
drop policy if exists "Insertar mantenimiento" on public.mantenimientos;
create policy "Insertar mantenimiento" on public.mantenimientos
  for insert to authenticated
  with check (auth.uid() = user_id);

drop policy if exists "Admin actualiza mantenimiento" on public.mantenimientos;
create policy "Admin actualiza mantenimiento" on public.mantenimientos
  for update to authenticated
  using (
    exists (select 1 from public.profiles
            where id = auth.uid() and rol = 'admin')
  );

drop policy if exists "Admin borra mantenimiento" on public.mantenimientos;
create policy "Admin borra mantenimiento" on public.mantenimientos
  for delete to authenticated
  using (
    exists (select 1 from public.profiles
            where id = auth.uid() and rol = 'admin')
  );


-- ---------- TAG_WRITES ----------

drop policy if exists "Admin gestiona writes" on public.tag_writes;
create policy "Admin gestiona writes" on public.tag_writes
  for all to authenticated
  using (
    exists (select 1 from public.profiles
            where id = auth.uid() and rol = 'admin')
  );


-- ---------- FOTOS ----------
-- A diferencia de mantenimientos, aca el rol SI se valida en la
-- politica. En mantenimientos quedo solo en la UI y eso significa que
-- cualquier autenticado puede insertar desde la consola; no repetir.

alter table public.fotos enable row level security;

drop policy if exists "Ver fotos" on public.fotos;
create policy "Ver fotos" on public.fotos
  for select to authenticated
  using (true);

drop policy if exists "Operador y admin suben fotos" on public.fotos;
create policy "Operador y admin suben fotos" on public.fotos
  for insert to authenticated
  with check (
    user_id = auth.uid()
    and exists (select 1 from public.profiles
                where id = auth.uid() and rol in ('admin','operador'))
  );

-- El operador puede borrar las suyas; el admin, cualquiera.
drop policy if exists "Borrar fotos" on public.fotos;
create policy "Borrar fotos" on public.fotos
  for delete to authenticated
  using (
    exists (select 1 from public.profiles
            where id = auth.uid() and rol = 'admin')
    or (user_id = auth.uid()
        and exists (select 1 from public.profiles
                    where id = auth.uid() and rol = 'operador'))
  );


-- ============================================================
-- 9. STORAGE  (bucket de fotos)
-- ============================================================
-- El bucket va PRIVADO: son fotos de instalaciones de clientes y no
-- deben quedar accesibles adivinando la ruta. El dashboard las muestra
-- con URLs firmadas (createSignedUrls), que caducan solas.
--
-- storage.objects ya viene con RLS activo desde Supabase; aca solo se
-- agregan las politicas del bucket.

insert into storage.buckets (id, name, public)
values ('fotos-tags', 'fotos-tags', false)
on conflict (id) do nothing;

drop policy if exists "Ver fotos del bucket" on storage.objects;
create policy "Ver fotos del bucket" on storage.objects
  for select to authenticated
  using (bucket_id = 'fotos-tags');

drop policy if exists "Subir fotos al bucket" on storage.objects;
create policy "Subir fotos al bucket" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'fotos-tags'
    and exists (select 1 from public.profiles
                where id = auth.uid() and rol in ('admin','operador'))
  );

drop policy if exists "Borrar fotos del bucket" on storage.objects;
create policy "Borrar fotos del bucket" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'fotos-tags'
    and exists (select 1 from public.profiles
                where id = auth.uid() and rol in ('admin','operador'))
  );


-- ============================================================
-- OPERACIONES FRECUENTES
-- ============================================================

-- Asignar rol (no hay UI para esto)
--   update public.profiles set rol = 'admin'    where email = 'x@y.com';
--   update public.profiles set rol = 'operador' where email = 'x@y.com';

-- Poner nombre a un usuario creado desde el panel de Supabase
-- (el trigger solo copia el email)
--   update public.profiles set nombre = 'J. Belaustegui' where email = 'x@y.com';

-- Crear el perfil a mano si el trigger no alcanzo a dispararse
--   insert into public.profiles (id, email, rol)
--   select id, email, 'admin' from auth.users where email = 'x@y.com'
--   on conflict (id) do update set rol = 'admin';

-- Tag de prueba
--   insert into public.tags (uid, nombre, lugar, lat, lng, created_by)
--   values ('TAG001', 'Rack principal', 'Sala de servidores',
--           -33.4489, -70.6693, (select id from auth.users limit 1));
