-- ============================================================
-- MIGRACION: clientes (multi-empresa) y rol superadmin
-- NFC Tracker — IoTeknica
--
-- Correr UNA sola vez, completa, en el SQL Editor de Supabase.
-- Va dentro de una transaccion: si cualquier paso falla, no se
-- aplica NADA y la base queda exactamente como estaba.
--
-- Que hace:
--   1. Crea la tabla clientes y un cliente inicial 'IoTeknica'.
--   2. Agrega cliente_id a profiles, tags, lecturas, mantenimientos,
--      fotos y audit_log, y rellena los datos existentes.
--   3. Los 'admin' actuales pasan a 'superadmin' (ven todos los
--      clientes). Operadores, users y todos los tags existentes quedan
--      en el cliente 'IoTeknica'; despues se reasignan a mano.
--   4. Reescribe las politicas RLS para aislar cada cliente.
--
-- No borra ningun dato. Si se quiere empezar limpio, hacerlo despues
-- y por separado.
--
-- DESPUES de correrla, subir index.html y pwa.html nuevos enseguida:
-- el dashboard publicado hoy no reconoce el rol 'superadmin', y hasta
-- que se actualice, los botones de administrador aparecen deshabilitados.
-- Los operadores pueden seguir trabajando con la PWA vieja sin problema.
--
-- Despues, correr verificar_clientes.sql para comprobar el aislamiento.
-- ============================================================

begin;


-- ============================================================
-- 1. CLIENTES
-- ============================================================
-- Borrar un cliente con datos falla a proposito (FK sin cascade): para
-- dar de baja un cliente se lo desactiva (activo = false), lo que corta
-- el acceso de todos sus usuarios sin destruir el historial.

create table if not exists public.clientes (
  id          uuid primary key default gen_random_uuid(),
  nombre      text not null unique,
  activo      boolean not null default true,
  created_at  timestamptz default now()
);

insert into public.clientes (nombre) values ('IoTeknica')
on conflict (nombre) do nothing;


-- ============================================================
-- 2. COLUMNA cliente_id
-- ============================================================
-- Se denormaliza en cada tabla (en vez de deducirla por join con tags)
-- por tres motivos: las politicas RLS quedan simples y rapidas, cubre
-- lecturas de tags no registrados (tag_id null), y el historial de
-- audit_log y fotos conserva su cliente aunque se borre la lectura.

alter table public.profiles       add column if not exists cliente_id uuid references public.clientes(id);
alter table public.tags           add column if not exists cliente_id uuid references public.clientes(id);
alter table public.lecturas       add column if not exists cliente_id uuid references public.clientes(id);
alter table public.mantenimientos add column if not exists cliente_id uuid references public.clientes(id);
alter table public.fotos          add column if not exists cliente_id uuid references public.clientes(id);
alter table public.audit_log      add column if not exists cliente_id uuid references public.clientes(id);


-- ============================================================
-- 3. ROLES: admin -> superadmin
-- ============================================================
-- El orden importa: primero se quita el check viejo, porque el update
-- a 'superadmin' lo violaria.

alter table public.profiles drop constraint if exists profiles_rol_check;
update public.profiles set rol = 'superadmin' where rol = 'admin';
alter table public.profiles add constraint profiles_rol_check
  check (rol in ('superadmin', 'admin', 'operador', 'user'));


-- ============================================================
-- 4. RELLENO DE DATOS EXISTENTES
-- ============================================================
-- Va ANTES de crear los triggers nuevos, para que no intervengan.

do $$
declare
  c_ini uuid := (select id from public.clientes where nombre = 'IoTeknica');
begin
  update public.profiles set cliente_id = c_ini
   where rol <> 'superadmin' and cliente_id is null;

  update public.tags set cliente_id = c_ini where cliente_id is null;

  update public.lecturas l set cliente_id = coalesce(
      (select t.cliente_id from public.tags t     where t.id = l.tag_id),
      (select p.cliente_id from public.profiles p where p.id = l.user_id),
      c_ini)
   where l.cliente_id is null;

  update public.mantenimientos m set cliente_id = coalesce(
      (select t.cliente_id from public.tags t where t.id = m.tag_id), c_ini)
   where m.cliente_id is null;

  update public.fotos f set cliente_id = coalesce(
      (select t.cliente_id from public.tags t where t.id = f.tag_id), c_ini)
   where f.cliente_id is null;

  update public.audit_log a set cliente_id = coalesce(
      (select l.cliente_id from public.lecturas l where l.id = a.lectura_id), c_ini)
   where a.cliente_id is null;
end $$;


-- ============================================================
-- 5. RESTRICCIONES E INDICES
-- ============================================================
-- lecturas.cliente_id y audit_log.cliente_id quedan nullables: un
-- superadmin puede escanear un tag no registrado, y esa lectura no
-- pertenece a ningun cliente.

alter table public.tags           alter column cliente_id set not null;
alter table public.mantenimientos alter column cliente_id set not null;
alter table public.fotos          alter column cliente_id set not null;

-- superadmin: sin cliente. admin y operador: con cliente obligatorio.
-- user: puede quedar sin cliente — es el estado "pendiente de asignar"
-- de toda cuenta nueva, y en ese estado no ve nada.
alter table public.profiles drop constraint if exists profiles_cliente_segun_rol;
alter table public.profiles add constraint profiles_cliente_segun_rol check (
     (rol = 'superadmin' and cliente_id is null)
  or (rol in ('admin', 'operador') and cliente_id is not null)
  or  rol = 'user'
);

create index if not exists profiles_cliente_idx       on public.profiles (cliente_id);
create index if not exists tags_cliente_idx           on public.tags (cliente_id);
create index if not exists lecturas_cliente_idx       on public.lecturas (cliente_id, leido_en desc);
create index if not exists mantenimientos_cliente_idx on public.mantenimientos (cliente_id);
create index if not exists fotos_cliente_idx          on public.fotos (cliente_id);
create index if not exists audit_log_cliente_idx      on public.audit_log (cliente_id);


-- >>> INICIO BLOQUE COMPARTIDO CON schema.sql >>>

-- ============================================================
-- HELPERS DE ACCESO
-- ============================================================
-- security definer: leen profiles sin pasar por su RLS (si no, las
-- politicas sobre profiles entran en recursion). search_path vacio y
-- nombres calificados: evita que alguien los desvie con un objeto
-- homonimo en otro esquema.
--
-- En las politicas se invocan como (select public.fn()) para que
-- Postgres los evalue una vez por consulta y no una vez por fila.

create or replace function public.mi_rol()
returns text language sql stable security definer set search_path = ''
as $$ select p.rol from public.profiles p where p.id = auth.uid() $$;

-- Solo devuelve el cliente si esta ACTIVO: desactivar un cliente corta
-- el acceso de todos sus usuarios de una vez.
create or replace function public.mi_cliente()
returns uuid language sql stable security definer set search_path = ''
as $$
  select p.cliente_id
    from public.profiles p
    join public.clientes c on c.id = p.cliente_id
   where p.id = auth.uid() and c.activo
$$;

create or replace function public.es_superadmin()
returns boolean language sql stable security definer set search_path = ''
as $$
  select coalesce(
    (select p.rol = 'superadmin' from public.profiles p where p.id = auth.uid()),
    false)
$$;

-- Cliente del que el usuario es ADMIN (null si no es admin de ninguno).
create or replace function public.admin_de()
returns uuid language sql stable security definer set search_path = ''
as $$ select case when public.mi_rol() = 'admin' then public.mi_cliente() end $$;

-- Cliente del que el usuario es parte del EQUIPO de terreno: admin u
-- operador (null si es user o no tiene cliente).
create or replace function public.equipo_de()
returns uuid language sql stable security definer set search_path = ''
as $$ select case when public.mi_rol() in ('admin', 'operador') then public.mi_cliente() end $$;


-- ============================================================
-- TRIGGERS DE ASIGNACION DE CLIENTE
-- ============================================================
-- El cliente de cada fila NUNCA lo decide el navegador: lo pone la
-- base. Son security definer para poder leer el cliente real del tag
-- aunque el usuario no pueda verlo — asi se detecta a quien intenta
-- colgar datos de un tag ajeno.
--
-- "auth.uid() is null" = la consulta viene del SQL Editor o de un
-- proceso de servidor, no de un usuario: se respeta lo que indique.

-- TAGS: si no se indica cliente, el del admin que lo registra.
create or replace function public.tags_asignar_cliente()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if new.cliente_id is null then
    new.cliente_id := public.mi_cliente();
  end if;
  if new.cliente_id is null then
    raise exception 'Indica a que cliente pertenece el tag';
  end if;
  return new;
end $$;

drop trigger if exists tags_asignar_cliente on public.tags;
create trigger tags_asignar_cliente
  before insert on public.tags
  for each row execute function public.tags_asignar_cliente();

-- LECTURAS: el cliente del operador. Si el tag es de otro cliente, se
-- rechaza. Una cuenta sin cliente activo no puede registrar lecturas.
create or replace function public.lecturas_asignar_cliente()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  t_cliente uuid;
  a_cliente uuid := public.mi_cliente();
begin
  if new.tag_id is not null then
    select t.cliente_id into t_cliente from public.tags t where t.id = new.tag_id;
  end if;

  if auth.uid() is null or public.es_superadmin() then
    new.cliente_id := coalesce(new.cliente_id, t_cliente);
    return new;
  end if;

  if a_cliente is null then
    raise exception 'Tu cuenta no esta asignada a ningun cliente activo';
  end if;
  if t_cliente is not null and t_cliente <> a_cliente then
    raise exception 'Este tag no pertenece a tu organizacion';
  end if;
  new.cliente_id := a_cliente;
  return new;
end $$;

drop trigger if exists lecturas_asignar_cliente on public.lecturas;
create trigger lecturas_asignar_cliente
  before insert on public.lecturas
  for each row execute function public.lecturas_asignar_cliente();

-- MANTENIMIENTOS y FOTOS: el cliente del tag, que debe ser el del autor.
create or replace function public.asignar_cliente_desde_tag()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  t_cliente uuid;
begin
  select t.cliente_id into t_cliente from public.tags t where t.id = new.tag_id;
  if t_cliente is null then
    raise exception 'El tag no existe';
  end if;
  if not (auth.uid() is null or public.es_superadmin())
     and t_cliente is distinct from public.mi_cliente() then
    raise exception 'Este tag no pertenece a tu organizacion';
  end if;
  new.cliente_id := t_cliente;
  return new;
end $$;

drop trigger if exists mantenimientos_asignar_cliente on public.mantenimientos;
create trigger mantenimientos_asignar_cliente
  before insert on public.mantenimientos
  for each row execute function public.asignar_cliente_desde_tag();

drop trigger if exists fotos_asignar_cliente on public.fotos;
create trigger fotos_asignar_cliente
  before insert on public.fotos
  for each row execute function public.asignar_cliente_desde_tag();

-- AUDIT_LOG: hereda el cliente de la lectura, asi sigue siendo visible
-- para su admin aunque la lectura se borre despues.
create or replace function public.log_estado_change()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if old.estado is distinct from new.estado then
    insert into public.audit_log
      (lectura_id, changed_by, estado_anterior, estado_nuevo, cliente_id)
    values
      (new.id, auth.uid(), old.estado, new.estado, new.cliente_id);
  end if;
  return new;
end $$;

drop trigger if exists on_lectura_estado_change on public.lecturas;
create trigger on_lectura_estado_change
  after update on public.lecturas
  for each row execute function public.log_estado_change();


-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================
-- Reglas:
--   superadmin → todo, de todos los clientes.
--   admin      → todo lo de SU cliente; aprueba, cambia estados, borra.
--   operador   → tags, mantenimientos y fotos de su cliente; sus lecturas.
--   user       → tags y mantenimientos de su cliente; sus lecturas.
--   sin cliente activo → solo su propio perfil.
--
-- El rol se valida SIEMPRE en la politica, nunca solo en la interfaz.

alter table public.clientes enable row level security;

-- ---------- CLIENTES ----------
-- Sin politicas de escritura: los clientes se crean desde el SQL Editor.
drop policy if exists "Ver clientes" on public.clientes;
create policy "Ver clientes" on public.clientes
  for select to authenticated
  using ((select public.es_superadmin()) or id = (select public.mi_cliente()));

-- ---------- PROFILES ----------
-- Antes cualquier autenticado leia TODOS los perfiles, con correo.
-- Ahora: el propio, los de su cliente, o todos si es superadmin.
-- cliente_id y rol no se pueden editar desde el cliente: la unica
-- columna con permiso de UPDATE para 'authenticated' es 'nombre'.
drop policy if exists "Auth users leen perfiles" on public.profiles;
-- "Ver perfil propio" existia en produccion sin figurar en schema.sql
-- (creada a mano en el panel): (id = auth.uid()) OR (get_my_rol() = 'admin').
-- Con 'admin' pasando a ser admin de UN cliente, le abria los perfiles de
-- TODOS los clientes. Lo legitimo que otorgaba ya lo cubre "Ver perfiles".
drop policy if exists "Ver perfil propio" on public.profiles;
drop policy if exists "Ver perfiles" on public.profiles;
create policy "Ver perfiles" on public.profiles
  for select to authenticated
  using (
    id = (select auth.uid())
    or (select public.es_superadmin())
    or cliente_id = (select public.mi_cliente())
  );

-- ---------- TAGS ----------
drop policy if exists "Leer tags autenticados" on public.tags;
drop policy if exists "Ver tags" on public.tags;
create policy "Ver tags" on public.tags
  for select to authenticated
  using ((select public.es_superadmin()) or cliente_id = (select public.mi_cliente()));

-- El with check impide que un admin cree un tag para otro cliente o
-- mueva uno propio a otro cliente.
drop policy if exists "Admin escribe tags" on public.tags;
create policy "Admin escribe tags" on public.tags
  for all to authenticated
  using      ((select public.es_superadmin()) or cliente_id = (select public.admin_de()))
  with check ((select public.es_superadmin()) or cliente_id = (select public.admin_de()));

-- ---------- LECTURAS ----------
drop policy if exists "User ve sus lecturas" on public.lecturas;
drop policy if exists "Ver lecturas" on public.lecturas;
create policy "Ver lecturas" on public.lecturas
  for select to authenticated
  using (
    user_id = (select auth.uid())
    or (select public.es_superadmin())
    or cliente_id = (select public.admin_de())
  );

drop policy if exists "Cualquier auth inserta lectura" on public.lecturas;
drop policy if exists "Insertar lectura propia" on public.lecturas;
create policy "Insertar lectura propia" on public.lecturas
  for insert to authenticated
  with check (user_id = (select auth.uid()));

drop policy if exists "Solo admin cambia estado" on public.lecturas;
drop policy if exists "Admin cambia estado" on public.lecturas;
create policy "Admin cambia estado" on public.lecturas
  for update to authenticated
  using      ((select public.es_superadmin()) or cliente_id = (select public.admin_de()))
  with check ((select public.es_superadmin()) or cliente_id = (select public.admin_de()));

drop policy if exists "Admin puede borrar lecturas" on public.lecturas;
drop policy if exists "Admin borra lecturas" on public.lecturas;
create policy "Admin borra lecturas" on public.lecturas
  for delete to authenticated
  using ((select public.es_superadmin()) or cliente_id = (select public.admin_de()));

-- ---------- AUDIT_LOG ----------
-- Sin politicas de escritura: solo escribe el trigger.
drop policy if exists "Admin lee audit" on public.audit_log;
create policy "Admin lee audit" on public.audit_log
  for select to authenticated
  using ((select public.es_superadmin()) or cliente_id = (select public.admin_de()));

-- ---------- MANTENIMIENTOS ----------
drop policy if exists "Ver mantenimientos" on public.mantenimientos;
create policy "Ver mantenimientos" on public.mantenimientos
  for select to authenticated
  using ((select public.es_superadmin()) or cliente_id = (select public.mi_cliente()));

-- Antes cualquier autenticado podia insertar (el rol se validaba solo
-- en la interfaz). Ahora solo admin y operador, o superadmin.
drop policy if exists "Insertar mantenimiento" on public.mantenimientos;
create policy "Insertar mantenimiento" on public.mantenimientos
  for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and ((select public.es_superadmin()) or (select public.equipo_de()) is not null)
  );

drop policy if exists "Admin actualiza mantenimiento" on public.mantenimientos;
create policy "Admin actualiza mantenimiento" on public.mantenimientos
  for update to authenticated
  using      ((select public.es_superadmin()) or cliente_id = (select public.admin_de()))
  with check ((select public.es_superadmin()) or cliente_id = (select public.admin_de()));

drop policy if exists "Admin borra mantenimiento" on public.mantenimientos;
create policy "Admin borra mantenimiento" on public.mantenimientos
  for delete to authenticated
  using ((select public.es_superadmin()) or cliente_id = (select public.admin_de()));

-- ---------- TAG_WRITES ----------
drop policy if exists "Admin gestiona writes" on public.tag_writes;
create policy "Admin gestiona writes" on public.tag_writes
  for all to authenticated
  using      ((select public.es_superadmin()))
  with check ((select public.es_superadmin()));

-- ---------- FOTOS ----------
-- Solo el equipo de terreno del cliente (admin y operador) las ve.
drop policy if exists "Ver fotos" on public.fotos;
create policy "Ver fotos" on public.fotos
  for select to authenticated
  using ((select public.es_superadmin()) or cliente_id = (select public.equipo_de()));

drop policy if exists "Operador y admin suben fotos" on public.fotos;
create policy "Operador y admin suben fotos" on public.fotos
  for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and ((select public.es_superadmin()) or (select public.equipo_de()) is not null)
  );

-- El operador borra las suyas; el admin, cualquiera de su cliente.
drop policy if exists "Borrar fotos" on public.fotos;
create policy "Borrar fotos" on public.fotos
  for delete to authenticated
  using (
    (select public.es_superadmin())
    or cliente_id = (select public.admin_de())
    or (user_id = (select auth.uid()) and cliente_id = (select public.equipo_de()))
  );

-- ---------- STORAGE (bucket fotos-tags) ----------
-- La primera carpeta de cada ruta es el tag_id: <tag_id>/<lectura_id>/<uuid>.jpg
-- Antes cualquier autenticado podia firmar URLs de CUALQUIER foto del
-- bucket conociendo la ruta. Ahora solo las de tags de su cliente.
drop policy if exists "Ver fotos del bucket" on storage.objects;
create policy "Ver fotos del bucket" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'fotos-tags'
    and (
      (select public.es_superadmin())
      or (storage.foldername(name))[1] in (
           select t.id::text from public.tags t
            where t.cliente_id = (select public.equipo_de()))
    )
  );

drop policy if exists "Subir fotos al bucket" on storage.objects;
create policy "Subir fotos al bucket" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'fotos-tags'
    and (
      (select public.es_superadmin())
      or (storage.foldername(name))[1] in (
           select t.id::text from public.tags t
            where t.cliente_id = (select public.equipo_de()))
    )
  );

drop policy if exists "Borrar fotos del bucket" on storage.objects;
create policy "Borrar fotos del bucket" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'fotos-tags'
    and (
      (select public.es_superadmin())
      or (storage.foldername(name))[1] in (
           select t.id::text from public.tags t
            where t.cliente_id = (select public.equipo_de()))
    )
  );

-- ============================================================
-- GESTION DE USUARIOS (la unica puerta para cambiar roles fuera
-- del SQL Editor)
-- ============================================================
-- rol y cliente_id no se pueden editar desde el navegador: la unica
-- columna de profiles con UPDATE para 'authenticated' es 'nombre'.
-- Estas dos funciones abren esa puerta con limites explicitos:
--
--   admin de cliente → solo 'operador' o 'user', solo en SU cliente,
--                      solo sobre cuentas sin asignar o ya suyas, y
--                      nunca sobre otro admin.
--   superadmin       → 'admin', 'operador' o 'user' en cualquier cliente.
--   'superadmin' NUNCA se asigna por aca: solo por SQL, a proposito.
--
-- Mensajes: si la cuenta es de otro cliente, se responde "no esta
-- disponible" sin decir de quien es.

create or replace function public.asignar_usuario(
  p_email   text,
  p_rol     text,
  p_cliente uuid default null)
returns text language plpgsql security definer set search_path = ''
as $$
declare
  v_super    boolean := public.es_superadmin();
  v_admin_de uuid    := public.admin_de();
  v_dest     public.profiles%rowtype;
  v_cliente  uuid;
begin
  if not v_super and v_admin_de is null then
    raise exception 'No tienes permiso para asignar usuarios';
  end if;
  if p_rol is null or p_rol not in ('admin', 'operador', 'user') then
    raise exception 'Rol no valido';
  end if;
  if p_rol = 'admin' and not v_super then
    raise exception 'Solo IoTeknica puede designar administradores';
  end if;

  select * into v_dest from public.profiles
   where lower(email) = lower(trim(p_email))
   for update;
  if not found then
    raise exception 'Todavia no hay ninguna cuenta con ese correo';
  end if;
  if v_dest.rol = 'superadmin' then
    raise exception 'Esa cuenta no esta disponible';
  end if;

  if v_super then
    v_cliente := p_cliente;
    if v_cliente is null then
      raise exception 'Indica a que cliente pertenece el usuario';
    end if;
    if not exists (select 1 from public.clientes c where c.id = v_cliente) then
      raise exception 'El cliente no existe';
    end if;
  else
    if p_cliente is not null and p_cliente <> v_admin_de then
      raise exception 'Solo puedes asignar usuarios a tu organizacion';
    end if;
    v_cliente := v_admin_de;
    -- La cuenta debe estar sin asignar o ser ya de este cliente, y no
    -- ser admin (eso tambien impide que un admin se cambie a si mismo).
    if (v_dest.cliente_id is not null and v_dest.cliente_id <> v_admin_de)
       or v_dest.rol = 'admin' then
      raise exception 'Esa cuenta no esta disponible';
    end if;
  end if;

  update public.profiles
     set rol = p_rol, cliente_id = v_cliente
   where id = v_dest.id;
  return 'ok';
end $$;

-- Devuelve la cuenta a 'user' sin cliente (pendiente): deja de ver todo.
create or replace function public.quitar_usuario(p_email text)
returns text language plpgsql security definer set search_path = ''
as $$
declare
  v_super    boolean := public.es_superadmin();
  v_admin_de uuid    := public.admin_de();
  v_dest     public.profiles%rowtype;
begin
  if not v_super and v_admin_de is null then
    raise exception 'No tienes permiso para quitar usuarios';
  end if;

  select * into v_dest from public.profiles
   where lower(email) = lower(trim(p_email))
   for update;
  if not found then
    raise exception 'No hay ninguna cuenta con ese correo';
  end if;
  if v_dest.rol = 'superadmin' then
    raise exception 'Esa cuenta no esta disponible';
  end if;
  if not v_super
     and (v_dest.cliente_id is distinct from v_admin_de or v_dest.rol = 'admin') then
    raise exception 'Esa cuenta no esta disponible';
  end if;

  update public.profiles
     set rol = 'user', cliente_id = null
   where id = v_dest.id;
  return 'ok';
end $$;

-- Supabase otorga EXECUTE a anon explicitamente sobre funciones nuevas
-- de public; revocarlo de 'public' solo no alcanza.
revoke execute on function public.asignar_usuario(text, text, uuid) from public, anon;
grant  execute on function public.asignar_usuario(text, text, uuid) to authenticated;
revoke execute on function public.quitar_usuario(text) from public, anon;
grant  execute on function public.quitar_usuario(text) to authenticated;

-- <<< FIN BLOQUE COMPARTIDO CON schema.sql <<<


-- Que PostgREST recargue el esquema y reconozca las columnas nuevas.
notify pgrst, 'reload schema';

commit;


-- ============================================================
-- OPERACIONES FRECUENTES (despues de migrar)
-- ============================================================

-- Crear un cliente
--   insert into public.clientes (nombre) values ('Minera Los Andes');

-- Ver los clientes y sus ids
--   select id, nombre, activo from public.clientes order by nombre;

-- Asignar un usuario a un cliente con su rol
--   update public.profiles
--      set rol = 'admin',
--          cliente_id = (select id from public.clientes where nombre = 'Minera Los Andes')
--    where email = 'jefe@minera.cl';

-- Mover un tag (y su historial) a otro cliente
--   with c as (select id from public.clientes where nombre = 'Minera Los Andes'),
--        t as (update public.tags set cliente_id = (select id from c)
--               where uid = 'TAG001' returning id)
--   update public.lecturas set cliente_id = (select id from c)
--    where tag_id in (select id from t);
--   (repetir el ultimo update para mantenimientos, fotos y audit_log)

-- Dar de baja un cliente sin borrar su historial
--   update public.clientes set activo = false where nombre = 'Minera Los Andes';
