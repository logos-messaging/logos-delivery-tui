import unittest2
import illview/core/geometry
import illview/widgets/treeview
import ../src/control/tui_brokers
import ../src/view/peer_trees

const
  A = "16Uiu2HAmAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA1"
  B = "16Uiu2HAmBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB2"

proc rows(): seq[PeerRow] =
  @[
    PeerRow(protocol: "relay", peerId: B, addresses: "/ip4/2.2.2.2/tcp/1"),
    PeerRow(protocol: "relay", peerId: A, addresses: "/ip4/1.1.1.1/tcp/1,/ip4/1.1.1.1/udp/1/quic-v1"),
    PeerRow(protocol: "store", peerId: A, addresses: "/ip4/1.1.1.1/tcp/1,/ip4/1.1.1.1/udp/1/quic-v1"),
  ]

suite "peer trees":
  test "by protocol: protocol > short peer id > addresses, keys are full ids":
    let t = byProtocol(rows())
    check t.len == 2
    check t[0].label == "relay (2)"
    check t[0].key == "relay"
    check t[0].expanded
    check t[0].children.len == 2
    let a = t[0].children[1]
    check a.key == A
    check a.label == "16Uiu2…AAAAA1 (2 addrs)"
    check a.children.len == 2
    check a.children[1].label == "/ip4/1.1.1.1/udp/1/quic-v1"
    check t[1].label == "store (1)"
    check t[1].children[0].label == "16Uiu2…AAAAA1 (2 addrs)"

  test "by peer: sorted peers with protocols and addresses branches":
    let t = byPeer(rows())
    check t.len == 2
    check t[0].key == A
    check t[0].label == "16Uiu2…AAAAA1  relay, store"
    check t[0].children[0].label == "protocols (2)"
    check t[0].children[0].key == "protocols"
    check t[0].children[1].label == "addresses (2)"
    check t[1].label == "16Uiu2…BBBBB2  relay"
    check t[1].children[1].children[0].label == "/ip4/2.2.2.2/tcp/1"

  test "selected peer resolves from the peer row or any row under it":
    let tv = newTreeView(byPeer(rows()))
    tv.bounds = rect(0, 0, 40, 20)
    check tv.selectedPeerId(peerDepth = 0) == A # row 0 is peer A
    tv.roots[0].expanded = true
    tv.roots[0].children[1].expanded = true     # A > addresses
    tv.selected = 3                              # A > addresses > first addr
    check tv.selectedNode.label == "/ip4/1.1.1.1/tcp/1"
    check tv.selectedPeerId(peerDepth = 0) == A
    let bp = newTreeView(byProtocol(rows()))
    bp.bounds = rect(0, 0, 40, 20)
    check bp.selectedPeerId(peerDepth = 1) == "" # a protocol row: no peer
    bp.selected = 1                               # relay > B
    check bp.selectedPeerId(peerDepth = 1) == B

  test "duplicate addresses from the peer store are listed once":
    let t = byProtocol(@[PeerRow(protocol: "relay", peerId: A,
      addresses: "/ip4/1.1.1.1/udp/1/quic-v1,/ip4/1.1.1.1/tcp/1,/ip4/1.1.1.1/udp/1/quic-v1")])
    check t[0].children[0].label == "16Uiu2…AAAAA1 (2 addrs)"
    check t[0].children[0].children.len == 2

  test "refresh keeps the user's expansion and selection":
    let tv = newTreeView(byPeer(rows()))
    tv.bounds = rect(0, 0, 40, 20)
    tv.roots[1].expanded = true # peer B open
    tv.selected = 1             # peer B
    var more = rows()
    more.add PeerRow(protocol: "filter", peerId: B, addresses: "/ip4/2.2.2.2/tcp/1")
    tv.setRoots(byPeer(more))
    check tv.roots[1].expanded
    check tv.selectedNode.key == B
    check tv.selectedNode.label == "16Uiu2…BBBBB2  relay, filter"
