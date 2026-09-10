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

Cinco tablas en Supabase, todas con RLS activo:

- **profiles** — extiende `auth.users`. Campo `rol`: `admin` | `operador` | `user`.
  Un trigger `handle_new_user` crea la fila al registrarse.
- **tags** — el tag fisico. `uid` es el identificador que viaja en la URL
  (ej: `TAG001`), no el serial del chip. Nombre, lugar, lat/lng.
- **lecturas** — evento de escaneo. `estado`: `pendiente` | `revisado` |
  `aprobado` | `rechazado`.
- **mantenimientos** — texto libre asociado a un tag. `estado`: `borrador` |
  `aprobado` | `rechazado`. Los crea el operador, los aprueba el admin.
- **audit_log** — inmutable. Un trigger `log_estado_change` inserta aqui cada
  vez que cambia `lecturas.estado`.

El esquema completo con politicas RLS esta en `schema.sql`.

## Roles

| Accion | user | operador | admin |
|---|---|---|---|
| Leer tags | si | si | si |
| Ver historial propio | si | si | si |
| Agregar mantenimiento | no | si | si |
| Aprobar mantenimientos | no | no | si |
| Registrar tags | no | no | si |
| Cambiar estado de lecturas | no | no | si |
| Borrar lecturas | no | no | si |
| Acceso al dashboard | no | no | si |

El rol se asigna por SQL; no hay UI para cambiarlo. Y no la puede haber
mientras el rol siga siendo intocable desde el cliente — `authenticated` no
tiene permiso de UPDATE sobre `profiles.rol`, a proposito (ver Trampas).
El panel de invitacion genera este SQL listo para copiar:

```sql
UPDATE public.profiles SET rol = 'operador' WHERE email = 'x@y.com';
```

Dos filas de la tabla de arriba se aplican solo en la UI, no en la base:
**agregar mantenimiento** (la politica RLS deja insertar a cualquier
autenticado) y **acceso al dashboard** (no hay control de rol al entrar; el
menu de gestion se oculta con CSS). Un `user` que abra la consola puede
listar `profiles` y `mantenimientos` completos.

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
- UI para cambiar roles sin pasar por SQL.
- Cola offline con IndexedDB para lecturas sin señal (se diseño, no se
  implemento en la version URL-based).
- Volumen de tiles: OSM sirve para piloto, no para operacion masiva.
