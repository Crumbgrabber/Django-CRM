/**
 * Holds every `apiRequest` call to the endpoint it names, as `src/lib/api-schema.d.ts`
 * (generated from the backend's OpenAPI schema) describes that endpoint:
 *
 * - the method exists on the path;
 * - the reply type the caller declares can hold the endpoint's success reply;
 * - the body fits the endpoint's request type, sends no field it does not
 *   declare, and is `FormData` only where it takes multipart.
 *
 * A call whose path is built at run time is held to the weaker rule that its
 * reply and body types come from the schema at all. Runs in `pnpm check`.
 */
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import ts from 'typescript';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const SCHEMA_FILES = ['src/lib/api-schema.d.ts', 'src/lib/enterprise-api-schema.d.ts'].map((f) =>
  join(ROOT, f)
);

const config = ts.getParsedCommandLineOfConfigFile(
  join(ROOT, 'tsconfig.json'),
  {},
  {
    ...ts.sys,
    onUnRecoverableConfigFileDiagnostic: (d) => {
      throw new Error(ts.flattenDiagnosticMessageText(d.messageText, '\n'));
    }
  }
);
if (!config) throw new Error('tsconfig.json did not parse');
const program = ts.createProgram({ rootNames: config.fileNames, options: config.options });
const checker = program.getTypeChecker();

type Route = { template: string; segments: (string | null)[]; type: ts.Type };

const routes: Route[] = [];
for (const file of SCHEMA_FILES) {
  const source = program.getSourceFile(file);
  if (!source) throw new Error(`${file} is not in the program`);
  const decl = source.statements.find(
    (s): s is ts.InterfaceDeclaration => ts.isInterfaceDeclaration(s) && s.name.text === 'paths'
  );
  if (!decl) throw new Error(`${file} declares no paths`);
  for (const prop of checker.getTypeAtLocation(decl).getProperties()) {
    const template = prop.getName();
    routes.push({
      template,
      segments: template.split('/').map((seg) => (seg.includes('{') ? null : seg)),
      type: checker.getTypeOfSymbol(prop)
    });
  }
}

const schemaDeclared = (type: ts.Type, seen = new Set<ts.Type>()): boolean => {
  if (seen.has(type)) return false;
  seen.add(type);
  const decls = [
    ...(type.aliasSymbol?.declarations ?? []),
    ...(type.getSymbol()?.declarations ?? [])
  ];
  if (decls.some((d) => SCHEMA_FILES.includes(d.getSourceFile().fileName))) return true;
  if (type.isUnionOrIntersection()) {
    return type.types.every(
      (t) => t.flags & (ts.TypeFlags.Undefined | ts.TypeFlags.Null) || schemaDeclared(t, seen)
    );
  }
  return false;
};

const prop = (type: ts.Type, name: string): ts.Type | undefined => {
  const symbol = type.getProperty(name);
  if (!symbol) return undefined;
  const value = checker.getNonNullableType(checker.getTypeOfSymbol(symbol));
  return value.flags & ts.TypeFlags.Never ? undefined : value;
};

const isOpen = (type: ts.Type) =>
  Boolean(checker.getIndexInfoOfType(type, ts.IndexKind.String)) ||
  (type.flags & (ts.TypeFlags.Any | ts.TypeFlags.Unknown)) !== 0;

/** Fields `sent` declares that `accepted` does not, per member of a union. */
function extraFields(sent: ts.Type, accepted: ts.Type): string[] {
  if (isOpen(accepted)) return [];
  const known = new Set(accepted.getProperties().map((p) => p.getName()));
  const members = sent.isUnion() ? sent.types : [sent];
  return [
    ...new Set(
      members.flatMap((m) =>
        m
          .getProperties()
          .map((p) => p.getName())
          .filter((n) => !known.has(n))
      )
    )
  ];
}

/** A type parameter stands for its constraint: `P extends keyof Replies`. */
const resolved = (type: ts.Type) =>
  type.flags & ts.TypeFlags.Instantiable ? (checker.getBaseConstraintOfType(type) ?? type) : type;

/** The string literals a type is limited to, if it is. */
function literalsOf(type: ts.Type): string[] | null {
  type = resolved(type);
  const members = type.isUnion() ? type.types : [type];
  return members.every((t) => t.isStringLiteral())
    ? members.map((t) => (t as ts.StringLiteralType).value)
    : null;
}

const literals = (node: ts.Expression) => literalsOf(checker.getTypeAtLocation(node));

/**
 * The paths a call names, a segment a substitution fills being null; a
 * substitution typed as string literals stands for each of them. A trailing
 * substitution is the query string, which is not part of the path.
 */
function endpointPaths(node: ts.Expression): (string | null)[][] | null {
  let texts: string[];
  if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) texts = [node.text];
  else if (ts.isTemplateExpression(node)) {
    texts = [node.head.text];
    for (const span of node.templateSpans) {
      const known = literals(span.expression) ?? ['\u0000'];
      texts = texts.flatMap((t) => known.map((k) => t + k + span.literal.text));
    }
  } else {
    const known = literals(node);
    if (!known) return null;
    texts = known;
  }
  return texts.map((text) => {
    text = text.split('?')[0];
    if (text.endsWith('/\u0000')) text = text.slice(0, -1);
    return `/api${text}`.split('/').map((seg) => (seg.includes('\u0000') ? null : seg));
  });
}

/**
 * The schema paths a call can reach: those sharing the most literal segments
 * with it, then those whose parameters line up with its substitutions. A call
 * that fills a segment the schema names (`/${module}/${id}/merge/`) is held to
 * every path it can reach.
 */
function routesFor(segments: (string | null)[]): Route[] {
  const fits = routes.filter(
    (r) =>
      r.segments.length === segments.length &&
      r.segments.every((seg, i) => seg === null || segments[i] === null || seg === segments[i])
  );
  const shared = (r: Route) =>
    r.segments.filter((seg, i) => seg !== null && seg === segments[i]).length;
  const loose = (r: Route) =>
    r.segments.filter((seg, i) => seg !== null && segments[i] === null).length;
  const best = Math.max(...fits.map(shared));
  const top = fits.filter((r) => shared(r) === best);
  const tightest = Math.min(...top.map(loose));
  return top.filter((r) => loose(r) === tightest);
}

const discarded = (call: ts.Node) => {
  let node = call.parent;
  if (ts.isAwaitExpression(node)) node = node.parent;
  return ts.isExpressionStatement(node) || ts.isVoidExpression(node);
};

const problems: string[] = [];
let held = 0;

for (const source of program.getSourceFiles()) {
  const file = source.fileName;
  if (!file.startsWith(join(ROOT, 'src')) || /\.(test|d)\.ts$/.test(file)) continue;
  const visit = (node: ts.Node) => {
    if (
      ts.isCallExpression(node) &&
      ts.isIdentifier(node.expression) &&
      node.expression.text === 'apiRequest'
    ) {
      check(node, source);
    }
    ts.forEachChild(node, visit);
  };
  visit(source);
}

function check(call: ts.CallExpression, source: ts.SourceFile) {
  const where = `${source.fileName.slice(ROOT.length + 1)}:${source.getLineAndCharacterOfPosition(call.getStart()).line + 1}`;
  const options = call.arguments[1];
  const literal = options && ts.isObjectLiteralExpression(options) ? options : undefined;
  const member = (name: string) =>
    literal?.properties.find((p) => p.name?.getText(source) === name) as
      ts.PropertyAssignment | ts.ShorthandPropertyAssignment | undefined;
  const methodNode = member('method');
  // A method typed as literals (`'PUT' | 'PATCH'`) is held to each of them.
  const methods = !methodNode
    ? ['get']
    : (ts.isPropertyAssignment(methodNode)
        ? literals(methodNode.initializer)
        : literalsOf(
            checker.getTypeOfSymbol(checker.getShorthandAssignmentValueSymbol(methodNode)!)
          )
      )?.map((m) => m.toLowerCase());
  const bodyNode = member('body');
  const bodyExpr = bodyNode
    ? ts.isShorthandPropertyAssignment(bodyNode)
      ? bodyNode.name
      : bodyNode.initializer
    : undefined;
  const signature = checker.getResolvedSignature(call);
  const returned = signature
    ? checker.getAwaitedType(checker.getReturnTypeOfSignature(signature))
    : undefined;
  const reply = returned && resolved(returned);
  const untypedReply = !reply || (reply.flags & (ts.TypeFlags.Unknown | ts.TypeFlags.Any)) !== 0;
  const body = bodyExpr ? checker.getTypeAtLocation(bodyExpr) : undefined;
  const isFormData = body?.getSymbol()?.getName() === 'FormData';

  const paths = endpointPaths(call.arguments[0]);
  const reached = [...new Set((paths ?? []).flatMap(routesFor))];
  held++;
  const missing = (paths ?? []).filter((p) => !routesFor(p).length);
  for (const p of missing)
    problems.push(`${where}: ${p.map((s) => s ?? '{}').join('/')} is not in the API schema`);

  if (!reached.length || !methods) {
    // Built at run time: the reply and body must at least be schema types.
    if (!untypedReply && reply && !schemaDeclared(reply) && !(reply.flags & ts.TypeFlags.Null))
      problems.push(`${where}: reply type is not from the API schema`);
    if (body && !isFormData && !schemaDeclared(body))
      problems.push(`${where}: body type is not from the API schema`);
    return;
  }
  for (const route of reached)
    for (const method of methods)
      checkOperation(route, method, where, call, reply, untypedReply, body, isFormData);
}

function checkOperation(
  route: Route,
  method: string,
  where: string,
  call: ts.CallExpression,
  reply: ts.Type | undefined,
  untypedReply: boolean,
  body: ts.Type | undefined,
  isFormData: boolean
) {
  const operation = prop(route.type, method);
  const label = `${method.toUpperCase()} ${route.template}`;
  if (!operation) {
    problems.push(`${where}: ${label} is not an operation the API has`);
    return;
  }

  const responses = prop(operation, 'responses');
  const replies = (responses?.getProperties() ?? [])
    .filter((p) => p.getName().startsWith('2'))
    .map((p) =>
      prop(
        prop(checker.getTypeOfSymbol(p), 'content') ?? checker.getNeverType(),
        'application/json'
      )
    )
    .filter((t): t is ts.Type => Boolean(t));
  if (replies.length && untypedReply && !discarded(call))
    problems.push(`${where}: ${label} replies with a body the caller leaves untyped`);
  if (replies.length && !untypedReply && reply) {
    for (const expected of replies) {
      if (!checker.isTypeAssignableTo(expected, reply))
        problems.push(
          `${where}: ${label} replies ${checker.typeToString(expected)}, not ${checker.typeToString(reply)}`
        );
    }
  }

  if (!body) return;
  const content = prop(prop(operation, 'requestBody') ?? checker.getNeverType(), 'content');
  if (!content) {
    problems.push(`${where}: ${label} takes no body in the schema`);
    return;
  }
  if (isFormData) {
    if (!prop(content, 'multipart/form-data'))
      problems.push(`${where}: ${label} does not take multipart`);
    return;
  }
  const accepted = prop(content, 'application/json');
  if (!accepted) {
    problems.push(`${where}: ${label} takes no JSON body`);
    return;
  }
  const named =
    body.aliasSymbol?.getName() === 'FormBody' ? body.aliasTypeArguments?.[0] : undefined;
  if (named) {
    const extra = extraFields(named, accepted);
    if (!schemaDeclared(named))
      problems.push(
        `${where}: ${label} body is a FormBody of ${checker.typeToString(named)}, not of a schema type`
      );
    else if (extra.length)
      problems.push(`${where}: ${label} body FormBody can send undeclared ${extra.join(', ')}`);
    return;
  }
  // A string index fits any all-optional request type, so it checks nothing.
  if (isOpen(body)) {
    problems.push(`${where}: ${label} body ${checker.typeToString(body)} names no fields`);
    return;
  }
  if (!checker.isTypeAssignableTo(body, accepted))
    problems.push(
      `${where}: ${label} body ${checker.typeToString(body)} does not fit ${checker.typeToString(accepted)}`
    );
  const extra = extraFields(body, accepted);
  if (extra.length) problems.push(`${where}: ${label} body sends undeclared ${extra.join(', ')}`);
}

if (problems.length) {
  console.error(`api-contract: ${problems.length} of ${held} API calls break the schema:`);
  for (const p of problems) console.error(`  ${p}`);
  process.exit(1);
}
console.log(`api-contract: ${held} API calls match the schema`);
