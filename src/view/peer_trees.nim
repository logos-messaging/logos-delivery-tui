## Peer trees for the node health page, built from the controller's flat
## (protocol, peerId, addresses) rows. Node keys carry full ids so
## `TreeView.setRoots` keeps expansion / selection across refreshes while
## labels show short peer ids and live counts.
##
##   by protocol:  ▾ relay (12)                 key = protocol
##                   ▸ 16Uiu2…x9QaB1 (2 addrs)  key = full peer id
##                       /ip4/…/tcp/30303       key = address
##   by peer:      ▸ 16Uiu2…x9QaB1  relay, store
##                   ▸ protocols (2)            key = "protocols"
##                   ▸ addresses (2)            key = "addresses"

{.push raises: [].}

import std/[algorithm, strutils, tables]
import illview/widgets/treeview
import ../control/tui_brokers
import ./common

proc addrList(p: PeerRow): seq[string] =
  ## The peer store can list the same multiaddr more than once.
  for a in p.addresses.split(','):
    if a.len > 0 and a notin result:
      result.add a

proc addrNodes(addrs: seq[string]): seq[TreeNode] =
  for a in addrs:
    result.add treeNode(a, key = a)

proc plural(n: int, word: string): string =
  $n & " " & word & (if n == 1: "" else: "s")

proc byProtocol*(rows: seq[PeerRow]): seq[TreeNode] =
  var order: seq[string]
  var peers: tables.Table[string, seq[PeerRow]]
  for r in rows:
    if r.protocol notin peers:
      order.add r.protocol
    peers.mgetOrPut(r.protocol, @[]).add r
  order.sort()
  for proto in order:
    var kids: seq[TreeNode]
    for p in peers.getOrDefault(proto):
      let addrs = p.addrList
      kids.add treeNode(
        short(p.peerId) & " (" & plural(addrs.len, "addr") & ")", addrNodes(addrs),
        key = p.peerId,
      )
    let n = treeNode(proto & " (" & $kids.len & ")", kids, key = proto)
    n.expanded = true # new protocols start open; the user's choice wins later
    result.add n

proc byPeer*(rows: seq[PeerRow]): seq[TreeNode] =
  var order: seq[string]
  var protos: tables.Table[string, seq[string]]
  var addrs: tables.Table[string, seq[string]]
  for r in rows:
    if r.peerId notin protos:
      order.add r.peerId
      addrs[r.peerId] = r.addrList
    protos.mgetOrPut(r.peerId, @[]).add r.protocol
  order.sort()
  for id in order:
    let ps = protos.getOrDefault(id)
    let ad = addrs.getOrDefault(id)
    var protoKids: seq[TreeNode]
    for p in ps:
      protoKids.add treeNode(p, key = p)
    result.add treeNode(
      short(id) & "  " & ps.join(", "),
      @[
        treeNode("protocols (" & $ps.len & ")", protoKids, key = "protocols"),
        treeNode("addresses (" & $ad.len & ")", addrNodes(ad), key = "addresses"),
      ],
      key = id,
    )

proc selectedPeerId*(t: TreeView, peerDepth: int): string =
  ## Full peer id of the selected row's ancestor at `peerDepth` (the row
  ## itself when it is the peer). "" when the selection is above that level.
  let v = t.visibleRows
  if t.selected < 0 or t.selected >= v.len:
    return ""
  var i = t.selected
  if v[i].depth < peerDepth:
    return ""
  while i >= 0 and v[i].depth > peerDepth:
    dec i
  if i < 0: "" else: v[i].node.key

{.pop.}
