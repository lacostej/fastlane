# Prototype of FastlanePty.spawn that keeps a controlling terminal (fastlane#21792): a forked helper is the session
# leader, starts the command in its session, writes an end marker once it exits, and only exits itself (taking the
# terminal away) after the parent has read up to the marker. The helper ends as the command did, so the parent
# waits for a real Process::Status.
require 'pty'
require 'securerandom'

module HelperPty
  TIOCSCTTY = RUBY_PLATFORM.include?("darwin") ? 0x20007461 : 0x540E

  def self.spawn(command, env: {})
    master, slave = PTY.open
    master.binmode
    marker = "\x00fastlane-pty-end-#{SecureRandom.hex(8)}\x00".b
    start_r, start_w = IO.pipe # helper -> parent: "pid N" or "errno N"
    done_r, done_w = IO.pipe # parent closes it once it has read the marker
    helper = fork do
      start_r.close
      done_w.close
      master.close
      Process.setsid
      slave.ioctl(TIOCSCTTY, 0)
      begin
        pid = Process.spawn(env, command, in: slave, out: slave, err: slave)
      rescue SystemCallError => e
        start_w.write("errno #{e.errno}")
        exit!(127)
      end
      start_w.write("pid #{pid}")
      start_w.close
      _, status = Process.wait2(pid)
      begin
        slave.write(marker)
      rescue SystemCallError, IOError
        nil
      end
      done_r.read
      if status.signaled?
        begin
          Signal.trap(status.termsig, "DEFAULT")
        rescue ArgumentError, Errno::EINVAL
          nil # SIGKILL and SIGSTOP cannot be trapped, and need no reset
        end
        Process.kill(status.termsig, Process.pid)
        sleep
      end
      exit!(status.exitstatus)
    end
    start_w.close
    done_r.close
    slave.close
    kind, number = start_r.read.split(" ")
    start_r.close
    if kind != "pid"
      done_w.close
      Process.wait2(helper)
      master.close
      raise SystemCallError.new("fork failed", Integer(number))
    end

    out_r, out_w = IO.pipe
    found = false
    pump = Thread.new do
      buffer = "".b
      keep = marker.bytesize - 1
      begin
        loop do
          buffer << master.readpartial(65_536)
          if (i = buffer.index(marker))
            found = true
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
        done_w.close unless done_w.closed?
      end
    end

    begin
      yield(out_r, master, Integer(number))
    ensure
      out_r.close unless out_r.closed?
      # A caller that stopped reading before the marker: close the terminal so a child blocked writing gets an error.
      # Once the marker is read the helper is waiting for done_w, and closing the terminal first would hang it up (SIGHUP).
      master.close unless found
      pump.join
      done_w.close unless done_w.closed?
      _, status = Process.wait2(helper)
      master.close unless master.closed?
    end
    raise StandardError, "Process crashed" if status.signaled?
    status.exitstatus
  end
end
