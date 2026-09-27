#!/bin/sh
# Regenerates the upstream conformance fixtures by running the vercel/ai
# TypeScript sources directly. Needs node, a vercel/ai checkout at the commit in
# docs/UPSTREAM.md, and network access for a small temporary npm install.
#
#   Tools/conformance/run.sh /path/to/vercel-ai
set -eu

UPSTREAM=$(cd "$1" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"; rm -f "$UPSTREAM/node_modules"' EXIT

cd "$WORK"
npm init -y >/dev/null
npm install --silent zod@4 eventsource-parser@3 @standard-schema/spec @workflow/serde@4.1.0 undici@7 json-schema tsx@4 pkce-challenge@5 cross-spawn@7
[ -e "$UPSTREAM/node_modules" ] || ln -s "$WORK/node_modules" "$UPSTREAM/node_modules"

cat >tsconfig.json <<EOF
{
  "compilerOptions": {
    "module": "esnext",
    "moduleResolution": "bundler",
    "target": "es2022",
    "paths": {
      "@ai-sdk/provider": ["$UPSTREAM/packages/provider/src/index.ts"],
      "@ai-sdk/provider-utils": ["$UPSTREAM/packages/provider-utils/src/index.ts"],
      "@ai-sdk/provider-utils/*": ["$UPSTREAM/packages/provider-utils/src/*"]
    }
  }
}
EOF

for script in "$HERE"/*.mts; do
  UPSTREAM="$UPSTREAM" TSX_TSCONFIG_PATH="$WORK/tsconfig.json" npx tsx "$script"
done
