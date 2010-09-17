#!/usr/bin/env ruby

# = run, a safer (and hopefully more convenient) alternative to popen3
#
# Copyright (c) 2010 Csaba Henk <csaba@lowlife.hu>

require 'ostruct'

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

  class Runfail < Exception
  end

  class OSSafe < OpenStruct

     def method_missing mid, *args
       mid.to_s =~ /=$/ or @table.include? mid or
         raise NoMethodError, "undefined method \"#{mid}\""
       super
     end

  end

  def run_opts_default
    {:stdin         => false,
     :stdout        => false,
     :stderr        => false,
     :may_fail      => false}
  end
  private :run_opts_default

  @@iomap = { STDIN => :stdin, STDOUT => :stdout, STDERR => :stderr }

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
  def run *args
    carg = []
    tyarg = { Array => carg, String => carg }
    args.each { |a| (tyarg[a.class] ||= []) << a }
    carg.flatten!
    opts = run_opts_default
    (tyarg[IO]     || []).each { |io| opts[@@iomap[io]] = true }
    (tyarg[Symbol] || []).each { |s|  opts[s] = true }
    (tyarg[Hash]   || []).each { |h|
      h.each { |k, v| opts[IO === k ? @@iomap[k] : k] = v }
    }

    o = OSSafe.new opts
    if block_given? and ![o.stdin, o.stdout, o.stderr].include? true
      o.stdout = do_lines = true
    end
    pii, pio, pie = nil
    o.stdin  == true and pii = IO.pipe
    o.stdout == true and pio = IO.pipe
    o.stderr == true and pie = IO.pipe
    %w[stdin stdout stderr].each { |d|
      o.send(d) == nil and o.send d + '=', DEVNULL
    }

    ioredir = proc {
      if pii
        pii[1].close
        STDIN.reopen pii[0]
      end
      if pio
        pio[0].close
        STDOUT.reopen pio[1]
      end
      if pie
        pie[0].close
        STDERR.reopen pie[1]
      end

      %w[stdin stdout stderr].each { |d|
        t = o.send(d)
        t == !!t or Object.const_get(d.upcase).reopen t
      }
    }
    pid = if carg.empty?
      fork or (
        ioredir.call
        return
      )
    else
      fork {
        ioredir.call
        exec *carg
      }
    end

    pii and pii[0].close
    pio and pio[1].close
    pie and pie[1].close

    fa = [(pii||[])[1], (pio||[])[0], (pie||[])[0]].compact
    if block_given?
      begin
        if do_lines
          fa[0].each { |l| yield l }
        else
          yield *fa
        end
      ensure
        fa.each { |f| f.closed? or f.close }
      end
    elsif !fa.empty?
      return fa << pid
    end

    pid, pst = Process.wait2 pid
    pst.success? or o.may_fail or
      raise Runfail, "\"#{carg.join " "}\" exited with " <<
            (pst.exitstatus ? pst.exitstatus.to_s : "signal #{pst.termsig}")
    pst
  end

  #
  # equivalent with
  #
  #   run!(:may_fail, ...)
  #
  # invocation
  #
  def run!(*args, &bl)
    run(*args, :may_fail, &bl)
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

  p run("ls", "bahhhabiiyyaya", STDERR, :may_fail) { |pe|
    pe.each { |l| puts "ls whines on us as #{l.inspect}" }
  }

  puts "----8<----"

  run(%w[cat -n], __FILE__, STDOUT) { |fo| run("head", STDIN => fo) }

  puts "----8<----"
  # DSL-ish indentation for pipe sequences
  #
  # Note that in order to relax the situation of pygmentize
  # not being installed, a simple :may_fail for it does not
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

  puts (r = run(STDOUT)) ? "child says #{r[0].read.inspect}" : "hi dad"

end
