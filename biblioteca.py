"""Lee la biblioteca de música y la imprime como JSON.

Uso: biblioteca.py <carpeta_musica> <carpeta_cache>

Lee las etiquetas ID3 (título, artista, álbum, pista, año, género) con un
lector propio, sin dependencias, y guarda una carátula por disco en
<cache>/portadas/. Lo leído se guarda en <cache>/etiquetas.json y solo se
vuelven a leer los archivos que cambiaron.

Salida: [{"t","a","aa","al","n","d","y","g","p","c","k"}, ...]
"""
import hashlib
import json
import os
import sys
import unicodedata

EXTENSIONES = {".mp3", ".flac", ".m4a", ".ogg", ".opus", ".wav", ".aac", ".wma"}
VERSION_CACHE = 2
MAX_TAG = 16 * 1024 * 1024

TEXTO = {
    "TIT2": "t", "TPE1": "a", "TPE2": "aa", "TALB": "al", "TRCK": "n",
    "TPOS": "d", "TDRC": "y", "TYER": "y", "TCON": "g",
    # ID3v2.2
    "TT2": "t", "TP1": "a", "TP2": "aa", "TAL": "al", "TRK": "n",
    "TPA": "d", "TYE": "y", "TCO": "g",
}


def clave(texto):
    t = unicodedata.normalize("NFD", texto)
    return "".join(c for c in t if unicodedata.category(c) != "Mn").lower()


def synchsafe(b):
    return (b[0] << 21) | (b[1] << 14) | (b[2] << 7) | b[3]


def decodificar(enc, datos):
    try:
        if enc == 0:
            s = datos.decode("latin-1")
        elif enc == 1:
            s = datos.decode("utf-16")
        elif enc == 2:
            s = datos.decode("utf-16-be")
        else:
            s = datos.decode("utf-8")
    except UnicodeDecodeError:
        s = datos.decode("latin-1", "replace")
    # ID3v2.4 separa varios valores con \0; nos quedamos con el primero
    return s.split("\x00")[0].strip()


def separar_terminado(enc, datos):
    """Corta un texto terminado en \\0 (o \\0\\0 en UTF-16) y devuelve el resto."""
    if enc in (1, 2):
        i = 0
        while i + 1 < len(datos):
            if datos[i] == 0 and datos[i + 1] == 0:
                return datos[:i], datos[i + 2:]
            i += 2
        return datos, b""
    i = datos.find(b"\x00")
    return (datos, b"") if i < 0 else (datos[:i], datos[i + 1:])


def leer_id3(ruta):
    """Devuelve (etiquetas, bytes_de_carátula|None)."""
    etiquetas, portada = {}, None
    with open(ruta, "rb") as f:
        cab = f.read(10)
        if len(cab) < 10 or cab[:3] != b"ID3":
            return etiquetas, portada
        version, banderas = cab[3], cab[5]
        tam = synchsafe(cab[6:10])
        if tam > MAX_TAG or version not in (2, 3, 4):
            return etiquetas, portada
        datos = f.read(tam)
    unsync_global = bool(banderas & 0x80)
    if unsync_global and version < 4:
        datos = datos.replace(b"\xff\x00", b"\xff")
    pos = 0
    if banderas & 0x40 and version >= 3:  # cabecera extendida
        ext = synchsafe(datos[0:4]) if version == 4 else int.from_bytes(datos[0:4], "big") + 4
        pos = ext
    largo_id, largo_cab = (3, 6) if version == 2 else (4, 10)
    while pos + largo_cab <= len(datos):
        fid = datos[pos:pos + largo_id]
        if not fid.strip(b"\x00") or not fid.isalnum():
            break
        if version == 2:
            ftam = int.from_bytes(datos[pos + 3:pos + 6], "big")
            fband = 0
        elif version == 4:
            ftam = synchsafe(datos[pos + 4:pos + 8])
            fband = datos[pos + 9]
        else:
            ftam = int.from_bytes(datos[pos + 4:pos + 8], "big")
            fband = 0
        cuerpo = datos[pos + largo_cab:pos + largo_cab + ftam]
        pos += largo_cab + ftam
        if version == 4 and fband & 0x02:
            cuerpo = cuerpo.replace(b"\xff\x00", b"\xff")
        if version == 4 and fband & 0x01:  # longitud de datos añadida
            cuerpo = cuerpo[4:]
        if not cuerpo:
            continue
        nombre = fid.decode("latin-1")
        if nombre in TEXTO:
            campo = TEXTO[nombre]
            if campo not in etiquetas or not etiquetas[campo]:
                etiquetas[campo] = decodificar(cuerpo[0], cuerpo[1:])
        elif nombre in ("APIC", "PIC") and portada is None:
            enc = cuerpo[0]
            if nombre == "APIC":
                _, resto = separar_terminado(0, cuerpo[1:])        # tipo MIME
            else:
                resto = cuerpo[4:]                                  # formato de 3 letras
            if len(resto) < 2:
                continue
            _, imagen = separar_terminado(enc, resto[1:])          # descripción
            if imagen[:3] == b"\xff\xd8\xff" or imagen[:8] == b"\x89PNG\r\n\x1a\n":
                portada = imagen
    return etiquetas, portada


def numero(texto):
    try:
        return int(str(texto).split("/")[0].strip() or 0)
    except ValueError:
        return 0


def main():
    raiz, cache = sys.argv[1], sys.argv[2]
    dir_portadas = os.path.join(cache, "portadas")
    os.makedirs(dir_portadas, exist_ok=True)
    ruta_cache = os.path.join(cache, "etiquetas.json")
    try:
        with open(ruta_cache, encoding="utf-8") as f:
            guardado = json.load(f)
        if guardado.get("v") != VERSION_CACHE:
            guardado = {}
    except (OSError, ValueError):
        guardado = {}
    anterior = guardado.get("archivos", {})
    nuevo = {}

    for carpeta, _, archivos in os.walk(raiz):
        for nombre in archivos:
            base, ext = os.path.splitext(nombre)
            if ext.lower() not in EXTENSIONES:
                continue
            ruta = os.path.join(carpeta, nombre)
            try:
                st = os.stat(ruta)
            except OSError:
                continue
            firma = f"{st.st_mtime_ns}:{st.st_size}"
            previo = anterior.get(ruta)
            if previo and previo.get("f") == firma:
                nuevo[ruta] = previo
                continue

            etiquetas, portada = {}, None
            if ext.lower() == ".mp3":
                try:
                    etiquetas, portada = leer_id3(ruta)
                except (OSError, IndexError, ValueError):
                    etiquetas, portada = {}, None
            # lo que falte sale del nombre del archivo: "Artista - Título"
            if " - " in base:
                a_nom, t_nom = base.split(" - ", 1)
            else:
                a_nom, t_nom = os.path.basename(carpeta), base
            e = {
                "f": firma,
                "t": (etiquetas.get("t") or t_nom).strip()[:200],
                "a": (etiquetas.get("a") or a_nom).strip()[:120],
                "aa": (etiquetas.get("aa") or "").strip()[:120],
                "al": (etiquetas.get("al") or "").strip()[:200],
                "n": numero(etiquetas.get("n", 0)),
                "d": numero(etiquetas.get("d", 0)) or 1,
                "y": (etiquetas.get("y") or "")[:4],
                "g": (etiquetas.get("g") or "").strip()[:60],
                "c": "",
            }
            if not e["aa"]:
                e["aa"] = e["a"]
            if not e["al"]:
                e["al"] = os.path.basename(carpeta)
            if portada:
                cid = hashlib.sha1((clave(e["aa"]) + "|" + clave(e["al"])).encode()).hexdigest()[:16]
                ext_img = ".png" if portada[:4] == b"\x89PNG" else ".jpg"
                destino = os.path.join(dir_portadas, cid + ext_img)
                if not os.path.exists(destino):
                    with open(destino + ".tmp", "wb") as f:
                        f.write(portada)
                    os.replace(destino + ".tmp", destino)
                e["c"] = destino
            nuevo[ruta] = e

    tmp = ruta_cache + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"v": VERSION_CACHE, "archivos": nuevo}, f, ensure_ascii=False)
    os.replace(tmp, ruta_cache)

    # Un disco comparte carátula: si alguna pista no la trae, usa la del resto.
    portada_disco = {}
    for e in nuevo.values():
        if e["c"]:
            portada_disco.setdefault((clave(e["aa"]), clave(e["al"])), e["c"])

    canciones = []
    vistas = set()
    orden = sorted(nuevo.items(), key=lambda it: (
        clave(it[1]["aa"]), it[1]["y"], clave(it[1]["al"]), it[1]["d"], it[1]["n"],
        clave(it[1]["t"]), len(it[0])))
    for ruta, e in orden:
        # la misma canción en dos carpetas (p. ej. Deezer/Deezer) se muestra una vez
        firma = (clave(e["a"]), clave(e["t"]), clave(e["al"]))
        if firma in vistas:
            continue
        vistas.add(firma)
        c = e["c"] or portada_disco.get((clave(e["aa"]), clave(e["al"])), "")
        canciones.append({
            "t": e["t"], "a": e["a"], "aa": e["aa"], "al": e["al"], "n": e["n"],
            "d": e["d"], "y": e["y"], "g": e["g"], "p": ruta, "c": c,
            "k": clave(" ".join((e["a"], e["t"], e["al"], e["aa"]))),
        })
    json.dump(canciones, sys.stdout, ensure_ascii=False)


if __name__ == "__main__":
    main()
