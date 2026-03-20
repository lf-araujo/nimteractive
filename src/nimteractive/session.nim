## VM session: holds the interpreter, evaluates code blocks.

import std/[os, strutils]
import compiler/[nimeval, llstream, idents, options, condsyms]

type
  Session* = object
    intr*: Interpreter
    stdlibPath*: string

var gSession*: Session

proc findStdlib(): string =
  ## Locate the Nim stdlib at compile time.
  result = findNimStdLibCompileTime()

proc initSession*(extraPaths: seq[string] = @[]) =
  let stdlib = findStdlib()
  var paths = @[stdlib] & extraPaths
  gSession.stdlibPath = stdlib
  gSession.intr = createInterpreter("session.nims", paths)

proc evalBlock*(code: string): tuple[value: string, stdout: string, err: string] =
  ## Evaluate a code block in the persistent VM.
  ## stdout capture is best-effort via a wrapper; full dup2 capture is TODO.
  try:
    gSession.intr.evalScript(llStreamOpen(code))
    result = (value: "", stdout: "", err: "")
  except:
    result = (value: "", stdout: "", err: getCurrentExceptionMsg())

proc destroySession*() =
  if gSession.intr != nil:
    destroyInterpreter(gSession.intr)
