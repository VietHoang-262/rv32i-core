#!/usr/bin/env python3
"""No cross compiler required: assemble test programs, execute an independent ISA model.
The model emits architectural retirements and externally visible memory transactions.
"""
from pathlib import Path
import argparse
import random
import json
from collections import Counter

MASK = 0xffffffff
MEM_BYTES = 4096
WORDS = MEM_BYTES // 4

def sx(v, n):
    return (v & ((1 << n) - 1)) - ((v >> (n - 1) & 1) << n)

def i(op, rd, f3, rs1, imm):
    return ((imm & 4095) << 20) | rs1 << 15 | f3 << 12 | rd << 7 | op

def r(rd, f3, rs1, rs2, f7=0):
    return f7 << 25 | rs2 << 20 | rs1 << 15 | f3 << 12 | rd << 7 | 0x33

def s(f3, rs1, rs2, imm):
    imm &= 4095
    return (imm >> 5) << 25 | rs2 << 20 | rs1 << 15 | f3 << 12 | (imm & 31) << 7 | 0x23

def b(f3, rs1, rs2, imm):
    assert imm % 2 == 0 and -4096 <= imm < 4096
    return ((imm >> 12) & 1) << 31 | ((imm >> 5) & 63) << 25 | rs2 << 20 | rs1 << 15 | f3 << 12 | ((imm >> 1) & 15) << 8 | ((imm >> 11) & 1) << 7 | 0x63

def u(op, rd, imm):
    return (imm & 0xfffff000) | rd << 7 | op

def j(rd, imm):
    return ((imm >> 20) & 1) << 31 | ((imm >> 1) & 1023) << 21 | ((imm >> 11) & 1) << 20 | ((imm >> 12) & 255) << 12 | rd << 7 | 0x6f

class Program:
    def __init__(self):
        self.code, self.labels, self.fixups = [], {}, []
    def emit(self, *words): self.code.extend(words)
    def label(self, name): self.labels[name] = len(self.code)*4
    def branch(self, f3, a, c, target):
        self.fixups.append((len(self.code), 'b', (f3,a,c), target)); self.emit(0)
    def jump(self, rd, target):
        self.fixups.append((len(self.code), 'j', (rd,), target)); self.emit(0)
    def li(self, rd, val):
        val &= MASK
        hi = (val + 0x800) & 0xfffff000
        self.emit(u(0x37, rd, hi), i(0x13, rd, 0, rd, sx(val & 4095, 12)))
    def finish(self):
        for idx, typ, args, target in self.fixups:
            delta = self.labels[target] - idx*4
            self.code[idx] = b(*args, delta) if typ == 'b' else j(*args, delta)
        return self.code

# Directed groups keep fixed golden constants separate from the interpreter.
MNEMONICS = {
    'r_type': ('ADD','SUB','SLL','SLT','SLTU','XOR','SRL','SRA','OR','AND'),
    'i_arithmetic': ('ADDI','SLTI','SLTIU','XORI','ORI','ANDI'),
    'shift_imm': ('SLLI','SRLI','SRAI'),
    'loads': ('LB','LH','LW','LBU','LHU'),
    'stores': ('SB','SH','SW'),
    'branches': ('BEQ','BNE','BLT','BGE','BLTU','BGEU'),
    'u_type': ('LUI','AUIPC'), 'jumps': ('JAL','JALR'),
    'fence_system': ('FENCE','ECALL','EBREAK'),
}

def mnemonic(ins):
    op=ins&127; f3=(ins>>12)&7; f7=ins>>25
    if op==0x33:
        if f3==0: return 'SUB' if f7==32 else 'ADD'
        if f3==5: return 'SRA' if f7==32 else 'SRL'
        return {1:'SLL',2:'SLT',3:'SLTU',4:'XOR',6:'OR',7:'AND'}[f3]
    if op==0x13:
        if f3==5: return 'SRAI' if f7==32 else 'SRLI'
        return {0:'ADDI',1:'SLLI',2:'SLTI',3:'SLTIU',4:'XORI',6:'ORI',7:'ANDI'}[f3]
    if op==3: return {0:'LB',1:'LH',2:'LW',4:'LBU',5:'LHU'}[f3]
    if op==0x23: return {0:'SB',1:'SH',2:'SW'}[f3]
    if op==0x63: return {0:'BEQ',1:'BNE',4:'BLT',5:'BGE',6:'BLTU',7:'BGEU'}[f3]
    return {0x37:'LUI',0x17:'AUIPC',0x6f:'JAL',0x67:'JALR',0xf:'FENCE',0x73:'ECALL' if ins==0x73 else 'EBREAK'}[op]

def coverage_requirements():
    required={f'mnemonic:{m}':1 for group in MNEMONICS.values() for m in group}
    required.update({f'branch:{m}:{outcome}':1 for m in MNEMONICS['branches'] for outcome in ('taken','not_taken')})
    for m in ('LB','LBU','SB'): required.update({f'lane:{m}:{lane}':1 for lane in range(4)})
    for m in ('LH','LHU','SH'): required.update({f'lane:{m}:{lane}':1 for lane in (0,2)})
    for m in ('LW','SW'): required[f'lane:{m}:0']=1
    for m in ('LB','LH'): required.update({f'sign:{m}:{sign}':1 for sign in ('positive','negative')})
    for m in MNEMONICS['shift_imm']: required.update({f'shamt:{m}:{sh}':1 for sh in (0,1,15,31)})
    required.update({f'fault:{cause}':1 for cause in (0,1,2,3,4,5,6,7,11)})
    return dict(sorted(required.items()))

class GoldenProgram(Program):
    def __init__(self):
        super().__init__(); self.golden={}; self.memory_golden={}
    def expect(self, ins, rd, value):
        self.golden[len(self.code)*4]=(rd,value); self.emit(ins)
    def options(self,group):
        return dict(group=group,golden=self.golden,memory_golden=self.memory_golden)

def grouped_programs():
    p=GoldenProgram()
    for rd,val in ((1,0x80000001),(2,31),(3,MASK),(4,1),(5,32),(6,0x7fffffff)): p.li(rd,val)
    vectors=[(0,1,3,0,0x80000000),(0,6,3,32,0x80000000),(1,1,2,0,0x80000000),
             (2,1,6,0,1),(3,1,6,0,0),(4,1,3,0,0x7ffffffe),(5,1,2,0,1),
             (5,1,2,32,MASK),(6,1,6,0,MASK),(7,1,3,0,0x80000001),
             (1,1,5,0,0x80000001),(5,1,5,0,0x80000001),(5,1,3,32,MASK)]
    for f3,a,c,f7,value in vectors: p.expect(r(10,f3,a,c,f7),10,value)
    p.expect(r(1,0,1,4),1,0x80000002) # rd aliases old rs1
    p.expect(r(4,0,4,4),4,2) # rd==rs1==rs2
    p.emit(0x100073)
    yield 'group_r_type',p.finish(),p.options('r_type')

    p=GoldenProgram(); p.li(1,0x80000001)
    for f3,a,imm,value in ((0,1,-1,0x80000000),(2,1,-2048,1),(3,1,-1,1),
                         (4,1,-1,0x7ffffffe),(6,1,2046,0x800007ff),(7,1,-2048,0x80000000),
                         (0,1,-2048,0x7ffff801),(0,0,2047,0x7ff),(3,0,-2048,1)):
        p.expect(i(0x13,10,f3,a,imm),10,value)
    p.expect(i(0x13,0,0,0,123),0,123); p.expect(i(0x13,10,0,0,0),10,0)
    p.emit(0x100073)
    yield 'group_i_arithmetic',p.finish(),p.options('i_arithmetic')

    p=GoldenProgram(); p.li(1,0x80000001)
    for f3,upper,values in ((1,0,(0x80000001,2,0x8000,0x80000000)),
                            (5,0,(0x80000001,0x40000000,0x10000,1)),
                            (5,0x400,(0x80000001,0xc0000000,0xffff0000,MASK))):
        for sh,value in zip((0,1,15,31),values): p.expect(i(0x13,10,f3,1,upper|sh),10,value)
    p.emit(0x100073)
    yield 'group_shift_imm',p.finish(),p.options('shift_imm')

    p=GoldenProgram(); p.li(1,0x400); p.li(2,0x80ff7f01); p.emit(s(2,1,2,0))
    for lane,value in enumerate((1,127,0xffffffff,0xffffff80)):
        p.expect(i(3,10,0,1,lane),10,value)
    for lane,value in enumerate((1,127,255,128)): p.expect(i(3,10,4,1,lane),10,value)
    for lane,signed,unsigned in ((0,0x7f01,0x7f01),(2,0xffff80ff,0x80ff)):
        p.expect(i(3,10,1,1,lane),10,signed); p.expect(i(3,10,5,1,lane),10,unsigned)
    p.expect(i(3,10,2,1,0),10,0x80ff7f01)
    p.expect(i(3,0,2,1,0),0,0x80ff7f01)
    p.li(3,0x404); p.expect(i(3,10,2,3,-4),10,0x80ff7f01); p.emit(0x100073)
    yield 'group_loads',p.finish(),p.options('loads')

    p=GoldenProgram(); p.li(1,0x400); p.li(2,0xa1b2c3d4)
    # Explicit final bytes prove lane selection and preservation of other lanes.
    for lane in range(4): p.emit(s(0,1,2,lane)); p.memory_golden[0x400+lane]=0xd4
    for lane in (0,2): p.emit(s(1,1,2,4+lane)); p.memory_golden.update({0x404+lane:0xd4,0x405+lane:0xc3})
    p.emit(s(2,1,2,8)); p.memory_golden.update({0x408:0xd4,0x409:0xc3,0x40a:0xb2,0x40b:0xa1})
    p.expect(i(3,10,2,1,0),10,0xd4d4d4d4); p.expect(i(3,10,2,1,4),10,0xc3d4c3d4)
    p.expect(i(3,10,2,1,8),10,0xa1b2c3d4)
    p.li(3,0x40d); p.emit(s(0,3,0,-1)); p.memory_golden[0x40c]=0
    p.emit(0x100073)
    yield 'group_stores',p.finish(),p.options('stores')

    p=GoldenProgram(); p.li(1,0x80000000); p.li(2,0x7fffffff); p.li(3,MASK); p.li(4,0)
    # Each comparison has independently chosen true/false/equality inputs.
    pairs={0:((1,1,True),(1,2,False)),1:((1,2,True),(1,1,False)),
           4:((1,2,True),(2,1,False),(1,1,False)),5:((2,1,True),(1,2,False),(1,1,True)),
           6:((2,1,True),(1,2,False),(1,1,False)),7:((1,2,True),(2,1,False),(1,1,True))}
    marker=0
    for f3,vectors in pairs.items():
        for a,c,take in vectors:
            target=f'directed_branch_{len(p.code)}'; p.branch(f3,a,c,target)
            p.emit(i(0x13,10,0,10,1)); marker+=not take; p.label(target)
    p.expect(i(0x13,11,0,10,0),11,int(marker))
    p.emit(i(0x13,12,0,0,3)); p.label('group_loop'); p.emit(i(0x13,12,0,12,-1)); p.branch(1,12,0,'group_loop')
    p.expect(i(0x13,11,0,12,0),11,0); p.emit(0x100073)
    yield 'group_branches',p.finish(),p.options('branches')

    p=GoldenProgram(); p.expect(u(0x37,10,0x80000000),10,0x80000000)
    p.expect(u(0x37,10,0xfffff000),10,0xfffff000); p.expect(u(0x17,10,0xfffff000),10,0xfffff008)
    p.expect(u(0x17,11,0x12345000),11,0x1234500c); p.emit(0x100073)
    yield 'group_u_type',p.finish(),p.options('u_type')

    p=GoldenProgram()
    p.expect(j(1,8),1,4); p.emit(0xffffffff)
    p.expect(i(0x13,2,0,0,21),2,21) # target 16 after negative offset and bit0 mask
    p.expect(i(0x67,2,0,2,-4),2,16) # rd aliases old rs1; target16, link16
    p.expect(j(3,8),3,20); p.emit(0x100073)
    p.expect(j(0,-4),0,28); p.emit(0xffffffff)
    yield 'group_jumps',p.finish(),p.options('jumps')

    p=GoldenProgram(); p.emit(0x0ff0000f,0x8ff1808f,0x0000000f); p.expect(i(0x13,10,0,0,7),10,7); p.emit(0x100073)
    yield 'group_fence_system',p.finish(),p.options('fence_system')
    yield 'group_system_ecall',[0x73],dict(group='fence_system')


class Stop(Exception):
    def __init__(self, cause, pc, tval=0): self.info=(cause,pc,tval & MASK)

# This model decodes raw instruction bits independently of the RTL control signals.
def execute(code, initial, imem_fault=MASK, dmem_fault=MASK, reset_pc=0, coverage=None, final_regs=None):
    regs=[0]*32; mem=bytearray(initial); pc=reset_pc; retire=[]; txns=[]
    if coverage is None: coverage=Counter()
    try:
        for _ in range(20000):
            if pc & 3: raise Stop(0,pc,pc)
            if pc == imem_fault or pc >= MEM_BYTES: raise Stop(1,pc,pc)
            ins=code[pc//4] if pc//4 < len(code) else 0x13
            op=ins&127; rd=(ins>>7)&31; f3=(ins>>12)&7; a=(ins>>15)&31; c=(ins>>20)&31; f7=ins>>25
            av=regs[a]; cv=regs[c]; imm=sx(ins>>20,12); npc=(pc+4)&MASK; result=0; wr=False
            if op==0x33:
                if f7 not in (0,32) or (f7==32 and f3 not in (0,5)): raise Stop(2,pc,ins)
                if f3==0: result=av-cv if f7 else av+cv
                elif f3==1: result=av<<(cv&31)
                elif f3==2: result=int(sx(av,32)<sx(cv,32))
                elif f3==3: result=int(av<cv)
                elif f3==4: result=av^cv
                elif f3==5: result=sx(av,32)>>(cv&31) if f7 else av>>(cv&31)
                elif f3==6: result=av|cv
                else: result=av&cv
                wr=True
            elif op==0x13:
                if f3==0: result=av+imm
                elif f3==2: result=int(sx(av,32)<imm)
                elif f3==3: result=int(av<(imm&MASK))
                elif f3==4: result=av^(imm&MASK)
                elif f3==6: result=av|(imm&MASK)
                elif f3==7: result=av&(imm&MASK)
                elif f3==1:
                    if f7: raise Stop(2,pc,ins)
                    result=av<<c
                elif f3==5:
                    if f7 not in (0,32): raise Stop(2,pc,ins)
                    result=sx(av,32)>>c if f7 else av>>c
                wr=True
            elif op in (0x37,0x17):
                result=(ins&0xfffff000)+(pc if op==0x17 else 0); wr=True
            elif op in (0x6f,0x67):
                if op==0x67:
                    if f3: raise Stop(2,pc,ins)
                    target=((av+imm)&MASK)&~1
                else:
                    ji=((ins>>31)<<20)|(((ins>>12)&255)<<12)|(((ins>>20)&1)<<11)|(((ins>>21)&1023)<<1)
                    target=(pc+sx(ji,21))&MASK
                if target&3: raise Stop(0,pc,target)
                result=pc+4; wr=True; npc=target
            elif op==0x63:
                if f3 not in (0,1,4,5,6,7): raise Stop(2,pc,ins)
                take={0:av==cv,1:av!=cv,4:sx(av,32)<sx(cv,32),5:sx(av,32)>=sx(cv,32),6:av<cv,7:av>=cv}[f3]
                coverage[f'branch:{mnemonic(ins)}:{"taken" if take else "not_taken"}']+=1
                bi=((ins>>31)<<12)|(((ins>>7)&1)<<11)|(((ins>>25)&63)<<5)|(((ins>>8)&15)<<1)
                if take:
                    npc=(pc+sx(bi,13))&MASK
                    if npc&3: raise Stop(0,pc,npc)
            elif op in (3,0x23):
                store=op==0x23
                if f3 not in ((0,1,2) if store else (0,1,2,4,5)): raise Stop(2,pc,ins)
                if store: imm=sx(((ins>>25)<<5)|((ins>>7)&31),12)
                addr=(av+imm)&MASK; width=1<<(f3&3)
                if addr&(width-1): raise Stop(6 if store else 4,pc,addr)
                lane=addr&3; be=((1<<width)-1)<<lane; wd=(cv<<(8*lane))&MASK
                txns.append((addr,int(store),be,wd if store else 0))
                if addr==dmem_fault or addr+width>MEM_BYTES: raise Stop(7 if store else 5,pc,addr)
                coverage[f'lane:{mnemonic(ins)}:{lane}']+=1
                if store:
                    mem[addr:addr+width]=(cv&((1<<(width*8))-1)).to_bytes(width,'little')
                else:
                    result=int.from_bytes(mem[addr:addr+width],'little')
                    if f3 in (0,1):
                        coverage[f'sign:{mnemonic(ins)}:{"negative" if result>>(width*8-1) else "positive"}']+=1
                        result=sx(result,width*8)
                    wr=True
            elif op==0xf:
                if f3: raise Stop(2,pc,ins)
            elif op==0x73:
                if ins==0x73: raise Stop(11,pc)
                if ins==0x100073: raise Stop(3,pc)
                raise Stop(2,pc,ins)
            else: raise Stop(2,pc,ins)
            coverage[f'mnemonic:{mnemonic(ins)}']+=1
            if op==0x13 and f3 in (1,5): coverage[f'shamt:{mnemonic(ins)}:{c}']+=1
            result&=MASK
            retire.append((pc,ins,int(wr and rd!=0),rd,result))
            if wr and rd: regs[rd]=result
            regs[0]=0; pc=npc
        raise RuntimeError('reference model timeout')
    except Stop as stop:
        if final_regs is not None: final_regs.extend(regs)
        coverage[f'fault:{stop.info[0]}']+=1
        if stop.info[0] in (3,11): coverage[f'mnemonic:{"EBREAK" if stop.info[0]==3 else "ECALL"}']+=1
        return retire,txns,mem,stop.info

def main_program(seed):
    p=Program()
    p.li(1,0x80000000); p.li(2,0xffffffff); p.li(3,31); p.li(4,32); p.li(5,0x7fffffff)
    p.emit(i(0x13,0,0,0,123)) # x0 must remain zero
    for a,c in ((1,2),(2,3),(5,4),(0,1),(3,5),(2,2)):
        for f3 in range(8): p.emit(r(6,f3,a,c))
        p.emit(r(6,0,a,c,32),r(6,5,a,c,32))
    for imm in (-2048,-1,0,1,2047):
        for f3 in (0,2,3,4,6,7): p.emit(i(0x13,7,f3,1,imm))
    for sh in (0,1,15,31):
        p.emit(i(0x13,7,1,1,sh),i(0x13,7,5,1,sh),i(0x13,7,5,1,0x400|sh))
    p.emit(u(0x37,8,0xabcde000),u(0x17,9,0x12345000))
    # Every branch both ways, including unsigned/signed disagreement.
    for f3 in (0,1,4,5,6,7):
        for a,c in ((1,2),(2,1),(0,0)):
            target=f'br_{len(p.code)}'; p.branch(f3,a,c,target); p.emit(i(0x13,10,0,10,1)); p.label(target)
    p.emit(i(0x13,11,0,0,3)); p.label('loop'); p.emit(i(0x13,11,0,11,-1)); p.branch(1,11,0,'loop')
    p.jump(12,'jump'); p.emit(0xffffffff); p.label('jump')
    target=(len(p.code)+4)*4
    p.emit(i(0x13,13,0,0,target+1),i(0x67,14,0,13,0),0xffffffff,0xffffffff)
    p.emit(i(0x13,15,0,0,0x400)); p.li(16,0x80ff7f01)
    p.emit(s(2,15,16,0))
    for lane in range(4):
        p.emit(i(3,17,0,15,lane),i(3,17,4,15,lane))
    for lane in (0,2): p.emit(i(3,17,1,15,lane),i(3,17,5,15,lane))
    p.emit(i(3,17,2,15,0))
    for lane in range(4): p.emit(s(0,15,16,4+lane),i(3,17,4,15,4+lane))
    for lane in (0,2): p.emit(s(1,15,16,8+lane),i(3,17,5,15,8+lane))
    # Signed negative offset, x0 load suppression, ordinary and reserved-field FENCE.
    p.emit(i(0x13,18,0,15,16),i(3,0,2,18,-16),s(0,18,16,-1),0x0ff0000f,0x8ff1808f)
    rng=random.Random(seed)
    for _ in range(300):
        rd=rng.randrange(1,32); a=rng.randrange(32); c=rng.randrange(32); f3=rng.randrange(8)
        if rng.randrange(2): p.emit(r(rd,f3,a,c,32 if f3 in (0,5) and rng.randrange(2) else 0))
        else:
            imm=rng.randrange(-2048,2048)
            if f3 in (1,5): imm=rng.randrange(32)|(0x400 if f3==5 and rng.randrange(2) else 0)
            p.emit(i(0x13,rd,f3,a,imm))
    # Re-establish data base after randomized register modifications.
    p.emit(i(0x13,15,0,0,0x400))
    for _ in range(80):
        f3=rng.randrange(3); width=1<<f3; off=rng.randrange(64//width)*width
        p.emit(s(f3,15,rng.randrange(32),off),i(3,rng.choice([n for n in range(32) if n!=15]),f3+(4 if f3<2 and rng.randrange(2) else 0),15,off))
    p.emit(0x100073)
    return p.finish()

def write_case(root,name,code,imem_fault=MASK,dmem_fault=MASK,reset_pc=0,group="regression",golden=None,memory_golden=None):
    out=root/name; out.mkdir(parents=True,exist_ok=True)
    initial=bytearray(((n*73+0x81)&255) for n in range(MEM_BYTES))
    coverage=Counter(); final_regs=[]
    retire,txns,final,stop=execute(code,initial,imem_fault,dmem_fault,reset_pc,coverage,final_regs)
    # These explicit constants are authored independently of execute(): detect
    # model/encoder mistakes before its trace is consumed by the RTL scoreboard.
    golden=golden or {}
    memory_golden=memory_golden or {}
    by_pc={row[0]:row for row in retire}
    for pc,(rd,value) in golden.items():
        row=by_pc.get(pc)
        if row is None or row[2:]!=(int(rd!=0),rd,value):
            raise AssertionError(f'{name}: fixed golden pc={pc:x}, expected rd{rd}={value:08x}, model={row}')
    for addr,value in memory_golden.items():
        if final[addr]!=value: raise AssertionError(f'{name}: fixed memory golden addr={addr:x}')
    (out/'metadata.json').write_text(json.dumps(dict(name=name,group=group,coverage=dict(sorted(coverage.items())),golden_checks=len(golden)+len(memory_golden),retirements=len(retire),transactions=len(txns),halt_cause=stop[0]),indent=2)+'\n')
    def words(data): return [int.from_bytes(data[n:n+4],'little') for n in range(0,len(data),4)]
    (out/'program.hex').write_text(''.join(f'{v:08x}\n' for v in code+[0x13]*(WORDS-len(code))))
    (out/'data.hex').write_text(''.join(f'{v:08x}\n' for v in words(initial)))
    (out/'registers.hex').write_text(''.join(f'{v:08x}\n' for v in final_regs))
    (out/'final.hex').write_text(''.join(f'{v:08x}\n' for v in words(final)))
    (out/'retire.hex').write_text(''.join(' '.join(f'{v:x}' for v in row)+'\n' for row in retire))
    (out/'transactions.hex').write_text(''.join(' '.join(f'{v:x}' for v in row)+'\n' for row in txns))
    cause,pc,tval=stop
    (out/'config.hex').write_text(' '.join(f'{v:x}' for v in (cause,pc,tval,int(cause==11),int(cause==3),len(retire),len(txns),imem_fault,dmem_fault,reset_pc))+'\n')
    return name

def generate(root):
    names=[]
    def case(name,code,**kw): names.append(write_case(root,name,code,**kw))
    for seed in (1,23,2026): case(f'isa_seed_{seed}',main_program(seed))
    case('ecall',[0x73]); case('ebreak',[0x100073]); case('fetch_error',[0x13],imem_fault=0)
    case('fetch_error_after_jump',[j(1,16)],imem_fault=16)
    for f3 in (1,2,5):
        for lane in range(1,4):
            if lane%(1<<(f3&3)): case(f'load_align_{f3}_{lane}',[i(3,1,f3,0,0x400+lane)])
    for f3 in (1,2):
        for lane in range(1,4):
            if lane%(1<<f3): case(f'store_align_{f3}_{lane}',[s(f3,0,1,0x400+lane)])
    case('load_error',[i(3,1,2,0,0x400)],dmem_fault=0x400)
    case('load_x0_error',[i(3,0,2,0,0x400)],dmem_fault=0x400)
    case('fetch_out_of_range',[u(0x37,1,0x1000),i(0x67,0,0,1,0)])
    case('jalr_same_rd_rs1',[i(0x13,1,0,0,13),i(0x67,1,0,1,0),0xffffffff,0x100073])
    case('jal_negative',[j(0,8),0x100073,j(1,-4)])
    case('store_error',[i(0x13,1,0,0,123),s(2,0,1,0x400)],dmem_fault=0x400)
    case('load_out_of_range',[u(0x37,1,0x1000),i(3,2,2,1,0)])
    case('store_out_of_range',[u(0x37,1,0x1000),s(2,1,0,0)])
    case('jal_align',[j(1,2)])
    case('jalr_align',[i(0x13,1,0,0,3),i(0x67,2,0,1,0)])
    case('branch_align_taken',[b(0,0,0,2)])
    case('branch_align_not_taken',[b(1,0,0,2),0x100073])
    case('reset_pc_align',[0x13],reset_pc=2)
    case('reset_fetch',[i(0x13,1,0,0,12),0x100073])
    case('reset_data',[i(3,1,2,0,0x400),0x100073])
    case('reset_store',[s(0,0,0,0x400),0x100073])
    # Unsupported extensions, malformed integer encodings, and exact SYSTEM checks.
    bad=[0xffffffff,0, r(1,0,0,0,1),i(0x13,1,1,0,0x20),i(0x13,1,1,0,0x400),i(0x13,1,5,0,0x200),i(0x67,1,1,0,0),i(3,1,3,0,0),s(3,0,1,0),b(2,0,0,0),0x0000100f,0x30001073,0x00200073,0x00008073,0x000000f3,0x30200073]
    for idx,ins in enumerate(bad): case(f'illegal_{idx:02}',[ins])
    for name,code,options in grouped_programs(): case(name,code,**options)
    (root/'cases.txt').write_text('\n'.join(names)+'\n')
    coverage=Counter()
    for name in names: coverage.update(json.loads((root/name/'metadata.json').read_text())['coverage'])
    required=coverage_requirements()
    missing={key:count for key,count in required.items() if coverage[key]<count}
    if missing: raise AssertionError(f'coverage gates missing: {missing}')
    (root/'coverage.json').write_text(json.dumps(dict(status='PASS',source='executed reference paths; RTL results checked separately',counts=dict(sorted(coverage.items())),minimums=required,cases=len(names)),indent=2)+'\n')
    print(f'Generated {len(names)} cases in {root}; {len(required)} coverage gates PASS')

if __name__=='__main__':
    ap=argparse.ArgumentParser(); ap.add_argument('--out',type=Path,default=Path('build/cases')); generate(ap.parse_args().out)
