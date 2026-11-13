// Run the production manifest functions from two exact desktop revisions.
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const { execFileSync } = require('node:child_process')
const [manifestFile, desktopRepo, dependencyDirectory] = process.argv.slice(2)
if (!dependencyDirectory) throw new Error('Usage: node check-desktop-manifest.cjs manifest.json desktop-repo electron-dependency-directory')
const { transformSync } = require(require.resolve('esbuild', { paths: [dependencyDirectory] }))
const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'))
const revisions = [['5.2.3', '785282e259^'], ['current master', 'origin/master']]
for (const [label, ref] of revisions) {
    const sha = execFileSync('git', ['-C', desktopRepo, 'rev-parse', ref], { encoding: 'utf8' }).trim()
    const source = execFileSync('git', ['-C', desktopRepo, 'show', `${sha}:projects/electron/src/modules/binaries.ts`], { encoding: 'utf8' })
    if (label === '5.2.3') {
        const pkg = JSON.parse(execFileSync('git', ['-C', desktopRepo, 'show', `${sha}:projects/electron/package.json`], { encoding: 'utf8' }))
        assert.equal(pkg.version, '5.2.3')
    }
    // Top-level functions and this object each end at an unindented closing brace.
    const config = source.match(/^const TOOL_CONFIG:[\s\S]*?^}/m)
    assert.ok(config, 'Tool configuration must be read from the selected source')
    const names = ['isValidManifest', 'findAsset', 'getToolVersion', 'toolSupportedOnCurrentPlatform', 'assetForCurrentPlatform', 'findToolAsset']
    const functions = names.flatMap(name => source.match(new RegExp(`^(?:export )?function ${name}\\([\\s\\S]*?^}`, 'm'))?.[0] ?? [])
    assert.ok(functions.some(text => text.includes('function isValidManifest(')))
    assert.ok(functions.some(text => text.includes('function findAsset(')))
    const code = transformSync([config[0], ...functions].join('\n'), { loader: 'ts', format: 'cjs' }).code
    // download_base is only a type declaration; installation resolves the asset's own url.
    assert.equal((source.match(/\bdownload_base\b/g) ?? []).length, 1, 'Review any new runtime dependency on download_base')
    for (const platform of ['darwin', 'win32', 'linux']) for (const arch of ['x64', 'arm64']) {
        const context = { exports: {}, module: { exports: {} }, path, process: { platform, arch } }
        vm.runInNewContext(code + '\nmodule.exports = { isValidManifest, findAsset, getToolVersion };', context)
        const api = context.module.exports
        assert.equal(api.isValidManifest(manifest), true)
        const asset = api.findAsset(manifest, 'cua-driver')
        assert.ok(asset, `${label} must resolve ${platform}/${arch}`)
        const expectedTool = label === '5.2.3' ? 'cua-driver' : 'computer-use-driver'
        const expectedVersion = label === '5.2.3' ? '0.28.2' : '0.34.1-bearly.2'
        assert.equal(api.getToolVersion(manifest, 'cua-driver'), expectedVersion)
        assert.ok(asset.url.includes(`/${expectedTool}-`))
        assert.ok(asset.url.includes(`/releases/download/${manifest.release_tag}/`))
        // A valid old reader must resolve full asset URLs even with an unrelated base.
        const alternateBase = { ...manifest, download_base: 'https://invalid.example/unused' }
        assert.equal(api.findAsset(alternateBase, 'cua-driver').url, asset.url)
    }
    console.log(`PASS ${label} ${sha}: valid manifest, all 6 platform/architecture pairs, no dependency on latest download_base`)
}
