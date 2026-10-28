#!/bin/bash
# Probe for scan's simulator pre-boot (fastlane#30498): can simctl boot non-iOS simulators,
# and does xcodebuild shut down a tvOS simulator it booted itself?
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

read -r udid runtime name <<< "$(first_device tvOS)"
if [ -n "${udid:-}" ]; then
  echo "== xcodebuild test on a shut-down tvOS simulator: $name $runtime"
  echo "state before: $(state $udid)"
  ( while true; do state "$udid"; sleep 1; done ) > "$OUT/states-tvos.log" 2>&1 &
  watcher=$!
  xcodebuild test -project snapshot/example/Example.xcodeproj -scheme ExampleTVUITests \
    -destination "id=$udid" -derivedDataPath "$OUT/dd" TVOS_DEPLOYMENT_TARGET=15.0 > "$OUT/xcodebuild-tvos.log" 2>&1
  echo "xcodebuild exit=$?"
  kill $watcher
  grep -E "Executed|TEST (SUCCEEDED|FAILED)" "$OUT/xcodebuild-tvos.log" | tail -2
  grep -A3 "Testing failed" "$OUT/xcodebuild-tvos.log"
  echo "states seen during the run:"
  uniq -c "$OUT/states-tvos.log"
  echo "state after: $(state $udid)"
  xcrun simctl spawn "$udid" log collect --output "$OUT/tvos-after.logarchive" > "$OUT/collect-tvos-after.log" 2>&1
  echo "log collect (after xcodebuild) exit=$?"
  head -2 "$OUT/collect-tvos-after.log"
fi
