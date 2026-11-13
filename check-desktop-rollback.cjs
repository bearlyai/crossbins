// What desktop readers do when the feed moves between the 2026-09-21 baseline and a staged release.
// Runs the real manifest, version and install-check functions from each desktop revision against
// a temporary user data folder, for Mac, Windows and Linux on x64 and arm64.
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const vm = require('node:vm')
const { execFileSync } = require('node:child_process')
const [stagedFile, desktopRepo, dependencyDirectory] = process.argv.slice(2)
if (!dependencyDirectory) throw new Error('Usage: node check-desktop-rollback.cjs manifest.json desktop-repo electron-dependency-directory')
const { transformSync } = require(require.resolve('esbuild', { paths: [dependencyDirectory] }))
const staged = JSON.parse(fs.readFileSync(stagedFile, 'utf8'))
const baseline = JSON.parse(fs.readFileSync(path.join(__dirname, 'baseline', '2026-09-21.manifest.json'), 'utf8'))
const OLD = [
    ['5.2.3', 'ab0e78c59fc0a066e357a1cbda1efda810c2e165'],
    ['5.2.3', '99b019cd435b2b91e5b147f10fe3c3eb7adda9c8'],
    ['5.2.4', '785282e25958df039b237c63b7b240a75f99b7c0'],
    ['5.2.5', '1b62fa40ba874f9d2bd27aec7743791286c3544f'],
    ['5.2.6', '94abd5948fc6b59258450a8aba856bf7fca0f60d'],
    ['5.2.7', '110fcaed189315584193f8c8a3925ae76404023e'],
    ['5.2.8', '41bf0dabe34e30aae69192aa8400e03768f1401e'],
    ['5.2.9', '5985a8199383df2614bd9aafd60db164f395121b'],
    ['5.2.10', '6ef1e6a5d6a7776d02fe6327dda8191a10837ad9'],
    ['5.2.11', '0ca291a0b1ab0ac188df04afc5d55d9a31d7c229'],
]
const FUNCTIONS = ['isValidManifest', 'findAsset', 'getToolVersion', 'toolSupportedOnCurrentPlatform', 'assetForCurrentPlatform', 'findToolAsset',
    'bundleConfigForCurrentPlatform', 'getManifestCachePath', 'getManifest', 'loadCachedManifestFromDisk', 'getBinDir', 'getVersionsPath', 'readVersions',
    'getBinaryFilename', 'getInstallPath', 'getBinaryPath', 'needsUpgrade', 'resolve']

function git(...args) {
    return execFileSync('git', ['-C', desktopRepo, ...args], { encoding: 'utf8' })
}

function reader(sha, platform, arch, userData) {
    const source = git('show', `${sha}:projects/electron/src/modules/binaries.ts`)
    const parts = [source.match(/^const TOOL_CONFIG:[\s\S]*?^}/m)[0]]
    for (const name of FUNCTIONS) {
        const found = source.match(new RegExp(`^(?:export )?function ${name}\\([\\s\\S]*?^}`, 'm'))
        if (found) parts.push(found[0])
        else if (!['findToolAsset', 'assetForCurrentPlatform', 'bundleConfigForCurrentPlatform'].includes(name)) throw new Error(`${sha} lacks ${name}`)
    }
    const code = transformSync(parts.join('\n'), { loader: 'ts', format: 'cjs' }).code
    const context = { exports: {}, module: { exports: {} }, fs, path, process: { platform, arch }, app: { getPath: () => userData }, logger: { debug() {}, info() {}, warn() {} } }
    vm.createContext(context)
    vm.runInContext(`let cachedManifest = null\n${code}\nthis.api = { TOOL_CONFIG, findAsset, getToolVersion, loadCachedManifestFromDisk, getManifestCachePath, getBinaryPath, writeVersions(v) { fs.mkdirSync(getBinDir(), { recursive: true }); fs.writeFileSync(getVersionsPath(), JSON.stringify(v)) }, needsUpgrade, resolve }`, context)
    return context.api
}

// A successful manifest refresh writes the disk cache and replaces the in-memory manifest; loading
// the disk cache sets the in-memory manifest the same way.
function feed(api, manifest) {
    fs.mkdirSync(path.dirname(api.getManifestCachePath()), { recursive: true })
    fs.writeFileSync(api.getManifestCachePath(), JSON.stringify(manifest))
}

function install(api, manifest) {
    const versions = {}
    for (const name of Object.keys(api.TOOL_CONFIG)) {
        if (!api.findAsset(manifest, name)) continue
        fs.mkdirSync(path.dirname(api.getBinaryPath(name)), { recursive: true })
        fs.writeFileSync(api.getBinaryPath(name), name)
        versions[name] = api.getToolVersion(manifest, name)
    }
    api.writeVersions(versions)
    return Object.keys(versions)
}

function entryOf(manifest, asset) {
    return manifest.tools.find((tool) => tool.assets.includes(asset)).name
}

const platforms = ['darwin', 'win32', 'linux'].flatMap((platform) => ['x64', 'arm64'].map((arch) => [platform, arch]))
const masterSha = git('rev-parse', 'origin/master').trim()
const masterVersion = JSON.parse(git('show', `${masterSha}:projects/electron/package.json`)).version
assert.match(git('show', `${masterSha}:projects/electron/src/modules/binaries.ts`), /preferredManifestEntry: "computer-use-driver"/)
const legacyDriver = baseline.tools.find((tool) => tool.name === 'cua-driver')

for (const [platform, arch] of platforms) {
    const userData = fs.mkdtempSync(path.join(os.tmpdir(), 'crossbins-rollback-'))
    try {
        const api = reader(masterSha, platform, arch, userData)
        // The staged release is latest and the desktop installs the new driver from it.
        feed(api, staged)
        api.loadCachedManifestFromDisk()
        const names = install(api, staged)
        assert.equal(entryOf(staged, api.findAsset(staged, 'cua-driver')), 'computer-use-driver')
        assert.equal(api.getToolVersion(staged, 'cua-driver'), '0.34.1-bearly.2')
        for (const name of names) assert.ok(api.resolve(name), `${name} installed`)
        // Latest moves back to 2026-09-21 while the app runs: nothing re-reads the manifest.
        feed(api, baseline)
        assert.ok(api.resolve('cua-driver'), 'a running app keeps the staged driver')
        assert.equal(api.needsUpgrade('cua-driver'), false)
        // Restart with a successful refresh: the baseline manifest is loaded.
        api.loadCachedManifestFromDisk()
        assert.equal(api.needsUpgrade('cua-driver'), true, 'staged driver is stale against the baseline')
        assert.equal(api.resolve('cua-driver'), null, 'the next computer-use start reinstalls the driver')
        const asset = api.findAsset(baseline, 'cua-driver')
        assert.equal(entryOf(baseline, asset), 'cua-driver')
        assert.equal(api.getToolVersion(baseline, 'cua-driver'), '0.28.2')
        assert.ok(legacyDriver.assets.includes(asset))
        for (const name of names.filter((name) => name !== 'cua-driver')) assert.equal(api.needsUpgrade(name), false, `${name} unchanged by rollback`)
        console.log(`PASS ${masterVersion} ${platform}/${arch}: keeps 0.34.1-bearly.2 until restart; after a refresh it reports the driver stale and selects cua-driver 0.28.2 (${asset.name}); ${names.length - 1} other tools stay current`)
    } finally {
        fs.rmSync(userData, { recursive: true, force: true })
    }
}

for (const [label, sha] of [...OLD, [masterVersion, masterSha]]) {
    if (label !== masterVersion) assert.equal(JSON.parse(git('show', `${sha}:projects/electron/package.json`)).version, label)
    for (const [platform, arch] of platforms) {
        const userData = fs.mkdtempSync(path.join(os.tmpdir(), 'crossbins-rollback-'))
        try {
            const api = reader(sha, platform, arch, userData)
            feed(api, baseline)
            api.loadCachedManifestFromDisk()
            const names = install(api, baseline)
            // The staged release becomes latest and is loaded.
            feed(api, staged)
            api.loadCachedManifestFromDisk()
            const stale = names.filter((name) => api.needsUpgrade(name) || !api.resolve(name))
            const unchanged = names.filter((name) => name !== 'cua-driver' || label !== masterVersion)
            for (const name of unchanged) {
                assert.ok(!stale.includes(name), `${label} ${name} must not be stale`)
                const before = api.findAsset(baseline, name)
                const after = api.findAsset(staged, name)
                assert.equal(after.sha256, before.sha256, `${label} ${name} bytes`)
                assert.equal(path.basename(after.url), path.basename(before.url), `${label} ${name} file name`)
            }
            if (label === masterVersion) assert.deepEqual(stale, ['cua-driver'])
            else assert.deepEqual(stale, [])
        } finally {
            fs.rmSync(userData, { recursive: true, force: true })
        }
    }
    const expectation = label === masterVersion ? 'only cua-driver moves to the new entry' : 'nothing stale, same bytes and file names'
    console.log(`PASS ${label} ${sha.slice(0, 10)}: baseline to staged on all 6 platform/architecture pairs, ${expectation}`)
}
