## Flattens a (nested) config object into `key = stringified value` rows.
## Recurses into object types whose name ends in "Conf" (the config structs;
## library `…Config` objects are rendered whole); everything else with `$`.

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
      when ($T).endsWith("Conf"): # `ref object` configs: v[] is "T:ObjectType"
        for name, field in fieldPairs(v[]):
          flattenInto(res, (if key.len > 0: key & "." & name else: name), field, depth + 1)
      else:
        flattenInto(res, key, v[], depth)
    else:
      res.add((key, "…"))
  elif T is object and ($T).endsWith("Conf"):
    if depth >= MaxDepth:
      res.add((key, "…"))
    else:
      for name, field in fieldPairs(v):
        flattenInto(res, (if key.len > 0: key & "." & name else: name), field, depth + 1)
  elif T is string:
    res.add((key, v))
  elif T is seq:
    # item by item: system's `$`(seq) can't see the items' `$` overloads
    var items: seq[string]
    for item in v:
      when typeof(item) is string:
        items.add item.escape
      else:
        var one: seq[FlatKV]
        flattenInto(one, "", item, MaxDepth)
        items.add (if one.len == 1: one[0].value else: "…")
    res.add((key, "@[" & items.join(", ") & "]"))
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
