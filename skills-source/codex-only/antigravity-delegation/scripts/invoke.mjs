import { createHash } from "node:crypto";
import { lstat, readFile } from "node:fs/promises";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const hash = bytes => createHash("sha256").update(bytes).digest("hex");
const fail = code => { throw new Error(code); };
const object = value => value !== null && typeof value === "object" && !Array.isArray(value);
const keys = (value, allowed) => Object.keys(value).every(key => allowed.includes(key));

async function plainPath(path, { directory = false, missing = false } = {}) {
  if (typeof path !== "string" || !isAbsolute(path) || path.includes("\0") || path.split(/[\\/]/).some(part => part === "." || part === "..")) fail("ABSOLUTE_CANONICAL_PATH_REQUIRED");
  let cursor = path, first = true;
  while (true) {
    try {
      const item = await lstat(cursor);
      if (item.isSymbolicLink()) fail("REPARSE_PATH_REFUSED");
      if (first && (directory ? !item.isDirectory() : !item.isFile())) fail("INSTALLATION_PATH_TYPE_INVALID");
    } catch (error) {
      if (!(missing && first && error.code === "ENOENT")) throw error;
    }
    const parent = dirname(cursor);
    if (parent === cursor) break;
    cursor = parent;
    first = false;
  }
}

async function readJson(path) {
  await plainPath(path);
  const bytes = await readFile(path);
  if (bytes.length > 1024 * 1024) fail("CONFIGURATION_TOO_LARGE");
  return { value: JSON.parse(bytes.toString("utf8").replace(/^\uFEFF/, "")), sha256: hash(bytes) };
}

export function parseArguments(args) {
  const options = {};
  for (let index = 0; index < args.length; index++) {
    const flag = args[index];
    if (flag === "--preflight" && !options.preflight) options.preflight = true;
    else if (flag === "--package" && options.packagePath === undefined && args[index + 1] && !args[index + 1].startsWith("--")) options.packagePath = args[++index];
    else if (flag === "--resume-successor" && options.successorPath === undefined && args[index + 1] && !args[index + 1].startsWith("--")) options.successorPath = args[++index];
    else fail("USAGE_PACKAGE_WITH_OPTIONAL_PREFLIGHT");
  }
  if (!options.packagePath) fail("PACKAGE_REQUIRED");
  return options;
}

/** Injection is for offline fixtures; the CLI always uses the fixed private root. */
export async function prepareInvocation(options, configurationRoot) {
  if (!configurationRoot || !isAbsolute(configurationRoot)) fail("LOCALAPPDATA_REQUIRED");
  configurationRoot = resolve(configurationRoot);
  await plainPath(configurationRoot, { directory: true });
  const deployment = await readJson(join(configurationRoot, "deployment.json"));
  const config = deployment.value;
  if (!object(config) || !keys(config, ["enabled", "channel", "consumerUseAcknowledged", "bridgeRoot", "agyPath", "catalogPath", "stateRoot", "settingsPath"])
      || typeof config.enabled !== "boolean" || typeof config.consumerUseAcknowledged !== "boolean" || config.channel !== "native-agy") fail("DEPLOYMENT_INVALID");
  if (typeof config.stateRoot !== "string" || resolve(config.stateRoot) !== join(configurationRoot, "state")) fail("FIXED_STATE_ROOT_REQUIRED");
  await plainPath(config.stateRoot, { directory: true, missing: true });
  await plainPath(config.bridgeRoot, { directory: true });
  await plainPath(config.agyPath);
  const runnerPath = join(config.bridgeRoot, "scripts", "antigravity-delegation.mjs");
  await plainPath(runnerPath);
  const routesPath = join(configurationRoot, "routes.json");
  const routes = await readJson(routesPath);
  if (!object(routes.value) || !keys(routes.value, ["primary", "fallback"])) fail("ROUTES_INVALID");
  for (const role of ["primary", "fallback"]) {
    const route = routes.value[role];
    if (!object(route) || !keys(route, ["model"]) || typeof route.model !== "string" || !route.model.trim()) fail("ROUTES_INVALID");
  }
  if (routes.value.primary.model === routes.value.fallback.model) fail("DISTINCT_ROLES_REQUIRED");
  const catalog = await readJson(config.catalogPath);
  const settings = await readJson(config.settingsPath);
  const workPackage = await readJson(options.packagePath);
  const successor = options.successorPath === undefined ? undefined : await readJson(options.successorPath);
  if (workPackage.value.configSha256 !== routes.sha256) fail("PACKAGE_ROUTE_DIGEST_MISMATCH");
  if (!options.preflight && (!config.enabled || !config.consumerUseAcknowledged)) fail("DELEGATION_NOT_ENABLED");
  const args = ["--package", options.packagePath, "--routes", routesPath, "--catalog", config.catalogPath,
    "--state-root", config.stateRoot, "--agy", config.agyPath, "--expected-routes-sha256", routes.sha256];
  args.push("--settings", config.settingsPath);
  if (options.preflight) args.push("--preflight");
  if (options.successorPath !== undefined) args.push("--resume-successor", options.successorPath);
  return { runnerPath, args, enabled: config.enabled && config.consumerUseAcknowledged,
    frozen: { deployment: deployment.sha256, routes: routes.sha256, catalog: catalog.sha256,
      settings: settings.sha256, package: workPackage.sha256, successor: successor?.sha256 ?? null } };
}

export async function main(args = process.argv.slice(2)) {
  const options = parseArguments(args);
  const local = process.env.LOCALAPPDATA;
  if (!local) fail("LOCALAPPDATA_REQUIRED");
  const invocation = await prepareInvocation(options, join(local, "agent-delegation"));
  if (options.preflight) {
    // The runner's preflight is a pure JSON/schema check, not an engine launch.
    process.stdout.write(JSON.stringify({ entry: "antigravity-delegation", enabled: invocation.enabled, frozen: invocation.frozen }) + "\n");
  }
  // Share the runner's signal/held-Job lifecycle instead of adding an unowned child host.
  const runner = await import(pathToFileURL(invocation.runnerPath).href);
  if (typeof runner.main !== "function") fail("MANAGED_ENTRY_INTERFACE_INVALID");
  return await runner.main(invocation.args);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().then(code => { if (Number.isInteger(code)) process.exitCode = code; }).catch(error => {
    process.stderr.write(JSON.stringify({ error: error.code ?? error.message }) + "\n");
    process.exitCode = 1;
  });
}
