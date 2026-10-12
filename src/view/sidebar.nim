## Left side bar: tree menu of views. Enter or a mouse click on a leaf opens
## (or focuses) its tab via `onOpen`; arrow keys only move the selection.

{.push raises: [].}

import illview

type
  Sidebar* = ref object
    tree*: TreeView
    onOpen*: proc(name: string) {.gcsafe, raises: [].}

  SideTree = ref object of TreeView
    ## illview's TreeView only selects on click; activation is Enter-only.
    owner: Sidebar

const
  VChannels* = "Channels"
  VMessaging* = "Messaging"
  VKernel* = "Kernel messaging"
  VPeers* = "Peers"
  VHealth* = "Node health"
  VConfig* = "Current configuration"
  VNodeMgmt* = "Node management"
  VScenario* = "Send scenario"

proc openSelected(s: Sidebar) =
  let n = s.tree.selectedNode
  if n != nil and not n.hasKids and s.onOpen != nil:
    s.onOpen(n.label)

method handleEvent*(t: SideTree, ev: Event): bool {.gcsafe, raises: [].} =
  result = procCall handleEvent(TreeView(t), ev)
  if ev.kind == evMouse and ev.imouse.action == maPress and ev.imouse.button == mbLeft:
    t.owner.openSelected() # no-op on group rows (their ▸/▾ toggles)

proc newSidebar*(): Sidebar =
  let s = Sidebar()
  let admin = treeNode("Admin", @[treeNode(VHealth), treeNode(VConfig), treeNode(VNodeMgmt)])
  let testing = treeNode("Testing", @[treeNode(VScenario)])
  admin.expanded = true
  testing.expanded = true
  let tree = SideTree(owner: s, roots: @[
    admin,
    treeNode(VChannels), treeNode(VMessaging), treeNode(VKernel), treeNode(VPeers),
    testing,
  ])
  initView(tree)
  tree.focusable = true
  s.tree = tree
  s.tree.border = bkSingle
  s.tree.borderTitle = "Menu"
  s.tree.hint = (prefHint(24), prefHint(0, stretch = 1)) # width: the shell's splitter
  s.tree.onActivate = proc(t: TreeView) {.gcsafe, raises: [].} =
    s.openSelected()
  s

{.pop.}
