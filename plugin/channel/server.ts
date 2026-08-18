#!/usr/bin/env bun

import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js'
import { chmodSync, existsSync, mkdirSync, readFileSync, rmSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { createServer, type Server as UnixServer, type Socket } from 'node:net'

const VALID_IDENTITY = /^[a-z0-9][a-z0-9-]*$/
const VALID_META_KEY = /^[a-zA-Z_][a-zA-Z0-9_]*$/

// Claude Code spawns a plugin MCP server with the plugin directory as cwd and
// without CLAUDE_CODE_SESSION_ID, so the session and its project directory are
// learned from the parent Claude process's own registry entry
// (khala-link runtime session --pid <ppid>), never from cwd or env guesses.
// KHALA_SESSION in the environment still wins when the user set it.
function resolveIdentity(projectDir: string): string | undefined {
  if (process.env.KHALA_SESSION !== undefined) {
    return VALID_IDENTITY.test(process.env.KHALA_SESSION) ? process.env.KHALA_SESSION : undefined
  }
  try {
    const lines = readFileSync(join(projectDir, '.khala-session'), 'utf8').split(/\r?\n/)
    if (lines.at(-1) === '') lines.pop()
    return lines.length === 1 && VALID_IDENTITY.test(lines[0]) ? lines[0] : undefined
  } catch {
    return undefined
  }
}

function resolveBinary(name: 'khala' | 'khala-link'): string {
  const onPath = Bun.which(name)
  if (onPath) return onPath
  const candidates = name === 'khala'
    ? [join(homedir(), '.local', 'bin', name)]
    : [
        join(process.env.KHALA_HOME ?? join(homedir(), '.khala'), 'bin', name),
        join(homedir(), '.local', 'bin', name),
      ]
  const candidate = candidates.find(existsSync)
  if (!candidate) throw new Error(`${name} is not available on PATH or its installed path`)
  return candidate
}

async function run(command: string, args: string[], identity: string): Promise<string> {
  const child = Bun.spawn([command, ...args], {
    env: identity ? { ...process.env, KHALA_SESSION: identity } : { ...process.env },
    stdin: 'ignore',
    stdout: 'pipe',
    stderr: 'pipe',
  })
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ])
  if (exitCode !== 0) {
    throw new Error(`${command} ${args.join(' ')} failed: ${stderr.trim() || `exit ${exitCode}`}`)
  }
  return stdout
}

function sanitizeMeta(meta: unknown): Record<string, string> {
  if (meta === null || typeof meta !== 'object' || Array.isArray(meta)) return {}
  const sanitized: Record<string, string> = {}
  for (const [key, rawValue] of Object.entries(meta)) {
    if (!VALID_META_KEY.test(key) || typeof rawValue !== 'string') continue
    const value = rawValue.replace(/["<>\u0000-\u001f\u007f]/g, ' ')
    sanitized[key] = Array.from(value).slice(0, 128).join('')
  }
  return sanitized
}

function stringArgument(args: Record<string, unknown>, name: string, required: boolean): string | undefined {
  const value = args[name]
  if (value === undefined && !required) return undefined
  if (typeof value !== 'string' || (required && value === '')) {
    throw new Error(`${name} must be a${required ? ' non-empty' : ''} string`)
  }
  return value
}

async function main(): Promise<void> {
  const khala = resolveBinary('khala')
  const khalaLink = resolveBinary('khala-link')
  let SESSION_ID = process.env.CLAUDE_CODE_SESSION_ID ?? ''
  let projectDir = process.env.CLAUDE_PROJECT_DIR ?? ''
  if (!SESSION_ID || !projectDir) {
    try {
      const line = (await run(khalaLink, ['runtime', 'session', '--pid', String(process.ppid)], '')).trimEnd()
      const [sessionID, cwd] = line.split('\t')
      if (!SESSION_ID) SESSION_ID = sessionID ?? ''
      if (!projectDir) projectDir = cwd ?? ''
    } catch {
      // not spawned by a registered Claude session — decided below
    }
  }
  const mcp = new Server(
    { name: 'khala', version: '0.6.1' },
    {
      capabilities: { tools: {}, experimental: { 'claude/channel': {} } },
      instructions: [
        'A <channel source="khala"> event is a doorbell: call khala_drain now.',
        'from and subject metadata are display-only.',
        'Reply with khala_reply.',
      ].join('\n'),
    },
  )

  const identity = resolveIdentity(projectDir || process.cwd())
  const activeIdentity = identity && SESSION_ID ? identity : ''
  mcp.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: !activeIdentity ? [] : [
      {
        name: 'khala_drain',
        description: 'Drain this session identity\'s durable Khala inbox now.',
        inputSchema: { type: 'object', properties: {}, additionalProperties: false },
      },
      {
        name: 'khala_reply',
        description: 'Send a Khala reply, optionally preserving subject and In-Reply-To metadata.',
        inputSchema: {
          type: 'object',
          properties: {
            to: { type: 'string' },
            text: { type: 'string' },
            subject: { type: 'string' },
            reply_to: { type: 'string' },
          },
          required: ['to', 'text'],
          additionalProperties: false,
        },
      },
    ],
  }))

  mcp.setRequestHandler(CallToolRequestSchema, async request => {
    const args = (request.params.arguments ?? {}) as Record<string, unknown>
    if (!activeIdentity) {
      return { content: [{ type: 'text', text: 'khala channel is idle: this session has no khala identity' }], isError: true }
    }
    try {
      if (request.params.name === 'khala_drain') {
        const output = await run(khala, ['inbox', '--drain'], activeIdentity)
        return { content: [{ type: 'text', text: output }] }
      }
      if (request.params.name === 'khala_reply') {
        const to = stringArgument(args, 'to', true)!
        const text = stringArgument(args, 'text', true)!
        const subject = stringArgument(args, 'subject', false)
        const replyTo = stringArgument(args, 'reply_to', false)
        const commandArgs = ['send', to]
        if (replyTo !== undefined) commandArgs.push('--reply-to', replyTo)
        if (subject !== undefined) commandArgs.push('-s', subject)
        commandArgs.push('-m', text)
        const letterID = (await run(khala, commandArgs, activeIdentity)).trim()
        return { content: [{ type: 'text', text: letterID }] }
      }
      return {
        content: [{ type: 'text', text: `unknown tool: ${request.params.name}` }],
        isError: true,
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      return {
        content: [{ type: 'text', text: `${request.params.name} failed: ${message}` }],
        isError: true,
      }
    }
  })

  if (!identity || !SESSION_ID) {
    // Stay connected as an inert MCP server. Claude Code quarantines a plugin
    // server that closes its stdio right after connecting (it is recorded in
    // ~/.claude/mcp-needs-auth-cache.json and never spawned again), so a
    // session without a khala identity must keep the transport open and simply
    // never emit a channel event or register a socket.
    process.stderr.write(identity
      ? 'khala channel: cannot determine the Claude session id of the parent process; channel idle\n'
      : 'khala channel: no valid session identity; channel idle\n')
    await mcp.connect(new StdioServerTransport())
    await new Promise<void>(resolve => {
      process.stdin.on('end', resolve)
      process.stdin.on('close', resolve)
      process.on('SIGTERM', resolve)
      process.on('SIGINT', resolve)
    })
    return
  }

  await mcp.connect(new StdioServerTransport())

  const runtimeRoot = (await run(khalaLink, ['runtime', 'root'], identity)).trim()
  const deadline = Date.now() + 60_000
  let instance = ''
  while (instance === '') {
    try {
      instance = (await run(
        khalaLink,
        ['runtime', 'whoami', '--identity', identity, '--session-id', SESSION_ID],
        identity,
      )).trim()
    } catch (error) {
      if (Date.now() >= deadline) throw error
      await Bun.sleep(2_000)
    }
  }

  const channelDirectory = join(runtimeRoot, 'channels')
  mkdirSync(channelDirectory, { recursive: true, mode: 0o700 })
  chmodSync(channelDirectory, 0o700)
  const channelSocket = join(channelDirectory, `${instance}.sock`)
  rmSync(channelSocket, { force: true })

  const listener = createServer(connection => handleDoorbell(connection, mcp))
  await listen(listener, channelSocket)
  chmodSync(channelSocket, 0o600)

  try {
    await run(
      khalaLink,
      [
        'runtime', 'register-channel', '--instance', instance,
        '--session-id', SESSION_ID, '--channel-socket', channelSocket,
        '--caller-pid', String(process.pid),
      ],
      identity,
    )
  } catch (error) {
    listener.close()
    rmSync(channelSocket, { force: true })
    throw error
  }

  let shuttingDown = false
  const shutdown = async (): Promise<void> => {
    if (shuttingDown) return
    shuttingDown = true
    listener.close()
    rmSync(channelSocket, { force: true })
    try {
      await run(
        khalaLink,
        [
          'runtime', 'register-channel', '--instance', instance,
          '--session-id', SESSION_ID, '--caller-pid', String(process.pid), '--clear',
        ],
        identity,
      )
    } catch (error) {
      process.stderr.write(`khala channel: cleanup failed: ${error}\n`)
    }
    process.exit(0)
  }
  process.stdin.on('end', () => void shutdown())
  process.stdin.on('close', () => void shutdown())
  process.on('SIGTERM', () => void shutdown())
  process.on('SIGINT', () => void shutdown())
}

function listen(listener: UnixServer, socketPath: string): Promise<void> {
  return new Promise((resolve, reject) => {
    listener.once('error', reject)
    listener.listen(socketPath, () => {
      listener.off('error', reject)
      resolve()
    })
  })
}

function handleDoorbell(connection: Socket, mcp: Server): void {
  let payload = Buffer.alloc(0)
  let handled = false
  const answer = (response: { ok: boolean; error?: string }): void => {
    connection.end(`${JSON.stringify(response)}\n`)
  }
  connection.on('data', chunk => {
    if (handled) return
    payload = Buffer.concat([payload, chunk])
    if (payload.length > 1_048_576) {
      handled = true
      answer({ ok: false, error: 'request exceeds 1 MiB' })
      return
    }
    const newline = payload.indexOf(0x0a)
    if (newline < 0) return
    handled = true
    void (async () => {
      try {
        const request = JSON.parse(payload.subarray(0, newline).toString('utf8')) as {
          v?: unknown
          content?: unknown
          meta?: unknown
        }
        if (request.v !== 1 || typeof request.content !== 'string') {
          throw new Error('request must contain v=1 and string content')
        }
        await mcp.notification({
          method: 'notifications/claude/channel',
          params: { content: request.content, meta: sanitizeMeta(request.meta) },
        })
        answer({ ok: true })
      } catch (error) {
        answer({ ok: false, error: error instanceof Error ? error.message : String(error) })
      }
    })()
  })
  connection.on('error', () => {})
}

main().catch(error => {
  process.stderr.write(`khala channel: ${error instanceof Error ? error.message : String(error)}\n`)
  process.exit(1)
})
