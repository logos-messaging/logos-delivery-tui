## Messaging control: send / subscribe / unsubscribe through the messaging API
## layer (`ld.messagingClient`), and a chat stream (`TuiChatLine`) built from
## our sends plus MessageSent/Propagated/Error/Queued/Received events.

{.push raises: [].}

import std/[sets, times, unicode]
import chronos, chronicles, results, stew/byteutils
import logos_delivery
import logos_delivery/messaging/api/[send, subscription]
import ../app/node_host
import ./tui_brokers

logScope:
  topics = "ldtui messaging"

type MessagingCtl = ref object
  ld: LogosDelivery
  ctx: BrokerContext
  outgoing: HashSet[string] ## requestIds we sent, to tag their status events
  sentL: MessageSentEventListener
  propL: MessagePropagatedEventListener
  errL: MessageErrorEventListener
  queuedL: MessageQueuedEventListener
  recvL: MessageReceivedEventListener

var gMsg {.threadvar.}: MessagingCtl

proc nowTs(): string =
  try:
    now().format("HH:mm:ss")
  except CatchableError:
    ""

proc printable*(payload: seq[byte]): string =
  ## Payload as text when it is valid UTF-8 without control characters,
  ## otherwise as hex.
  let s = string.fromBytes(payload)
  if validateUtf8(s) == -1:
    var ok = true
    for c in s:
      if c < ' ' and c notin {'\t'}:
        ok = false
        break
    if ok:
      return s
  "0x" & payload.toHex()

proc status(c: MessagingCtl, requestId: string, st: ChatStatus) =
  if requestId notin c.outgoing:
    return
  TuiChatLine.emit(
    tuiCtx,
    TuiChatLine(key: requestId, dir: ChatDir.Outgoing, status: st, ts: nowTs()),
  )
  if st in {ChatStatus.Propagated, ChatStatus.Error}:
    c.outgoing.excl requestId

proc send(
    c: MessagingCtl, contentTopic: string, payload: seq[byte], ephemeral: bool
): Future[Result[string, string]] {.async: (raises: []).} =
  if c.ld.isNil:
    return err("node is not running")
  ?c.ld.ensureMessaging()
  let env = MessageEnvelope.init(ContentTopic(contentTopic), payload, ephemeral)
  let reqId =
    try:
      ?(await c.ld.messagingClient.send(env))
    except CatchableError as e:
      return err("send failed: " & e.msg)
  let key = $reqId
  c.outgoing.incl key
  TuiChatLine.emit(
    tuiCtx,
    TuiChatLine(
      key: key,
      dir: ChatDir.Outgoing,
      contentTopic: contentTopic,
      text: printable(payload),
      status: ChatStatus.Pending,
      ts: nowTs(),
    ),
  )
  ok(key)

proc attach(c: MessagingCtl, ld: LogosDelivery) =
  c.ld = ld
  c.ctx = ld.waku.brokerCtx
  c.sentL = MessageSentEvent.listen(
    c.ctx,
    proc(e: MessageSentEvent) {.async: (raises: []).} =
      c.status($e.requestId, ChatStatus.Sent),
  ).valueOr(MessageSentEventListener())
  c.propL = MessagePropagatedEvent.listen(
    c.ctx,
    proc(e: MessagePropagatedEvent) {.async: (raises: []).} =
      c.status($e.requestId, ChatStatus.Propagated),
  ).valueOr(MessagePropagatedEventListener())
  c.errL = MessageErrorEvent.listen(
    c.ctx,
    proc(e: MessageErrorEvent) {.async: (raises: []).} =
      warn "message error", requestId = $e.requestId, error = e.error
      c.status($e.requestId, ChatStatus.Error),
  ).valueOr(MessageErrorEventListener())
  c.queuedL = MessageQueuedEvent.listen(
    c.ctx,
    proc(e: MessageQueuedEvent) {.async: (raises: []).} =
      c.status($e.requestId, ChatStatus.Queued),
  ).valueOr(MessageQueuedEventListener())
  c.recvL = MessageReceivedEvent.listen(
    c.ctx,
    proc(e: MessageReceivedEvent) {.async: (raises: []).} =
      TuiChatLine.emit(
        tuiCtx,
        TuiChatLine(
          key: e.messageHash,
          dir: ChatDir.Incoming,
          contentTopic: $e.message.contentTopic,
          text: printable(e.message.payload),
          status:
            if e.source == MessageSource.History: ChatStatus.History
            else: ChatStatus.Live,
          ts: nowTs(),
        ),
      ),
  ).valueOr(MessageReceivedEventListener())

proc detach(c: MessagingCtl) {.async: (raises: []).} =
  if c.ld.isNil:
    return
  await MessageSentEvent.dropListener(c.ctx, c.sentL)
  await MessagePropagatedEvent.dropListener(c.ctx, c.propL)
  await MessageErrorEvent.dropListener(c.ctx, c.errL)
  await MessageQueuedEvent.dropListener(c.ctx, c.queuedL)
  await MessageReceivedEvent.dropListener(c.ctx, c.recvL)
  c.outgoing.clear()
  c.ld = nil

proc init*() =
  let c = MessagingCtl()
  gMsg = c
  host().onAttach(
    proc(ld: LogosDelivery) {.gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        c.attach(ld)
  )
  host().onDetach(
    proc() {.async: (raises: []).} =
      {.cast(gcsafe).}:
        await c.detach()
  )
  discard TuiSend.setProvider(
    tuiCtx,
    proc(
        contentTopic: string, payload: seq[byte], ephemeral: bool
    ): Future[Result[string, string]] {.async.} =
      (await c.send(contentTopic, payload, ephemeral)),
  )
  discard TuiSubscribe.setProvider(
    tuiCtx,
    proc(contentTopic: string): Future[Result[void, string]] {.async.} =
      if c.ld.isNil:
        return err("node is not running")
      ?c.ld.ensureMessaging()
      try:
        ?(await c.ld.messagingClient.subscribe(ContentTopic(contentTopic)))
      except CatchableError as e:
        return err("subscribe failed: " & e.msg)
      info "subscribed", contentTopic
      ok(),
  )
  discard TuiUnsubscribe.setProvider(
    tuiCtx,
    proc(contentTopic: string): Future[Result[void, string]] {.async.} =
      if c.ld.isNil:
        return err("node is not running")
      ?c.ld.ensureMessaging()
      ?c.ld.messagingClient.unsubscribe(ContentTopic(contentTopic))
      info "unsubscribed", contentTopic
      ok(),
  )

{.pop.}
