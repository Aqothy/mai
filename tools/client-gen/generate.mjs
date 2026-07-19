import { execFileSync } from "node:child_process";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const toolsDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(toolsDir, "../..");
const schemaPath = path.join(repoRoot, "api/generated/client-api.schema.json");
const methodsPath = path.join(repoRoot, "api/generated/rpc-methods.json");
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
    "--out",
    swiftModelsPath,
  ],
  { stdio: "inherit" },
);

let swiftSource = await readFile(swiftModelsPath, "utf8");
const catalogStart = swiftSource.indexOf("/// Client-visible JSON-RPC parameters");
const firstModel = swiftSource.indexOf("// MARK: - ACPRegistryAgent");
if (catalogStart < 0 || firstModel < 0) throw new Error("quicktype Swift catalog was not found");
swiftSource = swiftSource.slice(0, catalogStart) + swiftSource.slice(firstModel);

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
const methodConstants = registry.methods
  .map((method) => `    public static let ${methodKey(method.name)} = ${JSON.stringify(method.name)}`)
  .join("\n");
await writeFile(
  path.join(swiftDir, "MaidRPC.swift"),
  `// Code generated from api/wire/methods.go. DO NOT EDIT.

public enum MaidRPCMethod {
${methodConstants}
}
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
