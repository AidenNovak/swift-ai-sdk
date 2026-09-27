// Generates Tests/AISDKOpenAITests/Fixtures/openai-responses-conformance.json by
// running the upstream TypeScript OpenAIResponsesLanguageModel on the recorded
// fixtures. The Swift tests replay the same cases and compare the results.
//
// Usage (see run.sh): UPSTREAM=/path/to/vercel-ai npx tsx openai-responses.mts
import * as fs from 'node:fs';
import * as path from 'node:path';

const upstream = process.env.UPSTREAM!;
const repo = path.resolve(import.meta.dirname, '../..');
const fixtures = path.join(repo, 'Tests/AISDKOpenAITests/Fixtures');

const { OpenAIResponsesLanguageModel } = await import(
  path.join(upstream, 'packages/openai/src/responses/openai-responses-language-model.ts')
);

const TEST_PROMPT = [{ role: 'user', content: [{ type: 'text', text: 'Hello' }] }];

const TEST_TOOLS = [
  {
    type: 'function',
    name: 'weather',
    inputSchema: {
      type: 'object',
      properties: { location: { type: 'string' } },
      required: ['location'],
      additionalProperties: false,
    },
  },
  {
    type: 'function',
    name: 'cityAttractions',
    inputSchema: {
      type: 'object',
      properties: { city: { type: 'string' } },
      required: ['city'],
      additionalProperties: false,
    },
  },
];

const deferredFunctionTools = [
  {
    type: 'function',
    name: 'get_weather',
    description: 'Get the current weather at a specific location',
    inputSchema: {
      type: 'object',
      properties: { location: { type: 'string' }, unit: { type: 'string', enum: ['celsius', 'fahrenheit'] } },
      required: ['location', 'unit'],
      additionalProperties: false,
    },
    strict: true,
    providerOptions: { openai: { deferLoading: true } },
  },
  {
    type: 'function',
    name: 'search_files',
    description: 'Search through files in the workspace',
    inputSchema: {
      type: 'object',
      properties: { query: { type: 'string' }, file_types: { type: 'array', items: { type: 'string' } } },
      required: ['query', 'file_types'],
      additionalProperties: false,
    },
    strict: true,
    providerOptions: { openai: { deferLoading: true } },
  },
];

const HOSTED_TOOL_SEARCH_TOOLS = [
  { type: 'provider', id: 'openai.tool_search', name: 'toolSearch', args: {} },
  ...deferredFunctionTools,
];

const CLIENT_TOOL_SEARCH_TOOLS = [
  {
    type: 'provider',
    id: 'openai.tool_search',
    name: 'toolSearch',
    args: {
      execution: 'client',
      description: 'Search for available tools based on what the user needs.',
      parameters: {
        type: 'object',
        properties: { goal: { type: 'string', description: 'What the user is trying to accomplish' } },
        required: ['goal'],
        additionalProperties: false,
      },
    },
  },
  ...deferredFunctionTools,
];

const codeInterpreter = [{ type: 'provider', id: 'openai.code_interpreter', name: 'codeExecution', args: {} }];
const fileSearch = [
  {
    type: 'provider',
    id: 'openai.file_search',
    name: 'fileSearch',
    args: {
      vectorStoreIds: ['vs_68caad8bd5d88191ab766cf043d89a18'],
      maxNumResults: 5,
      filters: { key: 'author', type: 'eq', value: 'Jane Smith' },
      ranking: { ranker: 'auto', scoreThreshold: 0.5 },
    },
  },
];
const containerShell = [
  { type: 'provider', id: 'openai.shell', name: 'shell', args: { environment: { type: 'containerAuto' } } },
];
const localShellTool = [{ type: 'provider', id: 'openai.shell', name: 'shell', args: {} }];
const mcpApprovalTool = [
  {
    type: 'provider',
    id: 'openai.mcp',
    name: 'MCP',
    args: {
      serverLabel: 'zip1',
      serverUrl: 'https://zip1.io/mcp',
      serverDescription: 'Link shortener',
      requireApproval: 'always',
    },
  },
];
const applyPatch = [{ type: 'provider', id: 'openai.apply_patch', name: 'apply_patch', args: {} }];
const programmaticTools = [
  { type: 'provider', id: 'openai.programmatic_tool_calling', name: 'program', args: {} },
  {
    type: 'function',
    name: 'getInventory',
    inputSchema: { type: 'object', properties: { sku: { type: 'string' } }, required: ['sku'] },
  },
  {
    type: 'function',
    name: 'getDemand',
    inputSchema: { type: 'object', properties: { sku: { type: 'string' } }, required: ['sku'] },
  },
];

const shellResultOutput = (stdout: string) => ({
  type: 'json',
  value: { output: [{ stdout, stderr: '', outcome: { type: 'exit', exitCode: 0 } }] },
});

const containerMultiturnPrompt = [
  { role: 'user', content: [{ type: 'text', text: 'Run uname -a' }] },
  {
    role: 'assistant',
    content: [
      {
        type: 'tool-call',
        toolCallId: 'call_abc123def456ghi789jkl012',
        toolName: 'shell',
        input: '{"action":{"commands":["uname -a"]}}',
        providerExecuted: true,
        providerOptions: { openai: { itemId: 'sh_0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e50' } },
      },
      {
        type: 'tool-result',
        toolCallId: 'call_abc123def456ghi789jkl012',
        toolName: 'shell',
        output: shellResultOutput('Linux container-host 6.1.0 #1 SMP x86_64 GNU/Linux\n'),
      },
      {
        type: 'text',
        text: 'Linux container-host 6.1.0 #1 SMP x86_64 GNU/Linux',
        providerOptions: { openai: { itemId: 'msg_0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e52' } },
      },
    ],
  },
  { role: 'user', content: [{ type: 'text', text: 'What architecture do you run in?' }] },
];

const localMultiturnPrompt = [
  { role: 'user', content: [{ type: 'text', text: 'Run uname -a' }] },
  {
    role: 'assistant',
    content: [
      {
        type: 'tool-call',
        toolCallId: 'call_abc123def456ghi789jkl012',
        toolName: 'shell',
        input: '{"action":{"commands":["uname -a"]}}',
        providerOptions: { openai: { itemId: 'sh_0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e50' } },
      },
    ],
  },
  {
    role: 'tool',
    content: [
      {
        type: 'tool-result',
        toolCallId: 'call_abc123def456ghi789jkl012',
        toolName: 'shell',
        output: shellResultOutput(
          'Darwin mac-host 24.6.0 Darwin Kernel Version 24.6.0 root:xnu-11417.60.45.601.5~1/RELEASE_ARM64_T6041 arm64\n',
        ),
      },
    ],
  },
  {
    role: 'assistant',
    content: [
      {
        type: 'text',
        text: 'Darwin mac-host 24.6.0 Darwin Kernel Version 24.6.0 arm64',
        providerOptions: { openai: { itemId: 'msg_0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e52' } },
      },
    ],
  },
  { role: 'user', content: [{ type: 'text', text: 'What architecture do you run in?' }] },
];

const mcpApprovalCall = (id: string) => ({
  role: 'assistant',
  content: [
    { type: 'tool-call', toolCallId: id, toolName: 'mcp.create_short_url', input: { url: 'https://ai-sdk.dev/' }, providerExecuted: true },
  ],
});
const mcpApprovalResponse = (id: string, approved: boolean) => ({
  role: 'tool',
  content: [{ type: 'tool-approval-response', approvalId: id, approved }],
});
const shortenPrompt = { role: 'user', content: [{ type: 'text', text: 'shorten ai-sdk.dev' }] };
const deniedId = 'mcpr_04f6b17429cf2b02006949a6712b1081968b3c7a72dec695d8';
const approvedId = 'mcpr_04f6b17429cf2b02006949a68bf5808196b6f2008a315c9aa4';

type Case = {
  name: string;
  fixture: string;
  modelId: string;
  options: Record<string, unknown>;
  modes?: Array<'generate' | 'stream'>;
};

const cases: Case[] = [
  { name: 'error', fixture: 'openai-error.1', modelId: 'gpt-4o', options: { prompt: TEST_PROMPT } },
  {
    name: 'reasoning-encrypted-content',
    fixture: 'openai-reasoning-encrypted-content.1',
    modelId: 'gpt-5-mini',
    options: { prompt: TEST_PROMPT, tools: codeInterpreter },
  },
  { name: 'parallel-tool-call-wrapper', fixture: 'parallel-tool-call-wrapper.1', modelId: 'gpt-5.4', options: { prompt: TEST_PROMPT, tools: TEST_TOOLS } },
  { name: 'code-interpreter', fixture: 'openai-code-interpreter-tool.1', modelId: 'gpt-5-nano', options: { prompt: TEST_PROMPT, tools: codeInterpreter } },
  {
    name: 'image-generation',
    fixture: 'openai-image-generation-tool.1',
    modelId: 'gpt-5-nano',
    options: {
      prompt: TEST_PROMPT,
      tools: [
        {
          type: 'provider',
          id: 'openai.image_generation',
          name: 'generateImage',
          args: { outputFormat: 'webp', quality: 'low', size: '1024x1024', partialImages: 2 },
        },
      ],
    },
  },
  { name: 'hosted-tool-search', fixture: 'openai-tool-search.1', modelId: 'gpt-5-nano', options: { prompt: TEST_PROMPT, tools: HOSTED_TOOL_SEARCH_TOOLS } },
  {
    name: 'client-tool-search',
    fixture: 'openai-client-tool-search.1',
    modelId: 'gpt-5.4',
    options: { prompt: TEST_PROMPT, tools: CLIENT_TOOL_SEARCH_TOOLS, providerOptions: { openai: { store: false } } },
  },
  {
    name: 'client-tool-search-2',
    fixture: 'openai-client-tool-search.2',
    modelId: 'gpt-5.4',
    options: { prompt: TEST_PROMPT, tools: CLIENT_TOOL_SEARCH_TOOLS, providerOptions: { openai: { store: false } } },
  },
  {
    name: 'local-shell',
    fixture: 'openai-local-shell-tool.1',
    modelId: 'gpt-5-codex',
    options: { prompt: TEST_PROMPT, tools: [{ type: 'provider', id: 'openai.local_shell', name: 'shell', args: {} }] },
  },
  {
    name: 'web-search',
    fixture: 'openai-web-search-tool.1',
    modelId: 'gpt-5-nano',
    options: {
      prompt: TEST_PROMPT,
      tools: [{ type: 'provider', id: 'openai.web_search', name: 'webSearch', args: { filters: { blockedDomains: ['example.com'] } } }],
    },
  },
  { name: 'shell', fixture: 'openai-shell-tool.1', modelId: 'gpt-5.1', options: { prompt: TEST_PROMPT, tools: localShellTool } },
  { name: 'shell-container', fixture: 'openai-shell-container.1', modelId: 'gpt-5.2', options: { prompt: TEST_PROMPT, tools: containerShell } },
  {
    name: 'shell-container-multiturn',
    fixture: 'openai-shell-container-multiturn.1',
    modelId: 'gpt-5.2',
    options: { prompt: containerMultiturnPrompt, tools: containerShell },
  },
  {
    name: 'shell-local-multiturn',
    fixture: 'openai-shell-local-multiturn.1',
    modelId: 'gpt-5.2',
    options: { prompt: localMultiturnPrompt, tools: localShellTool },
  },
  { name: 'shell-skills', fixture: 'openai-shell-skills.1', modelId: 'gpt-5.2', options: { prompt: TEST_PROMPT, tools: containerShell } },
  {
    name: 'mcp',
    fixture: 'openai-mcp-tool.1',
    modelId: 'gpt-5-mini',
    options: {
      prompt: TEST_PROMPT,
      tools: [
        {
          type: 'provider',
          id: 'openai.mcp',
          name: 'MCP',
          args: { serverLabel: 'dmcp', serverUrl: 'https://mcp.exa.ai/mcp', serverDescription: 'A web-search API for AI agents' },
        },
      ],
    },
  },
  { name: 'mcp-approval-1', fixture: 'openai-mcp-tool-approval.1', modelId: 'gpt-5-mini', options: { prompt: TEST_PROMPT, tools: mcpApprovalTool } },
  {
    name: 'mcp-approval-2',
    fixture: 'openai-mcp-tool-approval.2',
    modelId: 'gpt-5-mini',
    options: { prompt: [shortenPrompt, mcpApprovalCall(deniedId), mcpApprovalResponse(deniedId, false)], tools: mcpApprovalTool },
  },
  {
    name: 'mcp-approval-3',
    fixture: 'openai-mcp-tool-approval.3',
    modelId: 'gpt-5-mini',
    options: {
      prompt: [
        shortenPrompt,
        mcpApprovalCall(deniedId),
        mcpApprovalResponse(deniedId, false),
        { role: 'assistant', content: [{ type: 'text', text: 'The tool was not approved.' }] },
        { role: 'user', content: [{ type: 'text', text: 'try again' }] },
      ],
      tools: mcpApprovalTool,
    },
  },
  {
    name: 'mcp-approval-4',
    fixture: 'openai-mcp-tool-approval.4',
    modelId: 'gpt-5-mini',
    options: { prompt: [shortenPrompt, mcpApprovalCall(approvedId), mcpApprovalResponse(approvedId, true)], tools: mcpApprovalTool },
  },
  { name: 'file-search', fixture: 'openai-file-search-tool.1', modelId: 'gpt-5-nano', options: { prompt: TEST_PROMPT, tools: fileSearch } },
  {
    name: 'file-search-results',
    fixture: 'openai-file-search-tool.2',
    modelId: 'gpt-5-nano',
    options: { prompt: TEST_PROMPT, tools: fileSearch, providerOptions: { openai: { include: ['file_search_call.results'] } } },
  },
  { name: 'apply-patch', fixture: 'openai-apply-patch-tool.1', modelId: 'gpt-5.1-2025-11-13', options: { prompt: TEST_PROMPT, tools: applyPatch } },
  {
    name: 'apply-patch-delete',
    fixture: 'openai-apply-patch-tool-delete.1',
    modelId: 'gpt-5.1-2025-11-13',
    options: { prompt: TEST_PROMPT, tools: applyPatch },
    modes: ['stream'],
  },
  {
    name: 'custom-tool',
    fixture: 'openai-custom-tool.1',
    modelId: 'gpt-5.2-codex',
    options: {
      prompt: TEST_PROMPT,
      tools: [
        {
          type: 'provider',
          id: 'openai.custom',
          name: 'write_sql',
          args: {
            description: 'Write a SQL SELECT query to answer the user question.',
            format: { type: 'grammar', syntax: 'regex', definition: 'SELECT .+' },
          },
        },
      ],
    },
  },
  {
    name: 'compaction',
    fixture: 'openai-compaction.1',
    modelId: 'gpt-5.2',
    options: {
      prompt: [
        {
          role: 'assistant',
          content: [
            {
              type: 'custom',
              kind: 'openai.compaction',
              providerOptions: { openai: { type: 'compaction', itemId: 'cmp_123', encryptedContent: 'encrypted_compaction_state' } },
            },
          ],
        },
        { role: 'user', content: [{ type: 'text', text: 'Continue from this context.' }] },
      ],
      providerOptions: { openai: { store: false, compactionTrigger: true } },
    },
  },
  { name: 'phase', fixture: 'openai-phase.1', modelId: 'gpt-5.3-codex', options: { prompt: TEST_PROMPT } },
  {
    name: 'id-rotation',
    fixture: 'github-copilot-id-rotation.1',
    modelId: 'gpt-5.3-codex',
    options: { prompt: TEST_PROMPT, providerOptions: { openai: { reasoningEffort: 'low', reasoningSummary: 'detailed', store: false } } },
    modes: ['stream'],
  },
  ...[1, 2, 3].map(step => ({
    name: `programmatic-${step}`,
    fixture: `programmatic-tool-calling.${step}`,
    modelId: 'gpt-5.5',
    options: { prompt: TEST_PROMPT, tools: programmaticTools },
  })),
  {
    name: 'settings-and-warnings',
    fixture: 'openai-phase.1',
    modelId: 'o4-mini',
    options: {
      prompt: [
        { role: 'system', content: 'Be brief.' },
        {
          role: 'user',
          content: [
            { type: 'text', text: 'Hello' },
            { type: 'file', mediaType: 'image/png', data: { type: 'data', data: 'AAECAw==' } },
            { type: 'file', mediaType: 'application/pdf', data: { type: 'data', data: 'AAECAw==' }, filename: 'doc.pdf' },
            { type: 'file', mediaType: 'image/png', data: { type: 'data', data: 'file-abc123' } },
            { type: 'file', mediaType: 'application/pdf', data: { type: 'url', url: new URL('https://example.com/a.pdf') } },
          ],
        },
      ],
      temperature: 0.5,
      topP: 0.9,
      topK: 3,
      seed: 1,
      presencePenalty: 0.1,
      frequencyPenalty: 0.2,
      stopSequences: ['END'],
      maxOutputTokens: 100,
      responseFormat: { type: 'json', schema: { type: 'object', properties: { a: { type: 'string' } } }, name: 'answer' },
      providerOptions: {
        openai: {
          reasoningEffort: 'high',
          store: false,
          logprobs: 3,
          metadata: { run: 'x' },
          serviceTier: 'flex',
          textVerbosity: 'low',
          previousResponseId: 'resp_1',
          conversation: 'conv_1',
          instructions: 'Be kind.',
          promptCacheKey: 'k',
          maxToolCalls: 2,
          parallelToolCalls: false,
          user: 'u',
          safetyIdentifier: 's',
          truncation: 'auto',
          contextManagement: [{ type: 'compaction', compactThreshold: 5000 }],
        },
      },
      tools: TEST_TOOLS,
      toolChoice: { type: 'tool', toolName: 'weather' },
    },
    modes: ['generate'],
  },
  {
    name: 'gpt6-reasoning-update',
    fixture: 'openai-phase.1',
    modelId: 'gpt-6-sol',
    options: {
      prompt: [
        { role: 'user', content: [{ type: 'text', text: 'Hi' }] },
        { role: 'system', content: '', providerOptions: { openai: { reasoningEffortUpdate: 'high' } } },
        { role: 'user', content: [{ type: 'text', text: 'Think harder' }] },
      ],
      temperature: 0.2,
      providerOptions: {
        openai: {
          reasoningEffort: 'none',
          reasoningEffortUpdate: 'low',
          logprobs: true,
          promptCacheRetention: '24h',
          allowedTools: { toolNames: ['weather', 'missing'], mode: 'required' },
        },
      },
      tools: [
        ...TEST_TOOLS,
        {
          type: 'function',
          name: 'lookup',
          inputSchema: { type: 'object', properties: {} },
          providerOptions: { openai: { namespace: { name: 'crm', description: 'CRM tools' }, async: true } },
        },
      ],
    },
    modes: ['generate'],
  },
];

function fixtureResponse(fixture: string, mode: 'generate' | 'stream'): Response | undefined {
  if (mode === 'generate') {
    const file = path.join(fixtures, `${fixture}.json`);
    if (!fs.existsSync(file)) return undefined;
    return new Response(fs.readFileSync(file, 'utf8'), { status: 200, headers: { 'content-type': 'application/json' } });
  }
  const file = path.join(fixtures, `${fixture}.chunks.txt`);
  if (!fs.existsSync(file)) return undefined;
  const chunks = fs
    .readFileSync(file, 'utf8')
    .split('\n')
    .filter(line => line.trim().length > 0)
    .map(line => `data: ${line}\n\n`);
  chunks.push('data: [DONE]\n\n');
  const encoder = new TextEncoder();
  const body = new ReadableStream({
    start(controller) {
      for (const chunk of chunks) controller.enqueue(encoder.encode(chunk));
      controller.close();
    },
  });
  return new Response(body, { status: 200, headers: { 'content-type': 'text/event-stream' } });
}

const plain = (value: unknown) => JSON.parse(JSON.stringify(value ?? null));

function normalizePart(part: any) {
  if (part.type === 'error') {
    return { type: 'error', message: part.error?.message ?? JSON.stringify(part.error) };
  }
  return plain(part);
}

function errorInfo(error: any) {
  return { message: error.message, statusCode: error.statusCode ?? null, isRetryable: error.isRetryable ?? null };
}

const output: unknown[] = [];
for (const testCase of cases) {
  for (const mode of testCase.modes ?? (['generate', 'stream'] as const)) {
    const response = fixtureResponse(testCase.fixture, mode);
    if (response == null) continue;
    let requestBody: unknown;
    let counter = 0;
    const model = new OpenAIResponsesLanguageModel(testCase.modelId, {
      provider: 'openai',
      url: ({ path: p }: { path: string }) => `https://api.openai.com/v1${p}`,
      headers: () => ({ Authorization: 'Bearer APIKEY' }),
      generateId: () => `id-${counter++}`,
      fileIdPrefixes: ['file-'],
      fetch: async (_url: string, init: RequestInit) => {
        requestBody = JSON.parse(String(init.body));
        return response;
      },
    });
    const entry: Record<string, unknown> = { name: testCase.name, fixture: testCase.fixture, mode, modelId: testCase.modelId, options: testCase.options };
    try {
      if (mode === 'generate') {
        const result = await model.doGenerate(testCase.options);
        Object.assign(entry, {
          content: plain(result.content),
          finishReason: plain(result.finishReason),
          usage: plain(result.usage),
          providerMetadata: plain(result.providerMetadata),
          warnings: plain(result.warnings),
        });
      } else {
        const result = await model.doStream(testCase.options);
        const parts: unknown[] = [];
        const reader = result.stream.getReader();
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          parts.push(normalizePart(value));
        }
        entry.parts = parts;
      }
    } catch (error) {
      entry.error = errorInfo(error);
    }
    entry.requestBody = plain(requestBody);
    output.push(entry);
  }
}

fs.writeFileSync(path.join(fixtures, 'openai-responses-conformance.json'), JSON.stringify(output, null, 1) + '\n');
console.log(`wrote ${output.length} cases`);
