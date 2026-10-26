import { readFileSync, readdirSync } from 'node:fs';
import { join, relative } from 'node:path';
import { describe, expect, it } from 'vitest';

/*
 * App code carries no `any`, written or implied. `noImplicitAny` catches an
 * untyped parameter, but TypeScript cannot forbid an `any` written in JSDoc,
 * and an untyped `$props()` makes every prop `any` without a word. Hand-written
 * `.d.ts` files are checked too; the generated `api-schema.d.ts` is not. Tests may
 * use `any` for doubles, so `*.test.js` is skipped. For an untyped API reply,
 * fix the backend schema (backend/common/schema_contract.py) rather than
 * writing `any`; for data that really is arbitrary, use `unknown`.
 */
const SRC = new URL('../', import.meta.url).pathname;
const TAG = /@(?:type|param|returns?|typedef|property|prop|template|satisfies|this)\s*\{/g;

/** @param {string} dir @returns {string[]} */
function sourceFiles(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return sourceFiles(path);
    if (entry.name.endsWith('.test.js') || entry.name === 'api-schema.d.ts') return [];
    return /\.(js|svelte|d\.ts)$/.test(entry.name) ? [path] : [];
  });
}

/** The type expression starting at the `{` at `open`, braces balanced. */
function typeExpression(/** @type {string} */ text, /** @type {number} */ open) {
  let depth = 0;
  for (let i = open; i < text.length; i++) {
    if (text[i] === '{') depth++;
    else if (text[i] === '}' && --depth === 0) return text.slice(open, i + 1);
  }
  return text.slice(open);
}

/** @param {string} text @param {number} index */
const lineOf = (text, index) => text.slice(0, index).split('\n').length;

/** Every `any` in a JSDoc type, and every `$props()` with no type, as file:line. */
function findAny(/** @type {string} */ file) {
  const text = readFileSync(file, 'utf8');
  const where = relative(SRC, file);
  /** @type {string[]} */
  const found = [];
  if (file.endsWith('.d.ts')) {
    const code = text.replace(/\/\*[\s\S]*?\*\/|\/\/.*$/gm, (c) => c.replace(/[^\n]/g, ' '));
    for (const word of code.matchAll(/\bany\b/g))
      found.push(`${where}:${lineOf(text, word.index ?? 0)}`);
    return found;
  }
  for (const comment of text.matchAll(/\/\*\*[\s\S]*?\*\//g)) {
    for (const tag of comment[0].matchAll(TAG)) {
      const start = (comment.index ?? 0) + (tag.index ?? 0) + tag[0].length - 1;
      const expression = typeExpression(text, start);
      for (const word of expression.matchAll(/\bany\b/g)) {
        found.push(`${where}:${lineOf(text, start + (word.index ?? 0))}`);
      }
    }
  }
  for (const call of text.matchAll(/\$props\(\)/g)) {
    const statement =
      text
        .slice(0, call.index)
        .split(/;|<script[^>]*>/)
        .at(-1) ?? '';
    if (!/@type\s*\{/.test(statement))
      found.push(`${where}:${lineOf(text, call.index ?? 0)} ($props)`);
  }
  return found;
}

describe('app code', () => {
  it('has no any', () => {
    expect(sourceFiles(SRC).flatMap(findAny)).toEqual([]);
  });
});
