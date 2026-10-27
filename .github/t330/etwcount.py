"""Count flushes and writes in a tracerpt CSV of an NT Kernel Logger trace (disk,file,fileio).

  etwcount.py --dump <csv>                       event counts per (name, type) with two sample rows each
  etwcount.py --count <csv> <disk> <ops> <secs> [label]
      one line, per op (divided by <ops>): disk flushes on <disk> (DiskIo FlushBuffers), FlushFileBuffers
      calls on the image files (FileIo Flush on disk.raw/upper.ext4) and the handles they came through,
      disk writes on <disk> split by file (image, $LogFile, $Mft, other), KiB written.

Columns (tracerpt CSV): 0-18 the event header, user data from 19. DiskIo Read/Write: disk, IrpFlags,
TransferSize, Reserved, ByteOffset, FileObject (= the FileKey of FileIo events), Irp, response time,
thread. DiskIo FlushBuffers: disk, IrpFlags, response time, Irp, thread. FileIo Flush: IrpPtr,
FileObject, FileKey, TTID. FileIo FileCreate/FileRundown/Name: FileKey, name.
"""
import collections
import csv
import sys

IMG = ("\\disk.raw", "\\upper.ext4")


def rows(path):
    raw = open(path, "rb").read()
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
        text = raw.decode("utf-16")
    else:
        text = raw.decode("utf-8-sig", errors="replace")
    return [[x.strip() for x in r] for r in csv.reader(text.splitlines(), skipinitialspace=True)]


def dump(path):
    rs = rows(path)
    print(f"  csv {path}: {len(rs)} rows")
    counts = collections.Counter()
    samples = collections.defaultdict(list)
    for r in rs[1:]:
        if len(r) < 2:
            continue
        k = (r[0], r[1])
        counts[k] += 1
        if len(samples[k]) < 2:
            samples[k].append(r)
    for k, n in sorted(counts.items(), key=lambda x: -x[1]):
        print(f"  {k[0]:>20} {k[1]:<20} {n}")
        for s in samples[k]:
            print("      " + " , ".join(s)[:600])


def count(path, disk, ops, secs, label):
    rs = rows(path)
    names = {}
    for r in rs:
        if len(r) > 20 and r[0] == "FileIo" and r[1] in ("FileCreate", "FileRundown", "Name"):
            names[r[19]] = r[20]
    c = collections.Counter()
    img_handles = set()
    flush_names = collections.Counter()
    resp = []
    t0 = t1 = None
    for r in rs[1:]:
        if len(r) < 20:
            continue
        ev, ty, ud = r[0], r[1], r[19:]
        if ev == "DiskIo" and ty == "FlushBuffers":
            if ud[0] == disk:
                c["dflush"] += 1
                try:
                    resp.append(int(ud[2]))
                except ValueError:
                    pass
            else:
                c["dflush_other_disk"] += 1
        elif ev == "DiskIo" and ty == "Write" and ud[0] == disk:
            c["dwrite"] += 1
            c["dwbytes"] += int(ud[2])
            n = names.get(ud[5], "?")
            if n.endswith(IMG):
                c["dw_img"] += 1
            elif n.endswith("\\$LogFile"):
                c["dw_log"] += 1
            elif n.endswith("\\$Mft"):
                c["dw_mft"] += 1
            elif n == "?":
                c["dw_unknown"] += 1
            else:
                c["dw_other"] += 1
        elif ev == "FileIo" and ty == "Flush":
            n = names.get(ud[2], "?")
            if n.endswith(IMG):
                c["fflush_img"] += 1
                img_handles.add(ud[1])
            else:
                c["fflush_other"] += 1
                flush_names[n.rsplit("\\", 1)[-1]] += 1
    resp.sort()
    p50 = resp[len(resp) // 2] if resp else 0
    ops = max(ops, 1)
    per = lambda k: f"{c[k] / ops:.2f}"
    other = ",".join(f"{n}:{k}" for n, k in flush_names.most_common(3))
    print(f"{label:<22} dflush/op={per('dflush')} ffl-img/op={per('fflush_img')} handles={len(img_handles)} "
          f"dwrite/op={per('dwrite')} img={per('dw_img')} log={per('dw_log')} mft={per('dw_mft')} "
          f"oth={per('dw_other')} unk={per('dw_unknown')} KiBw/op={c['dwbytes'] / 1024 / ops:.1f} s={secs} "
          f"| raw dflush={c['dflush']} ffl-img={c['fflush_img']} ffl-other={c['fflush_other']} ({other}) "
          f"dflush-other-disk={c['dflush_other_disk']} flush-resp-p50={p50}")


if __name__ == "__main__":
    if sys.argv[1] == "--dump":
        dump(sys.argv[2])
    elif sys.argv[1] == "--count":
        count(sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5], sys.argv[6] if len(sys.argv) > 6 else "")
