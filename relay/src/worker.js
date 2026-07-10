export class RelayHub {
  constructor(ctx) {
    this.ctx = ctx
  }

  async fetch(request) {
    const url = new URL(request.url)
    if (url.pathname === '/connect') {
      const role = url.searchParams.get('role')
      const pair = new WebSocketPair()
      this.ctx.acceptWebSocket(pair[1], [role])
      return new Response(null, { status: 101, webSocket: pair[0] })
    }
    return new Response('not found', { status: 404 })
  }

  webSocketMessage(socket, message) {
    if (message === 'ping') {
      socket.send('pong')
      return
    }
    const senderRole = this.ctx.getTags(socket)[0]
    for (const otherSocket of this.ctx.getWebSockets()) {
      if (otherSocket === socket) continue
      if (this.ctx.getTags(otherSocket)[0] === senderRole) continue
      try { otherSocket.send(message) } catch {}
    }
  }
}

export default {
  async fetch(request, env) {
    if (request.headers.get('upgrade') !== 'websocket') {
      return new Response('expected websocket', { status: 426 })
    }
    const url = new URL(request.url)
    if (url.searchParams.get('token') !== env.RELAY_TOKEN) {
      return new Response('unauthorized', { status: 401 })
    }
    const role = url.searchParams.get('role')
    if (role !== 'phone' && role !== 'mac') {
      return new Response('bad role', { status: 400 })
    }
    const room = url.searchParams.get('room') || 'default'
    const hub = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(room))
    return hub.fetch(new Request(`https://hub/connect?role=${role}`, request))
  },
}
