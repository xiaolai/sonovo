#!/usr/bin/env bash
# Rebuild the bundled MDX compiler and browser runtime.
#
# Maintenance only: needs network and Node. The built files are committed
# under Sources/Sonovo/Resources and packaged by Scripts/package-app.sh. Bump
# the versions below and MDXCompiler.version together.
set -euo pipefail

mdx_version="3.1.1"
sucrase_version="3.35.1"
react_version="19.3.1"
esbuild_version="0.28.2"
acorn_version="8.15.0"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

cd "$scratch"
npm init -y >/dev/null
npm install --no-audit --no-fund \
    "@mdx-js/mdx@${mdx_version}" \
    "sucrase@${sucrase_version}" \
    "react@${react_version}" \
    "react-dom@${react_version}" \
    "esbuild@${esbuild_version}" \
    "acorn@${acorn_version}" >/dev/null

cat > compiler-entry.js <<'JS'
import { compileSync, createProcessor } from '@mdx-js/mdx';
import { transform } from 'sucrase';
import { parse } from 'acorn';

// The compiler reports each module's static ESM dependencies. The app
// resolves and reads them; this bundle never touches the filesystem. Parsing
// the source, rather than scanning compiled output, is what keeps an
// `import` inside a code fence or a comment from becoming a dependency.
const mdxProcessor = createProcessor({
  outputFormat: 'program',
  jsx: false,
  jsxImportSource: 'react',
  development: false
});

function importsFromProgram(program) {
  const found = [];
  for (const statement of program.body || []) {
    if (statement.type === 'ImportDeclaration' && statement.source) {
      found.push(statement.source.value);
    }
    if ((statement.type === 'ExportNamedDeclaration'
         || statement.type === 'ExportAllDeclaration')
        && statement.source) {
      found.push(statement.source.value);
    }
  }
  return found;
}

function staticImports(id, source) {
  if (/\.mdx$/i.test(id)) {
    const tree = mdxProcessor.parse(source);
    const found = [];
    for (const node of tree.children || []) {
      if (node.type === 'mdxjsEsm' && node.data && node.data.estree) {
        found.push(...importsFromProgram(node.data.estree));
      }
    }
    return found;
  }
  const stripped = transform(source, {
    transforms: /\.jsx$/i.test(id) ? ['jsx'] : [],
    jsxRuntime: 'classic',
    production: true,
    filePath: id
  }).code;
  return importsFromProgram(parse(stripped, {
    ecmaVersion: 'latest',
    sourceType: 'module',
    allowHashBang: true
  }));
}

function toCommonJS(id, source) {
  let code = source;
  if (/\.mdx$/i.test(id)) {
    code = String(compileSync(source, {
      outputFormat: 'program',
      jsx: false,
      jsxImportSource: 'react',
      development: false
    }));
  }
  const withJSX = /\.(mdx|jsx)$/i.test(id);
  let output = transform(code, {
    transforms: withJSX ? ['jsx', 'imports'] : ['imports'],
    jsxRuntime: 'classic',
    production: true,
    filePath: id
  }).code;
  if (/\.jsx$/i.test(id)) {
    output = 'const React = require("react");\n' + output;
  }
  return output;
}

globalThis.__sonovoCompile = function(requestJSON) {
  try {
    const request = JSON.parse(requestJSON);
    const modules = [];
    for (const id of Object.keys(request.files)) {
      modules.push({
        id: id,
        code: toCommonJS(id, request.files[id]),
        imports: staticImports(id, request.files[id])
      });
    }
    return JSON.stringify({
      ok: true,
      entry: request.entry,
      modules: modules
    });
  } catch (error) {
    return JSON.stringify({
      ok: false,
      error: String((error && error.message) || error),
      line: error && error.line,
      column: error && error.column
    });
  }
};
JS

cat > runtime-entry.js <<'JS'
import * as React from 'react';
import * as ReactDOM from 'react-dom/client';
import * as jsxRuntime from 'react/jsx-runtime';

globalThis.React = React;
globalThis.ReactDOM = ReactDOM;
globalThis.__sonovoJSXRuntime = jsxRuntime;
JS

node_modules/.bin/esbuild compiler-entry.js --bundle --format=iife --minify \
    --platform=neutral --main-fields=module,main \
    --define:process.env.NODE_ENV='"production"' \
    --outfile=mdx-compiler.js >/dev/null
node_modules/.bin/esbuild runtime-entry.js --bundle --format=iife --minify \
    --platform=browser --define:process.env.NODE_ENV='"production"' \
    --outfile=mdx-runtime.js >/dev/null

cp mdx-compiler.js "$repo_root/Sources/Sonovo/Resources/mdx-compiler-${mdx_version}.js"
cp mdx-runtime.js "$repo_root/Sources/Sonovo/Resources/mdx-runtime-${react_version}.js"

cd "$repo_root"
shasum -a 256 \
    "Sources/Sonovo/Resources/mdx-compiler-${mdx_version}.js" \
    "Sources/Sonovo/Resources/mdx-runtime-${react_version}.js"
