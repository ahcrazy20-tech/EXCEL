#!/bin/bash
# Execute the real Foundation/SQLite core tests on the macOS build host.
# This needs no simulator, signing identity, third-party package, or network.
# It is also usable directly: bash ci/test-core.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sheetx-core-tests.XXXXXX")"
trap 'rm -rf "$PACKAGE_DIR"' EXIT
mkdir -p "$PACKAGE_DIR/Sources" "$PACKAGE_DIR/Tests"
for file in Database Workspace AnalysisQueryPolicy QueryEngine NLQueryParser SavedAnalysis \
    ReportBuilder AnalysisRunner DataOverview ResultPresentation \
    PreparationModels PreparationEngine CleanValueRules; do
    cp "$ROOT/Sources/Core/$file.swift" "$PACKAGE_DIR/Sources/"
done
cp "$ROOT/Sources/App/PreparationLocalization.swift" "$PACKAGE_DIR/Sources/"
# Only presentation localization is adapted; database and preparation code are unchanged.
cat > "$PACKAGE_DIR/Sources/HostLocalization.swift" <<'SWIFT'
import Foundation
extension String {
    var loc: String { PreparationLocalization.table[self]?.0 ?? self }
}
SWIFT
for file in AnalysisFixture AnalysisSafetyTests WorkspaceAnalysisTests DataOverviewTests \
    ResultPresentationTests SheetDeletionTests PreparationTests; do
    cp "$ROOT/Tests/$file.swift" "$PACKAGE_DIR/Tests/"
done
cat > "$PACKAGE_DIR/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "SheetXCoreTests",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "SheetX", path: "Sources", linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "SheetXTests", dependencies: ["SheetX"], path: "Tests")
    ]
)
SWIFT
unset SDKROOT IPHONEOS_DEPLOYMENT_TARGET SWIFT_EXEC
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export MACOSX_DEPLOYMENT_TARGET=13.0
xcrun --sdk macosx swift test --package-path "$PACKAGE_DIR" --disable-sandbox
