## Placeholder page for views that are not specified yet.

{.push raises: [].}

import illview
import ./common

proc newPlaceholderView*(title: string): Window =
  let w = pageWindow(title)
  let l = newLabel(title & ": to be specified.")
  l.dock = dkFill
  l.padding = 1
  w.add l
  w

{.pop.}
