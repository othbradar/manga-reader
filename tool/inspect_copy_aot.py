"""Read-only objdump annotations for incomplete Blutter output; no network."""
import argparse
import re
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--start')
parser.add_argument('--end')
parser.add_argument('--find')
parser.add_argument('--sample', default='reverse_engineering/original_3.0.9_device')
args = parser.parse_args()
root = Path(args.sample)
pool = {}
for line in (root/'blutter_out/pp.txt').read_text().splitlines():
    match = re.match(r'\[pp\+0x([0-9a-f]+)\] (.*)', line)
    if match: pool[int(match[1],16)] = match[2]
names = dict((int(a,16),b) for a,b in re.findall(r'set_name\(0x([0-9a-f]+), "([^"]+)"', (root/'blutter_out/ida_script/addNames.py').read_text()))
command = ['/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/llvm-objdump','-D','--arch-name=aarch64','--section=.text']
if args.start: command.append('--start-address='+args.start)
if args.end: command.append('--stop-address='+args.end)
command.append(str(root/'extracted/lib/arm64-v8a/libapp.so'))
proc = subprocess.Popen(command, stdout=subprocess.PIPE, text=True)
registers = {'x27':0}
for line in proc.stdout:
    address = re.match(r'\s*([0-9a-f]+):', line)
    note = []
    if address and int(address[1],16) in names:
        note.append(names[int(address[1],16)])
    add = re.search(r'add\s+(x\d+), x27, #(0x[0-9a-f]+)(?:, lsl #12)?', line)
    load = re.search(r'ldr\s+x\d+, \[(x\d+), #(0x[0-9a-f]+)\]',line)
    if load and load[1] in registers:
        offset = registers[load[1]] + int(load[2],16)
        if offset in pool: note.append(f'pp+{offset:#x}: '+pool[offset])
    # Do not propagate a base after another instruction overwrites that register.
    dest = re.search(r'\s(?:mov|ldr|ldur|add|sub)\s+(x\d+),',line)
    if dest and dest[1] != 'x27': registers.pop(dest[1], None)
    if add: registers[add[1]] = int(add[2],16) * (4096 if 'lsl #12' in line else 1)
    branch = re.search(r'\bbl\s+0x([0-9a-f]+)',line)
    if branch and int(branch[1],16) in names: note.append('call '+names[int(branch[1],16)])
    result = line.rstrip() + (' // '+ ' | '.join(note) if note else '')
    if not args.find or re.search(args.find, result): print(result)
proc.wait()
