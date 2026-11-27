# Avid MXF Folder — columna "MXF Folder" y separar por bines

Herramienta para **Avid Media Composer** (Windows y Mac).

## Qué hace

Escribe en una **columna personalizada** de los bins de Avid la carpeta numerada de `Avid MediaFiles/MXF` donde vive la media de cada clip (por ejemplo `1000`, o `1, 1000` si el clip tiene pistas repartidas en varias carpetas).

Con la opción **--rename-bins**, además renombra los bins cuyos clips vienen todos de una sola carpeta (por ejemplo, el bin que se arma arrastrando el `.mdb`) con el nombre de esa carpeta: `Proyecto Bin` → `1000_ENTREVISTA`.

Cómo lo logra:
1. Recorre las carpetas `Avid MediaFiles/MXF/<n>` de todos los discos y lee el header de cada `.mxf` (sin tocar los archivos) para sacar el UMID.
2. Abre cada bin (`.avb`), sigue la cadena clip → file mob y cruza los UMID.
3. Graba el resultado en la columna (por defecto "MXF Folder") y la agrega a la vista del bin.

## Requisitos

- Python 3 (en Windows, instalado con la casilla "Add python.exe to PATH").
- Librerías `pyavb` y `pyaaf2`: se instalan solas la primera vez (necesita internet).
- Probado con Media Composer 2026.8.

## Cómo se usa

**Importante:** cerrá Media Composer (o como mínimo los bins) antes de correrlo. Si Avid tiene el bin abierto, lo pisa al guardar. Hace backup de cada bin antes de modificarlo. Conviene probar primero con `--dry-run`.

- **Windows:** `Windows/Avid_MXF_Folder.bat` — doble clic, arrastrá el bin (`.avb`) a la ventana y Enter. (El `.bat` lleva el script de Python adentro: es un solo archivo.)
- **Mac:** `Mac/Avid_MXF_Folder.command` — doble clic, arrastrá el bin y Enter. Busca la media en todos los discos de `/Volumes`. Ver `Mac/LEEME.txt` para habilitar los scripts la primera vez (`xattr -cr`).

Hay un instructivo con capturas en `docs/Instructivo.docx`.

## Contenido

| Archivo | Para qué |
|---|---|
| `Windows/Avid_MXF_Folder.bat` | Versión Windows (lanzador + script en un solo archivo) |
| `Mac/Avid_MXF_Folder.py` | Script multiplataforma (Windows y Mac, Intel y Apple Silicon) |
| `Mac/Avid_MXF_Folder.command` | Lanzador para Mac (prepara Python solo) |
| `Mac/LEEME.txt` | Instrucciones de los scripts de Avid para Mac |
| `docs/Instructivo.docx` | Instructivo |

## Descargas (listo para usar)

El `.exe` compilado para Windows está en la carpeta **`descargas/`**.
