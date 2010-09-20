#!/usr/bin/env ruby

# = run, a safer (and hopefully more convenient) alternative to popen3
#
# Copyright (c) 2010 Csaba Henk <csaba@lowlife.hu>

require 'fcntl'
require 'socket'

module Run
  extend self

  # too hacky too bad ruby doesn't do it for us
  DEVNULL =
  if RUBY_PLATFORM =~ /win|mingw|msdos/i and RUBY_PLATFORM !~ /darwin/i
    'NUL'
  else
    '/dev/null'
  end
  File.exist? DEVNULL or raise "null device not found"

  class Runfail < StandardError

    def initialize cst
      @status = cst
    end

    attr_reader :status

  end

  class RunStatus < Array

    attr_reader :in, :out, :err, :pid, :child_status

    SYM = { STDIN => :@in, STDOUT => :@out, STDERR => :@err }

    def initialize map, pid
      map.each { |k, v|
        (s = SYM[k]) ? instance_variable_set(s, v) : k.close
        self << v
      }
      self << pid
      @pid = pid
    end

    def ios
      select { |e| IO === e }
    end

    def close *iocl
      iocl.empty? and iocl = ios
      delete_if { |i|
        iocl.delete i or next
        i.closed? or i.close
        SYM.values.each { |s|
          i == instance_variable_get(s) and instance_variable_set s, nil
        }
        true
      }
    end

    def wait
      @child_status = Process.wait2(@pid)[1] if @pid
    end

    def complete
      close
      wait
    end

  end

  class Runner

    DEREP = Hash.new { |h, k| k }.merge! \
            0 => STDIN, 1 => STDOUT, 2 => STDERR, nil => DEVNULL
    IO2PI = Hash.new(1).merge! STDIN => 0

    def derep pr
      k, v = pr.map { |e| DEREP[e] }
      if v == true
        v = k.fileno < 3 ? IO.pipe : UNIXSocket.socketpair
        @ios.concat v
      end
      [k, v]
    end

    def self.argsep args
      args.flatten.partition {|x| String === x or x.respond_to? :call }
    end

    def initialize ctrl
      @ctrl = ctrl
      @ios = []
    end

    def run cact, *args

      # assemble the redirection plan, replacing symbolic representatives
      # with real things.
      redirs = []
      do_lines = block_given?
      args.each { |q|
        Hash === q or q = { q => true }
        q.each { |e|
          x, y = derep e
          (x == STDOUT or Array === y) and do_lines = false
          redirs << [x, y]
        }
      }
      do_lines and redirs << [STDOUT, IO.pipe]

      # This is how child will perform redirection instructions.
      ioredir = proc do
        redirs.each { |io, tg|
          case tg
          when Array
            i = IO2PI[io]
            tg[1 - i].close
            io.reopen tg[i]
            tg[i].close
          else
            io.reopen tg
          end
        }
      end

      # Fork child; if there are arguments, exec them
      # (with failure detection).
      @pid = if cact
        fork {
          ioredir.call
          cact.call
        }
      else
        fork or (
          ioredir.call
          return
        )
      end

      # Post-fork cleanup in parent, set up RunStatus
      # (registry of outstanding resources)
      iofa = []
      redirs.each { |io, tg|
        next unless Array === tg
        i = IO2PI[io]
        tg[i].close
        iofa << [io, tg[1 - i]]
      }
      @rst = RunStatus.new iofa, @pid

      # blow up upon exec failure
      if @ctrl
        ctrl = @rst.ios[-1]
        mex = ctrl.read
        @rst.close ctrl
        unless mex.empty?
          @rst.wait
          raise Marshal.load mex
        end
      end

      # blocky mode
      if block_given?
        if do_lines
          @rst.out.each { |l| yield l }
        else
          yield *@rst.ios
        end
        @rst.close
      end

      return @rst
    end

    def cleanup
      @ios.each { |i| i.closed? or i.close }
      @rst.close if @rst
      begin
        Process.wait @pid, Process::WNOHANG
      rescue Errno::ECHILD
      end if @pid
    end

  end

  # General syntax:
  #
  #   run(*args, *options)
  #   run(*args, *options) { |...| }
  #
  # _args_ consists of strings, ie. the command you want to run and its arguments.
  # _args_ is passed to Kernel#exec in the child.
  #
  # _options_ can be the following symbols: +:input+, +:output+, +:error+,
  # +:may_fail+, +:may_fail_loud+.
  #
  # A feature of _run_ is that it throws exception if the invoked command fails;
  # (which can be relaxed by passing +:may_fail+ or +:may_fail_loud+).
  #
  # In its simplest form,
  #
  #   run(*args)
  #   => pst
  #
  # _run_ runs the command, waits for its termination, and returns the process
  # exit status (unless the command failed, in which case a Runfail is raised).
  #
  # For reading lines from child, do:
  #
  #   run(*args) { |l| l =~ /v[1i][4a]gr[4a]/i and break "spam!" }
  #
  # Closing stdout is ensured, above things about termination apply here too.
  #
  # For getting the file object as such, add the +:output+ option:
  #
  #   run(*args, :output) { |f|
  #     while b = f.read(1024)
  #       b =~ /\0/m and break "binary!"
  #     end
  #   }
  #
  # If you want a customized set of children's descriptors, just use the
  # desired ones of +:input+, +:output+, +:error+:
  #
  #   run("sed", "s/better than //", :input, :output) { |fi, fo|
  #     fi.puts "Mac is better than a PC"
  #     fi.close
  #     puts fo.read
  #   }
  #
  # Finally, if you want to get at some descriptors in a non-closed form,
  # you can do it like:
  #
  #   run(*args, :error, :output)
  #   => [fo, fe, pid]
  #
  # ie. it returns the desired descriptors plus the child pid. Child is not
  # waited so cleaning up the fd-s and handling child's exit is up to you.
  #
  # Note that the descriptor set is always passed to you (either to block
  # or to caller) in the order of stdin, stdout, stderr, regardless
  # the order of the +:input+, +:ouput+, +:error+ options at _run_ invocation.
  #
  # +:may_fail+ and +:may_fail_loud+ modify the behavior of the first three
  # type of invocations. They let the child fail without raising an
  # exception. +:may_fail+ also redirects stderr to /dev/null (unless
  # +:error+ is passed).
  #
  def run *args, &bl
    carg, rest = Runner.argsep args

    rst = run! *args, &bl
    if !rst or         # we are the child
       carg.empty? or  # child didn't exec
       !rst.ios.empty? # we have open pipes
      return rst
    end

    pst = rst.wait
    unless pst.success?
      raise Runfail.new(pst), "\"#{carg.join " "}\" exited with " <<
            (pst.exitstatus ?
            "status #{pst.exitstatus}" :
            "signal #{pst.termsig}")
    end

    pst
  end

  def run! *args, &bl
    # Separate arguments which specify what the child is to do
    # from those ones which describe I/O redirection.
    carg_raw, rest = Runner.argsep args

    # assemble action plan for child
    ccalls, carg = carg_raw.partition { |x| x.respond_to? :call }
    cact = ccalls.last

    r = nil
    ctrl = nil
    begin
      if !cact and !carg.empty?
        # we are to exec
        ctrl = open DEVNULL
        rest << ctrl
        cact = proc {
          ctrl.fcntl Fcntl::F_SETFD, Fcntl::FD_CLOEXEC
          begin
            carg[0] = [carg[0], carg[0]]
            exec *carg
          rescue Exception => ex
            Marshal.dump ex, ctrl
          end
        }
      end

      r = Runner.new ctrl
      r.run cact, *rest, &bl
    rescue Exception
      ctrl and !ctrl.closed? and ctrl.close
      r.cleanup if r
      raise
    end
  end

end

if __FILE__ == $0
  include Run

  p run "head", __FILE__

  puts "----8<----"

  begin
    run "ls", "boobooyadada", STDERR => nil
  rescue Runfail => e
    puts "dude, ill fate found us like: #{e}"
  end

  puts "----8<----"

  pid, = run!("ls", "bahhhabiiyyaya", STDERR) { |pe|
    pe.each { |l| puts "ls whines on us as #{l.inspect}" }
  }
  p Process.wait2 pid

  puts "----8<----"

  run(%w[cat -n], __FILE__, STDOUT) { |fo| run("head", STDIN => fo) }

  puts "----8<----"
  # DSL-ish indentation for pipe sequences
  #
  # Note that in order to relax the situation of pygmentize
  # not being installed, calling it with #run! does not
  # suffice, as the demise of pygmentize may provoke a SIGPIPE
  # for head.

  pyg = "pygmentize"

  begin
          run(%w[cat -n], __FILE__, STDOUT) {
     |fo| run("head", STDOUT, STDIN => fo)  {
     |fo| run(pyg, %w[-g /dev/stdin], STDIN => fo, STDERR => nil)
    }}
  rescue Runfail => e
    puts "cannot run #{pyg} :("
  end

  puts "----8<----"

  puts (r = run(STDOUT)) ? "child says #{r.out.read.inspect}" : "hi dad"

end
