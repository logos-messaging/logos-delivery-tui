## The TUI's theme: illview's default (gray windows) with the content
## surfaces on dark blue for contrast: lists, tables, trees, text views (log
## pane, chat, progress) and the input / editor fields.

{.push raises: [].}

import illview

proc ldtuiTheme*(): Theme =
  result = defaultTheme()
  let ink = style(fgWhite, bgBlue, bright = true)
  result.styles[tkList] = ink # ListView / Table / TreeView / TextView rows
  result.styles[tkInput] = ink # Input / Editor
  result.styles[tkInputFocused] = ink
  result.styles[tkSelection] = style(fgYellow, bgBlue, bright = true)
    # selected row while the widget is not focused (focused: white on green)
  result.styles[tkCursor] = style(fgBlack, bgYellow) # text cursor: stands out on blue
  result.styles[tkTableHeader] = style(fgBlack, bgCyan) # distinct from the rows
  result.styles[tkScrollBar] = style(fgCyan, bgBlue)
  result.styles[tkProgress] = style(fgCyan, bgBlue)
  result.styles[tkWindowTitle] = style(fgWhite, bgBlue, bright = true)
    # window titles and the selected tab: bright white on the default gray is
    # unreadable on some terminals (Terminal.app)

{.pop.}
