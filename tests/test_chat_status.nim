import unittest2
import ../src/control/tui_brokers
import ../src/view/v_messaging

suite "message error in the detail pane":
  test "a failed message shows what the node said":
    check:
      errorText(ChatStatus.Error, "no peers to publish to") == "no peers to publish to"
      errorText(ChatStatus.Error, "line one\nline two") == "line one⏎line two"
      errorText(ChatStatus.Error, "") == "(no reason given)"

  test "no error row for other statuses":
    check:
      errorText(ChatStatus.Sent, "") == ""
      errorText(ChatStatus.Queued, "ignored") == ""
