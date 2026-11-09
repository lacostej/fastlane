# Runs the same commands through master's FastlanePty.spawn and the HoldPty prototype, reading as CommandExecutor.execute does.
# Usage: ruby compare.rb <fastlane_pty.rb> [stress runs] [stress processes]
require 'json'
require 'timeout'
require_relative File.expand_path(ARGV[0])
require_relative 'hold_pty'
require_relative 'helper_pty'

IMPLS = {
  "master" => ->(cmd, &blk) { FastlaneCore::FastlanePty.spawn(cmd, &blk) },
  "hold" => ->(cmd, &blk) { HoldPty.spawn(cmd, &blk) },
  "helper" => ->(cmd, &blk) { HelperPty.spawn(cmd, &blk) }
}.freeze

def read_all(impl, command, stop_after: nil)
  lines = []
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  status = Timeout.timeout(20) do
    IMPLS[impl].call(command) do |stdout, _stdin, _pid|
      stdout.each do |l|
        lines << l.chomp.delete("\r")
        break if stop_after && lines.size >= stop_after
      end
    end
  end
  [status, lines, (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2)]
rescue Timeout::Error
  [:timeout, lines, 20]
rescue StandardError => e
  ["#{e.class}: #{e.message} (exit_status #{e.exit_status})", lines, (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2)]
end

ruby = RbConfig.ruby
CASES = [
  ["echo foo", "echo foo", ->(s, l) { s == 0 && l == ["foo"] }],
  ["printf foo, no newline", "printf foo", ->(s, l) { s == 0 && l == ["foo"] }],
  ["UTF-8 bytes", "printf 'caf\\303\\251\\n'", ->(s, l) { s == 0 && l == ["café"] }],
  ["200,000 lines", "#{ruby} -e 'puts (1..200_000).to_a'", ->(s, l) { s == 0 && l.size == 200_000 && l.last == "200000" }],
  ["exit 3", "sh -c 'echo out; exit 3'", ->(s, l) { s == 3 && l == ["out"] }],
  ["killed", "kill -9 $$", ->(s, _l) { s.to_s.include?("Process crashed") }],
  ["missing program", "fl-no-such-program", ->(s, _l) { s.to_s.include?("No such file") }],
  ["stdout is a terminal", "#{ruby} -e 'p $stdout.tty?'", ->(s, l) { s == 0 && l == ["true"] }],
  ["controlling terminal", "sh -c 'echo via-dev-tty > /dev/tty'", ->(s, l) { s == 0 && l == ["via-dev-tty"] }],
  ["background child keeps the terminal", "sh -c 'sleep 3 & echo foo'", ->(s, l) { s == 0 && l == ["foo"] }],
  ["caller stops early", "yes", ->(_s, l) { l.size == 3 }]
].freeze

CASES.each do |name, command, ok|
  IMPLS.each_key do |impl|
    status, lines, secs = read_all(impl, command, stop_after: (name == "caller stops early" ? 3 : nil))
    shown = lines.size > 3 ? "#{lines.size} lines, last #{lines.last.inspect}" : lines.inspect
    puts format("%-38s %-7s %-4s %5.2fs status=%s output=%s", name, impl, ok.call(status, lines) ? "ok" : "DIFF", secs, status.inspect, shown)
  end
end

runs = Integer(ARGV[1] || 0)
processes = Integer(ARGV[2] || 1)
exit if runs.zero?
IMPLS.each_key do |impl|
  results = processes.times.map do
    r, w = IO.pipe
    pid = fork do
      r.close
      counts = Hash.new(0)
      (runs / processes).times { counts[read_all(impl, "echo foo")[1].join("\n")] += 1 }
      w.write(JSON.generate(counts))
      w.close
    end
    w.close
    [pid, r]
  end.map { |pid, r| d = r.read; Process.wait(pid); JSON.parse(d) }
  total = Hash.new(0)
  results.each { |c| c.each { |k, v| total[k] += v } }
  puts "stress #{impl.ljust(7)} echo foo: lost #{total.values.sum - total['foo']}/#{total.values.sum} #{total.reject { |k, _| k == 'foo' }}"
end
