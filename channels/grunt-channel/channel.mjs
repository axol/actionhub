import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import { mkdirSync, readdirSync, readFileSync, unlinkSync, writeFileSync, rmSync, watch } from 'node:fs'
import { join } from 'node:path'

const baseDirectory = '/tmp/claude-grunt'
const claudeProcessId = process.ppid
const inboxDirectory = join(baseDirectory, 'inbox', String(claudeProcessId))
const registryDirectory = join(baseDirectory, 'registry')
const registryFile = join(registryDirectory, `${claudeProcessId}.json`)

mkdirSync(inboxDirectory, { recursive: true })
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
  { name: 'grunt', version: '1.0.0' },
  {
    capabilities: { experimental: { 'claude/channel': {} } },
    instructions: 'Events from the grunt channel arrive as <channel source="grunt" ...>. They carry results of externally run jobs (specs, linters, builds) routed to this session. Read them and act on failures; no reply expected.',
  },
)

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
    }
  } finally {
    delivering = false
  }
}

watch(inboxDirectory, () => deliverInboxFiles())
setInterval(deliverInboxFiles, 2000)
deliverInboxFiles()
