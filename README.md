Run
===

Run can be used to spawn processes and interact with their I/O streams,
similiarly to [Open3#popen3](http://apidock.com/ruby/Open3/popen3).

It aims to solve some of the issues of popen, though.

Install
-------

      gem build run.gemspec
      sudo gem install run-*.gem

This is what you want, this is what you get
-------------------------------------------

* Run commands bypassing the shell, directly via `Kernel#exec`.
  (So far so good with `popen3` as well.)
* The simplest case must be simple:

       run "cat", "/etc/passwd"

* The most frequent task must be simple:

       run("ls", "pics") { |l| puts l if l =~ /jpg$/ }

* Child's failure should be noticed and handled. You get an exception if children fails
  (but you may relax this).

       run "ls", "/root"
       ls: cannot open directory /root: Permission denied
       [Exc!] "ls /root" failed with 2 (Run::Runfail)

       pst = run "ls", "/root", :may_fail
       pst.exitstatus
       => 2

* Non-line-oriented reading must be easy too:

       run("zcat", "foo.tar.gz", :output) { |fo|
         Minitar.unpack fo
       }

* Play with streams freely.

       run("tr", "l?", "f!", :input, :output) { |fi, fo|
         fi.puts "out of luck?"
         fi.close
         puts fo.read
       }

* DIY.

       fo, pid = run "curl", "-s", "index.hu", :output
       parse_extract_html fo
       Process.wait pid

See ebedded RDoc for more.
