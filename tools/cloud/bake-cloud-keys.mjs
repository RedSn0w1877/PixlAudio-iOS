#!/usr/bin/env node
// Bakes PixlAudio's built-in cloud keys (Cloud processing works out of the box, iOS and Android).
// No dependencies: Node's own crypto, fs and child_process. Run it yourself; the values never leave this PC except
// as the encrypted blobs (committed) and the decryption key (a GitHub secret). Nothing it prints is a value.
//
//   node tools/cloud/bake-cloud-keys.mjs            prompts for the three secrets (hidden input), then does it all
//   node tools/cloud/bake-cloud-keys.mjs --help     every flag
//
// Format (both apps): ASCII "PXCD1" + 12-byte random nonce + AES-256-GCM(ciphertext) + 16-byte tag, over the UTF-8
// JSON {"v":1,"runpodEndpointId","runpodKey","r2Endpoint","bucket","r2AccessKeyId","r2SecretAccessKey"}.
// Readers: PixlNet's CloudDefaultsBlob/CloudDefaultsPayload + the app's CloudDefaultsCrypto (iOS); Android later.

import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// ---- Hoa's setup (not secret) ----------------------------------------------------------------------------------
const DEFAULTS = {
  endpointId: 'r3wc9ybg5n4mej', // RunPod endpoint pixl-cloud-studio
  r2Endpoint: 'https://49083275082e89f3a024292385941801.r2.cloudflarestorage.com',
  bucket: 'pixl-cloud-studio',
  iosRepo: 'C:/Users/Hoa/Downloads/Code Projects/PixlAudio-iOS',
  androidRepo: 'C:/Users/Hoa/Downloads/Code Projects/PixelPlayer-master/beta2-release',
  iosGitHub: 'RedSn0w1877/PixlAudio-iOS',
  androidGitHub: 'RedSn0w1877/PixlAudio',
};
const IOS_BLOB = 'App/Resources/CloudDefaults.enc';
const ANDROID_BLOB = 'app/src/main/assets/cloud_defaults.enc';
const IOS_KEY_STUB = 'App/Generated/CloudDefaultsKey.swift';
const SECRET_NAME = 'CLOUD_DEFAULTS_KEY';
const MAGIC = Buffer.from('PXCD1', 'ascii');

// The committed placeholder blob (before the real one is baked) is encrypted with this THROWAWAY key over dummy values,
// so builds and tests work without any secret. It protects nothing and opens nothing real; AppTests use it too.
const PLACEHOLDER_KEY = '8So6sYvJwxeya05DKvPe8+SXf78b9qOdon/a66BjyQw=';
const PLACEHOLDER_VALUES = {
  runpodEndpointId: 'placeholder0endpoint',
  runpodKey: 'rpa_PLACEHOLDER_NOT_A_REAL_KEY',
  r2Endpoint: 'https://00000000000000000000000000000000.r2.cloudflarestorage.com',
  bucket: 'pixl-cloud-studio',
  r2AccessKeyId: '00000000000000000000000000000000',
  r2SecretAccessKey: 'placeholder-secret-not-a-real-one',
};

const HELP = `Bake PixlAudio's built-in cloud keys into the iOS and Android apps.

Usage:
  node tools/cloud/bake-cloud-keys.mjs [flags]

What it does (prints only what it changed, never a value):
  1. Reads the RunPod Restricted key, the R2 access key ID and the R2 secret access key: from the environment
     (PIXL_RUNPOD_KEY, PIXL_R2_KEY_ID, PIXL_R2_SECRET) or, for any that is unset, a hidden prompt (paste + Enter).
  2. Reuses the decryption key in %USERPROFILE%\\.pixlaudio\\cloud_defaults_key, or creates it (32 random bytes,
     base64). Keep that file: losing it only means baking again.
  3. Writes the encrypted blob to
       <ios repo>/${IOS_BLOB}
       <android repo>/${ANDROID_BLOB}
     (same format; each with its own random nonce) and checks that both open again.
  4. Sets the GitHub Actions secret ${SECRET_NAME} on ${DEFAULTS.iosGitHub} and ${DEFAULTS.androidGitHub} (gh CLI).
  5. Adds ${SECRET_NAME}=... to <android repo>/local.properties (only when git ignores that file there), or updates it.
  6. Tells you how to commit the two .enc files (or commits them itself with --commit; it never pushes).

Flags:
  --ios-repo DIR        iOS checkout (default: ${DEFAULTS.iosRepo})
  --android-repo DIR    Android checkout (default: ${DEFAULTS.androidRepo})
  --endpoint-id ID      RunPod endpoint id (default: ${DEFAULTS.endpointId})
  --r2-endpoint URL     R2 endpoint (default: ${DEFAULTS.r2Endpoint})
  --bucket NAME         R2 bucket (default: ${DEFAULTS.bucket})
  --key-file FILE       the decryption key file (default: %USERPROFILE%\\.pixlaudio\\cloud_defaults_key)
  --no-secrets          don't touch the GitHub secrets
  --no-local-properties don't touch the Android local.properties
  --commit              git add + commit the .enc file in each repo (only that file; no push)
  --check               change nothing: report whether the blobs in both repos open with the key file
  --dry-run             a rehearsal: everything goes under --out-dir (or a new temp folder): the key file, both
                        blobs and a local.properties. No gh, no git, the real repos and key file untouched.
  --out-dir DIR         where --dry-run writes (implies --dry-run)
  --placeholder         write the committed PLACEHOLDER blobs (dummy values, the public throwaway key) under
                        --out-dir; implies --dry-run and reads no secrets
  -h, --help            this text

Rotate: make new keys (RunPod: a new Restricted key for pixl-cloud-studio; Cloudflare: a new R2 token for the
bucket), run this again, commit, push, let CI build; then revoke the old keys. Delete the key file first to also
change the decryption key (then both repos' secrets and blobs change together).`;

// ---- small helpers ----------------------------------------------------------------------------------------------
class BakeError extends Error {}
const say = (line) => process.stdout.write(line + '\n');
const warn = (line) => process.stdout.write('warning: ' + line + '\n');

function parseArgs(argv) {
  const opts = { secrets: true, localProperties: true, commit: false, check: false, dryRun: false, placeholder: false };
  const valued = {
    '--ios-repo': 'iosRepo', '--android-repo': 'androidRepo', '--endpoint-id': 'endpointId',
    '--r2-endpoint': 'r2Endpoint', '--bucket': 'bucket', '--key-file': 'keyFile', '--out-dir': 'outDir',
  };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const eq = arg.indexOf('=');
    const name = arg.startsWith('--') && eq > 0 ? arg.slice(0, eq) : arg;
    if (valued[name]) {
      const value = eq > 0 && name !== arg ? arg.slice(eq + 1) : argv[++i];
      if (value === undefined || value === '') throw new BakeError(`${name} needs a value`);
      opts[valued[name]] = value;
      continue;
    }
    switch (arg) {
      case '-h': case '--help': opts.help = true; break;
      case '--no-secrets': opts.secrets = false; break;
      case '--no-local-properties': opts.localProperties = false; break;
      case '--commit': opts.commit = true; break;
      case '--check': opts.check = true; break;
      case '--dry-run': opts.dryRun = true; break;
      case '--placeholder': opts.placeholder = true; opts.dryRun = true; break;
      default: throw new BakeError(`unknown flag ${arg} (see --help)`);
    }
  }
  if (opts.outDir) opts.dryRun = true;
  if (opts.dryRun && (opts.commit || opts.check)) throw new BakeError('--dry-run/--out-dir/--placeholder go without --commit and --check');
  return opts;
}

function defaultKeyFile() {
  const home = process.env.USERPROFILE || os.homedir();
  return path.join(home, '.pixlaudio', 'cloud_defaults_key');
}

function decodeKey(text, where) {
  const trimmed = String(text).trim();
  const key = Buffer.from(trimmed, 'base64');
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(trimmed) || key.length !== 32 || key.toString('base64') !== trimmed) {
    throw new BakeError(`${where} is not a base64 32-byte key; fix or delete it (deleting means a new key everywhere)`);
  }
  return key;
}

/** The key file's key, created when missing. Returns { key, created }. */
function loadOrCreateKey(file) {
  if (fs.existsSync(file)) return { key: decodeKey(fs.readFileSync(file, 'utf8'), file), created: false };
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const key = crypto.randomBytes(32);
  fs.writeFileSync(file, key.toString('base64') + '\n', { mode: 0o600, flag: 'wx' });
  return { key, created: true };
}

export function seal(key, payload) {
  const nonce = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, nonce);
  const plaintext = Buffer.from(JSON.stringify(payload), 'utf8');
  const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  return Buffer.concat([MAGIC, nonce, ciphertext, cipher.getAuthTag()]);
}

/** The payload inside `blob`, or null when it doesn't open with `key` (wrong key, tampered, not a blob). */
export function open(key, blob) {
  if (!Buffer.isBuffer(blob) || blob.length <= MAGIC.length + 12 + 16 || !blob.subarray(0, MAGIC.length).equals(MAGIC)) {
    return null;
  }
  try {
    const nonce = blob.subarray(MAGIC.length, MAGIC.length + 12);
    const tag = blob.subarray(blob.length - 16);
    const decipher = crypto.createDecipheriv('aes-256-gcm', key, nonce);
    decipher.setAuthTag(tag);
    const plain = Buffer.concat([decipher.update(blob.subarray(MAGIC.length + 12, blob.length - 16)), decipher.final()]);
    return JSON.parse(plain.toString('utf8'));
  } catch {
    return null;
  }
}

const FIELDS = ['runpodEndpointId', 'runpodKey', 'r2Endpoint', 'bucket', 'r2AccessKeyId', 'r2SecretAccessKey'];

function payloadProblems(p) {
  const problems = [];
  if (!p || p.v !== 1) return ['not a v1 payload'];
  for (const field of FIELDS) {
    if (typeof p[field] !== 'string' || p[field].trim() === '') problems.push(`${field} is empty`);
  }
  if (problems.length) return problems;
  if (!/^[A-Za-z0-9_-]{1,64}$/.test(p.runpodEndpointId)) problems.push('the endpoint id has characters RunPod ids never have');
  if (!/^https:\/\/[a-z0-9.-]+(:\d+)?$/i.test(p.r2Endpoint)) problems.push('the R2 endpoint is not https://<host>');
  if (!/^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/.test(p.bucket)) problems.push('the bucket name is not a valid bucket name');
  return problems;
}

/** Hidden input from the terminal (paste + Enter). Shows only how many characters arrived. */
function promptHidden(question) {
  const stdin = process.stdin;
  if (!stdin.isTTY || typeof stdin.setRawMode !== 'function') {
    throw new BakeError('no terminal for hidden input here (Git Bash/mintty?): run this in PowerShell or Windows ' +
      'Terminal, or set PIXL_RUNPOD_KEY, PIXL_R2_KEY_ID and PIXL_R2_SECRET first');
  }
  return new Promise((resolve, reject) => {
    let value = '';
    process.stdout.write(question);
    stdin.setRawMode(true);
    stdin.setEncoding('utf8');
    stdin.resume();
    const finish = (error) => {
      stdin.off('data', onData);
      stdin.setRawMode(false);
      stdin.pause();
      process.stdout.write('\n');
      if (error) reject(error); else resolve(value);
    };
    const onData = (chunk) => {
      for (const ch of chunk) {
        if (ch === '\r' || ch === '\n') { finish(); return; }
        if (ch === '\u0003' || ch === '\u001b') { finish(new BakeError('cancelled; nothing was changed')); return; }
        if (ch === '\u007f' || ch === '\b') { value = value.slice(0, -1); continue; }
        if (ch >= ' ') value += ch;
      }
    };
    stdin.on('data', onData);
  });
}

async function readSecret(envName, label, check) {
  let value = process.env[envName];
  let from = `$${envName}`;
  if (value === undefined || value.trim() === '') {
    value = await promptHidden(`${label} (hidden; paste, then Enter): `);
    from = 'prompt';
  }
  value = value.trim();
  if (value === '') throw new BakeError(`${label} is empty; nothing was changed`);
  if (/\s/.test(value)) throw new BakeError(`${label} contains spaces or line breaks; paste it again`);
  say(`  ${label}: ${value.length} characters (${from})`);
  const hint = check(value);
  if (hint) warn(`${label}: ${hint}`);
  return value;
}

function git(repo, args, { allowFail = false } = {}) {
  const result = spawnSync('git', ['-C', repo, ...args], { stdio: ['ignore', 'pipe', 'pipe'], encoding: 'utf8' });
  if (result.error) throw new BakeError(`git is not available (${result.error.code})`);
  if (result.status !== 0 && !allowFail) {
    throw new BakeError(`git ${args[0]} failed in ${repo}: ${String(result.stderr).trim().split('\n')[0]}`);
  }
  return result;
}

function checkRepo(repo, label) {
  if (!fs.existsSync(repo)) throw new BakeError(`${label} checkout not found: ${repo} (use --${label.toLowerCase()}-repo)`);
  const top = git(repo, ['rev-parse', '--show-toplevel'], { allowFail: true });
  if (top.status !== 0) throw new BakeError(`${repo} is not a git checkout`);
  const branch = git(repo, ['branch', '--show-current'], { allowFail: true }).stdout.trim() || '(detached)';
  const counts = git(repo, ['rev-list', '--left-right', '--count', 'HEAD...@{u}'], { allowFail: true });
  if (counts.status === 0) {
    const [ahead, behind] = counts.stdout.trim().split(/\s+/).map(Number);
    if (behind > 0) warn(`${label} checkout (${branch}) is ${behind} commit(s) behind its upstream: pull before you commit`);
    if (ahead > 0) say(`  ${label} checkout (${branch}) has ${ahead} unpushed commit(s)`);
  }
  return branch;
}

function writeBlob(repo, rel, key, payload) {
  const file = path.join(repo, rel);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const blob = seal(key, payload);
  const back = open(key, blob);
  if (!back || FIELDS.some((f) => back[f] !== payload[f])) throw new BakeError('self-check failed: the blob did not open again');
  const before = fs.existsSync(file) ? fs.readFileSync(file) : null;
  fs.writeFileSync(file, blob);
  if (!open(key, fs.readFileSync(file))) throw new BakeError(`self-check failed after writing ${file}`);
  say(`  ${before ? 'replaced' : 'wrote'} ${file} (${blob.length} bytes; opens with the key)`);
  return file;
}

function setGitHubSecret(repoName, keyB64) {
  // --body, never stdin: piping into gh hangs on this PC. The value is scrubbed from anything gh prints.
  const result = spawnSync('gh', ['secret', 'set', SECRET_NAME, '--repo', repoName, '--body', keyB64],
    { stdio: ['ignore', 'pipe', 'pipe'], encoding: 'utf8' });
  if (result.error) throw new BakeError(`gh is not available (${result.error.code}); install GitHub CLI and run gh auth login`);
  if (result.status !== 0) {
    const why = String(result.stderr || result.stdout).split(keyB64).join('<redacted>').trim().split('\n')[0];
    throw new BakeError(`gh secret set ${SECRET_NAME} --repo ${repoName} failed: ${why}`);
  }
  say(`  set GitHub secret ${SECRET_NAME} on ${repoName}`);
}

function updateLocalProperties(androidRepo, keyB64, { requireIgnored }) {
  const file = path.join(androidRepo, 'local.properties');
  if (requireIgnored) {
    const ignored = git(androidRepo, ['check-ignore', '-q', 'local.properties'], { allowFail: true });
    if (ignored.status !== 0) {
      warn(`${file} is not ignored by git there: left alone (add it to .gitignore first)`);
      return;
    }
  }
  const text = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '';
  const lines = text.split(/\r?\n/);
  const index = lines.findIndex((l) => /^\s*CLOUD_DEFAULTS_KEY\s*[=:]/.test(l));
  const wanted = `${SECRET_NAME}=${keyB64}`;
  if (index >= 0 && lines[index].trim() === wanted) {
    say(`  ${file}: ${SECRET_NAME} already there (unchanged)`);
    return;
  }
  const eol = text.includes('\r\n') ? '\r\n' : '\n';
  let next;
  if (index >= 0) {
    lines[index] = wanted;
    next = lines.join(eol);
  } else {
    next = text + (text === '' || text.endsWith('\n') ? '' : eol) + wanted + eol;
  }
  fs.writeFileSync(file, next);
  say(`  ${file}: ${SECRET_NAME} ${index >= 0 ? 'updated' : 'added'}`);
}

function commitBlob(repo, rel, message) {
  git(repo, ['-c', 'core.autocrlf=false', 'add', '--', rel]);
  const staged = git(repo, ['diff', '--cached', '--quiet', '--', rel], { allowFail: true });
  if (staged.status === 0) {
    say(`  ${repo}: ${rel} unchanged in git, nothing to commit`);
    return;
  }
  git(repo, ['-c', 'core.autocrlf=false', 'commit', '-q', '-m', message, '--', rel]);
  const committed = spawnSync('git', ['-C', repo, 'show', `HEAD:${rel}`], { stdio: ['ignore', 'pipe', 'pipe'] });
  if (committed.status !== 0 || !Buffer.from(committed.stdout).equals(fs.readFileSync(path.join(repo, rel)))) {
    throw new BakeError(`${repo}: the committed ${rel} differs from the file on disk (line-ending conversion?)`);
  }
  const sha = git(repo, ['rev-parse', '--short', 'HEAD']).stdout.trim();
  say(`  committed ${rel} in ${repo} (${sha}); not pushed`);
}

function check(opts) {
  const keyFile = opts.keyFile || defaultKeyFile();
  if (!fs.existsSync(keyFile)) throw new BakeError(`no key file at ${keyFile}`);
  const key = decodeKey(fs.readFileSync(keyFile, 'utf8'), keyFile);
  let bad = 0;
  for (const [repo, rel] of [[opts.iosRepo, IOS_BLOB], [opts.androidRepo, ANDROID_BLOB]]) {
    const file = path.join(repo, rel);
    if (!fs.existsSync(file)) { say(`  ${file}: missing`); bad++; continue; }
    const blob = fs.readFileSync(file);
    const payload = open(key, blob);
    if (payload) {
      const problems = payloadProblems(payload);
      say(`  ${file}: opens with the key file; ${problems.length ? 'but ' + problems.join(', ') : 'v1, every field filled in'}`);
      if (problems.length) bad++;
    } else if (open(Buffer.from(PLACEHOLDER_KEY, 'base64'), blob)) {
      say(`  ${file}: still the placeholder (dummy values); bake the real keys`);
      bad++;
    } else {
      say(`  ${file}: does NOT open with the key file (another key, or damaged)`);
      bad++;
    }
  }
  return bad === 0 ? 0 : 1;
}

async function main(argv) {
  const opts = { ...DEFAULTS, ...parseArgs(argv) };
  if (opts.help) { say(HELP); return 0; }
  if (opts.check) return check(opts);

  const dry = opts.dryRun;
  if (dry) {
    opts.outDir = path.resolve(opts.outDir || fs.mkdtempSync(path.join(os.tmpdir(), 'pixl-bake-')));
    fs.mkdirSync(opts.outDir, { recursive: true });
    opts.iosRepo = path.join(opts.outDir, 'PixlAudio-iOS');
    opts.androidRepo = path.join(opts.outDir, 'PixlAudio-android');
    opts.keyFile = opts.keyFile || path.join(opts.outDir, 'cloud_defaults_key');
    say(`${opts.placeholder ? 'Placeholder' : 'Dry run'}: writing under ${opts.outDir} only (no gh, no git, real repos untouched).`);
  } else {
    opts.keyFile = opts.keyFile || defaultKeyFile();
    say('Checking the checkouts...');
    checkRepo(opts.iosRepo, 'iOS');
    if (!fs.existsSync(path.join(opts.iosRepo, IOS_KEY_STUB))) {
      warn(`${opts.iosRepo} has no ${IOS_KEY_STUB}: this checkout doesn't have the built-in keys feature yet (merge it first)`);
    }
    checkRepo(opts.androidRepo, 'Android');
  }

  let payload;
  let key;
  if (opts.placeholder) {
    payload = { v: 1, ...PLACEHOLDER_VALUES };
    key = Buffer.from(PLACEHOLDER_KEY, 'base64');
    say('  placeholder values and the public throwaway key');
  } else {
    say('The three secrets (from the environment or a hidden prompt):');
    const runpodKey = await readSecret('PIXL_RUNPOD_KEY', 'RunPod Restricted key',
      (v) => (v.startsWith('rpa_') ? '' : "doesn't start with rpa_ (RunPod keys usually do)"));
    const r2AccessKeyId = await readSecret('PIXL_R2_KEY_ID', 'R2 access key ID',
      (v) => (/^[0-9a-f]{32}$/.test(v) ? '' : 'R2 access key IDs are usually 32 hex characters'));
    const r2SecretAccessKey = await readSecret('PIXL_R2_SECRET', 'R2 secret access key',
      (v) => (/^[0-9a-f]{64}$/.test(v) ? '' : 'R2 secret access keys are usually 64 hex characters'));
    // A wrong shape is what R2 answers with HTTP 400 later, so refuse it here, before anything is written.
    if (!/^[0-9a-f]{32}$/.test(r2AccessKeyId) || !/^[0-9a-f]{64}$/.test(r2SecretAccessKey)) {
      throw new BakeError(`the R2 access key ID must be 32 hex characters (it is ${r2AccessKeyId.length}) and the secret ` +
        `64 (it is ${r2SecretAccessKey.length}); they may be swapped or cut short. Nothing was changed; run it again`);
    }
    if (r2AccessKeyId === r2SecretAccessKey || runpodKey === r2SecretAccessKey || runpodKey === r2AccessKeyId) {
      throw new BakeError('two of the three secrets are the same; paste each one from its own field');
    }
    payload = { v: 1, runpodEndpointId: opts.endpointId, runpodKey, r2Endpoint: opts.r2Endpoint, bucket: opts.bucket,
      r2AccessKeyId, r2SecretAccessKey };
    const loaded = loadOrCreateKey(opts.keyFile);
    key = loaded.key;
    say(`  decryption key: ${loaded.created ? 'created' : 'reused'} ${opts.keyFile}`);
  }
  const problems = payloadProblems(payload);
  if (problems.length) throw new BakeError(`not baking: ${problems.join(', ')}`);
  const keyB64 = key.toString('base64');

  say('Blobs:');
  writeBlob(opts.iosRepo, IOS_BLOB, key, payload);
  writeBlob(opts.androidRepo, ANDROID_BLOB, key, payload);

  if (opts.placeholder) {
    say(`Done. Copy ${path.join(opts.iosRepo, IOS_BLOB)} over the repo's ${IOS_BLOB} to restore the placeholder.`);
    return 0;
  }

  say('GitHub secrets:');
  if (dry) {
    for (const repo of [DEFAULTS.iosGitHub, DEFAULTS.androidGitHub]) say(`  would set ${SECRET_NAME} on ${repo} (dry run)`);
  } else if (opts.secrets) {
    setGitHubSecret(DEFAULTS.iosGitHub, keyB64);
    setGitHubSecret(DEFAULTS.androidGitHub, keyB64);
  } else {
    say('  skipped (--no-secrets)');
  }

  say('Android local.properties:');
  if (opts.localProperties) updateLocalProperties(opts.androidRepo, keyB64, { requireIgnored: !dry });
  else say('  skipped (--no-local-properties)');

  if (dry) {
    say(`Dry run done: ${opts.outDir}`);
    return 0;
  }
  const message = 'Cloud processing: bake the built-in cloud keys (encrypted blob)\n\n' +
    'Written by tools/cloud/bake-cloud-keys.mjs. AES-256-GCM; the key is the CLOUD_DEFAULTS_KEY Actions secret.';
  if (opts.commit) {
    say('Commits (no push):');
    commitBlob(opts.iosRepo, IOS_BLOB, message);
    commitBlob(opts.androidRepo, ANDROID_BLOB, message);
    say('Done. Push both repos when ready; CI then builds the apps with the key.');
  } else {
    say('Done. Now commit the two blobs (and push when ready):');
    say(`  git -C "${opts.iosRepo}" add ${IOS_BLOB} && git -C "${opts.iosRepo}" commit -m "Bake the built-in cloud keys" -- ${IOS_BLOB}`);
    say(`  git -C "${opts.androidRepo}" add ${ANDROID_BLOB} && git -C "${opts.androidRepo}" commit -m "Bake the built-in cloud keys" -- ${ANDROID_BLOB}`);
    say('  (or run this again with --commit)');
  }
  return 0;
}

const invokedDirectly = Boolean(process.argv[1]) && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedDirectly) {
  main(process.argv.slice(2)).then((code) => process.exit(code), (error) => {
    if (error instanceof BakeError) {
      process.stderr.write(`error: ${error.message}\n`);
      process.exit(1);
    }
    // Never a value: the fs / child_process messages that can land here carry paths and codes only.
    process.stderr.write(`error: unexpected ${error && error.name ? error.name : 'failure'}: ${error && error.message}\n`);
    process.exit(2);
  });
}
