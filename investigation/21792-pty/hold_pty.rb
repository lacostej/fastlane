# Prototype of FastlanePty.spawn that keeps the parent's slave open until the child is reaped (fastlane#21792).
# HOLD_CTTY=1 also makes the PTY the child's controlling terminal, which brings the loss back: see README.md.
# Same contract as FastlanePty.spawn_with_pty: yields (stdout, stdin, pid), returns the exit status,
# raises when the child was killed by a signal.
require 'pty'
require 'securerandom'

module HoldPty
  TIOCSCTTY = RUBY_PLATFORM.include?("darwin") ? 0x20007461 : 0x540E

  def self.spawn(command, env: {})
    master, slave = PTY.open
    master.binmode
    # The child reports a failed exec through this pipe, as PTY.spawn does
    exec_r, exec_w = IO.pipe
    pid = fork do
      exec_r.close
      master.close
      if ENV["HOLD_CTTY"] == "1"
        Process.setsid
        slave.ioctl(TIOCSCTTY, 0)
      else
        Process.setpgid(0, 0)
      end
      $stdin.reopen(slave)
      $stdout.reopen(slave)
      $stderr.reopen(slave)
      slave.close
      begin
        exec(env, command)
      rescue SystemCallError => e
        exec_w.write(e.errno.to_s)
        exec_w.close
        exit!(127)
      end
    end
    exec_w.close
    errno = exec_r.read
    exec_r.close
    unless errno.empty?
      Process.wait2(pid)
      slave.close
      master.close
      raise SystemCallError.new("fork failed", Integer(errno))
    end

    marker = "\x00fastlane-pty-end-#{SecureRandom.hex(8)}\x00".b
    out_r, out_w = IO.pipe
    # The child's output is ahead of the marker in the terminal's queue: copy it to the pipe until the marker
    pump = Thread.new do
      buffer = "".b
      keep = marker.bytesize - 1
      begin
        loop do
          buffer << master.readpartial(65_536)
          if (i = buffer.index(marker))
            out_w.write(buffer.byteslice(0, i))
            break
          end
          next if buffer.bytesize <= keep
          out_w.write(buffer.byteslice(0, buffer.bytesize - keep))
          buffer = buffer.byteslice(buffer.bytesize - keep, keep)
        end
      rescue EOFError, Errno::EIO, Errno::EPIPE, IOError
        nil
      ensure
        out_w.close unless out_w.closed?
      end
    end
    reaper = Thread.new do
      _, status = Process.wait2(pid)
      begin
        slave.write(marker)
      rescue IOError, SystemCallError
        nil
      end
      status
    end

    begin
      yield(out_r, master, pid)
    ensure
      out_r.close unless out_r.closed?
      # A caller that stopped reading early: close the terminal, as PTY.spawn's callers do, so a child blocked writing gets an error
      master.close unless reaper.join(0)
      status = reaper.value
      pump.join
      slave.close
      master.close unless master.closed?
    end
    raise StandardError, "Process crashed" if status.signaled?
    status.exitstatus
  end
end
