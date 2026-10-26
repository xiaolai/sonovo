#!/usr/bin/env bash
# Rebuild the bundled Graphviz/Markmap diagram engines.
#
# This is a maintenance script, not part of the build. It needs network access
# and Node; the built files are committed under Sources/Sonovo/Resources and
# packaged by Scripts/package-app.sh. Bump the versions below and
# MermaidRendererPolicy's renderer version together.
set -euo pipefail

viz_version="3.31.0"
markmap_version="0.18.12"
d3_version="7.9.0"
esbuild_version="0.28.2"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

curl -sS -o "$scratch/viz.tgz" \
    "https://registry.npmjs.org/@viz-js/viz/-/viz-${viz_version}.tgz"
mkdir "$scratch/viz"
tar xzf "$scratch/viz.tgz" -C "$scratch/viz" --strip-components=1
cp "$scratch/viz/dist/viz-global.js" \
    "Sources/Sonovo/Resources/viz-global-${viz_version}.min.js"

mkdir "$scratch/markmap"
cd "$scratch/markmap"
npm init -y >/dev/null
npm install --no-audit --no-fund \
    "markmap-lib@${markmap_version}" \
    "markmap-view@${markmap_version}" \
    "d3@${d3_version}" \
    "esbuild@${esbuild_version}" >/dev/null

cat > entry.js <<'JS'
import { Transformer } from 'markmap-lib';
import { Markmap } from 'markmap-view';

const transformer = new Transformer([]);
const settle = () => new Promise((resolve) => setTimeout(resolve, 30));

function flattenLabels(svg, color) {
  const nodes = Array.from(svg.querySelectorAll('foreignObject'));
  for (const foreign of nodes) {
    const text = (foreign.textContent || '').replace(/\s+/g, ' ').trim();
    const box = foreign.getBBox();
    const replacement = document.createElementNS('http://www.w3.org/2000/svg', 'text');
    replacement.setAttribute('x', String((box.x || 0) + 2));
    replacement.setAttribute('y', String((box.y || 0) + (box.height || 16) / 2));
    replacement.setAttribute('dominant-baseline', 'central');
    replacement.setAttribute('font-size', '16');
    replacement.setAttribute('fill', color);
    replacement.textContent = text;
    foreign.replaceWith(replacement);
  }
}

window.__sonovoRenderMarkmap = async function(source, identifier, configuration) {
  let container = null;
  try {
    const options = JSON.parse(configuration || '{}');
    const width = Number(options.width) > 0 ? Number(options.width) : 1200;
    const height = Number(options.height) > 0 ? Number(options.height) : 800;
    const textColor = typeof options.textColor === 'string'
      ? options.textColor
      : '#333333';
    const { root } = transformer.transform(source);
    container = document.createElement('div');
    container.style.width = width + 'px';
    container.style.height = height + 'px';
    container.style.position = 'absolute';
    container.style.left = '-20000px';
    container.style.top = '0';
    document.body.appendChild(container);
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('id', identifier);
    svg.setAttribute('xmlns', 'http://www.w3.org/2000/svg');
    svg.style.width = '100%';
    svg.style.height = '100%';
    container.appendChild(svg);
    const markmap = Markmap.create(svg, {
      autoFit: false,
      duration: 0,
      initialExpandLevel: -1
    }, root);
    markmap.fit();
    await settle();
    await settle();
    flattenLabels(svg, textColor);
    svg.removeAttribute('style');
    svg.setAttribute('viewBox', '0 0 ' + width + ' ' + height);
    svg.setAttribute('width', String(width));
    svg.setAttribute('height', String(height));
    const markup = svg.outerHTML;
    markmap.destroy();
    return JSON.stringify({ svg: markup });
  } catch (error) {
    return JSON.stringify({ error: String((error && error.message) || error) });
  } finally {
    if (container) { container.remove(); }
  }
};
JS

node_modules/.bin/esbuild entry.js --bundle --format=iife --minify \
    --outfile=markmap.min.js >/dev/null
cp markmap.min.js \
    "$repo_root/Sources/Sonovo/Resources/markmap-${markmap_version}.min.js"

shasum -a 256 \
    "Sources/Sonovo/Resources/viz-global-${viz_version}.min.js" \
    "Sources/Sonovo/Resources/markmap-${markmap_version}.min.js"
