#!/usr/bin/env ruby

# = run, a safer (and hopefully more convenient) alternative to popen3
#
# Copyright (c) 2010 Csaba Henk <csaba@lowlife.hu>

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

  DEREP = Hash.new { |h, k| k == true ? IO.pipe : k }.merge! \
            0 => STDIN, 1 => STDOUT, 2 => STDERR, nil => DEVNULL
  IO2PI = { STDIN => 0, STDOUT => 1, STDERR => 1 }

  def argsep args
    args.flatten.partition {|x| String === x }
  end
  private :argsep

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
    res = run! *args, &bl

    case res
    when Process::Status
      unless res.success?
        carg, rest = argsep args
        raise Runfail, "\"#{carg.join " "}\" exited with " <<
              (res.exitstatus ? res.exitstatus.to_s : "signal #{res.termsig}")
      end
    end

    res
  end

  def run! *args
    carg, rest = argsep args
    redirs = []
    do_lines = block_given?
    rest.each { |q|
      Hash === q or q = { q => true }
      q.each { |k,v|
        x, y = DEREP.values_at k, v
        (x == STDOUT or Array === y) and do_lines = false
        redirs << [x, y]
      }
    }
    do_lines and redirs << [STDOUT, IO.pipe]

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

    iofa = []
    redirs.each { |io, tg|
      next unless Array === tg
      i = IO2PI[io]
      tg[i].close
      iofa << [io, tg[1 - i]]
    }
    fa = iofa.sort_by { |io, f| io.fileno }.transpose[1]
    fa ||= []

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
    end

    if carg.empty? or (!block_given? and !fa.empty?)
      # if child doesn't exec or there are open
      # pipes, hand over control to caller
      return fa << pid
    end

    pid, pst = Process.wait2 pid
    pst
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

  p run!("ls", "bahhhabiiyyaya", STDERR) { |pe|
    pe.each { |l| puts "ls whines on us as #{l.inspect}" }
  }

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

  puts (r = run(STDOUT)) ? "child says #{r[0].read.inspect}" : "hi dad"

end
