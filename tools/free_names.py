"""Names a Lua file uses that nothing defines: a local it forgot, a variable a moved function no longer sees. Lua compiles those happily
and the name is nil at run time (the panel split, 0.58.48: moved code reads the panel's own variables). A scope-following reader, not a
full parser: good enough for this repo's style. Run before a release: python tools/free_names.py [files...] (no files: every script and lib
module). Exits non-zero when a file uses an unknown name."""
import glob, os, re, sys

KNOWN = set("""reaper gfx string table math os io debug utf8 coroutine package require pairs ipairs type tostring tonumber select pcall
xpcall error assert setmetatable getmetatable rawget rawset rawequal rawlen next print load loadfile dofile collectgarbage _G _ENV _VERSION
unpack arg self _""".split())
KEYWORDS = set("""and break do else elseif end false for function goto if in local nil not or repeat return then true until while""".split())
TOKEN = re.compile(r"""
  (?P<comment>--\[(?P<ceq>=*)\[.*?\](?P=ceq)\]|--[^\n]*)
 |(?P<long>\[(?P<leq>=*)\[.*?\](?P=leq)\])
 |(?P<str>"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*')
 |(?P<num>0[xX][0-9a-fA-F.pP+-]+|\d+\.?\d*(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?)
 |(?P<name>[A-Za-z_]\w*)
 |(?P<op>\.\.\.|\.\.|==|~=|<=|>=|//|::|<<|>>|[-+*/%^#&~|<>=(){}\[\];:,.])
 |(?P<ws>\s+)
""", re.S | re.X)

def tokens(src):
    pos, out, line = 0, [], 1
    while pos < len(src):
        m = TOKEN.match(src, pos)
        if not m:
            pos += 1; continue
        kind = m.lastgroup if m.lastgroup not in ("ceq", "leq") else ("comment" if m.group("comment") else "long")
        text = m.group(0)
        if kind == "name" and text in KEYWORDS: kind = "kw"
        if kind not in ("ws", "comment"): out.append((kind, text, line))
        line += text.count("\n")
        pos = m.end()
    return out

def free_names(src):
    toks = tokens(src)
    scopes = [set()]
    pending = []  # names a `for` declares, for the block its `do` opens
    found = {}
    braces = []  # inside a table constructor: a `name =` there is a key
    i = 0
    until_scope, until_line = set(), -1
    def declared(n): return any(n in s for s in scopes) or (n in until_scope and toks[i][2] == until_line)
    while i < len(toks):
        kind, text, line = toks[i]
        prev = toks[i - 1][1] if i else ""
        nxt = toks[i + 1][1] if i + 1 < len(toks) else ""
        if kind == "kw":
            if text == "local":
                if nxt == "function":
                    scopes[-1].add(toks[i + 2][1]); i += 1; continue  # (its own name is seen inside it; the function itself is read next)
                j = i + 1
                names = []
                while j < len(toks) and toks[j][0] == "name":
                    names.append(toks[j][1]); j += 1
                    if j < len(toks) and toks[j][1] == "<": j += 3  # <const> / <close>
                    if j < len(toks) and toks[j][1] == ",": j += 1
                    else: break
                # declared after the statement's expressions: `local x = x` reads the outer x. Approximated: from the next line on.
                scopes[-1].update(names)
                i = j; continue
            if text == "function":
                j = i + 1
                if j < len(toks) and toks[j][0] == "name":  # function a.b:c(...): `a` is read; c with ":" gives self
                    if not declared(toks[j][1]): found.setdefault(toks[j][1], toks[j][2])
                    method = False
                    while j + 1 < len(toks) and toks[j + 1][1] in (".", ":"):
                        method = method or toks[j + 1][1] == ":"
                        j += 2
                    j += 1
                else:
                    method = False
                params = {"self"} if method else set()
                if j < len(toks) and toks[j][1] == "(":
                    j += 1
                    while j < len(toks) and toks[j][1] != ")":
                        if toks[j][0] == "name": params.add(toks[j][1])
                        j += 1
                scopes.append(params)
                i = j + 1; continue
            if text == "for":
                j = i + 1
                while j < len(toks) and toks[j][1] not in ("=", "in"):
                    if toks[j][0] == "name": pending.append(toks[j][1])
                    j += 1
                i = j; continue
            if text in ("do", "then", "repeat"):
                scopes.append(set(pending)); pending = []
            elif text in ("elseif", "else"):
                scopes.pop()
                if text == "else": scopes.append(set())
            elif text == "end":
                if len(scopes) > 1: scopes.pop()
            elif text == "until":  # (its condition still sees the loop body's locals: kept for the rest of that line)
                if len(scopes) > 1: until_scope, until_line = scopes.pop(), line
            elif text == "goto":
                i += 2; continue
            i += 1; continue
        if text == "::":
            i += 3; continue
        if text == "{": braces.append(True)
        elif text == "}" and braces: braces.pop()
        if kind == "name":
            is_field = prev in (".", ":") and not (i >= 2 and toks[i - 2][1] == "..")
            is_key = braces and prev in ("{", ",", ";") and nxt == "=" and (i + 2 >= len(toks) or toks[i + 2][1] != "=")
            if not is_field and not is_key and not declared(text):
                found.setdefault(text, line)
        i += 1
    return found

def repo_globals(files):
    """Names this repo sets as globals on purpose (NAME = ... at the start of a line, upper case or BANDSYNC_)."""
    g = set()
    for f in files:
        for m in re.finditer(r"^\s*([A-Z][A-Z0-9_]{2,})\s*=[^=]", open(f, encoding="utf-8").read(), re.M): g.add(m.group(1))
    return g

if __name__ == "__main__":
    os.chdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    every = sorted(glob.glob("*.lua") + glob.glob("lib/*.lua"))
    files = sys.argv[1:] or every
    allowed = KNOWN | repo_globals(every)
    bad = 0
    for f in files:
        names = {n: l for n, l in free_names(open(f, encoding="utf-8").read()).items() if n not in allowed and not n.startswith("BANDSYNC_")}  # (the scripts' own hand-offs)
        for n, l in sorted(names.items(), key=lambda x: x[1]):
            print(f"{f}:{l}: {n} is used but never defined here")
            bad += 1
    print(f"{bad} unknown name(s)" if bad else "no unknown names")
    sys.exit(1 if bad else 0)
