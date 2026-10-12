## Recognises our own messages coming back on a subscribed content topic, so
## the chat shows each sent message once (its outgoing row).
##
## The relay delivers a node's own message to its subscription, and it can do
## so before the send service reports the message hash (MessagePropagated),
## so a received message is matched by hash when that is already known, else
## by content topic + payload against our sends not matched yet.

{.push raises: [].}

type
  OwnSend = object
    requestId: string
    contentTopic: string
    payload: seq[byte]
    hash: string ## "" until an event or an echo tells it
    echoed: bool

  EchoFilter* = object
    sends: seq[OwnSend] ## newest last, at most `MaxTracked`

const MaxTracked = 256

proc sent*(f: var EchoFilter, requestId, contentTopic: string, payload: seq[byte]) =
  f.sends.add OwnSend(requestId: requestId, contentTopic: contentTopic, payload: payload)
  if f.sends.len > MaxTracked:
    f.sends.delete(0)

proc hashKnown*(f: var EchoFilter, requestId, hash: string) =
  ## A send-service event names the message hash of our request.
  for s in f.sends.mitems:
    if s.requestId == requestId and s.hash.len == 0:
      s.hash = hash

proc isEcho*(f: var EchoFilter, hash, contentTopic: string, payload: seq[byte]): bool =
  ## True when this received message is one we sent (once per send).
  for s in f.sends.mitems:
    if s.hash.len > 0 and s.hash == hash:
      if s.echoed:
        return true # same message delivered again (e.g. live, then history)
      s.echoed = true
      return true
  for s in f.sends.mitems:
    if not s.echoed and s.hash.len == 0 and s.contentTopic == contentTopic and
        s.payload == payload:
      s.hash = hash
      s.echoed = true
      return true
  false

proc clear*(f: var EchoFilter) =
  f.sends.setLen(0)

{.pop.}
