"""Busca en el codigo cada cadena citada entre comillas invertidas en los documentos.

Imprime las que no aparecen literalmente en ningun archivo de codigo, para revisarlas
a mano (muchas son comandos o rutas que no tienen por que estar en el codigo).
"""
import os
import sys

root = sys.argv[1]
strings = [s.rstrip("\n") for s in open(sys.argv[2], encoding="utf-8") if s.strip()]
code_files = []
for d in ("docker", "scripts", "modules"):
    for dp, _, fs in os.walk(os.path.join(root, d)):
        for f in fs:
            code_files.append(os.path.join(dp, f))
code_files.append(os.path.join(root, "setup.sh"))
blob = ""
for p in code_files:
    try:
        blob += open(p, encoding="utf-8", errors="replace").read() + "\n"
    except OSError:
        pass
for s in strings:
    probe = s.split("<")[0].strip() if "<" in s else s
    if probe and probe not in blob:
        print("MISSING:", s)
