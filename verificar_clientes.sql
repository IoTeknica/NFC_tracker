-- ============================================================
-- VERIFICACION del aislamiento por cliente
-- NFC Tracker — IoTeknica
--
-- Correr DESPUES de migracion_clientes.sql, en el SQL Editor.
--
-- NO DEJA NADA EN LA BASE. Crea datos de prueba, se hace pasar por
-- distintos usuarios (igual que hace Supabase con cada peticion real),
-- compara lo que ve y puede hacer cada uno con lo esperado, y al final
-- lanza un error A PROPOSITO para que Postgres deshaga todo.
--
-- El resultado aparece como "ERROR" en el editor. Es normal: lee el
-- mensaje. Si la primera linea dice "N de N correctas ✓", esta bien.
--
-- Las pruebas de "no puede" solo cuentan como correctas si el rechazo
-- es el esperado (politica RLS, permiso o excepcion del trigger). Un
-- error de otro tipo se informa como FALLA con su mensaje.
-- ============================================================

do $$
declare
  sfx text := substr(md5(random()::text), 1, 6);

  cA uuid; cB uuid;

  uS  uuid := gen_random_uuid();   -- superadmin
  uAa uuid := gen_random_uuid();   -- admin    A
  uAo uuid := gen_random_uuid();   -- operador A
  uAu uuid := gen_random_uuid();   -- user     A
  uBa uuid := gen_random_uuid();   -- admin    B
  uBo uuid := gen_random_uuid();   -- operador B
  uP  uuid := gen_random_uuid();   -- pendiente (sin cliente)
  uP2 uuid := gen_random_uuid();   -- pendiente, para asignar

  eS text; eAa text; eAo text; eAu text; eBa text; eBo text; eP text; eP2 text;

  tA uuid; tB uuid;
  lAo uuid; lAu uuid; lBo uuid;
  mA uuid; mB uuid;
  fA uuid; fB uuid;
  objA text; objB text;

  ids_tags  uuid[]; ids_lect uuid[]; ids_mant uuid[];
  ids_fotos uuid[]; ids_perf uuid[]; objs text[];
  storage_ok boolean := true;

  descs text[] := '{}';
  obt   int[]  := '{}';
  esp   int[]  := '{}';
  det   text[] := '{}';

  n int; d text; v_c uuid; v_r text;
  informe text[] := '{}';
  ok int := 0;
  i int;
begin
  -- Arrancar sin identidad: auth.uid() = null (como el SQL Editor)
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);

  -- ==========================================================
  -- DATOS DE PRUEBA (como postgres, sin RLS)
  -- ==========================================================
  insert into public.clientes (nombre) values ('ZZ_PRUEBA_A_' || sfx) returning id into cA;
  insert into public.clientes (nombre) values ('ZZ_PRUEBA_B_' || sfx) returning id into cB;

  eS  := 'zz-s-'  || sfx || '@prueba.invalid';
  eAa := 'zz-aa-' || sfx || '@prueba.invalid';
  eAo := 'zz-ao-' || sfx || '@prueba.invalid';
  eAu := 'zz-au-' || sfx || '@prueba.invalid';
  eBa := 'zz-ba-' || sfx || '@prueba.invalid';
  eBo := 'zz-bo-' || sfx || '@prueba.invalid';
  eP  := 'zz-p-'  || sfx || '@prueba.invalid';
  eP2 := 'zz-p2-' || sfx || '@prueba.invalid';

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  select u.id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         u.email, now(), now(), '{}'::jsonb, '{}'::jsonb
    from (values (uS, eS), (uAa, eAa), (uAo, eAo), (uAu, eAu),
                 (uBa, eBa), (uBo, eBo), (uP, eP), (uP2, eP2)) as u(id, email);

  -- Upsert: funciona haya disparado o no el trigger handle_new_user
  insert into public.profiles (id, email, rol, cliente_id)
  values (uS,  eS,  'superadmin', null),
         (uAa, eAa, 'admin',      cA),
         (uAo, eAo, 'operador',   cA),
         (uAu, eAu, 'user',       cA),
         (uBa, eBa, 'admin',      cB),
         (uBo, eBo, 'operador',   cB),
         (uP,  eP,  'user',       null),
         (uP2, eP2, 'user',       null)
  on conflict (id) do update set rol = excluded.rol, cliente_id = excluded.cliente_id;

  insert into public.tags (uid, nombre, lugar, cliente_id)
  values ('ZZ-' || sfx || '-A', 'Tag prueba A', 'Lugar A', cA) returning id into tA;
  insert into public.tags (uid, nombre, lugar, cliente_id)
  values ('ZZ-' || sfx || '-B', 'Tag prueba B', 'Lugar B', cB) returning id into tB;

  insert into public.lecturas (tag_id, user_id, estado) values (tA, uAo, 'pendiente') returning id into lAo;
  insert into public.lecturas (tag_id, user_id, estado) values (tA, uAu, 'pendiente') returning id into lAu;
  insert into public.lecturas (tag_id, user_id, estado) values (tB, uBo, 'pendiente') returning id into lBo;

  insert into public.mantenimientos (tag_id, user_id, texto) values (tA, uAo, 'prueba A') returning id into mA;
  insert into public.mantenimientos (tag_id, user_id, texto) values (tB, uBo, 'prueba B') returning id into mB;

  objA := tA::text || '/' || lAo::text || '/zz-' || sfx || '.jpg';
  objB := tB::text || '/' || lBo::text || '/zz-' || sfx || '.jpg';
  insert into public.fotos (lectura_id, tag_id, user_id, path) values (lAo, tA, uAo, objA) returning id into fA;
  insert into public.fotos (lectura_id, tag_id, user_id, path) values (lBo, tB, uBo, objB) returning id into fB;

  begin
    insert into storage.objects (bucket_id, name) values ('fotos-tags', objA), ('fotos-tags', objB);
  exception when others then
    storage_ok := false;
    informe := informe || ('  AVISO  No se pudieron crear objetos de storage de prueba: '
                           || sqlerrm || ' — se omiten esas pruebas');
  end;

  -- Un registro de auditoria del cliente B, para comprobar que A no lo ve
  update public.lecturas set estado = 'revisado' where id = lBo;

  ids_tags  := array[tA, tB];
  ids_lect  := array[lAo, lAu, lBo];
  ids_mant  := array[mA, mB];
  ids_fotos := array[fA, fB];
  ids_perf  := array[uS, uAa, uAo, uAu, uBa, uBo, uP, uP2];
  objs      := array[objA, objB];

  -- Comprobacion previa: los triggers asignaron bien el cliente
  select count(*)::int into n from public.lecturas where id = lAo and cliente_id = cA;
  descs := array_append(descs, 'Trigger: lectura del operador A queda en cliente A'::text); obt := obt || n; esp := esp || 1; det := array_append(det, ''::text);
  select count(*)::int into n from public.fotos where id = fB and cliente_id = cB;
  descs := array_append(descs, 'Trigger: foto del tag B queda en cliente B'::text);        obt := obt || n; esp := esp || 1; det := array_append(det, ''::text);


  -- ==========================================================
  -- SUPERADMIN: ve todo
  -- ==========================================================
  perform set_config('request.jwt.claims', json_build_object('sub', uS, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', uS::text, true);
  execute 'set local role authenticated';

  select count(*)::int into n from public.tags           where id = any(ids_tags);  descs := array_append(descs, 'Superadmin ve los tags de A y B'::text);          obt := obt || n; esp := esp || 2; det := array_append(det, ''::text);
  select count(*)::int into n from public.lecturas       where id = any(ids_lect);  descs := array_append(descs, 'Superadmin ve todas las lecturas'::text);         obt := obt || n; esp := esp || 3; det := array_append(det, ''::text);
  select count(*)::int into n from public.mantenimientos where id = any(ids_mant);  descs := array_append(descs, 'Superadmin ve todos los mantenimientos'::text);   obt := obt || n; esp := esp || 2; det := array_append(det, ''::text);
  select count(*)::int into n from public.fotos          where id = any(ids_fotos); descs := array_append(descs, 'Superadmin ve todas las fotos'::text);            obt := obt || n; esp := esp || 2; det := array_append(det, ''::text);
  select count(*)::int into n from public.profiles       where id = any(ids_perf);  descs := array_append(descs, 'Superadmin ve todos los perfiles'::text);         obt := obt || n; esp := esp || 8; det := array_append(det, ''::text);
  if storage_ok then
    select count(*)::int into n from storage.objects where name = any(objs);        descs := array_append(descs, 'Superadmin ve los archivos de A y B'::text);     obt := obt || n; esp := esp || 2; det := array_append(det, ''::text);
  end if;

  execute 'reset role';


  -- ==========================================================
  -- OPERADOR A
  -- ==========================================================
  perform set_config('request.jwt.claims', json_build_object('sub', uAo, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', uAo::text, true);
  execute 'set local role authenticated';

  select count(*)::int into n from public.tags           where id = any(ids_tags);  descs := array_append(descs, 'Operador A ve solo el tag de A'::text);            obt := obt || n; esp := esp || 1; det := array_append(det, ''::text);
  select count(*)::int into n from public.lecturas       where id = any(ids_lect);  descs := array_append(descs, 'Operador A ve solo su propia lectura'::text);      obt := obt || n; esp := esp || 1; det := array_append(det, ''::text);
  select count(*)::int into n from public.mantenimientos where id = any(ids_mant);  descs := array_append(descs, 'Operador A ve solo mantenimientos de A'::text);    obt := obt || n; esp := esp || 1; det := array_append(det, ''::text);
  select count(*)::int into n from public.fotos          where id = any(ids_fotos); descs := array_append(descs, 'Operador A ve solo fotos de A'::text);             obt := obt || n; esp := esp || 1; det := array_append(det, ''::text);
  select count(*)::int into n from public.profiles       where id = any(ids_perf);  descs := array_append(descs, 'Operador A ve solo perfiles de A'::text);          obt := obt || n; esp := esp || 3; det := array_append(det, ''::text);
  if storage_ok then
    select count(*)::int into n from storage.objects where name = any(objs);        descs := array_append(descs, 'Operador A ve solo archivos de A'::text);         obt := obt || n; esp := esp || 1; det := array_append(det, ''::text);
  end if;

  select count(*)::int into n from public.audit_log where lectura_id = any(ids_lect);
  descs := array_append(descs, 'Operador A NO ve auditoria'::text); obt := obt || n; esp := esp || 0; det := array_append(det, ''::text);

  begin
    insert into public.lecturas (tag_id, user_id, estado) values (tB, uAo, 'pendiente');
    n := 0; d := 'se permitio';
  exception when others then
    if sqlstate in ('P0001', '42501') then n := 1; d := ''; else n := 0; d := sqlstate || ' ' || sqlerrm; end if;
  end;
  descs := array_append(descs, 'Operador A NO registra lectura en tag de B'::text); obt := obt || n; esp := esp || 1; det := array_append(det, d);

  begin
    insert into public.mantenimientos (tag_id, user_id, texto) values (tA, uAo, 'nuevo A');
    n := 1; d := '';
  exception when others then n := 0; d := sqlstate || ' ' || sqlerrm; end;
  descs := array_append(descs, 'Operador A SI crea mantenimiento en su tag'::text); obt := obt || n; esp := esp || 1; det := array_append(det, d);

  begin
    insert into public.mantenimientos (tag_id, user_id, texto) values (tB, uAo, 'intruso');
    n := 0; d := 'se permitio';
  exception when others then
    if sqlstate in ('P0001', '42501') then n := 1; d := ''; else n := 0; d := sqlstate || ' ' || sqlerrm; end if;
  end;
  descs := array_append(descs, 'Operador A NO crea mantenimiento en tag de B'::text); obt := obt || n; esp := esp || 1; det := array_append(det, d);

  begin
    insert into public.fotos (lectura_id, tag_id, user_id, path)
    values (lAo, tB, uAo, tB::text || '/intruso-' || sfx || '.jpg');
    n := 0; d := 'se permitio';
  exception when others then
    if sqlstate in ('P0001', '42501') then n := 1; d := ''; else n := 0; d := sqlstate || ' ' || sqlerrm; end if;
  end;
  descs := array_append(descs, 'Operador A NO sube foto a tag de B'::text); obt := obt || n; esp := esp || 1; det := array_append(det, d);

  update public.lecturas set estado = 'aprobado' where id = lAo;
  get diagnostics n = row_count;
  descs := array_append(descs, 'Operador A NO aprueba ni su propia lectura'::text); obt := obt || n; esp := esp || 0; det := array_append(det, ''::text);

  begin
    update public.profiles set rol = 'superadmin' where id = uAo;
    n := 0; d := 'se permitio';
  exception when others then
    if sqlstate = '42501' then n := 1; d := ''; else n := 0; d := sqlstate || ' ' || sqlerrm; end if;
  end;
  descs := array_append(descs, 'Operador A NO cambia su propio rol'::text); obt := obt || n; esp := esp || 1; det := array_append(det, d);

  begin
    update public.profiles set cliente_id = cB where id = uAo;
    n := 0; d := 'se permitio';
  exception when others then
    if sqlstate = '42501' then n := 1; d := ''; else n := 0; d := sqlstate || ' ' || sqlerrm; end if;
  end;
  descs := array_append(descs, 'Operador A NO se cambia de cliente'::text); obt := obt || n; esp := esp || 1; det := array_append(det, d);

  begin
    perform public.asignar_usuario(eP2, 'user');
    n := 0; d := 'se permitio';
  exception when others then
    if sqlstate = 'P0001' then n := 1; d := ''; else n := 0; d := sqlstate || ' ' || sqlerrm; end if;
  end;
  descs := array_append(descs, 'Operador A NO puede asignar usuarios'::text); obt := obt || n; esp := esp || 1; det := array_append(det, d);

  execute 'reset role';


  -- ==========================================================
  -- USER A
  -- ==========================================================
  perform set_config('request.jwt.claims', json_build_object('sub', uAu, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', uAu::text, true);
  execute 'set local role authenticated';

  select count(*)::int into n from public.tags     where id = any(ids_tags);  descs := array_append(descs, 'User A ve el tag de A'::text);                 obt := obt || n; esp := esp || 1; det := array_append(det, ''::text);
  select count(*)::int into n from public.lecturas where id = any(ids_lect);  descs := array_append(descs, 'User A ve solo su propia lectura'::text);      obt := obt || n; esp := esp || 1; det := array_append(det, ''::text);
  select count(*)::int into n from public.fotos    where id = any(ids_fotos); descs := array_append(descs, 'User A NO ve fotos'::text);                    obt := obt || n; esp := esp || 0; det := array_append(det, ''::text);
  if storage_ok then
    select count(*)::int into n from storage.objects where name = any(objs);  descs := array_append(descs, 'User A NO ve archivos'::text);                obt := obt || n; esp := esp || 0; det := array_append(det, ''::text);
  end if;

  begin
    insert into public.mantenimientos (tag_id, user_id, texto) values (tA, uAu, 'no deberia');
    n := 0; d := 'se permitio';
  exception when others then
    if sqlstate in ('P0001', '42501') then n := 1; d := ''; else n := 0; d := sqlstate || ' ' || sqlerrm; end if;
  end;
  descs := array_append(descs, 'User A NO crea mantenimientos'::text); obt := obt || n; esp := esp || 1; det := array_append(det, d);

  execute 'reset role';


  -- ==========================================================
  -- OPERADOR B
  -- ==========================================================
  perform set_config('request.jwt.claims', json_build_object('sub', uBo, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', uBo::text, true);
  execute 'set local role authenticated';

  select count(*)::int into n from public.tags     where id = any(ids_tags);  descs := array_append(descs, 'Operador B ve solo el tag de B'::text);       obt := obt || n; esp := esp || 1; det := array_append(det, ''::text);
  select count(*)::int into n from public.fotos    where id = any(ids_fotos); descs := array_append(descs, 'Operador B ve solo fotos de B'::text);        obt := obt || n; esp := esp || 1; det := array_append(det, ''::text);
  select count(*)::int into n from public.profiles where id = any(ids_perf);  descs := array_append(descs, 'Operador B ve solo perfiles de B'::text);     obt := obt || n; esp := esp || 2; det := array_append(det, ''::text);
  select count(*)::int into n from public.fotos    where id = fA;             descs := array_append(descs, 'Operador B NO ve la foto de A'::text);        obt := obt || n; esp := esp || 0; det := array_append(det, ''::text);

  execute 'reset role';


  -- ==========================================================
  -- CUENTA PENDIENTE (sin cliente): no ve nada, no registra nada
  -- ==========================================================
  perform set_config('request.jwt.claims', json_build_object('sub', uP, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', uP::text, true);
  execute 'set local role authenticated';

  select count(*)::int into n from public.tags           where id = any(ids_tags);  descs := array_append(descs, 'Pendiente NO ve tags'::text);              obt := obt || n; esp := esp || 0; det := array_append(det, ''::text);
  select count(*)::int into n from public.mantenimientos where id = any(ids_mant);  descs := array_append(descs, 'Pendiente NO ve mantenimientos'::text);    obt := obt || n; esp := esp || 0; det := array_append(det, ''::text);
  select count(*)::int into n from public.profiles       where id = any(ids_perf);  descs := array_append(descs, 'Pendiente ve solo su perfil'::text);       obt := obt || n; esp := esp || 1; det := array_append(det, ''::text);
  select count(*)::int into n from public.clientes       where id in (cA, cB);      descs := array_append(descs, 'Pendiente NO ve clientes'::text);          obt := obt || n; esp := esp || 0; det := array_append(det, ''::text);

  begin
    insert into public.lecturas (tag_id, user_id, estado) values (null, uP, 'pendiente');
    n := 0; d := 'se permitio';
  exception when others then
    if sqlstate in ('P0001', '42501') then n := 1; d := ''; else n := 0; d := sqlstate || ' ' || sqlerrm; end if;
  end;
  descs := array_append(descs, 'Pendiente NO registra lecturas'::text); obt := obt || n; esp := esp || 1; det := array_append(det, d);

  execute 'reset role';


  -- ==========================================================
  -- ADMIN A: ve y gestiona solo lo suyo
  -- ==========================================================
  perform set_config('request.jwt.claims', json_build_object('sub', uAa, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', uAa::text, true);
  execute 'set local role authenticated';

  select count(*)::int into n from public.tags           where id = any(ids_tags);  descs := array_append(descs, 'Admin A ve solo el tag de A'::text);               obt := obt || n; esp := esp || 1; det := array_append(det, ''::text);
  select count(*)::int into n from public.lecturas       where id = any(ids_lect);  descs := array_append(descs, 'Admin A ve las 2 lecturas de A'::text);            obt := obt || n; esp := esp || 2; det := array_append(det, ''::text);
  select count(*)::int into n from public.fotos          where id = any(ids_fotos); descs := array_append(descs, 'Admin A ve solo fotos de A'::text);                obt := obt || n; esp := esp || 1; det := array_append(det, ''::text);
  select count(*)::int into n from public.profiles       where id = any(ids_perf);  descs := array_append(descs, 'Admin A ve solo perfiles de A'::text);             obt := obt || n; esp := esp || 3; det := array_append(det, ''::text);
  select count(*)::int into n from public.clientes       where id in (cA, cB);      descs := array_append(descs, 'Admin A ve solo su cliente'::text);                obt := obt || n; esp := esp || 1; det := array_append(det, ''::text);
  if storage_ok then
    select count(*)::int into n from storage.objects where name = any(objs);        descs := array_append(descs, 'Admin A ve solo archivos de A'::text);            obt := obt || n; esp := esp || 1; det := array_append(det, ''::text);
  end if;

  select count(*)::int into n from public.mantenimientos where id = any(ids_mant);
  descs := array_append(descs, 'Admin A ve solo mantenimientos de A'::text); obt := obt || n; esp := esp || 1; det := array_append(det, ''::text);
  select count(*)::int into n from public.audit_log where lectura_id = lBo;
  descs := array_append(descs, 'Admin A NO ve auditoria de B'::text); obt := obt || n; esp := esp || 0; det := array_append(det, ''::text);

  update public.lecturas set estado = 'aprobado' where id = lBo;
  get diagnostics n = row_count;
  descs := array_append(descs, 'Admin A NO cambia estado de lectura de B'::text); obt := obt || n; esp := esp || 0; det := array_append(det, ''::text);

  update public.lecturas set estado = 'revisado' where id = lAo;
  get diagnostics n = row_count;
  descs := array_append(descs, 'Admin A SI cambia estado de lectura de A'::text); obt := obt || n; esp := esp || 1; det := array_append(det, ''::text);

  select count(*)::int into n from public.audit_log where lectura_id = lAo and cliente_id = cA;
  descs := array_append(descs, 'El cambio queda en auditoria, con cliente A'::text); obt := obt || n; esp := esp || 1; det := array_append(det, ''::text);

  begin
    insert into public.tags (uid, nombre, lugar) values ('ZZ-' || sfx || '-A2', 'Nuevo', 'Lugar')
    returning cliente_id into v_c;
    n := case when v_c = cA then 1 else 0 end;
    d := case when v_c = cA then '' else 'quedo en otro cliente' end;
  exception when others then n := 0; d := sqlstate || ' ' || sqlerrm; end;
  descs := array_append(descs, 'Admin A crea tag sin indicar cliente: queda en A'::text); obt := obt || n; esp := esp || 1; det := array_append(det, d);

  begin
    insert into public.tags (uid, nombre, lugar, cliente_id) values ('ZZ-' || sfx || '-B2', 'Intruso', 'Lugar', cB);
    n := 0; d := 'se permitio';
  exception when others then
    if sqlstate in ('P0001', '42501') then n := 1; d := ''; else n := 0; d := sqlstate || ' ' || sqlerrm; end if;
  end;
  descs := array_append(descs, 'Admin A NO crea tags para B'::text); obt := obt || n; esp := esp || 1; det := array_append(det, d);

  begin
    update public.profiles set rol = 'superadmin' where id = uAa;
    n := 0; d := 'se permitio';
  exception when others then
    if sqlstate = '42501' then n := 1; d := ''; else n := 0; d := sqlstate || ' ' || sqlerrm; end if;
  end;
  descs := array_append(descs, 'Admin A NO se hace superadmin editando su perfil'::text); obt := obt || n; esp := esp || 1; det := array_append(det, d);

  -- Gestion de usuarios: rechazos
  begin perform public.asignar_usuario(eP2, 'admin'); n := 0; d := 'se permitio';
  exception when others then if sqlstate = 'P0001' then n := 1; d := ''; else n := 0; d := sqlstate || ' ' || sqlerrm; end if; end;
  descs := array_append(descs, 'Admin A NO designa administradores'::text); obt := obt || n; esp := esp || 1; det := array_append(det, d);

  begin perform public.asignar_usuario(eP2, 'user', cB); n := 0; d := 'se permitio';
  exception when others then if sqlstate = 'P0001' then n := 1; d := ''; else n := 0; d := sqlstate || ' ' || sqlerrm; end if; end;
  descs := array_append(descs, 'Admin A NO asigna usuarios al cliente B'::text); obt := obt || n; esp := esp || 1; det := array_append(det, d);

  begin perform public.asignar_usuario(eBo, 'user'); n := 0; d := 'se permitio';
  exception when others then if sqlstate = 'P0001' then n := 1; d := ''; else n := 0; d := sqlstate || ' ' || sqlerrm; end if; end;
  descs := array_append(descs, 'Admin A NO toma al operador de B'::text); obt := obt || n; esp := esp || 1; det := array_append(det, d);

  begin perform public.asignar_usuario(eS, 'user'); n := 0; d := 'se permitio';
  exception when others then if sqlstate = 'P0001' then n := 1; d := ''; else n := 0; d := sqlstate || ' ' || sqlerrm; end if; end;
  descs := array_append(descs, 'Admin A NO toca al superadmin'::text); obt := obt || n; esp := esp || 1; det := array_append(det, d);

  begin perform public.asignar_usuario(eAa, 'superadmin'); n := 0; d := 'se permitio';
  exception when others then if sqlstate = 'P0001' then n := 1; d := ''; else n := 0; d := sqlstate || ' ' || sqlerrm; end if; end;
  descs := array_append(descs, 'Admin A NO se asigna superadmin por la funcion'::text); obt := obt || n; esp := esp || 1; det := array_append(det, d);

  begin perform public.quitar_usuario(eBo); n := 0; d := 'se permitio';
  exception when others then if sqlstate = 'P0001' then n := 1; d := ''; else n := 0; d := sqlstate || ' ' || sqlerrm; end if; end;
  descs := array_append(descs, 'Admin A NO quita usuarios de B'::text); obt := obt || n; esp := esp || 1; det := array_append(det, d);

  -- Gestion de usuarios: lo permitido
  begin perform public.asignar_usuario(eP2, 'operador'); n := 1; d := '';
  exception when others then n := 0; d := sqlstate || ' ' || sqlerrm; end;
  descs := array_append(descs, 'Admin A SI asigna una cuenta pendiente como operador'::text); obt := obt || n; esp := esp || 1; det := array_append(det, d);

  begin perform public.quitar_usuario(eAu); n := 1; d := '';
  exception when others then n := 0; d := sqlstate || ' ' || sqlerrm; end;
  descs := array_append(descs, 'Admin A SI quita a un user de A'::text); obt := obt || n; esp := esp || 1; det := array_append(det, d);

  execute 'reset role';

  select count(*)::int into n from public.profiles where id = uP2 and rol = 'operador' and cliente_id = cA;
  descs := array_append(descs, '  → la cuenta quedo como operador de A'::text); obt := obt || n; esp := esp || 1; det := array_append(det, ''::text);
  select count(*)::int into n from public.profiles where id = uAu and rol = 'user' and cliente_id is null;
  descs := array_append(descs, '  → el user quitado quedo pendiente'::text);    obt := obt || n; esp := esp || 1; det := array_append(det, ''::text);


  -- ==========================================================
  -- SUPERADMIN designa un admin de cliente
  -- ==========================================================
  perform set_config('request.jwt.claims', json_build_object('sub', uS, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', uS::text, true);
  execute 'set local role authenticated';

  begin perform public.asignar_usuario(eP, 'admin', cB); n := 1; d := '';
  exception when others then n := 0; d := sqlstate || ' ' || sqlerrm; end;
  descs := array_append(descs, 'Superadmin SI designa admin del cliente B'::text); obt := obt || n; esp := esp || 1; det := array_append(det, d);

  execute 'reset role';

  select count(*)::int into n from public.profiles where id = uP and rol = 'admin' and cliente_id = cB;
  descs := array_append(descs, '  → la cuenta quedo como admin de B'::text); obt := obt || n; esp := esp || 1; det := array_append(det, ''::text);


  -- ==========================================================
  -- CLIENTE DESACTIVADO: sus usuarios pierden el acceso
  -- ==========================================================
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  update public.clientes set activo = false where id = cA;

  perform set_config('request.jwt.claims', json_build_object('sub', uAa, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', uAa::text, true);
  execute 'set local role authenticated';

  select count(*)::int into n from public.tags where id = any(ids_tags);
  descs := array_append(descs, 'Con A desactivado, su admin NO ve sus tags'::text); obt := obt || n; esp := esp || 0; det := array_append(det, ''::text);

  execute 'reset role';


  -- ==========================================================
  -- INFORME y DESHACER TODO
  -- ==========================================================
  for i in 1 .. coalesce(array_length(descs, 1), 0) loop
    if obt[i] = esp[i] then
      ok := ok + 1;
      informe := informe || ('  OK     ' || descs[i]);
    else
      informe := informe || ('  FALLA  ' || descs[i] || '  (obtuvo ' || obt[i]
                             || ', esperado ' || esp[i]
                             || coalesce(' · ' || nullif(det[i], ''), '') || ')');
    end if;
  end loop;

  raise exception using message = format(
    E'VERIFICACION DE CLIENTES: %s de %s correctas%s\n\n%s\n\n'
    'Este "error" es intencional: deshace todos los datos de prueba.',
    ok, array_length(descs, 1),
    case when ok = array_length(descs, 1) then ' ✓' else '  —  HAY FALLAS' end,
    array_to_string(informe, E'\n'));
end $$;
