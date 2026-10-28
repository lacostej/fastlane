#!/bin/bash
# Probe for scan's simulator pre-boot (fastlane#30498): can simctl boot non-iOS simulators,
# and does xcodebuild shut down a simulator it booted itself, on every platform?
set -u
OUT="${RUNNER_TEMP:-/tmp}/sim-probe"
mkdir -p "$OUT"

xcodebuild -version
xcrun simctl runtime list
xcrun simctl list runtimes

# Newest runtime's first available device for a platform (iOS, tvOS, watchOS, xrOS)
first_device() {
  xcrun simctl list devices available -j | ruby -rjson -e '
    platform = ARGV[0]
    runtimes = JSON.parse($stdin.read)["devices"].select { |rt, l| rt.include?("SimRuntime.#{platform}-") && !l.empty? }
    rt, list = runtimes.max_by { |rt, _| rt.split("-").drop(1).map(&:to_i) }
    puts "#{list.first["udid"]} #{rt} #{list.first["name"]}" if list' "$1"
}

state() {
  xcrun simctl list devices -j | ruby -rjson -e '
    d = JSON.parse($stdin.read)["devices"].values.flatten.find { |x| x["udid"] == ARGV[0] }
    puts d ? d["state"] : "missing"' "$1"
}

echo "== bootstatus -b on an unknown device"
xcrun simctl bootstatus 00000000-0000-0000-0000-000000000000 -b
echo "exit=$?"

for platform in tvOS watchOS xrOS iOS; do
  read -r udid runtime name <<< "$(first_device $platform)"
  echo "== $platform: ${name:-none} ${runtime:-} ${udid:-}"
  [ -z "${udid:-}" ] && continue
  echo "state before: $(state $udid)"
  xcrun simctl bootstatus "$udid" -b > "$OUT/boot-$platform.log" 2>&1
  echo "bootstatus exit=$? state=$(state $udid)"
  tail -3 "$OUT/boot-$platform.log"
  xcrun simctl spawn "$udid" log collect --output "$OUT/$platform.logarchive" > "$OUT/collect-$platform.log" 2>&1
  echo "log collect (booted) exit=$?"
  tail -3 "$OUT/collect-$platform.log"
  xcrun simctl shutdown "$udid"
  echo "shutdown exit=$? state=$(state $udid)"
done

# Minimal Swift package with one XCTest, so the test run does not depend on an example project
PKG="$OUT/Probe"
mkdir -p "$PKG/Sources/Probe" "$PKG/Tests/ProbeTests"
cat > "$PKG/Package.swift" <<'SWIFT'
// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Probe", targets: [.target(name: "Probe"), .testTarget(name: "ProbeTests", dependencies: ["Probe"])])
SWIFT
echo 'public func probe() -> Int { 1 }' > "$PKG/Sources/Probe/Probe.swift"
printf 'import XCTest\nimport Probe\nfinal class ProbeTests: XCTestCase { func testProbe() { XCTAssertEqual(probe(), 1) } }\n' > "$PKG/Tests/ProbeTests/ProbeTests.swift"

# Xcode names the package scheme itself ("Probe-Package" on Xcode 27)
scheme=$(cd "$PKG" && xcodebuild -list 2>/dev/null | awk '/Schemes:/ { f = 1; next } f && NF { print $1; exit }')
echo "package scheme: $scheme"

for platform in tvOS watchOS xrOS iOS; do
  read -r udid runtime name <<< "$(first_device $platform)"
  [ -z "${udid:-}" ] && continue
  echo "== xcodebuild test on a shut-down $platform simulator: $name $runtime"
  echo "state before: $(state $udid)"
  ( while true; do state "$udid"; sleep 1; done ) > "$OUT/states-$platform.log" 2>&1 &
  watcher=$!
  (cd "$PKG" && xcodebuild test -scheme "$scheme" -destination "id=$udid" -derivedDataPath "$OUT/dd-$platform") > "$OUT/xcodebuild-$platform.log" 2>&1
  echo "xcodebuild exit=$?"
  kill $watcher; wait $watcher 2>/dev/null
  grep -E "Executed|TEST (SUCCEEDED|FAILED)" "$OUT/xcodebuild-$platform.log" | tail -2
  grep -A3 "Testing failed" "$OUT/xcodebuild-$platform.log"
  echo "states seen during the run:"
  uniq -c "$OUT/states-$platform.log"
  echo "state after: $(state $udid)"
  xcrun simctl spawn "$udid" log collect --output "$OUT/$platform-after.logarchive" > "$OUT/collect-$platform-after.log" 2>&1
  echo "log collect (after xcodebuild) exit=$?"
  head -2 "$OUT/collect-$platform-after.log"
  xcrun simctl shutdown "$udid" 2>/dev/null
done
