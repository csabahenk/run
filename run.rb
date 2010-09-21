#!/usr/bin/env ruby

# = run, a safer (and hopefully more convenient) alternative to popen3
#
# Copyright (c) 2010 Csaba Henk <csaba@lowlife.hu>

require 'fcntl'
require 'socket'

module Run

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

    attr_reader :status, :run_unwaited_pid

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

    def initialize args, block
      @ios = []
      @block = block

      # Separate arguments which specify what the child is to do
      # from those ones which describe I/O redirection.
      carg_raw, redir_raw = args.flatten.partition { |x|
        String === x or Symbol === x or x.respond_to? :call
      }

      # Child action.
      calls, carg_sx = carg_raw.partition { |x| x.respond_to? :call }
      carg_s, carg_x = carg_sx.partition { |x| String === x }
      carg = calls.last
      if !carg and !carg_s.empty?
        carg = carg_s
        cname = (carg_x.last || carg[0]).to_s
        carg[0] = [carg[0], cname]
      end
      @carg = carg

      # Parse redirection directives.
      redir = []
      do_lines = !!@block
      redir_raw.each { |q|
        Hash === q or q = { q => true }
        q.each { |e|
          x, y = DEREP.values_at *e
          (x == STDOUT or y == true) and do_lines = false
          redir << [x, y]
        }
      }
      do_lines and redir << [STDOUT, true]

      @do_lines = do_lines
      @redir    = redir
    end

    def run
      @want_wait = want_wait?
      run!
      return @rst unless @want_wait

      pst = @rst.wait
      unless pst.success?
        carg_rep = case @carg
        when Array
          @carg.flatten[1..-1].join " "
        else
          "<ruby>:#{@carg.inspect}"
        end
        raise Runfail.new(pst), "\"#{carg_rep}\" exited with " <<
              (pst.exitstatus ?
              "status #{pst.exitstatus}" :
              "signal #{pst.termsig}")
      end

      pst
    end

    def run!
      run_core case @carg
      when Array
        # We are to execute a program
        # in child, compile respective
        # action. (A control socket
        # shall be installed to detect
        # exec failure.)
        @ctrl = open DEVNULL
        @redir << [@ctrl, true]
        proc {
          @ctrl.fcntl Fcntl::F_SETFD, Fcntl::FD_CLOEXEC
          begin
            exec *@carg
          rescue Exception => ex
            Marshal.dump ex, @ctrl
          end
        }
      else
        @carg
      end

      @rst
    rescue Exception => ex
      cleanup
      ex.instance_variable_set :@run_unwaited_pid, @pid
      class << ex
        attr_reader :run_unwaited_pid
      end
      raise
    end

    private

    def want_wait?
      @carg and          # child action is predefined, and ...
      (!(@redir.transpose[1] || []).include?(true) or # either no channels
                                                      # to child are required,
                                                      # or ...
       @block) # or are required, but restricted to block context
    end

    def run_core cact
      # Prepare I/O.
      @redir.each { |e|
        e[1] == true or next
        e[1] = (e[0].fileno < 3 ? IO.pipe : UNIXSocket.socketpair)
        @ios.concat e[1]
      }

      # This is how child will perform redirection instructions.
      ioredir = proc do
        @redir.each { |io, tg|
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

      # Fork child; if there is pre-specified
      # action, do that.
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
      @redir.each { |io, tg|
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
      if @block
        if @do_lines
          @rst.out.each { |l| @block[l] }
        else
          @block[
            if @rst.ios.size > 1
               yrst = @rst.dup
               yrst.pop
               yrst
            else
               @rst[0]
            end
          ]
        end
        @rst.close
      end
    end

    def cleanup
      @ctrl and !@ctrl.closed? and @ctrl.close
      @ios.each { |i| i.closed? or i.close }
      @rst.close if @rst
      @pid and begin
        Process.wait @pid, @want_wait ? 0 : Process::WNOHANG
      rescue Errno::ECHILD
        @pid = nil
      end and @pid = nil
    end

  end

  module_function

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
    Runner.new(args, bl).run
  end

  def run! *args, &bl
    Runner.new(args, bl).run!
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
