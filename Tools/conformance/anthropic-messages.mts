// Generates Tests/AISDKAnthropicTests/Fixtures/anthropic-conformance.json by
// running the upstream TypeScript AnthropicLanguageModel on its recorded API
// responses (copied to Tests/AISDKAnthropicTests/Fixtures/upstream) and on
// request-only cases. The Swift tests replay the same cases and compare
// request bodies, betas, content, stream parts, usage and provider metadata.
import * as fs from 'node:fs';
import * as path from 'node:path';

const upstream = process.env.UPSTREAM!;
const repo = path.resolve(import.meta.dirname, '../..');
const fixturesDir = path.join(repo, 'Tests/AISDKAnthropicTests/Fixtures');
const upstreamFixtures = path.join(upstream, 'packages/anthropic/src/__fixtures__');
const copiedFixtures = path.join(fixturesDir, 'upstream');

const { AnthropicLanguageModel } = await import(path.join(upstream, 'packages/anthropic/src/anthropic-language-model.ts'));

fs.rmSync(copiedFixtures, { recursive: true, force: true });
fs.mkdirSync(copiedFixtures, { recursive: true });
for (const file of fs.readdirSync(upstreamFixtures)) {
  if (file.endsWith('.json') || file.endsWith('.chunks.txt')) {
    fs.copyFileSync(path.join(upstreamFixtures, file), path.join(copiedFixtures, file));
  }
}

const TEST_PROMPT = [{ role: 'user', content: [{ type: 'text', text: 'Hello' }] }];
const provider = (id: string, args: Record<string, unknown> = {}, name?: string) => ({
  type: 'provider',
  id: `anthropic.${id}`,
  name: name ?? id.replace(/_\d+$/, ''),
  args,
});
const fn = (name: string, extra: Record<string, unknown> = {}) => ({
  type: 'function',
  name,
  description: `The ${name} tool`,
  inputSchema: { type: 'object', properties: { city: { type: 'string' } }, required: ['city'] },
  ...extra,
});
const deferred = (name: string) => fn(name, { providerOptions: { anthropic: { deferLoading: true } } });

type Case = {
  name: string;
  fixture: string;
  modelId?: string;
  provider?: string;
  modes?: Array<'generate' | 'stream'>;
  options: Record<string, unknown>;
};

const fixtureCases: Case[] = [
  { name: 'text', fixture: 'anthropic-text', options: { prompt: TEST_PROMPT } },
  { name: 'refusal', fixture: 'anthropic-refusal', options: { prompt: TEST_PROMPT } },
  { name: 'refusal-no-details', fixture: 'anthropic-refusal-no-details', options: { prompt: TEST_PROMPT } },
  { name: 'tool-no-args', fixture: 'anthropic-tool-no-args', options: { prompt: TEST_PROMPT, tools: [fn('getTime')] } },
  { name: 'message-delta-input-tokens', fixture: 'anthropic-message-delta-input-tokens', options: { prompt: TEST_PROMPT } },
  { name: 'duplicate-message-start', fixture: 'duplicate-message-start', options: { prompt: TEST_PROMPT } },
  { name: 'spliced-message-start', fixture: 'spliced-message-start', options: { prompt: TEST_PROMPT } },
  {
    name: 'json-output-format',
    fixture: 'anthropic-json-output-format.1',
    options: {
      prompt: TEST_PROMPT,
      responseFormat: {
        type: 'json',
        schema: {
          type: 'object',
          properties: { name: { type: 'string', minLength: 2, format: 'email' }, tags: { type: 'array', items: { type: 'string' }, maxItems: 3 } },
          required: ['name'],
        },
      },
    },
  },
  {
    name: 'json-tool',
    fixture: 'anthropic-json-tool.1',
    options: {
      prompt: TEST_PROMPT,
      responseFormat: { type: 'json', schema: { type: 'object', properties: { elements: { type: 'array' } } } },
      providerOptions: { anthropic: { structuredOutputMode: 'jsonTool', disableParallelToolUse: false } },
    },
  },
  {
    name: 'json-tool-2',
    fixture: 'anthropic-json-tool.2',
    modes: ['stream'],
    options: {
      prompt: TEST_PROMPT,
      responseFormat: { type: 'json', schema: { type: 'object' } },
      providerOptions: { anthropic: { structuredOutputMode: 'jsonTool' } },
    },
  },
  {
    name: 'json-other-tool',
    fixture: 'anthropic-json-other-tool.1',
    options: {
      prompt: TEST_PROMPT,
      tools: [fn('weather')],
      responseFormat: { type: 'json', schema: { type: 'object' } },
      providerOptions: { anthropic: { structuredOutputMode: 'jsonTool' } },
    },
  },
  {
    name: 'web-search',
    fixture: 'anthropic-web-search-tool.1',
    options: {
      prompt: TEST_PROMPT,
      tools: [
        provider('web_search_20250305', {
          maxUses: 2,
          allowedDomains: ['swift.org'],
          userLocation: { type: 'approximate', city: 'Berlin', country: 'DE' },
        }, 'web_search'),
      ],
    },
  },
  {
    name: 'web-fetch',
    fixture: 'anthropic-web-fetch-tool.1',
    options: {
      prompt: TEST_PROMPT,
      tools: [provider('web_fetch_20250910', { maxUses: 1, citations: { enabled: true }, maxContentTokens: 5000 }, 'web_fetch')],
    },
  },
  { name: 'web-fetch-2', fixture: 'anthropic-web-fetch-tool.2', options: { prompt: TEST_PROMPT, tools: [provider('web_fetch_20250910', {}, 'web_fetch')] } },
  {
    name: 'web-fetch-error',
    fixture: 'anthropic-web-fetch-tool.error',
    options: { prompt: TEST_PROMPT, tools: [provider('web_fetch_20250910', {}, 'fetch')] },
  },
  {
    name: 'web-fetch-20260209',
    fixture: 'anthropic-web-fetch-tool-20260209.1',
    options: { prompt: TEST_PROMPT, tools: [provider('web_fetch_20260209', { maxUses: 3 }, 'web_fetch')] },
  },
  {
    name: 'code-execution-20250825',
    fixture: 'anthropic-code-execution-20250825.1',
    options: { prompt: TEST_PROMPT, tools: [provider('code_execution_20250825', {}, 'code_execution')] },
  },
  {
    name: 'code-execution-20250825-2',
    fixture: 'anthropic-code-execution-20250825.2',
    options: { prompt: TEST_PROMPT, tools: [provider('code_execution_20250825', {}, 'codeRunner')] },
  },
  {
    name: 'code-execution-pptx-skill',
    fixture: 'anthropic-code-execution-20250825.pptx-skill',
    options: {
      prompt: TEST_PROMPT,
      tools: [provider('code_execution_20250825', {}, 'code_execution')],
      providerOptions: {
        anthropic: {
          container: {
            skills: [
              { type: 'anthropic', skillId: 'pptx', version: 'latest' },
              { type: 'custom', providerReference: { anthropic: 'skill_01' } },
            ],
          },
        },
      },
    },
  },
  {
    name: 'code-execution-20260120-prompt-cache',
    fixture: 'anthropic-code-execution-20260120-prompt-cache.1',
    options: { prompt: TEST_PROMPT, tools: [provider('code_execution_20260120', {}, 'code_execution')] },
  },
  {
    name: 'code-execution-file-upload',
    fixture: 'anthropic-code-execution-file-upload.1',
    options: {
      prompt: [
        {
          role: 'user',
          content: [
            { type: 'file', mediaType: 'text/csv', data: { type: 'reference', reference: { anthropic: 'file_1' } }, providerOptions: { anthropic: { containerUpload: true } } },
            { type: 'text', text: 'Analyze the file' },
          ],
        },
      ],
      tools: [provider('code_execution_20250825', {}, 'code_execution')],
    },
  },
  {
    name: 'programmatic-tool-calling',
    fixture: 'anthropic-programmatic-tool-calling.1',
    options: {
      prompt: TEST_PROMPT,
      tools: [
        provider('code_execution_20250825', {}, 'code_execution'),
        fn('rollDie', { providerOptions: { anthropic: { allowedCallers: ['code_execution_20250825'] } } }),
      ],
    },
  },
  {
    name: 'tool-search-regex',
    fixture: 'anthropic-tool-search-regex.1',
    options: { prompt: TEST_PROMPT, tools: [provider('tool_search_regex_20251119', {}, 'toolSearch'), deferred('get_weather'), deferred('get_time')] },
  },
  {
    name: 'tool-search-bm25',
    fixture: 'anthropic-tool-search-bm25.1',
    options: { prompt: TEST_PROMPT, tools: [provider('tool_search_bm25_20251119', {}, 'toolSearch'), deferred('get_weather')] },
  },
  {
    name: 'tool-search-deferred-regex',
    fixture: 'anthropic-tool-search-deferred-regex',
    modes: ['stream'],
    options: { prompt: TEST_PROMPT, tools: [provider('tool_search_regex_20251119', {}, 'tool_search_tool_regex'), deferred('get_weather')] },
  },
  {
    name: 'tool-search-deferred-regex-2',
    fixture: 'anthropic-tool-search-deferred-regex.2',
    options: { prompt: TEST_PROMPT, tools: [provider('tool_search_regex_20251119', {}, 'tool_search_tool_regex'), deferred('get_weather')] },
  },
  {
    name: 'tool-search-deferred-bm25',
    fixture: 'anthropic-tool-search-deferred-bm25',
    modes: ['stream'],
    options: { prompt: TEST_PROMPT, tools: [deferred('get_weather')] },
  },
  {
    name: 'tool-search-deferred-bm25-2',
    fixture: 'anthropic-tool-search-deferred-bm25.2',
    options: { prompt: TEST_PROMPT, tools: [provider('tool_search_bm25_20251119', {}, 'search'), deferred('get_weather')] },
  },
  {
    name: 'mcp',
    fixture: 'anthropic-mcp.1',
    options: {
      prompt: TEST_PROMPT,
      providerOptions: {
        anthropic: {
          mcpServers: [
            {
              type: 'url',
              name: 'echo',
              url: 'https://echo.example.com/mcp',
              authorizationToken: 'token',
              toolConfiguration: { enabled: true, allowedTools: ['echo'] },
            },
          ],
        },
      },
    },
  },
  {
    name: 'memory',
    fixture: 'anthropic-memory-20250818.1',
    options: { prompt: TEST_PROMPT, tools: [provider('memory_20250818', {}, 'memory')] },
  },
  {
    name: 'advisor',
    fixture: 'anthropic-advisor-20260301.1',
    modelId: 'claude-sonnet-4-6',
    options: {
      prompt: TEST_PROMPT,
      tools: [provider('advisor_20260301', { model: 'claude-opus-5', maxUses: 2, maxTokens: 2048, caching: { type: 'ephemeral', ttl: '5m' } }, 'advisor')],
    },
  },
  {
    name: 'advisor-stream',
    fixture: 'anthropic-advisor-20250301.1',
    modes: ['stream'],
    modelId: 'claude-sonnet-4-6',
    options: { prompt: TEST_PROMPT, tools: [provider('advisor_20260301', { model: 'claude-opus-5' }, 'askAdvisor')] },
  },
  {
    name: 'advisor-stop-reasons',
    fixture: 'anthropic-advisor-stop-reasons',
    modelId: 'claude-sonnet-4-6',
    options: { prompt: TEST_PROMPT, tools: [provider('advisor_20260301', { model: 'claude-opus-5' }, 'advisor')] },
  },
  {
    name: 'clear-tool-uses',
    fixture: 'anthropic-clear-tool-uses.1',
    options: {
      prompt: TEST_PROMPT,
      providerOptions: {
        anthropic: {
          contextManagement: {
            edits: [
              {
                type: 'clear_tool_uses_20250919',
                trigger: { type: 'input_tokens', value: 1000 },
                keep: { type: 'tool_uses', value: 1 },
                clearAtLeast: { type: 'input_tokens', value: 500 },
                clearToolInputs: true,
                excludeTools: ['important'],
              },
            ],
          },
        },
      },
    },
  },
  {
    name: 'clear-thinking',
    fixture: 'anthropic-clear-thinking.1',
    options: {
      prompt: TEST_PROMPT,
      providerOptions: {
        anthropic: {
          thinking: { type: 'enabled', budgetTokens: 2000 },
          contextManagement: { edits: [{ type: 'clear_thinking_20251015', keep: { type: 'thinking_turns', value: 1 } }] },
        },
      },
    },
  },
  {
    name: 'combined-context-editing',
    fixture: 'anthropic-combined-context-editing.1',
    options: {
      prompt: TEST_PROMPT,
      providerOptions: {
        anthropic: {
          contextManagement: {
            edits: [
              { type: 'clear_thinking_20251015', keep: 'all' },
              { type: 'clear_tool_uses_20250919' },
              { type: 'compact_20260112', trigger: { type: 'input_tokens', value: 50000 }, pauseAfterCompaction: true, instructions: 'Summarize.' },
            ],
          },
        },
      },
    },
  },
  {
    name: 'compaction',
    fixture: 'anthropic-compaction.1',
    options: { prompt: TEST_PROMPT, providerOptions: { anthropic: { compaction: { type: 'summarize', instructions: 'Be brief.' } } } },
  },
  {
    name: 'fallback',
    fixture: 'anthropic-fallback',
    options: {
      prompt: TEST_PROMPT,
      providerOptions: { anthropic: { fallbacks: [{ model: 'claude-sonnet-4-5', max_tokens: 2000 }] } },
    },
  },
  {
    name: 'opus-5-reasoning-high',
    fixture: 'anthropic-claude-opus-5-reasoning-high.1',
    modelId: 'claude-opus-5',
    options: { prompt: TEST_PROMPT, reasoning: 'high' },
  },
];

// Prompts with provider-executed tool calls and results in earlier turns.
const priorToolTurns = [
  { role: 'user', content: [{ type: 'text', text: 'Research this' }] },
  {
    role: 'assistant',
    content: [
      { type: 'reasoning', text: 'Thinking', providerOptions: { anthropic: { signature: 'sig' } } },
      { type: 'text', text: 'Searching.', providerOptions: { anthropic: { citations: [{ type: 'web_search_result_location', cited_text: 'x', url: 'https://a.b', title: null, encrypted_index: 'e' }] } } },
      { type: 'tool-call', toolCallId: 'ws1', toolName: 'web_search', input: { query: 'swift' }, providerExecuted: true },
      {
        type: 'tool-result',
        toolCallId: 'ws1',
        toolName: 'web_search',
        output: { type: 'json', value: [{ url: 'https://swift.org', title: 'Swift', pageAge: null, encryptedContent: 'enc', type: 'web_search_result' }] },
      },
      { type: 'tool-call', toolCallId: 'ws2', toolName: 'web_search', input: { query: 'x' }, providerExecuted: true },
      { type: 'tool-result', toolCallId: 'ws2', toolName: 'web_search', output: { type: 'error-json', value: { errorCode: 'max_uses_exceeded' } } },
      { type: 'tool-call', toolCallId: 'wf1', toolName: 'web_fetch', input: { url: 'https://swift.org' }, providerExecuted: true },
      {
        type: 'tool-result',
        toolCallId: 'wf1',
        toolName: 'web_fetch',
        output: {
          type: 'json',
          value: {
            type: 'web_fetch_result',
            url: 'https://swift.org',
            retrievedAt: '2026-01-01',
            content: { type: 'document', title: 'Swift', citations: { enabled: true }, source: { type: 'text', mediaType: 'text/plain', data: 'Hello' } },
          },
        },
      },
      { type: 'tool-call', toolCallId: 'ce1', toolName: 'code_execution', input: { type: 'bash_code_execution', command: 'ls' }, providerExecuted: true },
      {
        type: 'tool-result',
        toolCallId: 'ce1',
        toolName: 'code_execution',
        output: { type: 'json', value: { type: 'bash_code_execution_result', stdout: 'a', stderr: '', return_code: 0, content: [] } },
      },
      { type: 'tool-call', toolCallId: 'ce2', toolName: 'code_execution', input: { type: 'text_editor_code_execution', command: 'view', path: '/a' }, providerExecuted: true },
      {
        type: 'tool-result',
        toolCallId: 'ce2',
        toolName: 'code_execution',
        output: { type: 'json', value: { type: 'text_editor_code_execution_view_result', content: 'x', file_type: 'text', num_lines: 1, start_line: 1, total_lines: 1 } },
      },
      { type: 'tool-call', toolCallId: 'ce3', toolName: 'code_execution', input: { type: 'programmatic-tool-call', code: 'print(1)' }, providerExecuted: true },
      {
        type: 'tool-result',
        toolCallId: 'ce3',
        toolName: 'code_execution',
        output: { type: 'json', value: { type: 'code_execution_result', stdout: '1', stderr: '', return_code: 0 } },
      },
      { type: 'tool-call', toolCallId: 'ce4', toolName: 'code_execution', input: { type: 'bash_code_execution', command: 'x' }, providerExecuted: true },
      { type: 'tool-result', toolCallId: 'ce4', toolName: 'code_execution', output: { type: 'error-json', value: { type: 'bash_code_execution_tool_result_error', errorCode: 'unavailable' } } },
      { type: 'tool-call', toolCallId: 'ts1', toolName: 'toolSearch', input: { pattern: 'weather' }, providerExecuted: true },
      { type: 'tool-result', toolCallId: 'ts1', toolName: 'toolSearch', output: { type: 'json', value: [{ type: 'tool_reference', toolName: 'get_weather' }] } },
      { type: 'tool-call', toolCallId: 'ad1', toolName: 'advisor', input: {}, providerExecuted: true },
      { type: 'tool-result', toolCallId: 'ad1', toolName: 'advisor', output: { type: 'json', value: { type: 'advisor_result', text: 'Do X', stopReason: 'end_turn' } } },
      {
        type: 'tool-call',
        toolCallId: 'mcp1',
        toolName: 'echo',
        input: { message: 'hi' },
        providerExecuted: true,
        providerOptions: { anthropic: { type: 'mcp-tool-use', serverName: 'echo-server' } },
      },
      { type: 'tool-result', toolCallId: 'mcp1', toolName: 'echo', output: { type: 'json', value: [{ type: 'text', text: 'hi' }] } },
      { type: 'tool-call', toolCallId: 'unk', toolName: 'mystery', input: {}, providerExecuted: true },
      {
        type: 'tool-call',
        toolCallId: 'call1',
        toolName: 'rollDie',
        input: { player: 'a' },
        providerOptions: { anthropic: { caller: { type: 'code_execution_20250825', toolId: 'ce3' } } },
      },
      { type: 'tool-call', toolCallId: 'comp1', toolName: 'computerTools', input: { action: 'left_click', coordinate: [1, 2] } },
      { type: 'text', text: 'Compacted summary', providerOptions: { anthropic: { type: 'compaction', signature: 'csig' } } },
      { type: 'reasoning', text: '', providerOptions: { anthropic: { redactedData: 'redacted' } } },
      { type: 'text', text: '  trailing  ' },
    ],
  },
  {
    role: 'tool',
    content: [
      { type: 'tool-result', toolCallId: 'call1', toolName: 'rollDie', output: { type: 'json', value: { roll: 4 } } },
      { type: 'tool-result', toolCallId: 'comp1', toolName: 'computerTools', output: { type: 'content', value: [{ type: 'text', text: 'clicked' }, { type: 'file', mediaType: 'image/png', data: { type: 'data', data: 'iVBORw0KGgo=' } }] } },
      { type: 'tool-approval-response', approvalId: 'a', approved: true },
    ],
  },
];

const requestCases: Case[] = [
  {
    name: 'sampling-and-warnings',
    fixture: 'anthropic-text',
    modelId: 'claude-sonnet-4-5',
    options: { prompt: TEST_PROMPT, temperature: 1.5, topP: 0.5, topK: 3, seed: 1, presencePenalty: 0.1, frequencyPenalty: 0.2, stopSequences: ['END'], maxOutputTokens: 100000 },
  },
  {
    name: 'rejects-sampling',
    fixture: 'anthropic-text',
    modelId: 'claude-opus-4-7',
    options: { prompt: TEST_PROMPT, temperature: 0.5, topP: 0.5, topK: 3 },
  },
  { name: 'unknown-model', fixture: 'anthropic-text', modelId: 'custom-model', options: { prompt: TEST_PROMPT, temperature: -1 } },
  {
    name: 'thinking-enabled-default-budget',
    fixture: 'anthropic-text',
    options: { prompt: TEST_PROMPT, temperature: 0.5, providerOptions: { anthropic: { thinking: { type: 'enabled' } } } },
  },
  {
    name: 'adaptive-thinking-display-and-binding',
    fixture: 'anthropic-text',
    modelId: 'claude-opus-4-7',
    options: {
      prompt: TEST_PROMPT,
      providerOptions: {
        anthropic: {
          thinking: { type: 'adaptive', display: 'updates', blockBinding: { prefixMismatchBehavior: 'drop_block' } },
          effort: 'xhigh',
          taskBudget: { type: 'tokens', total: 30000, remaining: 20000 },
          speed: 'fast',
          serviceTier: 'standard_only',
          inferenceGeo: 'us',
          fallbacks: 'default',
          cacheControl: { type: 'ephemeral', ttl: '1h' },
          metadata: { userId: 'user-1' },
          safeguards: [{ type: 'dangerous_tool_use', classifierContext: { purpose: 'test' } }],
          anthropicBeta: ['custom-beta-1'],
        },
      },
    },
  },
  { name: 'reasoning-none', fixture: 'anthropic-text', modelId: 'claude-sonnet-4-5', options: { prompt: TEST_PROMPT, reasoning: 'none' } },
  { name: 'reasoning-low-budget', fixture: 'anthropic-text', modelId: 'claude-sonnet-4-5', options: { prompt: TEST_PROMPT, reasoning: 'low' } },
  { name: 'reasoning-xhigh-adaptive', fixture: 'anthropic-text', modelId: 'claude-sonnet-4-6', options: { prompt: TEST_PROMPT, reasoning: 'xhigh' } },
  { name: 'reasoning-none-rejected', fixture: 'anthropic-text', modelId: 'claude-opus-5-5', options: { prompt: TEST_PROMPT, reasoning: 'none' } },
  {
    name: 'thinking-disabled-rejected',
    fixture: 'anthropic-text',
    modelId: 'claude-fable-5',
    options: { prompt: TEST_PROMPT, providerOptions: { anthropic: { thinking: { type: 'disabled' } } } },
  },
  {
    name: 'high-effort-disabled-thinking',
    fixture: 'anthropic-text',
    modelId: 'claude-opus-5',
    options: { prompt: TEST_PROMPT, providerOptions: { anthropic: { thinking: { type: 'disabled' }, effort: 'max' } } },
  },
  {
    name: 'forced-tool-rejected',
    fixture: 'anthropic-text',
    modelId: 'claude-opus-5-5',
    options: { prompt: TEST_PROMPT, tools: [fn('weather'), fn('time')], toolChoice: { type: 'tool', toolName: 'weather' } },
  },
  {
    name: 'required-tool-rejected-json',
    fixture: 'anthropic-text',
    modelId: 'claude-opus-5-5',
    options: {
      prompt: TEST_PROMPT,
      tools: [fn('weather')],
      toolChoice: { type: 'required' },
      responseFormat: { type: 'json', schema: { type: 'object' } },
      providerOptions: { anthropic: { structuredOutputMode: 'jsonTool' } },
    },
  },
  {
    name: 'function-tool-options',
    fixture: 'anthropic-text',
    options: {
      prompt: TEST_PROMPT,
      tools: [
        fn('weather', { strict: true, inputExamples: [{ input: { city: 'Paris' } }], providerOptions: { anthropic: { cacheControl: { type: 'ephemeral' }, eagerInputStreaming: true } } }),
        fn('time', { providerOptions: { anthropic: { allowedCallers: ['direct'] } } }),
      ],
      toolChoice: { type: 'auto' },
      providerOptions: { anthropic: { disableParallelToolUse: true } },
    },
  },
  { name: 'strict-unsupported', fixture: 'anthropic-text', modelId: 'claude-3-haiku-20240307', options: { prompt: TEST_PROMPT, tools: [fn('weather', { strict: true })], toolChoice: { type: 'none' } } },
  {
    name: 'all-provider-tools',
    fixture: 'anthropic-text',
    options: {
      prompt: TEST_PROMPT,
      tools: [
        provider('code_execution_20250522', {}, 'ce1'),
        provider('computer_20241022', { displayWidthPx: 1024, displayHeightPx: 768, displayNumber: 1 }, 'c1'),
        provider('computer_20250124', { displayWidthPx: 800, displayHeightPx: 600 }, 'c2'),
        provider('computer_20251124', { displayWidthPx: 800, displayHeightPx: 600, enableZoom: true }, 'c3'),
        provider('computer_toolset_20260801', { configs: { zoom: { enabled: false }, wait: { deferLoading: true } } }, 'computerTools'),
        provider('text_editor_20241022', {}, 't1'),
        provider('text_editor_20250124', {}, 't2'),
        provider('text_editor_20250429', {}, 't3'),
        provider('text_editor_20250728', { maxCharacters: 1000 }, 't4'),
        provider('bash_20241022', {}, 'b1'),
        provider('bash_20250124', {}, 'b2'),
        provider('memory_20250818', {}, 'mem'),
        provider('web_fetch_20260318', { useCache: false, responseInclusion: 'excluded' }, 'wf'),
        provider('web_search_20260209', { blockedDomains: ['x.com'] }, 'ws1'),
        provider('web_search_20260318', { responseInclusion: 'full' }, 'ws2'),
        provider('advisor_20260301', { model: 'claude-opus-5' }, 'adv'),
        provider('unknown_tool_1', {}, 'unknown'),
      ],
    },
  },
  {
    name: 'dynamic-filtering-marks-code-execution-dynamic',
    fixture: 'anthropic-code-execution-20250825.1',
    options: { prompt: TEST_PROMPT, tools: [provider('web_search_20260209', {}, 'web_search')] },
  },
  {
    name: 'prompt-provider-tool-turns',
    fixture: 'anthropic-text',
    options: {
      prompt: priorToolTurns,
      tools: [
        provider('web_search_20250305', {}, 'web_search'),
        provider('web_fetch_20250910', {}, 'web_fetch'),
        provider('code_execution_20250825', {}, 'code_execution'),
        provider('tool_search_regex_20251119', {}, 'toolSearch'),
        provider('advisor_20260301', { model: 'claude-opus-5' }, 'advisor'),
        provider('computer_toolset_20260801', {}, 'computerTools'),
        fn('rollDie'),
      ],
      providerOptions: { anthropic: { sendReasoning: true } },
    },
  },
  {
    name: 'prompt-without-reasoning',
    fixture: 'anthropic-text',
    options: { prompt: priorToolTurns, providerOptions: { anthropic: { sendReasoning: false } } },
  },
  {
    name: 'prompt-system-messages',
    fixture: 'anthropic-text',
    options: {
      prompt: [
        { role: 'system', content: 'Be brief.', providerOptions: { anthropic: { cacheControl: { type: 'ephemeral' } } } },
        { role: 'system', content: '', providerOptions: { anthropic: { effort: 'low', toolChanges: [{ type: 'tool_addition', toolName: 'weather' }] } } },
        { role: 'user', content: [{ type: 'text', text: 'Hi' }] },
        { role: 'assistant', content: [{ type: 'text', text: 'Hello' }] },
        { role: 'system', content: 'Now use tools.', providerOptions: { anthropic: { clearAt: 'next_user_message', toolChanges: [{ type: 'tool_addition', toolName: 'web_search' }, { type: 'tool_removal', toolName: 'weather' }] } } },
        { role: 'system', content: '', providerOptions: { anthropic: { effort: 'high' } } },
        { role: 'user', content: [{ type: 'text', text: 'Go' }] },
      ],
      tools: [provider('web_search_20250305', {}, 'web_search'), fn('weather')],
    },
  },
  {
    name: 'prompt-effort-only-initial-system',
    fixture: 'anthropic-text',
    options: {
      prompt: [
        { role: 'system', content: 'initial instructions' },
        { role: 'system', content: '', providerOptions: { anthropic: { effort: 'low' } } },
        { role: 'system', content: 'ignored options', providerOptions: { anthropic: { clearAt: 'next_user_message' } } },
        { role: 'user', content: [{ type: 'text', text: 'Hi' }] },
      ],
    },
  },
  {
    name: 'prompt-files-and-cache',
    fixture: 'anthropic-text',
    options: {
      prompt: [
        {
          role: 'user',
          content: [
            { type: 'text', text: 'Look', providerOptions: { anthropic: { cacheControl: { type: 'ephemeral' } } } },
            { type: 'file', mediaType: 'image/png', data: { type: 'url', url: 'https://example.com/a.png' } },
            { type: 'file', mediaType: 'image/*', data: { type: 'data', data: 'iVBORw0KGgo=' } },
            { type: 'file', mediaType: 'application/pdf', filename: 'doc.pdf', data: { type: 'data', data: 'JVBERi0x' }, providerOptions: { anthropic: { citations: { enabled: true }, title: 'Doc', context: 'ctx' } } },
            { type: 'file', mediaType: 'application/pdf', data: { type: 'url', url: 'https://example.com/a.pdf' } },
            { type: 'file', mediaType: 'text/plain', data: { type: 'data', data: 'aGVsbG8=' }, filename: 'a.txt' },
            { type: 'file', mediaType: 'text/plain', data: { type: 'text', text: 'inline' } },
            { type: 'file', mediaType: 'image/png', data: { type: 'reference', reference: { anthropic: 'file_img' } } },
            { type: 'file', mediaType: 'application/pdf', data: { type: 'reference', reference: { anthropic: 'file_pdf' } } },
          ],
          providerOptions: { anthropic: { cacheControl: { type: 'ephemeral' } } },
        },
        { role: 'assistant', content: [{ type: 'text', text: 'Ok', providerOptions: { anthropic: { cacheControl: { type: 'ephemeral' } } } }], providerOptions: { anthropic: { cacheControl: { type: 'ephemeral' } } } },
        {
          role: 'user',
          content: [{ type: 'text', text: 'Again' }],
          providerOptions: { anthropic: { cacheControl: { type: 'ephemeral' } } },
        },
      ],
    },
  },
  {
    name: 'custom-provider-key',
    fixture: 'anthropic-text',
    provider: 'deepseek.messages',
    options: {
      prompt: TEST_PROMPT,
      providerOptions: { anthropic: { effort: 'low', sendReasoning: false }, deepseek: { effort: 'high' } },
    },
  },
  {
    name: 'compaction-with-context-management',
    fixture: 'anthropic-text',
    options: {
      prompt: TEST_PROMPT,
      providerOptions: { anthropic: { compaction: { type: 'summarize' }, contextManagement: { edits: [] } } },
    },
  },
  {
    name: 'skills-without-code-execution',
    fixture: 'anthropic-text',
    options: {
      prompt: TEST_PROMPT,
      providerOptions: { anthropic: { container: { id: 'container_1', skills: [{ type: 'anthropic', skillId: 'xlsx' }] } } },
    },
  },
  {
    name: 'container-id',
    fixture: 'anthropic-text',
    options: { prompt: TEST_PROMPT, providerOptions: { anthropic: { container: { id: 'container_1' }, fallbacks: [] } } },
  },
];

function fixtureResponse(fixture: string, mode: 'generate' | 'stream'): Response | undefined {
  if (mode === 'generate') {
    const file = path.join(upstreamFixtures, `${fixture}.json`);
    if (!fs.existsSync(file)) return undefined;
    return new Response(fs.readFileSync(file, 'utf8'), { status: 200, headers: { 'content-type': 'application/json' } });
  }
  const file = path.join(upstreamFixtures, `${fixture}.chunks.txt`);
  if (!fs.existsSync(file)) return undefined;
  const chunks = fs
    .readFileSync(file, 'utf8')
    .split('\n')
    .map(line => `data: ${line}\n\n`);
  chunks.push('data: [DONE]\n\n');
  const encoder = new TextEncoder();
  return new Response(
    new ReadableStream({
      start(controller) {
        for (const chunk of chunks) controller.enqueue(encoder.encode(chunk));
        controller.close();
      },
    }),
    { status: 200, headers: { 'content-type': 'text/event-stream' } },
  );
}

const plain = (value: unknown) => JSON.parse(JSON.stringify(value ?? null));
const normalizePart = (part: any) =>
  part.type === 'error' ? { type: 'error', message: part.error?.message ?? JSON.stringify(part.error) } : plain(part);

const output: unknown[] = [];
for (const testCase of [...fixtureCases, ...requestCases]) {
  for (const mode of testCase.modes ?? (['generate', 'stream'] as const)) {
    const response = fixtureResponse(testCase.fixture, mode);
    if (response == null) continue;
    let requestBody: unknown;
    let betas: string[] = [];
    let counter = 0;
    const model = new AnthropicLanguageModel(testCase.modelId ?? 'claude-sonnet-4-5', {
      provider: testCase.provider ?? 'anthropic.messages',
      baseURL: 'https://api.anthropic.com/v1',
      headers: () => ({ 'x-api-key': 'test-key', 'anthropic-version': '2023-06-01' }),
      generateId: () => `id-${counter++}`,
      fetch: async (_url: string, init: RequestInit) => {
        requestBody = JSON.parse(String(init.body));
        const header = (init.headers as Record<string, string>)['anthropic-beta'];
        betas = header ? header.split(',').sort() : [];
        return response;
      },
    });
    const entry: Record<string, unknown> = {
      name: testCase.name,
      fixture: testCase.fixture,
      mode,
      modelId: testCase.modelId ?? 'claude-sonnet-4-5',
      provider: testCase.provider ?? 'anthropic.messages',
      options: testCase.options,
    };
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
        for await (const part of result.stream as any) parts.push(normalizePart(part));
        entry.parts = parts;
      }
    } catch (error: any) {
      entry.error = { name: error.name, message: error.message };
    }
    entry.requestBody = plain(requestBody);
    entry.betas = betas;
    output.push(entry);
  }
}

fs.writeFileSync(path.join(fixturesDir, 'anthropic-conformance.json'), JSON.stringify(output, null, 1) + '\n');
console.log(`anthropic conformance: ${output.length} cases`);
