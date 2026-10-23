#!/usr/bin/env python3
"""Packs an ELF linked at 0x00100000 into a .3dsx (header, three segments,
empty relocation tables). Segment boundaries come from the section layout."""
import os, struct, subprocess, sys, tempfile

elf, out = sys.argv[1], sys.argv[2]

def section_bytes(name):
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "section.bin")
        subprocess.run(["llvm-objcopy", "-O", "binary", "--only-section=" + name, elf, path], check=True)
        return open(path, "rb").read()

def section_sizes():
    text = subprocess.run(["llvm-readelf", "-S", "-W", elf], capture_output=True, text=True, check=True).stdout
    sizes = {}
    for line in text.splitlines():
        parts = line.replace("[", " ").replace("]", " ").split()
        if len(parts) > 6 and parts[1].startswith("."):
            sizes[parts[1]] = (int(parts[3], 16), int(parts[5], 16))
    return sizes

sizes = section_sizes()
code, rodata, data = section_bytes(".text"), section_bytes(".rodata"), section_bytes(".data")
bss = sizes.get(".bss", (0, 0))[1]
def pad(b): return b + b"\0" * ((-len(b)) % 0x1000)
code, rodata = pad(code), pad(rodata)
header = struct.pack("<4sHHIIIIII", b"3DSX", 0x20, 8, 0, 0, len(code), len(rodata), len(data) + bss, bss)
relocs = struct.pack("<II", 0, 0) * 3
open(out, "wb").write(header + relocs + code + rodata + data)
