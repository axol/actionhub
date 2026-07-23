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
      const receiverRole = this.ctx.getTags(otherSocket)[0]
      if (receiverRole === senderRole) continue
      if (senderRole === 'viewer' && receiverRole !== 'mac') continue
      try { otherSocket.send(message) } catch {}
    }
  }
}

const POLL_TIMEOUT_MILLISECONDS = 50000

export class MessageStore {
  constructor(ctx) {
    this.ctx = ctx
    this.pollWaiters = new Map()
  }

  async fetch(request) {
    const url = new URL(request.url)
    const segments = url.pathname.split('/').filter(Boolean)
    if (segments[0] !== 'messages') return json({ error: 'not found' }, 404)

    if (segments.length === 1 && request.method === 'POST') return this.createMessage(request)
    if (segments.length === 1 && request.method === 'GET') return this.listMessages(url)
    if (segments.length === 2 && request.method === 'GET') return this.showMessage(segments[1])
    if (segments.length === 2 && request.method === 'PATCH') return this.respondToMessage(segments[1], request)
    if (segments.length === 2 && request.method === 'DELETE') return this.deleteMessage(segments[1], request)
    if (segments.length === 3 && segments[2] === 'poll' && request.method === 'GET') return this.pollMessage(segments[1])
    return json({ error: 'not found' }, 404)
  }

  async createMessage(request) {
    const body = await readJson(request)
    if (!body) return json({ error: 'invalid json' }, 400)
    const { id, channel, request_blob, deletion_key } = body
    if (!isHexId(id) || !isHexId(channel) || typeof request_blob !== 'string' || typeof deletion_key !== 'string') {
      return json({ error: 'id, channel, request_blob, deletion_key required' }, 400)
    }
    if (await this.ctx.storage.get(messageKey(id))) return json({ error: 'exists' }, 409)
    const record = { id, channel, request_blob, deletion_key, response_blob: null, created_at: Date.now() }
    await this.ctx.storage.put(messageKey(id), record)
    await this.ctx.storage.put(channelKey(channel, record.created_at, id), id)
    return json({ id }, 201)
  }

  async listMessages(url) {
    const channel = url.searchParams.get('channel')
    if (!isHexId(channel)) return json({ error: 'channel required' }, 400)
    const index = await this.ctx.storage.list({ prefix: `c:${channel}:` })
    const records = []
    for (const id of index.values()) {
      const record = await this.ctx.storage.get(messageKey(id))
      if (record) records.push(publicFields(record))
    }
    return json(records)
  }

  async showMessage(id) {
    const record = await this.ctx.storage.get(messageKey(id))
    if (!record) return json({ error: 'not found' }, 404)
    return json(publicFields(record))
  }

  async respondToMessage(id, request) {
    const body = await readJson(request)
    if (!body || typeof body.response_blob !== 'string' || !body.response_blob) {
      return json({ error: 'response_blob required' }, 400)
    }
    const record = await this.ctx.storage.get(messageKey(id))
    if (!record) return json({ error: 'not found' }, 404)
    if (record.response_blob) return json({ error: 'already responded' }, 409)
    record.response_blob = body.response_blob
    await this.ctx.storage.put(messageKey(id), record)
    for (const resolve of this.pollWaiters.get(id) || []) resolve(body.response_blob)
    this.pollWaiters.delete(id)
    return json({ id, ok: true })
  }

  async pollMessage(id) {
    const record = await this.ctx.storage.get(messageKey(id))
    if (!record) return json({ error: 'not found' }, 404)
    if (record.response_blob) return json({ response_blob: record.response_blob })
    const responseBlob = await new Promise((resolve) => {
      const waiters = this.pollWaiters.get(id) || []
      waiters.push(resolve)
      this.pollWaiters.set(id, waiters)
      setTimeout(() => resolve(null), POLL_TIMEOUT_MILLISECONDS)
    })
    if (responseBlob) return json({ response_blob: responseBlob })
    return new Response(null, { status: 204 })
  }

  async deleteMessage(id, request) {
    const body = await readJson(request)
    if (!body || typeof body.deletion_key !== 'string') return json({ error: 'deletion_key required' }, 400)
    const record = await this.ctx.storage.get(messageKey(id))
    if (!record) return json({ error: 'not found' }, 404)
    if (record.deletion_key !== body.deletion_key) return json({ error: 'forbidden' }, 403)
    await this.ctx.storage.delete(messageKey(id))
    await this.ctx.storage.delete(channelKey(record.channel, record.created_at, id))
    return json({ id, deleted: true })
  }
}

function messageKey(id) {
  return `m:${id}`
}

function channelKey(channel, createdAt, id) {
  return `c:${channel}:${String(createdAt).padStart(14, '0')}:${id}`
}

function publicFields(record) {
  return { id: record.id, request_blob: record.request_blob, response_blob: record.response_blob, created_at: record.created_at }
}

function isHexId(value) {
  return typeof value === 'string' && /^[0-9a-f]{16,64}$/.test(value)
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
}

async function readJson(request) {
  try {
    return await request.json()
  } catch {
    return null
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url)
    if (url.pathname === '/messages' || url.pathname.startsWith('/messages/')) {
      const store = env.MESSAGE_STORE.get(env.MESSAGE_STORE.idFromName('messages'))
      return store.fetch(request)
    }
    if (request.headers.get('upgrade') !== 'websocket') {
      return new Response('expected websocket', { status: 426 })
    }
    if (url.searchParams.get('token') !== env.RELAY_TOKEN) {
      return new Response('unauthorized', { status: 401 })
    }
    const role = url.searchParams.get('role')
    if (role !== 'phone' && role !== 'mac' && role !== 'viewer') {
      return new Response('bad role', { status: 400 })
    }
    const room = url.searchParams.get('room') || 'default'
    const hub = env.RELAY_HUB.get(env.RELAY_HUB.idFromName(room))
    return hub.fetch(new Request(`https://hub/connect?role=${role}`, request))
  },
}
