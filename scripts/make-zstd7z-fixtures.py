#!/usr/bin/env python3
"""Rebuild added #316 synthetic fixtures; requires py7zr==1.1.4, never an app dependency.
Run from the repository root. Existing plain.7z is the independently produced seed.
"""
from pathlib import Path
import py7zr, io, struct, zlib, tempfile
from compression import zstd
assert py7zr.__version__ == "1.1.4"

root=Path('Tests/Fixtures/Zstd7z');payload=('Stow Zstd-in-7Z verification — 中文\n'*500).encode()
with py7zr.SevenZipFile(root/'solid-multifile.7z','w',filters=[{'id':py7zr.FILTER_ZSTD,'level':3}]) as z:
 z.writestr(payload,'payload.txt');z.writestr(bytes(range(256))*9,'nested/bytes.bin');z.writestr(b'','empty.txt')
with tempfile.TemporaryDirectory() as temporary:
 with py7zr.SevenZipFile(root/'solid-multifile.7z') as z:z.extractall(temporary)
 assert (Path(temporary)/'payload.txt').read_bytes()==payload
 assert (Path(temporary)/'nested/bytes.bin').read_bytes()==bytes(range(256))*9
with py7zr.SevenZipFile(root/'nonsolid-multifile.7z','w',filters=[{'id':py7zr.FILTER_ZSTD,'level':3}]) as z:z.writestr(payload,'payload.txt')
with py7zr.SevenZipFile(root/'nonsolid-multifile.7z','a',filters=[{'id':py7zr.FILTER_ZSTD,'level':3}]) as z:z.writestr(bytes(range(256))*9,'nested/bytes.bin')
with tempfile.TemporaryDirectory() as temporary:
 with py7zr.SevenZipFile(root/'nonsolid-multifile.7z') as z:
  assert len(z.header.main_streams.unpackinfo.folders)==2
  z.extractall(temporary)
 assert (Path(temporary)/'nested/bytes.bin').read_bytes()==bytes(range(256))*9
# A sparse synthetic input avoids holding 2 GiB in memory. Do not extract this fixture
# as routine acceptance: its purpose is cancelling while the decoder is active.
with tempfile.TemporaryDirectory() as temporary:
 source=Path(temporary)/'large.bin'
 with source.open('wb') as f:f.truncate(2<<30)
 with py7zr.SevenZipFile(root/'cancellation.7z','w',filters=[{'id':py7zr.FILTER_ZSTD,'level':1}]) as z:z.write(source,'large.bin')
base=(root/'plain.7z').read_bytes()
def rewrite(name,props=None,mutator=None,crc=None):
 with py7zr.SevenZipFile(io.BytesIO(base)) as z:
  h=z.header
  pack=h.main_streams.packinfo
  stream=base[32:32+sum(pack.packsizes)]
  if props is not None:h.main_streams.unpackinfo.folders[0].coders[0]['properties']=props
  if mutator:stream=mutator(stream);pack.packsizes=[len(stream)]
  if crc is not None:
   h.main_streams.unpackinfo.folders[0].crc=crc
   h.main_streams.substreamsinfo.digests=[crc]
  f=io.BytesIO();f.write(b'\x00'*32);f.write(stream);start,length,checksum=h.write(f,32,encoded=False)
  fields=struct.pack('<QQI',start-32,length,checksum)
  f.seek(0);f.write(b'7z\xbc\xaf\x27\x1c'+bytes([0,4])+struct.pack('<I',zlib.crc32(fields))+fields)
  (root/name).write_bytes(f.getvalue())
rewrite('properties-current.7z',b'\x00')
rewrite('properties-legacy3.7z',b'\x01\x05\x03')
rewrite('properties-unknown-flags.7z',b'\x01')
rewrite('properties-unknown-length.7z',b'\x00\x00')
rewrite('crc-mismatch.7z',crc=0x12345678)
rewrite('truncated-stream.7z',mutator=lambda s:s[:-7])
checksum_frame = zstd.compress(payload, options={zstd.CompressionParameter.checksum_flag: 1})
rewrite('frame-checksum.7z',mutator=lambda _: checksum_frame)
rewrite('frame-checksum-mismatch.7z',mutator=lambda _: checksum_frame[:-1]+bytes([checksum_frame[-1]^1]))
def huge(s):
 assert s[:4]==bytes.fromhex('28b52ffd') and not s[4]&32
 return s[:5]+bytes([160])+s[6:]
rewrite('over-window.7z',mutator=huge)
print('Regenerated synthetic Zstd-in-7Z fixtures.')
