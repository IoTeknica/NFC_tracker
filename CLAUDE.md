# NFC Tracker — IoTeknica

Sistema de trazabilidad de activos por tags NFC. Registra lecturas con GPS,
usuario y hora; permite registrar mantenimientos en terreno y gestionarlos
desde un dashboard web.

## Arquitectura

```
GitHub Pages (hosting estatico)
        │
        ├── index.html   → Dashboard web  (admin)
        └── pwa.html     → App movil PWA  (terreno)
                │
                └── Supabase (auth + PostgreSQL + realtime + RLS)
```

No hay build step, no hay framework, no hay dependencias npm. Son dos archivos
HTML autocontenidos (HTML + CSS + JS inline) que hablan directo con Supabase
via `@supabase/supabase-js@2` cargado por CDN. Cualquier cambio se despliega
subiendo el archivo a GitHub.

El unico recurso externo propio es `ioteknica-logo.png`, el logo de la barra
lateral del dashboard. Va junto a los HTML y se referencia con ruta relativa;
si se mueve o no se sube, el `<img>` cae al texto del `alt`. El archivo esta
a 3x (369x120) para pantallas retina y se muestra a 123x40. Se genero a
partir del logo original de IoTeknica: se le quito el fondo blanco (venia
opaco, sin canal alfa util), se recoloreo el azul marino a `--text` porque
sobre fondo oscuro no se leia, y se recorto el descriptor "CONSULTORIA",
ilegible a este tamano.

## URLs en produccion

| Recurso | URL |
|---|---|
| Dashboard | https://IoTeknica.github.io/NFC_tracker/ |
| PWA movil | https://IoTeknica.github.io/NFC_tracker/pwa.html |
| Repo | https://github.com/IoTeknica/NFC_tracker |
| Supabase | https://mcymkyzlvfktshzbucng.supabase.co |

Las credenciales de Supabase (URL + anon key) estan hardcodeadas cerca del
inicio del bloque `<script>` de cada archivo. La anon key es publica por
diseno — la seguridad real vive en las politicas RLS.

## Como funciona la lectura de tags

**Decision de arquitectura importante:** NO se usa la Web NFC API.

Se intento primero con `NDEFReader.scan()`, pero en Samsung con Android 10 la
promesa de `scan()` nunca resuelve — el stack NFC del sistema toma el chip
antes que Chrome. En Huawei con EMUI el problema es distinto: no hay Chrome
disponible (sin Google Play), y los navegadores alternativos no soportan la
API.

El enfoque actual es **URL-based**: cada tag fisico tiene grabada una URL con
el UID como query param.

```
https://IoTeknica.github.io/NFC_tracker/pwa.html?uid=TAG001
```

El usuario acerca el celular, Android abre el navegador con esa URL, la PWA
lee `?uid=` al cargar y registra la lectura. Funciona en cualquier telefono
con NFC sin depender de la Web NFC API.

Consecuencia: **la escritura de tags se hace siempre con NFC Tools**, no desde
la app. El panel Admin de la PWA genera la URL y la deja lista para copiar; el
admin la pega en NFC Tools (Write → Add a record → URL) y la graba en el chip.

## Modelo de datos

Siete tablas en Supabase, todas con RLS activo, mas un bucket de Storage.
**Es multi-cliente**: cada fila pertenece a un cliente y la base decide quien
la ve.

- **clientes** — las organizaciones. `activo = false` corta el acceso de
  todos sus usuarios sin borrar historial. Borrar un cliente con datos falla
  a proposito (FK sin cascade): se desactiva, no se borra.
- **profiles** — extiende `auth.users`. `rol`: `superadmin` | `admin` |
  `operador` | `user`. `cliente_id`: obligatorio para admin y operador, nulo
  para superadmin, opcional para user. Un trigger `handle_new_user` crea la
  fila al registrarse, como `user` sin cliente.
- **tags** — el tag fisico. `uid` es el identificador que viaja en la URL
  (ej: `TAG001`), no el serial del chip. Nombre, lugar, lat/lng. `uid` es
  unico en TODO el sistema, no por cliente: la URL del chip no dice de que
  cliente es.
- **lecturas** — evento de escaneo. `estado`: `pendiente` | `revisado` |
  `aprobado` | `rechazado`.
- **mantenimientos** — texto libre asociado a un tag. `estado`: `borrador` |
  `aprobado` | `rechazado`. Los crea el operador, los aprueba el admin.
- **audit_log** — inmutable. Un trigger `log_estado_change` inserta aqui cada
  vez que cambia `lecturas.estado`.
- **fotos** — fotografias del punto. Pertenecen a UNA visita (`lectura_id`) y
  se agrupan por punto (`tag_id`, denormalizado para que el dashboard no
  necesite el join con lecturas). En Postgres solo vive la ruta; el archivo
  esta en el bucket. `lectura_id` va con `ON DELETE SET NULL`: borrar una
  lectura no debe hacer desaparecer la evidencia del punto.

**`cliente_id` esta denormalizado** en profiles, tags, lecturas,
mantenimientos, fotos y audit_log, en vez de deducirse por join con tags: las
politicas quedan simples y rapidas, cubre lecturas de tags no registrados, y el
historial conserva su cliente aunque se borre la lectura.

**El cliente de cada fila lo pone la base, nunca el navegador.** Triggers
`security definer` lo asignan al insertar y rechazan colgar una lectura,
mantenimiento o foto de un tag de otro cliente. Una cuenta sin cliente activo
no puede registrar lecturas.

El bucket `fotos-tags` es **privado**. El dashboard muestra las fotos con URLs
firmadas (`createSignedUrls`), que caducan solas. Sus politicas deciden el
cliente de cada archivo por la primera carpeta de la ruta (el `tag_id`).

El esquema completo esta en `schema.sql`. La base de produccion se paso al
modelo multi-cliente una sola vez con `migracion_clientes.sql`, y
`verificar_clientes.sql` comprueba el aislamiento contra la base real.

## Roles

`superadmin` es IoTeknica y ve todos los clientes. Dentro de cada cliente hay
`admin`, `operador` y `user`.

| Accion | user | operador | admin | superadmin |
|---|---|---|---|---|
| Ver tags de su cliente | si | si | si | todos |
| Ver sus propias lecturas | si | si | todas las del cliente | todas |
| Ver mantenimientos | si | si | si | todos |
| Agregar mantenimiento | no | si | si | si |
| Ver y agregar fotos del punto | no | si | si | si |
| Aprobar mantenimientos | no | no | si | si |
| Registrar tags | no | no | en su cliente | en cualquiera |
| Cambiar estado / borrar lecturas | no | no | si | si |
| Gestionar operadores y users | no | no | de su cliente | de todos |
| Designar admins de cliente | no | no | no | si |
| Acceso al dashboard | no | no | si | si |

**Todo se valida en la base** (RLS, triggers y permisos de columna). La
interfaz solo decide que botones mostrar. Antes habia dos excepciones —alta de
mantenimientos y acceso al dashboard se controlaban solo en la UI—; ambas se
cerraron con el modelo multi-cliente. Es el criterio a seguir.

Por que `superadmin` aparte y no "operador con atribuciones de admin": el
operador ejecuta y el admin supervisa, fundirlos anula la aprobacion. Y falla
hacia el lado seguro: el error natural al dar de alta al admin de un cliente
(escribir `admin`) le da acceso solo a su cliente; el acceso global exige
escribir `superadmin` a proposito.

### Como se asignan roles y clientes

`rol` y `cliente_id` NO se pueden editar desde el navegador: la unica columna
de `profiles` con permiso de UPDATE para `authenticated` es `nombre` (ver
Trampas). Hay dos puertas, y solo dos:

1. **Dashboard, vista Usuarios** — usa las funciones `asignar_usuario()` y
   `quitar_usuario()` de la base, con limites explicitos:
   - el admin de un cliente asigna solo `operador` o `user`, solo en su
     cliente, solo sobre cuentas sin asignar o ya suyas, nunca sobre otro admin;
   - el superadmin asigna `admin`, `operador` o `user` en cualquier cliente;
   - si el correo es de otro cliente, el mensaje es "no esta disponible", sin
     revelar de quien es.
   La invitacion intenta asignar ANTES de enviar el correo, asi una cuenta de
   otro cliente se rechaza sin mandarle nada a nadie.
2. **SQL Editor** — lo unico que queda fuera de la app, a proposito: crear
   clientes y designar superadmins.

```sql
insert into public.clientes (nombre) values ('Minera Los Andes');
update public.profiles set rol = 'superadmin', cliente_id = null where email = 'x@ioteknica.cl';
```

## Fotos del punto

Operador y admin pueden adjuntar hasta **5 fotos por visita** al leer un tag.
El tope se valida en la base con el trigger `check_max_fotos`, no solo en la
UI. En el dashboard aparecen con el icono de camara al lado del de
mantenimientos, agrupadas por visita.

**La camara se abre con `<input type="file" capture="environment">`, NO con
`getUserMedia`.** Es la misma decision que con la Web NFC y por el mismo
motivo: `getUserMedia` pertenece a la familia de APIs que ya fallo en los
Huawei con EMUI (sin Chrome) y en el Samsung con Android 10. `capture` delega
en la app de camara del sistema y funciona en cualquier telefono. Ademas el
flujo pedido (tomar → guardar o descartar → tomar otra o salir) sale igual.

**Las fotos se comprimen antes de subir**, y no es opcional: una foto de
celular pesa entre 3 y 12 MB, asi que 5 serian hasta 60 MB subidos con datos
moviles desde terreno. Se redimensiona el lado largo a 1600px y se recodifica
a JPEG con calidad 0.7 — medido: 2,73 MB → 273 KB, y las cinco quedan en
~1,3 MB.

Si la fila de `fotos` falla despues de que el archivo ya subio, la app borra
el archivo para no dejar huerfanos en el bucket.

**Cada foto sube DOS archivos**: el original de 1600px (~275 KB) y una
miniatura de 320px (~11 KB). La ruta de la miniatura se deriva del original
(`<uuid>.jpg` → `<uuid>_thumb.jpg`), no hay columna aparte — asi no hizo
falta una migracion. Al borrar hay que quitar las dos.

El motivo es el egreso, no el espacio: la galeria dibuja cuadraditos de 92px,
y sin miniatura el navegador se baja el original entero para mostrarlos. Un
punto con 20 fotos pasaba de **5,37 MB a 0,21 MB** por apertura — 25 veces
menos. La miniatura solo suma ~4% de almacenamiento.

Las fotos subidas antes de este cambio no tienen miniatura. Los `<img>` de la
galeria llevan `onerror` que cae al original, asi que se siguen viendo.

Si la miniatura falla al generarse o subirse, la foto se guarda igual: es una
optimizacion, no un requisito.

**La galeria del dashboard esta paginada** de a 24 fotos (`FOTO_PAGINA`), con
un boton "ver mas". Un punto visitado cada semana durante dos años acumula
cientos de fotos y traerlas todas en cada apertura es lento y caro.

Pendiente: sin señal la subida falla. La cola offline sigue sin implementarse.

## Trampas conocidas

Cosas que ya costaron tiempo y no conviene volver a descubrir:

- **La URL de Supabase va sin `/rest/v1`.** El panel la muestra con ese sufijo;
  el cliente JS lo agrega solo.
- **Los joins de PostgREST necesitan hint explicito de FK** cuando hay mas de
  una relacion posible: `tags!lecturas_tag_id_fkey(...)`, no `tags(...)`.
- **RLS sola no protege columnas.** La politica "Editar perfil propio" limita
  QUE fila edita cada usuario (la suya), no QUE columnas. Sin restriccion
  extra, cualquiera se hacia admin con
  `update profiles set rol='admin' where id = <el suyo>` y de ahi pasaba
  todas las demas politicas. Se cierra con permisos de columna:
  `revoke update on profiles from authenticated` +
  `grant update (nombre) on profiles to authenticated`. El orden importa —
  un revoke por columna NO anula el permiso de tabla que Supabase da por
  defecto; hay que quitar el de tabla primero.
- **Escapar HTML no protege un `onclick`.** El navegador decodifica las
  entidades del atributo ANTES de pasar el texto al parser de JS, asi que un
  `&#39;` vuelve a ser comilla y rompe el string igual. Los datos de usuario
  que necesita un handler van en `data-*` y se leen con `dataset`.
- **`migracion_clientes.sql` y `schema.sql` comparten un bloque identico**
  (helpers, triggers, politicas y funciones de usuarios), entre las marcas
  `>>> INICIO BLOQUE COMPARTIDO` y `<<< FIN BLOQUE COMPARTIDO`. Si se cambia
  una politica, cambiarla en los dos, o schema.sql deja de reflejar produccion.
- **Desde el SQL Editor, `auth.uid()` es nulo** y los triggers lo interpretan
  como "proceso de servidor": respetan el `cliente_id` que se indique. Por eso
  crear un tag a mano exige pasar `cliente_id` — sin el falla con "Indica a
  que cliente pertenece el tag".
- **`verificar_clientes.sql` termina en ERROR a proposito.** Lanza una excepcion
  con el informe para que Postgres deshaga todos los datos de prueba. Leer el
  mensaje: si dice "N de N correctas", esta todo bien.
- **Un admin no distingue "UID inexistente" de "UID de otro cliente".** La RLS
  le oculta los tags ajenos. Al registrar un UID que ya usa otro cliente, recibe
  "Ese UID ya esta en uso" sin saber de quien es; y al escanearlo, "no registrado
  o no pertenece a tu organizacion". Es a proposito.
- **Los embeds a `clientes` llevan hint de FK** (`clientes!profiles_cliente_id_fkey`,
  `clientes!lecturas_cliente_id_fkey`): con `cliente_id` en seis tablas, mejor
  no dejar que PostgREST adivine el camino.
- **Una politica creada a mano en el panel de Supabase no aparece en
  `schema.sql`, y sigue activa.** Paso con "Ver perfil propio" en `profiles`:
  `(id = auth.uid()) OR (get_my_rol() = 'admin')`. Nunca estuvo en el
  archivo, asi que la migracion multi-cliente no la reemplazo; y como `admin`
  paso a significar "admin de UN cliente", le abria a cada admin los perfiles
  de todos los clientes. La detecto `verificar_clientes.sql`. Las politicas son
  permisivas y se suman: una sola de mas alcanza para abrir una fuga. Nunca
  crear politicas desde el panel sin agregarlas a `schema.sql`, y ante la duda
  listar lo que realmente hay con `select * from pg_policies`.
- **`get_my_rol()` debe ser `security definer`** o las politicas RLS sobre
  `profiles` entran en recursion infinita.
- **`getSession()` y `onAuthStateChange` juntos causan loop.** Solo uno maneja
  el arranque. `getSession()` ya procesa el token del magic link que viene en
  el hash de la URL.
- **`position: fixed` no funciona** dentro del iframe del preview. Los modales
  son paneles inline en el flujo normal.
- **Edge bloquea el storage de Supabase** con su tracking prevention y la
  sesion no persiste. Usar Chrome.
- **Borrar una lectura falla** si tiene filas en `audit_log`. El FK esta con
  `ON DELETE SET NULL` para permitirlo.
- **Supabase pausa el proyecto** tras 7 dias sin actividad en el plan free. Hay
  un monitor en UptimeRobot pingeando para evitarlo.
- **El mapa NO usa CARTO.** Desde agosto 2026 CARTO exige API key en
  `basemaps.cartocdn.com` y estampa "API KEY REQUIRED" sobre los tiles. Se
  migro a `tile.openstreetmap.org`, que no pide llave. Si el mapa se ve raro,
  revisar primero el proveedor de tiles.
- **Cache de GitHub Pages.** Tras subir un archivo hay que recargar con
  Ctrl+Shift+R o parece que el cambio no se aplico.

## Convenciones del codigo

- Todo en espanol: UI, comentarios, nombres de funciones de dominio.
- Paleta oscura definida en `:root` como CSS custom properties. Los tokens
  `--text-2` y `--text-3` ya se subieron una vez por contraste; no bajarlos.
- Fuentes: Syne (titulos), DM Sans (cuerpo), DM Mono (datos/tecnico),
  Space Grotesk (numeros KPI, con `tabular-nums`).
- El dashboard es SPA por `switchView(nombre)` que muestra/oculta divs
  `#view-*`. Agregar una vista implica: div nuevo, item en el sidebar, entrada
  en el array de `switchView` y en el objeto `titles`.
- Sin localStorage para datos de sesion (lo maneja el cliente de Supabase).

## Pendientes / ideas

- Editar tags (nombre, lugar, coordenadas) desde el dashboard; hoy solo se
  crean desde la PWA.
- UI para crear clientes (hoy por SQL).
- Cola offline con IndexedDB para lecturas sin señal (se diseño, no se
  implemento en la version URL-based).
- Volumen de tiles: OSM sirve para piloto, no para operacion masiva.
