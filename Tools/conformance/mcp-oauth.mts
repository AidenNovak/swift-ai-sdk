// Generates Tests/AISDKMCPTests/Fixtures/mcp-oauth-conformance.json by running
// the upstream `auth()` flow against scripted HTTP responses with a recording
// provider. PKCE and state values are masked before comparison.
import * as fs from 'node:fs';
import * as path from 'node:path';

const upstream = process.env.UPSTREAM!;
const repo = path.resolve(import.meta.dirname, '../..');
const outputDir = path.join(repo, 'Tests/AISDKMCPTests/Fixtures');

const { auth } = await import(path.join(upstream, 'packages/mcp/src/tool/oauth.ts'));

type Scripted = { status: number; headers?: Record<string, string>; body?: unknown };
type ProviderState = {
  tokens?: Record<string, unknown>;
  clientInformation?: Record<string, unknown>;
  authorizationServerInformation?: Record<string, unknown>;
  codeVerifier?: string;
  state?: string;
  storedState?: string;
  dynamicallyRegistered?: boolean;
  canSaveAuthorizationServerInformation?: boolean;
};
type Case = {
  name: string;
  serverUrl: string;
  options?: { authorizationCode?: string; callbackState?: string; callbackIssuer?: string; scope?: string; resourceMetadataUrl?: string };
  provider: ProviderState;
  responses: Record<string, Scripted | Scripted[]>;
};

const server = 'https://mcp.example.com/mcp';
const as = 'https://auth.example.com';
const prm = { resource: server, authorization_servers: [as], scopes_supported: ['mcp:read', 'mcp:write'] };
const asMetadata = {
  issuer: as,
  authorization_endpoint: `${as}/authorize`,
  token_endpoint: `${as}/token`,
  registration_endpoint: `${as}/register`,
  response_types_supported: ['code'],
  code_challenge_methods_supported: ['S256'],
  grant_types_supported: ['authorization_code', 'refresh_token'],
  token_endpoint_auth_methods_supported: ['none'],
};
const pinned = { issuer: as, authorization_server: `${as}/`, token_endpoint: `${as}/token` };
const discovery = {
  'GET https://mcp.example.com/.well-known/oauth-protected-resource/mcp': { status: 200, body: prm },
  'GET https://auth.example.com/.well-known/oauth-authorization-server': { status: 200, body: asMetadata },
};

const cases: Case[] = [
  {
    name: 'fresh-registration-and-redirect',
    serverUrl: server,
    provider: {},
    responses: {
      ...discovery,
      'POST https://auth.example.com/register': {
        status: 201,
        body: {
          client_id: 'client-1',
          client_id_issued_at: 1,
          redirect_uris: ['http://127.0.0.1:33418/callback'],
          client_name: 'Swift AI SDK',
          grant_types: ['authorization_code'],
          unknown_field: 'dropped',
        },
      },
    },
  },
  {
    name: 'registration-response-missing-redirect-uris',
    serverUrl: server,
    provider: {},
    responses: {
      ...discovery,
      'POST https://auth.example.com/register': { status: 201, body: { client_id: 'client-1' } },
    },
  },
  {
    name: 'callback-exchanges-code',
    serverUrl: server,
    options: { authorizationCode: 'code-123', callbackState: 'state-1', callbackIssuer: as },
    provider: {
      clientInformation: { client_id: 'client-1', ...pinned },
      codeVerifier: 'verifier-abc',
      storedState: 'state-1',
    },
    responses: {
      ...discovery,
      'POST https://auth.example.com/token': {
        status: 200,
        body: { access_token: 'access-1', token_type: 'Bearer', refresh_token: 'refresh-1', expires_in: 3600 },
      },
    },
  },
  {
    name: 'refreshes-tokens',
    serverUrl: server,
    provider: {
      clientInformation: { client_id: 'client-1', ...pinned },
      tokens: { access_token: 'old', token_type: 'Bearer', refresh_token: 'refresh-1', ...pinned },
    },
    responses: {
      ...discovery,
      'POST https://auth.example.com/token': { status: 200, body: { access_token: 'new', token_type: 'Bearer' } },
    },
  },
  {
    name: 'invalid-grant-restarts-authorization',
    serverUrl: server,
    provider: {
      clientInformation: { client_id: 'client-1', ...pinned },
      tokens: { access_token: 'old', token_type: 'Bearer', refresh_token: 'bad', ...pinned },
      canSaveAuthorizationServerInformation: true,
    },
    responses: {
      ...discovery,
      'POST https://auth.example.com/token': { status: 400, body: { error: 'invalid_grant', error_description: 'expired' } },
    },
  },
  {
    name: 'legacy-server-as-authorization-server',
    serverUrl: 'https://legacy.example.com/mcp',
    provider: { clientInformation: { client_id: 'client-legacy' }, canSaveAuthorizationServerInformation: true },
    responses: {
      'GET https://legacy.example.com/.well-known/oauth-protected-resource/mcp': { status: 404 },
      'GET https://legacy.example.com/.well-known/oauth-protected-resource': { status: 404 },
      'GET https://legacy.example.com/.well-known/oauth-authorization-server/mcp': { status: 404 },
      'GET https://legacy.example.com/.well-known/oauth-authorization-server': { status: 404 },
      'GET https://legacy.example.com/.well-known/openid-configuration/mcp': { status: 404 },
      'GET https://legacy.example.com/mcp/.well-known/openid-configuration': { status: 404 },
    },
  },
  {
    name: 'oidc-discovery-with-path',
    serverUrl: server,
    provider: { clientInformation: { client_id: 'client-1' }, canSaveAuthorizationServerInformation: true },
    responses: {
      'GET https://mcp.example.com/.well-known/oauth-protected-resource/mcp': {
        status: 200,
        body: { resource: server, authorization_servers: ['https://idp.example.com/tenant'] },
      },
      'GET https://idp.example.com/.well-known/oauth-authorization-server/tenant': { status: 404 },
      'GET https://idp.example.com/.well-known/oauth-authorization-server': { status: 404 },
      'GET https://idp.example.com/.well-known/openid-configuration/tenant': {
        status: 200,
        body: {
          issuer: 'https://idp.example.com/tenant',
          authorization_endpoint: 'https://idp.example.com/tenant/authorize',
          token_endpoint: 'https://idp.example.com/tenant/token',
          jwks_uri: 'https://idp.example.com/tenant/jwks',
          response_types_supported: ['code'],
          subject_types_supported: ['public'],
          id_token_signing_alg_values_supported: ['RS256'],
          code_challenge_methods_supported: ['S256'],
        },
      },
    },
  },
  {
    name: 'issuer-mismatch-fails',
    serverUrl: server,
    provider: { clientInformation: { client_id: 'client-1' } },
    responses: {
      ...discovery,
      'GET https://auth.example.com/.well-known/oauth-authorization-server': {
        status: 200,
        body: { ...asMetadata, issuer: 'https://evil.example.com' },
      },
    },
  },
  {
    name: 'client-secret-basic',
    serverUrl: server,
    options: { authorizationCode: 'code-9' },
    provider: {
      clientInformation: { client_id: 'confidential', client_secret: 's3cret', ...pinned },
      codeVerifier: 'verifier-xyz',
    },
    responses: {
      ...discovery,
      'GET https://auth.example.com/.well-known/oauth-authorization-server': {
        status: 200,
        body: { ...asMetadata, token_endpoint_auth_methods_supported: ['client_secret_basic', 'client_secret_post'] },
      },
      'POST https://auth.example.com/token': { status: 200, body: { access_token: 'a', token_type: 'Bearer' } },
    },
  },
  {
    name: 'state-mismatch-fails',
    serverUrl: server,
    options: { authorizationCode: 'code', callbackState: 'wrong' },
    provider: { clientInformation: { client_id: 'client-1', ...pinned }, codeVerifier: 'v', storedState: 'right' },
    responses: { ...discovery },
  },
  {
    name: 'cross-origin-resource-metadata-rejected',
    serverUrl: server,
    options: { resourceMetadataUrl: 'https://other.example.com/.well-known/oauth-protected-resource' },
    provider: {},
    responses: {},
  },
];

const output: unknown[] = [];
for (const testCase of cases) {
  const requests: unknown[] = [];
  const calls: unknown[] = [];
  const queues = structuredClone(testCase.responses);
  const state = structuredClone(testCase.provider);

  const fetchFn = async (input: string | URL, init?: RequestInit) => {
    const url = String(input);
    const method = init?.method ?? 'GET';
    const headers = Object.fromEntries(
      [...new Headers(init?.headers).entries()].filter(([name]) => name !== 'user-agent'),
    );
    const bodyText = init?.body == null ? null : String(init.body);
    let body: unknown = bodyText;
    if (bodyText != null && headers['content-type']?.includes('application/json')) body = JSON.parse(bodyText);
    requests.push({ method, url, headers, body });
    const entry = queues[`${method} ${url}`];
    const scripted = Array.isArray(entry) ? (entry.length > 1 ? entry.shift() : entry[0]) : entry;
    if (scripted == null) return new Response('not found', { status: 404 });
    return new Response(scripted.body == null ? null : JSON.stringify(scripted.body), {
      status: scripted.status,
      headers: { 'content-type': 'application/json', ...(scripted.headers ?? {}) },
    });
  };

  const provider: any = {
    get redirectUrl() {
      return 'http://127.0.0.1:33418/callback';
    },
    get clientMetadata() {
      return { redirect_uris: ['http://127.0.0.1:33418/callback'], client_name: 'Swift AI SDK', scope: 'fallback' };
    },
    tokens: () => state.tokens,
    saveTokens: (tokens: unknown) => {
      calls.push({ method: 'saveTokens', value: tokens });
      state.tokens = tokens as any;
    },
    clientInformation: () => state.clientInformation,
    saveClientInformation: (info: unknown) => {
      calls.push({ method: 'saveClientInformation', value: info });
      state.clientInformation = info as any;
    },
    redirectToAuthorization: (url: URL) => {
      calls.push({ method: 'redirectToAuthorization', value: url.href });
    },
    saveCodeVerifier: (verifier: string) => {
      calls.push({ method: 'saveCodeVerifier', value: verifier });
      state.codeVerifier = verifier;
    },
    codeVerifier: () => state.codeVerifier ?? '',
    invalidateCredentials: (scope: string) => {
      calls.push({ method: 'invalidateCredentials', value: scope });
      if (scope === 'tokens' || scope === 'all') state.tokens = undefined;
      if (scope === 'all' || scope === 'client') state.clientInformation = undefined;
    },
    isClientInformationDynamicallyRegistered: () => state.dynamicallyRegistered ?? false,
    ...(state.storedState != null ? { storedState: () => state.storedState } : {}),
    ...(state.canSaveAuthorizationServerInformation
      ? {
          authorizationServerInformation: () => state.authorizationServerInformation,
          saveAuthorizationServerInformation: (info: unknown) => {
            calls.push({ method: 'saveAuthorizationServerInformation', value: info });
            state.authorizationServerInformation = info as any;
          },
        }
      : {}),
  };

  let result: unknown;
  try {
    result = {
      value: await auth(provider, {
        serverUrl: testCase.serverUrl,
        ...(testCase.options ?? {}),
        ...(testCase.options?.resourceMetadataUrl ? { resourceMetadataUrl: new URL(testCase.options.resourceMetadataUrl) } : {}),
        fetchFn,
      }),
    };
  } catch (error: any) {
    result = { error: error.message };
  }
  output.push({ ...testCase, requests, calls, result });
}

fs.writeFileSync(path.join(outputDir, 'mcp-oauth-conformance.json'), JSON.stringify(output, null, 1) + '\n');
console.log(`wrote ${output.length} OAuth cases`);
