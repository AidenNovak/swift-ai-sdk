// Generates Tests/AISDKUITests/Fixtures/ui-conformance.json by running the
// upstream UI message stream, conversion, validation and chat code. The Swift
// tests replay the same inputs and compare the results.
import * as fs from 'node:fs';
import * as path from 'node:path';

const upstream = process.env.UPSTREAM!;
const repo = path.resolve(import.meta.dirname, '../..');
const outputDir = path.join(repo, 'Tests/AISDKUITests/Fixtures');
const ai = (file: string) => import(path.join(upstream, 'packages/ai/src', file));

const { processUIMessageStream, createStreamingUIMessageState } = await ai('ui/process-ui-message-stream.ts');
const { convertToModelMessages } = await ai('ui/convert-to-model-messages.ts');
const { safeValidateUIMessages } = await ai('ui/validate-ui-messages.ts');
const { lastAssistantMessageIsCompleteWithToolCalls } = await ai(
  'ui/last-assistant-message-is-complete-with-tool-calls.ts',
);
const { lastAssistantMessageIsCompleteWithApprovalResponses } = await ai(
  'ui/last-assistant-message-is-complete-with-approval-responses.ts',
);
const { AbstractChat } = await ai('ui/chat.ts');
const { createUIMessageStream } = await ai('ui-message-stream/create-ui-message-stream.ts');
const { toUIMessageStream } = await ai('ui-message-stream/to-ui-message-stream.ts');
const { streamText } = await ai('generate-text/stream-text.ts');
const { isStepCount } = await ai('generate-text/stop-condition.ts');
const { MockLanguageModelV4 } = await ai('test/mock-language-model-v4.ts');
const { jsonSchema, tool, dynamicTool } = await import(path.join(upstream, 'packages/provider-utils/src/index.ts'));

const plain = (value: unknown) => (value === undefined ? undefined : JSON.parse(JSON.stringify(value)));
const errorJSON = (error: any) => ({ name: error?.name, message: error?.message, chunkType: error?.chunkType, chunkId: error?.chunkId });
const streamOf = <T,>(items: T[]) =>
  new ReadableStream<T>({
    start(controller) {
      for (const item of items) controller.enqueue(item);
      controller.close();
    },
  });
const collect = async <T,>(stream: ReadableStream<T>) => {
  const items: T[] = [];
  for await (const item of stream as any) items.push(item);
  return items;
};
const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));

// A tool input validator shared with the Swift tests: `city` must be a string.
const cityValidator = (value: any) =>
  typeof value?.city === 'string'
    ? { success: true as const, value }
    : { success: false as const, error: new Error('city must be a string') };
const citySchema = () =>
  jsonSchema({ type: 'object', properties: { city: { type: 'string' } }, required: ['city'] }, { validate: cityValidator });

// MARK: - processUIMessageStream

type ProcessCase = { name: string; message?: unknown; chunks: any[] };

const usage = { inputTokens: { total: 3 }, outputTokens: { total: 5 } };

const processCases: ProcessCase[] = [
  {
    name: 'text',
    chunks: [
      { type: 'start', messageId: 'msg-1' },
      { type: 'start-step' },
      { type: 'text-start', id: 't1' },
      { type: 'text-delta', id: 't1', delta: 'Hello' },
      { type: 'text-delta', id: 't1', delta: ', world' },
      { type: 'text-end', id: 't1' },
      { type: 'finish-step' },
      { type: 'finish', finishReason: 'stop' },
    ],
  },
  {
    name: 'reasoning-and-text-metadata',
    chunks: [
      { type: 'start' },
      { type: 'start-step' },
      { type: 'reasoning-start', id: 'r1', providerMetadata: { p: { a: 1 } } },
      { type: 'reasoning-delta', id: 'r1', delta: 'Think' },
      { type: 'reasoning-delta', id: 'r1', delta: 'ing', providerMetadata: { p: { b: 2 } } },
      { type: 'reasoning-end', id: 'r1' },
      { type: 'text-start', id: 't1' },
      { type: 'text-delta', id: 't1', delta: 'Answer' },
      { type: 'text-end', id: 't1', providerMetadata: { p: { done: true } } },
      { type: 'finish-step' },
      { type: 'finish' },
    ],
  },
  {
    name: 'static-tool-streaming',
    chunks: [
      { type: 'start' },
      { type: 'start-step' },
      { type: 'tool-input-start', toolCallId: 'c1', toolName: 'weather', title: 'Weather' },
      { type: 'tool-input-delta', toolCallId: 'c1', inputTextDelta: '{"city":' },
      { type: 'tool-input-delta', toolCallId: 'c1', inputTextDelta: '"Par' },
      { type: 'tool-input-delta', toolCallId: 'c1', inputTextDelta: 'is"}' },
      {
        type: 'tool-input-available',
        toolCallId: 'c1',
        toolName: 'weather',
        input: { city: 'Paris' },
        providerMetadata: { p: { call: 1 } },
      },
      { type: 'tool-output-available', toolCallId: 'c1', output: { temperature: 20 }, providerMetadata: { p: { result: 1 } } },
      { type: 'finish-step' },
      { type: 'finish', finishReason: 'tool-calls' },
    ],
  },
  {
    name: 'dynamic-tool-error',
    chunks: [
      { type: 'start-step' },
      {
        type: 'tool-input-start',
        toolCallId: 'c1',
        toolName: 'mcp_search',
        dynamic: true,
        toolMetadata: { server: 'docs' },
      },
      { type: 'tool-input-delta', toolCallId: 'c1', inputTextDelta: '{"q":"swift"}' },
      { type: 'tool-input-available', toolCallId: 'c1', toolName: 'mcp_search', input: { q: 'swift' }, dynamic: true },
      { type: 'tool-output-error', toolCallId: 'c1', errorText: 'Server unavailable' },
    ],
  },
  {
    name: 'tool-input-error',
    chunks: [
      { type: 'start-step' },
      { type: 'tool-input-error', toolCallId: 'c1', toolName: 'weather', input: '{"city":', errorText: 'Invalid JSON' },
      { type: 'tool-input-start', toolCallId: 'c2', toolName: 'lookup', dynamic: true },
      { type: 'tool-input-error', toolCallId: 'c2', toolName: 'lookup', input: { id: 1 }, errorText: 'Bad input' },
      { type: 'tool-input-error', toolCallId: 'c3', toolName: 'other', input: {}, errorText: 'No tool', dynamic: true },
    ],
  },
  {
    name: 'approval-denied',
    chunks: [
      { type: 'start-step' },
      { type: 'tool-input-available', toolCallId: 'c1', toolName: 'delete_file', input: { path: '/tmp/x' } },
      {
        type: 'tool-approval-request',
        approvalId: 'a1',
        toolCallId: 'c1',
        reason: 'Deletes a file',
        isAutomatic: false,
        signature: 'sig',
        approvalDescriptor: { risk: 'high' },
      },
      { type: 'tool-approval-response', approvalId: 'a1', approved: false, reason: 'Not now' },
      { type: 'tool-output-denied', toolCallId: 'c1' },
    ],
  },
  {
    name: 'approval-granted-provider-executed',
    chunks: [
      { type: 'start-step' },
      {
        type: 'tool-input-available',
        toolCallId: 'c1',
        toolName: 'web_search',
        input: { query: 'swift' },
        providerExecuted: true,
      },
      { type: 'tool-approval-request', approvalId: 'a1', toolCallId: 'c1', isAutomatic: true },
      { type: 'tool-approval-response', approvalId: 'a1', approved: true, providerMetadata: { p: { x: 1 } } },
      { type: 'tool-output-available', toolCallId: 'c1', output: [{ url: 'https://swift.org' }], providerExecuted: true },
    ],
  },
  {
    name: 'data-parts',
    chunks: [
      { type: 'data-weather', id: 'w1', data: { status: 'loading' } },
      { type: 'data-weather', id: 'w1', data: { status: 'done', temperature: 21 } },
      { type: 'data-notice', data: 'transient!', transient: true },
      { type: 'data-log', data: 'one' },
      { type: 'data-log', data: 'two' },
      { type: 'data-weather', id: 'w2', data: { status: 'loading' } },
    ],
  },
  {
    name: 'message-metadata-merge',
    chunks: [
      { type: 'start', messageId: 'm1', messageMetadata: { a: 1, nested: { x: 1 }, list: [1, 2] } },
      { type: 'message-metadata', messageMetadata: { nested: { y: 2 }, list: [3] } },
      { type: 'finish', finishReason: 'length', messageMetadata: { b: 2 } },
    ],
  },
  {
    name: 'sources-files-custom',
    chunks: [
      { type: 'start-step' },
      { type: 'source-url', sourceId: 's1', url: 'https://example.com', title: 'Example' },
      { type: 'source-document', sourceId: 's2', mediaType: 'application/pdf', title: 'Doc', filename: 'doc.pdf' },
      { type: 'file', url: 'data:image/png;base64,iVBORw0KGgo=', mediaType: 'image/png', providerMetadata: { p: { f: 1 } } },
      { type: 'reasoning-file', url: 'data:text/plain;base64,aGk=', mediaType: 'text/plain' },
      { type: 'custom', kind: 'openai.compaction', providerMetadata: { openai: { id: 'x' } } },
    ],
  },
  {
    name: 'multi-step-and-reset',
    chunks: [
      { type: 'start' },
      { type: 'start-step' },
      { type: 'tool-input-available', toolCallId: 'c1', toolName: 'weather', input: { city: 'Rome' } },
      { type: 'tool-output-available', toolCallId: 'c1', output: 'sunny' },
      { type: 'finish-step' },
      { type: 'start-step' },
      { type: 'text-start', id: 't1' },
      { type: 'text-delta', id: 't1', delta: 'Draft' },
      { type: 'reset-step' },
      { type: 'text-start', id: 't2' },
      { type: 'text-delta', id: 't2', delta: 'It is sunny.' },
      { type: 'text-end', id: 't2' },
      { type: 'finish-step' },
      { type: 'finish' },
    ],
  },
  {
    name: 'continue-assistant-message',
    message: {
      id: 'assistant-1',
      role: 'assistant',
      parts: [
        { type: 'step-start' },
        { type: 'tool-weather', toolCallId: 'c1', state: 'input-available', input: { city: 'Oslo' } },
        {
          type: 'tool-delete',
          toolCallId: 'c2',
          state: 'approval-requested',
          input: { path: '/x' },
          approval: { id: 'a2' },
        },
      ],
    },
    chunks: [
      { type: 'start' },
      { type: 'tool-approval-response', approvalId: 'a2', approved: true, reason: 'ok' },
      { type: 'start-step' },
      { type: 'tool-output-available', toolCallId: 'c1', output: { temperature: -3 }, preliminary: true },
      { type: 'tool-output-available', toolCallId: 'c1', output: { temperature: -2 } },
      { type: 'text-start', id: 't1' },
      { type: 'text-delta', id: 't1', delta: 'Cold.' },
      { type: 'text-end', id: 't1' },
      { type: 'finish-step' },
      { type: 'finish' },
    ],
  },
  {
    name: 'error-chunk-and-abort',
    chunks: [
      { type: 'start' },
      { type: 'error', errorText: 'Rate limited' },
      { type: 'abort', reason: 'user' },
    ],
  },
  { name: 'missing-text-start', chunks: [{ type: 'text-delta', id: 'nope', delta: 'x' }] },
  { name: 'missing-reasoning-start', chunks: [{ type: 'reasoning-end', id: 'nope' }] },
  { name: 'missing-tool-input-start', chunks: [{ type: 'tool-input-delta', toolCallId: 'c9', inputTextDelta: '{' }] },
  { name: 'missing-tool-invocation', chunks: [{ type: 'tool-output-available', toolCallId: 'c9', output: 1 }] },
  { name: 'missing-approval', chunks: [{ type: 'tool-approval-response', approvalId: 'a9', approved: true }] },
];

const processResults = [];
for (const testCase of processCases) {
  const state = createStreamingUIMessageState({ lastMessage: plain(testCase.message), messageId: 'generated-id' });
  const events: unknown[] = [];
  let thrown: unknown;
  try {
    await collect(
      processUIMessageStream({
        // upstream stores data chunks in the message and mutates them later
        stream: streamOf(plain(testCase.chunks)),
        runUpdateMessageJob: async (job: any) =>
          job({
            state,
            write: ({ updateStatus = true } = {}) =>
              events.push({ type: 'write', updateStatus, message: plain(state.message) }),
          }),
        onToolCall: ({ toolCall }: any) => void events.push({ type: 'toolCall', toolCall: plain(toolCall) }),
        onData: (part: any) => void events.push({ type: 'data', part: plain({ ...part, transient: undefined }) }),
        onError: (error: any) => void events.push({ type: 'error', message: error.message }),
      }),
    );
  } catch (error) {
    thrown = errorJSON(error);
  }
  processResults.push({
    ...testCase,
    events,
    thrown,
    message: plain(state.message),
    initialMessage: plain(testCase.message),
    finishReason: state.finishReason,
  });
}

// MARK: - streamText -> toUIMessageStream

type ToolSpec = { dynamic?: boolean; output?: unknown; error?: string; needsApproval?: boolean; title?: string };
type StreamCase = {
  name: string;
  steps: any[][];
  tools?: Record<string, ToolSpec>;
  maxSteps?: number;
  options?: {
    sendReasoning?: boolean;
    sendSources?: boolean;
    sendStart?: boolean;
    sendFinish?: boolean;
    originalMessages?: unknown[];
    generateMessageId?: string;
    messageMetadata?: Record<string, unknown>;
    onError?: string;
  };
};

const finish = (unified = 'stop') => ({ type: 'finish', finishReason: { unified, raw: unified }, usage });

const streamCases: StreamCase[] = [
  {
    name: 'text-with-metadata',
    steps: [
      [
        { type: 'stream-start', warnings: [] },
        { type: 'response-metadata', id: 'resp', modelId: 'mock' },
        { type: 'text-start', id: '0' },
        { type: 'text-delta', id: '0', delta: 'Hello' },
        { type: 'text-delta', id: '0', delta: ' there' },
        { type: 'text-end', id: '0' },
        finish(),
      ],
    ],
    options: { messageMetadata: { start: { model: 'mock' }, finish: { tokens: 5 } } },
  },
  {
    name: 'reasoning-hidden',
    steps: [
      [
        { type: 'reasoning-start', id: 'r' },
        { type: 'reasoning-delta', id: 'r', delta: 'secret' },
        { type: 'reasoning-end', id: 'r' },
        { type: 'text-start', id: 't' },
        { type: 'text-delta', id: 't', delta: 'ok' },
        { type: 'text-end', id: 't' },
        finish(),
      ],
    ],
    options: { sendReasoning: false, sendStart: false, sendFinish: false },
  },
  {
    name: 'tool-loop-with-colliding-part-ids',
    tools: { weather: { output: { temperature: 20 }, title: 'Weather' } },
    maxSteps: 2,
    steps: [
      [
        { type: 'text-start', id: '0' },
        { type: 'text-delta', id: '0', delta: 'Checking.' },
        { type: 'text-end', id: '0' },
        { type: 'tool-input-start', id: 'c1', toolName: 'weather' },
        { type: 'tool-input-delta', id: 'c1', delta: '{"city":"Paris"}' },
        { type: 'tool-input-end', id: 'c1' },
        { type: 'tool-call', toolCallId: 'c1', toolName: 'weather', input: '{"city":"Paris"}' },
        finish('tool-calls'),
      ],
      [
        { type: 'text-start', id: '0' },
        { type: 'text-delta', id: '0', delta: 'It is 20 degrees.' },
        { type: 'text-end', id: '0' },
        finish(),
      ],
    ],
  },
  {
    name: 'dynamic-tool',
    tools: { lookup: { dynamic: true, output: 'found' } },
    maxSteps: 1,
    steps: [
      [
        { type: 'tool-input-start', id: 'c1', toolName: 'lookup' },
        { type: 'tool-input-end', id: 'c1' },
        { type: 'tool-call', toolCallId: 'c1', toolName: 'lookup', input: '{"id":7}' },
        finish('tool-calls'),
      ],
    ],
  },
  {
    name: 'tool-error-and-invalid-call',
    tools: { weather: { error: 'weather service down' } },
    maxSteps: 1,
    steps: [
      [
        { type: 'tool-call', toolCallId: 'c1', toolName: 'weather', input: '{"city":"Paris"}' },
        { type: 'tool-call', toolCallId: 'c2', toolName: 'unknown_tool', input: '{}' },
        { type: 'tool-call', toolCallId: 'c3', toolName: 'weather', input: '{"city":1}' },
        finish('tool-calls'),
      ],
    ],
  },
  {
    name: 'sources-and-files',
    steps: [
      [
        { type: 'source', sourceType: 'url', id: 's1', url: 'https://swift.org', title: 'Swift' },
        { type: 'source', sourceType: 'document', id: 's2', mediaType: 'text/plain', title: 'Notes' },
        { type: 'file', mediaType: 'image/png', data: { type: 'data', data: 'iVBORw0KGgo=' } },
        finish(),
      ],
    ],
    options: { sendSources: true },
  },
  {
    name: 'provider-executed-tool',
    steps: [
      [
        { type: 'tool-call', toolCallId: 'p1', toolName: 'web_search', input: '{"q":"swift"}', providerExecuted: true },
        { type: 'tool-result', toolCallId: 'p1', toolName: 'web_search', result: [{ url: 'https://swift.org' }] },
        { type: 'tool-call', toolCallId: 'p2', toolName: 'web_search', input: '{"q":"x"}', providerExecuted: true },
        {
          type: 'tool-result',
          toolCallId: 'p2',
          toolName: 'web_search',
          result: { code: 'unavailable' },
          isError: true,
        },
        { type: 'text-start', id: 't' },
        { type: 'text-delta', id: 't', delta: 'Found it.' },
        { type: 'text-end', id: 't' },
        finish(),
      ],
    ],
  },
  {
    name: 'persistence-and-approval',
    tools: { delete_file: { needsApproval: true, output: 'deleted' } },
    maxSteps: 2,
    steps: [
      [
        { type: 'tool-call', toolCallId: 'c1', toolName: 'delete_file', input: '{"city":"x"}' },
        finish('tool-calls'),
      ],
    ],
    options: {
      originalMessages: [{ id: 'u1', role: 'user', parts: [{ type: 'text', text: 'Delete it' }] }],
      generateMessageId: 'response-1',
    },
  },
  {
    name: 'continuation-of-assistant-message',
    steps: [
      [
        { type: 'text-start', id: 't' },
        { type: 'text-delta', id: 't', delta: 'More.' },
        { type: 'text-end', id: 't' },
        finish(),
      ],
    ],
    options: {
      originalMessages: [
        { id: 'u1', role: 'user', parts: [{ type: 'text', text: 'Hi' }] },
        { id: 'a1', role: 'assistant', parts: [{ type: 'text', text: 'Hello.' }] },
      ],
      generateMessageId: 'unused',
    },
  },
  {
    name: 'model-error-part',
    steps: [
      [
        { type: 'text-start', id: 't' },
        { type: 'text-delta', id: 't', delta: 'Partial' },
        { type: 'error', error: 'overloaded' },
        { type: 'text-end', id: 't' },
        finish('error'),
      ],
    ],
  },
];

const streamResults = [];
for (const testCase of streamCases) {
  let call = 0;
  const model = new MockLanguageModelV4({
    doStream: async () => ({ stream: streamOf(testCase.steps[call++] ?? testCase.steps[testCase.steps.length - 1]) }),
  });
  const tools: Record<string, any> = {};
  for (const [name, spec] of Object.entries(testCase.tools ?? {})) {
    const execute = async () => {
      if (spec.error != null) throw new Error(spec.error);
      return spec.output;
    };
    tools[name] = spec.dynamic
      ? dynamicTool({ inputSchema: jsonSchema({ type: 'object' }), execute })
      : tool({ inputSchema: citySchema(), execute, needsApproval: spec.needsApproval, title: spec.title });
  }
  const result = streamText({
    model,
    prompt: 'test',
    tools,
    stopWhen: isStepCount(testCase.maxSteps ?? 1),
    _internal: { generateId: () => 'gen-id' },
  });
  let onEnd: unknown;
  const options = testCase.options ?? {};
  const chunks = await collect(
    toUIMessageStream({
      stream: result.stream,
      tools,
      sendReasoning: options.sendReasoning,
      sendSources: options.sendSources,
      sendStart: options.sendStart,
      sendFinish: options.sendFinish,
      originalMessages: options.originalMessages as any,
      generateMessageId: options.generateMessageId ? () => options.generateMessageId! : undefined,
      messageMetadata: options.messageMetadata
        ? ({ part }: any) => (options.messageMetadata as any)[part.type]
        : undefined,
      onError: options.onError ? (error: any) => `${options.onError}: ${error.message}` : undefined,
      onEnd: (event: any) => {
        onEnd = plain({ ...event, outcome: event.outcome.status });
      },
    }),
  );
  streamResults.push({ ...testCase, chunks: plain(chunks), onEnd });
}

// MARK: - convertToModelMessages

const convertCases = [
  {
    name: 'system-user-assistant',
    messages: [
      { id: 's', role: 'system', parts: [{ type: 'text', text: 'Be brief. ', providerMetadata: { a: { x: 1 } } }, { type: 'text', text: 'Be kind.' }] },
      {
        id: 'u',
        role: 'user',
        parts: [
          { type: 'file', mediaType: 'image/png', url: 'https://example.com/cat.png', filename: 'cat.png' },
          { type: 'file', mediaType: 'application/pdf', url: 'https://example.com/doc.pdf', providerReference: { openai: 'file-1' } },
          { type: 'text', text: 'What is this?', providerMetadata: { a: { y: 2 } } },
          { type: 'data-context', data: 'ignored without converter' },
        ],
      },
      {
        id: 'a',
        role: 'assistant',
        parts: [
          { type: 'step-start' },
          { type: 'reasoning', text: 'Looking', providerMetadata: { a: { sig: 'abc' } } },
          { type: 'text', text: 'A cat.' },
          { type: 'custom', kind: 'openai.compaction', providerMetadata: { openai: { id: 'c' } } },
          { type: 'reasoning-file', mediaType: 'image/png', url: 'data:image/png;base64,iVBORw0KGgo=' },
          { type: 'source-url', sourceId: 's', url: 'https://example.com' },
        ],
      },
    ],
  },
  {
    name: 'tool-states',
    messages: [
      {
        id: 'a',
        role: 'assistant',
        parts: [
          { type: 'step-start' },
          { type: 'text', text: 'Calling tools.' },
          { type: 'tool-weather', toolCallId: 'c1', state: 'output-available', input: { city: 'Paris' }, output: { temperature: 20 }, callProviderMetadata: { p: { a: 1 } } },
          { type: 'tool-weather', toolCallId: 'c2', state: 'output-error', input: { city: 'X' }, errorText: 'Unknown city' },
          { type: 'tool-weather', toolCallId: 'c3', state: 'output-error', rawInput: '{"city":', errorText: 'Bad JSON', resultProviderMetadata: { p: { r: 1 } } },
          { type: 'dynamic-tool', toolName: 'lookup', toolCallId: 'c4', state: 'output-available', input: {}, output: 'text output' },
          { type: 'tool-weather', toolCallId: 'c5', state: 'input-streaming', input: { city: 'Pa' } },
          { type: 'tool-weather', toolCallId: 'c6', state: 'input-available', input: { city: 'Rome' } },
          { type: 'step-start' },
          { type: 'text', text: 'Done.' },
        ],
      },
    ],
  },
  {
    name: 'approvals',
    messages: [
      {
        id: 'a',
        role: 'assistant',
        parts: [
          { type: 'step-start' },
          { type: 'tool-delete', toolCallId: 'c1', state: 'approval-requested', input: { path: '/a' }, approval: { id: 'a1', requestReason: 'Dangerous', isAutomatic: false, signature: 'sig' } },
          { type: 'tool-delete', toolCallId: 'c2', state: 'approval-responded', input: { path: '/b' }, approval: { id: 'a2', approved: true } },
          { type: 'tool-delete', toolCallId: 'c3', state: 'approval-responded', input: { path: '/c' }, approval: { id: 'a3', approved: false, reason: 'No' }, callProviderMetadata: { p: { z: 1 } } },
          { type: 'tool-delete', toolCallId: 'c4', state: 'output-denied', input: { path: '/d' }, approval: { id: 'a4', approved: false } },
          { type: 'tool-delete', toolCallId: 'c5', state: 'output-available', input: { path: '/e' }, output: 'deleted', approval: { id: 'a5', approved: true, reason: 'fine' } },
        ],
      },
    ],
  },
  {
    name: 'provider-executed',
    messages: [
      {
        id: 'a',
        role: 'assistant',
        parts: [
          { type: 'tool-web_search', toolCallId: 'p1', state: 'output-available', input: { q: 'swift' }, output: [{ url: 'https://swift.org' }], providerExecuted: true, callProviderMetadata: { p: { c: 1 } } },
          { type: 'tool-web_search', toolCallId: 'p2', state: 'output-error', input: { q: 'x' }, errorText: 'unavailable', providerExecuted: true, resultProviderMetadata: { p: { r: 2 } } },
          { type: 'tool-web_search', toolCallId: 'p3', state: 'approval-responded', input: { q: 'y' }, providerExecuted: true, approval: { id: 'pa', approved: true } },
          { type: 'text', text: 'Summary' },
        ],
      },
    ],
  },
  {
    name: 'ignore-incomplete-tool-calls',
    ignoreIncompleteToolCalls: true,
    messages: [
      {
        id: 'a',
        role: 'assistant',
        parts: [
          { type: 'tool-weather', toolCallId: 'c1', state: 'input-available', input: { city: 'Paris' } },
          { type: 'tool-weather', toolCallId: 'c2', state: 'output-available', input: { city: 'Rome' }, output: 'sunny', preliminary: true },
          { type: 'tool-weather', toolCallId: 'c3', state: 'output-available', input: { city: 'Oslo' }, output: 'cold' },
        ],
      },
    ],
  },
  {
    name: 'data-part-converter',
    convertData: true,
    messages: [
      { id: 'u', role: 'user', parts: [{ type: 'data-note', data: 'user note' }, { type: 'text', text: 'Hi' }] },
      { id: 'a', role: 'assistant', parts: [{ type: 'data-note', data: 'assistant note' }, { type: 'data-skip', data: 'x' }] },
    ],
  },
];

const convertResults = [];
for (const testCase of convertCases) {
  const modelMessages = await convertToModelMessages(testCase.messages as any, {
    ignoreIncompleteToolCalls: testCase.ignoreIncompleteToolCalls,
    convertDataPart: testCase.convertData
      ? (part: any) => (part.type === 'data-note' ? { type: 'text', text: `Note: ${part.data}` } : undefined)
      : undefined,
  });
  convertResults.push({ ...testCase, modelMessages: plain(modelMessages) });
}

// MARK: - validateUIMessages

const validMessage = { id: 'u', role: 'user', parts: [{ type: 'text', text: 'Hi' }] };
const validateCases = [
  { name: 'valid', messages: [validMessage] },
  { name: 'missing', messages: null },
  { name: 'empty-array', messages: [] },
  { name: 'user-without-parts', messages: [{ id: 'u', role: 'user', parts: [] }] },
  { name: 'assistant-without-parts', messages: [{ id: 'a', role: 'assistant', parts: [] }] },
  { name: 'bad-role', messages: [{ id: 'x', role: 'tool', parts: [{ type: 'text', text: 'x' }] }] },
  { name: 'bad-part', messages: [{ id: 'u', role: 'user', parts: [{ type: 'image', url: 'x' }] }] },
  {
    name: 'output-error-without-error-text',
    messages: [{ id: 'a', role: 'assistant', parts: [{ type: 'tool-weather', toolCallId: 'c', state: 'output-error', input: {} }] }],
  },
  {
    name: 'strips-fields-for-state',
    messages: [
      {
        id: 'a',
        role: 'assistant',
        parts: [{ type: 'tool-weather', toolCallId: 'c', state: 'input-available', input: { city: 'Paris' }, preliminary: true, rawInput: 'x' }],
      },
    ],
  },
  {
    name: 'metadata-schema',
    metadataSchema: true,
    messages: [{ ...validMessage, metadata: { createdAt: 5 } }, { ...validMessage, id: 'u2', metadata: { createdAt: 'x' } }],
  },
  {
    name: 'data-schema-missing',
    dataSchemas: true,
    messages: [{ id: 'a', role: 'assistant', parts: [{ type: 'data-unknown', data: 1 }] }],
  },
  {
    name: 'data-schema-valid',
    dataSchemas: true,
    messages: [{ id: 'a', role: 'assistant', parts: [{ type: 'data-weather', id: 'w', data: { city: 'Paris' } }] }],
  },
  {
    name: 'tool-input-valid',
    tools: true,
    messages: [{ id: 'a', role: 'assistant', parts: [{ type: 'tool-weather', toolCallId: 'c', state: 'input-available', input: { city: 'Paris' } }] }],
  },
  {
    name: 'tool-input-invalid',
    tools: true,
    messages: [{ id: 'a', role: 'assistant', parts: [{ type: 'tool-weather', toolCallId: 'c', state: 'input-available', input: { city: 3 } }] }],
  },
  {
    name: 'tool-invalid-output-error-becomes-dynamic',
    tools: true,
    messages: [
      { id: 'a', role: 'assistant', parts: [{ type: 'tool-weather', toolCallId: 'c', state: 'output-error', input: { city: 3 }, errorText: 'bad' }] },
    ],
  },
  {
    name: 'unknown-tool-terminal-becomes-dynamic',
    tools: true,
    messages: [
      { id: 'a', role: 'assistant', parts: [{ type: 'tool-legacy', toolCallId: 'c', state: 'output-available', input: {}, output: 'x' }] },
    ],
  },
  {
    name: 'unknown-tool-pending',
    tools: true,
    messages: [{ id: 'a', role: 'assistant', parts: [{ type: 'tool-legacy', toolCallId: 'c', state: 'input-available', input: {} }] }],
  },
];

const validateResults = [];
for (const testCase of validateCases) {
  const result = await safeValidateUIMessages({
    messages: testCase.messages,
    metadataSchema: testCase.metadataSchema
      ? jsonSchema({ type: 'object' }, {
          validate: (value: any) =>
            typeof value?.createdAt === 'number'
              ? { success: true, value }
              : { success: false, error: new Error('createdAt must be a number') },
        })
      : undefined,
    dataSchemas: testCase.dataSchemas ? { weather: citySchema() } : undefined,
    tools: testCase.tools ? { weather: { inputSchema: citySchema() } } : undefined,
  } as any);
  validateResults.push({
    name: testCase.name,
    messages: testCase.messages,
    metadataSchema: testCase.metadataSchema ?? false,
    dataSchemas: testCase.dataSchemas ?? false,
    tools: testCase.tools ?? false,
    success: result.success,
    data: result.success ? plain(result.data) : undefined,
    errorName: result.success ? undefined : result.error.name,
  });
}

// MARK: - lastAssistantMessageIsComplete*

const completeCases = [
  { name: 'no-messages', messages: [] },
  { name: 'user-last', messages: [validMessage] },
  {
    name: 'tool-outputs-complete',
    messages: [{ id: 'a', role: 'assistant', parts: [{ type: 'step-start' }, { type: 'tool-a', toolCallId: '1', state: 'input-available', input: {} }, { type: 'step-start' }, { type: 'tool-a', toolCallId: '2', state: 'output-available', input: {}, output: 1 }, { type: 'tool-b', toolCallId: '3', state: 'output-error', input: {}, errorText: 'x' }] }],
  },
  {
    name: 'preliminary-output',
    messages: [{ id: 'a', role: 'assistant', parts: [{ type: 'tool-a', toolCallId: '1', state: 'output-available', input: {}, output: 1, preliminary: true }] }],
  },
  {
    name: 'only-provider-executed',
    messages: [{ id: 'a', role: 'assistant', parts: [{ type: 'tool-a', toolCallId: '1', state: 'output-available', input: {}, output: 1, providerExecuted: true }] }],
  },
  {
    name: 'approval-responded',
    messages: [{ id: 'a', role: 'assistant', parts: [{ type: 'tool-a', toolCallId: '1', state: 'approval-responded', input: {}, approval: { id: 'x', approved: true } }, { type: 'tool-b', toolCallId: '2', state: 'output-denied', input: {}, approval: { id: 'y', approved: false } }] }],
  },
  {
    name: 'approval-pending',
    messages: [{ id: 'a', role: 'assistant', parts: [{ type: 'tool-a', toolCallId: '1', state: 'approval-responded', input: {}, approval: { id: 'x', approved: true } }, { type: 'tool-b', toolCallId: '2', state: 'approval-requested', input: {}, approval: { id: 'y' } }] }],
  },
];
const completeResults = completeCases.map(testCase => ({
  ...testCase,
  toolCalls: lastAssistantMessageIsCompleteWithToolCalls({ messages: testCase.messages as any }),
  approvalResponses: lastAssistantMessageIsCompleteWithApprovalResponses({ messages: testCase.messages as any }),
}));

// MARK: - createUIMessageStream

type WriterOp = { write?: unknown; merge?: unknown[]; throw?: string; setOutcome?: string };
const createCases: { name: string; ops: WriterOp[]; onError?: string; originalMessages?: unknown[]; onStepEnd?: boolean }[] = [
  {
    name: 'writes',
    onStepEnd: true,
    ops: [
      { write: { type: 'start' } },
      { write: { type: 'start-step' } },
      { write: { type: 'text-start', id: 't' } },
      { write: { type: 'text-delta', id: 't', delta: 'Hi' } },
      { write: { type: 'text-end', id: 't' } },
      { write: { type: 'data-status', data: 'done' } },
      { write: { type: 'finish-step' } },
      { write: { type: 'finish', finishReason: 'stop' } },
      { setOutcome: 'completed' },
    ],
  },
  {
    name: 'execute-throws',
    ops: [{ write: { type: 'start' } }, { throw: 'kaboom' }],
  },
  {
    name: 'merge-with-custom-error',
    onError: 'handled',
    ops: [
      { write: { type: 'start' } },
      {
        merge: [
          { type: 'text-start', id: 'm' },
          { type: 'text-delta', id: 'm', delta: 'merged' },
          { type: 'text-end', id: 'm' },
        ],
      },
      { throw: 'late failure' },
    ],
  },
  {
    name: 'continues-assistant-message',
    originalMessages: [
      { id: 'u1', role: 'user', parts: [{ type: 'text', text: 'Hi' }] },
      { id: 'a1', role: 'assistant', parts: [{ type: 'text', text: 'Hello' }] },
    ],
    ops: [
      { write: { type: 'start' } },
      { write: { type: 'text-start', id: 't' } },
      { write: { type: 'text-delta', id: 't', delta: ' again' } },
      { write: { type: 'text-end', id: 't' } },
      { write: { type: 'abort', reason: 'stopped' } },
    ],
  },
];

const createResults = [];
for (const testCase of createCases) {
  let onEnd: unknown;
  const stepEnds: unknown[] = [];
  const stream = createUIMessageStream({
    generateId: () => 'generated-message-id',
    originalMessages: testCase.originalMessages as any,
    onError: testCase.onError ? (error: any) => `${testCase.onError}: ${error.message}` : undefined,
    onStepEnd: testCase.onStepEnd ? (event: any) => void stepEnds.push(plain(event)) : undefined,
    onEnd: (event: any) => {
      onEnd = plain({ ...event, outcome: event.outcome.status });
    },
    execute: async ({ writer }: any) => {
      for (const op of testCase.ops) {
        if (op.write) writer.write(op.write);
        if (op.merge) writer.merge(streamOf(op.merge));
        if (op.setOutcome) writer.setOutcome({ status: op.setOutcome });
        if (op.throw) {
          await sleep(10);
          throw new Error(op.throw);
        }
      }
    },
  });
  createResults.push({ ...testCase, chunks: plain(await collect(stream)), onEnd, stepEnds });
}

// MARK: - Chat

type ChatOp =
  | { op: 'send'; text: string; messageId?: string; metadata?: unknown }
  | { op: 'sendEmpty' }
  | { op: 'regenerate'; messageId?: string }
  | { op: 'addToolOutput'; toolCallId: string; output?: unknown; errorText?: string }
  | { op: 'approve'; id: string; approved: boolean; reason?: string }
  | { op: 'clearError' };
type ChatCase = {
  name: string;
  initialMessages?: unknown[];
  responses: ({ chunks: unknown[] } | { error: string })[];
  ops: ChatOp[];
  autoSend?: 'toolCalls' | 'approvals';
  clientTools?: Record<string, unknown>;
};

const chatCases: ChatCase[] = [
  {
    name: 'send-text',
    responses: [
      {
        chunks: [
          { type: 'start', messageId: 'server-1', messageMetadata: { model: 'mock' } },
          { type: 'start-step' },
          { type: 'text-start', id: 't' },
          { type: 'text-delta', id: 't', delta: 'Hello!' },
          { type: 'text-end', id: 't' },
          { type: 'data-usage', data: { tokens: 3 } },
          { type: 'finish-step' },
          { type: 'finish', finishReason: 'stop' },
        ],
      },
    ],
    ops: [{ op: 'send', text: 'Hi', metadata: { sentAt: 1 } }],
  },
  {
    name: 'client-tool-round-trip',
    autoSend: 'toolCalls',
    clientTools: { getLocation: { city: 'Paris' } },
    responses: [
      {
        chunks: [
          { type: 'start', messageId: 'server-1' },
          { type: 'start-step' },
          { type: 'tool-input-available', toolCallId: 'c1', toolName: 'getLocation', input: {} },
          { type: 'finish-step' },
          { type: 'finish', finishReason: 'tool-calls' },
        ],
      },
      {
        chunks: [
          { type: 'start' },
          { type: 'start-step' },
          { type: 'text-start', id: 't' },
          { type: 'text-delta', id: 't', delta: 'You are in Paris.' },
          { type: 'text-end', id: 't' },
          { type: 'finish-step' },
          { type: 'finish', finishReason: 'stop' },
        ],
      },
    ],
    ops: [{ op: 'send', text: 'Where am I?' }],
  },
  {
    name: 'approval-round-trip',
    autoSend: 'approvals',
    responses: [
      {
        chunks: [
          { type: 'start', messageId: 'server-1' },
          { type: 'start-step' },
          { type: 'tool-input-available', toolCallId: 'c1', toolName: 'deleteFile', input: { path: '/tmp/a' } },
          { type: 'tool-approval-request', approvalId: 'ap1', toolCallId: 'c1' },
          { type: 'finish-step' },
          { type: 'finish', finishReason: 'tool-calls' },
        ],
      },
      {
        chunks: [
          { type: 'start' },
          { type: 'tool-output-available', toolCallId: 'c1', output: 'deleted' },
          { type: 'start-step' },
          { type: 'text-start', id: 't' },
          { type: 'text-delta', id: 't', delta: 'Deleted.' },
          { type: 'text-end', id: 't' },
          { type: 'finish-step' },
          { type: 'finish' },
        ],
      },
    ],
    ops: [
      { op: 'send', text: 'Delete /tmp/a' },
      { op: 'approve', id: 'ap1', approved: true, reason: 'go ahead' },
    ],
  },
  {
    name: 'manual-tool-output-and-send-empty',
    responses: [
      {
        chunks: [
          { type: 'start', messageId: 'server-1' },
          { type: 'start-step' },
          { type: 'tool-input-available', toolCallId: 'c1', toolName: 'confirm', input: { question: 'Sure?' } },
          { type: 'finish-step' },
          { type: 'finish' },
        ],
      },
      {
        chunks: [
          { type: 'start' },
          { type: 'start-step' },
          { type: 'text-start', id: 't' },
          { type: 'text-delta', id: 't', delta: 'Confirmed.' },
          { type: 'text-end', id: 't' },
          { type: 'finish-step' },
          { type: 'finish' },
        ],
      },
    ],
    ops: [
      { op: 'send', text: 'Do it' },
      { op: 'addToolOutput', toolCallId: 'c1', errorText: 'User declined' },
      { op: 'sendEmpty' },
    ],
  },
  {
    name: 'regenerate-and-edit',
    responses: [
      { chunks: [{ type: 'start', messageId: 'r1' }, { type: 'text-start', id: 't' }, { type: 'text-delta', id: 't', delta: 'First' }, { type: 'text-end', id: 't' }, { type: 'finish' }] },
      { chunks: [{ type: 'start', messageId: 'r2' }, { type: 'text-start', id: 't' }, { type: 'text-delta', id: 't', delta: 'Second' }, { type: 'text-end', id: 't' }, { type: 'finish' }] },
      { chunks: [{ type: 'start', messageId: 'r3' }, { type: 'text-start', id: 't' }, { type: 'text-delta', id: 't', delta: 'Edited' }, { type: 'text-end', id: 't' }, { type: 'finish' }] },
    ],
    ops: [
      { op: 'send', text: 'Question' },
      { op: 'regenerate' },
      { op: 'send', text: 'Better question', messageId: 'id-0' },
    ],
  },
  {
    name: 'transport-error-and-clear',
    responses: [{ error: 'Network down' }],
    ops: [{ op: 'send', text: 'Hi' }, { op: 'clearError' }],
  },
  {
    name: 'error-chunk',
    responses: [
      {
        chunks: [
          { type: 'start', messageId: 'r1' },
          { type: 'text-start', id: 't' },
          { type: 'text-delta', id: 't', delta: 'Part' },
          { type: 'error', errorText: 'Model overloaded' },
          { type: 'text-end', id: 't' },
        ],
      },
    ],
    ops: [{ op: 'send', text: 'Hi' }],
  },
  {
    name: 'continue-from-initial-messages',
    initialMessages: [
      { id: 'u0', role: 'user', parts: [{ type: 'text', text: 'Earlier' }] },
      { id: 'a0', role: 'assistant', parts: [{ type: 'text', text: 'Earlier answer' }] },
    ],
    responses: [{ chunks: [{ type: 'start' }, { type: 'text-start', id: 't' }, { type: 'text-delta', id: 't', delta: 'New answer' }, { type: 'text-end', id: 't' }, { type: 'finish' }] }],
    ops: [{ op: 'send', text: 'Next' }],
  },
];

class RecordingState {
  status = 'ready';
  error: Error | undefined = undefined;
  messages: any[];
  statuses: string[] = [];
  constructor(messages: any[]) {
    this.messages = messages;
  }
  pushMessage = (message: any) => {
    this.messages = this.messages.concat(structuredClone(message));
  };
  popMessage = () => {
    this.messages = this.messages.slice(0, -1);
  };
  replaceMessage = (index: number, message: any) => {
    this.messages = [...this.messages.slice(0, index), structuredClone(message), ...this.messages.slice(index + 1)];
  };
  snapshot = <T,>(value: T): T => structuredClone(value);
}

class TestChat extends AbstractChat<any> {
  constructor(options: any) {
    super(options);
  }
}

const chatResults = [];
for (const testCase of chatCases) {
  let idCounter = 0;
  const state = new RecordingState(plain(testCase.initialMessages ?? []));
  const statusProxy = new Proxy(state, {
    set(target: any, key, value) {
      if (key === 'status') target.statuses.push(value);
      target[key] = value;
      return true;
    },
  });
  const requests: unknown[] = [];
  const finishes: unknown[] = [];
  const toolCalls: unknown[] = [];
  const data: unknown[] = [];
  const errors: string[] = [];
  let responseIndex = 0;

  const chat: any = new TestChat({
    id: 'chat-1',
    generateId: () => `id-${idCounter++}`,
    state: statusProxy,
    transport: {
      sendMessages: async (options: any) => {
        requests.push(plain({ trigger: options.trigger, chatId: options.chatId, messageId: options.messageId, messages: options.messages }));
        const response = testCase.responses[responseIndex++];
        if ('error' in response) throw new Error(response.error);
        return streamOf(plain(response.chunks));
      },
      reconnectToStream: async () => null,
    },
    onToolCall: ({ toolCall }: any) => {
      toolCalls.push(plain(toolCall));
      const output = testCase.clientTools?.[toolCall.toolName];
      if (output !== undefined) {
        chat.addToolOutput({ tool: toolCall.toolName, toolCallId: toolCall.toolCallId, output });
      }
    },
    onData: (part: any) => void data.push(plain(part)),
    onError: (error: Error) => void errors.push(error.message),
    onFinish: (event: any) =>
      void finishes.push(
        plain({
          messageId: event.message.id,
          messageCount: event.messages.length,
          isAbort: event.isAbort,
          isDisconnect: event.isDisconnect,
          isError: event.isError,
          finishReason: event.finishReason,
        }),
      ),
    sendAutomaticallyWhen:
      testCase.autoSend === 'toolCalls'
        ? lastAssistantMessageIsCompleteWithToolCalls
        : testCase.autoSend === 'approvals'
          ? lastAssistantMessageIsCompleteWithApprovalResponses
          : undefined,
  });

  const settle = async () => {
    let stable = 0;
    while (stable < 5) {
      await sleep(5);
      stable = chat.status === 'submitted' || chat.status === 'streaming' ? 0 : stable + 1;
    }
  };

  for (const op of testCase.ops) {
    switch (op.op) {
      case 'send':
        await chat.sendMessage({ text: op.text, metadata: op.metadata, messageId: op.messageId });
        break;
      case 'sendEmpty':
        await chat.sendMessage();
        break;
      case 'regenerate':
        await chat.regenerate({ messageId: op.messageId });
        break;
      case 'addToolOutput':
        await chat.addToolOutput({ tool: 'x', toolCallId: op.toolCallId, output: op.output, errorText: op.errorText, state: op.errorText ? 'output-error' : 'output-available' });
        break;
      case 'approve':
        await chat.addToolApprovalResponse({ id: op.id, approved: op.approved, reason: op.reason });
        break;
      case 'clearError':
        chat.clearError();
        break;
    }
    await settle();
  }

  chatResults.push({
    ...testCase,
    requests,
    messages: plain(state.messages),
    statuses: state.statuses,
    status: state.status,
    finishes,
    toolCalls,
    data,
    errors,
  });
}

fs.writeFileSync(
  path.join(outputDir, 'ui-conformance.json'),
  JSON.stringify(
    {
      process: processResults,
      stream: streamResults,
      convert: convertResults,
      validate: validateResults,
      complete: completeResults,
      create: createResults,
      chat: chatResults,
    },
    null,
    1,
  ) + '\n',
);
console.log(
  `ui conformance: ${processResults.length} process, ${streamResults.length} stream, ${convertResults.length} convert, ` +
    `${validateResults.length} validate, ${completeResults.length} complete, ${createResults.length} create, ${chatResults.length} chat`,
);
