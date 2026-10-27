"""NTFS image layouts for the guest fsync measurement (puddle fork, measurement only, never shipped).

Windows counterpart of puddle's img-layout.py (Linux, SEEK_DATA/SEEK_HOLE + debugfs): allocation via
FSCTL_QUERY_ALLOCATED_RANGES, the guest journal's location parsed from the ext4 image itself.

  ntfs-layout.py stat <img>                 size, sparse flag, allocated bytes, size on disk, valid data length,
                                            journal allocation, touched 64 MiB chunks
  ntfs-layout.py journal <img>              write the guest journal's holes with zeros (fix B emulation)
  ntfs-layout.py fill <img>                 write every hole with zeros, then clear the sparse flag (non-sparse,
                                            allocated and zero-written)
  ntfs-layout.py unsparse <img>             only clear the sparse flag (what NTFS does with the holes)
  ntfs-layout.py chunklist <img> <MiB>      print the chunks that hold data (for an oracle grow-ahead fill)
  ntfs-layout.py chunks <img> <MiB> [list]  write the holes of every chunk that holds data, or of the chunks
                                            listed in the file <list> (grow-ahead emulation)
  ntfs-layout.py validdata <img>            rewrite as a non-sparse file whose clusters are allocated and whose
                                            valid data length is set with SetFileValidData (no zeros written;
                                            needs SeManageVolumePrivilege; reference only: exposes stale disk)
  ntfs-layout.py vdldemo <dir> <MiB>        non-sparse file of <MiB>: allocate, then write 4 KiB at the end
                                            (shows NTFS zero-filling up to the valid data length)
  ntfs-layout.py clone <src> <dst>          (T-386) block-clone every allocated range of <src> into a new sparse <dst>
                                            with FSCTL_DUPLICATE_EXTENTS_TO_FILE (ReFS only, same volume); holes stay
                                            holes; prints the time and the bytes cloned
  ntfs-layout.py copy <src> <dst>           (T-386) the same bytes into a new sparse <dst> with plain reads and writes
                                            (no sharing): the comparison for clone
Holes read as zero, so journal/fill/chunks/validdata never change what the guest reads.
"""
import ctypes
import os
import struct
import subprocess
import sys
import time
from ctypes import wintypes

MIB = 1 << 20
k32 = ctypes.WinDLL("kernel32", use_last_error=True)
adv = ctypes.WinDLL("advapi32", use_last_error=True)

GENERIC_READ, GENERIC_WRITE = 0x80000000, 0x40000000
SHARE_ALL = 7
OPEN_EXISTING, CREATE_ALWAYS = 3, 2
FSCTL_QUERY_ALLOCATED_RANGES = 0x000940CF
FSCTL_SET_SPARSE = 0x000900C4
FSCTL_DUPLICATE_EXTENTS_TO_FILE = 0x00098344
ERROR_MORE_DATA = 234
INVALID = ctypes.c_void_p(-1).value

k32.CreateFileW.restype = wintypes.HANDLE
k32.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p, wintypes.DWORD,
                            wintypes.DWORD, wintypes.HANDLE]
k32.DeviceIoControl.argtypes = [wintypes.HANDLE, wintypes.DWORD, ctypes.c_void_p, wintypes.DWORD, ctypes.c_void_p,
                                wintypes.DWORD, ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p]
k32.GetCompressedFileSizeW.restype = wintypes.DWORD
k32.GetCompressedFileSizeW.argtypes = [wintypes.LPCWSTR, ctypes.POINTER(wintypes.DWORD)]
k32.SetFilePointerEx.argtypes = [wintypes.HANDLE, ctypes.c_longlong, ctypes.c_void_p, wintypes.DWORD]
k32.SetEndOfFile.argtypes = [wintypes.HANDLE]
k32.SetFileValidData.argtypes = [wintypes.HANDLE, ctypes.c_longlong]
k32.WriteFile.argtypes = [wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD),
                          ctypes.c_void_p]
k32.ReadFile.argtypes = [wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD),
                         ctypes.c_void_p]
k32.FlushFileBuffers.argtypes = [wintypes.HANDLE]
k32.CloseHandle.argtypes = [wintypes.HANDLE]
k32.GetFileAttributesW.restype = wintypes.DWORD
k32.GetFileAttributesW.argtypes = [wintypes.LPCWSTR]


def check(ok, what):
    if not ok:
        raise OSError(ctypes.get_last_error(), f"{what}: {ctypes.FormatError(ctypes.get_last_error())}")


class H:
    def __init__(self, path, write=False, create=False):
        access = GENERIC_READ | (GENERIC_WRITE if write else 0)
        self.h = k32.CreateFileW(path, access, SHARE_ALL, None, CREATE_ALWAYS if create else OPEN_EXISTING, 0x80, None)
        check(self.h not in (None, INVALID), f"open {path}")

    def close(self):
        k32.CloseHandle(self.h)

    def seek(self, off):
        check(k32.SetFilePointerEx(self.h, off, None, 0), "seek")

    def write(self, off, data):
        self.seek(off)
        n = wintypes.DWORD()
        check(k32.WriteFile(self.h, data, len(data), ctypes.byref(n), None), "write")
        assert n.value == len(data)

    def read(self, off, length):
        self.seek(off)
        buf = ctypes.create_string_buffer(length)
        n = wintypes.DWORD()
        check(k32.ReadFile(self.h, buf, length, ctypes.byref(n), None), "read")
        return buf.raw[: n.value]

    def flush(self):
        check(k32.FlushFileBuffers(self.h), "flush")

    def set_sparse(self, on):
        b = ctypes.c_ubyte(1 if on else 0)
        n = wintypes.DWORD()
        check(k32.DeviceIoControl(self.h, FSCTL_SET_SPARSE, ctypes.byref(b), 1, None, 0, ctypes.byref(n), None),
              "FSCTL_SET_SPARSE")

    def set_eof(self, size):
        self.seek(size)
        check(k32.SetEndOfFile(self.h), "SetEndOfFile")

    def duplicate_from(self, src, src_off, dst_off, length):
        """Block-clone [src_off, src_off+length) of the open file <src> to dst_off of this file."""
        inp = struct.pack("<Qqqq", int(src.h or 0), src_off, dst_off, length)
        n = wintypes.DWORD()
        check(k32.DeviceIoControl(self.h, FSCTL_DUPLICATE_EXTENTS_TO_FILE, inp, len(inp), None, 0, ctypes.byref(n),
                                  None), f"FSCTL_DUPLICATE_EXTENTS_TO_FILE off={src_off} len={length}")

    def data_ranges(self, start, end):
        out = []
        pos = start
        while pos < end:
            inp = struct.pack("<qq", pos, end - pos)
            buf = ctypes.create_string_buffer(16 * 512)
            n = wintypes.DWORD()
            ok = k32.DeviceIoControl(self.h, FSCTL_QUERY_ALLOCATED_RANGES, inp, 16, buf, len(buf), ctypes.byref(n),
                                     None)
            err = ctypes.get_last_error()
            if not ok and err != ERROR_MORE_DATA:
                check(False, "FSCTL_QUERY_ALLOCATED_RANGES")
            got = [struct.unpack_from("<qq", buf.raw, i) for i in range(0, n.value, 16)]
            out += [(a, a + b) for a, b in got]
            if ok or not got:
                break
            pos = got[-1][0] + got[-1][1]
        return [(max(a, start), min(b, end)) for a, b in out if b > start and a < end]


def size_of(path):
    return os.stat(path).st_size


def on_disk(path):
    hi = wintypes.DWORD()
    lo = k32.GetCompressedFileSizeW(path, ctypes.byref(hi))
    return (hi.value << 32) | lo


def is_sparse(path):
    return bool(k32.GetFileAttributesW(path) & 0x200)


def valid_data(path):
    r = subprocess.run(["fsutil", "file", "queryValidData", path], capture_output=True, text=True)
    txt = (r.stdout + r.stderr).strip().replace("\n", " ")
    for tok in txt.replace(":", " ").split():
        if tok.startswith("0x"):
            try:
                return int(tok, 16)
            except ValueError:
                pass
    return txt


def holes(h, start, end):
    out, pos = [], start
    for a, b in h.data_ranges(start, end):
        if a > pos:
            out.append((pos, a))
        pos = b
    if pos < end:
        out.append((pos, end))
    return out


ZERO = bytes(MIB)


def write_zeros(h, a, b):
    n = 0
    while a < b:
        k = min(MIB, b - a)
        h.write(a, ZERO[:k])
        a += k
        n += k
    return n


def fill_holes(h, start, end):
    return sum(write_zeros(h, a, b) for a, b in holes(h, start, end))


def journal_range(h):
    """Byte ranges of the ext4 journal (inode 8), parsed from the image."""
    sb = h.read(1024, 1024)
    if struct.unpack_from("<H", sb, 56)[0] != 0xEF53:
        raise SystemExit("not ext4")
    bs = 1024 << struct.unpack_from("<I", sb, 24)[0]
    first_data = struct.unpack_from("<I", sb, 20)[0]
    ipg = struct.unpack_from("<I", sb, 40)[0]
    isz = struct.unpack_from("<H", sb, 88)[0]
    incompat = struct.unpack_from("<I", sb, 96)[0]
    jino = struct.unpack_from("<I", sb, 224)[0] or 8
    dsz = struct.unpack_from("<H", sb, 254)[0] if incompat & 0x80 else 32
    g, idx = (jino - 1) // ipg, (jino - 1) % ipg
    gd = h.read((first_data + 1) * bs + g * dsz, dsz)
    itab = struct.unpack_from("<I", gd, 8)[0] | ((struct.unpack_from("<I", gd, 0x28)[0] << 32) if dsz >= 64 else 0)
    inode = h.read(itab * bs + idx * isz, isz)
    ranges = []

    def walk(node):
        magic, entries, _mx, depth = struct.unpack_from("<HHHH", node, 0)
        if magic != 0xF30A:
            raise SystemExit("journal inode has no extent tree")
        for i in range(entries):
            off = 12 + 12 * i
            if depth == 0:
                _lb, ln, hi, lo = struct.unpack_from("<IHHI", node, off)
                ln = ln - 32768 if ln > 32768 else ln
                p = (hi << 32) | lo
                ranges.append((p * bs, (p + ln) * bs))
            else:
                _lb, lo, hi = struct.unpack_from("<IIH", node, off)
                walk(h.read(((hi << 32) | lo) * bs, bs))

    walk(inode[0x28:0x28 + 60])
    return ranges


def chunk_set(h, size, cs):
    touched = set()
    for a, b in h.data_ranges(0, size):
        touched.update(range(a // cs, (b - 1) // cs + 1))
    return touched


def enable_privilege(name):
    TOKEN_ADJUST_PRIVILEGES, TOKEN_QUERY = 0x20, 0x8
    tok = wintypes.HANDLE()
    adv.OpenProcessToken.argtypes = [wintypes.HANDLE, wintypes.DWORD, ctypes.POINTER(wintypes.HANDLE)]
    check(adv.OpenProcessToken(k32.GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, ctypes.byref(tok)),
          "OpenProcessToken")
    luid = ctypes.c_int64()
    adv.LookupPrivilegeValueW.argtypes = [wintypes.LPCWSTR, wintypes.LPCWSTR, ctypes.c_void_p]
    check(adv.LookupPrivilegeValueW(None, name, ctypes.byref(luid)), "LookupPrivilegeValueW")
    tp = struct.pack("<IqI", 1, luid.value, 2)  # one privilege, SE_PRIVILEGE_ENABLED
    adv.AdjustTokenPrivileges.argtypes = [wintypes.HANDLE, wintypes.BOOL, ctypes.c_char_p, wintypes.DWORD,
                                          ctypes.c_void_p, ctypes.c_void_p]
    check(adv.AdjustTokenPrivileges(tok, False, tp, 0, None, None), "AdjustTokenPrivileges")
    err = ctypes.get_last_error()
    if err:  # ERROR_NOT_ALL_ASSIGNED
        raise OSError(err, f"privilege {name} not held")


def stat_line(img):
    h = H(img)
    size = size_of(img)
    rs = h.data_ranges(0, size)
    data = sum(b - a for a, b in rs)
    try:
        jr = journal_range(h)
        jtot = sum(b - a for a, b in jr)
        jdata = sum(sum(y - x for x, y in h.data_ranges(a, b)) for a, b in jr)
        jtxt = f"journal {jtot / MIB:.0f} MiB data {jdata / MIB:.1f} MiB"
    except SystemExit as e:
        jtxt = f"journal ? ({e})"
    chunks = len(chunk_set(h, size, 64 * MIB))
    h.close()
    vdl = valid_data(img)
    vdl = f"{vdl / MIB:.1f} MiB" if isinstance(vdl, int) else vdl
    return (f"{os.path.basename(os.path.dirname(img))}/{os.path.basename(img)}: size {size / MIB:.0f} MiB, "
            f"sparse {int(is_sparse(img))}, data {data / MIB:.1f} MiB, on-disk {on_disk(img) / MIB:.1f} MiB, "
            f"vdl {vdl}, {jtxt}, 64M chunks {chunks}, ranges {len(rs)}")


def main():
    cmd = sys.argv[1]
    t0 = time.monotonic()
    if cmd == "stat":
        print(stat_line(sys.argv[2]))
    elif cmd == "journal":
        img = sys.argv[2]
        h = H(img, write=True)
        n = sum(fill_holes(h, a, b) for a, b in journal_range(h))
        h.flush()
        h.close()
        print(f"{img}: journal holes written {n / MIB:.1f} MiB in {time.monotonic() - t0:.2f} s")
    elif cmd == "fill":
        img = sys.argv[2]
        h = H(img, write=True)
        n = fill_holes(h, 0, size_of(img))
        h.flush()
        h.set_sparse(False)
        h.close()
        print(f"{img}: holes written {n / MIB:.1f} MiB, sparse flag cleared, in {time.monotonic() - t0:.2f} s")
    elif cmd == "unsparse":
        img = sys.argv[2]
        h = H(img, write=True)
        h.set_sparse(False)
        h.close()
        print(f"{img}: sparse flag cleared in {time.monotonic() - t0:.2f} s")
    elif cmd == "chunklist":
        img, cs = sys.argv[2], int(sys.argv[3]) * MIB
        h = H(img)
        print(" ".join(str(c) for c in sorted(chunk_set(h, size_of(img), cs))))
        h.close()
    elif cmd == "chunks":
        img, cs = sys.argv[2], int(sys.argv[3]) * MIB
        h = H(img, write=True)
        if len(sys.argv) > 4:
            with open(sys.argv[4]) as f:
                want = {int(x) for x in f.read().split()}
        else:
            want = chunk_set(h, size_of(img), cs)
        n = sum(fill_holes(h, c * cs, min((c + 1) * cs, size_of(img))) for c in sorted(want))
        h.flush()
        h.close()
        print(f"{img}: {len(want)} chunks, holes written {n / MIB:.1f} MiB in {time.monotonic() - t0:.2f} s")
    elif cmd == "validdata":
        img = sys.argv[2]
        enable_privilege("SeManageVolumePrivilege")
        size = size_of(img)
        tmp = img + ".vdl"
        src = H(img)
        dst = H(tmp, write=True, create=True)
        dst.set_eof(size)
        check(k32.SetFileValidData(dst.h, size), "SetFileValidData")
        n = 0
        for a, b in src.data_ranges(0, size):
            while a < b:
                k = min(MIB, b - a)
                dst.write(a, src.read(a, k))
                a += k
                n += k
        dst.flush()
        src.close()
        dst.close()
        os.replace(tmp, img)
        print(f"{img}: non-sparse, allocated, valid data length set, {n / MIB:.1f} MiB data copied in "
              f"{time.monotonic() - t0:.2f} s")
    elif cmd == "clone":
        src, dst = sys.argv[2], sys.argv[3]
        size = size_of(src)
        cluster = int(os.environ.get("CLUSTER", "4096"))
        s = H(src)
        d = H(dst, write=True, create=True)
        d.set_sparse(True)
        d.set_eof(size)
        rs = s.data_ranges(0, size)
        n = 0
        for a, b in rs:
            a -= a % cluster
            b = min(size, b + (-b) % cluster)
            while a < b:
                k = min(1 << 30, b - a)
                d.duplicate_from(s, a, a, k)
                a += k
                n += k
        d.flush()
        s.close()
        d.close()
        print(f"{src} -> {dst}: cloned {n / MIB:.1f} MiB in {len(rs)} ranges in {time.monotonic() - t0:.3f} s")
    elif cmd == "copy":
        src, dst = sys.argv[2], sys.argv[3]
        size = size_of(src)
        s = H(src)
        d = H(dst, write=True, create=True)
        d.set_sparse(True)
        d.set_eof(size)
        n = 0
        for a, b in s.data_ranges(0, size):
            while a < b:
                k = min(MIB, b - a)
                d.write(a, s.read(a, k))
                a += k
                n += k
        d.flush()
        s.close()
        d.close()
        print(f"{src} -> {dst}: copied {n / MIB:.1f} MiB in {time.monotonic() - t0:.3f} s")
    elif cmd == "vdldemo":
        d, mib = sys.argv[2], int(sys.argv[3])
        p = os.path.join(d, "vdl-demo.bin")
        h = H(p, write=True, create=True)
        h.set_eof(mib * MIB)
        h.close()
        print(f"vdl-demo: SetEndOfFile {mib} MiB in {time.monotonic() - t0:.2f} s: on-disk {on_disk(p) / MIB:.1f} MiB, "
              f"vdl {valid_data(p)}")
        h = H(p, write=True)
        t1 = time.monotonic()
        h.write(mib * MIB - 4096, b"x" * 4096)
        t2 = time.monotonic()
        h.flush()
        t3 = time.monotonic()
        h.close()
        print(f"vdl-demo: 4 KiB at the end: write {t2 - t1:.2f} s, flush {t3 - t2:.2f} s; vdl {valid_data(p)}")
        os.remove(p)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
