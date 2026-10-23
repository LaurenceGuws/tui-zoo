#!/usr/bin/env python3
"""Independent emitted-byte, receipt, orthogonality and PTY cleanup proofs."""
from pathlib import Path
import subprocess,json,re,hashlib,struct,os,pty,termios,copy,select,time,signal,sys,tempfile,fcntl
scratch=tempfile.TemporaryDirectory(prefix="tui-zoo-unicode-")
G=Path(scratch.name)
BIN=Path(sys.argv[1]).resolve()
D=G/"cli";D.mkdir()
cases=["ascii","utf8","combining","wide","emoji","scripts","presentation","churn","mixed"]
results=[];position_groups={}
sgr=re.compile(rb"\x1b\[[0-9;]*m")
cup=re.compile(rb"\x1b\[(\d+);(\d+)H(?:\x1b\[[0-9;]*m)*")
def run(args,label,ok=True):
 p=subprocess.run([str(BIN),*args],stdin=subprocess.DEVNULL,capture_output=True,timeout=10)
 (D/(label+".stdout")).write_bytes(p.stdout);(D/(label+".stderr")).write_bytes(p.stderr)
 if ok:p.check_returncode()
 return p
for case in cases:
 for pattern in ["random","sequential"]:
  control=None
  for fg,bg in [(False,False),(True,False),(False,True),(True,True)]:
   label=f"{case}-{pattern}-{int(fg)}{int(bg)}"
   args=["unicode","--case",case,"--pattern",pattern,"--frames","2","--dose","32","--fps","1000","--seed","7","--cols","5","--rows","3","--synchronized-output","--no-alt-screen","--digest"]
   if fg:args.append("--foreground")
   if bg:args.append("--background")
   p=run(args,label);r=json.loads(p.stderr)
   assert r["type"]=="tui_zoo.unicode/v1" and r["writes"]==64 and r["frames"]==2
   assert r["foreground"]==fg and r["background"]==bg and r["unused_columns"]==1
   begin=p.stdout.index(b"\x1b[?2026h");end=p.stdout.rindex(b"\x1b[?2026l")+8
   assert r["frame_bytes"]==end-begin,(label,r["frame_bytes"],end-begin)
   position_hash=hashlib.sha256(b"tui-zoo.unicode.positions/v1"+struct.pack(">HH",5,3))
   text_hash=hashlib.sha256(b"tui-zoo.unicode.text/v1")
   payload=0;scalars=0;ops=[]
   for match in cup.finditer(p.stdout):
    row,col=map(int,match.groups());assert 1<=row<=3 and col in [1,3]
    end=p.stdout.index(b"\x1b",match.end())
    text=p.stdout[match.end():end]
    assert text and b"\x1b"not in text
    payload+=len(text);scalars+=len(text.decode("utf-8"))
    position_hash.update(struct.pack(">HH",row,col));text_hash.update(struct.pack(">H",len(text))+text)
    ops.append((row,col,text))
   assert len(ops)==64 and payload==r["payload_bytes"]and scalars==r["codepoints"]
   assert r["nominal_cells"]==128
   assert position_hash.hexdigest()==r["positions_sha256"]
   assert text_hash.hexdigest()==r["text_sha256"]
   stripped=sgr.sub(b"",p.stdout)
   if control is None:control=stripped
   else:assert stripped==control,("color changed text or position",label)
   if pattern in position_groups:assert r["positions_sha256"]==position_groups[pattern]
   else:position_groups[pattern]=r["positions_sha256"]
   results.append(dict(label=label,receipt=r,stdout_sha=hashlib.sha256(p.stdout).hexdigest()))
# Runtime-only timing does not silently enable digest work.
r=json.loads(run(["unicode","--duration-ms","25","--fps","240","--dose","8"],"duration").stderr)
assert r["positions_sha256"]is None and r["text_sha256"]is None and not r["digest"]
# All churn values are exercised in an actual emitted stream.
p=run(["unicode","--case","churn","--frames","1","--dose","4096","--fps","1000","--cols","80","--rows","24"],"churn4096")
texts=[]
for m in cup.finditer(p.stdout):texts.append(p.stdout[m.end():p.stdout.index(b"\x1b",m.end())].decode())
assert len(texts)==4096 and len(set(texts))==4096 and all(0x4e00<=ord(t)<=0x5dff for t in texts)
invalid=[["--case","nope"],["--pattern","nope"],["--digest"],["--cols","1"],["--frames","0"],["--frames","1000001"],["--dose","0"],["--dose","65537"],["--fps","nan"],["--fps","1001"],["--oracle"],["--cursor-only"],["--glyph-set","unicode"],["--case"],["--pattern"],["--frames","2","--digest","--duration-ms","1"]]
for n,args in enumerate(invalid):
 p=run(["unicode",*args],f"invalid{n}",False)
 assert p.returncode==2 and p.stdout==b""and json.loads(p.stderr)["workload"]=="unicode"
# Reject a live one-column PTY before entering or clearing the screen.
master,slave=pty.openpty()
fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack("HHHH",1,1,0,0))
p=subprocess.Popen([str(BIN),"unicode","--frames","1"],stdin=subprocess.DEVNULL,stdout=slave,stderr=subprocess.PIPE)
_,err=p.communicate(timeout=5)
assert p.returncode==2 and json.loads(err)["workload"]=="unicode"
assert not select.select([master],[],[],0)[0]
os.close(master);os.close(slave)
# Graceful signal restores the owning PTY's full termios and visible terminal modes.
master,slave=pty.openpty()
original=copy.deepcopy(termios.tcgetattr(slave));output=bytearray()
p=subprocess.Popen([str(BIN),"unicode","--case","mixed","--dose","64","--fps","240","--duration-ms","60000","--synchronized-output"],stdin=slave,stdout=slave,stderr=subprocess.PIPE,start_new_session=True)
end=time.monotonic()+.3
while time.monotonic()<end:
 if select.select([master],[],[],.02)[0]:output.extend(os.read(master,65536))
p.send_signal(signal.SIGTERM)
end=time.monotonic()+5
while p.poll()is None and time.monotonic()<end:
 if select.select([master],[],[],.02)[0]:output.extend(os.read(master,65536))
assert p.wait(timeout=1)==0
while select.select([master],[],[],0)[0]:output.extend(os.read(master,65536))
assert termios.tcgetattr(slave)==original
assert output.count(b"\x1b[?2026h")==output.count(b"\x1b[?2026l")
assert output.endswith(b"\x1b[0m\x1b[2J\x1b[H\x1b[?25h\x1b[?1049l")
receipt=json.loads(p.stderr.read());assert receipt["frames"]>0
os.close(master);os.close(slave)
(D/"signal.stdout").write_bytes(output)
manifest=dict(ok=True,binary_sha=hashlib.sha256(BIN.read_bytes()).hexdigest(),matrix_runs=len(results),matrix=results,invalid_cases=len(invalid),signal_receipt=receipt,limits="Input/counters/determinism/cleanup proofs. No Unicode screen-state or performance ranking claim.")
(G/"cli-proof.json").write_text(json.dumps(manifest,indent=2))
print(json.dumps(dict(ok=True,matrix_runs=len(results),invalid=len(invalid),churn_unique=4096,signal_cleanup=True)))
