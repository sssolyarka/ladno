#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
version="$(sed -n 's/^version: \([^+]*\).*/\1/p' pubspec.yaml)"
mkdir -p dist build/rpm/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
rpmbuild -bb packaging/linux/ladno.spec \
  --define "_topdir $PWD/build/rpm" \
  --define "app_version $version" \
  --define "project_dir $PWD" \
  --define "bundle_dir $PWD/build/linux/x64/release/bundle"
cp build/rpm/RPMS/x86_64/ladno-*.rpm "dist/ladno-$version-fedora-x86_64.rpm"
tar -C build/linux/x64/release -czf "dist/ladno-$version-linux-x64.tar.gz" bundle
rpm -qpl "dist/ladno-$version-fedora-x86_64.rpm" | sed -n '1,20p'
