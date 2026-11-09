# Does holding the parent's slave fd open until the child is reaped keep a short command's output on macOS?
# Usage: ruby hold-slave.rb <runs per variant> <processes>
require 'pty'
require 'json'

runs = Integer(ARGV[0])
processes = Integer(ARGV[1])

def run_once(command, hold_slave)
  master, slave = PTY.open
  pid = Process.spawn(command, in: slave, out: slave, err: slave, pgroup: true)
  slave.close unless hold_slave
  out = +""
  if hold_slave
    # The slave stays open, so the master never reaches end-of-file: wait for the child, then read what is left
    _, status = Process.wait2(pid)
    loop do
      out << master.read_nonblock(4096)
    rescue IO::WaitReadable
      break
    end
    slave.close
  else
    begin
      loop { out << master.readpartial(4096) }
    rescue EOFError, Errno::EIO
    end
    _, status = Process.wait2(pid)
  end
  master.close
  [out.delete("\r").chomp, status.exitstatus]
end

counts = processes.times.map do
  r, w = IO.pipe
  pid = fork do
    r.close
    result = { "close" => Hash.new(0), "hold" => Hash.new(0) }
    (runs / processes).times do
      result["close"][run_once("echo foo", false)[0]] += 1
      result["hold"][run_once("echo foo", true)[0]] += 1
    end
    w.write(JSON.generate(result))
    w.close
  end
  w.close
  [pid, r]
end.map { |pid, r| d = r.read; Process.wait(pid); JSON.parse(d) }

%w[close hold].each do |variant|
  total = Hash.new(0)
  counts.each { |c| c[variant].each { |k, v| total[k] += v } }
  lost = total.values.sum - total["foo"]
  puts "#{variant.ljust(6)} lost #{lost}/#{total.values.sum} #{total.reject { |k, _| k == 'foo' }}"
end
