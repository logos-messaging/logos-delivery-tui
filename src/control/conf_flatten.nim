## Flattens a (nested) config object into `key = stringified value` rows.
## Recurses into object types whose name contains "Conf" (the config
## structs); everything else is rendered with `$`.

{.push raises: [].}

import std/[options, typetraits, strutils]
import results

type FlatKV* = tuple[key, value: string]

const MaxDepth = 6

proc flattenInto*[T](res: var seq[FlatKV], key: string, v: T, depth = 0) =
  when T is distinct:
    flattenInto(res, key, distinctBase(T)(v), depth)
  elif T is Opt:
    if v.isSome:
      flattenInto(res, key, v.get, depth)
    else:
      res.add((key, "none"))
  elif T is Option:
    if v.isSome:
      flattenInto(res, key, v.get, depth)
    else:
      res.add((key, "none"))
  elif T is ref:
    if v.isNil:
      res.add((key, "nil"))
    elif depth < MaxDepth:
      flattenInto(res, key, v[], depth)
    else:
      res.add((key, "…"))
  elif T is object and "Conf" in $T:
    if depth >= MaxDepth:
      res.add((key, "…"))
    else:
      for name, field in fieldPairs(v):
        flattenInto(res, (if key.len > 0: key & "." & name else: name), field, depth + 1)
  elif T is string:
    res.add((key, v))
  elif compiles($v):
    try:
      res.add((key, $v))
    except Exception:
      res.add((key, "<unprintable>"))
  else:
    res.add((key, "<" & $T & ">"))

proc flatten*[T](v: T, prefix = ""): seq[FlatKV] =
  flattenInto(result, prefix, v)

{.pop.}
