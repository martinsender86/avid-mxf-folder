@echo off & (where python >nul 2>&1 || (echo No encuentro Python. Reinstalalo tildando Add python.exe to PATH. & pause & exit /b)) & python -x "%~f0" %* & echo. & pause & exit /b
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
avid_mxf_folder_column.py

Escribe en una columna custom de los bins de Avid Media Composer la carpeta
numerada de "Avid MediaFiles/MXF" donde vive la media de cada clip
(por ejemplo "1000", o "1, 1000" si el clip tiene pistas repartidas).

Cómo funciona:
  1. Recorre las carpetas Avid MediaFiles/MXF/<n> de los discos y lee el header
     de cada .mxf (sin tocar los archivos) para sacar el UMID del file package.
  2. Abre cada bin (.avb), sigue la cadena clip -> file mob y cruza los UMID.
  3. Graba el resultado en la columna custom (por defecto "MXF Folder") y la
     agrega a la vista del bin.
  4. Con --rename-bins, renombra los bins cuyos clips vienen todos de una
     sola carpeta (por ej. el bin armado arrastrando el .mdb) con el nombre
     de esa carpeta: "Proyecto Bin" -> "1000_ENTREVISTA".

IMPORTANTE:
  - Cerrá Media Composer (o como mínimo cerrá los bins) antes de correrlo.
    Si Avid tiene el bin abierto, lo va a pisar al guardar.
  - Por defecto hace backup de cada bin antes de modificarlo.
  - Probalo primero con --dry-run.

Requisitos:  pip install pyavb pyaaf2
"""

import argparse
import datetime
import glob
import json
import os
import re
import shutil
import string
import sys
import tempfile

try:
    import avb
    import aaf2.mxf as mxf
except ImportError:
    import subprocess
    print("Instalando librerías (solo la primera vez)...")
    subprocess.call([sys.executable, "-m", "pip", "install", "pyavb", "pyaaf2"])
    try:
        import avb
        import aaf2.mxf as mxf
    except ImportError:
        sys.exit("\nNo se pudieron instalar las librerías. Copiá el texto de arriba y pasáselo a Claude.")


MEDIA_SUBPATH = os.path.join("Avid MediaFiles", "MXF")
USER_COLUMN_FORMAT = 2   # texto editable
USER_COLUMN_TYPE = 40    # columna de usuario (custom)
NOT_FOUND = "SIN MEDIA"
LINKED = "LINK"


# ---------------------------------------------------------------------------
# 1. Indexar MXF
# ---------------------------------------------------------------------------

def default_media_roots():
    """Busca Avid MediaFiles/MXF en todos los discos montados."""
    roots = []
    if sys.platform == "darwin":
        candidates = glob.glob("/Volumes/*")
    elif os.name == "nt":
        candidates = ["%s:\\" % d for d in string.ascii_uppercase]
    else:
        candidates = glob.glob("/mnt/*") + glob.glob("/media/*/*")
    for c in candidates:
        p = os.path.join(c, MEDIA_SUBPATH)
        if os.path.isdir(p):
            roots.append(p)
    return roots


def normalize_media_root(path):
    """Acepta el disco, la carpeta Avid MediaFiles o la carpeta MXF."""
    path = os.path.abspath(os.path.expanduser(path))
    for cand in (path, os.path.join(path, "MXF"), os.path.join(path, MEDIA_SUBPATH)):
        if os.path.basename(cand.rstrip("\\/")) == "MXF" and os.path.isdir(cand):
            return cand
    return None


def drive_label(mxf_root):
    """Nombre del volumen a partir de .../<Disco>/Avid MediaFiles/MXF."""
    vol = os.path.dirname(os.path.dirname(mxf_root.rstrip("\\/")))
    name = os.path.basename(vol.rstrip("\\/"))
    return name or vol.rstrip("\\/")


def norm_umid(value):
    return str(value).strip().lower()


def read_file_package_ids(path):
    """Devuelve los UMID de file package de un MXF OP-Atom (solo lee el header)."""
    f = mxf.MXFFile(path)
    ids = set()
    for obj in f.objects.values():
        if isinstance(obj, mxf.MXFEssenceData) and "MobID" in obj.data:
            ids.add(norm_umid(obj.data["MobID"]))
    if not ids:  # fallback: todos los source packages que no sean de cinta
        for pkg in f.packages():
            if isinstance(pkg, mxf.MXFSourcePackage):
                d = pkg.resolve_ref("Descriptor") if "Descriptor" in pkg.data else None
                if d is not None and not isinstance(d, mxf.MXFTapeDescriptor):
                    ids.add(norm_umid(pkg.mob_id))
    return ids


def build_mxf_index(mxf_roots, with_drive, cache_path=None, verbose=False):
    """{umid: set(["1000", ...])}"""
    cache = {}
    if cache_path and os.path.isfile(cache_path):
        try:
            with open(cache_path, "r", encoding="utf-8") as fh:
                cache = json.load(fh)
        except Exception:
            cache = {}
    new_cache = {}
    index = {}
    total = errors = 0

    for root in mxf_roots:
        label = drive_label(root)
        for folder in sorted(os.listdir(root)):
            folder_path = os.path.join(root, folder)
            if not os.path.isdir(folder_path):
                continue
            value = "%s:%s" % (label, folder) if with_drive else folder
            count = 0
            for entry in os.scandir(folder_path):
                if not entry.is_file() or not entry.name.lower().endswith(".mxf"):
                    continue
                st = entry.stat()
                key = "%s|%d|%d" % (entry.path, st.st_size, int(st.st_mtime))
                ids = cache.get(key)
                if ids is None:
                    try:
                        ids = sorted(read_file_package_ids(entry.path))
                    except Exception as e:
                        errors += 1
                        if verbose:
                            print("   ! no se pudo leer %s: %s" % (entry.path, e))
                        ids = []
                new_cache[key] = ids
                for umid in ids:
                    index.setdefault(umid, set()).add(value)
                count += 1
            total += count
            print("   %-40s %6d MXF" % (os.path.join(label, "MXF", folder), count))

    if cache_path:
        try:
            with open(cache_path, "w", encoding="utf-8") as fh:
                json.dump(new_cache, fh)
        except Exception as e:
            print("   ! no se pudo guardar la caché: %s" % e)

    print("   Total: %d archivos MXF, %d UMIDs%s" %
          (total, len(index), (", %d con error" % errors) if errors else ""))
    return index


# ---------------------------------------------------------------------------
# 2. Resolver clips del bin
# ---------------------------------------------------------------------------

SKIP_KEYS = {"descriptor", "attributes", "root"}


def iter_children(obj):
    """Recorre genéricamente componentes pyavb (sequences, efectos, etc.)."""
    data = getattr(obj, "property_data", None)
    if data is None:
        return
    for k in list(data.keys()):
        if k in SKIP_KEYS:
            continue
        try:
            v = getattr(obj, k)          # resuelve referencias
        except Exception:
            continue
        if hasattr(v, "property_data"):
            yield v
        elif isinstance(v, (list, tuple)) or type(v).__name__.endswith("List"):
            try:
                for item in v:
                    if hasattr(item, "property_data"):
                        yield item
            except Exception:
                pass


def resolve_folders(mob, mobs_by_id, index):
    """Devuelve (set de carpetas, hay_file_mob_sin_media, hay_link)."""
    folders = set()
    missing = False
    linked = False
    seen_mobs = set()
    seen_objs = set()
    alive = []   # mantiene vivos los objetos visitados (evita reuso de id())
    stack = [mob]

    while stack:
        obj = stack.pop()
        if obj is None or id(obj) in seen_objs:
            continue
        seen_objs.add(id(obj))
        alive.append(obj)
        cls = type(obj).__name__

        if hasattr(obj, "mob_type") and hasattr(obj, "mob_id"):
            mid = norm_umid(obj.mob_id)
            if mid in seen_mobs:
                continue
            seen_mobs.add(mid)
            if mid in index:
                folders |= index[mid]
                continue
            if getattr(obj, "mob_type", "") == "SourceMob":
                desc = getattr(obj, "descriptor", None) if "descriptor" in obj.property_data else None
                loc = None
                if desc is not None and hasattr(desc, "property_data") and "locator" in desc.property_data:
                    loc = getattr(desc, "locator", None)
                lname = type(loc).__name__ if loc is not None else ""
                if lname == "MSMLocator":
                    missing = True       # media administrada por Avid, no está en los discos
                    continue
                if desc is not None and "FileLocator" in lname:
                    linked = True        # clip linkeado (AMA)
            for t in obj.tracks:
                stack.append(t)
            continue

        if cls == "SourceClip":
            try:
                ref = mobs_by_id.get(norm_umid(obj.mob_id))
            except Exception:
                ref = None
            if ref is not None:
                stack.append(ref)
            continue

        stack.extend(iter_children(obj))

    return folders, missing, linked


def folder_sort_key(v):
    tail = v.split(":")[-1]
    return (0, int(tail), v) if tail.isdigit() else (1, 0, v)


def format_value(folders, missing, linked):
    if folders:
        return ", ".join(sorted(folders, key=folder_sort_key))
    if missing:
        return NOT_FOUND
    if linked:
        return LINKED
    return None


# ---------------------------------------------------------------------------
# 3. Escribir bins
# ---------------------------------------------------------------------------

def ensure_column(bin_obj, column):
    view = bin_obj.view_setting
    cols = list(view.columns)
    for c in cols:
        if c.get("title") == column:
            if not c.get("hidden"):
                return False
            c["hidden"] = False
            break
    else:
        cols.append({"title": column, "format": USER_COLUMN_FORMAT,
                     "type": USER_COLUMN_TYPE, "hidden": False})
    view.columns = cols          # reasignar marca la vista como modificada
    view.mark_modified()
    return True


def set_user_value(f, mob, column, value):
    attrs = mob.attributes
    if attrs is None:
        attrs = f.create.Attributes()
        mob.attributes = attrs
    user = attrs.get("_USER")
    if user is None:
        user = f.create.Attributes()
        attrs["_USER"] = user
    if user.get(column) == value:
        return False
    user[column] = value
    attrs.mark_modified()
    return True


# Nombres que Avid pone a un bin nuevo ("<Proyecto> Bin", "Untitled", etc.)
DEFAULT_BIN_NAME = re.compile(r"(\bbin\b|untitled|sin t[ií]tulo)", re.IGNORECASE)
INVALID_CHARS = re.compile(r'[\\/:*?"<>|]')


def bin_name_for(folder_value):
    """'DISCO_A:1000_ENTREVISTA' -> '1000_ENTREVISTA'"""
    name = folder_value.split(":")[-1]
    return INVALID_CHARS.sub("_", name).strip(" .")


def rename_target(bin_path, folders_per_item, has_compositions, args):
    """Devuelve (nuevo_path, motivo_si_no). Solo renombra bins 'de una carpeta'."""
    if not folders_per_item:
        return None, "sin clips con media"
    if has_compositions:
        return None, "tiene secuencias o subclips"
    distinct = set()
    for fs in folders_per_item:
        if fs is None:
            return None, "tiene clips sin media o linkeados"
        distinct |= fs
    if len(distinct) != 1:
        return None, "mezcla carpetas"
    current = os.path.splitext(os.path.basename(bin_path))[0]
    new_name = args.bin_prefix + bin_name_for(next(iter(distinct)))
    if current == new_name:
        return None, None
    if not args.rename_any and not DEFAULT_BIN_NAME.search(current):
        return None, "ya tiene nombre propio (usá --rename-any)"
    folder = os.path.dirname(bin_path)
    target = os.path.join(folder, new_name + ".avb")
    n = 2
    while os.path.exists(target) or os.path.exists(os.path.splitext(target)[0] + ".lck"):
        target = os.path.join(folder, "%s_%d.avb" % (new_name, n))
        n += 1
    return target, None


def is_locked(bin_path):
    base = os.path.splitext(bin_path)[0]
    return os.path.exists(base + ".lck")


def process_bin(bin_path, index, args, backup_root):
    if is_locked(bin_path):
        print("   [SALTEADO, bloqueado .lck] %s" % bin_path)
        return 0, None

    changes = 0
    tally = {}
    folders_per_item = []      # para decidir el renombre del bin
    has_compositions = False
    with avb.open(bin_path) as f:
        b = f.content
        mobs_by_id = {norm_umid(m.mob_id): m for m in b.mobs}

        for item in b.items:
            if not item.user_placed:
                continue
            mob = item.mob
            if mob is None:
                continue
            if getattr(mob, "mob_type", "") == "CompositionMob":
                has_compositions = True
            if args.skip_sequences and getattr(mob, "mob_type", "") == "CompositionMob" \
                    and getattr(mob, "usage_code", None) in (None, 0):
                continue
            folders, missing, linked = resolve_folders(mob, mobs_by_id, index)
            value = format_value(folders, missing, linked)
            if value is None:
                continue
            folders_per_item.append(set(folders) if folders else None)
            tally[value] = tally.get(value, 0) + 1
            if not args.dry_run and set_user_value(f, mob, args.column, value):
                changes += 1

        col_changed = False if args.dry_run else ensure_column(b, args.column)

        summary = ", ".join("%s: %d" % (k, v) for k, v in
                            sorted(tally.items(), key=lambda kv: folder_sort_key(kv[0])))
        print("   %s  ->  %s" % (os.path.basename(bin_path), summary or "sin clips con media"))

        target = None
        if args.rename_bins:
            target, why = rename_target(bin_path, folders_per_item, has_compositions, args)
            if target:
                print("      renombrar bin  ->  %s" % os.path.splitext(os.path.basename(target))[0])
            elif why:
                print("      no se renombra: %s" % why)

        if args.dry_run:
            return 0, None
        if changes == 0 and not col_changed:
            if target:
                backup_bin(bin_path, backup_root)
                os.rename(bin_path, target)
            return 0, target

        backup_bin(bin_path, backup_root)

        fd, tmp = tempfile.mkstemp(suffix=".avb", dir=os.path.dirname(bin_path))
        os.close(fd)
        try:
            f.write(tmp)
        except Exception:
            os.remove(tmp)
            raise

    os.replace(tmp, bin_path)
    if target:
        os.rename(bin_path, target)
    return changes, target


def backup_bin(bin_path, backup_root):
    if not backup_root:
        return
    dest = os.path.join(backup_root, os.path.basename(os.path.dirname(bin_path)),
                        os.path.basename(bin_path))
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    shutil.copy2(bin_path, dest)


# ---------------------------------------------------------------------------
# 4. Separar un bin en un bin por carpeta
# ---------------------------------------------------------------------------

MIXED_BIN = "MXF_MIXTO"


def column_folders(mob, column):
    """Lee el valor ya cargado en la columna: '1, 1000' -> {'1', '1000'}"""
    attrs = mob.attributes
    user = attrs.get("_USER") if attrs is not None else None
    value = user.get(column) if user is not None else None
    if not value or value in (NOT_FOUND, LINKED):
        return set(), value
    return {v.strip() for v in value.split(",") if v.strip()}, value


def split_bin(src_path, index, args, backup_root, consume=False, by_column=False):
    """Toma un bin con clips de una o varias carpetas (por ej. donde se
    arrastraron uno o varios .mdb) y crea/actualiza un bin por carpeta.
    Con consume=True, si todo salió bien, saca el bin de origen del proyecto
    (lo mueve al backup)."""
    if is_locked(src_path):
        print("   [SALTEADO, bloqueado .lck] %s" % src_path)
        return []
    problems = 0
    out_dir = os.path.dirname(src_path)
    groups = {}          # nombre_bin -> [(mob, valor)]
    skipped = 0

    with avb.open(src_path) as src:
        b = src.content
        mobs_by_id = {norm_umid(m.mob_id): m for m in b.mobs}
        columns = [dict(c) for c in b.view_setting.columns]

        for item in b.items:
            if not item.user_placed or item.mob is None:
                continue
            mob = item.mob
            if by_column:
                folders, value = column_folders(mob, args.column)
            else:
                if getattr(mob, "mob_type", "") != "MasterMob":
                    skipped += 1
                    continue
                folders, missing, linked = resolve_folders(mob, mobs_by_id, index)
                value = format_value(folders, missing, linked)
            if not folders:
                skipped += 1
                continue
            name = bin_name_for(next(iter(folders))) if len(folders) == 1 else MIXED_BIN
            groups.setdefault(args.bin_prefix + name, []).append((mob, value))

        print("   %s  ->  %d bin(s)%s" % (os.path.basename(src_path), len(groups),
              (("  (%d items sin valor en '%s': quedan solo en el bin original)" % (skipped, args.column))
               if by_column else
               ("  (%d items salteados: secuencias, subclips o sin media)" % skipped)) if skipped else ""))

        results = []
        for name in sorted(groups, key=folder_sort_key):
            clips = groups[name]
            dest = os.path.join(out_dir, name + ".avb")
            exists = os.path.exists(dest)
            if exists and is_locked(dest):
                print("      %-30s [SALTEADO, bloqueado .lck]" % name)
                problems += 1
                continue

            existing_ids = set()
            if exists:
                with avb.open(dest) as d:
                    existing_ids = {norm_umid(m.mob_id) for m in d.content.mobs}
            new_clips = [(m, v) for m, v in clips if norm_umid(m.mob_id) not in existing_ids]
            print("      %-30s %4d clip(s)%s" % (name, len(new_clips),
                  (" nuevos (el bin ya existe)" if exists else " (bin nuevo)")))
            if args.dry_run or not new_clips:
                continue

            dst = avb.open(dest) if exists else avb.open()
            try:
                db = dst.content
                if not exists:
                    db.view_setting.columns = [dict(c) for c in columns]
                for mob, value in new_clips:
                    # el master clip visible + sus file mobs / source mobs ocultos
                    deps = [m for m in mob.dependant_mobs()
                            if norm_umid(m.mob_id) not in existing_ids]
                    for dm in deps:
                        item = db.add_mob(dm.copy(dst))
                        item.user_placed = False
                        existing_ids.add(norm_umid(dm.mob_id))
                    new_master = mob.copy(dst)
                    set_user_value(dst, new_master, args.column, value)
                    db.add_mob(new_master).user_placed = True
                    existing_ids.add(norm_umid(mob.mob_id))
                ensure_column(db, args.column)

                if exists:
                    backup_bin(dest, backup_root)
                fd, tmp = tempfile.mkstemp(suffix=".avb", dir=out_dir)
                os.close(fd)
                try:
                    dst.write(tmp)
                except Exception:
                    os.remove(tmp)
                    raise
            finally:
                dst.close()
            os.replace(tmp, dest)
            results.append(dest)

    if consume:
        if skipped or problems or not groups:
            print("      (el bin %s queda en el proyecto: tiene items que no se pudieron ubicar)"
                  % os.path.basename(src_path))
        elif args.dry_run:
            print("      %s se retira del proyecto (queda en el backup)" % os.path.basename(src_path))
        else:
            dest = os.path.join(backup_root, "MDB_procesados", os.path.basename(src_path))
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            if os.path.exists(dest):
                dest = os.path.splitext(dest)[0] + "_%d.avb" % len(os.listdir(os.path.dirname(dest)))
            shutil.move(src_path, dest)
            print("      %s retirado del proyecto (guardado en el backup)" % os.path.basename(src_path))
    return results


def is_mdb_bin(path):
    return os.path.basename(path).upper().startswith("MDB")


def avid_is_running():
    try:
        import subprocess
        if os.name == "nt":
            out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq AvidMediaComposer.exe"],
                                 capture_output=True, text=True).stdout
            return "avidmediacomposer.exe" in out.lower()
        out = subprocess.run(["pgrep", "-if", "AvidMediaComposer"],
                             capture_output=True, text=True).stdout
        return bool(out.strip())
    except Exception:
        return False


def collect_bins(paths):
    bins = []
    for p in paths:
        p = os.path.abspath(os.path.expanduser(p))
        if os.path.isfile(p) and p.lower().endswith(".avb"):
            bins.append(p)
        elif os.path.isdir(p):
            for dirpath, dirnames, filenames in os.walk(p):
                dirnames[:] = [d for d in dirnames
                               if d not in ("Avid Attic", "Attic") and not d.startswith(".")]
                for fn in filenames:
                    if fn.lower().endswith(".avb") and not fn.startswith("."):
                        bins.append(os.path.join(dirpath, fn))
    return sorted(set(bins))


# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(
        description="Agrega a los bins de Avid una columna con la carpeta de "
                    "Avid MediaFiles/MXF donde está la media de cada clip.")
    ap.add_argument("bins", nargs="+",
                    help="Bins (.avb) o carpetas (por ej. la carpeta del proyecto)")
    ap.add_argument("-m", "--media", action="append", default=[],
                    help="Disco, 'Avid MediaFiles' o carpeta MXF a indexar. "
                         "Repetible. Si no se indica, busca en todos los discos.")
    ap.add_argument("-c", "--column", default="MXF Folder",
                    help="Nombre de la columna custom (default: 'MXF Folder')")
    ap.add_argument("--with-drive", action="store_true",
                    help="Incluir el nombre del disco, ej. 'MEDIA_01:1000'")
    ap.add_argument("--skip-sequences", action="store_true",
                    help="No escribir la columna en secuencias")
    ap.add_argument("--rename-bins", action="store_true",
                    help="Renombrar con el nombre de la carpeta MXF los bins cuyos clips "
                         "vienen todos de una sola carpeta (ej. bin armado arrastrando el .mdb)")
    ap.add_argument("--rename-any", action="store_true",
                    help="Con --rename-bins: renombrar aunque el bin ya tenga un nombre propio "
                         "(por defecto solo renombra bins con nombre de bin nuevo: '... Bin', 'Untitled')")
    ap.add_argument("--bin-prefix", default="",
                    help="Prefijo para el nombre del bin, ej. 'MXF_' -> 'MXF_1000_ENTREVISTA'")
    ap.add_argument("--split", action="store_true",
                    help="Separar los bins indicados en un bin por carpeta MXF "
                         "(para el bin donde arrastraste varios .mdb juntos)")
    ap.add_argument("--mdb-bins", action="store_true",
                    help="Los bins cuyo nombre empieza con MDB se convierten en un bin por "
                         "carpeta MXF (con el nombre de la carpeta) y se retiran del proyecto")
    ap.add_argument("--split-by-column", action="store_true",
                    help="Separar los bins indicados (.avb) en un bin por valor de la "
                         "columna MXF Folder ya cargada. No escanea media. El bin original no se toca.")
    ap.add_argument("--dry-run", action="store_true",
                    help="Solo mostrar lo que haría, sin modificar bins")
    ap.add_argument("--no-backup", action="store_true",
                    help="No hacer backup de los bins antes de modificarlos")
    ap.add_argument("--cache", default=os.path.join(os.path.expanduser("~"), ".avid_mxf_index_cache.json"),
                    help="Archivo de caché del índice MXF (acelera las próximas corridas)")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    if not args.dry_run and avid_is_running():
        sys.exit("\nMedia Composer está abierto. Cerralo del todo y volvé a correr el script.\n"
                 "(Si Avid queda abierto, al guardar pisa los cambios en los bins.)")

    if args.split_by_column:
        files = [os.path.abspath(os.path.expanduser(p)) for p in args.bins]
        bad = [p for p in files if not (os.path.isfile(p) and p.lower().endswith(".avb"))]
        if bad:
            sys.exit("Para separar indicá bins (.avb), no carpetas:\n  " + "\n  ".join(bad))
        backup_root = None
        if not args.dry_run and not args.no_backup:
            backup_root = os.path.join(os.path.expanduser("~"), "Avid_MXF_Folder_backups",
                                       datetime.datetime.now().strftime("%Y%m%d_%H%M%S"))
        print("\nSeparando %d bin(s) según la columna '%s'%s:" %
              (len(files), args.column, " [PRUEBA]" if args.dry_run else ""))
        made = []
        for bp in files:
            try:
                made += split_bin(bp, None, args, backup_root, by_column=True)
            except Exception as e:
                print("   [ERROR] %s: %s" % (bp, e))
        if args.dry_run:
            return
        print("\nListo. Bins creados o actualizados: %d." % len(made))
        for m in made:
            print("   %s" % os.path.splitext(os.path.basename(m))[0])
        if made:
            print("El bin original no se modificó. Abrí Avid, revisá los bins nuevos y "
                  "después, si querés, borrá el original.")
        else:
            print("No se creó ningún bin. ¿El bin tiene la columna '%s' completa?" % args.column)
        return

    if args.media:
        roots = []
        for m in args.media:
            r = normalize_media_root(m)
            if r is None:
                sys.exit("No encuentro 'Avid MediaFiles/MXF' en: %s" % m)
            roots.append(r)
    else:
        roots = default_media_roots()
    if not roots:
        sys.exit("No encontré ninguna carpeta 'Avid MediaFiles/MXF'. Indicala con --media.")

    bins = collect_bins(args.bins)
    if not bins:
        sys.exit("No encontré bins (.avb) en lo que indicaste.")

    print("\n1) Indexando media:")
    index = build_mxf_index(roots, args.with_drive, args.cache, args.verbose)

    backup_root = None
    if not args.dry_run and not args.no_backup:
        # Fuera del proyecto: si queda adentro, Avid lo muestra como bins duplicados
        stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
        backup_root = os.path.join(os.path.expanduser("~"), "Avid_MXF_Folder_backups", stamp)

    if args.mdb_bins:
        mdb = [bp for bp in bins if is_mdb_bin(bp)]
        print("\n2) Bins MDB: %d%s" % (len(mdb), " [DRY RUN]" if args.dry_run else ""))
        if not mdb:
            print("   No hay bins que empiecen con MDB.")
        consume_root = backup_root or os.path.join(
            os.path.expanduser("~"), "Avid_MXF_Folder_backups",
            datetime.datetime.now().strftime("%Y%m%d_%H%M%S"))
        made = []
        for bp in mdb:
            try:
                made += split_bin(bp, index, args, consume_root, consume=True)
            except Exception as e:
                print("   [ERROR] %s: %s" % (bp, e))
        if made:
            print("   Bins creados o actualizados: %s" %
                  ", ".join(os.path.splitext(os.path.basename(m))[0] for m in made))
        bins = collect_bins(args.bins)
        if not args.dry_run:
            bins = [bp for bp in bins if not is_mdb_bin(bp) or os.path.exists(bp)]
        else:
            bins = [bp for bp in bins if not is_mdb_bin(bp)]
        print("\n3) Columna en el resto de los bins:")

    if args.split:
        print("\n2) Separando %d bin(s) por carpeta%s:" % (len(bins), " [DRY RUN]" if args.dry_run else ""))
        made = []
        for bp in bins:
            try:
                made += split_bin(bp, index, args, backup_root)
            except Exception as e:
                print("   [ERROR] %s: %s" % (bp, e))
        print("\nListo. Bins creados o actualizados: %d." % len(made))
        if made:
            print("El bin original no se modificó: cuando verifiques los nuevos, lo podés borrar en Avid.")
            print("Abrí el proyecto en Avid: los bins nuevos aparecen en la ventana del proyecto.")
        return

    if not args.mdb_bins:
        print("\n2) Procesando %d bin(s)%s:" % (len(bins), " [DRY RUN]" if args.dry_run else ""))
    total = 0
    renamed = []
    failed = []
    for bp in bins:
        try:
            n, new_path = process_bin(bp, index, args, backup_root)
            total += n
            if new_path:
                renamed.append((bp, new_path))
        except Exception as e:
            failed.append(bp)
            print("   [ERROR] %s: %s" % (bp, e))

    print("\nListo. Clips actualizados: %d." % total)
    for old, new in renamed:
        print("Bin renombrado: %s  ->  %s" % (os.path.basename(old), os.path.basename(new)))
    if backup_root and os.path.isdir(backup_root):
        print("Backup de los bins originales en: %s" % backup_root)
    if failed:
        print("Bins con error (no se tocaron): %d" % len(failed))
    if not args.dry_run:
        print("Abrí el proyecto; si la columna '%s' no aparece, agregala desde "
              "Choose Columns (clic derecho en el encabezado del bin)." % args.column)


# ---------------------------------------------------------------------------
# Modo "todo en uno": arrastrar el bin sobre Avid_MXF_Folder.bat
# ---------------------------------------------------------------------------

def parse_dropped(text):
    text = text.strip()
    paths = re.findall(r'"([^"]+)"', text)
    if not paths and text:
        paths = [text]
    return [p.strip() for p in paths if p.strip()]


def ask(prompt):
    try:
        return input(prompt).strip()
    except EOFError:
        return ""


def interactive(argv):
    print("=" * 60)
    print("  Avid MXF Folder")
    print("  Completa la columna MXF Folder y crea un bin por carpeta")
    print("=" * 60)

    while avid_is_running():
        ask("\nMedia Composer está abierto. Cerralo del todo y apretá Enter... ")

    bins = [p for p in argv if p.strip()]
    if not bins:
        bins = parse_dropped(ask("\nArrastrá a esta ventana el bin (.avb) y apretá Enter:\n> "))
    bins = [os.path.abspath(p) for p in bins]
    bad = [p for p in bins if not (os.path.isfile(p) and p.lower().endswith(".avb"))]
    if not bins or bad:
        print("\nEso no es un bin de Avid (.avb):")
        for p in bad or ["(nada)"]:
            print("   " + p)
        print("Arrastrá el archivo del bin, que está dentro de la carpeta del proyecto.")
        return

    roots = default_media_roots()
    while not roots:
        d = parse_dropped(ask("\nNo encontré 'Avid MediaFiles\\MXF'. Arrastrá acá el disco de la media y apretá Enter:\n> "))
        r = normalize_media_root(d[0]) if d else None
        if r:
            roots = [r]
        elif not d:
            return

    args = argparse.Namespace(
        column="MXF Folder", with_drive=False, skip_sequences=False,
        rename_bins=False, rename_any=False, bin_prefix="", dry_run=True,
        no_backup=False, verbose=False,
        cache=os.path.join(os.path.expanduser("~"), ".avid_mxf_index_cache.json"))

    print("\n1) Leyendo la media (la primera vez puede tardar):")
    index = build_mxf_index(roots, False, args.cache, False)

    print("\n2) Lo que se va a hacer (todavía no se modifica nada):")
    for bp in bins:
        process_bin(bp, index, args, None)                    # columna
        split_bin(bp, index, args, None)                      # bins por carpeta

    if ask("\n¿Aplicar? Escribí S y apretá Enter: ").upper() != "S":
        print("\nCancelado. No se modificó nada.")
        return
    while avid_is_running():
        ask("\nMedia Composer está abierto. Cerralo del todo y apretá Enter... ")

    args.dry_run = False
    backup_root = os.path.join(os.path.expanduser("~"), "Avid_MXF_Folder_backups",
                               datetime.datetime.now().strftime("%Y%m%d_%H%M%S"))
    print("\n3) Aplicando:")
    made = []
    for bp in bins:
        try:
            process_bin(bp, index, args, backup_root)
            made += split_bin(bp, None, args, backup_root, by_column=True)
        except Exception as e:
            print("   [ERROR] %s: %s" % (os.path.basename(bp), e))

    print("\n" + "=" * 60)
    print("Listo.")
    for m in made:
        print("   Bin creado/actualizado: %s" % os.path.splitext(os.path.basename(m))[0])
    print("\nAbrí Avid: los bins nuevos están en la ventana del proyecto y tienen")
    print("la columna MXF Folder (si no se ve: clic derecho en el encabezado > Choose Columns).")
    print("El bin original quedó igual, con la columna completa. Backup en:")
    print("   " + backup_root)


if __name__ == "__main__":
    if "--cli" in sys.argv:
        sys.argv.remove("--cli")
        main()
    else:
        interactive(sys.argv[1:])
