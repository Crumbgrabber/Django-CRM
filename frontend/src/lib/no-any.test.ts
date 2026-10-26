import { readFileSync, readdirSync } from 'node:fs';
import { join, relative } from 'node:path';
import ts from 'typescript';
import { describe, expect, it } from 'vitest';

/*
 * App code carries no `any`, written or implied. `noImplicitAny` catches an
 * untyped parameter and ESLint (`@typescript-eslint/no-explicit-any`) a written
 * `any`, hand-written `.d.ts` files included, but neither notices a `$props()`
 * with no type, which makes every prop `any` without a word. This test does.
 * For an untyped API reply, fix the backend schema
 * (backend/common/schema_contract.py) rather than writing `any`; for data that
 * really is arbitrary, use `unknown`.
 */
const SRC = new URL('../', import.meta.url).pathname;

function components(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return components(path);
    return entry.name.endsWith('.svelte') ? [path] : [];
  });
}

/**
 * Every `$props()` declared without a type, as file:line. Parsed, not
 * pattern-matched: a props type spans lines and holds `;` and `=>`.
 */
function untypedProps(file: string): string[] {
  const text = readFileSync(file, 'utf8');
  const found: string[] = [];
  for (const block of text.matchAll(/(<script\b[^>]*>)([\s\S]*?)<\/script>/g)) {
    if (!block[2].includes('$props()')) continue;
    const at = (block.index ?? 0) + block[1].length;
    const sf = ts.createSourceFile(file, block[2], ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
    const visit = (node: ts.Node) => {
      if (ts.isCallExpression(node) && node.expression.getText(sf) === '$props') {
        const decl = node.parent;
        if (!ts.isVariableDeclaration(decl) || !decl.type) {
          const line = text.slice(0, at + node.getStart(sf)).split('\n').length;
          found.push(`${relative(SRC, file)}:${line}`);
        }
      }
      ts.forEachChild(node, visit);
    };
    visit(sf);
  }
  return found;
}

describe('app code', () => {
  it('types every $props()', () => {
    expect(components(SRC).flatMap(untypedProps)).toEqual([]);
  });
});
