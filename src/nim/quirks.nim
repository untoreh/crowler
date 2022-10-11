## NOTE: This allows to call pyobjects as functions, but can mess templating up for other things
import nimpy {.all.}
import macros

macro fnCall(o: untyped, args: varargs[untyped]): untyped =
  let plainArgs = newTree(nnkBracket)
  let kwArgs = newTree(nnkBracket)

  for arg in args:
    # Skip the bogus [] `args` when no argument is passed
    if arg.kind == nnkHiddenStdConv and arg[0].kind == nnkEmpty:
      continue
    elif arg.kind != nnkExprEqExpr:
      plainArgs.add(newCall("toPyObjectArgument", arg))
    else:
      expectKind(arg[0], nnkIdent)
      kwArgs.add(newTree(nnkPar,
        newCall("cstring", newLit($arg[0])),
        newCall("toPyObjectArgument", arg[1])))

  result = newCall(bindSym"newPyObjectConsumingRef",
    newCall(bindSym"callObjectAux", newcall("privateRawPyObj", o), plainArgs, kwArgs))

template `()`*(o: PyObject, args: varargs[untyped]): PyObject =
  fnCall(o, args)
