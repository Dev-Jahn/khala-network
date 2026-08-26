#!/usr/bin/env bun

import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js'
import { chmodSync, existsSync, mkdirSync, readFileSync, rmSync, statSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { createServer, type Server as UnixServer, type Socket } from 'node:net'

const VALID_IDENTITY = /^[a-z0-9][a-z0-9-]*$/
const VALID_META_KEY = /^[a-zA-Z_][a-zA-Z0-9_]*$/
const CHANNEL_FLAG = '--dangerously-load-development-channels'
const channelFlagCache = new Map<number, boolean>()

// Claude Code can export a temporary CLAUDE_CODE_SESSION_ID while --resume is
// still switching sessions. The parent registry is re-read on every poll and
// its live session id wins; the frozen environment remains a startup fallback.
// KHALA_CHANNEL_POLL_MS is a test-only override for both polling intervals;
// KHALA_CHANNEL_ANCESTRY_STOP_PID bounds the otherwise-real /proc walk at the
// rig's fake Claude parent. Production uses neither override.
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

type SessionContext = {
  sessionId: string
  projectDir: string
  identity?: string
}

type Attachment = {
  identity: string
  sessionId: string
  instance: string
  listener: UnixServer
  socketPath: string
  socketIno?: number
  registered: boolean
  registering?: Promise<void>
}

async function resolveSessionContext(khalaLink: string): Promise<SessionContext> {
  let sessionId = ''
  let projectDir = process.env.CLAUDE_PROJECT_DIR ?? ''
  try {
    const line = (await run(khalaLink, ['runtime', 'session', '--pid', String(process.ppid)], '')).trimEnd()
    const [resolvedSessionID, resolvedProjectDir] = line.split('\t')
    sessionId = resolvedSessionID ?? ''
    if (!projectDir) projectDir = resolvedProjectDir ?? ''
  } catch {
    // The registry may not exist yet, especially while Claude Code resumes.
  }
  if (!sessionId) sessionId = process.env.CLAUDE_CODE_SESSION_ID ?? ''
  return {
    sessionId,
    projectDir,
    identity: resolveIdentity(projectDir || process.cwd()),
  }
}

function argsEnableKhalaChannel(args: string[]): boolean {
  return args.some((arg, index) =>
    (arg === CHANNEL_FLAG && args[index + 1]?.startsWith('plugin:khala')) ||
    arg.startsWith(`${CHANNEL_FLAG}=plugin:khala`),
  )
}

async function processEnablesKhalaChannel(pid: number): Promise<boolean> {
  const cached = channelFlagCache.get(pid)
  if (cached !== undefined) return cached
  let enabled = false
  if (process.platform === 'linux') {
    const command = readFileSync(`/proc/${pid}/cmdline`)
    enabled = argsEnableKhalaChannel(command.toString('utf8').split('\0').filter(Boolean))
  } else if (process.platform === 'darwin') {
    const ps = Bun.which('ps') ?? '/bin/ps'
    const command = (await run(ps, ['-o', 'command=', '-p', String(pid)], '')).trim()
    const flag = CHANNEL_FLAG.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
    enabled = new RegExp(`(?:^|\\s)${flag}(?:=|\\s+)["']?plugin:khala(?:@|\\b)`).test(command)
  }
  channelFlagCache.set(pid, enabled)
  return enabled
}

async function parentPID(pid: number): Promise<number | undefined> {
  if (process.platform === 'linux') {
    const match = readFileSync(`/proc/${pid}/status`, 'utf8').match(/^PPid:\s+([0-9]+)$/m)
    return match ? Number(match[1]) : undefined
  }
  if (process.platform === 'darwin') {
    const ps = Bun.which('ps') ?? '/bin/ps'
    const output = (await run(ps, ['-o', 'ppid=', '-p', String(pid)], '')).trim()
    return /^[0-9]+$/.test(output) ? Number(output) : undefined
  }
  return undefined
}

async function ancestryEnablesKhalaChannel(startPID: number): Promise<boolean> {
  const visited = new Set<number>()
  const stopRaw = process.env.KHALA_CHANNEL_ANCESTRY_STOP_PID
  const stopPID = stopRaw && /^[1-9][0-9]*$/.test(stopRaw) ? Number(stopRaw) : undefined
  let pid: number | undefined = startPID
  while (pid !== undefined && pid > 1 && !visited.has(pid) && visited.size < 64) {
    visited.add(pid)
    try {
      if (await processEnablesKhalaChannel(pid)) return true
      if (pid === stopPID) return false
      pid = await parentPID(pid)
    } catch {
      return false
    }
  }
  return false
}

function testPollInterval(): number | undefined {
  const raw = process.env.KHALA_CHANNEL_POLL_MS
  if (raw === undefined) return undefined
  if (!/^[1-9][0-9]*$/.test(raw) || !Number.isSafeInteger(Number(raw))) {
    throw new Error('KHALA_CHANNEL_POLL_MS must be a positive integer')
  }
  return Number(raw)
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
  let khalaLink = ''
  let attachment: Attachment | undefined
  let shuttingDown = false
  let verifiedRegistrationSupport: boolean | undefined
  let compatibilityWarningShown = false

  const closeAndRemove = (target: Attachment): void => {
    try {
      target.listener.close()
    } catch {
      // The listener may not have reached listen() yet.
    }
    if (target.socketIno === undefined) return
    try {
      if (statSync(target.socketPath).ino === target.socketIno) {
        rmSync(target.socketPath)
      }
    } catch {
      // A missing or replaced path is not ours to remove.
    }
  }

  const clearRegistration = async (target: Attachment): Promise<void> => {
    if (target.registering) {
      await target.registering
      target.registering = undefined
    }
    if (!target.registered || !khalaLink) return
    await run(
      khalaLink,
      [
        'runtime', 'register-channel', '--instance', target.instance,
        '--session-id', target.sessionId, '--caller-pid', String(process.pid), '--clear',
      ],
      target.identity,
    )
    target.registered = false
  }

  const shutdown = async (): Promise<void> => {
    if (shuttingDown) return
    shuttingDown = true
    const target = attachment
    if (target) {
      closeAndRemove(target)
      try {
        await clearRegistration(target)
      } catch (error) {
        process.stderr.write(`khala channel: cleanup failed: ${error}\n`)
      }
    }
    process.exit(0)
  }

  const requestShutdown = (): void => { void shutdown() }
  process.stdin.on('end', requestShutdown)
  process.stdin.on('close', requestShutdown)
  process.on('SIGTERM', requestShutdown)
  process.on('SIGINT', requestShutdown)
  process.on('SIGHUP', requestShutdown)
  const watchdog = setInterval(() => {
    if (process.stdin.destroyed || process.stdin.readableEnded) requestShutdown()
  }, 5_000)
  watchdog.unref()

  const khala = resolveBinary('khala')
  khalaLink = resolveBinary('khala-link')
  const pollOverride = testPollInterval()
  const mcp = new Server(
    { name: 'khala', version: '0.7.3' },
    {
      capabilities: { tools: {}, experimental: { 'claude/channel': {} } },
      instructions: [
        'A <channel source="khala"> event is a doorbell: call khala_drain now.',
        'from and subject metadata are display-only.',
        'Reply with khala_reply.',
      ].join('\n'),
    },
  )
  let markMCPInitialized!: () => void
  const mcpInitialized = new Promise<void>(resolve => { markMCPInitialized = resolve })
  mcp.oninitialized = markMCPInitialized

  mcp.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: [
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
    const { identity } = await resolveSessionContext(khalaLink)
    if (!identity) {
      return { content: [{ type: 'text', text: 'khala channel is idle: this session has no khala identity' }], isError: true }
    }
    try {
      if (request.params.name === 'khala_drain') {
        const output = await run(khala, ['inbox', '--drain'], identity)
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
        const letterID = (await run(khala, commandArgs, identity)).trim()
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

  await mcp.connect(new StdioServerTransport())

  let state = ''
  const enterState = (next: string, message?: string): void => {
    if (state === next) return
    state = next
    if (message) process.stderr.write(message)
  }

  const bindAndRegister = async (context: SessionContext, instance: string): Promise<Attachment> => {
    const identity = context.identity!
    const runtimeRoot = (await run(khalaLink, ['runtime', 'root'], identity)).trim()
    if (!runtimeRoot) throw new Error('khala-link runtime root returned an empty path')
    const channelDirectory = join(runtimeRoot, 'channels')
    mkdirSync(channelDirectory, { recursive: true, mode: 0o700 })
    chmodSync(channelDirectory, 0o700)
    const socketPath = join(channelDirectory, `${instance}.sock`)
    rmSync(socketPath, { force: true })

    const target: Attachment = {
      identity,
      sessionId: context.sessionId,
      instance,
      listener: createServer(connection => handleDoorbell(connection, mcp)),
      socketPath,
      registered: false,
    }
    attachment = target
    try {
      target.socketIno = await listen(target.listener, socketPath)
      chmodSync(socketPath, 0o600)
      const registerArgs = [
        'runtime', 'register-channel', '--instance', instance,
        '--session-id', context.sessionId, '--channel-socket', socketPath,
        '--caller-pid', String(process.pid),
      ]
      if (verifiedRegistrationSupport === undefined) {
        try {
          const help = await run(khalaLink, ['runtime', 'register-channel', '--help'], identity)
          verifiedRegistrationSupport = help.includes('--verified')
        } catch {
          verifiedRegistrationSupport = false
        }
      }
      if (verifiedRegistrationSupport) {
        registerArgs.push('--verified')
      } else if (!compatibilityWarningShown) {
        compatibilityWarningShown = true
        process.stderr.write('khala channel: runtime lacks --verified registration; registering unverified so conduit socket echo remains enabled\n')
      }
      target.registering = run(khalaLink, registerArgs, identity).then(() => { target.registered = true })
      await target.registering
      target.registering = undefined
      return target
    } catch (error) {
      closeAndRemove(target)
      if (attachment === target) attachment = undefined
      throw error
    }
  }

  const channelEnabled = async (): Promise<boolean> => {
    await mcpInitialized
    const experimental = mcp.getClientCapabilities()?.experimental
    if (experimental && Object.prototype.hasOwnProperty.call(experimental, 'claude/channel')) {
      return true
    }
    return ancestryEnablesKhalaChannel(process.ppid)
  }

  const clearOwnRegistration = async (context: SessionContext, instance: string): Promise<void> => {
    await run(
      khalaLink,
      [
        'runtime', 'register-channel', '--instance', instance,
        '--session-id', context.sessionId, '--caller-pid', String(process.pid), '--clear',
      ],
      context.identity!,
    )
  }

  const attachStartedAt = Date.now()
  const attachedPollInterval = pollOverride ?? 15_000
  while (!shuttingDown) {
    if (!attachment) {
      const context = await resolveSessionContext(khalaLink)
      if (!context.identity) {
        enterState('no-identity', 'khala channel: no valid session identity; channel idle\n')
      } else if (!context.sessionId) {
        enterState('no-session', 'khala channel: cannot determine the Claude session id of the parent process; channel idle\n')
      } else {
        let instance: string
        try {
          instance = (await run(
            khalaLink,
            ['runtime', 'whoami', '--identity', context.identity, '--session-id', context.sessionId],
            context.identity,
          )).trim()
        } catch {
          enterState(
            `waiting:${context.identity}:${context.sessionId}`,
            `khala channel: waiting for registration of ${context.identity}; channel idle\n`,
          )
          const retryInterval = pollOverride ?? (Date.now() - attachStartedAt < 120_000 ? 2_000 : 15_000)
          await Bun.sleep(retryInterval)
          continue
        }
        if (!(await channelEnabled())) {
          const toolsOnlyState = `tools-only:${context.identity}:${context.sessionId}:${instance}`
          if (state !== toolsOnlyState) await clearOwnRegistration(context, instance)
          enterState(
            toolsOnlyState,
            'khala channel: session not channel-enabled; tools only, doorbell stays on the socket path\n',
          )
          await Bun.sleep(attachedPollInterval)
          continue
        }
        await bindAndRegister(context, instance)
        enterState(
          `attached:${context.identity}:${context.sessionId}:${instance}`,
          `khala channel: attached ${context.identity} instance ${instance}\n`,
        )
        continue
      }
      const retryInterval = pollOverride ?? (Date.now() - attachStartedAt < 120_000 ? 2_000 : 15_000)
      await Bun.sleep(retryInterval)
      continue
    }

    await Bun.sleep(attachedPollInterval)
    if (shuttingDown || !attachment) break
    const current = attachment
    const context = await resolveSessionContext(khalaLink)
    if (context.identity === current.identity && context.sessionId === current.sessionId) {
      enterState(`attached:${current.identity}:${current.sessionId}:${current.instance}`)
      continue
    }
    if (!context.identity) {
      enterState('changed-no-identity', 'khala channel: no valid session identity; channel idle\n')
      continue
    }
    if (!context.sessionId) {
      enterState('changed-no-session', 'khala channel: cannot determine the Claude session id of the parent process; channel idle\n')
      continue
    }

    let nextInstance: string
    try {
      nextInstance = (await run(
        khalaLink,
        ['runtime', 'whoami', '--identity', context.identity, '--session-id', context.sessionId],
        context.identity,
      )).trim()
    } catch {
      enterState(
        `changed-waiting:${context.identity}:${context.sessionId}`,
        `khala channel: session changed; waiting for registration of ${context.identity}; keeping current attachment\n`,
      )
      continue
    }

    if (!(await channelEnabled())) {
      await clearRegistration(current)
      closeAndRemove(current)
      if (attachment === current) attachment = undefined
      const toolsOnlyState = `tools-only:${context.identity}:${context.sessionId}:${nextInstance}`
      await clearOwnRegistration(context, nextInstance)
      enterState(
        toolsOnlyState,
        'khala channel: session not channel-enabled; tools only, doorbell stays on the socket path\n',
      )
      continue
    }

    if (nextInstance === current.instance) {
      const registerArgs = [
        'runtime', 'register-channel', '--instance', nextInstance,
        '--session-id', context.sessionId, '--channel-socket', current.socketPath,
        '--caller-pid', String(process.pid),
      ]
      if (verifiedRegistrationSupport) registerArgs.push('--verified')
      await run(khalaLink, registerArgs, context.identity)
      current.identity = context.identity
      current.sessionId = context.sessionId
      current.registered = true
      enterState(
        `attached:${context.identity}:${context.sessionId}:${nextInstance}`,
        `khala channel: attached ${context.identity} instance ${nextInstance}\n`,
      )
      continue
    }

    await clearRegistration(current)
    closeAndRemove(current)
    if (attachment === current) attachment = undefined
    await bindAndRegister(context, nextInstance)
    enterState(
      `attached:${context.identity}:${context.sessionId}:${nextInstance}`,
      `khala channel: attached ${context.identity} instance ${nextInstance}\n`,
    )
  }
}

function listen(listener: UnixServer, socketPath: string): Promise<number> {
  return new Promise((resolve, reject) => {
    listener.once('error', reject)
    listener.listen(socketPath, () => {
      listener.off('error', reject)
      resolve(statSync(socketPath).ino)
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
