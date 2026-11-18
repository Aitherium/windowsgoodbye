"""Merge OCI image layers into ONE root-filesystem tar, stream to stream.

Never unpacks onto the Windows disk: NTFS cannot hold Linux symlinks, device nodes,
case-only twins or modes, and a measured extract of awnix's 683 MB base layer lost
2,006 files and 768 symlinks. Tar-to-tar keeps every entry exactly as the image has it.

Layers are applied top-down (newest first): the first time a path is seen it wins.
A ".wh.<name>" whiteout hides <name> (and everything under it) from older layers; a
".wh..wh..opq" opaque marker hides the whole directory's older contents.

    python merge_layers.py out.tar layer1.tar.gz layer2.tar.gz ...   (oldest first)
"""
import sys
import tarfile

WH, OPQ = ".wh.", ".wh..wh..opq"


def norm(name: str) -> str:
    # strip a leading "./" or "/" PREFIX only. lstrip("./") would eat the dot of a
    # root dotfile, so a root whiteout ".wh.b" became "wh.b": missed, and leaked as a file.
    while name.startswith("./"):
        name = name[2:]
    return name.lstrip("/").rstrip("/")


def merge(out_path: str, layers: list) -> dict:
    seen = set()          # paths already emitted by a newer layer
    hidden = set()        # whited-out paths (and their subtrees)
    opaque = set()        # dirs whose older contents are hidden
    stats = {"entries": 0, "symlinks": 0, "whiteouts": 0}

    def is_hidden(path: str, layer_opaque: set) -> bool:
        parts = path.split("/")
        for i in range(1, len(parts) + 1):
            pre = "/".join(parts[:i])
            if pre in hidden:
                return True
        for i in range(1, len(parts)):
            if "/".join(parts[:i]) in layer_opaque:
                return True
        return False

    with tarfile.open(out_path, "w", format=tarfile.PAX_FORMAT) as out:
        for lp in reversed(layers):          # newest first
            new_hidden, new_opaque = set(), set()
            with tarfile.open(lp, "r:*") as tin:
                for m in tin:
                    p = norm(m.name)
                    if not p:
                        continue
                    base = p.rsplit("/", 1)[-1]
                    parent = p.rsplit("/", 1)[0] if "/" in p else ""
                    if base == OPQ:
                        new_opaque.add(parent)
                        stats["whiteouts"] += 1
                        continue
                    if base.startswith(WH):
                        new_hidden.add((parent + "/" if parent else "") + base[len(WH):])
                        stats["whiteouts"] += 1
                        continue
                    if p in seen or is_hidden(p, opaque):
                        continue
                    seen.add(p)
                    m.name = p
                    if m.islnk():
                        m.linkname = norm(m.linkname)
                    if m.issym():
                        stats["symlinks"] += 1
                    out.addfile(m, tin.extractfile(m) if m.isreg() else None)
                    stats["entries"] += 1
            # whiteouts/opaques in THIS layer hide only OLDER layers: apply after it
            hidden |= new_hidden
            opaque |= new_opaque
    return stats


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit("usage: merge_layers.py out.tar layer1 [layer2 ...]  (oldest first)")
    s = merge(sys.argv[1], sys.argv[2:])
    print(f"merged {s['entries']} entries ({s['symlinks']} symlinks, {s['whiteouts']} whiteouts applied)")
