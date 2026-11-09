#!/usr/bin/env python3
"""Validate and freeze the reviewed J714s developer image inputs."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[4]
INTEGRATION = Path(__file__).resolve().parents[1]
MANIFEST = INTEGRATION / 'candidate-package-manifest.json'
PROVENANCE = INTEGRATION / 'build-input-provenance.json'
PROFILE = 'j714s-developer'


def sha256(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def load_candidate_set():
    path = ROOT / 'image-builder/builder/candidate_set.py'
    spec = importlib.util.spec_from_file_location('j714s_candidate_set', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(*args: str, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def verify_main_commit(commit: str) -> None:
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('builder commit must be a full lowercase Git SHA')
    remote = run('git', 'ls-remote', 'origin', 'refs/heads/main', cwd=ROOT,
                 stdout=subprocess.PIPE, text=True).stdout.split()[0]
    if remote != commit:
        raise ValueError(f'builder commit is not current origin/main ({remote})')
    run('git', 'cat-file', '-e', f'{commit}^{{commit}}', cwd=ROOT)


def verify_source_records(candidate, package_dir: Path, manifest: dict,
                          runtime: Path, settings: Path, runtime_source: dict) -> list[dict]:
    if (manifest.get('schema') != 1 or manifest.get('candidate_only') is not True
            or candidate.set_digest(manifest) != manifest.get('set_sha256')):
        raise ValueError('checked-in package manifest has an invalid schema or set digest')
    expected = {row['filename']: row for row in manifest['packages']}
    if manifest.get('source', {}).get('repository') != runtime_source['repository'] or manifest.get('source', {}).get('commit') != runtime_source['commit']:
        raise ValueError('runtime source identity differs from the checked-in package manifest')
    if package_dir.is_symlink() or not package_dir.is_dir():
        raise ValueError('package input must be a regular directory')
    supplied = {p.name: p for p in package_dir.iterdir() if p.is_file()
                and p.name.endswith('.pkg.tar.zst')}
    runtime_inputs = {'omarchy': runtime, 'omarchy-settings': settings}
    expected_runtime_names = {row['filename'] for row in expected.values()
                              if row['name'] in runtime_inputs}
    if set(supplied) != set(expected) - expected_runtime_names:
        raise ValueError('package directory must contain the 13 non-runtime archives pinned by the manifest')
    records = []
    for filename, row in sorted(expected.items()):
        archive = runtime_inputs[row['name']] if row['name'] in runtime_inputs else supplied[filename]
        if archive.is_symlink() or not archive.is_file():
            raise ValueError(f'package archive is not a regular file: {filename}')
        fields = candidate.pkginfo(archive)
        if fields.get('pkgname') != [row['name']] or fields.get('pkgver') != [row['version']] or fields.get('arch') != ['aarch64']:
            raise ValueError(f'package metadata mismatch: {filename}')
        if archive.stat().st_size != row['size_bytes'] or sha256(archive) != row['sha256']:
            raise ValueError(f'package size or SHA-256 mismatch: {filename}')
        if runtime_inputs.get(row['name']) == archive:
            source = {'repository': runtime_source['repository'], 'commit': runtime_source['commit']}
            if row['source'] != source:
                raise ValueError(f'{row["name"]} source identity differs from the public manifest')
        records.append({k: row[k] for k in ('name', 'version', 'arch', 'filename', 'sha256', 'source')})
    return records


def validate_signer(home: Path, policy: dict) -> None:
    if home.is_symlink() or not home.is_dir():
        raise ValueError('signing home must be an existing directory')
    result = run('gpg', '--batch', '--homedir', str(home), '--with-colons', '--list-secret-keys',
                 stdout=subprocess.PIPE, text=True).stdout
    fingerprints = [line.split(':')[9].upper() for line in result.splitlines()
                    if line.startswith('fpr:') and len(line.split(':')) > 9]
    if not fingerprints or fingerprints[0] != policy['signing_fingerprint'].upper():
        raise ValueError('supplied signing home does not contain the profile-approved signer')


def validate_engine(engine_archive: Path) -> dict:
    lock = json.loads((ROOT / 'Engine/source-lock.json').read_text())
    identity = lock['validation_artifact']
    if engine_archive.is_symlink() or not engine_archive.is_file():
        raise ValueError('engine archive must be a regular file')
    if engine_archive.name != identity['filename'] or engine_archive.stat().st_size != identity['size_bytes'] or sha256(engine_archive) != identity['sha256']:
        raise ValueError('engine archive does not match the current Engine/source-lock.json')
    # The checked-in engine verifier confirms the archive contents against the lock too.
    with tempfile.TemporaryDirectory(prefix='j714s-engine-') as temporary:
        destination = Path(temporary)
        shutil.copyfile(engine_archive, destination / engine_archive.name)
        run(sys.executable, str(ROOT / 'Engine/prepare-engine.py'), '--output', str(destination),
            '--cache', str(destination / 'cache'))
    return identity


def validate_recovery(directory: Path, expected_sha: str) -> str:
    verifier = ROOT / 'image-builder/builder/recovery_app.py'
    run(sys.executable, str(verifier), str(directory), '--sha256', expected_sha)
    actual = sha256(directory / 'omarchy-recovery-app.json')
    if actual != expected_sha:
        raise ValueError('Recovery inventory digest differs from provenance')
    return actual


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', choices=(PROFILE,), default=PROFILE)
    parser.add_argument('--packages', type=Path, required=True, help='directory with the 13 non-runtime manifest-pinned archives')
    parser.add_argument('--runtime', type=Path, required=True, help='source-built omarchy package')
    parser.add_argument('--settings', type=Path, required=True, help='source-built omarchy-settings package')
    parser.add_argument('--recovery', type=Path, required=True, help='validated Recovery app directory')
    parser.add_argument('--recovery-artifact', type=Path, required=True, help='downloaded CI artifact archive for the Recovery app')
    parser.add_argument('--engine', type=Path, required=True, help='prebuilt engine archive matching Engine/source-lock.json')
    parser.add_argument('--signing-home', type=Path, required=True, help='existing profile-approved signing home')
    parser.add_argument('--candidate-set-tool', type=Path, required=True, help='pinned omacom candidate-set script')
    parser.add_argument('--builder-commit', required=True, help='published current origin/main commit')
    parser.add_argument('--output', type=Path, required=True, help='new output directory')
    parser.add_argument('--archive', type=Path, required=True, help='new deterministic .tar.zst destination')
    args = parser.parse_args()

    try:
        verify_main_commit(args.builder_commit)
        candidate = load_candidate_set()
        profile = __import__('image_profile').select(args.profile)
        trust = profile['trust']
        policy = candidate.load_policy(profile=args.profile)
        metadata = json.loads(MANIFEST.read_text())
        runtime_source = {key: metadata['source'][key] for key in ('repository', 'commit')}
        provenance = json.loads(PROVENANCE.read_text())
        tool_pin = provenance['candidate_set_signer_tool']
        if (tool_pin.get('repository') != 'omacom/omarchy-mac-pkgs'
                or tool_pin.get('path') != 'tools/release/candidate-set'):
            raise ValueError('candidate-set signer tool pin has an unexpected origin')
        records = verify_source_records(candidate, args.packages, metadata, args.runtime, args.settings,
                                        runtime_source)
        for name, path in (('omarchy', args.runtime), ('omarchy-settings', args.settings)):
            if path.is_symlink() or not path.is_file():
                raise ValueError(f'{name} archive must be a regular file')
            if candidate.member(path, candidate.REVISION_FILES[name]).decode().strip() != runtime_source['commit']:
                raise ValueError(f'{name} does not record the pinned runtime source')
        if len(records) != 15 or len({row['name'] for row in records}) != 15:
            raise ValueError('candidate set must contain the checked-in 15-package manifest')
        if candidate.digest(trust / 'public.asc') != policy['public_key_sha256']:
            raise ValueError('profile public-key fingerprint differs from the policy')
        validate_signer(args.signing_home, policy)
        tool = args.candidate_set_tool
        if tool.is_symlink() or sha256(tool) != tool_pin['sha256']:
            raise ValueError(f'candidate-set tool differs from pinned upstream {tool_pin["commit"]}')
        identity = validate_engine(args.engine)
        recovery = provenance['recovery']
        if args.recovery_artifact.is_symlink() or not args.recovery_artifact.is_file() or sha256(args.recovery_artifact) != recovery['artifact_sha256']:
            raise ValueError('Recovery CI artifact does not match public provenance')
        validate_recovery(args.recovery, recovery['inventory_sha256'])
        source_tree = run('git', 'rev-parse', f"{recovery['source_commit']}:Recovery", cwd=ROOT,
                          stdout=subprocess.PIPE, text=True).stdout.strip()
        if source_tree != recovery['source_tree']:
            raise ValueError('Recovery source commit/tree differs from published metadata')

        if args.output.exists() or args.output.is_symlink():
            raise ValueError('output directory already exists')
        args.output.mkdir(parents=True)
        candidate_dir = args.output / 'candidate-set'
        candidate_dir.mkdir()
        for row in records:
            src = args.runtime if row['name'] == 'omarchy' else args.settings if row['name'] == 'omarchy-settings' else args.packages / row['filename']
            shutil.copy2(src, candidate_dir / row['filename'])
        manifest = {'schema': 1, 'candidate_only': True,
                    'set': 'j714s-dev-runtime-' + candidate.set_digest({'packages': records})[:12],
                    'source': {**runtime_source, 'ref': metadata['source']['ref']},
                    'platform_sources': metadata['platform_sources'],
                    'packages': sorted(records, key=lambda row: row['name']),
                    'limitations': metadata['limitations']}
        manifest['set_sha256'] = candidate.set_digest(manifest)
        manifest_path = candidate_dir / 'manifest.json'
        manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
        environment = {**os.environ, 'CANDIDATE_SIGNING_GNUPGHOME': str(args.signing_home)}
        run('bash', str(tool), 'sign', str(manifest_path), str(candidate_dir), env=environment)
        summary = candidate.describe(candidate_dir, profile=args.profile)
        if len(summary['packages']) != 15 or summary['signer'] != policy['primary_fingerprint'].upper():
            raise ValueError('signed set did not pass developer profile admission')

        validate_recovery(args.recovery, recovery['inventory_sha256'])
        shutil.copytree(args.recovery, args.output / 'recovery')
        engine_dir = args.output / 'engine'
        engine_dir.mkdir()
        shutil.copy2(args.engine, engine_dir / identity['filename'])
        baseline = provenance['official_baseline']
        source_provenance = {
            'schema': 1, 'developer_only': True, 'builder_commit': args.builder_commit,
            'set_sha256': manifest['set_sha256'], 'manifest_sha256': candidate.digest(manifest_path),
            'receipt_sha256': candidate.digest(candidate_dir / 'signing.json'),
            'development_signer': summary['signer'], 'runtime_source': manifest['source'],
            'platform_sources': manifest['platform_sources'], 'recovery': recovery,
            'native_mesa': provenance['native_mesa'], 'official_baseline': baseline,
            'engine': identity, 'limitations': manifest['limitations']}
        (args.output / 'source-provenance.json').write_text(json.dumps(source_provenance, indent=2) + '\n')
        (args.output / 'candidate-set/ACTUAL-SIGNED-SET.json').write_text(json.dumps(summary, indent=2) + '\n')
        if args.archive.exists() or args.archive.is_symlink():
            raise ValueError('archive destination already exists')
        with tempfile.TemporaryDirectory(prefix='j714s-input-tar-') as temporary:
            tar_path = Path(temporary) / 'inputs.tar'
            run('tar', '--sort=name', '--mtime=@0', '--owner=0', '--group=0', '--numeric-owner',
                '-cf', str(tar_path), '-C', str(args.output), 'candidate-set', 'recovery', 'engine',
                'source-provenance.json')
            args.archive.parent.mkdir(parents=True, exist_ok=True)
            run('zstd', '-T0', '-10', '--no-progress', str(tar_path), '-o', str(args.archive))
        print(f'archive_sha256={sha256(args.archive)}')
        print(f'PASS: validated {len(summary["packages"])} signed packages, Recovery, and locked engine inputs')
    except (ValueError, OSError, KeyError, TypeError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print(f'finish-inputs: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
