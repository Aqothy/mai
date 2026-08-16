import { execFileSync } from "node:child_process";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const toolsDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(toolsDir, "../..");
const schemaPath = path.join(repoRoot, "api/generated/client-api.schema.json");
const methodsPath = path.join(repoRoot, "api/generated/rpc-methods.json");
const vocabularyPath = path.join(repoRoot, "api/generated/vocabulary.json");
const swiftDir = path.join(repoRoot, "clients/swift/mai/Generated");
const swiftModelsPath = path.join(swiftDir, "MaidModels.swift");

await rm(swiftDir, { recursive: true, force: true });
await mkdir(swiftDir, { recursive: true });
execFileSync(
  path.join(toolsDir, "node_modules/.bin/quicktype"),
  [
    "--quiet",
    "--src",
    schemaPath,
    "--src-lang",
    "schema",
    "--lang",
    "swift",
    "--top-level",
    "MaidClientAPI",
    "--access-level",
    "public",
    "--mutable-properties",
    "--out",
    swiftModelsPath,
  ],
  { stdio: "inherit" },
);

let swiftSource = await readFile(swiftModelsPath, "utf8");
const catalogStart = swiftSource.indexOf("/// Client-visible JSON-RPC parameters");
const catalogModel = swiftSource.indexOf("// MARK: - MaidClientAPI", Math.max(catalogStart, 0));
const firstModel = swiftSource.indexOf("// MARK: - ", catalogModel + 1);
if (catalogStart < 0 || catalogModel < 0 || firstModel < 0) {
  throw new Error("quicktype Swift catalog was not found");
}
swiftSource = swiftSource.slice(0, catalogStart) + swiftSource.slice(firstModel);

if (!swiftSource.includes("public var timeline: [TimelineEntry]")) {
  throw new Error("quicktype did not generate mutable model properties");
}

const jsonAnyDecoder = "    public required init(from decoder: Decoder) throws {";
const decoderIndex = swiftSource.lastIndexOf(jsonAnyDecoder);
if (decoderIndex < 0) throw new Error("quicktype JSONAny decoder was not found");
swiftSource =
  swiftSource.slice(0, decoderIndex) +
  `    /// Wraps a JSON-compatible Swift value for arbitrary wire fields.
    public init(_ value: Any) {
        self.value = value
    }

` +
  swiftSource.slice(decoderIndex);

const codingKeyClass = "class JSONCodingKey: CodingKey {";
if (!swiftSource.includes(codingKeyClass)) {
  throw new Error("quicktype JSONCodingKey helper was not found");
}
swiftSource = swiftSource.replace(
  codingKeyClass,
  "final class JSONCodingKey: CodingKey {",
);

await writeFile(swiftModelsPath, swiftSource);

const registry = JSON.parse(await readFile(methodsPath, "utf8"));
const rpcNames = [...new Set([
  ...registry.methods.map((method) => method.name),
  ...registry.notifications.map((notification) => notification.name),
])];
const methodConstants = rpcNames
  .map((name) => `    public static let ${methodKey(name)} = ${JSON.stringify(name)}`)
  .join("\n");
await writeFile(
  path.join(swiftDir, "MaidRPC.swift"),
  `// Code generated from api/wire/methods.go. DO NOT EDIT.

nonisolated public enum MaidRPCMethod {
${methodConstants}
}
`,
);

const { vocabularies } = JSON.parse(await readFile(vocabularyPath, "utf8"));
const vocabularyEnums = vocabularies
  .map((vocabulary) => {
    const doc = vocabulary.description ? `/// ${vocabulary.description}\n` : "";
    const cases = vocabulary.values
      .map((value) => `    case ${caseName(value)} = ${JSON.stringify(value)}`)
      .join("\n");
    return `${doc}public enum Maid${vocabulary.name}: String, Codable, Sendable, CaseIterable {
${cases}
}`;
  })
  .join("\n\n");
await writeFile(
  path.join(swiftDir, "MaidVocabulary.swift"),
  `// Code generated from api/wire/vocabulary.go. DO NOT EDIT.
//
// Closed string vocabularies the daemon sends. The wire models keep these
// fields as plain String on purpose, so an unknown value from a newer daemon
// still decodes; use \`Maid<Name>(rawValue:)\` to branch and treat nil as
// "unrecognized" rather than as an error.

${vocabularyEnums}
`,
);

function methodKey(name) {
  const words = name.split(/[^A-Za-z0-9]+/).filter(Boolean);
  return (
    words[0].toLowerCase() +
    words
      .slice(1)
      .map((word) => word[0].toUpperCase() + word.slice(1))
      .join("")
  );
}

// Vocabulary values mix separator styles ("thread.meta-updated", "in_progress")
// with values that are already camelCase ("acceptForSession"), so the first
// word is lower-FIRSTed rather than lowercased wholesale.
function caseName(value) {
  const words = value.split(/[^A-Za-z0-9]+/).filter(Boolean);
  const [first, ...rest] = words;
  return (
    first[0].toLowerCase() +
    first.slice(1) +
    rest.map((word) => word[0].toUpperCase() + word.slice(1)).join("")
  );
}
