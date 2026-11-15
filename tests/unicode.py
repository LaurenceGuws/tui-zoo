#!/usr/bin/env python3
"""Independent emitted-byte, receipt, orthogonality and PTY cleanup proofs."""
from pathlib import Path
import subprocess,json,re,hashlib,struct,os,pty,termios,copy,select,time,signal,sys,tempfile,fcntl,unicodedata
scratch=tempfile.TemporaryDirectory(prefix="tui-zoo-unicode-")
G=Path(scratch.name)
BIN=Path(sys.argv[1]).resolve()
D=G/"cli";D.mkdir()
cases=["ascii","utf8","combining","wide","emoji","scripts","presentation","churn","grapheme-churn","grapheme-repeat","emoji-zwj","indic-conjunct","arabic-join","hangul-nfc","hangul-nfd","mixed"]
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
# Protect the accepted seed-7 text streams used for historical comparisons.
# Pin the new case independently; it is deliberately absent from mixed.
pinned_text_hashes={
 "mixed":"15d3a32a4abf00589c10f8b6d84d3e1084b642fcdb8cfc1f7706a7b2910d51d9",
 "churn":"6b76f9bca9bd3a97b065f42338db33138a651cdbf11ab4c4cca74952d892d896",
 "grapheme-churn":"dc044f68d8d358b1e6fdb954fb8a1635f33bf32d51743d6278e7da5af1f17142",
 "grapheme-repeat":"2b7322aac54de9898997c8a06663d90dd4b53f4468685fb807da4cd62124c599",
 "emoji-zwj":"c51c813fe5c72def9fe4d0575e4d4f93069eeb3ee06b353e307d0e56c0c952ca",
 "indic-conjunct":"ff6c03fef1d45bfdb84010ee6c6322d8d8a6632208d7de823370f51036be89d0",
 "arabic-join":"67acc9f7da05dae3dfbcb9d63bd6e272e9aaff26fcc8783997ce7e12fc5e2857",
 "hangul-nfc":"afbd5889e14358e3b2fde0ea3a9dc8e8cf7ae58d8a908524a274a99b71c3ada9",
 "hangul-nfd":"cc756eb6a12bb7a61bc2c870a81ac610bead8f66032da3d407ae192c2c431533",
}
for case,expected in pinned_text_hashes.items():
 receipt=next(entry["receipt"] for entry in results if entry["label"]==f"{case}-random-00")
 assert receipt["positions_sha256"]=="db73dbb160f1e0524d8876482223c76ad48553ef6bf2240673121e6f5d90b4c4"
 assert receipt["text_sha256"]==expected,(case,receipt["text_sha256"])
# Runtime-only timing does not silently enable digest work.
r=json.loads(run(["unicode","--duration-ms","25","--fps","240","--dose","8"],"duration").stderr)
assert r["positions_sha256"]is None and r["text_sha256"]is None and not r["digest"]
# All churn values are exercised in an actual emitted stream.
p=run(["unicode","--case","churn","--frames","1","--dose","4096","--fps","1000","--cols","80","--rows","24"],"churn4096")
texts=[]
for m in cup.finditer(p.stdout):texts.append(p.stdout[m.end():p.stdout.index(b"\x1b",m.end())].decode())
assert len(texts)==4096 and len(set(texts))==4096 and all(0x4e00<=ord(t)<=0x5dff for t in texts)
# The generated case contains two independent four-scalar clusters per slot.
p=run(["unicode","--case","grapheme-churn","--frames","2","--dose","128","--fps","1000","--seed","7","--cols","80","--rows","24"],"grapheme-churn256")
clusters=[]
for m in cup.finditer(p.stdout):
 text=p.stdout[m.end():p.stdout.index(b"\x1b",m.end())].decode()
 assert len(text)==8 and text[0]=="a" and text[4]=="b"
 clusters.extend([text[:4],text[4:]])
assert len(clusters)==512 and len(set(clusters))==512
# Same encoded dose as churn, but a tiny corpus repeating every 32 slot writes.
repeat=run(["unicode","--case","grapheme-repeat","--frames","2","--dose","128","--fps","1000","--seed","7","--cols","80","--rows","24"],"grapheme-repeat256")
repeated_clusters=[]
for m in cup.finditer(repeat.stdout):
 text=repeat.stdout[m.end():repeat.stdout.index(b"\x1b",m.end())].decode()
 assert len(text)==8 and text[0]=="a" and text[4]=="b"
 repeated_clusters.extend([text[:4],text[4:]])
assert len(repeated_clusters)==512 and len(set(repeated_clusters))==64
assert repeated_clusters[:64]==clusters[:64]
assert repeated_clusters[64:128]==repeated_clusters[:64]
# The two Hangul cases select the same syllables in identical order. NFC and
# decomposed-Jamo inputs must be visibly equivalent by normalization, while
# stressing different UTF-8 and grapheme-joining work. This is input proof only.
def payload_texts(stream):
 return [stream[m.end():stream.index(b"\x1b",m.end())].decode("utf-8") for m in cup.finditer(stream)]
hangul_args=["--frames","1","--dose","256","--fps","1000","--seed","7","--cols","80","--rows","24"]
nfc=payload_texts(run(["unicode","--case","hangul-nfc",*hangul_args],"hangul-nfc-256").stdout)
nfd=payload_texts(run(["unicode","--case","hangul-nfd",*hangul_args],"hangul-nfd-256").stdout)
assert len(nfc)==len(nfd)==256
assert len(set(nfc))==len(set(nfd))==8
assert all(len(a)==1 and len(b) in (2,3) and a!=b and unicodedata.normalize("NFC",b)==a for a,b in zip(nfc,nfd))
# Isolated joining corpora contain the intended Unicode mechanisms in actual
# emitted bytes; never treat these checks as font/shaping/screen-state oracles.
for case,expected in [("emoji-zwj",8),("indic-conjunct",8),("arabic-join",8)]:
 texts=payload_texts(run(["unicode","--case",case,*hangul_args],case+"-256").stdout)
 assert len(texts)==256 and len(set(texts))==expected
 if case=="emoji-zwj":assert all("\u200d" in t for t in texts)
 if case=="indic-conjunct":assert all("\u094d" in t or "\u09cd" in t for t in texts)
 if case=="arabic-join":assert all(any("\u0600"<=c<="\u06ff" for c in t) for t in texts)
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
print(json.dumps(dict(ok=True,matrix_runs=len(results),invalid=len(invalid),churn_unique=4096,hangul_equivalence=True,joining_corpora=True,signal_cleanup=True)))
