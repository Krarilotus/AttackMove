"""attack-move, run unchanged under the harness on both exes: the game's own click handler runs
from the Shift test to the end of the order, with the order functions stubbed and recorded."""
import sys, struct
sys.path.insert(0, '.')
from harness import Host

FAIL = []


def ok(cond, what):
    print(('  ok   ' if cond else '  FAIL ') + what)
    if not cond:
        FAIL.append(what)


def call_target(h, at):
    return (at + 5 + struct.unpack('<i', h.m.read(at + 1, 4))[0]) & 0xFFFFFFFF


def s16(v):
    return v - 0x10000 if v & 0x8000 else v


def run_exe(extreme, config=None, label=''):
    print(('EXT' if extreme else 'VAN') + label)
    h = Host(extreme=extreme, config=config or {})
    E = h.E
    for line in h.logs:
        print('   log', line)
    shift = E.find('39 3D ? ? ? ? 0F 84 ? ? ? ? 8B 0D ? ? ? ? 3B CF A1 ? ? ? ? 74 4B 83 F8 0A 89 6C 24 2C 0F 8D')[0]
    route = E.find('66 39 9E ? ? 00 00 0F 84 ? ? ? ? 55 8B CF E8 ? ? ? ? 85 C0 0F 84 ? ? ? ? 0F BF 86 ? ? 00 00 0F BF 8E ? ? 00 00 83 C0 01 3B C1')[0]
    ticks_at = E.find('8B 87 50 0A 00 00 8B 8F 98 09 00 00 8B 15')[0]
    shift_flag = E.u32(shift + 2)
    patrol = E.u32(shift + 0x0E)
    tribes = patrol - 0x1C
    count = tribes + 0x20
    mouse_y = E.u32(shift + 0x31)
    mouse_x = E.u32(shift + 0x3F)
    give_move = (shift + 0x4B + 5 + E.i32(shift + 0x4C)) & 0xFFFFFFFF
    end = shift + 0x61                                   # jmp to the handler's end, after the first order
    flag_off = E.u32(route + 3)
    step_off = E.u32(route + 0x20)
    points_off = E.u32(route + 0x6C)
    size = E.u32(route + 0x61) * 4
    all_arrived = (route + 0x10 + 5 + E.i32(route + 0x11)) & 0xFFFFFFFF
    ticks = E.u32(ticks_at + 14)
    normal = (shift + 6 + 6 + E.i32(shift + 8)) & 0xFFFFFFFF
    extend = None
    # the "add a point" call: B9 UnitsState / E8 extendRallyPoint after the counter cap
    code = h.m.read(shift, 0x120)
    for i in range(0x80, 0x110):
        if code[i] == 0xB9 and code[i + 5] == 0xE8:
            t = call_target(h, shift + i + 5)
            if t != give_move:
                extend = t
                break
    print('   shift %08X groups %08X size %X flag +%X step +%X points +%X ext %08X' % (
        shift, tribes, size, flag_off, step_off, points_off, extend or 0))

    T = 7
    G = tribes + T * size

    def group(flag=0, step=0, p1=(0, 0), uid=0x1234):
        h.put16(G + flag_off, flag)
        h.put16(G + step_off, step)
        h.put16(G + points_off + 4, p1[0])
        h.put16(G + points_off + 6, p1[1])
        h.put32(G + 0x34, uid)

    moves, adds, arrived = [], [], []
    patrol_calls = []

    def stubs(arrive=1):
        h.stub(give_move, ret_bytes=0x14, record=moves)
        h.stub(extend, ret_bytes=0x10, record=adds)
        h.stub(all_arrived, result=arrive, ret_bytes=4, record=arrived)

    # The click code ends each order with `jmp <end>`; stop there.
    end_target = None
    from capstone import Cs, CS_ARCH_X86, CS_MODE_32
    md = Cs(CS_ARCH_X86, CS_MODE_32)
    for i in md.disasm(h.m.read(shift + 0x12, 0x100), shift + 0x12):
        if i.mnemonic == 'jmp' and i.op_str.startswith('0x'):
            end_target = int(i.op_str, 16)
            break
    assert end_target
    iat = E.u32(normal + 2)
    h.put32(iat, 0x7F000000)
    h.stub(0x7F000000, result=12345)

    def do(x, y, **k):
        del moves[:], adds[:], arrived[:]
        stubs(k.pop('arrive', 1))
        h.put32(tribes, T)
        h.put32(patrol, k.pop('pat', 0))
        if 'rally' in k:
            h.put32(count, k.pop('rally'))
        h.put32(mouse_x, x)
        h.put32(mouse_y, y)
        h.put32(ticks, k.pop('tick', 1000))
        h.put32(shift_flag, 0 if k.pop('plain', False) else 1)
        h.run(shift, until=end_target, regs={'edi': 0, 'ebp': 1}, stack=[0] * 0x20, limit=50000)
        return [(c[1][:5]) for c in moves], [(c[1][:4]) for c in adds]

    M1 = 0xFFFFFFFF
    # a. fresh selection: counter 1 starts a route
    group()
    mv, ad = do(100, 120, rally=1, tick=1000)
    ok(mv == [[T, 100, 120, M1, 1]] and not ad and h.u32(count) == 2, 'counter 1: a new route (%s %s)' % (mv, ad))
    # d. second Shift-click before the route started: added to it
    mv, ad = do(110, 130, tick=1005)
    ok(not mv and ad == [[T, 110, 130, 2]] and h.u32(count) == 3, 'route ordered, not started: point added (%s %s)' % (mv, ad))
    # b. live route: added
    group(flag=0xFFFF, step=1, p1=(100, 120))
    mv, ad = do(115, 135, tick=1100)
    ok(not mv and ad == [[T, 115, 135, 3]], 'live route: point added (%s %s)' % (mv, ad))
    # e. route finished (flag 0, step 0, first point ours): a new route
    group(flag=0, step=0, p1=(100, 120))
    mv, ad = do(140, 150, tick=1150)
    ok(mv == [[T, 140, 150, M1, 1]] and not ad and h.u32(count) == 2, 'route finished: a new route (%s %s)' % (mv, ad))
    # pending window over, flag still 0: new route
    group(flag=0, step=1, p1=(1, 1))
    mv, ad = do(141, 151, tick=1150 + 300)
    ok(mv == [[T, 141, 151, M1, 1]] and not ad, 'old order, no route: a new route (%s %s)' % (mv, ad))
    # j. another group with the same id: new route
    group(flag=0, step=1, p1=(141, 151), uid=0x9999)
    mv, ad = do(142, 152, tick=1460)
    ok(mv == [[T, 142, 152, M1, 1]] and not ad, 'other group, same id: a new route (%s %s)' % (mv, ad))

    # f. normal move, then Shift-click while it is under way: the move becomes the first leg
    group(flag=0, step=1, p1=(0, 0))
    mv, ad = do(50, 60, plain=True, tick=2000)
    ok(len(mv) == 1 and mv[0][:4] == [T, 50, 60, 0] and h.u32(count) == 2, 'normal move (%s)' % mv)
    group(flag=0, step=1, p1=(50, 60))
    mv, ad = do(70, 80, tick=2010)
    ok(mv == [[T, 50, 60, M1, 1]] and ad == [[T, 70, 80, 2]] and h.u32(count) == 3,
       'Shift after a normal move: move becomes the first leg (%s %s)' % (mv, ad))
    mv, ad = do(75, 85, tick=2015)
    ok(not mv and ad == [[T, 75, 85, 3]], 'and the next Shift-click adds (%s %s)' % (mv, ad))
    # g. normal move long ago: still walking -> first leg, arrived -> new route
    do(50, 60, plain=True, tick=3000)
    group(flag=0, step=1, p1=(50, 60))
    mv, ad = do(70, 80, tick=3500, arrive=0)
    ok(mv == [[T, 50, 60, M1, 1]] and ad == [[T, 70, 80, 2]] and arrived, 'old normal move, still walking: first leg (%s %s)' % (mv, ad))
    do(50, 60, plain=True, tick=4000)
    mv, ad = do(70, 80, tick=4500, arrive=1)
    ok(mv == [[T, 70, 80, M1, 1]] and not ad, 'old normal move, arrived: a new route (%s %s)' % (mv, ad))
    # i. patrol button: the first leg is a patrol
    do(50, 60, plain=True, tick=5000)
    mv, ad = do(70, 80, tick=5005, pat=1)
    ok(mv and mv[0][3] == 1, 'patrol button: first leg is a patrol (%s)' % mv)
    # patrol live: add
    group(flag=1, step=1, p1=(50, 60))
    mv, ad = do(71, 81, tick=5100)
    ok(not mv and len(ad) == 1, 'live patrol: point added (%s %s)' % (mv, ad))
    # cap: counter 10 -> 9
    group(flag=0xFFFF, step=1, p1=(50, 60))
    mv, ad = do(72, 82, rally=10, tick=5200)
    ok(not mv and ad == [[T, 72, 82, 9]], 'cap at nine points kept (%s)' % ad)
    return h


def run_continue_off(extreme):
    h = run_exe(extreme, {'waypoints': {'continue_move': False}}, ' continue_move off')


def alt(extreme, config=None):
    print(('EXT' if extreme else 'VAN') + ' alt')
    h = Host(extreme=extreme, config=config or {})
    E = h.E
    shift = E.find('39 3D ? ? ? ? 0F 84 ? ? ? ? 8B 0D ? ? ? ? 3B CF A1 ? ? ? ? 74 4B 83 F8 0A 89 6C 24 2C 0F 8D')[0]
    alt_flag = E.u32(shift + 2) + 4
    sites = [E.find('6A 05 B9 ? ? ? ? E8 ? ? ? ? 33 DB 3B C3 0F 84 ? ? ? ? 8B F0 69 F6 90 04 00 00 66 39 9E')[0],
             E.find('6A 05 B9 ? ? ? ? E8 ? ? ? ? 85 C0 74 ? B9 ? ? ? ? E8 ? ? ? ? B9 ? ? ? ? E8 ? ? ? ? B9')[0],
             E.find('6A 04 6A 04 B9 ? ? ? ? E8 ? ? ? ? 6A 01 B9 ? ? ? ? E8 ? ? ? ? 8B D8 85 DB 0F 84')[0] + 0x0E,
             E.find('6A 01 B9 ? ? ? ? E8 ? ? ? ? 8B F8 85 FF 74 ? 57 E8')[0]]
    get_unit = (sites[0] + 7 + 5 + E.i32(sites[0] + 8)) & 0xFFFFFFFF
    units = E.u32(sites[0] + 3)
    sel = E.u32(sites[1] + 0x44)
    calls = []
    for s in sites:
        for a, sel_n, want in ((0, 3, 77), (1, 3, 0), (1, 0, 77)):
            del calls[:]
            h.stub(get_unit, result=77, ret_bytes=4, record=calls)
            h.put32(alt_flag, a)
            h.put32(sel, sel_n)
            h.run(s, until=s + 12, limit=1000)
            ok(h.cpu.r['eax'] == want and h.cpu.r['esp'] == 0x70100000 - 4,
               '%08X alt %d selected %d -> %d (%d)' % (s, a, sel_n, want, h.cpu.r['eax']))
            ok(bool(calls) == (want == 77) and (not calls or calls[0][1][0] in (1, 5) and calls[0][0] == units),
               '   the game search asked: %s' % bool(calls))


def off(extreme):
    h = Host(extreme=extreme, config={'waypoints': {'always': False}, 'stacking': {'alt': False}})
    ok(not h.patched, ('EXT' if extreme else 'VAN') + ' everything off: no code changed')


for ext in (False, True):
    run_exe(ext)
    alt(ext)
    off(ext)
print('\nFAILED: %d' % len(FAIL))
for f in FAIL:
    print('  ', f)
