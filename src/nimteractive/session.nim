## VM session: persistent Interpreter with growing script buffer.
##
## Error handling: msgs.nim calls quit(1) via two paths:
##   1. fatalMsgs                      → line 432-433
##   2. eh == doAbort AND cmd != cmdIdeTools → line 446-447
## Both are bypassed when conf.cmd == cmdIdeTools (msgs.nim:432,446).
## Setting conf.cmd = cmdIdeTools inside the error hook prevents both.
## conf.errorMax = high(int) is belt-and-suspenders for the errorMax path.
## After the hook fires, evalScript returns normally; we recreate the
## interpreter to clear its partial state before the next eval.

import compiler/[nimeval, llstream, lineinfos, options]
import std/[os, posix, strutils]

type
  Session* = ref object
    intr*: Interpreter
    searchPaths: seq[string]
    imports: string
    procs: string
    history: string
    outputBaseline: int

var gSession*: Session
var gEvalError {.threadvar.}: string

proc nimStdlibPath*(): string =
  result = findNimStdLibCompileTime()

proc makeInterpreter(searchPaths: seq[string]): Interpreter =
  result = createInterpreter("session.nims", searchPaths)
  result.registerErrorHook(
    proc(config: ConfigRef; info: TLineInfo; msg: string; sev: Severity) {.gcsafe.} =
      # config.m.errorOutputs == {} when inside a compiles() context
      # (semexprs.nim sets it to {} to silence probe errors).
      # Ignore those — they are expected "does this compile?" failures.
      if sev == Severity.Error and gEvalError == "" and
          config.m.errorOutputs != {}:
        config.cmd = cmdIdeTools   # msgs.nim:446 — skips doAbort quit
        config.errorMax = high(int) # msgs.nim:445 — skips errorMax quit
        gEvalError = msg
        # msgs.nim:632 — internalErrorImpl returns early when
        # cmd==cmdIdeTools AND structuredErrorHook==nil,
        # preventing errInternal from calling quit even for fatal msgs.
        config.structuredErrorHook = nil)

proc newSession*(extraPaths: seq[string] = @[]): Session =
  result = Session()
  let stdlib = nimStdlibPath()
  result.searchPaths = @[stdlib, stdlib / "pure", stdlib / "core"] & extraPaths
  result.intr = makeInterpreter(result.searchPaths)

proc initGlobalSession*(extraPaths: seq[string] = @[]) =
  gSession = newSession(extraPaths)

proc fullScript(s: Session): string =
  result = s.imports
  if s.procs != "": result &= "\n" & s.procs
  if s.history != "": result &= "\n" & s.history

proc evalRaw(s: Session, script: string): tuple[stdout: string, err: string] =
  var pipefd: array[2, cint]
  if pipe(pipefd) != 0:
    return ("", "pipe() failed")

  let savedOut = dup(STDOUT_FILENO)
  discard dup2(pipefd[1], STDOUT_FILENO)
  discard close(pipefd[1])

  gEvalError = ""
  try:
    s.intr.evalScript(llStreamOpen(script))
  except:
    if gEvalError == "":
      gEvalError = getCurrentExceptionMsg()

  stdout.flushFile()
  discard dup2(savedOut, STDOUT_FILENO)
  discard close(savedOut)

  var buf = newString(65536)
  let n = read(pipefd[0], addr buf[0], 65536)
  discard close(pipefd[0])

  let captured = if n > 0: buf[0..<n] else: ""
  if gEvalError != "":
    # Interpreter is in a partial/tainted state after an error; rebuild it.
    s.intr = makeInterpreter(s.searchPaths)
  result = (captured.strip(leading = false), gEvalError)

proc setImports*(s: Session; code: string): tuple[stdout: string, err: string] =
  s.imports = code
  s.procs = ""
  s.history = ""
  s.outputBaseline = 0
  result = s.evalRaw(s.imports)

proc setProcs*(s: Session; code: string): tuple[stdout: string, err: string] =
  s.procs = code
  s.history = ""
  s.outputBaseline = 0
  result = s.evalRaw(s.imports & "\n" & s.procs)

proc deltaOut(s: Session; full: string): string =
  if full.len > s.outputBaseline: full[s.outputBaseline..^1].strip()
  else: ""

proc evalBlock*(s: Session; code: string): tuple[stdout: string, err: string] =
  ## Append to history, replay full script, return only the new output delta.
  ## If the expression "has to be used", retry with `echo` (prints the value),
  ## then fall back to `discard` for types with no $ operator.
  let trimmed = code.strip()

  # Attempt 1: as-is
  block:
    let (full, err) = s.evalRaw(s.fullScript() & "\n" & trimmed)
    if err == "":
      s.history &= "\n" & trimmed
      let newOut = s.deltaOut(full)
      s.outputBaseline = full.len
      return (newOut, "")
    elif "has to be used" notin err:
      return ("", err)  # real error, don't touch history

  # Attempt 2: wrap in echo — shows the value like a proper REPL
  block:
    let echoCode = "echo " & trimmed
    let (full, err) = s.evalRaw(s.fullScript() & "\n" & echoCode)
    if err == "":
      s.history &= "\n" & echoCode
      let newOut = s.deltaOut(full)
      s.outputBaseline = full.len
      return (newOut, "")

  # Attempt 3: discard — for types with no $ operator
  block:
    let discardCode = "discard " & trimmed
    let (full, err) = s.evalRaw(s.fullScript() & "\n" & discardCode)
    if err == "":
      s.history &= "\n" & discardCode
      let newOut = s.deltaOut(full)
      s.outputBaseline = full.len
      return (newOut, "")

  # All attempts failed — return error without touching history
  result = ("", "error: " & trimmed)

proc resetSession*(s: Session) =
  s.intr = makeInterpreter(s.searchPaths)
  s.imports = ""
  s.procs = ""
  s.history = ""
  s.outputBaseline = 0
