## VM session: persistent Interpreter with growing script buffer.
##
## State is accumulated by replaying an ever-growing script on each eval.
## Imported modules are cached in the module graph, so only the incremental
## AST-walk cost is paid after the first import.
##
## Buffer structure:
##   [imports]  <- from :precompile chunk, never cleared
##   [procs]    <- from most recent :procs chunk, replaced on reload
##   [history]  <- eval blocks appended sequentially

import compiler/[nimeval, llstream]
import std/[os, posix, strutils]

type
  Session* = ref object
    intr*: Interpreter
    searchPaths: seq[string]
    imports: string   ## precompile chunk content
    procs: string     ## most recent procs chunk content
    history: string   ## accumulated eval blocks
    outputBaseline: int  ## byte length of output produced by history so far

var gSession*: Session

proc nimStdlibPath*(): string =
  ## Runtime stdlib path from `nim dump`.
  ## Falls back to compile-time querySetting if dump fails.
  result = findNimStdLibCompileTime()

proc newSession*(extraPaths: seq[string] = @[]): Session =
  result = Session()
  let stdlib = nimStdlibPath()
  result.searchPaths = @[stdlib, stdlib / "pure", stdlib / "core"] & extraPaths
  result.intr = createInterpreter("session.nims", result.searchPaths)

proc initGlobalSession*(extraPaths: seq[string] = @[]) =
  gSession = newSession(extraPaths)

proc fullScript(s: Session): string =
  result = s.imports
  if s.procs != "": result &= "\n" & s.procs
  if s.history != "": result &= "\n" & s.history

proc evalRaw(s: Session, script: string): tuple[stdout: string, err: string] =
  ## Eval script with stdout captured via dup2. Returns captured output and
  ## any error message.
  var pipefd: array[2, cint]
  if pipe(pipefd) != 0:
    return ("", "pipe() failed")

  let savedOut = dup(STDOUT_FILENO)
  discard dup2(pipefd[1], STDOUT_FILENO)
  discard close(pipefd[1])

  var evalErr = ""
  try:
    s.intr.evalScript(llStreamOpen(script))
  except:
    evalErr = getCurrentExceptionMsg()

  stdout.flushFile()
  discard dup2(savedOut, STDOUT_FILENO)
  discard close(savedOut)

  var buf = newString(65536)
  let n = read(pipefd[0], addr buf[0], 65536)
  discard close(pipefd[0])

  let captured = if n > 0: buf[0..<n] else: ""
  result = (captured.strip(leading = false), evalErr)

proc setImports*(s: Session; code: string): tuple[stdout: string, err: string] =
  ## Called by :precompile chunk. Warms up the module graph.
  ## Resets everything — imports are the new foundation.
  s.imports = code
  s.procs = ""
  s.history = ""
  s.outputBaseline = 0
  result = s.evalRaw(s.imports)

proc setProcs*(s: Session; code: string): tuple[stdout: string, err: string] =
  ## Called by :procs chunk. Replaces procs, clears history.
  ## Module graph stays warm; outputBaseline resets to 0 for the clean state.
  s.procs = code
  s.history = ""
  s.outputBaseline = 0
  let script = s.imports & "\n" & s.procs
  result = s.evalRaw(script)

proc evalBlock*(s: Session; code: string): tuple[stdout: string, err: string] =
  ## Append to history, replay full script, return only the new output delta.
  ## outputBaseline tracks how many bytes the previous replay produced so we
  ## can strip the replayed output and return only what the new code emitted.
  s.history &= "\n" & code
  let (full, err) = s.evalRaw(s.fullScript())
  let newOut = if full.len > s.outputBaseline: full[s.outputBaseline..^1].strip()
               else: ""
  s.outputBaseline = full.len
  result = (newOut, err)

proc resetSession*(s: Session) =
  ## Restart the interpreter entirely (clears module graph too).
  s.intr = createInterpreter("session.nims", s.searchPaths)
  s.imports = ""
  s.procs = ""
  s.history = ""
  s.outputBaseline = 0
