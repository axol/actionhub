import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import { ListToolsRequestSchema, CallToolRequestSchema } from '@modelcontextprotocol/sdk/types.js'
import { mkdirSync, readdirSync, readFileSync, unlinkSync, writeFileSync, renameSync, rmSync, watch } from 'node:fs'
import { join } from 'node:path'

const baseDirectory = '/tmp/claude-voice'
const claudeProcessId = process.ppid
const inboxDirectory = join(baseDirectory, 'inbox', String(claudeProcessId))
const speakDirectory = join(baseDirectory, 'speak')
const registryDirectory = join(baseDirectory, 'registry')
const registryFile = join(registryDirectory, `${claudeProcessId}.json`)

mkdirSync(inboxDirectory, { recursive: true })
mkdirSync(speakDirectory, { recursive: true })
mkdirSync(registryDirectory, { recursive: true })
writeFileSync(registryFile, JSON.stringify({
  claudeProcessId,
  workingDirectory: process.cwd(),
  inboxDirectory,
  startedAt: new Date().toISOString(),
}, null, 2))

const removeRegistryEntry = () => rmSync(registryFile, { force: true })
process.on('exit', removeRegistryEntry)
process.on('SIGTERM', () => process.exit(0))
process.on('SIGINT', () => process.exit(0))

const mcp = new Server(
  { name: 'voice', version: '1.0.0' },
  {
    capabilities: { experimental: { 'claude/channel': {} }, tools: {} },
    instructions:
      'Messages arriving as <channel source="voice"> are the user speaking to you, transcribed from voice. ' +
      'Treat them as normal user instructions. ' +
      'To answer by voice, call the speak tool. Use it deliberately, not for every message: ' +
      'a clarifying question, a completion notice, a failure that needs a decision. ' +
      'speak text must be optimized for listening: fluent conversational language in the language the user spoke, ' +
      'one to three short sentences, no markdown, no file paths, no code, no enumerations.',
  },
)

mcp.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [{
    name: 'speak',
    description: 'Speak a short message to the user out loud via text-to-speech. Use for clarifying questions and important notices only. Text must be fluent spoken language: no markdown, no paths, no code.',
    inputSchema: {
      type: 'object',
      properties: {
        text: { type: 'string', description: 'The message to speak, one to three short conversational sentences' },
      },
      required: ['text'],
    },
  }],
}))

mcp.setRequestHandler(CallToolRequestSchema, async (request) => {
  if (request.params.name !== 'speak') throw new Error(`unknown tool: ${request.params.name}`)
  const { text } = request.params.arguments
  const fileName = `speak-${Date.now()}.json`
  const temporaryPath = join(speakDirectory, `.${fileName}`)
  writeFileSync(temporaryPath, JSON.stringify({ text }))
  renameSync(temporaryPath, join(speakDirectory, fileName))
  return { content: [{ type: 'text', text: 'queued for speech' }] }
})

await mcp.connect(new StdioServerTransport())

let delivering = false

const deliverInboxFiles = async () => {
  if (delivering) return
  delivering = true
  try {
    const fileNames = readdirSync(inboxDirectory).filter(fileName => !fileName.startsWith('.')).sort()
    for (const fileName of fileNames) {
      const filePath = join(inboxDirectory, fileName)
      const content = readFileSync(filePath, 'utf8')
      unlinkSync(filePath)
      await mcp.notification({
        method: 'notifications/claude/channel',
        params: { content, meta: { file: fileName } },
      })
      const soundFileName = `sound-${Date.now()}-${fileName}.json`
      const temporarySoundPath = join(speakDirectory, `.${soundFileName}`)
      writeFileSync(temporarySoundPath, JSON.stringify({ sound: 'delivered' }))
      renameSync(temporarySoundPath, join(speakDirectory, soundFileName))
    }
  } finally {
    delivering = false
  }
}

watch(inboxDirectory, () => deliverInboxFiles())
setInterval(deliverInboxFiles, 2000)
deliverInboxFiles()
