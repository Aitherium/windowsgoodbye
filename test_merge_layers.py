"""Offline tests for merge_layers.py: the OCI layer rules a broken merge would get wrong.

    python -m pytest test_merge_layers.py -q
"""
import io
import os
import sys
import tarfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import merge_layers  # noqa: E402


def layer(path, entries):
    """entries: [(name, kind, payload)] kind in file|dir|sym|hard|wh|opq"""
    with tarfile.open(path, "w:gz") as t:
        for name, kind, payload in entries:
            ti = tarfile.TarInfo(name)
            if kind == "file":
                data = payload.encode()
                ti.size = len(data)
                t.addfile(ti, io.BytesIO(data))
                continue
            if kind == "dir":
                ti.type = tarfile.DIRTYPE
            elif kind == "sym":
                ti.type, ti.linkname = tarfile.SYMTYPE, payload
            elif kind == "hard":
                ti.type, ti.linkname = tarfile.LNKTYPE, payload
            elif kind in ("wh", "opq"):
                ti.size = 0
            t.addfile(ti)


def merged(tmp_path, *layers_entries):
    paths = []
    for i, entries in enumerate(layers_entries):
        p = str(tmp_path / f"l{i}.tgz")
        layer(p, entries)
        paths.append(p)
    out = str(tmp_path / "out.tar")
    merge_layers.merge(out, paths)
    with tarfile.open(out) as t:
        return {m.name: (m, t.extractfile(m).read().decode() if m.isreg() else None) for m in t}


def test_newer_layer_wins(tmp_path):
    m = merged(tmp_path, [("etc", "dir", ""), ("etc/motd", "file", "old")], [("etc/motd", "file", "new")])
    assert m["etc/motd"][1] == "new"


def test_whiteout_removes_file_and_subtree(tmp_path):
    m = merged(tmp_path,
               [("a", "dir", ""), ("a/keep", "file", "k"), ("a/gone", "file", "g"),
                ("b", "dir", ""), ("b/x", "file", "x")],
               [("a/.wh.gone", "wh", ""), (".wh.b", "wh", "")])
    assert "a/keep" in m and "a/gone" not in m
    assert "b" not in m and "b/x" not in m
    assert not any(".wh." in n for n in m)


def test_opaque_dir_hides_only_older_contents(tmp_path):
    m = merged(tmp_path,
               [("d", "dir", ""), ("d/old", "file", "o")],
               [("d", "dir", ""), ("d/.wh..wh..opq", "opq", ""), ("d/new", "file", "n")])
    assert "d/new" in m and "d/old" not in m


def test_symlinks_and_hardlinks_survive(tmp_path):
    m = merged(tmp_path, [("usr", "dir", ""), ("usr/real", "file", "r"),
                          ("usr/soft", "sym", "real"), ("usr/hard", "hard", "./usr/real")])
    assert m["usr/soft"][0].issym() and m["usr/soft"][0].linkname == "real"
    assert m["usr/hard"][0].islnk() and m["usr/hard"][0].linkname == "usr/real"


def test_whiteout_in_a_layer_does_not_hide_that_layers_own_file(tmp_path):
    # a layer may delete an old file and add a new one under the same dir
    m = merged(tmp_path, [("x", "dir", ""), ("x/f", "file", "1")],
               [("x/.wh.f", "wh", ""), ("x/g", "file", "2")])
    assert "x/f" not in m and m["x/g"][1] == "2"
