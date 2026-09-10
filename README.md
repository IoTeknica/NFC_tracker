# NFC Tracker

Trazabilidad de activos por tags NFC. Registro de lecturas con GPS y control
de mantenimiento en terreno.

**IoTeknica**

## Archivos

| Archivo | Que es |
|---|---|
| `index.html` | Dashboard web — gestion, mapa, historial, usuarios, auditoria |
| `pwa.html` | App movil — lectura de tags y registro de mantenimientos |
| `schema.sql` | Esquema de Supabase con politicas RLS |
| `CLAUDE.md` | Contexto tecnico del proyecto |
| `ioteknica-logo.png` | Logo de la barra lateral del dashboard |

Sin build step. Los HTML son autocontenidos salvo por el logo, que va como
archivo aparte junto a ellos; todo se despliega subiendolo a GitHub Pages.

## Desplegar

Subir el archivo modificado al repo (Add file → Upload files → commit).
GitHub Pages publica en 1-2 minutos. Recargar con **Ctrl+Shift+R** — sin eso
el navegador sigue mostrando la version anterior.

## Levantar un entorno nuevo

1. Crear proyecto en Supabase
2. Ejecutar `schema.sql` completo en el SQL Editor
3. Reemplazar `SUPABASE_URL` y `SUPABASE_KEY` en ambos HTML
   (la URL va **sin** `/rest/v1`)
4. Authentication → URL Configuration → agregar la URL de la PWA como
   Site URL y como Redirect URL
5. Crear el primer usuario y darle rol admin por SQL

## Instalar un tag nuevo

1. PWA → pestana Admin → registrar UID, nombre y lugar
2. Copiar la URL que genera el panel
3. NFC Tools → Write → Add a record → URL → pegar → grabar en el chip
4. Instalar el tag fisico

La escritura del chip se hace siempre con NFC Tools, no desde la app.

## Desarrollo local

```bash
python -m http.server 8080
```

Abrir `http://localhost:8080/index.html`. No sirve abrir el archivo con
doble clic: `file://` es un origen unico y Supabase no autentica.
