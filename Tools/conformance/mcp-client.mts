// Generates Tests/AISDKMCPTests/Fixtures/mcp-client-conformance.json by running
// the upstream TypeScript MCP client against scripted servers. The Swift tests
// replay the same scripts and compare requests and results.
import * as fs from 'node:fs';
import * as path from 'node:path';

const upstream = process.env.UPSTREAM!;
const repo = path.resolve(import.meta.dirname, '../..');
const outputDir = path.join(repo, 'Tests/AISDKMCPTests/Fixtures');

const { createMCPClient } = await import(path.join(upstream, 'packages/mcp/src/tool/mcp-client.ts'));
const { asSchema, jsonSchema } = await import(path.join(upstream, 'packages/provider-utils/src/index.ts'));

type Reply = { result?: unknown; error?: { code: number; message: string; data?: unknown } };
type Operation =
  | { op: 'tools'; schemas?: Record<string, { inputSchema: unknown; outputSchema?: unknown }> }
  | { op: 'execute'; tool: string; input: unknown; schemas?: Record<string, { inputSchema: unknown; outputSchema?: unknown }> }
  | { op: 'callTool'; name: string; arguments?: unknown }
  | { op: 'listTools' }
  | { op: 'listResources' }
  | { op: 'readResource'; uri: string }
  | { op: 'listResourceTemplates' }
  | { op: 'listPrompts' }
  | { op: 'getPrompt'; name: string; arguments?: unknown }
  | { op: 'complete'; ref: unknown; argument: unknown }
  | { op: 'close' };

type Case = {
  name: string;
  config?: Record<string, unknown>;
  modernDiscovery?: boolean;
  replies: Record<string, Reply[]>;
  operations: Operation[];
};

const initialize = (overrides: Record<string, unknown> = {}): Reply => ({
  result: {
    protocolVersion: '2025-11-25',
    capabilities: { tools: {}, resources: {}, prompts: {}, completions: {} },
    serverInfo: { name: 'test-server', version: '1.2.3', title: 'Test Server' },
    instructions: 'Use the tools wisely.',
    ...overrides,
  },
});

const weatherTool = {
  name: 'get_weather',
  title: 'Get Weather',
  description: 'Current weather',
  inputSchema: { type: 'object', properties: { city: { type: 'string' } }, required: ['city'] },
  annotations: { readOnlyHint: true, openWorldHint: false, custom: 'ignored' },
  _meta: { ui: { resourceUri: 'ui://weather/app.html', visibility: ['model', 'app'] } },
};

const cases: Case[] = [
  {
    name: 'initialize-and-tools',
    config: { clientName: 'swift-tests', version: '9.9.9', capabilities: { elicitation: {} } },
    replies: {
      initialize: [initialize()],
      'tools/list': [
        { result: { tools: [weatherTool], nextCursor: 'page-2' } },
        {
          result: {
            tools: [
              { name: 'no_args', inputSchema: { type: 'object' } },
              { name: 'legacy_title', inputSchema: { type: 'object', properties: {} }, annotations: { title: 'Legacy' } },
            ],
          },
        },
      ],
    },
    operations: [{ op: 'tools' }],
  },
  {
    name: 'execute-and-model-output',
    replies: {
      initialize: [initialize()],
      'tools/list': [{ result: { tools: [weatherTool] } }],
      'tools/call': [
        {
          result: {
            content: [
              { type: 'text', text: 'Sunny' },
              { type: 'image', data: 'AAECAw==', mimeType: 'image/png' },
              { type: 'resource_link', uri: 'file:///a', name: 'a' },
            ],
          },
        },
        { result: { structuredContent: { temperature: 23 } } },
        { result: { toolResult: { legacy: true } } },
        { result: { content: [{ type: 'text', text: 'boom' }], isError: true } },
      ],
    },
    operations: [
      { op: 'execute', tool: 'get_weather', input: { city: 'Hangzhou' } },
      { op: 'execute', tool: 'get_weather', input: { city: 'Shanghai' } },
      { op: 'execute', tool: 'get_weather', input: { city: 'Legacy' } },
      { op: 'execute', tool: 'get_weather', input: { city: 'Error' } },
    ],
  },
  {
    name: 'typed-tools-with-output-schema',
    replies: {
      initialize: [initialize()],
      'tools/list': [{ result: { tools: [weatherTool, { name: 'other', inputSchema: { type: 'object' } }] } }],
      'tools/call': [
        { result: { content: [{ type: 'text', text: 'ignored' }], structuredContent: { temperature: 21 } } },
        { result: { content: [{ type: 'text', text: '{"temperature":19}' }] } },
        { result: { content: [{ type: 'text', text: 'not json' }] } },
      ],
    },
    operations: [
      {
        op: 'execute',
        tool: 'get_weather',
        input: { city: 'A' },
        schemas: {
          get_weather: {
            inputSchema: { type: 'object', properties: { city: { type: 'string' } } },
            outputSchema: { type: 'object', properties: { temperature: { type: 'number' } }, required: ['temperature'] },
          },
        },
      },
      {
        op: 'execute',
        tool: 'get_weather',
        input: { city: 'B' },
        schemas: {
          get_weather: {
            inputSchema: { type: 'object', properties: { city: { type: 'string' } } },
            outputSchema: { type: 'object', properties: { temperature: { type: 'number' } }, required: ['temperature'] },
          },
        },
      },
      {
        op: 'execute',
        tool: 'get_weather',
        input: { city: 'C' },
        schemas: {
          get_weather: {
            inputSchema: { type: 'object', properties: { city: { type: 'string' } } },
            outputSchema: { type: 'object', properties: { temperature: { type: 'number' } }, required: ['temperature'] },
          },
        },
      },
    ],
  },
  {
    name: 'resources-prompts-completions',
    replies: {
      initialize: [initialize()],
      'resources/list': [{ result: { resources: [{ uri: 'file:///a.txt', name: 'a.txt', mimeType: 'text/plain' }] } }],
      'resources/read': [{ result: { contents: [{ uri: 'file:///a.txt', text: 'hello' }] } }],
      'resources/templates/list': [{ result: { resourceTemplates: [{ uriTemplate: 'file:///{path}', name: 'file' }] } }],
      'prompts/list': [{ result: { prompts: [{ name: 'review', arguments: [{ name: 'code', required: true }] }] } }],
      'prompts/get': [
        { result: { description: 'Review', messages: [{ role: 'user', content: { type: 'text', text: 'Review this' } }] } },
      ],
      'completion/complete': [{ result: { completion: { values: ['python', 'pytorch'], total: 2, hasMore: false } } }],
    },
    operations: [
      { op: 'listResources' },
      { op: 'readResource', uri: 'file:///a.txt' },
      { op: 'listResourceTemplates' },
      { op: 'listPrompts' },
      { op: 'getPrompt', name: 'review', arguments: { code: 'x' } },
      { op: 'complete', ref: { type: 'ref/prompt', name: 'review' }, argument: { name: 'language', value: 'py' } },
    ],
  },
  {
    name: 'errors-and-capabilities',
    replies: {
      initialize: [initialize({ capabilities: { tools: {} } })],
      'tools/call': [
        { error: { code: -32602, message: 'Invalid params', data: { field: 'city' } } },
        { result: { content: [{ type: 'image', data: 'not base64!', mimeType: 'image/png' }] } },
      ],
    },
    operations: [
      { op: 'callTool', name: 'get_weather', arguments: { city: 1 } },
      { op: 'callTool', name: 'get_weather', arguments: {} },
      { op: 'listResources' },
      { op: 'listPrompts' },
      { op: 'complete', ref: { type: 'ref/prompt', name: 'x' }, argument: { name: 'a', value: 'b' } },
    ],
  },
  {
    name: 'unsupported-protocol-version',
    replies: { initialize: [initialize({ protocolVersion: '2023-01-01' })] },
    operations: [],
  },
  {
    name: 'older-protocol-version',
    replies: { initialize: [initialize({ protocolVersion: '2024-11-05', instructions: undefined })] },
    operations: [{ op: 'close' }],
  },
  {
    name: 'modern-discovery',
    modernDiscovery: true,
    replies: {
      'server/discover': [
        {
          result: {
            resultType: 'complete',
            supportedVersions: ['2026-07-28'],
            capabilities: { tools: {} },
            instructions: 'modern',
            _meta: { 'io.modelcontextprotocol/serverInfo': { name: 'modern-server', version: '2.0.0' } },
          },
        },
      ],
      'tools/list': [
        {
          result: {
            resultType: 'complete',
            tools: [
              {
                name: 'header_tool',
                inputSchema: {
                  type: 'object',
                  properties: { region: { type: 'string', 'x-mcp-header': 'Region' }, count: { type: 'integer' } },
                },
              },
            ],
          },
        },
      ],
      'tools/call': [{ result: { resultType: 'complete', content: [{ type: 'text', text: 'ok' }] } }],
    },
    operations: [{ op: 'tools' }, { op: 'callTool', name: 'header_tool', arguments: { region: 'eu-west', count: 2 } }],
  },
];

function scriptedTransport(testCase: Case, sent: unknown[]) {
  const replies = structuredClone(testCase.replies);
  const transport: any = {
    supportsProtocolVersionDiscovery: testCase.modernDiscovery === true,
    supportsMcpToolParameterHeaders: testCase.modernDiscovery === true,
    async start() {},
    async close() {
      transport.onclose?.();
    },
    setProtocolVersion(version: string) {
      transport.protocolVersion = version;
    },
    async send(message: any, options?: { headers?: Record<string, string> }) {
      const { id, jsonrpc, ...rest } = message;
      sent.push({ ...rest, ...(options?.headers ? { headers: options.headers } : {}) });
      if (!('method' in message) || !('id' in message)) return;
      const queue = replies[message.method];
      const reply = queue == null ? undefined : queue.length > 1 ? queue.shift() : queue[0];
      if (reply == null) {
        setTimeout(() => transport.onmessage?.({ jsonrpc: '2.0', id, error: { code: -32601, message: 'Method not found' } }), 0);
        return;
      }
      setTimeout(() => transport.onmessage?.({ jsonrpc: '2.0', id, ...reply }), 0);
    },
  };
  return transport;
}

const plain = (value: unknown) => JSON.parse(JSON.stringify(value ?? null));
const errorInfo = (error: any) => ({
  error: { message: error.message, code: error.code ?? null, data: error.data ?? null },
});

async function describeTool(name: string, tool: any) {
  const schema = await asSchema(tool.inputSchema).jsonSchema;
  return plain({
    name,
    type: tool.type ?? 'function',
    description: tool.description,
    title: tool.title,
    metadata: tool.metadata,
    inputSchema: schema,
  });
}

const output: unknown[] = [];
for (const testCase of cases) {
  const sent: unknown[] = [];
  const results: unknown[] = [];
  let client: any;
  try {
    client = await createMCPClient({ transport: scriptedTransport(testCase, sent), ...(testCase.config ?? {}) });
    results.push({
      op: 'init',
      serverInfo: plain(client.serverInfo),
      instructions: client.instructions ?? null,
      protocolVersion: client.initializeResult.protocolVersion,
    });
  } catch (error) {
    results.push({ op: 'init', ...errorInfo(error) });
  }

  for (const operation of client == null ? [] : testCase.operations) {
    try {
      switch (operation.op) {
        case 'tools': {
          const schemas =
            operation.schemas == null
              ? undefined
              : Object.fromEntries(
                  Object.entries(operation.schemas).map(([key, value]) => [
                    key,
                    {
                      inputSchema: jsonSchema(value.inputSchema as any),
                      ...(value.outputSchema ? { outputSchema: jsonSchema(value.outputSchema as any) } : {}),
                    },
                  ]),
                );
          const tools = await client.tools(schemas ? { schemas } : undefined);
          results.push({
            op: 'tools',
            tools: await Promise.all(Object.entries(tools).map(([name, tool]) => describeTool(name, tool))),
          });
          break;
        }
        case 'execute': {
          const schemas =
            operation.schemas == null
              ? undefined
              : Object.fromEntries(
                  Object.entries(operation.schemas).map(([key, value]) => [
                    key,
                    {
                      inputSchema: jsonSchema(value.inputSchema as any),
                      ...(value.outputSchema ? { outputSchema: jsonSchema(value.outputSchema as any) } : {}),
                    },
                  ]),
                );
          const tools = await client.tools(schemas ? { schemas } : undefined);
          const tool = tools[operation.tool];
          const executed = await tool.execute(operation.input, { toolCallId: 'call-1', messages: [] });
          const modelOutput = await tool.toModelOutput({ toolCallId: 'call-1', input: operation.input, output: executed });
          results.push({ op: 'execute', output: plain(executed), modelOutput: plain(modelOutput) });
          break;
        }
        case 'callTool':
          results.push({ op: 'callTool', result: plain(await client.callTool({ name: operation.name, arguments: operation.arguments })) });
          break;
        case 'listTools':
          results.push({ op: 'listTools', result: plain(await client.listTools()) });
          break;
        case 'listResources':
          results.push({ op: 'listResources', result: plain(await client.listResources()) });
          break;
        case 'readResource':
          results.push({ op: 'readResource', result: plain(await client.readResource({ uri: operation.uri })) });
          break;
        case 'listResourceTemplates':
          results.push({ op: 'listResourceTemplates', result: plain(await client.listResourceTemplates()) });
          break;
        case 'listPrompts':
          results.push({ op: 'listPrompts', result: plain(await client.experimental_listPrompts()) });
          break;
        case 'getPrompt':
          results.push({
            op: 'getPrompt',
            result: plain(await client.experimental_getPrompt({ name: operation.name, arguments: operation.arguments })),
          });
          break;
        case 'complete':
          results.push({ op: 'complete', result: plain(await client.complete({ ref: operation.ref, argument: operation.argument })) });
          break;
        case 'close':
          await client.close();
          results.push({ op: 'close' });
          break;
      }
    } catch (error) {
      results.push({ op: operation.op, ...errorInfo(error) });
    }
  }
  output.push({ ...testCase, sent: plain(sent), results: plain(results) });
}

fs.mkdirSync(outputDir, { recursive: true });
fs.writeFileSync(path.join(outputDir, 'mcp-client-conformance.json'), JSON.stringify(output, null, 1) + '\n');
console.log(`wrote ${output.length} MCP cases`);
